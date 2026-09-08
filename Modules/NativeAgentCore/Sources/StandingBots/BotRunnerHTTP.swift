import Foundation
import Darwin
import Network
import Security

public enum BotRunnerHTTP {
    /// Headless GET only, isolated cookies/cache, bounded body, no scripts or
    /// model-directed follow-up fetches. Unsupported connector strings fail.
    // Match BotRunner's stored callback type at the default argument boundary.
    public static let fetch: BotRunnerFetch = { source, admission in
        try await fetchPinned(source, admission: admission, resolve: { try resolve($0) })
    }

    static let maximumRedirects = 20
    static let maximumBodyBytes = 256 * 1024

    // Internal seams only. Production always checks all answers and uses the
    // numeric endpoint transport; there is no hostname-based connection fallback.
    static func fetchPinned(_ source: String,
                      admission: @escaping BotRunnerAdmission,
                      resolve: @escaping @Sendable (String) throws -> [String],
                      allowsAddress: @escaping @Sendable (String) -> Bool = isPublicAddress,
                      exchange: @escaping @Sendable (URL, String) async throws -> Response = exchange) async throws -> String {
        try await BotRunnerDeadline.run(seconds: 30) {
            guard var url = URL(string: source) else { throw BotRunnerError.unavailableSource }
            for hop in 0...maximumRedirects {
                try Task.checkCancellation()
                let address = try admit(url, resolve: resolve, allowsAddress: allowsAddress)
                try await BotRunner.admit(admission)
                let response = try await exchange(url, address)
                if (300..<400).contains(response.status) {
                    guard hop < maximumRedirects else {
                        throw BotRunnerError.unsafeDestination("redirect limit exceeded")
                    }
                    guard let location = response.headers["location"],
                          let target = URL(string: location, relativeTo: url)?.absoluteURL else {
                        throw BotRunnerError.unsafeDestination("missing or invalid redirect URL")
                    }
                    url = target
                    continue
                }
                guard (200..<300).contains(response.status),
                      response.body.count <= maximumBodyBytes,
                      let text = String(data: response.body, encoding: .utf8) else {
                    throw BotRunnerError.unavailableSource
                }
                return text
            }
            throw BotRunnerError.unavailableSource
        }
    }

    /// Every answer must be public: mixed public/private DNS is not admission.
    /// Kept injectable for deterministic tests without contacting a destination.
    @discardableResult
    static func admit(_ url: URL, resolve: (String) throws -> [String] = resolve,
                      allowsAddress: (String) -> Bool = isPublicAddress) throws -> String {
        guard ["https", "http"].contains(url.scheme?.lowercased() ?? ""),
              let host = url.host, !host.isEmpty, url.user == nil, url.password == nil else {
            throw BotRunnerError.unsafeDestination("HTTP(S) host without credentials required")
        }
        let addresses = try resolve(host.trimmingCharacters(in: CharacterSet(charactersIn: "[]")))
        guard !addresses.isEmpty, addresses.allSatisfy(allowsAddress),
              addresses.allSatisfy({ IPv4Address($0) != nil || IPv6Address($0) != nil }) else {
            throw BotRunnerError.unsafeDestination("host resolves to a non-public address")
        }
        return addresses[0]
    }

    private static func resolve(_ host: String) throws -> [String] {
        var hints = addrinfo()
        hints.ai_family = AF_UNSPEC
        hints.ai_socktype = SOCK_STREAM
        var result: UnsafeMutablePointer<addrinfo>?
        guard getaddrinfo(host, nil, &hints, &result) == 0, let first = result else {
            throw BotRunnerError.unsafeDestination("destination could not be resolved")
        }
        defer { freeaddrinfo(first) }
        var addresses: [String] = []
        var cursor: UnsafeMutablePointer<addrinfo>? = first
        while let row = cursor {
            var buffer = [CChar](repeating: 0, count: Int(NI_MAXHOST))
            guard getnameinfo(row.pointee.ai_addr, row.pointee.ai_addrlen,
                              &buffer, socklen_t(buffer.count), nil, 0, NI_NUMERICHOST) == 0 else {
                throw BotRunnerError.unsafeDestination("unreadable destination address")
            }
            addresses.append(String(cString: buffer))
            cursor = row.pointee.ai_next
        }
        return addresses
    }

    static func isPublicAddress(_ text: String) -> Bool {
        var v4 = in_addr()
        if inet_pton(AF_INET, text, &v4) == 1 {
            let ip = UInt32(bigEndian: v4.s_addr)
            let excluded: [(UInt32, UInt32)] = [
                (0x00000000, 8), (0x0a000000, 8), (0x64400000, 10),
                (0x7f000000, 8), (0xa83f8110, 32), (0xa9fe0000, 16), (0xac100000, 12),
                (0xc0000000, 24), (0xc0000200, 24), (0xc0586300, 24),
                (0xc0a80000, 16), (0xc6120000, 15), (0xc6336400, 24),
                (0xcb007100, 24), (0xe0000000, 3)
            ]
            return !excluded.contains { network, prefix in
                ip & (UInt32.max << (32 - prefix)) == network
            }
        }
        var v6 = in6_addr()
        guard inet_pton(AF_INET6, text, &v6) == 1 else { return false }
        let bytes = withUnsafeBytes(of: &v6) { Array($0) }
        if bytes.prefix(10).allSatisfy({ $0 == 0 }), bytes[10] == 255, bytes[11] == 255 {
            return isPublicAddress(bytes.suffix(4).map(String.init).joined(separator: "."))
        }
        // Only global unicast 2000::/3. Exclude special protocol assignments,
        // documentation and 6to4 (which can embed a private IPv4 destination).
        guard bytes[0] & 0xe0 == 0x20 else { return false }
        if bytes[0] == 0x20 && bytes[1] == 0x01 {
            if bytes[2] < 2 || (bytes[2] == 0x0d && bytes[3] == 0xb8) { return false }
        }
        if bytes[0] == 0x20 && bytes[1] == 0x02 { return false }
        if bytes[0] == 0x3f && bytes[1] == 0xff && bytes[2] & 0xf0 == 0 { return false }
        return true
    }

    struct Response: Sendable {
        let status: Int
        let headers: [String: String]
        let body: Data
    }

    static func verifyPeer(_ endpoint: NWEndpoint?, address: String, port: NWEndpoint.Port) throws {
        guard case let .hostPort(host, actualPort) = endpoint, actualPort == port else {
            throw BotRunnerError.unsafeDestination("connected destination could not be verified")
        }
        let matches: Bool
        switch host {
        case .ipv4(let ip): matches = IPv4Address(address)?.rawValue == ip.rawValue
        case .ipv6(let ip): matches = IPv6Address(address)?.rawValue == ip.rawValue
        default: matches = false
        }
        guard matches else {
            throw BotRunnerError.unsafeDestination("connected address differs from admitted address")
        }
    }

    private static func exchange(_ url: URL, _ address: String) async throws -> Response {
        let transfer = try PinnedTransfer(url: url, address: address)
        return try await withTaskCancellationHandler {
            try Task.checkCancellation()
            return try await withCheckedThrowingContinuation { transfer.start($0) }
        } onCancel: { transfer.cancel() }
    }

    /// URLSession does not expose an SNI override for an IP URL. Network's TLS
    /// options bind SNI and certificate verification to the original hostname,
    /// independently of the numeric TCP endpoint. Only HTTP/1.1 is negotiated.
    private final class PinnedTransfer: @unchecked Sendable {
        let queue = DispatchQueue(label: "StandingBots.pinnedHTTP")
        let connection: NWConnection
        let address: String
        let port: NWEndpoint.Port
        let request: Data
        var continuation: CheckedContinuation<Response, Error>?
        var terminal = false
        var buffer = Data()

        init(url: URL, address: String) throws {
            self.address = address
            let secure = url.scheme?.lowercased() == "https"
            guard let host = url.host?.trimmingCharacters(in: CharacterSet(charactersIn: "[]")),
                  let components = URLComponents(url: url, resolvingAgainstBaseURL: false),
                  let portValue = UInt16(exactly: url.port ?? (secure ? 443 : 80)),
                  let port = NWEndpoint.Port(rawValue: portValue), portValue != 0 else {
                throw BotRunnerError.unsafeDestination("invalid destination host or port")
            }
            self.port = port
            let numericHost: NWEndpoint.Host
            if let ip = IPv4Address(address) { numericHost = .ipv4(ip) }
            else if let ip = IPv6Address(address) { numericHost = .ipv6(ip) }
            else { throw BotRunnerError.unsafeDestination("admitted address is not numeric") }
            let tls = secure ? NWProtocolTLS.Options() : nil
            if let tls {
                sec_protocol_options_set_tls_server_name(tls.securityProtocolOptions, host)
                sec_protocol_options_add_tls_application_protocol(tls.securityProtocolOptions, "http/1.1")
                sec_protocol_options_set_verify_block(tls.securityProtocolOptions, { _, trust, complete in
                    let serverTrust = sec_trust_copy_ref(trust).takeRetainedValue()
                    let policy = SecPolicyCreateSSL(true, host as CFString)
                    // Trust evaluation must not make auxiliary, unpinned network requests.
                    let configured = SecTrustSetPolicies(serverTrust, policy) == errSecSuccess
                        && SecTrustSetNetworkFetchAllowed(serverTrust, false) == errSecSuccess
                    complete(configured && SecTrustEvaluateWithError(serverTrust, nil))
                }, DispatchQueue.global(qos: .utility))
            }
            connection = NWConnection(host: numericHost, port: port,
                                      using: NWParameters(tls: tls, tcp: NWProtocolTCP.Options()))
            let authority = (host.contains(":") ? "[\(host)]" : host)
                + (url.port.map { ":\($0)" } ?? "")
            let target = (components.percentEncodedPath.isEmpty ? "/" : components.percentEncodedPath)
                + (components.percentEncodedQuery.map { "?\($0)" } ?? "")
            guard !authority.contains(where: { $0.isWhitespace || $0.isNewline }),
                  !target.contains(where: { $0.isWhitespace || $0.isNewline }) else {
                throw BotRunnerError.unsafeDestination("invalid HTTP request target")
            }
            request = Data("GET \(target) HTTP/1.1\r\nHost: \(authority)\r\nAccept-Encoding: identity\r\nConnection: close\r\n\r\n".utf8)
        }

        func start(_ waiting: CheckedContinuation<Response, Error>) {
            queue.async {
                guard !self.terminal else { waiting.resume(throwing: CancellationError()); return }
                self.continuation = waiting
                self.connection.stateUpdateHandler = { [weak self] state in
                    guard let self, !self.terminal else { return }
                    switch state {
                    case .ready:
                        do {
                            try self.checkPeer()
                            self.connection.send(content: self.request, completion: .contentProcessed { [weak self] error in
                                guard let self, !self.terminal else { return }
                                if let error { self.finish(.failure(error)) }
                                else { self.receive() }
                            })
                        } catch { self.finish(.failure(error)) }
                    case .failed(let error), .waiting(let error): self.finish(.failure(error))
                    case .cancelled: self.finish(.failure(CancellationError()))
                    default: break
                    }
                }
                self.connection.start(queue: self.queue)
            }
        }

        func cancel() { queue.async { self.finish(.failure(CancellationError())) } }

        func checkPeer() throws {
            try verifyPeer(connection.currentPath?.remoteEndpoint, address: address, port: port)
        }

        func receive() {
            connection.receive(minimumIncompleteLength: 1, maximumLength: 16 * 1024) { [weak self] data, _, complete, error in
                guard let self, !self.terminal else { return }
                do {
                    try self.checkPeer()
                    if let error { throw error }
                    if let data { self.buffer.append(data) }
                    // Bound framing overhead as well as the decoded body.
                    guard self.buffer.count <= maximumBodyBytes * 2 else { throw BotRunnerError.unavailableSource }
                    if let response = try parse(self.buffer, complete: complete) {
                        self.finish(.success(response))
                    } else { self.receive() }
                } catch { self.finish(.failure(error)) }
            }
        }

        func finish(_ result: Result<Response, Error>) {
            guard !terminal else { return }
            terminal = true
            connection.stateUpdateHandler = nil
            connection.cancel()
            let waiting = continuation
            continuation = nil
            waiting?.resume(with: result)
        }
    }

    /// Strict bounded HTTP/1.1 framing: content length, chunked, or EOF. No
    /// decompression, cookies, cache, proxies, or automatic redirect machinery.
    static func parse(_ data: Data, complete: Bool) throws -> Response? {
        func invalid() -> BotRunnerError { .unavailableSource }
        guard let boundary = data.range(of: Data("\r\n\r\n".utf8)) else {
            if complete || data.count > 32 * 1024 { throw invalid() }
            return nil
        }
        guard boundary.upperBound <= 32 * 1024,
              let header = String(data: data[..<boundary.lowerBound], encoding: .utf8) else { throw invalid() }
        let lines = header.components(separatedBy: "\r\n")
        let statusLine = lines[0].split(separator: " ")
        guard statusLine.count >= 2, ["HTTP/1.1", "HTTP/1.0"].contains(String(statusLine[0])),
              let status = Int(statusLine[1]), (200...599).contains(status) else { throw invalid() }
        var headers: [String: String] = [:]
        for line in lines.dropFirst() {
            guard let colon = line.firstIndex(of: ":"), colon != line.startIndex else { throw invalid() }
            let key = line[..<colon].lowercased()
            guard !key.contains(where: { $0.isWhitespace }) else { throw invalid() }
            let value = line[line.index(after: colon)...].trimmingCharacters(in: .whitespaces)
            if headers[key] != nil {
                guard !["content-length", "transfer-encoding", "location", "content-encoding"].contains(key) else { throw invalid() }
                continue // Unused repeated fields (for example Set-Cookie) have no effect.
            }
            headers[key] = value
        }
        if (300..<400).contains(status) || status == 204 {
            return Response(status: status, headers: headers, body: Data())
        }
        guard headers["content-encoding"] == nil || headers["content-encoding"]?.lowercased() == "identity" else { throw invalid() }
        let bytes = Data(data[boundary.upperBound...])
        var body = Data()
        if let transfer = headers["transfer-encoding"] {
            guard transfer.lowercased() == "chunked", headers["content-length"] == nil else { throw invalid() }
            var offset = 0
            while true {
                guard let end = bytes.range(of: Data("\r\n".utf8), in: offset..<bytes.count) else {
                    if complete { throw invalid() }; return nil
                }
                guard end.lowerBound - offset <= 1024,
                      let line = String(data: bytes[offset..<end.lowerBound], encoding: .utf8),
                      let sizeText = line.split(separator: ";", omittingEmptySubsequences: false).first,
                      !sizeText.isEmpty, sizeText.allSatisfy({ $0.isHexDigit }),
                      let size = Int(sizeText, radix: 16), size <= maximumBodyBytes - body.count else { throw invalid() }
                offset = end.upperBound
                if size == 0 {
                    // Trailers are ignored but must terminate and remain bounded.
                    if bytes.count >= offset + 2, bytes[offset..<offset + 2] == Data("\r\n".utf8)
                        || bytes.range(of: Data("\r\n\r\n".utf8), in: offset..<bytes.count) != nil {
                        return Response(status: status, headers: headers, body: body)
                    }
                    if complete { throw invalid() }; return nil
                }
                guard bytes.count >= offset + size + 2 else { if complete { throw invalid() }; return nil }
                guard bytes[offset + size..<offset + size + 2] == Data("\r\n".utf8) else { throw invalid() }
                body.append(bytes[offset..<offset + size])
                offset += size + 2
            }
        } else if let length = headers["content-length"] {
            guard !length.isEmpty, length.allSatisfy({ $0.isASCII && $0.isNumber }),
                  let count = Int(length), count <= maximumBodyBytes else { throw invalid() }
            guard bytes.count >= count else { if complete { throw invalid() }; return nil }
            body = Data(bytes.prefix(count))
        } else {
            guard bytes.count <= maximumBodyBytes else { throw invalid() }
            guard complete else { return nil }
            body = bytes
        }
        return Response(status: status, headers: headers, body: body)
    }
}
