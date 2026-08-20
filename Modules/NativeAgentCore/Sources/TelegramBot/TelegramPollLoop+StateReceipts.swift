import Foundation
import NativeAgentCore
import PersistenceCore

enum TelegramUpdateClaimPhase: String, Sendable, Equatable {
    case pending
    case processing
    case completed
    case outcomeUnknown = "outcome_unknown"
}

struct TelegramUpdateClaim: Sendable, Equatable {
    let updateId: Int
    let update: TelegramUpdate
    let phase: TelegramUpdateClaimPhase
    let claimedAt: String
    let updatedAt: String
}

enum TelegramUpdateInboxError: Error, LocalizedError, Equatable {
    case malformedClaim(String)
    case mismatchedUpdateId(expected: Int, actual: Int)

    var errorDescription: String? {
        switch self {
        case .malformedClaim(let name):
            return "Telegram durable inbox claim is malformed: \(name)"
        case .mismatchedUpdateId(let expected, let actual):
            return "Telegram durable inbox claim id mismatch: expected \(expected), got \(actual)"
        }
    }
}

/// Telegram-owned durable admission state. A fetched update is written here
/// before its upstream offset advances. Pending work can therefore survive a
/// crash after acknowledgement; a prior-run `processing` claim is quarantined
/// as outcome-unknown rather than replaying possibly-effecting work.
struct TelegramUpdateInbox: Sendable {
    let directory: URL
    private let persistence = SwiftNativePersistenceCore()

    init(offsetURL: URL) {
        let parent = offsetURL.deletingLastPathComponent()
        if parent.lastPathComponent == "telegram" {
            self.directory = parent.appendingPathComponent("update_inbox", isDirectory: true)
        } else {
            self.directory = parent.appendingPathComponent(
                offsetURL.lastPathComponent + ".inbox",
                isDirectory: true
            )
        }
    }

    func snapshots() async throws -> [TelegramUpdateClaim] {
        guard FileManager.default.fileExists(atPath: directory.path) else { return [] }
        let urls = try FileManager.default.contentsOfDirectory(
            at: directory,
            includingPropertiesForKeys: [.isRegularFileKey, .isSymbolicLinkKey],
            options: [.skipsHiddenFiles]
        )
        var claims: [TelegramUpdateClaim] = []
        var seenUpdateIDs: Set<Int> = []
        for url in urls where url.pathExtension == "json" {
            let values = try url.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey])
            guard values.isRegularFile == true, values.isSymbolicLink != true else {
                throw TelegramUpdateInboxError.malformedClaim(url.lastPathComponent)
            }
            let claim = try decodeClaim(at: url)
            guard url.deletingPathExtension().lastPathComponent == String(claim.updateId),
                  seenUpdateIDs.insert(claim.updateId).inserted else {
                throw TelegramUpdateInboxError.malformedClaim(url.lastPathComponent)
            }
            claims.append(claim)
        }
        return claims.sorted { $0.updateId < $1.updateId }
    }

    @discardableResult
    func ensurePending(_ update: TelegramUpdate) async throws -> TelegramUpdateClaim {
        let path = claimPath(updateId: update.updateId)
        return try await persistence.withFileLock(path) {
            if FileManager.default.fileExists(atPath: path.path) {
                return try decodeClaim(at: path)
            }
            let now = _tgNowString()
            let claim = TelegramUpdateClaim(
                updateId: update.updateId,
                update: update,
                phase: .pending,
                claimedAt: now,
                updatedAt: now
            )
            try await write(claim, to: path)
            return claim
        }
    }

    @discardableResult
    func transition(
        updateId: Int,
        from allowed: Set<TelegramUpdateClaimPhase>,
        to phase: TelegramUpdateClaimPhase
    ) async throws -> TelegramUpdateClaim {
        let path = claimPath(updateId: updateId)
        return try await persistence.withFileLock(path) {
            let current = try decodeClaim(at: path)
            guard allowed.contains(current.phase) else { return current }
            let next = TelegramUpdateClaim(
                updateId: current.updateId,
                update: current.update,
                phase: phase,
                claimedAt: current.claimedAt,
                updatedAt: _tgNowString()
            )
            try await write(next, to: path)
            return next
        }
    }

    func pruneTerminalClaims(keepingNewest keep: Int = 256) async {
        guard let claims = try? await snapshots() else { return }
        let terminal = claims.filter { $0.phase == .completed || $0.phase == .outcomeUnknown }
        guard terminal.count > keep else { return }
        for claim in terminal.prefix(terminal.count - keep) {
            try? FileManager.default.removeItem(at: claimPath(updateId: claim.updateId))
        }
    }

    private func claimPath(updateId: Int) -> URL {
        directory.appendingPathComponent("\(updateId).json", isDirectory: false)
    }

    private func decodeClaim(at path: URL) throws -> TelegramUpdateClaim {
        let data: Data
        do {
            data = try Data(contentsOf: path)
        } catch {
            throw TelegramUpdateInboxError.malformedClaim(path.lastPathComponent)
        }
        guard case .object(let object) = try? JSONValue.parse(data),
              case .int(let schema)? = object["schemaVersion"], schema == 1,
              case .int(let rawUpdateId)? = object["updateId"],
              let updateId = Int(exactly: rawUpdateId),
              case .string(let rawPhase)? = object["phase"],
              let phase = TelegramUpdateClaimPhase(rawValue: rawPhase),
              case .string(let claimedAt)? = object["claimedAt"], !claimedAt.isEmpty,
              case .string(let updatedAt)? = object["updatedAt"], !updatedAt.isEmpty,
              let updateValue = object["update"],
              let updateData = try? updateValue.serializedData(pretty: false),
              let update = try? JSONDecoder().decode(TelegramUpdate.self, from: updateData) else {
            throw TelegramUpdateInboxError.malformedClaim(path.lastPathComponent)
        }
        guard update.updateId == updateId else {
            throw TelegramUpdateInboxError.mismatchedUpdateId(expected: updateId, actual: update.updateId)
        }
        return TelegramUpdateClaim(
            updateId: updateId,
            update: update,
            phase: phase,
            claimedAt: claimedAt,
            updatedAt: updatedAt
        )
    }

    private func write(_ claim: TelegramUpdateClaim, to path: URL) async throws {
        let updateData = try JSONEncoder().encode(claim.update)
        let updateValue = try JSONValue.parse(updateData)
        let value: JSONValue = .object([
            "schemaVersion": .int(1),
            "updateId": .int(Int64(claim.updateId)),
            "phase": .string(claim.phase.rawValue),
            "claimedAt": .string(claim.claimedAt),
            "updatedAt": .string(claim.updatedAt),
            "update": updateValue,
        ])
        try await persistence.writeDataAtomicDurable(
            value.serializedData(pretty: true),
            to: path
        )
    }
}

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
        delivery: TelegramAssistantDeliveryDriver,
        receiptKind: String,
        sendErrorContext: String,
        update: TelegramUpdate,
        message: TelegramMessage,
        text: String
    ) async {
        if await delivery.abortDelivering(notice: notice) {
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
