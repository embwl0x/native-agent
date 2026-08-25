import XCTest
@testable import NativeAgentMobile

/// Executable fence for `ios.sync / ios.voice.output`.
final class VoiceOutputStateEvalTests: XCTestCase {
    func test_playbackIsNeverSpeakingUntilAnUtteranceIsAccepted() {
        var state = VoiceOutputPlaybackState.idle

        XCTAssertFalse(state.isSpeaking)
        XCTAssertTrue(state.beginIfIdle())
        XCTAssertTrue(state.isSpeaking)
    }

    func test_activePlaybackRejectsASecondEnqueueUntilItFinishesOrIsInterrupted() {
        var state = VoiceOutputPlaybackState.idle

        XCTAssertTrue(state.beginIfIdle())
        XCTAssertFalse(state.beginIfIdle())
        XCTAssertTrue(state.isSpeaking)

        state.finish()
        XCTAssertFalse(state.isSpeaking)
        XCTAssertTrue(state.beginIfIdle())

        state.finish()
        XCTAssertFalse(state.isSpeaking)
    }

    func test_controllerUsesTheStateForAudioFailureStopAndInterruption() throws {
        let source = try MobileEvalSources.mobileSource("VoiceOutputController.swift")
        let controller = try XCTUnwrap(
            MobileEvalSources.blockBody(named: "VoiceOutputController", keyword: "final class", in: source)
        )

        XCTAssertTrue(controller.contains("guard playbackState == .idle else { return }"))
        XCTAssertTrue(controller.contains("guard playbackState.beginIfIdle() else { return }"))
        XCTAssertTrue(controller.contains("func handleAudioSessionInterruption()"))
        XCTAssertTrue(controller.contains("finishPlayback()"))
    }
}
