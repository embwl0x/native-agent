import Foundation
import NativeAgentCore
import PersistenceCore
// Blueprint: | `TelegramPollLoop+Voice.swift` | `TelegramPollLoop`: `recordVoiceTranscription`, `voiceTranscriptionNotice`, `voiceAttachment` |

extension TelegramPollLoop {
    func recordVoiceTranscription(
        update: TelegramUpdate,
        message: TelegramMessage,
        attachment: TelegramMediaAttachment,
        transcription: TelegramVoiceTranscription
    ) async {
        var row: [String: JSONValue] = [
            "id": .string(UUID().uuidString),
            "at": .string(_tgNowString()),
            "kind": .string("voice_transcription"),
            "chatId": .string(String(message.chatId)),
            "messageId": .int(Int64(message.messageId)),
            "updateId": .int(Int64(update.updateId)),
            "fileId": .string(attachment.fileId),
            "backend": .string(transcription.backend),
            "model": .string(transcription.model),
        ]
        if let filename = attachment.captureFilename {
            row["filename"] = .string(filename)
        }
        if let size = attachment.sizeBytes {
            row["sizeBytes"] = .int(Int64(size))
        }
        if let latency = transcription.latencyMilliseconds {
            row["latencyMs"] = .int(Int64(latency))
        }
        if let preview = _tgPreview(transcription.text) {
            row["transcriptPreview"] = .string(preview)
        }
        try? await appendJSONLCapped(
            .object(row),
            to: telegramDir.appendingPathComponent("receipts.jsonl"),
            using: SwiftNativePersistenceCore(),
            maxLines: JSONLLineCaps.telegramReceipts,
            logLabel: "TelegramPollLoop.receipts"
        )
    }

    static func voiceTranscriptionNotice(for error: Error) -> String {
        let cause = _tgRedactToken(error.localizedDescription)
        if error is CancellationError {
            return "voice_cancelled: Voice transcription was cancelled. No transcript was confirmed; no further action is needed for this attempt."
        }
        if case TelegramMediaDownloadError.oversized(let bytes, let cap) = error {
            return "voice_oversized: Voice note is \(bytes) bytes; limit \(cap). Send a shorter note in this conversation."
        }
        if case TelegramVoiceTranscriptionError.speechPermissionDenied(let state) = error, state == "not determined" {
            return "voice_permission_required: \(cause). In Telegram setup, choose Set up Telegram voice and approve Speech Recognition."
        }
        let description = [
            (error as? LocalizedError)?.errorDescription,
            String(describing: error)
        ]
        .compactMap { $0 }
        .joined(separator: " ")
        .lowercased()
        if description.contains("siri and dictation") || description.contains("dictation") {
            return "voice_dictation_blocked: \(cause). Enable Dictation in System Settings → Keyboard → Dictation."
        }
        if description.contains("speech recognition permission denied") {
            return "voice_permission_denied: \(cause). Allow NativeAgent in System Settings → Privacy & Security → Speech Recognition; a restricted grant needs the Mac administrator."
        }
        if description.contains("apple speech unavailable") {
            return "voice_speech_unavailable: \(cause). Check the recognition language and service availability in macOS Dictation settings."
        }
        if description.contains("ogg/opus") || description.contains("ffmpeg") || description.contains("audio conversion failed") {
            return "voice_conversion_failed: \(cause). Send M4A, MP3 or WAV audio in this conversation."
        }
        if description.contains("timed out") {
            return "voice_timeout: \(cause). No transcript was confirmed; type the message in this conversation."
        }
        if description.contains("oversized") {
            return "voice_oversized: \(cause). Send a shorter note within the voice byte limit shown in Telegram setup."
        }
        return "voice_transcription_failed: \(cause). Type the message in this conversation."
    }

    static func voiceAttachment(from message: TelegramMessage) -> TelegramMediaAttachment? {
        guard case .object(let extras)? = message.extras else { return nil }
        let pairs: [(String, JSONValue?)] = [
            ("voice", extras["voice"]),
            ("audio", extras["audio"]),
        ]
        for (kind, raw) in pairs {
            guard case .object(let obj)? = raw,
                  case .string(let fileId)? = obj["file_id"],
                  !fileId.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
                continue
            }
            let mime: String? = {
                if case .string(let value)? = obj["mime_type"],
                   !value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                    return value
                }
                return nil
            }()
            return TelegramMediaAttachment(
                kind: kind,
                fileId: fileId,
                mimeType: mime,
                sizeBytes: _tgJSONInt(obj["file_size"]),
                bytes: nil,
                captureFilename: nil
            )
        }
        return nil
    }
}
