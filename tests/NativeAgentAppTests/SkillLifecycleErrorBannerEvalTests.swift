import Testing
@testable import NativeAgentApp

@Suite("app.settings · Skill Lifecycle feedback", .serialized)
struct SkillLifecycleErrorBannerEvalTests {
    @Test @MainActor
    func identicalFailureAfterDismissRaisesANewVisibleBannerEvent() {
        let app = AppModel(startBackgroundTasks: false)
        let failure = "Skill catalog unavailable: manifest registry: unreadable"

        // This is the same AppModel receipt path used after each failed skill
        // catalog load. Equal strings must not share an event identity.
        app.recordSkillManifestFailure(failure)
        let first = app.skillLifecycleFeedback
        #expect(first?.kind == .failure)
        #expect(first?.message == failure)
        #expect(app.skillManifestError == failure)

        app.dismissSkillManifestFeedback()
        #expect(app.skillLifecycleFeedback == nil)
        #expect(app.skillManifestError == nil)

        app.recordSkillManifestFailure(failure)
        let second = app.skillLifecycleFeedback
        #expect(second?.kind == .failure)
        #expect(second?.message == failure)
        #expect(second?.id != first?.id)
        #expect(app.skillManifestError == failure)
    }

    @Test @MainActor
    func aNewFailureSupersedesSuccessToastAndOldDismissCannotEraseIt() {
        let app = AppModel(startBackgroundTasks: false)
        app.recordSkillManifestSuccess("‘Writer’ is now active.")
        guard let successID = app.skillLifecycleFeedback?.id else {
            Issue.record("success did not create a toast event")
            return
        }
        #expect(app.skillLifecycleFeedback?.kind == .success)

        app.recordSkillManifestFailure("Enable failed: registry unavailable")
        #expect(app.skillLifecycleFeedback?.kind == .failure)
        #expect(app.skillManifestError == "Enable failed: registry unavailable")

        // The delayed three-second success-toast cleanup is keyed to the
        // original event. It cannot clear a newer failure banner.
        app.dismissSkillManifestSuccess(id: successID)
        #expect(app.skillLifecycleFeedback?.kind == .failure)
    }
}
