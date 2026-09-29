import Darwin
import Foundation
import Security

public enum ChromeSocketIdentity {
    // 2026-09-06: inherit the running, signed caller's designated signer constraint,
    // never a requirement read from the peer's replaceable executable on disk.
    // App and nested relay have different identifiers but share that signer.
    private static func requirement(identifier: String) -> SecRequirement? {
        guard identifier.range(of: #"^[A-Za-z0-9._-]+$"#, options: .regularExpression) != nil
        else { return nil }
        var ownCode: SecCode?
        var ownStaticCode: SecStaticCode?
        var ownRequirement: SecRequirement?
        var text: CFString?
        guard SecCodeCopySelf([], &ownCode) == errSecSuccess, let ownCode,
              SecCodeCheckValidity(ownCode, [], nil) == errSecSuccess,
              SecCodeCopyStaticCode(ownCode, [], &ownStaticCode) == errSecSuccess,
              let ownStaticCode,
              SecCodeCopyDesignatedRequirement(ownStaticCode, [], &ownRequirement) == errSecSuccess,
              let ownRequirement,
              SecRequirementCopyString(ownRequirement, [], &text) == errSecSuccess,
              let text else { return nil }
        let source = text as String
        // Ad-hoc/unsigned builds have no transferable signer identity: refuse.
        guard source.contains("anchor apple generic"),
              let prefix = source.range(
                of: #"^identifier ("[^"]*"|[A-Za-z0-9._-]+) and "#,
                options: .regularExpression
              ) else { return nil }
        let pinned = source.replacingCharacters(in: prefix, with: "identifier \"\(identifier)\" and ")
        var requirement: SecRequirement?
        guard SecRequirementCreateWithString(pinned as CFString, [], &requirement) == errSecSuccess
        else { return nil }
        return requirement
    }

    // 2026-09-06: the audit token binds validation to the kernel's socket peer,
    // including its PID generation, rather than a path or a reusable PID.
    public static func peerIsTrusted(descriptor: Int32, identifiers: [String]) -> Bool {
        var token = audit_token_t()
        var size = socklen_t(MemoryLayout<audit_token_t>.size)
        guard getsockopt(descriptor, SOL_LOCAL, LOCAL_PEERTOKEN, &token, &size) == 0,
              size == MemoryLayout<audit_token_t>.size else { return false }
        let data = withUnsafeBytes(of: token) { Data($0) }
        var peer: SecCode?
        let attributes = [kSecGuestAttributeAudit as String: data] as CFDictionary
        guard SecCodeCopyGuestWithAttributes(nil, attributes, [], &peer) == errSecSuccess,
              let peer else { return false }
        return identifiers.contains { identifier in
            guard let requirement = requirement(identifier: identifier) else { return false }
            return SecCodeCheckValidity(peer, [], requirement) == errSecSuccess
        }
    }

    public static func peerIsNativeAgent(descriptor: Int32) -> Bool {
        guard let path = ChromeHostIdentity.executablePath(ofProcess: getpid()),
              ChromeHostIdentity.isBundledRelay(executablePath: path) else { return false }
        let app = URL(fileURLWithPath: path).resolvingSymlinksInPath()
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        guard let identifier = Bundle(url: app)?.bundleIdentifier else { return false }
        return peerIsTrusted(descriptor: descriptor, identifiers: [identifier])
    }
}
