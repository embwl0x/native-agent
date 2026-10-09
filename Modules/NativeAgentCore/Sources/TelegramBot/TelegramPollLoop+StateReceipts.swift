import FeedPolicy
import CryptoKit
import Foundation
import NativeAgentCore
import PersistenceCore

extension TelegramPollLoop {
    static func botStorageIdentity(_ token: String) -> String {
        let id = String(token.prefix { $0 != ":" })
        // Invalid credentials never become a path component.
        return id.allSatisfy({ $0.isASCII && $0.isNumber }) && !id.isEmpty
            ? id : "invalid"
    }

    func prepareBotIngressStorage() async throws {
        guard let id = Int64(botIdentity), id > 0, token.contains(":") else {
            throw TelegramOffsetCursorError.malformed
        }
        let store = SwiftNativePersistenceCore()
        // The saved bot ID survives token rotation and does not depend on a
        // private chat ever needing the optional username cache.
        try await store.withFileLock(legacyOffsetURL) {
            guard !FileManager.default.fileExists(atPath: offsetURL.path) else { return }
            let legacyInbox = TelegramUpdateInbox(offsetURL: legacyOffsetURL)
            guard FileManager.default.fileExists(atPath: legacyOffsetURL.path)
                    || FileManager.default.fileExists(atPath: legacyInbox.directory.path) else { return }
            let state = try await store.readJSON(telegramDir.appendingPathComponent("state.json"), ifMissing: .object([:]))
            guard case .object(let root) = state else {
                throw TelegramBotError.underlying("Legacy Telegram inbox ownership unavailable: state.json must be an object; polling paused.")
            }
            let savedIdentity: String?
            // Only the previous poller's state can attribute legacy work.
            // Current credentials say nothing about who received that inbox.
            if case .object(let menu)? = root["commandMenu"], let identity = _tgJSONString(menu["botIdentity"]) {
                savedIdentity = identity
            } else {
                savedIdentity = nil
            }
            // A matching old cache can still attribute storage for callers
            // without saved configuration. Never bypass a conflicting saved ID.
            let ownsLegacy = savedIdentity.map { $0 == String(id) }
                ?? (_tgJSONString(root["botUsernameTokenFingerprint"]) == Self.botTokenFingerprint(token))
            guard ownsLegacy else {
                throw TelegramBotError.underlying("Legacy Telegram inbox ownership unresolved for this bot; cursor and inbox preserved, polling paused. Restore historical bot identity evidence before retrying.")
            }
            let inbox = TelegramUpdateInbox(offsetURL: offsetURL)
            try await store.withFileLock(legacyInbox.directory.appendingPathComponent("claims_index.json")) {
                if FileManager.default.fileExists(atPath: legacyInbox.directory.path) {
                    let manager = FileManager.default
                    if manager.fileExists(atPath: inbox.directory.path) {
                        guard manager.contentsEqual(atPath: legacyInbox.directory.path, andPath: inbox.directory.path) else {
                            throw TelegramBotError.underlying("Legacy Telegram inbox migration is incomplete; cursor and both inboxes preserved, polling paused.")
                        }
                        _ = try await inbox.snapshots()
                    } else {
                        let staged = TelegramUpdateInbox(offsetURL: offsetURL.deletingLastPathComponent()
                            .appendingPathComponent(".migration-\(UUID().uuidString)"))
                        try manager.createDirectory(at: inbox.directory.deletingLastPathComponent(), withIntermediateDirectories: true)
                        defer { try? manager.removeItem(at: staged.directory) }
                        try manager.copyItem(at: legacyInbox.directory, to: staged.directory)
                        _ = try await staged.snapshots()
                        guard manager.contentsEqual(atPath: legacyInbox.directory.path, andPath: staged.directory.path) else {
                            throw TelegramBotError.underlying("Legacy Telegram inbox copy could not be verified; polling paused.")
                        }
                        try manager.moveItem(at: staged.directory, to: inbox.directory)
                    }
                }
                let offset = try TelegramOffsetCursor(fileURL: legacyOffsetURL).load()
                _ = try await TelegramOffsetCursor(fileURL: offsetURL).advance(to: offset)
            }
        }
    }

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
        do {
            try await store.withFileLock(path) {
                let current = try await store.readJSON(path, ifMissing: .object([:]))
                guard case .object(var obj) = current else {
                    throw TelegramUpdateInboxError.malformedClaim("state.json")
                }
                guard patch.contains(where: { obj[$0.key] != $0.value }) else { return }
                for (key, value) in patch { obj[key] = value }
                try await store.writeJSON(.object(obj), to: path)
            }
        } catch {
            // Never write over a state file that did not read back. Logged
            // here, not through recordError, which writes state.json too.
            await TelegramErrorLog.append(
                .object([
                    "id": .string(UUID().uuidString),
                    "at": .string(_tgNowString()),
                    "context": .string("state_read"),
                    "error": .string(String(describing: error)),
                ]),
                to: telegramDir.appendingPathComponent("errors.jsonl")
            )
            return
        }
    }

    /// A short, non-reversible fingerprint of the bot token. The token itself
    /// never reaches state.json; this only has to tell one token from another.
    static func botTokenFingerprint(_ token: String) -> String {
        String(
            SHA256.hash(data: Data(token.utf8))
                .map { String(format: "%02x", $0) }
                .joined()
                .prefix(16)
        )
    }

    /// How long a cached identity is trusted. A rename is rare, so an hourly
    /// getMe would be waste; a day is short enough that a stale @username
    /// self-corrects without anyone clearing state.
    static let botUsernameCacheSeconds: TimeInterval = 24 * 60 * 60

    /// 2026-09-06: this bot's own @username, cached in telegram/state.json.
    /// Named slash commands and group mention checks use this identity. A
    /// failed lookup leaves mention-required group messages unaddressed.
    ///
    /// 2026-09-06: the cache is keyed to the token's fingerprint and expires.
    /// Cached forever and untied to the token, a swapped token (or a rename)
    /// left this loop answering as the PREVIOUS bot — every command addressed
    /// to the new @username read as another bot's and was dropped.
    func resolveBotUsername() async -> String? {
        let store = SwiftNativePersistenceCore()
        let path = telegramDir.appendingPathComponent("state.json")
        let state: JSONValue
        do {
            state = try await store.readJSON(path, ifMissing: .object([:]))
        } catch {
            await recordError(context: "state_read", error: String(describing: error))
            return nil
        }
        let fingerprint = Self.botTokenFingerprint(token)
        if case .object(let root) = state,
           let cached = _tgJSONString(root["botUsername"]),
           !cached.isEmpty,
           _tgJSONString(root["botUsernameTokenFingerprint"]) == fingerprint,
           let cachedAt = _tgParseDate(_tgJSONString(root["botUsernameAt"])),
           Date().timeIntervalSince(cachedAt) < Self.botUsernameCacheSeconds {
            return cached
        }
        do {
            let username = try await Self.defaultFetchBotUsername(token)
            let trimmed = username.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty else { return nil }
            await writeStatePatch([
                "botUsername": .string(trimmed),
                "botUsernameTokenFingerprint": .string(fingerprint),
                "botUsernameAt": .string(_tgNowString()),
            ])
            return trimmed
        } catch {
            await recordError(context: "get_me", error: String(describing: error))
            return nil
        }
    }

    func syncCommandMenuIfNeeded() async {
        guard let syncCommandMenu else { return }
        let store = SwiftNativePersistenceCore()
        let path = telegramDir.appendingPathComponent("state.json")
        let state: JSONValue
        do {
            state = try await store.readJSON(path, ifMissing: .object([:]))
        } catch {
            await recordError(context: "state_read", error: String(describing: error))
            return
        }
        if case .object(let root) = state,
           case .object(let menu)? = root["commandMenu"],
           _tgJSONInt(menu["commandCount"]) == TelegramCommandRegistry.commands.count,
           _tgJSONString(menu["registryVersion"]) == TelegramCommandRegistry.version,
           _tgJSONString(menu["botIdentity"]) == botIdentity,
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
                    "botIdentity": .string(botIdentity),
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
                    "botIdentity": .string(botIdentity),
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

    func recordSeen(update: TelegramUpdate) async {
        await writeStatePatch([
            "lastSeenUpdateId": .int(Int64(update.updateId)),
            "lastSeenAt": .string(_tgNowString()),
            "lastError": .null,
        ])
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
        try? await appendJSONLCapped(
            .object(row),
            to: telegramDir.appendingPathComponent("blocked.jsonl"),
            using: SwiftNativePersistenceCore(),
            maxLines: JSONLLineCaps.telegramBlocked,
            logLabel: "TelegramPollLoop.blocked"
        )
    }

    /// A disabled bot can show the owner who messaged it without executing
    /// anything or granting the sender authority. Preserve the whole fetched
    /// page in the canonical inbox before advancing, so later checks progress
    /// and enabling the bot can still process those updates with admission.
    public static func discoverSenders(token: String, dataRoot: URL) async throws -> Int {
        let loop = TelegramPollLoop(token: token, revokeDriverControl: {}, dataRoot: dataRoot)
        try await loop.prepareBotIngressStorage()
        let store = SwiftNativePersistenceCore()
        return try await store.withFileLock(loop.offsetURL.appendingPathExtension("discovery")) {
            let cursor = TelegramOffsetCursor(fileURL: loop.offsetURL)
            let inbox = TelegramUpdateInbox(offsetURL: loop.offsetURL)
            let result = try await loop.bot.longPoll(token: token, offset: cursor.load(), timeoutSeconds: 0,
                                                     session: loop.longPollSession)
            var count = 0
            for update in result.updates {
                let claim = try await inbox.ensurePending(update)
                guard let message = claim.update.message else { continue }
                await loop.recordBlocked(reason: "setup_sender_not_admitted", update: claim.update,
                                         message: message, text: nil)
                count += 1
            }
            if let last = result.updates.map(\.updateId).max() {
                guard last < Int.max else { throw TelegramOffsetCursorError.invalidOffset }
                try await cursor.advance(to: last + 1)
            }
            return count
        }
    }

    /// Strip the bot token from any string headed for logs/state/UI.
    /// URLSession errors embed the failing URL — which contains
    /// /bot<TOKEN>/ — and recordError rows render verbatim in the Mac
    /// TelegramView errors panel (audit 2026-06-09, security-adjacent).
    static func _tgRedactToken(_ s: String) -> String {
        // Both the raw form (bot123:secret) and the percent-encoded form a
        // URLSession error can carry (bot123%3Asecret) — the encoded colon
        // slipped the original pattern (gpt-5.5 review, telegram-vision-in).
        guard let botRegex = try? NSRegularExpression(pattern: #"bot\d+(?::|%3[Aa])[A-Za-z0-9_\-]+"#),
              let bareRegex = try? NSRegularExpression(pattern: #"\b\d{6,}(?::|%3[Aa])[A-Za-z0-9_\-]+"#)
        else { return s }
        // ONE redaction vocabulary across every layer that scrubs a Telegram
        // token (this upstream scrub fires before TelegramRichMessage.sanitize's
        // typed regex, so an ad-hoc "<redacted>" here would shadow the typed
        // marker downstream and make evidence undiagnosable — 0.4.3 gauntlet).
        let botRedacted = botRegex.stringByReplacingMatches(
            in: s, range: NSRange(s.startIndex..., in: s), withTemplate: "[REDACTED_TELEGRAM_TOKEN]"
        )
        // Status, model, session and persona values can carry a token without
        // a URL's `bot` prefix. Treat the Bot API's numeric-id form as secret
        // in those assembled UI strings too.
        return bareRegex.stringByReplacingMatches(
            in: botRedacted,
            range: NSRange(botRedacted.startIndex..., in: botRedacted),
            withTemplate: "[REDACTED_TELEGRAM_TOKEN]"
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
        // Locked append with 5 MB rotation and one backup.
        await TelegramErrorLog.append(
            .object(row),
            to: telegramDir.appendingPathComponent("errors.jsonl")
        )
        await writeStatePatch([
            "lastError": .string("\(context): \(error)"),
        ])
    }

    /// Stop the ephemeral preview, then persist one system notice and receipt.
    func deliverTurnNotice(
        _ notice: String,
        delivery: TelegramAssistantDeliveryDriver,
        receiptKind: String,
        sendErrorContext: String,
        update: TelegramUpdate,
        message: TelegramMessage,
        text: String
    ) async {
        await delivery.stop()
        do {
            try await sendMessage(token, message.destination, notice)
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
    func persistOffset(_ nextOffset: Int, cursor: TelegramOffsetCursor) async -> Int? {
        do {
            return try await cursor.advance(to: nextOffset)
        } catch {
            FileHandle.standardError.write(Data("TelegramPollLoop: persist offset failed: \(Self._tgRedactToken(String(describing: error)))\n".utf8))
            await recordError(context: "persist_offset", error: String(describing: error))
            return nil
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
