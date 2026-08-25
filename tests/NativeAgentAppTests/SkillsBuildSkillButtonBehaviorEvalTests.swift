import Foundation
import Testing
@testable import NativeAgentApp

// EVAL FENCE: app.settings / ui.Skills.buildSkillButton

private final class SkillBuildRequestCapture: @unchecked Sendable {
    var starter: String?
}

@MainActor
@Suite("app.settings · Skills build-skill button", .serialized)
struct SkillsBuildSkillButtonBehaviorEvalTests {
    @Test("header and empty-state action owner prepares the canonical chat starter")
    func buildButtonUsesTheRealComposerDraftOwner() {
        let app = AppModel(dataRootOverride: FileManager.default.temporaryDirectory, startBackgroundTasks: false)
        app.activeChatSessionId = "skills-build-session"

        let outcome = SkillBuildButtonPresentation.beginBuild(using: app)

        #expect(outcome == .draftPrepared)
        #expect(app.chatDraft(for: "skills-build-session") == SkillBuildButtonPresentation.starter)
        #expect(SkillBuildButtonPresentation.starter.hasSuffix(" "))
    }

    @Test("an existing composer draft is retained rather than silently replaced")
    func buildButtonPreservesTheUserDraft() {
        let app = AppModel(dataRootOverride: FileManager.default.temporaryDirectory, startBackgroundTasks: false)
        app.activeChatSessionId = "skills-existing-draft"
        app.injectChatDraft("Keep this unfinished request", sessionId: app.activeChatSessionId)

        let outcome = SkillBuildButtonPresentation.beginBuild(using: app)

        #expect(outcome == .existingDraftPreserved)
        #expect(app.chatDraft(for: app.activeChatSessionId) == "Keep this unfinished request")
    }

    @Test("without a session the button requests Chat recovery but never claims a prepared draft")
    func missingSessionRemainsAnExplicitPendingHandoff() {
        let app = AppModel(dataRootOverride: FileManager.default.temporaryDirectory, startBackgroundTasks: false)
        app.activeChatSessionId = ""
        let capture = SkillBuildRequestCapture()
        let observer = NotificationCenter.default.addObserver(
            forName: .skillBuildRequest,
            object: nil,
            queue: nil
        ) { note in
            capture.starter = note.object as? String
        }
        defer { NotificationCenter.default.removeObserver(observer) }

        let outcome = SkillBuildButtonPresentation.beginBuild(using: app)

        #expect(outcome == .awaitingChatSession)
        #expect(app.chatDrafts.isEmpty)
        #expect(capture.starter == SkillBuildButtonPresentation.starter)
    }
}
