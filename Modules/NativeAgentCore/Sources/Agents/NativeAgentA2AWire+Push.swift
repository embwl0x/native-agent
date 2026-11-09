import Foundation
import NativeAgentShared
import Darwin
import PersistenceCore
import AgentConversations
import MacControl

// Blueprint: | `NativeAgentA2AWire+Push.swift` | `AgentContactCallback`, `AgentContactPushConfig` |

/// Persist callback account references only; URLs and credentials may contain secrets and belong in Keychain.
public struct AgentContactCallback: Codable, Sendable, Equatable {
    let account: String
    var delivered: String?
    /// Retain failed update causes as owed callback evidence.
    var failure: String?
}

/// Keep callback secrets durable in Keychain so accepted callbacks survive this process.
struct AgentContactPushConfig: Codable, Sendable {
    struct Authentication: Codable, Sendable { let scheme: String; let credentials: String? }
    let id: String
    let taskId: String
    let url: String
    let token: String?
    let authentication: Authentication?
    let generation = UUID()
    private enum CodingKeys: String, CodingKey { case id, taskId, url, token, authentication }

    static func parse(_ value: JSONValue, taskID: String) async throws -> Self {
        guard let object = value.foundationObject as? [String: Any],
              let rawURL = object["url"] as? String, rawURL.utf8.count <= 4096,
              object["taskId"] == nil || object["taskId"] as? String == "" || object["taskId"] as? String == taskID else { throw invalid }
        let identifier: String
        if let raw = object["id"] {
            guard let text = raw as? String, !text.isEmpty, text.utf8.count <= 128,
                  text.unicodeScalars.allSatisfy({ CharacterSet.alphanumerics.contains($0) || "-_.".unicodeScalars.contains($0) }) else { throw invalid }
            identifier = text
        } else { identifier = UUID().uuidString.lowercased() }
        let token = object["token"] as? String
        if object["token"] != nil, token == nil { throw invalid }
        guard token.map({ safeHeader($0) && $0.utf8.count <= 4096 }) ?? true else { throw invalid }
        var authentication: Authentication?
        if let raw = object["authentication"] {
            guard let auth = raw as? [String: Any], let scheme = auth["scheme"] as? String,
                  !scheme.isEmpty, scheme.utf8.count <= 64,
                  scheme.utf8.allSatisfy({ (65...90).contains($0) || (97...122).contains($0) || (48...57).contains($0) || $0 == 45 }),
                  auth["credentials"] == nil || auth["credentials"] is String else { throw invalid }
            let credentials = auth["credentials"] as? String
            guard credentials.map({ safeHeader($0) && $0.utf8.count <= 4096 }) ?? true else { throw invalid }
            authentication = Authentication(scheme: scheme, credentials: credentials)
        }
        _ = try await destination(rawURL)
        return Self(id: identifier, taskId: taskID, url: rawURL, token: token, authentication: authentication)
    }
    var value: JSONValue { get throws { try JSONValue.fromEncodable(self) } }

    private struct Secret: Codable { let url: String; let token: String?; let scheme: String?; let credentials: String? }
    var account: String { "a2a-push:" + taskId + ":" + id }
    var callback: AgentContactCallback { .init(account: account) }

    /// Keep the whole callback (URL and credentials) before it is acknowledged.
    func keep() throws {
        try AgentPeerCredentials.writeSecret(JSONEncoder().encode(Secret(url: url, token: token,
            scheme: authentication?.scheme, credentials: authentication?.credentials)), account: account)
    }

    /// Relaunch resolves callbacks from their existing Keychain accounts.
    static func restored(_ callback: AgentContactCallback, id: String, taskId: String) throws -> Self {
        guard let data = try AgentPeerCredentials.readSecret(account: callback.account) else {
            throw AgentContactFailure(code: -32603, message: "The callback's Keychain destination is missing.")
        }
        let secret = try JSONDecoder().decode(Secret.self, from: data)
        return Self(id: id, taskId: taskId, url: secret.url, token: secret.token,
                    authentication: secret.scheme.map { Authentication(scheme: $0, credentials: secret.credentials) })
    }
    static var invalid: AgentContactFailure { .init(code: -32602, message: "Invalid or unsafe push notification configuration") }
    private static func safeHeader(_ value: String) -> Bool { value.unicodeScalars.allSatisfy { $0.value >= 32 && $0.value != 127 } }

    /// Resolve once, reject the entire answer set if any address is unsafe, and pin the selected address for the connection (including HTTPS SNI/verification).
    typealias Destination = (host: String, port: Int, address: String)

    static func destination(_ raw: String) async throws -> Destination {
        let resolution = ContinuationOnce<Result<Destination, Error>>()
        // DNS owns this wait; silence cannot classify a destination as unsafe.
        DispatchQueue.global(qos: .utility).async {
            resolution.resume(Result { try resolveDestination(raw) })
        }
        return try await withTaskCancellationHandler {
            try await resolution.wait().get()
        } onCancel: { resolution.resume(.failure(CancellationError())) }
    }

    private static func resolveDestination(_ raw: String) throws -> Destination {
        guard safeHeader(raw), !raw.contains(" "), let url = URL(string: raw), let host0 = url.host, !host0.isEmpty,
              url.user == nil, url.password == nil, url.fragment == nil,
              url.scheme == "https" || url.scheme == "http" else { throw invalid }
        let host = host0.trimmingCharacters(in: CharacterSet(charactersIn: "[]")).lowercased()
        let port = url.port ?? (url.scheme == "https" ? 443 : 80)
        guard !host.contains("%"), !host.contains("\n"), !host.contains("\r"),
              (1...65535).contains(port) else { throw invalid }
        var hints = addrinfo()
        hints.ai_family = AF_UNSPEC; hints.ai_socktype = SOCK_STREAM; hints.ai_flags = AI_ADDRCONFIG
        var head: UnsafeMutablePointer<addrinfo>?
        let resolved = getaddrinfo(host, nil, &hints, &head)
        guard resolved == 0 else {
            let cause = gai_strerror(resolved).map { String(cString: $0) } ?? "resolver code \(resolved)"
            throw AgentContactFailure(code: -32603,
                message: "Callback DNS for \(host) failed: \(cause). Repair that destination's DNS before delivering its owed update.")
        }
        guard let first = head else {
            throw AgentContactFailure(code: -32603,
                message: "Callback DNS for \(host) returned no address. Configure a resolvable destination before delivering its owed update.")
        }
        defer { freeaddrinfo(first) }
        var addresses: [String] = []
        var pointer: UnsafeMutablePointer<addrinfo>? = first
        while let current = pointer {
            let info = current.pointee
            var buffer = [CChar](repeating: 0, count: Int(NI_MAXHOST))
            let named = getnameinfo(info.ai_addr, info.ai_addrlen, &buffer, socklen_t(buffer.count), nil, 0, NI_NUMERICHOST)
            guard named == 0 else {
                let cause = gai_strerror(named).map { String(cString: $0) } ?? "resolver code \(named)"
                throw AgentContactFailure(code: -32603,
                    message: "Callback address for \(host) could not be read: \(cause). Repair its DNS address before delivering the owed update.")
            }
            let address = String(cString: buffer)
            guard allowed(address, allowHTTP: url.scheme == "http") else { throw invalid }
            addresses.append(address)
            pointer = info.ai_next
        }
        guard let address = addresses.first else { throw invalid }
        return (host, port, address)
    }

    static func allowed(_ address: String, allowHTTP: Bool) -> Bool {
        var ipv4 = in_addr()
        if inet_pton(AF_INET, address, &ipv4) == 1 {
            let n = UInt32(bigEndian: ipv4.s_addr)
            if n >> 24 == 127 { return true }
            if allowHTTP { return false }
            // Public unicast only; in particular reject metadata, LAN, CGNAT, link-local, multicast and unspecified addresses.
            return n != 0xA83F8110 && n >> 24 != 0 && n >> 24 != 10 && n >> 16 != 0xA9FE && n >> 16 != 0xC0A8 &&
                n >> 20 != 0xAC1 && n >> 22 != 0x191 && n >> 17 != 0x6309 && n >> 28 < 14 &&
                n >> 8 != 0xC00000 && n >> 8 != 0xC00002 && n >> 8 != 0xC63364 && n >> 8 != 0xCB0071
        }
        var ipv6 = in6_addr()
        guard inet_pton(AF_INET6, address, &ipv6) == 1 else { return false }
        let bytes = withUnsafeBytes(of: &ipv6) { Array($0) }
        if bytes.dropLast().allSatisfy({ $0 == 0 }) && bytes.last == 1 { return true }
        // Only global IPv6 unicast. This also excludes mapped IPv4, ULA, link-local, multicast, unspecified and well-known NAT64 addresses.
        var prefix = bytes.makeIterator()
        guard !allowHTTP, let first = prefix.next(), let second = prefix.next(), let third = prefix.next(), let fourth = prefix.next(),
              first & 0xE0 == 0x20 else { return false }
        // Reject transition mechanisms that can tunnel to private IPv4.
        if first == 0x20 && second == 0x02 { return false }
        if first == 0x20 && second == 0x01 && third == 0 && fourth == 0 { return false }
        return true
    }

    /// Pin DNS with --resolve while preserving hostname TLS checks. Exclude shell, user curlrc, proxies, redirects, credential argv and response bodies from
    /// callback transport.
    func deliver(_ payload: Data) async throws {
        try Task.checkCancellation()
        let target = try await Self.destination(url)
        try Task.checkCancellation()
        func quoted(_ value: String) -> String {
            "\"" + value.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "\"", with: "\\\"")
                .replacingOccurrences(of: "\n", with: "\\n").replacingOccurrences(of: "\r", with: "\\r").replacingOccurrences(of: "\t", with: "\\t") + "\""
        }
        let ip = target.address.contains(":") ? "[\(target.address)]" : target.address
        var config = "url = \(quoted(url))\n"
        // A literal IPv6 URL already fixes the network destination.
        if !target.host.contains(":") {
            config += "resolve = \(quoted("\(target.host):\(target.port):\(ip)"))\n"
        }
        config += "header = \(quoted("Content-Type: application/a2a+json"))\n"
        if let authentication {
            let header = authentication.scheme + (authentication.credentials.map { " " + $0 } ?? "")
            config += "header = \(quoted("Authorization: " + header))\n"
        }
        if let token { config += "header = \(quoted("X-A2A-Notification-Token: " + token))\n" }
        config += "data-binary = \(quoted(String(decoding: payload, as: UTF8.self)))\n"
        let result = try await ProcessExecution().run(executable: "/usr/bin/curl",
            arguments: ["-q", "--globoff", "--config", "-", "--silent", "--noproxy", "*", "--proto", "=http,https", "--max-redirs", "0",
                "--max-filesize", "1024", "--output", "/dev/null", "--write-out", "%{http_code}"],
            currentDirectory: nil, environment: ["PATH": "/usr/bin:/bin"],
            standardInput: Data(config.utf8), timeoutSeconds: nil, outputByteLimit: 1024)
        guard result.exitCode == 0 else {
            throw AgentContactFailure(code: -32603,
                message: "Callback transport exited \(result.exitCode): \(result.stderr). "
                    + "Acceptance is unknown; inspect the receiver before another delivery.")
        }
        guard let status = Int(result.stdout), (200..<300).contains(status) else {
            throw AgentContactFailure(code: -32603,
                message: "Callback returned HTTP \(result.stdout). Repair the receiver before requesting another delivery.")
        }
    }
}
