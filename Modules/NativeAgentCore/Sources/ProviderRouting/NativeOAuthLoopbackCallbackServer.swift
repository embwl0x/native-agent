import AppKit
import Darwin
import Foundation
import Synchronization
// Blueprint: | `NativeOAuthLoopbackCallbackServer.swift` | callback-owned wait; cancellation closes blocking socket I/O on Dispatch |

public final class NativeOAuthLoopbackCallbackServer: Sendable {
    public let redirectURI: URL

    private let fd: Int32
    private let path: String
    private let port: UInt16
    private let displayName: String
    private let callbackPageMessage: @Sendable (URL) -> String
    private struct State {
        var continuation: CheckedContinuation<URL, Error>?
        var workerStarted = false
        var waitStarted = false
        var activeClients: Set<Int32> = []
        var didFinish = false
    }
    private let state = Mutex(State())

    public init(
        preferredPort: UInt16,
        path: String,
        displayName: String,
        callbackPageMessage: @escaping @Sendable (URL) -> String = NativeOAuthFlow.callbackPageMessage
    ) throws {
        self.path = path
        self.displayName = displayName
        self.callbackPageMessage = callbackPageMessage
        let opened = Darwin.socket(AF_INET, SOCK_STREAM, 0)
        guard opened >= 0 else {
            throw OAuthLoopbackCallbackError.socket("socket() failed: \(String(cString: strerror(errno)))")
        }
        var socketFD: Int32? = opened
        do {
            var yes: Int32 = 1
            _ = Darwin.setsockopt(
                opened,
                SOL_SOCKET,
                SO_REUSEADDR,
                &yes,
                socklen_t(MemoryLayout<Int32>.size)
            )
            if !Self.bind(opened, port: preferredPort) {
                let bindErrno = errno
                throw OAuthLoopbackCallbackError.socket("bind() failed: \(String(cString: strerror(bindErrno)))")
            }
            guard Darwin.listen(opened, 1) == 0 else {
                throw OAuthLoopbackCallbackError.socket("listen() failed: \(String(cString: strerror(errno)))")
            }
            let resolvedPort = try Self.boundPort(opened)
            guard let uri = URL(string: "http://127.0.0.1:\(resolvedPort)\(path)") else {
                throw OAuthLoopbackCallbackError.socket("Could not build loopback redirect URI.")
            }
            self.fd = opened
            self.port = resolvedPort
            self.redirectURI = uri
            socketFD = nil
        } catch {
            if let socketFD {
                Darwin.close(socketFD)
            }
            throw error
        }
    }


    public static func runOpenAIAuthSession(authURL: URL, port: UInt16, expectedState: String) async throws -> URL {
        guard port != 0 else {
            throw NSError(domain: "NativeOAuthFlow", code: -22,
                userInfo: [NSLocalizedDescriptionKey: "Invalid loopback port \(port)."])
        }
        let server: NativeOAuthLoopbackCallbackServer
        do {
            server = try NativeOAuthLoopbackCallbackServer(
                preferredPort: port, path: NativeOAuthFlow.openAILoopbackPath,
                displayName: "ChatGPT"
            )
        } catch {
            throw NSError(domain: "NativeOAuthFlow", code: -20, userInfo: [
                NSLocalizedDescriptionKey:
                    "Couldn't start the local sign-in listener on port \(port). "
                    + "Another app (or a running `codex`) may be using it. "
                    + "Underlying error: \(error.localizedDescription)"])
        }
        defer { server.cancel() }
        try Task.checkCancellation()
        let opened = await MainActor.run {
            !Task.isCancelled && NSWorkspace.shared.open(authURL)
        }
        try Task.checkCancellation()
        guard opened else {
            throw NSError(domain: "NativeOAuthFlow", code: -23, userInfo: [
                NSLocalizedDescriptionKey: "macOS could not open the sign-in URL. Choose a working default browser in System Settings, then sign in again."
            ])
        }
        do {
            return try await server.wait(expectedState: expectedState)
        } catch OAuthLoopbackCallbackError.canceled {
            if Task.isCancelled { throw CancellationError() }
            throw OAuthLoopbackCallbackError.canceled
        }
    }

    @concurrent
    public func wait(expectedState: String) async throws -> URL {
        // A second caller cannot retire the first caller's listener.
        try state.withLock { state in
            guard !state.didFinish else { throw OAuthLoopbackCallbackError.canceled }
            guard !state.waitStarted else { throw OAuthLoopbackCallbackError.alreadyWaiting }
            state.waitStarted = true
        }
        return try await withTaskCancellationHandler {
            try await acceptOnce(expectedState: expectedState)
        } onCancel: {
            self.cancel()
        }
    }

    public func cancel() {
        DispatchQueue.global(qos: .userInitiated).async { [self] in
            finish(.failure(OAuthLoopbackCallbackError.canceled))
        }
    }

    private func acceptOnce(expectedState: String) async throws -> URL {
        try await withCheckedThrowingContinuation { (cont: CheckedContinuation<URL, Error>) in
            let start = state.withLock { state in
                guard !state.didFinish else { return false }
                state.continuation = cont
                state.workerStarted = true
                return true
            }
            guard start else {
                cont.resume(throwing: OAuthLoopbackCallbackError.canceled)
                return
            }
            // Socket reads leave the cooperative executor free to deliver cancellation.
            DispatchQueue.global(qos: .userInitiated).async { [self] in
                acceptRequests(expectedState: expectedState)
            }
        }
    }

    private func acceptRequests(expectedState: String) {
        // Keep the descriptor reserved until the worker can no longer enter accept(), including cancellation before this worker starts running.
        defer { Darwin.close(fd) }
        while true {
            var addr = sockaddr()
            var len = socklen_t(MemoryLayout<sockaddr>.size)
            let client = Darwin.accept(fd, &addr, &len)
            guard client >= 0 else {
                let failure = errno
                if failure == EINTR { continue }
                if !state.withLock({ $0.didFinish }) {
                    finish(.failure(OAuthLoopbackCallbackError.socket("accept() failed: \(String(cString: strerror(failure)))")))
                }
                return
            }
            let admitted = state.withLock { state in
                guard !state.didFinish, state.activeClients.count < 4 else { return false }
                state.activeClients.insert(client)
                return true
            }
            guard admitted else {
                Darwin.close(client)
                if state.withLock({ $0.didFinish }) { return }
                continue
            }
            var noSigPipe: Int32 = 1
            _ = Darwin.setsockopt(client, SOL_SOCKET, SO_NOSIGPIPE, &noSigPipe,
                                  socklen_t(MemoryLayout<Int32>.size))
            DispatchQueue.global(qos: .userInitiated).async { [self] in
                if let url = acceptRequest(client, expectedState: expectedState) {
                    finish(.success(url))
                }
            }
        }
    }

    private func acceptRequest(_ client: Int32, expectedState: String) -> URL? {
        defer {
            state.withLock { state in
                state.activeClients.remove(client)
                Darwin.close(client)
            }
        }

        let limit = 64 * 1024
        var buffer = [UInt8](repeating: 0, count: 16 * 1024)
        var requestBytes = Data()
        let lineEnd = Data([13, 10])
        // TCP can split the request line across reads; cancellation shuts down the socket.
        while requestBytes.range(of: lineEnd) == nil, requestBytes.count < limit {
            let count = Darwin.recv(client, &buffer, min(buffer.count, limit - requestBytes.count), 0)
            if count < 0, errno == EINTR { continue }
            guard count > 0 else { return nil }
            requestBytes.append(contentsOf: buffer.prefix(count))
        }
        guard let end = requestBytes.range(of: lineEnd) else {
            writeHTTPResponse(client, accepted: nil)
            return nil
        }
        guard let firstLine = String(data: requestBytes[..<end.lowerBound], encoding: .utf8) else {
            writeHTTPResponse(client, accepted: nil)
            return nil
        }
        var parts = firstLine.split(separator: " ").makeIterator()
        guard parts.next() == "GET", let requestTarget = parts.next() else {
            writeHTTPResponse(client, accepted: nil)
            return nil
        }
        guard let url = OAuthLoopbackCallbackPolicy.validCallbackURL(target: String(requestTarget), path: path, port: port),
              OAuthLoopbackCallbackPolicy.callbackMatchesState(url, expectedState: expectedState) else {
            writeHTTPResponse(client, accepted: nil)
            return nil
        }
        writeHTTPResponse(client, accepted: url)
        return url
    }

    private func finish(_ result: Result<URL, Error>) {
        let cont = state.withLock { state -> CheckedContinuation<URL, Error>? in
            guard !state.didFinish else { return nil }
            state.didFinish = true
            let continuation = state.continuation
            state.continuation = nil
            // Shutdown interrupts I/O; the worker retains each descriptor until it exits.
            for client in state.activeClients { Darwin.shutdown(client, SHUT_RDWR) }
            Darwin.shutdown(fd, SHUT_RDWR)
            if !state.workerStarted { Darwin.close(fd) }
            return continuation
        }
        switch result {
        case .success(let url):
            cont?.resume(returning: url)
        case .failure(let error):
            cont?.resume(throwing: error)
        }
    }

    private func writeHTTPResponse(_ client: Int32, accepted url: URL?) {
        let html: String
        let status: String
        if let url {
            let message = callbackPageMessage(url)
            html = """
                <!doctype html><html><head><meta charset="utf-8"><title>NativeAgent</title>
                <style>body{font:15px -apple-system,Helvetica,Arial;background:#111;color:#eee;
                display:flex;height:100vh;align-items:center;justify-content:center;margin:0}
                .c{text-align:center;max-width:420px;padding:24px}</style></head>
                <body><div class="c"><h2>\(message)</h2></div></body></html>
                """
            status = "200 OK"
        } else {
            html = """
                    <html><body>This request was not accepted. The NativeAgent \(displayName) sign-in listener is still waiting for the browser \
                    callback.</body></html>
                    """
            status = "400 Bad Request"
        }
        let response = """
        HTTP/1.1 \(status)\r
        Content-Type: text/html; charset=utf-8\r
        Content-Length: \(html.utf8.count)\r
        Connection: close\r
        \r
        \(html)
        """
        response.withCString { ptr in
            _ = Darwin.send(client, ptr, strlen(ptr), 0)
        }
    }

    private static func bind(_ fd: Int32, port: UInt16) -> Bool {
        var addr = sockaddr_in()
        addr.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
        addr.sin_family = sa_family_t(AF_INET)
        addr.sin_port = in_port_t(port).bigEndian
        addr.sin_addr = in_addr(s_addr: inet_addr("127.0.0.1"))
        let result = withUnsafePointer(to: &addr) { ptr in
            ptr.withMemoryRebound(to: sockaddr.self, capacity: 1) { sockPtr in
                Darwin.bind(fd, sockPtr, socklen_t(MemoryLayout<sockaddr_in>.size))
            }
        }
        return result == 0
    }

    private static func boundPort(_ fd: Int32) throws -> UInt16 {
        var addr = sockaddr_in()
        var len = socklen_t(MemoryLayout<sockaddr_in>.size)
        let result = withUnsafeMutablePointer(to: &addr) { ptr in
            ptr.withMemoryRebound(to: sockaddr.self, capacity: 1) { sockPtr in
                Darwin.getsockname(fd, sockPtr, &len)
            }
        }
        guard result == 0 else {
            throw OAuthLoopbackCallbackError.socket("getsockname() failed: \(String(cString: strerror(errno)))")
        }
        return UInt16(bigEndian: addr.sin_port)
    }
}
