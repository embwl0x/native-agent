import Foundation
import MacControl
import Testing
@testable import NativeAgentApp

@Suite("Mac Control bridge lifecycle")
struct MacControlBridgeLifecycleTests {
    @Test("listener admission waits for successful durable recovery")
    func recoveryPrecedesListenerAdmission() {
        var startup = MacControlBridgeStartupState()
        guard let generation = startup.begin(listenerExists: false) else {
            Issue.record("first startup attempt should be admitted")
            return
        }

        #expect(startup.mayContinueAfterRecovery(
            generation: generation,
            recoverySucceeded: false,
            listenerExists: false
        ) == false)
        #expect(startup.mayContinueAfterRecovery(
            generation: generation,
            recoverySucceeded: true,
            listenerExists: false
        ) == true)
        #expect(startup.finish(generation: generation) == true)
        #expect(startup.mayContinueAfterRecovery(
            generation: generation,
            recoverySucceeded: true,
            listenerExists: false
        ) == false)
    }

    @Test("stop invalidates stale recovery and permits a clean restart")
    func stopInvalidatesStaleRecovery() {
        var startup = MacControlBridgeStartupState()
        guard let staleGeneration = startup.begin(listenerExists: false) else {
            Issue.record("first startup attempt should be admitted")
            return
        }
        startup.stop()
        guard let liveGeneration = startup.begin(listenerExists: false) else {
            Issue.record("restart should be admitted after stop")
            return
        }

        #expect(liveGeneration != staleGeneration)
        #expect(startup.mayContinueAfterRecovery(
            generation: staleGeneration,
            recoverySucceeded: true,
            listenerExists: false
        ) == false)
        #expect(startup.mayContinueAfterRecovery(
            generation: liveGeneration,
            recoverySucceeded: true,
            listenerExists: false
        ) == true)
    }

    @Test("late cancellation never overwrites successful process completion")
    func lateCancellationPreservesSuccess() {
        #expect(MacControlBridge.execTerminalState(
            exit: 0,
            timedOut: false,
            cancellationSignalled: true
        ) == .completed)
    }

    @Test("only a signalled unsuccessful process acknowledges cancellation")
    func cancellationAcknowledgementRequiresCausalEvidence() {
        #expect(MacControlBridge.execTerminalState(
            exit: 15,
            timedOut: false,
            cancellationSignalled: true
        ) == .cancelAcknowledged)
        #expect(MacControlBridge.execTerminalState(
            exit: 15,
            timedOut: false,
            cancellationSignalled: false
        ) == .failed)
    }

    @Test("deadline evidence takes precedence over cancellation bookkeeping")
    func timeoutRemainsDistinct() {
        #expect(MacControlBridge.execTerminalState(
            exit: 15,
            timedOut: true,
            cancellationSignalled: true
        ) == .timedOut)
    }

    @Test("request-read deadline cancels only its own unrouted connection")
    func requestReadDeadlineIsIdentityGated() {
        let liveToken = UUID()
        let staleToken = UUID()
        let pending = BridgeReadDeadlineState(token: liveToken)

        #expect(pending.shouldCancel(firingToken: liveToken))
        #expect(!pending.shouldCancel(firingToken: staleToken))
    }

    @Test("routing cancels request-read expiry ownership")
    func routedConnectionIsExemptFromReadDeadline() {
        let token = UUID()
        var state = BridgeReadDeadlineState(token: token)
        state.routed = true

        #expect(!state.shouldCancel(firingToken: token))
    }
}
