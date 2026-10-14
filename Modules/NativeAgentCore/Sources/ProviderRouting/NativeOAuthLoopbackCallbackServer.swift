import AppKit
import Darwin
import Foundation

public final class NativeOAuthLoopbackCallbackServer: OAuthLoopbackSession, @unchecked Sendable {
    public let redirectURI: URL

    private let fd: Int32
    private let path: String
    private let port: UInt16
    private let displayName: String
    private let callbackPageMessage: @Sendable (URL) -> String
    private let lock = NSLock()
    private var continuation: CheckedContinuation<URL, Error>?
    private var worker: Task<Void, Never>?
    private var activeClients: Set<Int32> = []
    private var didFinish = false
    private var openAIFlow = false

    public init(
        preferredPort: UInt16,
        path: String,
        displayName: String,
        allowsPortFallback: Bool,
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
                guard allowsPortFallback,
                      bindErrno == EADDRINUSE,
                      Self.bind(opened, port: 0) else {
                    throw OAuthLoopbackCallbackError.socket("bind() failed: \(String(cString: strerror(bindErrno)))")
                }
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
                displayName: "ChatGPT", allowsPortFallback: false
            )
        } catch {
            throw NSError(domain: "NativeOAuthFlow", code: -20, userInfo: [
                NSLocalizedDescriptionKey:
                    "Couldn't start the local sign-in listener on port \(port). "
                    + "Another app (or a running `codex`) may be using it. "
                    + "Underlying error: \(error.localizedDescription)"])
        }
        server.openAIFlow = true
        defer { server.cancel() }
        Task { @MainActor in NSWorkspace.shared.open(authURL) }
        do {
            return try await server.wait(timeoutSeconds: 300, expectedState: expectedState)
        } catch OAuthLoopbackCallbackError.timedOut {
            throw NSError(domain: "NativeOAuthFlow", code: -21,
                userInfo: [NSLocalizedDescriptionKey: "ChatGPT sign-in timed out. Start it again to retry."])
        } catch OAuthLoopbackCallbackError.canceled {
            if Task.isCancelled { throw CancellationError() }
            throw OAuthLoopbackCallbackError.canceled
        }
    }

    public func wait(timeoutSeconds: TimeInterval, expectedState: String) async throws -> URL {
        try await withTaskCancellationHandler {
            try await withThrowingTaskGroup(of: URL.self) { group in
                group.addTask { try await self.acceptOnce(expectedState: expectedState) }
                group.addTask {
                    let seconds = max(timeoutSeconds, 1)
                    try await Task.sleep(nanoseconds: UInt64(seconds * 1_000_000_000))
                    self.finish(.failure(OAuthLoopbackCallbackError.timedOut))
                    throw OAuthLoopbackCallbackError.timedOut
                }
                guard let url = try await group.next() else {
                    throw OAuthLoopbackCallbackError.canceled
                }
                group.cancelAll()
                return url
            }
        } onCancel: {
            self.finish(.failure(OAuthLoopbackCallbackError.canceled))
        }
    }

    public func cancel() {
        finish(.failure(OAuthLoopbackCallbackError.canceled))
    }

    private func acceptOnce(expectedState: String) async throws -> URL {
        try await withCheckedThrowingContinuation { (cont: CheckedContinuation<URL, Error>) in
            lock.lock()
            if didFinish {
                lock.unlock()
                cont.resume(throwing: OAuthLoopbackCallbackError.canceled)
                return
            }
            continuation = cont
            worker = Task.detached { [self] in
                acceptRequests(expectedState: expectedState)
            }
            lock.unlock()
        }
    }

    private func acceptRequests(expectedState: String) {
        // Keep the descriptor reserved until the worker can no longer enter
        // accept(), including cancellation before this task starts running.
        defer { Darwin.close(fd) }
        while !Task.isCancelled {
            var addr = sockaddr()
            var len = socklen_t(MemoryLayout<sockaddr>.size)
            let client = Darwin.accept(fd, &addr, &len)
            guard client >= 0 else {
                finish(.failure(OAuthLoopbackCallbackError.canceled))
                return
            }
            lock.lock()
            guard !didFinish else {
                lock.unlock()
                Darwin.close(client)
                return
            }
            var noSigPipe: Int32 = 1
            _ = Darwin.setsockopt(client, SOL_SOCKET, SO_NOSIGPIPE, &noSigPipe,
                                  socklen_t(MemoryLayout<Int32>.size))
            activeClients.insert(client)
            lock.unlock()
            if openAIFlow {
                Task.detached { [self] in
                    if let url = acceptRequest(client, expectedState: expectedState) {
                        finish(.success(url))
                    }
                }
            } else if let url = acceptRequest(client, expectedState: expectedState) {
                finish(.success(url))
                return
            }
        }
    }

    private func acceptRequest(_ client: Int32, expectedState: String) -> URL? {
        defer {
            lock.lock()
            activeClients.remove(client)
            Darwin.close(client)
            lock.unlock()
        }

        let limit = openAIFlow ? 64 * 1024 : 8192
        var buffer = [UInt8](repeating: 0, count: openAIFlow ? 16 * 1024 : limit)
        var requestBytes = Data()
        let lineEnd = Data([13, 10])
        // TCP does not preserve request boundaries. Accumulate the request
        // line within the existing byte cap; cancellation shuts down the read.
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
        let firstLine: String
        if openAIFlow {
            guard let line = String(data: requestBytes[..<end.lowerBound], encoding: .utf8) else {
                writeHTTPResponse(client, accepted: nil)
                return nil
            }
            firstLine = line
        } else {
            firstLine = String(decoding: requestBytes[..<end.lowerBound], as: UTF8.self)
        }
        let parts = firstLine.split(separator: " ")
        guard parts.count >= 2, parts[0] == "GET" else {
            writeHTTPResponse(client, accepted: nil)
            return nil
        }
        let target = String(parts[1])
        let callback: URL?
        if openAIFlow {
            callback = NativeOAuthFlow.callbackTarget(from: firstLine)
                .flatMap { URL(string: "http://localhost:\(port)\($0)") }
                .flatMap { NativeOAuthFlow.callbackHasResult($0) ? $0 : nil }
        } else {
            callback = OAuthLoopbackCallbackPolicy.validCallbackURL(target: target, path: path, port: port)
        }
        guard let url = callback,
              OAuthLoopbackCallbackPolicy.callbackMatchesState(url, expectedState: expectedState) else {
            writeHTTPResponse(client, accepted: nil)
            return nil
        }
        writeHTTPResponse(client, accepted: url)
        return url
    }

    private func finish(_ result: Result<URL, Error>) {
        lock.lock()
        guard !didFinish else {
            lock.unlock()
            return
        }
        didFinish = true
        let cont = continuation
        continuation = nil
        let worker = worker
        self.worker = nil
        // The worker owns close; shutdown interrupts an accepted socket's
        // blocking read/write without racing descriptor reuse.
        for client in activeClients { Darwin.shutdown(client, SHUT_RDWR) }
        Darwin.shutdown(fd, SHUT_RDWR)
        if worker == nil { Darwin.close(fd) }
        lock.unlock()
        worker?.cancel()
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
        if openAIFlow {
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
                html = "Not found."
                status = "404 Not Found"
            }
        } else {
            html = url.map { "<html><body>\(callbackPageMessage($0))</body></html>" }
                ?? "<html><body>This request was not accepted. The NativeAgent \(displayName) sign-in listener is still waiting for the browser callback.</body></html>"
            status = url == nil ? "400 Bad Request" : "200 OK"
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
