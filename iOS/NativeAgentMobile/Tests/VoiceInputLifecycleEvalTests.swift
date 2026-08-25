import Speech
import XCTest
@testable import NativeAgentMobile

private actor DelayedFirstSpeechAuthorization {
    private var requests = 0
    private var firstRequestContinuation: CheckedContinuation<Void, Never>?

    func request() async -> SFSpeechRecognizerAuthorizationStatus {
        requests += 1
        guard requests == 1 else { return .denied }
        await withCheckedContinuation { continuation in
            firstRequestContinuation = continuation
        }
        return .authorized
    }

    func hasFirstRequest() -> Bool { firstRequestContinuation != nil }

    func releaseFirstRequest() {
        firstRequestContinuation?.resume()
        firstRequestContinuation = nil
    }
}

/// Executable fence for `ios.screens / ios.voice.input`.
///
/// Start/stop generations must not leave a tap or recognition task behind, and
/// a delayed older start may never revive the current microphone state.
@MainActor
final class VoiceInputLifecycleEvalTests: XCTestCase {
    func test_stopAndDeniedStartsAlwaysReturnTheControllerToAnIdleLifecycle() async {
        let controller = VoiceInputController(
            requestSpeechAuthorization: { .denied },
            requestMicrophoneAuthorization: { true }
        )

        controller.stop()
        assertIdle(controller.lifecycleSnapshot)

        await controller.start()
        assertIdle(controller.lifecycleSnapshot)
        XCTAssertTrue(controller.error?.localizedCaseInsensitiveContains("speech recognition permission") == true)

        controller.stop()
        assertIdle(controller.lifecycleSnapshot)
    }

    /// `notDetermined` is not a user denial: it is the state an unavailable
    /// iOS prompt can leave behind. The input must remain idle, explain that
    /// distinction, and leave the user a Settings recovery path without ever
    /// touching microphone setup.
    func test_unresolvedSpeechAuthorizationSurfacesARecoverableStateBeforeMicrophoneSetup() async {
        let controller = VoiceInputController(
            requestSpeechAuthorization: { .notDetermined },
            requestMicrophoneAuthorization: {
                XCTFail("microphone setup must not run while speech authorization is unresolved")
                return true
            }
        )

        await controller.start()

        assertIdle(controller.lifecycleSnapshot)
        XCTAssertTrue(controller.error?.localizedCaseInsensitiveContains("not resolved") == true)
        XCTAssertTrue(controller.error?.localizedCaseInsensitiveContains("settings") == true)
        XCTAssertFalse(controller.error?.localizedCaseInsensitiveContains("denied") == true)
    }

    func test_lateAuthorizationFromAnOlderStartCannotReviveTheNewerStoppedGeneration() async {
        let authorization = DelayedFirstSpeechAuthorization()
        let controller = VoiceInputController(
            requestSpeechAuthorization: { await authorization.request() },
            requestMicrophoneAuthorization: { true }
        )

        let olderStart = Task { @MainActor in await controller.start() }
        for _ in 0..<100 {
            if await authorization.hasFirstRequest() { break }
            await Task.yield()
        }
        let firstRequestArrived = await authorization.hasFirstRequest()
        XCTAssertTrue(firstRequestArrived, "the test did not reach the delayed authorization boundary")

        controller.stop()
        await controller.start() // second authorization is denied immediately
        let generationAfterNewerStart = controller.lifecycleSnapshot.generation
        assertIdle(controller.lifecycleSnapshot)

        await authorization.releaseFirstRequest()
        await olderStart.value

        let final = controller.lifecycleSnapshot
        assertIdle(final)
        XCTAssertEqual(final.generation, generationAfterNewerStart)
        XCTAssertTrue(final.generation >= 3, "start / stop / start must advance the lifecycle generation")
    }

    private func assertIdle(
        _ snapshot: VoiceInputLifecycleSnapshot,
        file: StaticString = #filePath,
        line: UInt = #line
    ) {
        XCTAssertFalse(snapshot.isListening, file: file, line: line)
        XCTAssertFalse(snapshot.isStarting, file: file, line: line)
        XCTAssertFalse(snapshot.tapInstalled, file: file, line: line)
        XCTAssertFalse(snapshot.hasRecognitionTask, file: file, line: line)
        XCTAssertFalse(snapshot.desiredListening, file: file, line: line)
        XCTAssertFalse(snapshot.waitingForFinalAfterStop, file: file, line: line)
    }
}
