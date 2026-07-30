import Foundation
import NativeAgentCore
import PersistenceCore

extension TelegramPollLoop {
    // MARK: - Inbound photo / image ingestion (telegram-vision-in)
    //
    // Recovered from the daemon-era telegram_photo_attachment /
    // telegram_photo_max_bytes / download_telegram_photo_as_attachment trio
    // that died with the
    // daemon. Ported to the Swift poll path: a photo a user sends into Telegram
    // is downloaded via the existing two-stage TelegramMediaDownloader, then
    // injected as a native image attachment on the SAME chat turn the Mac UI
    // already consumes (MultimodalAttachment {type:"image", base64, mime,
    // byteSize}). The app-layer handler does the TelegramMediaAttachment ->
    // MultimodalAttachment conversion so this module stays free of a
    // ChatOrchestration dependency.

    /// Default cap for an inbound image download. Telegram bot photos top out
    /// around a few MB, but a user can "send as file" an arbitrarily large
    /// image document. 10MB mirrors the daemon-era clamp to
    /// MAX_CHAT_ATTACHMENT_BYTES (the chat-attachment validation ceiling on the
    /// Mac path): anything larger would download here then be rejected
    /// downstream as a bad attachment, so the two stages must agree. The poll
    /// loop refuses a getFile-reported oversize BEFORE any byte transfer.
    public static let defaultPhotoMaxBytes = 10 * 1024 * 1024

    /// Extract an inbound image descriptor from a message, or nil for "no image
    /// here". Telegram sends a `photo` as a LIST of size variants
    /// (smallest..largest); pick the largest by width*height so the model sees
    /// the best resolution. Also accept an `image/*` `document` — the
    /// uncompressed "send as file" path. Both shapes live in `message.extras`
    /// (neither `photo` nor `document` is a TelegramMessage known key).
    static func photoAttachment(from message: TelegramMessage) -> TelegramMediaAttachment? {
        guard case .object(let extras)? = message.extras else { return nil }

        // photo: list of variants -> largest by pixel count
        if case .array(let variants)? = extras["photo"], !variants.isEmpty {
            var best: [String: JSONValue]?
            var bestPixels = -1
            for variant in variants {
                guard case .object(let obj) = variant,
                      case .string(let fileId)? = obj["file_id"],
                      !fileId.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                else { continue }
                let w = _tgJSONInt(obj["width"]) ?? 0
                let h = _tgJSONInt(obj["height"]) ?? 0
                let px = w * h
                if px >= bestPixels {
                    bestPixels = px
                    best = obj
                }
            }
            if let best, case .string(let fileId)? = best["file_id"] {
                return TelegramMediaAttachment(
                    kind: "photo",
                    fileId: fileId,
                    mimeType: nil,   // photos have no mime; resolved from file_path suffix post-download
                    sizeBytes: _tgJSONInt(best["file_size"]),
                    bytes: nil,
                    captureFilename: nil
                )
            }
        }

        // image/* document (uncompressed send-as-file)
        if case .object(let doc)? = extras["document"],
           case .string(let fileId)? = doc["file_id"],
           !fileId.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            let mime = (_tgJSONString(doc["mime_type"]) ?? "").lowercased()
            if mime.hasPrefix("image/") {
                return TelegramMediaAttachment(
                    kind: "document",
                    fileId: fileId,
                    mimeType: mime,
                    sizeBytes: _tgJSONInt(doc["file_size"]),
                    bytes: nil,
                    captureFilename: nil
                )
            }
        }

        return nil
    }

    /// Caption text for a media-only send (a photo/document with no `text`).
    /// Telegram puts it in `message.extras["caption"]` — TelegramMessage.text
    /// only reads `text`, so without this an image-with-caption loses the
    /// caption entirely.
    static func caption(from message: TelegramMessage) -> String? {
        guard case .object(let extras)? = message.extras else { return nil }
        guard case .string(let cap)? = extras["caption"] else { return nil }
        let trimmed = cap.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }

    /// Resolve an image mime from the downloaded file's path suffix (Telegram
    /// `file_path` carries the extension; photos themselves have no mime). Used
    /// when the descriptor's mimeType is nil (the `photo` list path).
    static func imageMime(forFilename name: String?, fallbackMime: String?) -> String {
        if let fallbackMime, fallbackMime.lowercased().hasPrefix("image/") {
            return fallbackMime.lowercased()
        }
        let suffix = (name.map { URL(fileURLWithPath: $0).pathExtension } ?? "").lowercased()
        switch suffix {
        case "jpg", "jpeg": return "image/jpeg"
        case "png": return "image/png"
        case "gif": return "image/gif"
        case "webp": return "image/webp"
        case "bmp": return "image/bmp"
        case "heic": return "image/heic"
        default: return "image/jpeg"
        }
    }

    /// Emit a `telegram.attachment_dropped` trace to traces/events.jsonl when an
    /// inbound attachment exists but couldn't be processed (download failure,
    /// oversize, unsupported). Mirrors emitMemoryCommitTrace's shape + the
    /// shared appendJSONLCapped cap discipline. The reason is token-redacted so
    /// the bot token can never leak into a trace; raw image bytes are NEVER
    /// written (only kind + byteSize + reason). This is the tripwire half — the
    /// user-visible reply is sent separately by the caller.
    func emitAttachmentDroppedTrace(
        kind: String,
        reason: String,
        chatId: Int,
        updateId: Int
    ) async {
        let tracesPath = dataRoot
            .appendingPathComponent("traces", isDirectory: true)
            .appendingPathComponent("events.jsonl")
        let row: JSONValue = .object([
            "id": .string(UUID().uuidString.lowercased()),
            "kind": .string("telegram.attachment_dropped"),
            "title": .string("telegram_attachment_dropped"),
            "status": .string("error"),
            "payload": .object([
                "attachmentKind": .string(kind),
                "reason": .string(Self._tgRedactToken(reason)),
                "chatId": .string(String(chatId)),
                "updateId": .int(Int64(updateId)),
                "surface": .string("telegram"),
            ]),
            "createdAt": .string(_tgNowString()),
        ])
        let persistence = SwiftNativePersistenceCore()
        do {
            try await appendJSONLCapped(
                row, to: tracesPath, using: persistence,
                logLabel: "TelegramPollLoop.attachmentDropped"
            )
        } catch {
            FileHandle.standardError.write(
                Data("TelegramPollLoop: telegram.attachment_dropped trace append failed: \(Self._tgRedactToken(String(describing: error)))\n".utf8)
            )
        }
    }

    /// Build a user-visible "couldn't process that image" reply. The reason is
    /// token-redacted and trimmed; never echoes raw bytes or the token.
    static func attachmentDroppedNotice(reason: String) -> String {
        let redacted = _tgRedactToken(reason).trimmingCharacters(in: .whitespacesAndNewlines)
        let short = redacted.count > 180 ? String(redacted.prefix(180)) + "..." : redacted
        if short.isEmpty {
            return "(I couldn't process that image — please try resending it.)"
        }
        return "(I couldn't process that image: \(short). Try resending it.)"
    }
}

