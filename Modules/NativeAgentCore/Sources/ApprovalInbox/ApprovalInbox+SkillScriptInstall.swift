import Foundation
import NativeAgentCore
import PersistenceCore

// Blueprint: | `ApprovalInbox+SkillScriptInstall.swift` | `SwiftNativeApprovalInbox.askUserToInstallScript`; Exact-digest reviews. |

/// Approval admits only the reviewed script digest through the Skills install owner; denial leaves it drafted.
extension SwiftNativeApprovalInbox {
    public static let skillScriptInstallAction = "skill.script_install"
    public static let skillScriptPreviewLimit = 300_000

    /// These decisions admit code as the owner's. Every deciding surface must show the saved review; a shortened notification cannot offer approval.
    public nonisolated static func requiresExecutableReview(action: String) -> Bool {
        action == skillScriptInstallAction
    }

    @discardableResult
    public func askUserToInstallScript(
        skill: String, skillID: String, digest: String, why: String, script: String,
        turn: Turn?, handsBack: Bool = false
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
        ]), turn: turn, handsBack: handsBack) { payload in
            guard case .object(let bound) = payload else { return false }
            return bound["skill"] == .string(skillID) && bound["digest"] == .string(digest)
        }.record
    }

    public static func skillScriptInstallBinding(_ record: ApprovalRecord) -> (skill: String, digest: String)? {
        guard record.action == skillScriptInstallAction, case .object(let bound) = record.payload,
              case .string(let skill)? = bound["skill"], case .string(let digest)? = bound["digest"],
              !skill.isEmpty, !digest.isEmpty else { return nil }
        return (skill, digest)
    }
}

extension ApprovalRecord {
    public var requiresExecutableReview: Bool {
        SwiftNativeApprovalInbox.requiresExecutableReview(action: action)
    }
}
