import Foundation
import AVFoundation
import Testing
@testable import NativeAgentApp

// EVAL FENCE: app.runtimes / voice.output.controller

@MainActor
@Suite("Voice output controller generations", .serialized)
struct VoiceOutputControllerEvalTests {
    @Test("a rejected audio start reports failure instead of speaking", arguments: [false, true])
    func audioStartResultControlsPlaybackState(started: Bool) async throws {
        let player = try SilentStartResultAudioPlayer(started: started)
        let controller = VoiceOutputController(audioPlayerFactory: { _ in player }) { _ in Data() }
        await controller.speak(text: "silent fixture", mode: .openai, ownerID: "message")
        #expect(player.playCalls == 1)
        #expect(controller.isSpeaking == started)
        #expect(controller.speechOwnerID == (started ? "message" : nil))
        #expect((controller.consumeError(ownerID: "message") != nil) == !started)
        #expect(!controller._localSynthesizerPreparedForTesting)
        if !started {
            #expect(player.delegate == nil)
            #expect(player.stopCalls == 1)
        }
        controller.stop()
    }

    @Test("mounted output controllers keep local speech services cold")
    func localSynthesizerIsLazy() {
        let controller = VoiceOutputController { _ in Data() }

        #expect(!controller._localSynthesizerPreparedForTesting)
        controller.pause()
        controller.resume()
        controller.stop()
        #expect(!controller._localSynthesizerPreparedForTesting)
    }

    @Test("a stopped OpenAI synthesis cannot revive speaking after a newer request")
    func stoppedGenerationCannotPublishAfterItsFetchResumes() async {
        let gate = VoiceSynthesisGate()
        let controller = VoiceOutputController { text in
            try await gate.fetch(text)
        }

        let first = Task { await controller.speak(text: "first", mode: .openai) }
        await gate.waitUntilRequested("first")
        #expect(controller.isSpeaking)
        #expect(!controller._localSynthesizerPreparedForTesting)

        controller.stop()
        #expect(!controller.isSpeaking)

        let second = Task { await controller.speak(text: "second", mode: .openai) }
        await gate.waitUntilRequested("second")
        #expect(controller.isSpeaking)

        await gate.succeed("first")
        await first.value
        #expect(controller.isSpeaking, "A stale fetch completion must not clear or revive the newer generation.")

        controller.stop()
        #expect(!controller.isSpeaking)
        await gate.succeed("second")
        await second.value
        #expect(!controller.isSpeaking, "Every stop leaves the controller non-speaking after pending fetches settle.")
    }

    @Test("one manual playback owner supersedes another without borrowing its UI state")
    func playbackOwnershipFollowsTheNewestRequest() async {
        let gate = VoiceSynthesisGate()
        let controller = VoiceOutputController { text in
            try await gate.fetch(text)
        }

        let first = Task {
            await controller.speak(text: "first", mode: .openai, ownerID: "message:first")
        }
        await gate.waitUntilRequested("first")
        #expect(controller.isSpeaking(ownerID: "message:first"))
        #expect(!controller.isSpeaking(ownerID: "message:second"))

        let second = Task {
            await controller.speak(text: "second", mode: .openai, ownerID: "message:second")
        }
        await gate.waitUntilRequested("second")
        #expect(!controller.isSpeaking(ownerID: "message:first"))
        #expect(controller.isSpeaking(ownerID: "message:second"))

        await gate.succeed("first")
        await first.value
        #expect(controller.isSpeaking(ownerID: "message:second"))

        controller.stop()
        await gate.succeed("second")
        await second.value
        #expect(!controller.isSpeaking)
        #expect(controller.speechOwnerID == nil)
    }

    @Test("stop, supersession, and caller cancellation cancel pending synthesis", .timeLimit(.minutes(1)))
    func pendingSynthesisCancellationFollowsPlaybackOwnership() async {
        let gate = VoiceSynthesisGate(cancelsWhenRequested: true)
        let controller = VoiceOutputController { text in try await gate.fetch(text) }

        let stopped = Task { await controller.speak(text: "stopped", mode: .openai) }
        await gate.waitUntilRequested("stopped")
        controller.stop()
        await stopped.value
        #expect(await gate.wasCancelled("stopped"))
        #expect(!controller.isSpeaking)

        let previous = Task { await controller.speak(text: "previous", mode: .openai, ownerID: "previous") }
        await gate.waitUntilRequested("previous")
        let current = Task { await controller.speak(text: "current", mode: .openai, ownerID: "current") }
        await gate.waitUntilRequested("current")
        await previous.value
        #expect(await gate.wasCancelled("previous"))
        #expect(controller.isSpeaking(ownerID: "current"))
        controller.stop()
        await current.value
        #expect(await gate.wasCancelled("current"))

        let cancelledCaller = Task { await controller.speak(text: "caller", mode: .openai) }
        await gate.waitUntilRequested("caller")
        cancelledCaller.cancel()
        await cancelledCaller.value
        #expect(await gate.wasCancelled("caller"))
        #expect(!controller.isSpeaking)
        #expect(controller.errorMessage == nil)
        #expect(!controller._localSynthesizerPreparedForTesting)
    }

    @Test("a cancelled caller cannot play a non-cooperative synthesis result", .timeLimit(.minutes(1)))
    func cancelledCallerDiscardsLateSynthesis() async {
        let gate = VoiceSynthesisGate()
        let controller = VoiceOutputController { text in try await gate.fetch(text) }
        let caller = Task { await controller.speak(text: "late", mode: .openai) }
        await gate.waitUntilRequested("late")
        caller.cancel()
        await gate.succeed("late")
        await caller.value
        #expect(!controller.isSpeaking)
        #expect(controller.speechOwnerID == nil)
        #expect(controller.errorMessage == nil, "Cancelled results must not reach audio decoding or fallback.")
        #expect(!controller._localSynthesizerPreparedForTesting)
    }
}

private final class SilentStartResultAudioPlayer: AVAudioPlayer {
    let started: Bool
    private(set) var playCalls = 0
    private(set) var stopCalls = 0

    init(started: Bool) throws {
        self.started = started
        // A valid one-sample, mono 8 kHz PCM WAV initializes AVAudioPlayer
        // without its unsupported empty initializer. play() never reaches
        // AVFoundation, so neither result exercises live audio output.
        let silentWAV = Data([
            0x52, 0x49, 0x46, 0x46, 38, 0, 0, 0,
            0x57, 0x41, 0x56, 0x45, 0x66, 0x6d, 0x74, 0x20,
            16, 0, 0, 0, 1, 0, 1, 0,
            0x40, 0x1f, 0, 0, 0x80, 0x3e, 0, 0,
            2, 0, 16, 0, 0x64, 0x61, 0x74, 0x61,
            2, 0, 0, 0, 0, 0,
        ])
        try super.init(data: silentWAV, fileTypeHint: "wav")
    }

    override func play() -> Bool {
        playCalls += 1
        return started
    }

    override func stop() {
        stopCalls += 1
    }
}

private actor VoiceSynthesisGate {
    private var continuations: [String: CheckedContinuation<Data, Error>] = [:]
    private let cancelsWhenRequested: Bool
    private var cancelled: Set<String> = []

    init(cancelsWhenRequested: Bool = false) {
        self.cancelsWhenRequested = cancelsWhenRequested
    }

    func fetch(_ text: String) async throws -> Data {
        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                continuations[text] = continuation
            }
        } onCancel: {
            Task { await self.cancelIfSupported(text) }
        }
    }

    private func cancelIfSupported(_ text: String) {
        guard cancelsWhenRequested else { return }
        cancelled.insert(text)
        continuations.removeValue(forKey: text)?.resume(throwing: CancellationError())
    }

    func wasCancelled(_ text: String) -> Bool { cancelled.contains(text) }

    func waitUntilRequested(_ text: String) async {
        while continuations[text] == nil {
            await Task.yield()
        }
    }

    func succeed(_ text: String) {
        continuations.removeValue(forKey: text)?.resume(returning: Data())
    }
}
