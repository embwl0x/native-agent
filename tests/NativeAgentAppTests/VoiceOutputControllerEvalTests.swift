import Foundation
import Testing
@testable import NativeAgentApp

// EVAL FENCE: app.runtimes / voice.output.controller

@MainActor
@Suite("Voice output controller generations", .serialized)
struct VoiceOutputControllerEvalTests {
    @Test("a stopped OpenAI synthesis cannot revive speaking after a newer request")
    func stoppedGenerationCannotPublishAfterItsFetchResumes() async {
        let gate = VoiceSynthesisGate()
        let controller = VoiceOutputController { text in
            try await gate.fetch(text)
        }

        let first = Task { await controller.speak(text: "first", mode: .openai) }
        await gate.waitUntilRequested("first")
        #expect(controller.isSpeaking)

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
}

private actor VoiceSynthesisGate {
    private var continuations: [String: CheckedContinuation<Data, Error>] = [:]

    func fetch(_ text: String) async throws -> Data {
        try await withCheckedThrowingContinuation { continuation in
            continuations[text] = continuation
        }
    }

    func waitUntilRequested(_ text: String) async {
        while continuations[text] == nil {
            await Task.yield()
        }
    }

    func succeed(_ text: String) {
        continuations.removeValue(forKey: text)?.resume(returning: Data())
    }
}
