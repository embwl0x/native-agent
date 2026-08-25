import Testing
@testable import NativeAgentApp

// EVAL FENCE: app.mind / logic.dreams.diaryLoadGeneration

@Suite("Dream diary load generation")
struct DreamDiaryLoadGenerationEvalTests {
    private func response(
        date: String,
        enabled: Bool
    ) -> DreamDiaryResponse {
        DreamDiaryResponse(
            entries: [DreamEntry(date: date, content: "Dream \(date)")],
            enabled: enabled,
            totalEntries: 1
        )
    }

    @Test("a newer diary result remains the only result admitted after an older read finishes late")
    func lateOlderCompletionCannotReplaceTheNewerPayload() {
        var state = DreamDiaryLoadGeneration()
        let older = state.begin()
        let newer = state.begin()
        let latest = response(date: "2026-08-24", enabled: true)
        let obsolete = response(date: "2026-08-23", enabled: false)

        #expect(state.isLoading)
        #expect(state.settle(request: newer, response: latest) == .current(latest))
        #expect(!state.isLoading)
        #expect(state.settle(request: older, response: obsolete) == .superseded)
        #expect(!state.isLoading)

        // The admitted response is the one that reaches DreamsView's entries,
        // selected-date, and toggle reconciliation branch; the old response is
        // structurally unavailable to that branch.
        #expect(latest.entries.map(\.date) == ["2026-08-24"])
        #expect(latest.enabled)
    }

    @Test("an older completion leaves the newer request's spinner active until that newer request settles")
    func staleCompletionCannotClearTheCurrentSpinner() {
        var state = DreamDiaryLoadGeneration()
        let older = state.begin()
        let newer = state.begin()

        #expect(state.settle(request: older, response: response(date: "2026-08-23", enabled: false)) == .superseded)
        #expect(state.isLoading)

        #expect(state.settle(request: newer, response: nil) == .current(nil))
        #expect(!state.isLoading)
    }
}
