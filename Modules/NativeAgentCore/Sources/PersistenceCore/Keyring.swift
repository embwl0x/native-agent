import Foundation
// Blueprint: | `Keyring.swift` | `Keyring` enum: the one keyring's storage — a secret by them name in one Keychain service with the hosts and programs the person granted it for, its renewal and when it was granted; `kept`, every entry by name; `{{secret:<name>}}` names; a program grant is the executable's path and code identity; no network |

/// The one keyring (docs/AGENT_IS_THE_APP.md, "Reach"): where every secret
/// her abilities reach with is kept, under the name she gave it, in this
/// Mac's Keychain under one service, with where the person granted it to go.
/// Storage and names only: granting, signing in and renewing belong to
/// ProviderRouting's OAuth owner, inserting and redacting to the broker.
public enum Keyring {
    static let service = "NativeAgent.keyring"
    private static let placeholder = try! NSRegularExpression(pattern: "\\{\\{secret:([^{}]*)\\}\\}")
    private static let lock = NSLock()

    /// A signed-in secret's value expires; its token endpoint renews it, the
    /// client authenticating as it did at sign-in (`clientAuth` "basic" for
    /// HTTP Basic, else in the body).
    public struct Renewal: Codable, Sendable, Equatable {
        public var token: String
        public var clientID: String
        public var clientSecret: String?
        public var clientAuth: String?
        public var refreshToken: String
        public var expires: Date
        public init(token: String, clientID: String, clientSecret: String?, clientAuth: String?, refreshToken: String, expires: Date) {
            self.token = token; self.clientID = clientID; self.clientSecret = clientSecret; self.clientAuth = clientAuth
            self.refreshToken = refreshToken; self.expires = expires
        }
    }

    /// A program a secret may be handed to: the executable's path and its
    /// code identity when the person granted it.
    public struct Program: Codable, Sendable, Hashable {
        public var path: String
        public var identity: String
        public init(path: String, identity: String) { self.path = path; self.identity = identity }
    }

    /// One kept secret: the value, the hosts it may be carried to, the
    /// programs it may be handed to, its renewal, when it was granted, and
    /// the account a sign-in granted it for (not secret: she may read it).
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

    /// A host as a grant keeps it and a destination is checked against it:
    /// a DNS name lowercased, or an IPv6 literal (brackets optional) in its
    /// one short form; nil for anything else, a scoped literal (`%en0`)
    /// included: the system folds its interface into the address.
    public static func host(_ text: String) -> String? {
        let text = text.lowercased()
        let bare = text.hasPrefix("[") && text.hasSuffix("]") ? String(text.dropFirst().dropLast()) : text
        var v6 = in6_addr(), out = [CChar](repeating: 0, count: Int(INET6_ADDRSTRLEN))
        if !bare.contains("%"), inet_pton(AF_INET6, bare, &v6) == 1 { return inet_ntop(AF_INET6, &v6, &out, socklen_t(out.count)).map { String(cString: $0) } }
        return text.range(of: "^[a-z0-9]([a-z0-9-]*[a-z0-9])?(\\.[a-z0-9]([a-z0-9-]*[a-z0-9])?)*$", options: .regularExpression) != nil ? text : nil
    }

    /// Every name a value's strings write as `{{secret:<name>}}`, in order.
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

    /// Every kept secret by name: what the Connectors page lists.
    public static func kept() throws -> [(name: String, entry: Entry)] {
        try DeviceSecretKeychain.accounts(service: service).sorted().compactMap { name in try entry(name).map { (name, $0) } }
    }

    public static func save(_ name: String, _ entry: Entry) throws {
        let data = try JSONEncoder().encode(entry)
        try lock.withLock {
            if try DeviceSecretKeychain.read(service: service, account: name) == nil {
                try DeviceSecretKeychain.insert(data, service: service, account: name)
            } else { try DeviceSecretKeychain.replace(data, service: service, account: name) }
        }
        changed()
    }

    public static func remove(_ name: String) throws {
        try lock.withLock { try DeviceSecretKeychain.delete(service: service, account: name) }
        changed()
    }

    /// Every open list of the keyring rereads it, whichever window granted, renewed or removed.
    private static func changed() {
        StoreChangeBus.shared.emit(StoreChange(store: .keyring, path: URL(string: "keychain:" + service)!))
    }
}
