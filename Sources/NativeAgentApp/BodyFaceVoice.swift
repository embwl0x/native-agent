import ChatTurnRuntime
import ChatSessionWork
import EngineRuntime
import Foundation
import MultimodalTTS
import NativeAgentShared
import Observation
import ScreenVision
// Blueprint: | `BodyFaceVoice.swift` | Body microphone, speech and attachment reads publish operation-bound values to the window |

@MainActor
final class BodyFaceVoice {
    private let engine: NativeAgentEngine
    private struct Capture {
        let input: VoiceInputCapture
        var value: VoiceFace
        var watch: Task<Void, Never>?
    }
    private var captures: [UUID: Capture] = [:]
    private var speech: [UUID: Task<Void, Never>] = [:]

    init(engine: NativeAgentEngine) { self.engine = engine }

    func close() async {
        let held = captures
        let spoken = speech
        captures.removeAll()
        speech.removeAll()
        for capture in held.values { capture.watch?.cancel(); capture.input.discardListening() }
        for task in spoken.values { task.cancel() }
        let playback = VoiceOutputController.sharedMessagePlayback
        if let owner = playback.speechOwnerID, spoken.keys.contains(where: { $0.uuidString == owner }) { playback.stop() }
        for capture in held.values { await capture.watch?.value }
        for task in spoken.values { await task.value }
    }

    func handle(_ act: FaceAct) async throws -> FaceActReply? {
        switch act {
        case .voice(let command): return try await voice(command)
        case .ingestAttachment(let transfer):
            return .artifact(try await Self.attachment(transfer.attachment))
        case .captureScreen:
            let captured = try await Self.capture()
            return .artifact(captured)
        default: return nil
        }
    }

    private func voice(_ command: VoiceAct) async throws -> FaceActReply {
        switch command {
        case .beginDictation(let id, let session, let revision):
            guard captures[id] == nil else { throw BodyFaceServices.failure("voice_operation_exists", "This dictation operation is already open.") }
            VoiceOutputController.sharedMessagePlayback.stop()
            let input = VoiceInputCapture.forChat()
            if let cause = await input.requestPermission().errorMessage {
                throw BodyFaceServices.failure("voice_permission_required", cause)
            }
            try Task.checkCancellation()
            input.startListening()
            guard input.isListening else {
                throw BodyFaceServices.failure("voice_capture_failed", input.errorMessage ?? "The microphone did not start.")
            }
            let value = VoiceFace(operation: id, session: session, message: nil, composerRevision: revision,
                phase: .listening, text: input.transcript, attachment: nil, state: .ready)
            captures[id] = Capture(input: input, value: value)
            await engine.face.post(value, at: .voice(id))
            let watch = Task { [weak self] in
                guard let self else { return }
                await watchCapture(id)
            }
            captures[id]?.watch = watch
            return .voice(value)
        case .finishDictation(let id):
            guard let capture = captures[id] else { throw BodyFaceServices.failure("voice_operation_missing", "This dictation operation is not open.") }
            let result = await capture.input.stopListeningResult()
            try Task.checkCancellation()
            captures.removeValue(forKey: id)?.watch?.cancel()
            var value = capture.value
            value.phase = .finished
            switch result {
            case .final(let text): value.text = text
            case .partial:
                throw BodyFaceServices.failure("voice_capture_partial", "Recognition ended before a final transcript was available.")
            case .failed(let cause): throw BodyFaceServices.failure("voice_capture_failed", cause)
            }
            if let attachment = capture.input.attachment { value.attachment = try await Self.faceAttachment(attachment) }
            await engine.face.post(value, at: .voice(id))
            return .voice(value)
        case .discardDictation(let id):
            guard var capture = captures.removeValue(forKey: id) else {
                throw BodyFaceServices.failure("voice_operation_missing", "This dictation operation is not open.")
            }
            capture.watch?.cancel()
            capture.input.discardListening()
            capture.value.phase = .cancelled
            capture.value.text = nil
            await engine.face.post(capture.value, at: .voice(id))
            return .voice(capture.value)
        case .speak(let id, let session, let message, let supplied):
            let text: String
            if let message {
                guard let session else { throw BodyFaceServices.failure("speech_session_missing", "This message has no conversation identity.") }
                let found: ChatMessage
                if session.hasPrefix("contact:") {
                    found = try await engine.contactThreadMessage(String(session.dropFirst(8)), id: message)
                } else {
                    let messages = try await engine.transcripts.loadMessages(sessionId: session, cached: false)
                    guard let value = messages.first(where: { $0.id == message }) else {
                        throw BodyFaceServices.failure("speech_message_missing", "The message is absent from the checked conversation.")
                    }
                    found = value
                }
                text = found.content
            } else { text = supplied }
            let owner = id.uuidString
            let playback = VoiceOutputController.sharedMessagePlayback
            await playback.speak(text: text, policy: engine.trust.policy,
                loadPolicy: { try await self.engine.trust.load() }, ownerID: owner)
            let value = VoiceFace(operation: id, session: session, message: message, composerRevision: nil,
                phase: playback.isSpeaking(ownerID: owner) ? .speaking : .finished, text: nil, attachment: nil,
                state: playback.consumeError(ownerID: owner).map {
                    .unavailable(BodyFaceServices.failure("speech_failed", $0))
                } ?? .ready)
            await engine.face.post(value, at: .voice(id))
            speech[id]?.cancel()
            speech[id] = Task { [weak self] in
                guard let self else { return }
                await watchSpeech(value)
            }
            return .voice(value)
        case .stopSpeech(let id):
            let playback = VoiceOutputController.sharedMessagePlayback
            if playback.speechOwnerID == id.uuidString { playback.stop() }
            speech.removeValue(forKey: id)?.cancel()
            let value = VoiceFace(operation: id, session: nil, message: nil, composerRevision: nil,
                phase: .cancelled, text: nil, attachment: nil, state: .ready)
            await engine.face.post(value, at: .voice(id))
            return .voice(value)
        }
    }

    private func watchCapture(_ id: UUID) async {
        let (changes, signal) = AsyncStream<Void>.makeStream()
        defer { signal.finish() }
        var events = changes.makeAsyncIterator()
        while !Task.isCancelled, var capture = captures[id] {
            let read = withObservationTracking {
                (capture.input.transcript, capture.input.isListening, capture.input.isStopping, capture.input.errorMessage)
            } onChange: { signal.yield() }
            capture.value.text = read.0
            capture.value.phase = read.2 ? .recognizing : read.1 ? .listening : .finished
            if let issue = read.3 { capture.value.state = .unavailable(BodyFaceServices.failure("voice_capture_failed", issue)) }
            captures[id]?.value = capture.value
            await engine.face.post(capture.value, at: .voice(id))
            guard await events.next() != nil else { return }
        }
    }

    private func watchSpeech(_ initial: VoiceFace) async {
        var value = initial
        let playback = VoiceOutputController.sharedMessagePlayback
        let (changes, signal) = AsyncStream<Void>.makeStream()
        defer { signal.finish() }
        var events = changes.makeAsyncIterator()
        while !Task.isCancelled {
            let read = withObservationTracking { (playback.isSpeaking(ownerID: value.operation.uuidString), playback.errorMessage) }
                onChange: { signal.yield() }
            value.phase = read.0 ? .speaking : .finished
            if let issue = playback.consumeError(ownerID: value.operation.uuidString) {
                value.state = .unavailable(BodyFaceServices.failure("speech_failed", issue))
            }
            await engine.face.post(value, at: .voice(value.operation))
            guard read.0, await events.next() != nil else { return }
        }
    }

    @concurrent private static func faceAttachment(_ attachment: MultimodalAttachment) async throws -> FaceAttachment {
        let bytes: Data
        if let decoded = Data(base64Encoded: attachment.base64) { bytes = decoded }
        else if let path = attachment.path { bytes = try Data(contentsOf: URL(fileURLWithPath: path)) }
        else { throw BodyFaceServices.failure("voice_attachment_missing", "The recorded audio has no readable bytes.") }
        return .init(id: attachment.id, name: attachment.name ?? attachment.id, mimeType: attachment.mime,
            byteCount: bytes.count, resource: nil, bytes: bytes)
    }

    @concurrent private static func attachment(_ attachment: FaceAttachment) async throws -> ArtifactGrant {
        let bytes: Data
        if let supplied = attachment.bytes { bytes = supplied }
        else if let grant = attachment.resource {
            let url = try BodyFaceResources.resolve(grant)
            let access = url.startAccessingSecurityScopedResource()
            defer { if access { url.stopAccessingSecurityScopedResource() } }
            bytes = try Data(contentsOf: url)
        } else { throw BodyFaceServices.failure("attachment_bytes_missing", "The selected attachment has no readable bytes or access grant.") }
        guard bytes.count == attachment.byteCount else {
            throw BodyFaceServices.failure("attachment_changed", "The attachment changed after selection. Choose it again.")
        }
        return .init(resource: nil, bytes: bytes, mimeType: attachment.mimeType, name: attachment.name, warnings: [])
    }

    @concurrent private static func capture() async throws -> ArtifactGrant {
        let image = try await NativeScreenCapture.captureImageBase64()
        guard let bytes = Data(base64Encoded: image.base64) else {
            throw BodyFaceServices.failure("screenshot_encoding_invalid", "The capture owner returned invalid image bytes.")
        }
        return .init(resource: nil, bytes: bytes, mimeType: image.mime, name: image.name, warnings: [])
    }
}

extension VoiceOutputController {
    /// Spoken replies keep one owner in her body; the window process only presents.
    static let sharedMessagePlayback = VoiceOutputController(
        failureMessage: { UserFacingError.message($0, action: $1) },
        failureCause: { UserFacingError.cause($0, action: $1) }
    )
}
