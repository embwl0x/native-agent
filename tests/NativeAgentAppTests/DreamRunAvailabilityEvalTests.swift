import Testing
@testable import NativeAgentApp

// EVAL FENCE: app.mind / ui.dreams.button.runDream

@MainActor
@Suite("Dream run availability", .serialized)
struct DreamRunAvailabilityEvalTests {
    @Test("unreadable, checking, enabled, and disabled diary gates retain distinct action contracts")
    func availabilityNeverDescribesAnUnreadableGateAsDisabled() {
        #expect(DreamRunAvailability.resolve(
            hasReadDiaryGate: false,
            diaryLoadFailed: false,
            dreamEnabledFromDiary: false
        ) == .checking)
        #expect(!DreamRunAvailability.checking.canRun)

        #expect(DreamRunAvailability.resolve(
            hasReadDiaryGate: true,
            diaryLoadFailed: false,
            dreamEnabledFromDiary: true
        ) == .enabled)
        #expect(DreamRunAvailability.enabled.canRun)

        #expect(DreamRunAvailability.resolve(
            hasReadDiaryGate: true,
            diaryLoadFailed: false,
            dreamEnabledFromDiary: false
        ) == .disabled)

        let unavailable = DreamRunAvailability.resolve(
            hasReadDiaryGate: true,
            diaryLoadFailed: true,
            dreamEnabledFromDiary: false
        )
        #expect(unavailable == .unavailable)
        #expect(!unavailable.canRun)
        #expect(unavailable.help.contains("could not be read"))
        #expect(!unavailable.help.contains("is disabled"))
    }

    @Test("Run Dream action presentation labels an unreadable diary as unavailable, not disabled")
    func runDreamGateSeparatesDisabledFromUnreadableDiary() {
        // DreamsView feeds these exact values into both `.disabled` and `.help`
        // for the Run Dream action; this is the UI's production decision seam.
        let disabled = DreamRunAvailability.resolve(
            hasReadDiaryGate: true,
            diaryLoadFailed: false,
            dreamEnabledFromDiary: false
        )
        #expect(!disabled.canRun)
        #expect(disabled.help.contains("Dream cycle is disabled"))

        let unreadable = DreamRunAvailability.resolve(
            hasReadDiaryGate: true,
            diaryLoadFailed: true,
            dreamEnabledFromDiary: false
        )
        #expect(!unreadable.canRun)
        #expect(unreadable.help.contains("could not be read"))
        #expect(!unreadable.help.contains("Dream cycle is disabled"))
    }
}
