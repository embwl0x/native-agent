import Darwin
import Foundation
import PersistenceCore
// Blueprint: | `Modules/NativeAgentCore/Sources/Senses/SenseSandboxProfile.swift` | Deny-default Seatbelt reach, shared private-root policy (workspace allowed only through app delivery), and exact-IP network fence |

/// P2 launches the helper with /usr/bin/sandbox-exec -p <profile>. The app
/// supplies source and material over the plug; source arrives over the supervised plug.
public enum SenseSandboxProfile {
    private static func exclusions(dataRoot: URL, personaRoot: URL) -> (roots: [URL], deliveryWorkspace: URL) {
        ([dataRoot, personaRoot] + [".ssh", ".aws", ".gnupg", ".codex", "Library/Keychains"]
            .map { FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent($0) }, NativeAgentWorkspaceRoot.resolve(dataRoot: dataRoot))
    }

    /// Delivery excludes private roots, except the workspace; the helper's
    /// direct filesystem reach excludes those roots including the workspace.
    public static func requirePublicPath(_ path: String, dataRoot: URL, personaRoot: URL) throws {
        let candidate = URL(fileURLWithPath: (path as NSString).expandingTildeInPath)
            .standardizedFileURL.resolvingSymlinksInPath().path
        func under(_ root: URL) -> Bool {
            let root = root.standardizedFileURL.resolvingSymlinksInPath().path
            return NativeAgentWorkspaceRoot.relativePath(candidate, under: root) != nil
        }
        let policy = exclusions(dataRoot: dataRoot, personaRoot: personaRoot)
        if under(policy.deliveryWorkspace) { return }
        guard !policy.roots.contains(where: under) else {
            throw SenseFailure(code: "source_denied", message: "Sense material cannot come from private app stores, persona or credentials.")
        }
    }

    public static func build(reach: SenseReach, helperURL: URL, scratch: URL,
                             dataRoot: URL, personaRoot: URL) throws -> String {
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
                  return NativeAgentWorkspaceRoot.relativePath(scratchPath, under: root) != nil
              }) else {
            throw SenseFailure(code: "bad_reach", message: "Sense scratch must be an owned 0700 directory outside data and persona roots.")
        }
        var rules = [
            "(version 1)", "(deny default)",
            "(allow process-info* (target self) (target children))",
            "(allow sysctl-read)",
            "(allow signal (target self) (target children))",
            "(allow file-read-metadata)",
            "(allow file-read-data (literal \"/\") (subpath \"/System\") (subpath \"/private/var/db/timezone\") (subpath \"/usr/share/icu\") (subpath \"/usr/lib\") (literal \"/dev/null\") (literal \"/dev/random\") (literal \"/dev/urandom\") (literal \(path(helperURL))) (literal \(path(helperURL.deletingLastPathComponent().deletingLastPathComponent().appendingPathComponent("Resources/Senses/sense.js")))))",
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
        // These denies win over '/' reach, including the in-data-root workspace;
        // its legitimate access is app-side delivery, never helper file access.
        for root in exclusions(dataRoot: dataRoot, personaRoot: personaRoot).roots {
            rules.append("(deny file-read* file-write* (subpath \(path(root))))")
        }
        return rules.joined(separator: "\n")
    }
}
