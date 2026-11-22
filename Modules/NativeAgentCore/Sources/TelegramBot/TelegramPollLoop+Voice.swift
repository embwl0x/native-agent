import Foundation
import NativeAgentShared
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
            "at": .string(NativeTimestampFormat.fractionalZulu(Date())),
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
        do {
            try await appendJSONLCapped(
                .object(row),
                to: telegramDir.appendingPathComponent("receipts.jsonl"),
                maxLines: JSONLLineCaps.telegramReceipts,
                logLabel: "TelegramPollLoop.receipts"
            )
        } catch {
            await recordError(context: "voice_receipt_write", error: String(describing: error), update: update, message: message)
        }
    }

    /// Plain words first, what to do next; the raw cause only at the end, in parentheses.
    static func voiceTranscriptionNotice(for error: Error) -> String {
        let cause = TurnSecretRedactor.redactText(error.localizedDescription)
            .trimmingCharacters(in: CharacterSet(charactersIn: ". \n"))
        switch error {
        case is CancellationError:
            return "Voice transcription was cancelled. No transcript was confirmed; no further action is needed for this attempt."
        case TelegramMediaDownloadError.oversized(let bytes, let cap):
            return "This voice note is too big to transcribe (\(bytes) bytes; the limit is \(cap)). Send a shorter note in this conversation."
        case TelegramVoiceTranscriptionError.speechPermissionDenied(let state):
            if state == "not determined" {
                return "Speech Recognition has not been allowed on the Mac yet, so this voice note was not transcribed. "
                    + "In Telegram setup, choose Set up Telegram voice and approve Speech Recognition."
            }
            return """
                Speech Recognition is turned off for NativeAgent on the Mac, so this voice note was not transcribed. Allow NativeAgent in \
                System Settings → Privacy & Security → Speech Recognition; a restricted grant needs the Mac administrator.
                """
        case TelegramVoiceTranscriptionError.speechUnavailable:
            return "\(cause). Check the recognition language and service availability in macOS Dictation settings."
        case TelegramVoiceTranscriptionError.conversionFailed:
            return "\(cause). Send M4A, MP3 or WAV audio in this conversation."
        case TelegramVoiceTranscriptionError.malformedResponse:
            return "No words could be made out in that voice note. Type the message in this conversation."
        case TelegramVoiceTranscriptionError.speechRecognitionFailed(let detail):
            let description = detail.lowercased()
            if description.contains("dictation") {
                return "I can't hear voice notes yet: turn on Dictation on the Mac (System Settings → Keyboard → Dictation), or send it as text."
            }
            if description.contains("timed out") {
                return "Transcribing the voice note timed out. No transcript was confirmed; type the message in this conversation. (\(cause))"
            }
        default: break
        }
        return "The voice note could not be transcribed. Type the message in this conversation. (\(cause))"
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
                sizeBytes: (obj["file_size"]?.integerValue.flatMap(Int.init(exactly:)) ?? obj["file_size"]?.stringValue.flatMap(Int.init)),
                bytes: nil,
                captureFilename: nil
            )
        }
        return nil
    }
}
