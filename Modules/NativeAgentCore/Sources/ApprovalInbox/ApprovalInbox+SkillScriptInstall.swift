import Foundation
import PersistenceCore

// Blueprint: | `ApprovalInbox+SkillScriptInstall.swift` | `SwiftNativeApprovalInbox.askUserToInstallScript`: exact-digest executable review cards and install bindings; every deciding surface must show saved review |

/// User's card for a skill script only he turns on (skills-as-code): approved,
/// from the Mac or his phone, it admits exactly the digest it shows, through
/// the Skills page's own Install; denied, the script stays drafted. One card
/// per script digest, its `lastRequestedAt` stamped when asked again.
extension SwiftNativeApprovalInbox {
    public static let skillScriptInstallAction = "skill.script_install"
    /// The card carries exact source, header and bounded fixtures.
    public static let skillScriptPreviewLimit = 300_000

    /// These decisions admit code as the owner's. Every deciding surface must
    /// show the saved review; a shortened notification cannot offer approval.
    public nonisolated static func requiresExecutableReview(action: String, payload: JSONValue) -> Bool {
        if action == skillScriptInstallAction { return true }
        guard action == "self_improvement.apply", case .object(let fields) = payload,
              case .object(let apply)? = fields["apply"], apply["op"] == .string("enable_skill"),
              case .string? = apply["reviewedDigest"] else { return false }
        return true
    }

    @discardableResult
    public func askUserToInstallScript(
        skill: String, skillID: String, digest: String, why: String, script: String
    ) async throws -> ApprovalRecord {
        guard digest.count == 64, digest.allSatisfy({ $0.isHexDigit && !$0.isUppercase }),
              !script.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw ApprovalInboxError.malformedResponse("an executable approval requires its exact digest and review")
        }
        let short = String(digest.prefix(12))
        return try await createOrTouchPending(.object([
            "title": .string("Install \(skill)'s script?"),
            "action": .string(Self.skillScriptInstallAction),
            "risk": .string("medium"),
            "reason": .string(why + " Approve installs this exact candidate, including code, fixtures and dependencies (digest \(short)); if it changed since, "
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

extension ApprovalRecord {
    public var requiresExecutableReview: Bool {
        SwiftNativeApprovalInbox.requiresExecutableReview(action: action, payload: payload)
    }
}
