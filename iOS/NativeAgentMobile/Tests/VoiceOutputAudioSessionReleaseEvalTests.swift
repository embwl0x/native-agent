import XCTest
@testable import NativeAgentMobile

/// E5 (upgrade-sweep 2026-08): the audio session stayed active after the last
/// utterance, holding the route and suppressing other apps' audio indefinitely.
///
/// Silent-failure class: the user hears NOTHING wrong from NativeAgent — the
/// damage lands on whatever they play next. Only a test can see it.
@MainActor
final class VoiceOutputAudioSessionReleaseEvalTests: XCTestCase {

    func test_theSessionIsNotDeactivatedBeforeItWasEverActivated() {
        var deactivations = 0
        let controller = VoiceOutputController(
            configureAudioSession: {},
            activateAudioSession: {},
            deactivateAudioSession: { deactivations += 1 }
        )
        // Nothing has spoken: stop() must not poke a session we never took.
        controller.stop()
        XCTAssertEqual(deactivations, 0)
        XCTAssertFalse(controller.audioSessionActive)
    }

    func test_anInterruptionReleasesTheRouteRatherThanHoldingIt() {
        var deactivations = 0
        let controller = VoiceOutputController(
            configureAudioSession: {},
            activateAudioSession: {},
            deactivateAudioSession: { deactivations += 1 }
        )
        controller.enabled = true
        controller.speak("hello")
        XCTAssertTrue(controller.audioSessionActive,
                      "speak() must record that it took the audio session")
        controller.handleAudioSessionInterruption()
        XCTAssertEqual(deactivations, 1)
        XCTAssertFalse(controller.audioSessionActive)
    }

    func test_aFailedDeactivationKeepsTheFlagSetSoTheNextIdleRetries() {
        struct Boom: Error {}
        var attempts = 0
        let controller = VoiceOutputController(
            configureAudioSession: {},
            activateAudioSession: {},
            deactivateAudioSession: {
                attempts += 1
                if attempts == 1 { throw Boom() }
            }
        )
        controller.enabled = true
        controller.speak("hello")
        controller.stop()
        XCTAssertEqual(attempts, 1)
        XCTAssertTrue(controller.audioSessionActive, "a failed release must not be forgotten")
        controller.stop()
        XCTAssertEqual(attempts, 2)
        XCTAssertFalse(controller.audioSessionActive)
    }

    func test_theDeactivationNotifiesOtherAudioApps() throws {
        // The default closure is the one that ships; assert the option is on it.
        let source = try MobileEvalSources.mobileSource("VoiceOutputController.swift")
        XCTAssertTrue(source.contains(".notifyOthersOnDeactivation"))
        XCTAssertTrue(source.contains("deactivateAudioSession"))
    }
}
