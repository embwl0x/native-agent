import Testing
@testable import NativeAgentApp

@Suite("Inbox trigger toggle behavior")
struct InboxTriggerToggleBehaviorTests {
    // app.desk / desk.inboxPolicy.triggerToggle
    @Test("failed latest toggle restores the server state and a retry always produces a new request")
    func failedToggleReturnsToServerAndDoesNotSuppressRetry() {
        var state = InboxTriggerToggleStateMachine(serverEnabled: true)

        let disable = state.userToggled(to: false)
        #expect(disable.requestedEnabled == false)
        #expect(state.visualEnabled == false)
        state.completed(disable, accepted: false)
        #expect(state.serverEnabled == true)
        #expect(state.visualEnabled == true)

        let retry = state.userToggled(to: false)
        #expect(retry.id != disable.id)
        #expect(retry.requestedEnabled == false)
        #expect(state.visualEnabled == false)
        state.completed(retry, accepted: true)
        #expect(state.serverEnabled == false)
        #expect(state.visualEnabled == false)
    }

    // app.desk / desk.inboxPolicy.triggerToggle
    @Test("a stale failed completion cannot overwrite a user retoggle while the newer request still dispatches")
    func retoggleDuringFlightKeepsNewestVisualIntentAndAcceptsServerReload() {
        var state = InboxTriggerToggleStateMachine(serverEnabled: true)

        let disable = state.userToggled(to: false)
        let reenable = state.userToggled(to: true)
        #expect(disable.id != reenable.id)
        #expect(disable.requestedEnabled == false)
        #expect(reenable.requestedEnabled == true)
        #expect(state.visualEnabled == true)

        state.completed(disable, accepted: false)
        #expect(state.visualEnabled == true)
        #expect(state.serverEnabled == true)

        state.completed(reenable, accepted: true)
        #expect(state.visualEnabled == true)
        #expect(state.serverEnabled == true)

        state.synchronizeServer(enabled: false)
        #expect(state.visualEnabled == false)
        #expect(state.serverEnabled == false)
    }

    // app.desk / desk.inboxPolicy.triggerToggle
    @Test("a delayed server refresh cannot repaint over a newer local toggle")
    func inFlightToggleOwnsVisualStateUntilItCompletes() {
        var state = InboxTriggerToggleStateMachine(serverEnabled: false)
        let enable = state.userToggled(to: true)
        state.synchronizeServer(enabled: false)
        #expect(state.serverEnabled == false)
        #expect(state.visualEnabled == true)

        state.completed(enable, accepted: false)
        #expect(state.visualEnabled == false)
        #expect(state.serverEnabled == false)
    }
}
