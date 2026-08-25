import AVFoundation
import Foundation
import Testing
@testable import NativeAgentApp

// EVAL FENCE: app.runtimes / voice.output.readAloud

@MainActor
@Suite("Read aloud generation callbacks", .serialized)
struct VoiceReadAloudGenerationEvalTests {
    @Test("stale cancelled utterances, including copies, cannot clear the live read-aloud state")
    func staleDelegateCallbacksDoNotReachCurrentUtterance() async {
        let controller = VoiceOutputController()
        await controller.speak(text: "first local utterance", mode: .local)
        let firstGeneration = controller.speechGeneration
        controller.stop()

        await controller.speak(text: "second local utterance", mode: .local)
        #expect(controller.isSpeaking)

        let original = GenerationTaggedUtterance(string: "first", generation: firstGeneration)
        let copied = original.copy() as! AVSpeechUtterance
        let synthesizer = AVSpeechSynthesizer()
        controller.speechSynthesizer(synthesizer, didCancel: original)
        controller.speechSynthesizer(synthesizer, didCancel: copied)
        await Task.yield()
        await Task.yield()
        #expect(controller.isSpeaking)

        controller.stop()
        #expect(!controller.isSpeaking)
    }
}
