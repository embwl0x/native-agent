import Foundation
import SwiftUI
import NativeAgentShared
// Blueprint: | `VoiceInputController.swift` | Operation-scoped renderer dictation; microphone, consent and recognition stay in the body |

@MainActor @Observable
final class FaceVoiceInput {
    private(set) var operation: UUID?
    private(set) var isStarting = false
    private var client: (any FaceClient)?
    var errorMessage: String?
    private func part<Value: Equatable>(_ name: String, _ read: @escaping (VoiceFace?) -> Value) -> Value {
        guard let operation, let client else { return read(nil) }
        return client.face.slot(.voice(operation)).select(name, as: VoiceFace.self, read)
    }
    var transcript: String { part("transcript") { $0?.text ?? "" } }
    var isListening: Bool { part("listening") { $0?.phase == .listening } }
    var isStopping: Bool { part("recognizing") { $0?.phase == .recognizing } }

    func start(client: any FaceClient, session: String, revision: UInt64) async throws -> VoiceFace {
        let id = UUID()
        self.client = client
        operation = id
        isStarting = true
        defer { if operation == id { isStarting = false } }
        errorMessage = nil
        let reply = try await client.act(.voice(.beginDictation(id: id, session: session, composerRevision: revision)))
        let value = try voiceReply(reply, id: id)
        return value
    }

    func receive(_ value: VoiceFace) {
        guard value.operation == operation else { return }
        if case .unavailable(let failure) = value.state { errorMessage = failure.localizedDescription }
    }

    func finish() async throws -> VoiceFace {
        guard let id = operation, let client else {
            throw WireFailure(code: "dictation_not_started", message: "No dictation operation is open.", cause: nil, effects: .none)
        }
        let value = try voiceReply(try await client.act(.voice(.finishDictation(id: id))), id: id)
        guard value.phase == .finished || value.phase == .cancelled else {
            throw WireFailure(code: "dictation_unsettled", message: "Dictation has not returned its final result.", cause: nil, effects: .unknown)
        }
        if operation == id { operation = nil }
        return value
    }

    func discardListening() {
        guard let id = operation, let client else { return }
        operation = nil
        isStarting = false
        Task { @MainActor in
            do {
                let reply = try await client.act(.voice(.discardDictation(id: id)))
                _ = try voiceReply(reply, id: id)
            } catch { errorMessage = error.localizedDescription }
        }
    }

    private func voiceReply(_ reply: FaceActReply, id: UUID) throws -> VoiceFace {
        switch reply {
        case .voice(let value) where value.operation == id:
            if case .unavailable(let failure) = value.state { throw failure }
            return value
        case .refused(let failure), .failed(let failure): throw failure
        default:
            throw WireFailure(code: "voice_reply_mismatch", message: "I did not return this voice operation.", cause: nil, effects: .unknown)
        }
    }
}

struct FaceDictationObservation: ViewModifier {
    let input: FaceVoiceInput
    func body(content: Content) -> some View {
        content.background { FaceDictationFeed(input: input) }
    }
}

private struct FaceDictationFeed: View {
    @Environment(AppModel.self) private var appModel
    let input: FaceVoiceInput
    var body: some View {
        Color.clear.frame(width: 0, height: 0).accessibilityHidden(true)
            .modifier(FaceObservation(demand: input.operation.map { .key(.voice($0)) }))
            .onChange(of: input.operation.flatMap { appModel.face.slot(.voice($0)).value(as: VoiceFace.self) }, initial: true) { _, value in
                if let value { input.receive(value) }
            }
    }
}
