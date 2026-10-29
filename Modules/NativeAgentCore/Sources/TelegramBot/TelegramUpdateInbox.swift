import Foundation
import CryptoKit
import NativeAgentCore
import PersistenceCore
// Blueprint: | `TelegramUpdateInbox.swift` | `TelegramUpdateInbox` struct; `snapshots`, `ensurePending`, `failedReplyClaims`, `repair`; maintained claim index emits delivery invalidations and can be reconstructed from checked claims without changing phases; recovery exceptions retain a terminal quarantined claim and reason, excluded from automatic replay; resumable work obeys the originating DataRootLife, reads stopped/restored across lives and resumes fresh only on explicit request |

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
    case stopped
}

struct TelegramUpdateClaim: Sendable, Codable, Equatable {
    var lifeID: String? = nil
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
    var queueAcknowledgementMessageId: Int?
    /// A queued retry retains its resolved request and conversation.
    var resolvedRetryText: String?
    var resolvedRetryMessage: TelegramMessage?
    var resolvedSessionId: String?
    let claimedAt: String
    var updatedAt: String
}

extension TelegramUpdateClaim {
    enum CodingKeys: String, CodingKey {
        case schemaVersion, lifeID, updateId, update, phase, assistantDelivery, assistantRunId, assistantSessionId, assistantOriginRunId, settledAssistantRuns, noRecoverableAnswer, failedBeforeAnswer, quarantineReason, queueAcknowledgementMessageId, resolvedRetryText, resolvedRetryMessage, resolvedSessionId, claimedAt, updatedAt
    }

    init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        guard try values.decode(JSONValue.self, forKey: .schemaVersion) == .int(1),
              case .int(let rawId) = try values.decode(JSONValue.self, forKey: .updateId),
              let id = Int(exactly: rawId) else {
            throw DecodingError.dataCorrupted(.init(codingPath: decoder.codingPath, debugDescription: "Invalid claim schema or ID"))
        }
        updateId = id
        update = try values.decode(TelegramUpdate.self, forKey: .update)
        phase = try values.decode(TelegramUpdateClaimPhase.self, forKey: .phase)
        claimedAt = try values.decode(String.self, forKey: .claimedAt)
        updatedAt = try values.decode(String.self, forKey: .updatedAt)
        let string: (CodingKeys) -> String? = { key in
            guard let raw = try? values.decode(String.self, forKey: key), !raw.isEmpty else { return nil }
            return raw
        }
        lifeID = string(.lifeID)
        assistantRunId = string(.assistantRunId)
        assistantSessionId = string(.assistantSessionId)
        assistantOriginRunId = string(.assistantOriginRunId)
        quarantineReason = string(.quarantineReason)
        resolvedRetryText = string(.resolvedRetryText)
        resolvedSessionId = string(.resolvedSessionId)
        switch try? values.decode(JSONValue.self, forKey: .queueAcknowledgementMessageId) {
        case .int(let raw)?: queueAcknowledgementMessageId = Int(exactly: raw)
        case .double(let raw)?: queueAcknowledgementMessageId = Int(exactly: raw)
        case .string(let raw)?: queueAcknowledgementMessageId = Int(raw)
        default: queueAcknowledgementMessageId = nil
        }
        resolvedRetryMessage = try values.decodeIfPresent(TelegramMessage.self, forKey: .resolvedRetryMessage)
        assistantDelivery = try values.decodeIfPresent(TelegramAssistantDeliveryState.self, forKey: .assistantDelivery)
        settledAssistantRuns = values.contains(.settledAssistantRuns)
            ? try values.decode([String: String].self, forKey: .settledAssistantRuns) : [:]
        noRecoverableAnswer = (try? values.decode(JSONValue.self, forKey: .noRecoverableAnswer)) == .bool(true)
        failedBeforeAnswer = (try? values.decode(JSONValue.self, forKey: .failedBeforeAnswer)) == .bool(true)
    }

    func encode(to encoder: Encoder) throws {
        var values = encoder.container(keyedBy: CodingKeys.self)
        try values.encode(1, forKey: .schemaVersion)
        try values.encode(lifeID, forKey: .lifeID)
        try values.encode(updateId, forKey: .updateId)
        try values.encode(update, forKey: .update)
        try values.encode(phase, forKey: .phase)
        try values.encode(assistantDelivery, forKey: .assistantDelivery)
        try values.encode(assistantRunId, forKey: .assistantRunId)
        try values.encode(assistantSessionId, forKey: .assistantSessionId)
        try values.encode(assistantOriginRunId, forKey: .assistantOriginRunId)
        try values.encode(settledAssistantRuns, forKey: .settledAssistantRuns)
        try values.encode(noRecoverableAnswer, forKey: .noRecoverableAnswer)
        try values.encode(failedBeforeAnswer, forKey: .failedBeforeAnswer)
        try values.encode(quarantineReason, forKey: .quarantineReason)
        try values.encode(queueAcknowledgementMessageId, forKey: .queueAcknowledgementMessageId)
        try values.encode(resolvedRetryText, forKey: .resolvedRetryText)
        try values.encode(resolvedRetryMessage, forKey: .resolvedRetryMessage)
        try values.encode(resolvedSessionId, forKey: .resolvedSessionId)
        try values.encode(claimedAt, forKey: .claimedAt)
        try values.encode(updatedAt, forKey: .updatedAt)
    }
}

enum TelegramUpdateInboxError: Error, LocalizedError, Equatable {
    case malformedClaim(String)
    case mismatchedUpdateId(expected: Int, actual: Int)

    var errorDescription: String? {
        switch self {
        case .malformedClaim(let name):
            return "telegram_claim_malformed: Inbox claim \(name) is malformed. Inspect that file in this bot's update_inbox and reconcile any delivery receipts before repairing it; do not delete it to replay the update."
        case .mismatchedUpdateId(let expected, let actual):
            return "telegram_claim_mismatch: Inbox claim ID is \(actual), expected \(expected). Reconcile \(expected).json in this bot's update_inbox with its delivery receipts before repairing it; do not replay the update."
        }
    }
}

/// Claims precede the upstream offset and resume only within their life.
/// Processing uncertainty never replays effects; queued claims retain their controls.
public struct TelegramUpdateInbox: Sendable {
    let directory: URL
    private let dataRoot: URL

    init(offsetURL: URL, dataRoot: URL) {
        self.dataRoot = dataRoot
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

    private init(directory: URL, dataRoot: URL) { self.directory = directory; self.dataRoot = dataRoot }

    /// Reconstruct only the derived index; claims retain every phase and delivery uncertainty.
    public static func repair(dataRoot: URL, inbox: String) async throws -> JSONValue {
        let root = dataRoot.appendingPathComponent("telegram", isDirectory: true).resolvingSymlinksInPath()
        let directory = dataRoot.appendingPathComponent(inbox, isDirectory: true).standardizedFileURL
        guard let tail = NativeAgentWorkspaceRoot.relativePath(directory.resolvingSymlinksInPath().path, under: root.path), !tail.isEmpty,
              directory.lastPathComponent == "update_inbox" || directory.lastPathComponent.hasSuffix(".inbox"),
              FileManager.default.fileExists(atPath: directory.path) else {
            throw ToolFailureError("Pass the existing Telegram inbox path named by the failure.",
                                   argumentPath: "inbox", effects: .none)
        }
        let store = Self(directory: directory, dataRoot: dataRoot)
        do {
            return try await SwiftNativePersistenceCore.withFileLock(store.indexPath) {
                let claims = try await store.snapshots()
                let preserved = store.indexPath.appendingPathExtension("preserved-" + UUID().uuidString)
                if FileManager.default.fileExists(atPath: store.indexPath.path) {
                    try await SwiftNativePersistenceCore.writeDataAtomicDurableAsync(Data(contentsOf: store.indexPath), to: preserved)
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
        let inbox = NativeAgentWorkspaceRoot.relativePath(directory.path, under: dataRoot.path) ?? directory.path
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
            let inbox = Self(directory: directory, dataRoot: dataRoot)
            claims += try await SwiftNativePersistenceCore.withFileLock(inbox.indexPath) {
                try await inbox.loadIndex().entries.values.filter { $0.phase == .failedBeforeAnswer }
                    .map {
                        let path = inbox.claimPath(updateId: $0.updateId)
                        return (path: path, at: try inbox.decodeClaim(at: path).updatedAt)
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
            let claim = try decodeClaim(at: url)
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
                let claim = try decodeClaim(at: path)
                guard claim.assistantRunId == runId, claim.assistantSessionId == sessionId,
                      claim.update.message?.destination == destination,
                      claim.assistantDelivery?.reply == delivery.reply else { throw TelegramUpdateInboxError.malformedClaim(path.lastPathComponent) }
                return claim
            }
            var saved = delivery
            saved.outcomeUnknown = priorVerdict != nil
            let now = _tgNowString()
            var claim = TelegramUpdateClaim(lifeID: try DataRootLife.current(in: dataRoot), updateId: updateId,
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
        guard update.updateId >= 0, update.hasValidInboxID else {
            throw TelegramUpdateInboxError.malformedClaim("\(update.updateId).json")
        }
        let path = claimPath(updateId: update.updateId)
        return try await withClaimMutationLock(path) {
            if FileManager.default.fileExists(atPath: path.path) {
                let existing = try decodeClaim(at: path)
                try await upsertIndex(existing)
                return existing
            }
            let now = _tgNowString()
            let claim = TelegramUpdateClaim(
                lifeID: try DataRootLife.current(in: dataRoot),
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

    /// Phase and resolved retry input commit together; nil preserves retained input.
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
            let current = try decodeClaim(at: path)
            guard allowed.contains(current.phase) else { return current }
            if let resolvedSessionId {
                guard NativeAgentChatSessionID.normalizedPathComponent(resolvedSessionId) != nil,
                      current.resolvedSessionId == nil || current.resolvedSessionId == resolvedSessionId else {
                    throw TelegramUpdateInboxError.malformedClaim(path.lastPathComponent)
                }
            }
            var next = current
            next.phase = phase
            next.assistantRunId = assistantRunId ?? current.assistantRunId
            next.assistantSessionId = assistantSessionId ?? current.assistantSessionId
            next.quarantineReason = quarantineReason ?? current.quarantineReason
            if phase != .queued { next.queueAcknowledgementMessageId = nil }
            next.resolvedRetryText = resolvedRetryText ?? current.resolvedRetryText
            next.resolvedRetryMessage = resolvedRetryMessage ?? current.resolvedRetryMessage
            next.resolvedSessionId = resolvedSessionId ?? current.resolvedSessionId
            next.updatedAt = _tgNowString()
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
            let current = try decodeClaim(at: path)
            // A send can settle after the queued turn starts or is consumed.
            // Preserve the returned message identity in every phase.
            var next = current
            next.queueAcknowledgementMessageId = messageId
            next.updatedAt = _tgNowString()
            try await write(next, to: path)
            try await upsertIndex(next)
            return next
        }
    }

    func claim(updateId: Int) throws -> TelegramUpdateClaim {
        try decodeClaim(at: claimPath(updateId: updateId))
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
            var current = try decodeClaim(at: path)
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
        try await SwiftNativePersistenceCore.withFileLock(claimPath(updateId: updateId).appendingPathExtension("delivery"), body)
    }

    func prepareSuccessor(updateId: Int, runId: String, sessionId: String, delivery: TelegramAssistantDeliveryState) async throws {
        let path = claimPath(updateId: updateId)
        try await withClaimMutationLock(path) {
            var claim = try decodeClaim(at: path)
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
        try await SwiftNativePersistenceCore.withFileLock(indexPath) {
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
            let claim = try decodeClaim(at: claimPath(updateId: entry.updateId))
            if claim.phase != .stopped { recovered.append(claim) }
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
        try? await SwiftNativePersistenceCore.withFileLock(indexPath) {
            guard let referenced = try? CodexCompletionReadout.unsettledAnswerRuns(
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
            guard let claim = try? decodeClaim(at: claimPath(updateId: entry.updateId)),
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
        try await SwiftNativePersistenceCore.withFileLock(indexPath) {
            try await SwiftNativePersistenceCore.withFileLock(path, body)
        }
    }

    private func decodeClaim(at path: URL) throws -> TelegramUpdateClaim {
        var claim: TelegramUpdateClaim
        do {
            claim = try JSONDecoder().decode(TelegramUpdateClaim.self, from: Data(contentsOf: path))
        } catch {
            throw TelegramUpdateInboxError.malformedClaim(path.lastPathComponent)
        }
        guard claim.update.hasValidInboxID, !claim.claimedAt.isEmpty, !claim.updatedAt.isEmpty,
              claim.phase != .quarantined || claim.quarantineReason != nil,
              claim.settledAssistantRuns.allSatisfy({ !$0.key.isEmpty && ["completed", "sent_unconfirmed"].contains($0.value) }) else {
            throw TelegramUpdateInboxError.malformedClaim(path.lastPathComponent)
        }
        guard claim.update.updateId == claim.updateId else {
            throw TelegramUpdateInboxError.mismatchedUpdateId(expected: claim.updateId, actual: claim.update.updateId)
        }
        if let delivery = claim.assistantDelivery {
            guard !delivery.reply.isEmpty || !(delivery.imagePaths ?? []).isEmpty,
                  delivery.confirmedMessageIds.count <= TelegramRichMessageRenderer.render(delivery.reply).count,
                  (0...(delivery.imagePaths?.count ?? 0)).contains(delivery.confirmedImageCount ?? 0) else {
                throw TelegramUpdateInboxError.malformedClaim(path.lastPathComponent)
            }
        }
        if try !DataRootLife.isCurrent(claim.lifeID, in: dataRoot)
            && (claim.phase != .completed || claim.assistantDelivery?.isDelivered == false) {
            claim.phase = .stopped
            claim.quarantineReason = DataRootLife.stoppedReason
        }
        return claim
    }

    private func write(_ claim: TelegramUpdateClaim, to path: URL) async throws {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        try await SwiftNativePersistenceCore.writeDataAtomicDurableAsync(encoder.encode(claim), to: path)
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
        try await SwiftNativePersistenceCore.writeDataAtomicDurableAsync(
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
