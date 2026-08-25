import Testing
@testable import NativeAgentApp

@MainActor
private final class GlobalHotkeyVoiceTurnProbe {
    var permissionGranted = true
    var permissionFailure: String?
    var holdCurrent = true
    var captureStartFailure: String?
    var captureFailure: String?
    var transcripts: [String] = []
    var acceptance: AppModel.ChatTurnAcceptance = .accepted(sessionId: "voice-session")
    var captureStarts = 0
    var captureStops = 0
    var submitted: [String] = []
    var unavailable: [String] = []
    var rejected: [String] = []

    func makeTurn() -> GlobalHotkeyVoiceTurn {
        GlobalHotkeyVoiceTurn(
            requestPermission: { self.permissionGranted },
            permissionFailureMessage: { self.permissionFailure },
            isVoiceHoldCurrent: { self.holdCurrent },
            beginCapture: {
                self.captureStarts += 1
                return self.captureStartFailure
            },
            stopCapture: {
                self.captureStops += 1
                return self.transcripts.isEmpty ? "" : self.transcripts.removeFirst()
            },
            captureFailureMessage: { self.captureFailure },
            submitTurn: { transcript in
                self.submitted.append(transcript)
                return self.acceptance
            },
            reportUnavailable: { self.unavailable.append($0) },
            reportRejectedTurn: { self.rejected.append($0) }
        )
    }
}

@MainActor
@Suite("Global hotkey voice turn")
struct GlobalHotkeyVoiceTurnEvalTests {
    // EVAL FENCE: app.mac / turn-ingredient.globalHotkeyVoiceTurn
    @Test("held hotkey submits one trimmed voice turn through the durable chat boundary")
    func heldHotkeySubmitsExactlyOneTurn() async {
        let probe = GlobalHotkeyVoiceTurnProbe()
        probe.transcripts = ["  Capture this thought.  "]
        let turn = probe.makeTurn()

        #expect(await turn.beginVoiceTurn() == .listening)
        #expect(await turn.endVoiceTurn() == .submitted(.accepted(sessionId: "voice-session")))
        #expect(probe.captureStarts == 1)
        #expect(probe.captureStops == 1)
        #expect(probe.submitted == ["Capture this thought."])
        #expect(probe.unavailable.isEmpty)
        #expect(probe.rejected.isEmpty)

        // Carbon can produce an extra key-up during focus changes. It must
        // not stop another capture or fabricate a duplicate chat message.
        #expect(await turn.endVoiceTurn() == .noActiveCapture)
        #expect(probe.captureStops == 1)
        #expect(probe.submitted == ["Capture this thought."])
    }

    @Test("denial, late release, capture failure, and empty capture do not create a chat turn")
    func unavailableVoiceStatesRemainVisibleAndTurnFree() async {
        let denied = GlobalHotkeyVoiceTurnProbe()
        denied.permissionGranted = false
        denied.permissionFailure = "Microphone access denied. Enable it in System Settings."
        #expect(await denied.makeTurn().beginVoiceTurn() == .permissionRefused("Microphone access denied. Enable it in System Settings."))
        #expect(denied.captureStarts == 0)
        #expect(denied.submitted.isEmpty)
        #expect(denied.unavailable == ["Microphone access denied. Enable it in System Settings."])

        let released = GlobalHotkeyVoiceTurnProbe()
        released.holdCurrent = false
        #expect(await released.makeTurn().beginVoiceTurn() == .releasedBeforeCapture)
        #expect(released.captureStarts == 0)
        #expect(released.submitted.isEmpty)

        let unavailableCapture = GlobalHotkeyVoiceTurnProbe()
        unavailableCapture.captureStartFailure = "No usable microphone input route was found."
        #expect(await unavailableCapture.makeTurn().beginVoiceTurn() == .captureUnavailable("No usable microphone input route was found."))
        #expect(unavailableCapture.captureStarts == 1)
        #expect(unavailableCapture.submitted.isEmpty)
        #expect(unavailableCapture.unavailable == ["No usable microphone input route was found."])

        let empty = GlobalHotkeyVoiceTurnProbe()
        empty.transcripts = [" \n "]
        let emptyTurn = empty.makeTurn()
        #expect(await emptyTurn.beginVoiceTurn() == .listening)
        #expect(await emptyTurn.endVoiceTurn() == .discardedEmptyTranscript)
        #expect(empty.submitted.isEmpty)
    }

    @Test("a rejected durable chat turn remains visible and a later hold can submit normally")
    func rejectedTurnDoesNotPoisonTheNextVoiceTurn() async {
        let probe = GlobalHotkeyVoiceTurnProbe()
        probe.transcripts = ["first", "second"]
        probe.acceptance = .rejected(message: "No active chat session. Your message was not sent.")
        let turn = probe.makeTurn()

        #expect(await turn.beginVoiceTurn() == .listening)
        #expect(await turn.endVoiceTurn() == .submissionRejected("No active chat session. Your message was not sent."))
        #expect(probe.submitted == ["first"])
        #expect(probe.rejected == ["No active chat session. Your message was not sent."])

        probe.acceptance = .accepted(sessionId: "voice-session")
        #expect(await turn.beginVoiceTurn() == .listening)
        #expect(await turn.endVoiceTurn() == .submitted(.accepted(sessionId: "voice-session")))
        #expect(probe.submitted == ["first", "second"])
    }
}
