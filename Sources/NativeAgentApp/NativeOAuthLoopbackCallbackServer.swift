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

    func wait(timeoutSeconds: TimeInterval) async throws -> URL {
        try await withTaskCancellationHandler {
            try await withThrowingTaskGroup(of: URL.self) { group in
                group.addTask { try await self.acceptOnce() }
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

    private func acceptOnce() async throws -> URL {
        try await withCheckedThrowingContinuation { (cont: CheckedContinuation<URL, Error>) in
            lock.lock()
            if didFinish {
                lock.unlock()
                cont.resume(throwing: CallbackError.canceled)
                return
            }
            continuation = cont
            worker = Task.detached { [self] in
                acceptRequest()
            }
            lock.unlock()
        }
    }

    private func acceptRequest() {
        var addr = sockaddr()
        var len = socklen_t(MemoryLayout<sockaddr>.size)
        let client = Darwin.accept(fd, &addr, &len)
        guard client >= 0 else {
            finish(.failure(CallbackError.canceled))
            return
        }
        defer { Darwin.close(client) }

        var buffer = [UInt8](repeating: 0, count: 8192)
        let count = Darwin.recv(client, &buffer, buffer.count, 0)
        guard count > 0 else {
            writeHTTPResponse(client, ok: false)
            finish(.failure(CallbackError.malformedRequest))
            return
        }
        let request = String(decoding: buffer.prefix(count), as: UTF8.self)
        guard let firstLine = request.split(separator: "\r\n", maxSplits: 1).first else {
            writeHTTPResponse(client, ok: false)
            finish(.failure(CallbackError.malformedRequest))
            return
        }
        let parts = firstLine.split(separator: " ")
        guard parts.count >= 2, parts[0] == "GET" else {
            writeHTTPResponse(client, ok: false)
            finish(.failure(CallbackError.malformedRequest))
            return
        }
        let target = String(parts[1])
        guard let url = Self.validCallbackURL(
            target: target,
            path: path,
            port: port
        ) else {
            writeHTTPResponse(client, ok: false)
            finish(.failure(CallbackError.malformedRequest))
            return
        }
        writeHTTPResponse(client, ok: true)
        finish(.success(url))
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
            ? "<html><body>NativeAgent \(displayName) sign-in complete. You can close this tab.</body></html>"
            : "<html><body>NativeAgent \(displayName) sign-in failed. Return to NativeAgent.</body></html>"
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
