import Foundation
import Testing
@testable import NativeAgentApp

@MainActor
private final class VoiceRecognitionDriverProbe: VoiceInputRecognitionDriving {
    private var handler: (@MainActor (VoiceInputRecognitionEvent) -> Void)?
    private(set) var startCount = 0
    private(set) var finishCount = 0

    func start(handler: @escaping @MainActor (VoiceInputRecognitionEvent) -> Void) throws {
        startCount += 1
        self.handler = handler
    }

    func finish() {
        finishCount += 1
    }

    func cancel() {}

    func emit(_ event: VoiceInputRecognitionEvent) {
        handler?(event)
    }
}

// EVAL FENCE: app.runtimes / voice.input.listen
@MainActor
@Suite("Voice input controller lifecycle", .serialized)
struct VoiceInputControllerEvalTests {
    @Test("mounted voice controllers keep native speech resources cold until native capture")
    func nativeSpeechResourcesAreLazy() async {
        let driver = VoiceRecognitionDriverProbe()
        let controller = VoiceInputController(
            permissionRequest: { .granted },
            recognitionDriver: driver
        )

        #expect(!controller._nativeResourcesPreparedForTesting)
        #expect(await controller.requestPermission())
        #expect(!controller._nativeResourcesPreparedForTesting)

        // A non-native driver also has no reason to initialize Speech or an
        // AVAudioEngine; production reaches that allocation only after the
        // user starts the built-in microphone path.
        controller.startListening()
        #expect(!controller._nativeResourcesPreparedForTesting)
    }

    @Test("a final recognition result resolves one stop before its timeout")
    func finalResultWinsAndLeavesTheControllerIdle() async {
        let driver = VoiceRecognitionDriverProbe()
        let controller = VoiceInputController(
            permissionRequest: { .granted },
            recognitionDriver: driver,
            stopTimeoutNanoseconds: 50_000_000
        )
        controller.startListening()
        driver.emit(.partial("partial phrase"))

        let stop = Task { @MainActor in await controller.stopListeningResult() }
        await Task.yield()
        #expect(driver.finishCount == 1)
        driver.emit(.final("final phrase"))

        #expect(await stop.value == .final("final phrase"))
        #expect(controller.transcript == "final phrase")
        #expect(!controller.isListening)
        // The canceled fallback must not revive the controller or a completed
        // continuation after its original deadline.
        try? await Task.sleep(for: .milliseconds(60))
        #expect(!controller.isListening)
    }

    @Test("a timeout returns a flagged partial result and ignores a late final")
    func timeoutBeforeFinalIsTerminalAndHonest() async {
        let driver = VoiceRecognitionDriverProbe()
        let controller = VoiceInputController(
            permissionRequest: { .granted },
            recognitionDriver: driver,
            stopTimeoutNanoseconds: 1_000_000
        )
        controller.startListening()
        driver.emit(.partial("latest partial"))

        let result = await controller.stopListeningResult()
        #expect(result == .partial("latest partial"))
        #expect(result.isPartial)
        #expect(result.transcriptForSubmission.isEmpty)
        #expect(result.userFacingFailureMessage?.contains("timed out") == true)
        #expect(controller.transcript == "latest partial")
        #expect(controller.errorMessage?.contains("timed out") == true)
        #expect(!controller.isListening)
        // A queued second stop may reach the controller after the timeout has
        // made the UI idle. It must retain the same incomplete classification,
        // never recast the saved partial text as a final result.
        #expect(await controller.stopListeningResult() == .partial("latest partial"))
        driver.emit(.final("late final"))
        #expect(controller.transcript == "latest partial")
        #expect(!controller.isListening)
    }

    @Test("concurrent stops share one finish and one final result")
    func concurrentStopsWaitForTheSameTerminalResult() async {
        let driver = VoiceRecognitionDriverProbe()
        let controller = VoiceInputController(
            permissionRequest: { .granted },
            recognitionDriver: driver,
            stopTimeoutNanoseconds: 50_000_000
        )
        controller.startListening()
        driver.emit(.partial("not final"))

        let first = Task { @MainActor in await controller.stopListeningResult() }
        await Task.yield()
        let second = Task { @MainActor in await controller.stopListeningResult() }
        await Task.yield()

        // A second key-up or mounted composer callback must join the first
        // flush rather than returning the partial text or queueing another
        // recognition finish.
        #expect(driver.finishCount == 1)
        driver.emit(.final("settled phrase"))

        #expect(await first.value == .final("settled phrase"))
        #expect(await second.value == .final("settled phrase"))
        #expect(driver.finishCount == 1)
        #expect(!controller.isListening)
    }

    @Test("a canceled timeout from one stop cannot complete the next stop")
    func twoStopsKeepTheirContinuationsAndFinalResultsIsolated() async {
        let driver = VoiceRecognitionDriverProbe()
        let controller = VoiceInputController(
            permissionRequest: { .granted },
            recognitionDriver: driver,
            stopTimeoutNanoseconds: 40_000_000
        )

        controller.startListening()
        let firstStop = Task { @MainActor in await controller.stopListening() }
        await Task.yield()
        driver.emit(.final("first final"))
        #expect(await firstStop.value == "first final")

        // Cross the original stop's deadline while a new stop is waiting.
        // Without generation ownership, that stale timer could resume the
        // second continuation with its partial transcript.
        try? await Task.sleep(for: .milliseconds(20))
        controller.startListening()
        driver.emit(.partial("second partial"))
        let secondStop = Task { @MainActor in await controller.stopListening() }
        await Task.yield()
        try? await Task.sleep(for: .milliseconds(25))
        driver.emit(.final("second final"))

        #expect(await secondStop.value == "second final")
        #expect(driver.startCount == 2)
        #expect(driver.finishCount == 2)
        #expect(controller.transcript == "second final")
        #expect(!controller.isListening)
    }
}
