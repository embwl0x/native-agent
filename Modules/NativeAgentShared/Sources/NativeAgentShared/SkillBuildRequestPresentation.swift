import Foundation
// Blueprint: | `SkillBuildRequestPresentation.swift` | `SkillBuildRequestPresentation`: typed outcome of a Build-a-skill request, shared by the app and the face |

/// Typed outcomes keep a missing session or preserved draft from being called a successful build.
public enum SkillBuildRequestPresentation {
    public enum DraftOutcome: Equatable, Sendable {
        case draftPrepared
        case existingDraftPreserved
        case awaitingChatSession
    }

    public static func build(activeSessionID: String, existingDraft: String) -> DraftOutcome {
        guard !activeSessionID.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            return .awaitingChatSession
        }
        return existingDraft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            ? .draftPrepared
            : .existingDraftPreserved
    }
}
