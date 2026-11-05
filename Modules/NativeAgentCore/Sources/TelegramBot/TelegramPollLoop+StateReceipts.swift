import CryptoKit
import Foundation
import NativeAgentShared
import NativeAgentCore
import PersistenceCore
// Blueprint: | `TelegramPollLoop+StateReceipts.swift` | `TelegramPollLoop`: sole checked state.json reader and mutation owner (`readState`, `mutateState`) for polling and status consumers; only missing state is empty, and unreadable/non-object state fails with a dedicated telegram/state.json error and is never overwritten; bot ingress validates its current identity without global-storage migration; `inferDataRoot`, `writeStatePatch`, `botTokenFingerprint`, `discoverSenders`; bounded setup pages persist in the canonical inbox before the bot cursor advances |

private struct TelegramStateReadError: LocalizedError, CustomStringConvertible {
    let description = "telegram_state_unavailable: telegram/state.json is unreadable or is not a JSON object. Its contents were preserved."
    var errorDescription: String? { description }
}

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
        do {
            try await Self.mutateState(dataRoot: dataRoot) { obj in
                for (key, value) in patch { obj[key] = value }
            }
        } catch {
            // Never write over a state file that did not read back. Logged here, not through recordError, which writes state.json too.
            await appendErrorLog(
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

    /// Sole checked state.json reader for polling and management diagnostics. Only missing means empty; unreadable or non-object state is unavailable.
    /// Local/off-disk backup, support state snapshot, phone status projection; no production export. PrivacyMap: telegram.
    public static func readState(dataRoot: URL) async throws -> [String: JSONValue] {
        let current: JSONValue
        do {
            current = try await SwiftNativePersistenceCore.readJSON(
                dataRoot.appendingPathComponent("telegram/state.json"), ifMissing: .object([:]))
        } catch { throw TelegramStateReadError() }
        guard case .object(let object) = current else { throw TelegramStateReadError() }
        return object
    }

    /// Sole locked mutation owner; the checked read must succeed before editing.
    public static func mutateState<Result: Sendable>(
        dataRoot: URL, _ update: @Sendable (inout [String: JSONValue]) -> Result
    ) async throws -> Result {
        let path = dataRoot.appendingPathComponent("telegram/state.json")
        return try await SwiftNativePersistenceCore.withFileLock(path) {
            let current = try await Self.readState(dataRoot: dataRoot)
            var object = current
            let result = update(&object)
            if current != object { try await SwiftNativePersistenceCore.writeJSON(.object(object), to: path) }
            return result
        }
    }

    /// A short, non-reversible fingerprint of the bot token. The token itself never reaches state.json; this only has to tell one token from another.
    static func botTokenFingerprint(_ token: String) -> String {
        String(
            SHA256.hash(data: Data(token.utf8))
                .map { String(format: "%02x", $0) }
                .joined()
                .prefix(16)
        )
    }

    /// A day-long username cache corrects renames without wasteful hourly getMe requests.
    static let botUsernameCacheSeconds: TimeInterval = 24 * 60 * 60

    /// Cache bot usernames by token fingerprint and expiry; failed lookups leave required mentions unaddressed.
    func resolveBotUsername() async -> String? {
        let root: [String: JSONValue]
        do {
            root = try await Self.readState(dataRoot: dataRoot)
        } catch {
            await recordError(context: "state_read", error: String(describing: error))
            return nil
        }
        let fingerprint = Self.botTokenFingerprint(token)
        if let cached = root["botUsername"]?.stringValue,
           !cached.isEmpty,
           root["botUsernameTokenFingerprint"]?.stringValue == fingerprint,
           let cachedAt = _tgParseDate(root["botUsernameAt"]?.stringValue),
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
        let root: [String: JSONValue]
        do {
            root = try await Self.readState(dataRoot: dataRoot)
        } catch {
            await recordError(context: "state_read", error: String(describing: error))
            return
        }
        // Gate command-menu attempts on backoff; success resets the curve.
        guard await commandMenuBackoff.shouldAttempt() else { return }
        do {
            let projection = try await bot.commandProjection()
            if case .object(let menu)? = root["commandMenu"], menu["synced"] == .bool(true),
               (menu["commandCount"]?.integerValue.flatMap(Int.init(exactly:)) ?? menu["commandCount"]?.stringValue.flatMap(
                   Int.init)) == projection.commands.count,
               menu["registryVersion"]?.stringValue == projection.version,
               menu["botIdentity"]?.stringValue == botIdentity,
               menu["syncedAt"]?.stringValue != nil {
                return
            }
            let status = try await syncCommandMenu(token, projection.commands)
            await commandMenuBackoff.recordSuccess()
            await writeStatePatch([
                "commandMenu": .object([
                    "botIdentity": .string(botIdentity),
                    "commandCount": .int(Int64(status.commandCount)),
                    "registryVersion": .string(projection.version),
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
                    "commandCount": .int(Int64(TelegramCommandRegistry.menuCommandNames.count)),
                    "registryVersion": .string(TelegramCommandRegistry.version),
                    "synced": .bool(false),
                    "lastAttemptAt": .string(_tgNowString()),
                    "lastSyncError": .string(TurnSecretRedactor.redactText(String(describing: error))),
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
            maxLines: JSONLLineCaps.telegramBlocked,
            logLabel: "TelegramPollLoop.blocked"
        )
    }

    /// Retain setup pages before advancing so enabling later still admits them normally; discovery never grants sender authority.
    public static func discoverSenders(token: String, dataRoot: URL) async throws -> Int {
        let loop = TelegramPollLoop(token: token, revokeDriverControl: {}, dataRoot: dataRoot)
        try await loop.prepareBotIngressStorage()
        return try await SwiftNativePersistenceCore.withFileLock(loop.offsetURL.appendingPathExtension("discovery")) {
            let cursor = TelegramOffsetCursor(fileURL: loop.offsetURL)
            let inbox = TelegramUpdateInbox(offsetURL: loop.offsetURL, dataRoot: loop.dataRoot)
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

    func recordError(
        context: String,
        error rawError: String,
        update: TelegramUpdate? = nil,
        message: TelegramMessage? = nil,
        text: String? = nil
    ) async {
        let error = TurnSecretRedactor.redactText(rawError)
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
        await appendErrorLog(
            .object(row),
            to: telegramDir.appendingPathComponent("errors.jsonl")
        )
        await writeStatePatch([
            "lastError": .string("\(context): \(error)"),
        ])
    }

    /// Polling reports log-storage failure without attempting another writer.
    private func appendErrorLog(_ row: JSONValue, to path: URL) async {
        do { try await TelegramErrorLog.append(row, to: path) }
        catch {
            // No second write mechanism: polling reports the storage cause here.
            FileHandle.standardError.write(Data("Telegram error log unavailable at \(path.path): \(error.localizedDescription)\n".utf8))
        }
    }

    /// The update's assistant-delivery journal owns its one failure notice.
    func deliverTurnNotice(
        _ notice: String,
        delivery: TelegramAssistantDeliveryDriver,
        receiptKind: String,
        sendErrorContext: String,
        update: TelegramUpdate,
        message: TelegramMessage,
        text: String
    ) async {
        do {
            let inbox = TelegramUpdateInbox(offsetURL: offsetURL, dataRoot: dataRoot)
            let claim = try inbox.claim(updateId: update.updateId)
            _ = try await inbox.recordAssistantDelivery(updateId: update.updateId,
                delivery: claim.assistantDelivery, failedBeforeAnswer: true)
            switch await delivery.finalize(reply: notice) {
            case .delivered:
                if let session = claim.assistantSessionId, let run = claim.assistantRunId {
                    try await settleReplyCheckpoint(sessionId: session, runId: run, verdict: "failed_before_answer")
                }
                await recordReceipt(kind: receiptKind, update: update, message: message, text: text, reply: notice)
            case .failed(let reason), .outcomeUnknown(let reason):
                await recordError(context: sendErrorContext, error: reason, update: update, message: message, text: text)
            case .held: break
            }
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
            FileHandle.standardError.write(Data("TelegramPollLoop: persist offset failed: \(TurnSecretRedactor.redactText(String(describing: error)))\n".utf8))
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
            maxLines: JSONLLineCaps.telegramReceipts,
            logLabel: "TelegramPollLoop.receipts"
        )
        await writeStatePatch([
            "lastReplyAt": .string(at),
            "lastError": .null,
        ])
    }
}
