import Darwin
import Foundation

final class NativeOAuthLoopbackCallbackServer: @unchecked Sendable {
    enum CallbackError: LocalizedError {
        case timedOut
        case canceled
        case socket(String)
        case malformedRequest

        var errorDescription: String? {
            switch self {
            case .timedOut:
                return "Timed out waiting for the OAuth callback."
            case .canceled:
                return "OAuth callback listener was canceled."
            case .socket(let message):
                return message
            case .malformedRequest:
                return "Browser callback request was malformed."
            }
        }
    }

    let redirectURI: URL

    private let fd: Int32
    private let path: String
    private let port: UInt16
    private let displayName: String
    private let lock = NSLock()
    private var continuation: CheckedContinuation<URL, Error>?
    private var worker: Task<Void, Never>?
    private var activeClient: Int32?
    private var didFinish = false

    init(
        preferredPort: UInt16,
        path: String,
        displayName: String,
        allowsPortFallback: Bool = true
    ) throws {
        self.path = path
        self.displayName = displayName
        let opened = Darwin.socket(AF_INET, SOCK_STREAM, 0)
        guard opened >= 0 else {
            throw CallbackError.socket("socket() failed: \(String(cString: strerror(errno)))")
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
                    throw CallbackError.socket("bind() failed: \(String(cString: strerror(bindErrno)))")
                }
            }
            guard Darwin.listen(opened, 1) == 0 else {
                throw CallbackError.socket("listen() failed: \(String(cString: strerror(errno)))")
            }
            let resolvedPort = try Self.boundPort(opened)
            guard let uri = URL(string: "http://127.0.0.1:\(resolvedPort)\(path)") else {
                throw CallbackError.socket("Could not build loopback redirect URI.")
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

    func wait(timeoutSeconds: TimeInterval, expectedState: String) async throws -> URL {
        try await withTaskCancellationHandler {
            try await withThrowingTaskGroup(of: URL.self) { group in
                group.addTask { try await self.acceptOnce(expectedState: expectedState) }
                group.addTask {
                    let seconds = max(timeoutSeconds, 1)
                    try await Task.sleep(nanoseconds: UInt64(seconds * 1_000_000_000))
                    self.finish(.failure(CallbackError.timedOut))
                    throw CallbackError.timedOut
                }
                guard let url = try await group.next() else {
                    throw CallbackError.canceled
                }
                group.cancelAll()
                return url
            }
        } onCancel: {
            self.finish(.failure(CallbackError.canceled))
        }
    }

    func cancel() {
        finish(.failure(CallbackError.canceled))
    }

    private func acceptOnce(expectedState: String) async throws -> URL {
        try await withCheckedThrowingContinuation { (cont: CheckedContinuation<URL, Error>) in
            lock.lock()
            if didFinish {
                lock.unlock()
                cont.resume(throwing: CallbackError.canceled)
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
        while !Task.isCancelled {
            var addr = sockaddr()
            var len = socklen_t(MemoryLayout<sockaddr>.size)
            let client = Darwin.accept(fd, &addr, &len)
            guard client >= 0 else {
                finish(.failure(CallbackError.canceled))
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
            activeClient = client
            lock.unlock()
            if let url = acceptRequest(client, expectedState: expectedState) {
                finish(.success(url))
                return
            }
        }
    }

    private func acceptRequest(_ client: Int32, expectedState: String) -> URL? {
        defer {
            lock.lock()
            activeClient = nil
            Darwin.close(client)
            lock.unlock()
        }

        var buffer = [UInt8](repeating: 0, count: 8192)
        var requestBytes = Data()
        let lineEnd = Data([13, 10])
        // TCP does not preserve request boundaries. Accumulate the request
        // line within the existing byte cap; cancellation shuts down the read.
        while requestBytes.range(of: lineEnd) == nil, requestBytes.count < buffer.count {
            let count = Darwin.recv(client, &buffer, buffer.count - requestBytes.count, 0)
            if count < 0, errno == EINTR { continue }
            guard count > 0 else { return nil }
            requestBytes.append(contentsOf: buffer.prefix(count))
        }
        guard let end = requestBytes.range(of: lineEnd) else {
            writeHTTPResponse(client, ok: false)
            return nil
        }
        let firstLine = String(decoding: requestBytes[..<end.lowerBound], as: UTF8.self)
        let parts = firstLine.split(separator: " ")
        guard parts.count >= 2, parts[0] == "GET" else {
            writeHTTPResponse(client, ok: false)
            return nil
        }
        let target = String(parts[1])
        guard let url = Self.validCallbackURL(
            target: target,
            path: path,
            port: port
        ), Self.callbackMatchesState(url, expectedState: expectedState) else {
            writeHTTPResponse(client, ok: false)
            return nil
        }
        writeHTTPResponse(client, ok: true)
        return url
    }

    /// Only the exact state issued for this attempt may consume its listener.
    static func callbackMatchesState(_ url: URL, expectedState: String) -> Bool {
        let states = URLComponents(url: url, resolvingAgainstBaseURL: false)?
            .queryItems?.filter { $0.name == "state" } ?? []
        return !expectedState.isEmpty && states.count == 1 && states[0].value == expectedState
    }

    static func validCallbackURL(
        target: String,
        path: String,
        port: UInt16
    ) -> URL? {
        guard target.hasPrefix("/"),
              let url = URL(string: "http://127.0.0.1:\(port)\(target)"),
              url.path == path,
              let items = URLComponents(
                  url: url,
                  resolvingAgainstBaseURL: false
              )?.queryItems else {
            return nil
        }
        let hasResult = items.contains {
            ($0.name == "code" || $0.name == "error")
                && !($0.value ?? "").isEmpty
        }
        return hasResult ? url : nil
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
        if let activeClient { Darwin.shutdown(activeClient, SHUT_RDWR) }
        Darwin.shutdown(fd, SHUT_RDWR)
        Darwin.close(fd)
        lock.unlock()
        worker?.cancel()
        switch result {
        case .success(let url):
            cont?.resume(returning: url)
        case .failure(let error):
            cont?.resume(throwing: error)
        }
    }

    private func writeHTTPResponse(_ client: Int32, ok: Bool) {
        let html = ok
            ? "<html><body>NativeAgent \(displayName) sign-in callback received. Return to NativeAgent to check whether sign-in completed. You can close this tab.</body></html>"
            : "<html><body>This request was not accepted. The NativeAgent \(displayName) sign-in listener is still waiting for the browser callback.</body></html>"
        let status = ok ? "200 OK" : "400 Bad Request"
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
            throw CallbackError.socket("getsockname() failed: \(String(cString: strerror(errno)))")
        }
        return UInt16(bigEndian: addr.sin_port)
    }
}
