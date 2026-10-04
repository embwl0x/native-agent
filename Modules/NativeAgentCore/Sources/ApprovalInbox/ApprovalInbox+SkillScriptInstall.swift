import Foundation
import PersistenceCore

/// User's card for a skill script only he turns on (skills-as-code): approved,
/// from the Mac or his phone, it admits exactly the digest it shows, through
/// the Skills page's own Install; denied, the script stays drafted. One card
/// per script digest, its `lastRequestedAt` stamped when asked again.
extension SwiftNativeApprovalInbox {
    public static let skillScriptInstallAction = "skill.script_install"
    /// The card's preview carries the whole script (8 KB at most) and its
    /// header; one that would not fit is never filed.
    public static let skillScriptPreviewLimit = 12_000

    @discardableResult
    public func askUserToInstallScript(
        skill: String, skillID: String, digest: String, why: String, script: String
    ) async throws -> ApprovalRecord {
        let short = String(digest.prefix(12))
        return try await createOrTouchPending(.object([
            "title": .string("Install \(skill)'s script?"),
            "action": .string(Self.skillScriptInstallAction),
            "risk": .string("medium"),
            "reason": .string(why + " Approve installs this exact script (digest \(short)); if it changed since, "
                + "approving installs nothing. Deny leaves it drafted."),
            "payloadPreview": .string(script),
            "payload": .object(["skill": .string(skillID), "name": .string(skill), "digest": .string(digest)]),
        ])) { payload in
            guard case .object(let bound) = payload else { return false }
            return bound["skill"] == .string(skillID) && bound["digest"] == .string(digest)
        }.record
    }

    /// The skill and exact digest an install card binds, nil when malformed.
    public static func skillScriptInstallBinding(_ record: ApprovalRecord) -> (skill: String, digest: String)? {
        guard record.action == skillScriptInstallAction, case .object(let bound) = record.payload,
              case .string(let skill)? = bound["skill"], case .string(let digest)? = bound["digest"],
              !skill.isEmpty, !digest.isEmpty else { return nil }
        return (skill, digest)
    }
}
