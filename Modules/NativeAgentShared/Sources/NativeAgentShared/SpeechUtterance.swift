import Foundation
@preconcurrency import Speech
@preconcurrency import AVFoundation

// Blueprint: | `SpeechUtterance.swift` | `SpeechUtterance`: original audio/recognition evidence, submitted wording and compact uncertainty projection without rewriting hypotheses |

/// Recognition is evidence attached to the original audio, never a rewrite of it.
public struct SpeechUtterance: Codable, Hashable, Sendable {
    public struct Hypothesis: Codable, Hashable, Sendable {
        public struct Segment: Codable, Hashable, Sendable {
            public let text: String
            public let timestamp: TimeInterval
            public let duration: TimeInterval
            public let confidence: Float
            public let alternatives: [String]
        }
        public let text: String
        public let segments: [Segment]
    }
    public let text: String
    /// The person's submitted wording; recognition hypotheses remain original.
    public var correctedText: String?
    public var correctionReferences: [String]?
    public let isFinal: Bool
    public let hypotheses: [Hypothesis]
    /// Non-nil when the original remains with another device's chat attachment.
    public var audioReference: String?

    public init(_ result: SFSpeechRecognitionResult) {
        text = result.bestTranscription.formattedString
        isFinal = result.isFinal
        hypotheses = result.transcriptions.map { transcription in
            Hypothesis(text: transcription.formattedString, segments: transcription.segments.map {
                .init(text: $0.substring, timestamp: $0.timestamp, duration: $0.duration,
                      confidence: $0.confidence, alternatives: $0.alternativeSubstrings)
            })
        }
    }

    public var face: String { "Transcript: \(correctedText ?? text)" }

    /// What she reads of a voice message: the transcript and the recognizer's
    /// doubt (the words it was unsure of, with what else they may have been).
    /// The full recognition record stays on the attachment; every word's
    /// timing across every hypothesis was ~60K tokens for a one-minute note.
    public func evidence(audioReference: String) throws -> String {
        var lines = ["[Voice message · audio: \(self.audioReference ?? audioReference)]", face]
        if let correctedText, correctedText != text { lines.append("Recognized as: \(text)") }
        let unsure = (hypotheses.first?.segments ?? []).filter { $0.confidence > 0 && $0.confidence < 0.5 }.prefix(24).map { segment in
            "\(segment.text) (\(String(format: "%.2f", segment.confidence))"
                + (segment.alternatives.isEmpty ? ")" : "; or " + segment.alternatives.prefix(3).joined(separator: ", ") + ")")
        }
        if !unsure.isEmpty { lines.append("Unsure words (confidence as reported): " + unsure.joined(separator: ", ")) }
        return lines.joined(separator: "\n")
    }

    /// One user-initiated capture. The attachment owner takes the bytes; abandoned
    /// and failed captures remove their temporary audio when released.
    public final class Recording: @unchecked Sendable {
        private let lock = NSLock()
        private let url: URL
        private var file: AVAudioFile?

        public init(format: AVAudioFormat) throws {
            url = FileManager.default.temporaryDirectory.appendingPathComponent("\(UUID().uuidString).caf")
            file = try AVAudioFile(forWriting: url, settings: format.settings,
                                   commonFormat: format.commonFormat, interleaved: format.isInterleaved)
        }

        public func append(_ buffer: AVAudioPCMBuffer) throws {
            try lock.withLock {
                guard let file else { throw CocoaError(.fileWriteUnknown) }
                try file.write(from: buffer)
            }
        }

        public func finish(utterance: SpeechUtterance) throws -> MultimodalAttachment {
            let bytes = try lock.withLock {
                file = nil
                return try Data(contentsOf: url)
            }
            return MultimodalAttachment(type: "audio", base64: bytes.base64EncodedString(),
                mime: "audio/x-caf", name: "voice.caf", byteSize: bytes.count, utterance: utterance)
        }

        deinit { try? FileManager.default.removeItem(at: url) }
    }
}
