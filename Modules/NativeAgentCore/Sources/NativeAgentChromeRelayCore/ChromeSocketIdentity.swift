import Darwin
import Foundation
import Security

public enum ChromeSocketIdentity {
    // 2026-09-06: inherit the running, signed caller's designated signer constraint,
    // never a requirement read from the peer's replaceable executable on disk.
    // App and nested relay have different identifiers but share that signer.
    private static func requireSuccess(_ status: OSStatus, _ check: String) throws {
        guard status == errSecSuccess else { throw ChromeHostIdentity.SigningFailure(check: check, status: status) }
    }

    private static func requirement(identifier: String) throws -> SecRequirement {
        guard identifier.range(of: #"^[A-Za-z0-9._-]+$"#, options: .regularExpression) != nil
        else { throw ChromeHostIdentity.SigningFailure(check: "socket peer identifier", status: errSecParam) }
        var ownCode: SecCode?
        var ownStaticCode: SecStaticCode?
        var ownRequirement: SecRequirement?
        var text: CFString?
        try requireSuccess(SecCodeCopySelf([], &ownCode), "SecCodeCopySelf (socket signer)")
        guard let ownCode else { throw ChromeHostIdentity.SigningFailure(check: "socket signer code", status: errSecCSNoSuchCode) }
        try requireSuccess(SecCodeCheckValidity(ownCode, [], nil), "SecCodeCheckValidity (socket signer)")
        try requireSuccess(SecCodeCopyStaticCode(ownCode, [], &ownStaticCode), "SecCodeCopyStaticCode (socket signer)")
        guard let ownStaticCode else { throw ChromeHostIdentity.SigningFailure(check: "socket signer static code", status: errSecCSNoSuchCode) }
        try requireSuccess(SecCodeCopyDesignatedRequirement(ownStaticCode, [], &ownRequirement), "SecCodeCopyDesignatedRequirement (socket signer)")
        guard let ownRequirement else { throw ChromeHostIdentity.SigningFailure(check: "socket signer requirement", status: errSecCSReqFailed) }
        try requireSuccess(SecRequirementCopyString(ownRequirement, [], &text), "SecRequirementCopyString (socket signer)")
        guard let text else { throw ChromeHostIdentity.SigningFailure(check: "socket signer requirement text", status: errSecCSReqFailed) }
        let source = text as String
        // Ad-hoc/unsigned builds have no transferable signer identity: refuse.
        guard source.contains("anchor apple generic"),
              let prefix = source.range(
                of: #"^identifier ("[^"]*"|[A-Za-z0-9._-]+) and "#,
                options: .regularExpression
              ) else { throw ChromeHostIdentity.SigningFailure(check: "socket signer vendor admission", status: errSecCSReqFailed) }
        let pinned = source.replacingCharacters(in: prefix, with: "identifier \"\(identifier)\" and ")
        var requirement: SecRequirement?
        try requireSuccess(SecRequirementCreateWithString(pinned as CFString, [], &requirement), "SecRequirementCreateWithString (socket peer)")
        guard let requirement else { throw ChromeHostIdentity.SigningFailure(check: "socket peer requirement", status: errSecCSReqFailed) }
        return requirement
    }

    // 2026-09-06: the audit token binds validation to the kernel's socket peer,
    // including its PID generation, rather than a path or a reusable PID.
    public static func peerIsTrusted(descriptor: Int32, identifiers: [String]) -> Bool {
        (try? checkTrustedPeer(descriptor: descriptor, identifiers: identifiers)) != nil
    }

    private static func checkTrustedPeer(descriptor: Int32, identifiers: [String]) throws {
        var token = audit_token_t()
        var size = socklen_t(MemoryLayout<audit_token_t>.size)
        let result = getsockopt(descriptor, SOL_LOCAL, LOCAL_PEERTOKEN, &token, &size)
        guard result == 0, size == MemoryLayout<audit_token_t>.size else {
            let code = result == 0 ? EINVAL : errno
            throw NSError(domain: NSPOSIXErrorDomain, code: Int(code), userInfo: [
                NSLocalizedDescriptionKey: "LOCAL_PEERTOKEN failed (errno \(code)).",
                "chrome_check": "LOCAL_PEERTOKEN",
            ])
        }
        let data = withUnsafeBytes(of: token) { Data($0) }
        var peer: SecCode?
        let attributes = [kSecGuestAttributeAudit as String: data] as CFDictionary
        try requireSuccess(SecCodeCopyGuestWithAttributes(nil, attributes, [], &peer), "SecCodeCopyGuestWithAttributes (socket peer audit token)")
        guard let peer else { throw ChromeHostIdentity.SigningFailure(check: "socket peer code", status: errSecCSNoSuchCode) }
        var status = errSecCSReqFailed
        for identifier in identifiers {
            status = SecCodeCheckValidity(peer, [], try requirement(identifier: identifier))
            if status == errSecSuccess { return }
        }
        throw ChromeHostIdentity.SigningFailure(check: "SecCodeCheckValidity (socket peer \(identifiers.joined(separator: ", ")))", status: status)
    }

    public static func peerIsNativeAgent(descriptor: Int32) -> Bool {
        (try? checkNativeAgentPeer(descriptor: descriptor)) != nil
    }

    public static func checkNativeAgentPeer(descriptor: Int32) throws {
        guard let path = ChromeHostIdentity.executablePath(ofProcess: getpid()),
              ChromeHostIdentity.isBundledRelay(executablePath: path) else {
            throw ChromeHostIdentity.SigningFailure(check: "bundled relay identity", status: errSecCSReqFailed)
        }
        let app = URL(fileURLWithPath: path).resolvingSymlinksInPath()
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        guard let identifier = Bundle(url: app)?.bundleIdentifier else {
            throw ChromeHostIdentity.SigningFailure(check: "app bundle signing identifier", status: errSecCSReqFailed)
        }
        try checkTrustedPeer(descriptor: descriptor, identifiers: [identifier])
    }
}
