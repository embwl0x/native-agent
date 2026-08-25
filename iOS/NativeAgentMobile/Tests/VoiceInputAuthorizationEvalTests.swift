import Speech
import XCTest
@testable import NativeAgentMobile

private actor DelayedMicrophoneAuthorization {
    private var continuation: CheckedContinuation<Bool, Never>?

    func request() async -> Bool {
        await withCheckedContinuation { continuation in
            self.continuation = continuation
        }
    }

    func isPending() -> Bool { continuation != nil }

    func resolve(_ granted: Bool) {
        continuation?.resume(returning: granted)
        continuation = nil
    }
}

/// Executable fence for `ios.sync / ios.voiceInput.authorization`.
///
/// Voice input requires both permissions. The controller must make the pending
/// gate explicit, then refuse to begin audio capture when microphone access is
/// declined after speech recognition has already been authorized.
@MainActor
final class VoiceInputAuthorizationEvalTests: XCTestCase {
    func test_microphoneAuthorizationIsVisibleAndDeniedBeforeAudioCaptureBegins() async {
        let microphone = DelayedMicrophoneAuthorization()
        let controller = VoiceInputController(
            requestSpeechAuthorization: { .authorized },
            requestMicrophoneAuthorization: { await microphone.request() }
        )

        let start = Task { @MainActor in await controller.start() }
        for _ in 0..<100 {
            if await microphone.isPending() { break }
            await Task.yield()
        }

        let microphoneAuthorizationIsPending = await microphone.isPending()
        XCTAssertTrue(microphoneAuthorizationIsPending, "the controller did not reach microphone authorization")
        XCTAssertTrue(controller.isStarting)
        XCTAssertEqual(controller.statusText, "Requesting microphone permission...")
        XCTAssertFalse(controller.lifecycleSnapshot.tapInstalled)
        XCTAssertFalse(controller.lifecycleSnapshot.hasRecognitionTask)

        await microphone.resolve(false)
        await start.value

        XCTAssertEqual(controller.error, VoicePresentation.deniedMicrophoneMessage())
        XCTAssertNil(controller.statusText)
        XCTAssertFalse(controller.lifecycleSnapshot.isListening)
        XCTAssertFalse(controller.lifecycleSnapshot.isStarting)
        XCTAssertFalse(controller.lifecycleSnapshot.tapInstalled)
        XCTAssertFalse(controller.lifecycleSnapshot.hasRecognitionTask)
        XCTAssertFalse(controller.lifecycleSnapshot.desiredListening)
    }
}
