import Darwin
import Foundation
import PersistenceCore

/// P2 launches the helper with /usr/bin/sandbox-exec -p <profile>. The app
/// supplies source and material over the plug; only compiler scratch is writable.
public enum SenseSandboxProfile {
    /// The app's byte delivery obeys the same exclusions as helper reach.
    public static func requirePublicPath(_ path: String, dataRoot: URL, personaRoot: URL) throws {
        let candidate = URL(fileURLWithPath: (path as NSString).expandingTildeInPath)
            .standardizedFileURL.resolvingSymlinksInPath().path
        let home = FileManager.default.homeDirectoryForCurrentUser
        func under(_ root: URL) -> Bool {
            let root = root.standardizedFileURL.resolvingSymlinksInPath().path
            return candidate == root || candidate.hasPrefix(root + "/")
        }
        // The person's workspace is their own files, even though a public
        // install keeps it inside the data root (NativeAgentWorkspaceRoot).
        if under(NativeAgentWorkspaceRoot.resolve(dataRoot: dataRoot)) { return }
        let roots = [dataRoot, personaRoot] + [".ssh", ".aws", ".gnupg", ".codex", "Library/Keychains"].map { home.appendingPathComponent($0) }
        guard !roots.contains(where: under) else {
            throw SenseFailure(code: "source_denied", message: "Sense material cannot come from private app stores, persona or credentials.")
        }
    }

    public static func build(reach: SenseReach, helperURL: URL, scratch: URL,
                             dataRoot: URL, personaRoot: URL,
                             language: SenseLanguage = .javascript) throws -> String {
        func quote(_ path: String) -> String {
            "\"" + path.replacingOccurrences(of: "\\", with: "\\\\")
                .replacingOccurrences(of: "\"", with: "\\\"") + "\""
        }
        func path(_ url: URL) -> String {
            quote(url.standardizedFileURL.resolvingSymlinksInPath().path)
        }
        guard scratch.isFileURL, dataRoot.isFileURL, personaRoot.isFileURL, helperURL.isFileURL,
              scratch.standardizedFileURL.path != "/" else {
            throw SenseFailure(code: "bad_reach", message: "Sense sandbox requires local roots and a private scratch folder.")
        }
        let scratchPath = scratch.standardizedFileURL.resolvingSymlinksInPath().path
        let scratchAttributes = try FileManager.default.attributesOfItem(atPath: scratchPath)
        guard scratchAttributes[.type] as? FileAttributeType == .typeDirectory,
              (scratchAttributes[.posixPermissions] as? NSNumber)?.intValue == 0o700,
              (scratchAttributes[.ownerAccountID] as? NSNumber)?.uint32Value == geteuid(),
              ![dataRoot, personaRoot].contains(where: {
                  let root = $0.standardizedFileURL.resolvingSymlinksInPath().path
                  return scratchPath == root || scratchPath.hasPrefix(root + "/")
              }) else {
            throw SenseFailure(code: "bad_reach", message: "Sense scratch must be an owned 0700 directory outside data and persona roots.")
        }
        var rules = [
            "(version 1)", "(deny default)",
            "(allow process-info* (target self) (target children))",
            "(allow sysctl-read)",
            "(allow signal (target self) (target children))",
            "(allow file-read-metadata)",
            "(allow file-read-data (literal \"/\") (subpath \"/System\") (subpath \"/private/var/db/timezone\") (subpath \"/usr/lib\") (literal \"/dev/null\") (literal \"/dev/random\") (literal \"/dev/urandom\") (literal \(path(helperURL))) (literal \(path(helperURL.deletingLastPathComponent().deletingLastPathComponent().appendingPathComponent("Resources/Senses/sense.js")))))",
            "(allow file-write-data (literal \"/dev/null\"))",
            "(allow file-read-data file-write-data (literal \"/dev/stdin\") (literal \"/dev/stdout\") (literal \"/dev/stderr\") (subpath \"/dev/fd\"))",
            "(allow process-exec (literal \(path(helperURL))))",
            "(allow file-map-executable (subpath \"/System\") (subpath \"/usr/lib\") (literal \(path(helperURL))))",
        ]
        for readPath in reach.readPaths {
            guard readPath.hasPrefix("/"), !readPath.contains("\u{0}"), !readPath.contains("\n") else {
                throw SenseFailure(code: "bad_reach", message: "Sense read reach must contain absolute paths.")
            }
            rules.append("(allow file-read-data (subpath \(path(URL(fileURLWithPath: readPath)))))")
        }
        // Resolve before launch: Seatbelt fences exact IPs, never all outbound
        // traffic for a DNS declaration. DNS changes require a fresh profile.
        for host in reach.hosts {
            guard !host.isEmpty, host.utf8.count <= 253,
                  host.unicodeScalars.allSatisfy({ CharacterSet(charactersIn: "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789.-:").contains($0) }) else {
                throw SenseFailure(code: "bad_reach", message: "Sense network reach requires exact hosts without wildcards, ports or URLs.")
            }
            var hints = addrinfo()
            hints.ai_family = AF_UNSPEC; hints.ai_socktype = SOCK_STREAM
            var result: UnsafeMutablePointer<addrinfo>?
            guard getaddrinfo(host, nil, &hints, &result) == 0, let first = result else {
                throw SenseFailure(code: "bad_reach", message: "Sense network host could not be resolved: \(host).")
            }
            defer { freeaddrinfo(first) }
            var cursor: UnsafeMutablePointer<addrinfo>? = first
            var addresses = Set<String>()
            while let info = cursor {
                var numeric = [CChar](repeating: 0, count: Int(NI_MAXHOST))
                if getnameinfo(info.pointee.ai_addr, info.pointee.ai_addrlen, &numeric, socklen_t(numeric.count), nil, 0, NI_NUMERICHOST) == 0 {
                    addresses.insert(String(decoding: numeric.prefix { $0 != 0 }.map { UInt8(bitPattern: $0) }, as: UTF8.self))
                }
                cursor = info.pointee.ai_next
            }
            guard !addresses.isEmpty else { throw SenseFailure(code: "bad_reach", message: "Sense network host has no IP addresses.") }
            for address in addresses.sorted() {
                rules.append("(allow network-outbound (remote ip \(quote(address.contains(":") ? "[\(address)]:*" : "\(address):*"))))")
            }
        }
        if !reach.hosts.isEmpty {
            rules.append("(allow mach-lookup (global-name \"com.apple.mDNSResponder\") (global-name \"com.apple.system.opendirectoryd.libinfo\") (global-name \"com.apple.trustd\") (global-name \"com.apple.trustd.agent\"))")
        }
        if language == .swift {
            rules += [
                "(allow process-fork)",
                "(allow file-read-data (subpath \"/usr\") (subpath \"/Library/Developer\") (subpath \"/Applications/Xcode.app\") (subpath \(path(scratch))))",
                "(allow file-write* (subpath \(path(scratch))))",
                "(allow process-exec (literal \"/usr/bin/swift\") (literal \"/usr/bin/xcrun\") (subpath \"/Library/Developer\") (subpath \"/Applications/Xcode.app\"))",
                "(allow file-map-executable (subpath \"/usr\") (subpath \"/Library/Developer\") (subpath \"/Applications/Xcode.app\") (subpath \(path(scratch))))",
                "(allow mach-lookup (global-name \"com.apple.xcode.Selector\"))",
            ]
        }
        // These denies win even over a declared '/' read grant. The resolved
        // persona root may live outside dataRoot in development installations.
        // Deny the whole app store, including the notebook:
        // all legitimate access to it is app-side through the plug.
        rules.append("(deny file-read* file-write* (subpath \(path(dataRoot))))")
        rules.append("(deny file-read* file-write* (subpath \(path(personaRoot))))")
        let home = FileManager.default.homeDirectoryForCurrentUser
        for store in [".ssh", ".aws", ".gnupg", ".codex", "Library/Keychains"] {
            rules.append("(deny file-read* file-write* (subpath \(path(home.appendingPathComponent(store)))))")
        }
        return rules.joined(separator: "\n")
    }
}
