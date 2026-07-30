import Foundation
import NativeAgentCore
import PersistenceCore

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
        let description = [
            (error as? LocalizedError)?.errorDescription,
            String(describing: error)
        ]
        .compactMap { $0 }
        .joined(separator: " ")
        .lowercased()
        if description.contains("notconfigured") || description.contains("no openai platform key") {
            return "(I got your voice note, but Whisper transcription needs an OpenAI platform key.)"
        }
        if description.contains("siri and dictation") || description.contains("dictation") {
            return "(I got your voice note, but macOS Siri/Dictation is blocking Apple Speech. I retried the non-on-device path; if this keeps happening, enable Dictation in System Settings.)"
        }
        if description.contains("speech recognition permission denied") {
            return "(I got your voice note, but macOS Speech Recognition permission is not approved for NativeAgent yet.)"
        }
        if description.contains("apple speech unavailable") {
            return "(I got your voice note, but Apple Speech is not available on this Mac right now.)"
        }
        if description.contains("ogg/opus") || description.contains("ffmpeg") || description.contains("audio conversion failed") {
            return "(I got your voice note, but I could not convert Telegram's audio format for Apple Speech.)"
        }
        if description.contains("oversized") {
            return "(I got your voice note, but it is too large for the Telegram voice transcription limit.)"
        }
        return "(I got your voice note, but transcription failed before I could read it.)"
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

