import Foundation
// Blueprint: | `Keyring.swift` | `Keyring`, `kept`, `{{secret:<name>}}`; Secret storage and grant identity only. |

/// Keep named secrets and their granted destinations in one Keychain service; OAuth owns renewal, the broker owns use/redaction.
public enum Keyring {
    static let service = "NativeAgent.keyring"
    private static let placeholder = try! NSRegularExpression(pattern: "\\{\\{secret:([^{}]*)\\}\\}")
    private static let lock = NSLock()

    /// Renewal must authenticate like sign-in: clientAuth basic uses HTTP Basic, otherwise credentials stay in the body.
    public struct Renewal: Codable, Sendable, Equatable {
        public var token: String
        public var clientID: String
        public var clientSecret: String?
        public var clientAuth: String?
        public var refreshToken: String
        /// Nil means the service supplied no expiry; renew before the next use.
        public var expires: Date?
        public init(token: String, clientID: String, clientSecret: String?, clientAuth: String?, refreshToken: String, expires: Date?) {
            self.token = token; self.clientID = clientID; self.clientSecret = clientSecret; self.clientAuth = clientAuth
            self.refreshToken = refreshToken; self.expires = expires
        }
    }

    /// Bind program grants to executable path and code identity at the time of consent.
    public struct Program: Codable, Sendable, Hashable {
        public var path: String
        public var identity: String
        public init(path: String, identity: String) { self.path = path; self.identity = identity }
    }

    /// Account identity is readable metadata; the secret value remains restricted to granted hosts and programs.
    public struct Entry: Codable, Sendable, Equatable {
        public var value: String
        public var hosts: [String]
        public var programs: [Program]
        public var renewal: Renewal?
        public var at: Date
        public var account: String?
        public init(value: String, hosts: [String], programs: [Program], renewal: Renewal?, at: Date, account: String? = nil) {
            self.value = value; self.hosts = hosts; self.programs = programs; self.renewal = renewal; self.at = at; self.account = account
        }
    }

    public static func validName(_ name: String) -> Bool {
        !name.isEmpty && name.count <= 64 && name.unicodeScalars.allSatisfy {
            ("a"..."z").contains($0) || ("0"..."9").contains($0) || "._-".unicodeScalars.contains($0)
        }
    }

    /// Canonicalize hosts for grant comparison; reject scoped IPv6 literals because the system folds interface into address.
    public static func host(_ text: String) -> String? {
        let text = text.lowercased()
        let bare = text.hasPrefix("[") && text.hasSuffix("]") ? String(text.dropFirst().dropLast()) : text
        var v6 = in6_addr(), out = [CChar](repeating: 0, count: Int(INET6_ADDRSTRLEN))
        if !bare.contains("%"), inet_pton(AF_INET6, bare, &v6) == 1 { return inet_ntop(AF_INET6, &v6, &out, socklen_t(out.count)).map { String(cString: $0) } }
        return text.range(of: "^[a-z0-9]([a-z0-9-]*[a-z0-9])?(\\.[a-z0-9]([a-z0-9-]*[a-z0-9])?)*$", options: .regularExpression) != nil ? text : nil
    }

    public static func names(in value: JSONValue) -> [String] {
        var names: [String] = []
        _ = value.mapStrings { text in
            for match in placeholder.matches(in: text, range: NSRange(text.startIndex..., in: text)) {
                if let range = Range(match.range(at: 1), in: text), !names.contains(String(text[range])) {
                    names.append(String(text[range]))
                }
            }
            return text
        }
        return names
    }

    public static func entry(_ name: String) throws -> Entry? {
        guard validName(name), let data = try DeviceSecretKeychain.read(service: service, account: name) else { return nil }
        return try JSONDecoder().decode(Entry.self, from: data)
    }

    public static func kept() throws -> [(name: String, entry: Entry)] {
        try DeviceSecretKeychain.accounts(service: service).sorted().compactMap { name in try entry(name).map { (name, $0) } }
    }

    public static func save(_ name: String, _ entry: Entry) throws {
        let data = try JSONEncoder().encode(entry)
        do {
            try lock.withLock {
                if try DeviceSecretKeychain.read(service: service, account: name) == nil {
                    try DeviceSecretKeychain.insert(data, service: service, account: name)
                } else { try DeviceSecretKeychain.replace(data, service: service, account: name) }
            }
        } catch let error as DeviceSecretKeychain.Failure {
            if case .acceptedButUnverified = error { changed() }
            throw error
        }
        changed()
    }

    public static func remove(_ name: String) throws {
        try lock.withLock { try DeviceSecretKeychain.delete(service: service, account: name) }
        changed()
    }

    /// Reread on every open so grants, renewal and removal from other windows stay visible.
    private static func changed() {
        StoreChangeBus.shared.emit(StoreChange(store: .keyring, path: URL(string: "keychain:" + service)!))
    }
}
