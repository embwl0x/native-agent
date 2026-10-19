import Foundation
import CryptoKit
import NativeAgentCore
import PersistenceCore

enum TelegramUpdateClaimPhase: String, Sendable, Equatable, Codable {
    case pending
    case awaitingSpeechPermission = "awaiting_speech_permission"
    case processing
    case queued
    case completed
    case outcomeUnknown = "outcome_unknown"
    case sentUnconfirmed = "sent_unconfirmed"
    case failedBeforeAnswer = "failed_before_answer"
    case quarantined
}

struct TelegramUpdateClaim: Sendable, Equatable {
    let updateId: Int
    let update: TelegramUpdate
    var phase: TelegramUpdateClaimPhase
    var assistantDelivery: TelegramAssistantDeliveryState? = nil
    var assistantRunId: String? = nil
    var assistantSessionId: String? = nil
    var assistantOriginRunId: String? = nil
    var settledAssistantRuns: [String: String] = [:]
    var noRecoverableAnswer = false
    var failedBeforeAnswer = false
    var quarantineReason: String? = nil
    let queueAcknowledgementMessageId: Int?
    /// 2026-09-06: for a queued `/retry`, the message text the retry resolved
    /// to at queue time. `/retry` reads the last user message from the
    /// coordinator's in-memory map; after a restart that map is empty, so a
    /// queued retry replayed from this inbox answered "nothing to retry" and
    /// settled its claim. Nil for every other update.
    let resolvedRetryText: String?
    let resolvedRetryMessage: TelegramMessage?
    let resolvedSessionId: String?
    let claimedAt: String
    var updatedAt: String
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
/// as outcome-unknown rather than replaying possibly-effecting work. Queued
/// claims also retain their acknowledgement message id so restart recovery
/// reclaims the original controls instead of creating a shadow queue card.
public struct TelegramUpdateInbox: Sendable {
    let directory: URL
    private let persistence = SwiftNativePersistenceCore()

    enum ClaimReadKind: Sendable, Equatable, Hashable {
        case recovery
        case mutation
        case diagnosticSnapshot
    }

    @TaskLocal static var claimReadObserver: (@Sendable (ClaimReadKind) -> Void)?

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

    private init(directory: URL) { self.directory = directory }

    /// Reconstruct only the derived index; claims retain every phase and delivery uncertainty.
    public static func repair(dataRoot: URL, inbox: String) async throws -> JSONValue {
        let root = dataRoot.appendingPathComponent("telegram", isDirectory: true).resolvingSymlinksInPath()
        let directory = dataRoot.appendingPathComponent(inbox, isDirectory: true).standardizedFileURL
        guard directory.resolvingSymlinksInPath().path.hasPrefix(root.path + "/"),
              directory.lastPathComponent == "update_inbox" || directory.lastPathComponent.hasSuffix(".inbox"),
              FileManager.default.fileExists(atPath: directory.path) else {
            throw ToolFailureError("Pass the existing Telegram inbox path named by the failure.",
                                   argumentPath: "inbox", effects: .none)
        }
        let store = Self(directory: directory)
        do {
            return try await store.persistence.withFileLock(store.indexPath) {
                let claims = try await store.snapshots()
                let preserved = store.indexPath.appendingPathExtension("preserved-" + UUID().uuidString)
                if FileManager.default.fileExists(atPath: store.indexPath.path) {
                    try await store.persistence.writeDataAtomicDurable(Data(contentsOf: store.indexPath), to: preserved)
                }
                try await store.writeIndex(InboxClaimIndex(claims: claims))
                _ = try await store.recoverableClaimsLocked()
                return .object(["status": .string("ok"), "inbox": .string(inbox),
                    "detail": .string("Telegram admission index rebuilt from its checked claims. Claim phases and uncertain effects are unchanged; the next successful inbox recovery settles the repair.")])
            }
        } catch {
            throw store.repairFailure(error, dataRoot: dataRoot, effects: .unknown)
        }
    }

    func repairFailure(_ error: Error, dataRoot: URL, effects: ToolFailureError.Effects = .none) -> ToolFailureError {
        let name: String
        switch error {
        case TelegramUpdateInboxError.malformedClaim(let claim): name = claim
        case TelegramUpdateInboxError.mismatchedUpdateId(let expected, _): name = "\(expected).json"
        default: name = indexPath.lastPathComponent
        }
        let owner = directory.appendingPathComponent(name).path
        let inbox = String(directory.path.dropFirst(dataRoot.path.count + 1))
        let next = name == indexPath.lastPathComponent
            ? ToolFailureError.call("app", ["action": .string("telegram.repair"), "args": .object(["inbox": .string(inbox)])])
            : ToolFailureError.call("app", ["action": .string("files.read"), "args": .object(["path": .string(owner)])])
        return ToolFailureError("Telegram admission recovery failed at \(owner): \(error.localizedDescription) "
            + (name == indexPath.lastPathComponent
                ? "Rebuild the index from its checked claims; restarting the poller cannot repair this state."
                : "Read this claim and restore it only from authoritative admission or delivery evidence, preserving unknown effects; then call telegram.repair for \(inbox)."),
            effects: effects, owner: owner, nextCall: next)
    }

    public static func failedReplyClaims(dataRoot: URL) async throws -> [(path: URL, at: String)] {
        let telegram = dataRoot.appendingPathComponent("telegram", isDirectory: true)
        let bots = telegram.appendingPathComponent("bots", isDirectory: true)
        var directories = [telegram.appendingPathComponent("update_inbox", isDirectory: true)]
        if FileManager.default.fileExists(atPath: bots.path) {
            for bot in try FileManager.default.contentsOfDirectory(at: bots, includingPropertiesForKeys: [.isDirectoryKey], options: [.skipsHiddenFiles])
                where try bot.resourceValues(forKeys: [.isDirectoryKey]).isDirectory == true {
                directories += try FileManager.default.contentsOfDirectory(at: bot, includingPropertiesForKeys: nil, options: [.skipsHiddenFiles])
                    .filter { $0.lastPathComponent.hasSuffix(".inbox") }
            }
        }
        var claims: [(path: URL, at: String)] = []
        for directory in directories where FileManager.default.fileExists(atPath: directory.path) {
            let inbox = Self(directory: directory)
            claims += try await inbox.persistence.withFileLock(inbox.indexPath) {
                try await inbox.loadIndex().entries.values.filter { $0.phase == .failedBeforeAnswer }
                    .map {
                        let path = inbox.claimPath(updateId: $0.updateId)
                        return (path: path, at: try inbox.decodeClaim(at: path, kind: .diagnosticSnapshot).updatedAt)
                    }
            }
        }
        return claims
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
        for url in urls where url.pathExtension == "json"
            && Int(url.deletingPathExtension().lastPathComponent) != nil {
            let values = try url.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey])
            guard values.isRegularFile == true, values.isSymbolicLink != true else {
                throw TelegramUpdateInboxError.malformedClaim(url.lastPathComponent)
            }
            let claim = try decodeClaim(at: url, kind: .diagnosticSnapshot)
            guard url.deletingPathExtension().lastPathComponent == String(claim.updateId),
                  seenUpdateIDs.insert(claim.updateId).inserted else {
                throw TelegramUpdateInboxError.malformedClaim(url.lastPathComponent)
            }
            claims.append(claim)
        }
        return claims.sorted { $0.updatedAt < $1.updatedAt }
    }

    func reserveReply(runId: String, sessionId: String, destination: TelegramDestination,
                      delivery: TelegramAssistantDeliveryState, priorVerdict: String?, fromUserId: Int?) async throws -> TelegramUpdateClaim {
        // Upstream update ids are nonnegative; outbound answers share the same journal in its negative namespace.
        let updateId = -1 - SHA256.hash(data: Data(runId.utf8)).prefix(7).reduce(0) { ($0 << 8) | Int($1) }
        let path = claimPath(updateId: updateId)
        return try await withClaimMutationLock(path) {
            if FileManager.default.fileExists(atPath: path.path) {
                let claim = try decodeClaim(at: path, kind: .mutation)
                guard claim.assistantRunId == runId, claim.assistantSessionId == sessionId,
                      claim.update.message?.destination == destination,
                      claim.assistantDelivery?.reply == delivery.reply else { throw TelegramUpdateInboxError.malformedClaim(path.lastPathComponent) }
                return claim
            }
            var saved = delivery
            saved.outcomeUnknown = priorVerdict != nil
            let now = _tgNowString()
            var claim = TelegramUpdateClaim(updateId: updateId,
                update: TelegramUpdate(updateId: updateId, message: TelegramMessage(messageId: updateId,
                    chatId: destination.chatId, messageThreadId: destination.threadId,
                    fromUserId: fromUserId)),
                phase: priorVerdict == nil ? .processing : .sentUnconfirmed,
                assistantDelivery: saved, assistantRunId: runId, assistantSessionId: sessionId,
                queueAcknowledgementMessageId: nil, resolvedRetryText: nil, resolvedRetryMessage: nil,
                resolvedSessionId: nil, claimedAt: now, updatedAt: now)
            if let priorVerdict { claim.settledAssistantRuns[runId] = priorVerdict }
            try await write(claim, to: path)
            try await upsertIndex(claim)
            return claim
        }
    }

    @discardableResult
    func ensurePending(_ update: TelegramUpdate) async throws -> TelegramUpdateClaim {
        let path = claimPath(updateId: update.updateId)
        return try await withClaimMutationLock(path) {
            if FileManager.default.fileExists(atPath: path.path) {
                let existing = try decodeClaim(at: path, kind: .mutation)
                try await upsertIndex(existing)
                return existing
            }
            let now = _tgNowString()
            let claim = TelegramUpdateClaim(
                updateId: update.updateId,
                update: update,
                phase: .pending,
                queueAcknowledgementMessageId: nil,
                resolvedRetryText: nil,
                resolvedRetryMessage: nil,
                resolvedSessionId: nil,
                claimedAt: now,
                updatedAt: now
            )
            try await write(claim, to: path)
            try await upsertIndex(claim)
            return claim
        }
    }

    /// 2026-09-06: `resolvedRetryText` rides the phase write. A queued
    /// `/retry` used to become `.queued` first and pin its text in a second
    /// write, so a crash in between left exactly the claim recovery cannot
    /// resolve — the bug the pin was added to fix. Nil keeps whatever the
    /// claim already carries.
    @discardableResult
    func transition(
        updateId: Int,
        from allowed: Set<TelegramUpdateClaimPhase>,
        to phase: TelegramUpdateClaimPhase,
        assistantRunId: String? = nil,
        assistantSessionId: String? = nil,
        resolvedRetryText: String? = nil,
        resolvedRetryMessage: TelegramMessage? = nil,
        resolvedSessionId: String? = nil,
        quarantineReason: String? = nil
    ) async throws -> TelegramUpdateClaim {
        let path = claimPath(updateId: updateId)
        return try await withClaimMutationLock(path) {
            let current = try decodeClaim(at: path, kind: .mutation)
            guard allowed.contains(current.phase) else { return current }
            if let resolvedSessionId {
                guard NativeAgentChatSessionID.normalizedPathComponent(resolvedSessionId) != nil,
                      current.resolvedSessionId == nil || current.resolvedSessionId == resolvedSessionId else {
                    throw TelegramUpdateInboxError.malformedClaim(path.lastPathComponent)
                }
            }
            let next = TelegramUpdateClaim(
                updateId: current.updateId,
                update: current.update,
                phase: phase,
                assistantDelivery: current.assistantDelivery,
                assistantRunId: assistantRunId ?? current.assistantRunId,
                assistantSessionId: assistantSessionId ?? current.assistantSessionId,
                assistantOriginRunId: current.assistantOriginRunId,
                settledAssistantRuns: current.settledAssistantRuns,
                noRecoverableAnswer: current.noRecoverableAnswer,
                failedBeforeAnswer: current.failedBeforeAnswer,
                quarantineReason: quarantineReason ?? current.quarantineReason,
                queueAcknowledgementMessageId: phase == .queued
                    ? current.queueAcknowledgementMessageId
                    : nil,
                resolvedRetryText: resolvedRetryText ?? current.resolvedRetryText,
                resolvedRetryMessage: resolvedRetryMessage ?? current.resolvedRetryMessage,
                resolvedSessionId: resolvedSessionId ?? current.resolvedSessionId,
                claimedAt: current.claimedAt,
                updatedAt: _tgNowString()
            )
            try await write(next, to: path)
            try await upsertIndex(next)
            return next
        }
    }

    @discardableResult
    func recordQueueAcknowledgement(
        updateId: Int,
        messageId: Int
    ) async throws -> TelegramUpdateClaim {
        let path = claimPath(updateId: updateId)
        return try await withClaimMutationLock(path) {
            let current = try decodeClaim(at: path, kind: .mutation)
            guard current.phase == .queued else { return current }
            let next = TelegramUpdateClaim(
                updateId: current.updateId,
                update: current.update,
                phase: current.phase,
                assistantDelivery: current.assistantDelivery,
                assistantRunId: current.assistantRunId,
                assistantSessionId: current.assistantSessionId,
                assistantOriginRunId: current.assistantOriginRunId,
                settledAssistantRuns: current.settledAssistantRuns,
                noRecoverableAnswer: current.noRecoverableAnswer,
                failedBeforeAnswer: current.failedBeforeAnswer,
                quarantineReason: current.quarantineReason,
                queueAcknowledgementMessageId: messageId,
                resolvedRetryText: current.resolvedRetryText,
                resolvedRetryMessage: current.resolvedRetryMessage,
                resolvedSessionId: current.resolvedSessionId,
                claimedAt: current.claimedAt,
                updatedAt: _tgNowString()
            )
            try await write(next, to: path)
            try await upsertIndex(next)
            return next
        }
    }

    func claim(updateId: Int) throws -> TelegramUpdateClaim {
        try decodeClaim(at: claimPath(updateId: updateId), kind: .mutation)
    }

    @discardableResult
    func recordAssistantDelivery(
        updateId: Int,
        delivery: TelegramAssistantDeliveryState?,
        recovering: Bool = false,
        failedBeforeAnswer: Bool = false
    ) async throws -> TelegramAssistantDeliveryState? {
        let path = claimPath(updateId: updateId)
        return try await withClaimMutationLock(path) {
            var current = try decodeClaim(at: path, kind: .mutation)
            let previous = current
            if failedBeforeAnswer { current.failedBeforeAnswer = true }
            if recovering, var retained = current.assistantDelivery {
                if retained.imagePaths == nil { retained.imagePaths = delivery?.imagePaths }
                current.assistantDelivery = retained
            } else {
                current.assistantDelivery = delivery
                current.noRecoverableAnswer = delivery == nil
            }
            if let saved = current.assistantDelivery,
               [.completed, .sentUnconfirmed, .failedBeforeAnswer].contains(current.phase),
               !saved.isDelivered, !saved.outcomeUnknown, saved.rejectionReason == nil {
                current.phase = .outcomeUnknown
            }
            if current != previous {
                current.updatedAt = _tgNowString()
                // A crash must not hide an answer whose resend consent was saved.
                if current.phase != previous.phase { try await upsertIndex(current) }
                try await write(current, to: path)
            }
            return current.assistantDelivery
        }
    }

    func withAssistantDeliveryLock<T: Sendable>(
        updateId: Int,
        _ body: @Sendable () async throws -> T
    ) async throws -> T {
        try await persistence.withFileLock(claimPath(updateId: updateId).appendingPathExtension("delivery"), body)
    }

    func prepareSuccessor(updateId: Int, runId: String, sessionId: String, delivery: TelegramAssistantDeliveryState) async throws {
        let path = claimPath(updateId: updateId)
        try await withClaimMutationLock(path) {
            var claim = try decodeClaim(at: path, kind: .mutation)
            guard claim.assistantRunId != runId else { return }
            guard claim.settledAssistantRuns[runId] == nil,
                  let priorRun = claim.assistantRunId, let prior = claim.assistantDelivery,
                  prior.isDelivered || prior.outcomeUnknown else { throw TelegramUpdateInboxError.malformedClaim(path.lastPathComponent) }
            claim.settledAssistantRuns[priorRun] = prior.isDelivered ? "completed" : "sent_unconfirmed"
            claim.assistantOriginRunId = claim.assistantOriginRunId ?? claim.assistantRunId
            claim.assistantRunId = runId
            claim.assistantSessionId = sessionId
            claim.assistantDelivery = delivery
            claim.noRecoverableAnswer = false
            claim.failedBeforeAnswer = false
            claim.updatedAt = _tgNowString()
            try await write(claim, to: path)
        }
    }

    /// Recovery reads the maintained index, then opens only pending,
    /// processing, queued, or permission-blocked claim files. Terminal retention never makes an idle Telegram
    /// tick reread hundreds of historical update payloads.
    func recoverableClaims() async throws -> [TelegramUpdateClaim] {
        try await persistence.withFileLock(indexPath) {
            try await recoverableClaimsLocked()
        }
    }

    private func recoverableClaimsLocked() async throws -> [TelegramUpdateClaim] {
        var index = try await loadIndex()
        var recovered: [TelegramUpdateClaim] = []
        var repairedIndex = false
        for entry in index.entries.values.sorted(by: { $0.updateId < $1.updateId })
        where entry.phase == .pending || entry.phase == .processing || entry.phase == .queued
            || entry.phase == .awaitingSpeechPermission || entry.phase == .outcomeUnknown {
            let claim = try decodeClaim(at: claimPath(updateId: entry.updateId), kind: .recovery)
            recovered.append(claim)
            if claim.phase != entry.phase {
                index.entries[entry.updateId] = InboxClaimIndex.Entry(
                    updateId: claim.updateId,
                    phase: claim.phase
                )
                repairedIndex = true
            }
        }
        if repairedIndex { try await writeIndex(index) }
        return recovered
    }

    func pruneTerminalClaims(dataRoot: URL, keepingNewest keep: Int = 256) async {
        try? await persistence.withFileLock(indexPath) {
            guard let referenced = try? CodexCompletionLifecycleProjection.unsettledAnswerRuns(
                configRoot: InstallPaths.current.bridgeConfigRoot(dataRoot: dataRoot), dataRoot: dataRoot) else { return }
            await pruneTerminalClaimsLocked(keepingNewest: keep, referenced: referenced)
        }
    }

    private func pruneTerminalClaimsLocked(keepingNewest keep: Int, referenced: Set<String>) async {
        guard var index = try? await loadIndex() else { return }
        let terminal = index.entries.values
            .filter { $0.phase == .completed || $0.phase == .failedBeforeAnswer }
        guard terminal.count > keep else { return }
        let eligible = terminal.compactMap { entry -> TelegramUpdateClaim? in
            guard let claim = try? decodeClaim(at: claimPath(updateId: entry.updateId), kind: .mutation),
                  Set(claim.settledAssistantRuns.keys).union([claim.assistantRunId, claim.assistantOriginRunId].compactMap { $0 })
                    .isDisjoint(with: referenced) else { return nil }
            return claim
        }.sorted { $0.updatedAt < $1.updatedAt }
        var changed = false
        for claim in eligible.prefix(max(0, eligible.count - keep)) {
            let path = claimPath(updateId: claim.updateId)
            guard claim.phase == .failedBeforeAnswer || claim.assistantDelivery?.isDelivered != false,
                  claim.assistantRunId == nil || claim.assistantDelivery != nil || claim.noRecoverableAnswer else { continue }
            try? FileManager.default.removeItem(at: path)
            if !FileManager.default.fileExists(atPath: path.path) {
                let lockPath = path.appendingPathExtension("lock")
                try? FileManager.default.removeItem(at: lockPath)
                index.entries.removeValue(forKey: claim.updateId)
                changed = true
            }
        }
        if changed { try? await writeIndex(index) }
    }

    private func claimPath(updateId: Int) -> URL {
        directory.appendingPathComponent("\(updateId).json", isDirectory: false)
    }

    private var indexPath: URL {
        directory.appendingPathComponent("claims_index.json", isDirectory: false)
    }

    // Index ownership precedes claim ownership and spans both durable writes.
    // Recovery, migration, and pruning hold this same index lock, so none can
    // replace another topic's index entry or remove an in-flight claim.
    private func withClaimMutationLock<T: Sendable>(
        _ path: URL,
        _ body: @Sendable () async throws -> T
    ) async throws -> T {
        try await persistence.withFileLock(indexPath) {
            try await persistence.withFileLock(path, body)
        }
    }

    private func decodeClaim(at path: URL, kind: ClaimReadKind) throws -> TelegramUpdateClaim {
        Self.claimReadObserver?(kind)
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
        guard phase != .quarantined || Self.optionalString(object["quarantineReason"]) != nil else {
            throw TelegramUpdateInboxError.malformedClaim(path.lastPathComponent)
        }
        let retryMessage: TelegramMessage?
        if let value = object["resolvedRetryMessage"], value != .null {
            do {
                retryMessage = try JSONDecoder().decode(TelegramMessage.self, from: value.serializedData(pretty: false))
            } catch {
                throw TelegramUpdateInboxError.malformedClaim(path.lastPathComponent)
            }
        } else {
            retryMessage = nil
        }
        let delivery: TelegramAssistantDeliveryState?
        if let value = object["assistantDelivery"], value != .null {
            do {
                delivery = try JSONDecoder().decode(TelegramAssistantDeliveryState.self, from: value.serializedData(pretty: false))
                guard let delivery, !delivery.reply.isEmpty || !(delivery.imagePaths ?? []).isEmpty,
                      delivery.confirmedMessageIds.count <= TelegramRichMessageRenderer.render(delivery.reply).count,
                      (0...(delivery.imagePaths?.count ?? 0)).contains(delivery.confirmedImageCount ?? 0) else {
                    throw TelegramUpdateInboxError.malformedClaim(path.lastPathComponent)
                }
            } catch {
                throw TelegramUpdateInboxError.malformedClaim(path.lastPathComponent)
            }
        } else {
            delivery = nil
        }
        var settledRuns: [String: String] = [:]
        if let value = object["settledAssistantRuns"] {
            guard case .object(let saved) = value else { throw TelegramUpdateInboxError.malformedClaim(path.lastPathComponent) }
            for (run, verdict) in saved {
                guard !run.isEmpty, case .string(let status) = verdict,
                      ["completed", "sent_unconfirmed"].contains(status) else { throw TelegramUpdateInboxError.malformedClaim(path.lastPathComponent) }
                settledRuns[run] = status
            }
        }
        return TelegramUpdateClaim(
            updateId: updateId,
            update: update,
            phase: phase,
            assistantDelivery: delivery,
            assistantRunId: Self.optionalString(object["assistantRunId"]),
            assistantSessionId: Self.optionalString(object["assistantSessionId"]),
            assistantOriginRunId: Self.optionalString(object["assistantOriginRunId"]),
            settledAssistantRuns: settledRuns,
            noRecoverableAnswer: object["noRecoverableAnswer"] == .bool(true),
            failedBeforeAnswer: object["failedBeforeAnswer"] == .bool(true),
            quarantineReason: Self.optionalString(object["quarantineReason"]),
            queueAcknowledgementMessageId: Self.optionalInt(
                object["queueAcknowledgementMessageId"]
            ),
            resolvedRetryText: Self.optionalString(object["resolvedRetryText"]),
            resolvedRetryMessage: retryMessage,
            resolvedSessionId: Self.optionalString(object["resolvedSessionId"]),
            claimedAt: claimedAt,
            updatedAt: updatedAt
        )
    }

    private func write(_ claim: TelegramUpdateClaim, to path: URL) async throws {
        let updateData = try JSONEncoder().encode(claim.update)
        let updateValue = try JSONValue.parse(updateData)
        let retryMessageValue: JSONValue = try claim.resolvedRetryMessage.map {
            try JSONValue.parse(JSONEncoder().encode($0))
        } ?? .null
        let deliveryValue = try claim.assistantDelivery.map {
            try JSONValue.parse(JSONEncoder().encode($0))
        } ?? .null
        let value: JSONValue = .object([
            "schemaVersion": .int(1),
            "updateId": .int(Int64(claim.updateId)),
            "phase": .string(claim.phase.rawValue),
            "claimedAt": .string(claim.claimedAt),
            "updatedAt": .string(claim.updatedAt),
            "queueAcknowledgementMessageId": claim.queueAcknowledgementMessageId
                .map { .int(Int64($0)) } ?? .null,
            "resolvedRetryText": claim.resolvedRetryText.map { .string($0) } ?? .null,
            "resolvedRetryMessage": retryMessageValue,
            "resolvedSessionId": claim.resolvedSessionId.map(JSONValue.string) ?? .null,
            "assistantDelivery": deliveryValue,
            "assistantRunId": claim.assistantRunId.map { .string($0) } ?? .null,
            "assistantSessionId": claim.assistantSessionId.map { .string($0) } ?? .null,
            "assistantOriginRunId": claim.assistantOriginRunId.map(JSONValue.string) ?? .null,
            "settledAssistantRuns": .object(claim.settledAssistantRuns.mapValues(JSONValue.string)),
            "noRecoverableAnswer": .bool(claim.noRecoverableAnswer),
            "failedBeforeAnswer": .bool(claim.failedBeforeAnswer),
            "quarantineReason": claim.quarantineReason.map(JSONValue.string) ?? .null,
            "update": updateValue,
        ])
        try await persistence.writeDataAtomicDurable(
            value.serializedData(pretty: true),
            to: path
        )
    }

    private static func optionalString(_ value: JSONValue?) -> String? {
        guard case .string(let raw)? = value else { return nil }
        return raw.isEmpty ? nil : raw
    }

    private static func optionalInt(_ value: JSONValue?) -> Int? {
        switch value {
        case .int(let raw)?: return Int(exactly: raw)
        case .double(let raw)?: return Int(exactly: raw)
        case .string(let raw)?: return Int(raw)
        default: return nil
        }
    }

    private func loadIndex() async throws -> InboxClaimIndex {
        guard FileManager.default.fileExists(atPath: indexPath.path) else {
            // One-time migration for pre-index installs. This may scan retained
            // claims once, but every later tick reads this bounded index first.
            let migrated = InboxClaimIndex(claims: try await snapshots())
            try await writeIndex(migrated)
            return migrated
        }
        let data: Data
        do {
            data = try Data(contentsOf: indexPath)
        } catch {
            throw TelegramUpdateInboxError.malformedClaim(indexPath.lastPathComponent)
        }
        guard let index = try? JSONDecoder().decode(InboxClaimIndex.self, from: data),
              index.isValid else {
            throw TelegramUpdateInboxError.malformedClaim(indexPath.lastPathComponent)
        }
        return index
    }

    private func writeIndex(_ index: InboxClaimIndex) async throws {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try await persistence.writeDataAtomicDurable(
            JSONEncoder().encode(index),
            to: indexPath
        )
        StoreChangeBus.shared.emit(StoreChange(store: .replyDelivery, path: indexPath))
    }

    private func upsertIndex(_ claim: TelegramUpdateClaim) async throws {
        var index = try await loadIndex()
        index.entries[claim.updateId] = InboxClaimIndex.Entry(
            updateId: claim.updateId,
            phase: claim.phase
        )
        try await writeIndex(index)
    }
}

private struct InboxClaimIndex: Codable, Sendable {
    struct Entry: Codable, Sendable {
        let updateId: Int
        let phase: TelegramUpdateClaimPhase
    }

    let schemaVersion: Int
    var entries: [Int: Entry]

    init(claims: [TelegramUpdateClaim] = []) {
        self.schemaVersion = 1
        self.entries = Dictionary(claims.map {
            ($0.updateId, Entry(updateId: $0.updateId, phase: $0.phase))
        }, uniquingKeysWith: { first, _ in first })
    }

    var isValid: Bool {
        schemaVersion == 1
            && entries.allSatisfy { id, entry in id == entry.updateId }
    }
}
