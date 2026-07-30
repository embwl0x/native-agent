import Foundation
import NativeAgentCore
import PersistenceCore

extension TelegramPollLoop {
    static func inferDataRoot(from offsetURL: URL) -> URL {
        let parent = offsetURL.deletingLastPathComponent()
        if parent.lastPathComponent == "telegram" {
            return parent.deletingLastPathComponent()
        }
        return parent
    }

    var telegramDir: URL {
        dataRoot.appendingPathComponent("telegram", isDirectory: true)
    }

    func writeStatePatch(_ patch: [String: JSONValue]) async {
        let store = SwiftNativePersistenceCore()
        let path = telegramDir.appendingPathComponent("state.json")
        let current = await store.readJSON(path, defaultValue: .object([:]))
        var obj: [String: JSONValue]
        if case .object(let currentObj) = current {
            obj = currentObj
        } else {
            obj = [:]
        }
        for (key, value) in patch {
            obj[key] = value
        }
        try? await store.writeJSON(.object(obj), to: path)
    }

    func syncCommandMenuIfNeeded() async {
        guard let syncCommandMenu else { return }
        let store = SwiftNativePersistenceCore()
        let path = telegramDir.appendingPathComponent("state.json")
        let state = await store.readJSON(path, defaultValue: .object([:]))
        if case .object(let root) = state,
           case .object(let menu)? = root["commandMenu"],
           _tgJSONInt(menu["commandCount"]) == TelegramCommandRegistry.commands.count,
           _tgJSONString(menu["registryVersion"]) == TelegramCommandRegistry.version,
           _tgJSONString(menu["syncedAt"]) != nil {
            return
        }
        // U5 W-D: a failed setMyCommands used to re-attempt on EVERY tick
        // (every ~2s, forever). Gate re-attempts on the menu backoff window;
        // success resets the curve.
        guard await commandMenuBackoff.shouldAttempt() else { return }
        do {
            let status = try await syncCommandMenu(token, TelegramCommandRegistry.commands)
            await commandMenuBackoff.recordSuccess()
            await writeStatePatch([
                "commandMenu": .object([
                    "commandCount": .int(Int64(status.commandCount)),
                    "registryVersion": .string(status.registryVersion),
                    "syncedAt": .string(status.syncedAt),
                    "synced": .bool(true),
                    "lastSyncError": .null,
                ]),
            ])
        } catch {
            let retryDelay = await commandMenuBackoff.recordFailure()
            await writeStatePatch([
                "commandMenu": .object([
                    "commandCount": .int(Int64(TelegramCommandRegistry.commands.count)),
                    "registryVersion": .string(TelegramCommandRegistry.version),
                    "synced": .bool(false),
                    "lastAttemptAt": .string(_tgNowString()),
                    "lastSyncError": .string(Self._tgRedactToken(String(describing: error))),
                    "nextRetryDelaySeconds": .double(retryDelay),
                ]),
            ])
        }
    }

    func recordSeen(update: TelegramUpdate, message: TelegramMessage?) async {
        await writeStatePatch([
            "lastSeenUpdateId": .int(Int64(update.updateId)),
            "lastSeenAt": .string(_tgNowString()),
            "lastError": .null,
        ])
        _ = message
    }

    func recordBlocked(
        reason: String,
        update: TelegramUpdate,
        message: TelegramMessage?,
        text: String?
    ) async {
        let at = _tgNowString()
        var row: [String: JSONValue] = [
            "id": .string(UUID().uuidString),
            "at": .string(at),
            "reason": .string(reason),
            "updateId": .int(Int64(update.updateId)),
        ]
        if let message {
            row["chatId"] = .string(String(message.chatId))
            row["messageId"] = .int(Int64(message.messageId))
            if let userId = message.fromUserId {
                row["userId"] = .string(String(userId))
            }
        }
        if let preview = _tgPreview(text) {
            row["textPreview"] = .string(preview)
        }
        try? await SwiftNativePersistenceCore().appendJSONL(
            .object(row),
            to: telegramDir.appendingPathComponent("blocked.jsonl")
        )
    }

    /// Strip the bot token from any string headed for logs/state/UI.
    /// URLSession errors embed the failing URL — which contains
    /// /bot<TOKEN>/ — and recordError rows render verbatim in the Mac
    /// TelegramView errors panel (audit 2026-06-09, security-adjacent).
    static func _tgRedactToken(_ s: String) -> String {
        // Both the raw form (bot123:secret) and the percent-encoded form a
        // URLSession error can carry (bot123%3Asecret) — the encoded colon
        // slipped the original pattern (gpt-5.5 review, telegram-vision-in).
        guard let regex = try? NSRegularExpression(pattern: #"bot\d+(?::|%3[Aa])[A-Za-z0-9_\-]+"#) else { return s }
        return regex.stringByReplacingMatches(
            in: s, range: NSRange(s.startIndex..., in: s), withTemplate: "bot<redacted>"
        )
    }

    func recordError(
        context: String,
        error rawError: String,
        update: TelegramUpdate? = nil,
        message: TelegramMessage? = nil,
        text: String? = nil
    ) async {
        let error = Self._tgRedactToken(rawError)
        let at = _tgNowString()
        var row: [String: JSONValue] = [
            "id": .string(UUID().uuidString),
            "at": .string(at),
            "context": .string(context),
            "error": .string(error),
        ]
        if let update {
            row["updateId"] = .int(Int64(update.updateId))
        }
        if let message {
            row["chatId"] = .string(String(message.chatId))
            row["messageId"] = .int(Int64(message.messageId))
            if let userId = message.fromUserId {
                row["userId"] = .string(String(userId))
            }
        }
        if let preview = _tgPreview(text) {
            row["textPreview"] = .string(preview)
        }
        // U5 W-D: flock'd append with 5MB/.1-backup rotation (dedup_shadow
        // recipe). (receipts.jsonl — the other telegram log — is now line-capped
        // via appendJSONLCapped too; tightness round 2 P-M1.)
        await TelegramErrorLog.append(
            .object(row),
            to: telegramDir.appendingPathComponent("errors.jsonl")
        )
        await writeStatePatch([
            "lastError": .string("\(context): \(error)"),
        ])
    }

    /// Finish an otherwise silent turn with one visible Telegram notice.
    /// Prefer replacing an existing streaming draft; if no draft was ever
    /// created, send a new message. Both paths persist the same receipt.
    func deliverDraftOrSendNotice(
        _ notice: String,
        draft: TelegramDraftStreamer,
        receiptKind: String,
        sendErrorContext: String,
        update: TelegramUpdate,
        message: TelegramMessage,
        text: String
    ) async {
        if await draft.abortDelivering(notice: notice) {
            await recordReceipt(
                kind: receiptKind,
                update: update,
                message: message,
                text: text,
                reply: notice
            )
            return
        }
        do {
            try await sendMessage(token, message.chatId, notice)
            await recordReceipt(
                kind: receiptKind,
                update: update,
                message: message,
                text: text,
                reply: notice
            )
        } catch {
            await recordError(
                context: sendErrorContext,
                error: String(describing: error),
                update: update,
                message: message,
                text: text
            )
        }
    }

    @discardableResult
    func persistOffset(_ nextOffset: Int, store: SwiftNativePersistenceCore) async -> Bool {
        do {
            try await store.writeJSON(.object(["offset": .int(Int64(nextOffset))]), to: offsetURL)
            return true
        } catch {
            FileHandle.standardError.write(Data("TelegramPollLoop: persist offset failed: \(Self._tgRedactToken(String(describing: error)))\n".utf8))
            await recordError(context: "persist_offset", error: String(describing: error))
            return false
        }
    }

    func recordReceipt(
        kind: String,
        update: TelegramUpdate,
        message: TelegramMessage,
        text: String,
        reply: String
    ) async {
        let at = _tgNowString()
        var row: [String: JSONValue] = [
            "id": .string(UUID().uuidString),
            "at": .string(at),
            "kind": .string(kind),
            "chatId": .string(String(message.chatId)),
            "messageId": .int(Int64(message.messageId)),
            "updateId": .int(Int64(update.updateId)),
            "lastSeenUpdateId": .int(Int64(update.updateId)),
        ]
        if let userId = message.fromUserId {
            row["userId"] = .string(String(userId))
        }
        if let replyTo = message.replyTo {
            row["replyToMessageId"] = .int(Int64(replyTo.messageId))
            if let fromIsBot = replyTo.fromIsBot {
                row["replyToFromBot"] = .bool(fromIsBot)
            }
            if let preview = _tgPreview(replyTo.previewText) {
                row["replyToTextPreview"] = .string(preview)
            }
        }
        if let preview = _tgPreview(text) {
            row["textPreview"] = .string(preview)
        }
        if let preview = _tgPreview(reply) {
            row["replyPreview"] = .string(preview)
        }
        try? await appendJSONLCapped(
            .object(row),
            to: telegramDir.appendingPathComponent("receipts.jsonl"),
            using: SwiftNativePersistenceCore(),
            maxLines: JSONLLineCaps.telegramReceipts,
            logLabel: "TelegramPollLoop.receipts"
        )
        await writeStatePatch([
            "lastReplyAt": .string(at),
            "lastError": .null,
            "lastChatRetryError": .null,
            "lastChatRetryFailedAttempt": .null,
            "lastChatRetryNextAttempt": .null,
            "lastChatRetrySuppressUserAppend": .null,
        ])
    }
}
