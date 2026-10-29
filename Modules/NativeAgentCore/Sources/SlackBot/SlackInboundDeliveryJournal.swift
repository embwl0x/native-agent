import CryptoKit
import Foundation
import NativeAgentCore
import PersistenceCore
// Blueprint: | `SlackInboundDeliveryJournal.swift` | `SlackInboundDeliveryJournal` actor; socket/history/recovery admission, retains accepted handler tasks until actual exit with one active handler per event in the process (across loop replacements), and terminal delivery truth; `path`, `recoverySummary`, `failedReplyClaims`, `confirmReplyPart` retain confirmed text/image progress across holds; resumable work obeys the originating DataRootLife, reads stopped/restored across lives and resumes fresh only on explicit request |

enum SlackInboundDeliveryPhase: String, Codable, Sendable {
    case claimed
    case generating
    case prepared
    case dispatching
    case delivered
    case interrupted
    case outcomeUnknown = "outcome_unknown"
    case sentUnconfirmed = "sent_unconfirmed"
    case failedBeforeAnswer = "failed_before_answer"
    case stopped

    var isTerminal: Bool { self == .delivered || self == .interrupted || self == .sentUnconfirmed || self == .failedBeforeAnswer || self == .stopped }
}

struct SlackPreparedUpload: Codable, Equatable, Sendable {
    let path: String
    let name: String
    let mime: String
}

struct SlackPreparedReply: Codable, Equatable, Sendable {
    let text: String
    let uploads: [SlackPreparedUpload]
    let fingerprint: String

    static func make(text: String, uploads: [SlackPreparedUpload]) -> SlackPreparedReply {
        let uploadIdentity = uploads
            .map { "\($0.path)\u{1F}\($0.name)\u{1F}\($0.mime)" }
            .joined(separator: "\u{1E}")
        let digest = SHA256.hash(data: Data("\(text)\u{1D}\(uploadIdentity)".utf8))
        return SlackPreparedReply(
            text: text,
            uploads: uploads,
            fingerprint: digest.map { String(format: "%02x", $0) }.joined()
        )
    }
}

struct SlackInboundDeliveryRecord: Codable, Equatable, Sendable {
    var lifeID: String? = nil
    struct Rejection: Codable, Equatable, Sendable {
        let reason: String
        let preparedFingerprint: String
        let at: Date
    }

    let inbound: SlackInboundMessage
    var phase: SlackInboundDeliveryPhase
    var prepared: SlackPreparedReply?
    var dispatchStartedAt: Date?
    var updatedAt: Date
    var outcomeDetail: String?
    var assistantRunId: String? = nil
    var assistantSessionId: String? = nil
    var assistantOriginRunId: String? = nil
    var settledAssistantRuns: [String: String]? = nil
    var failedBeforeAnswer: Bool? = nil
    var lastRejection: Rejection? = nil
    var confirmedText: Bool? = nil
    var confirmedUploadCount: Int? = nil

    var hasValidUploadProgress: Bool {
        (0...(prepared?.uploads.count ?? 0)).contains(confirmedUploadCount ?? 0)
    }
}

enum SlackInboundClaimOutcome: Sendable, Equatable {
    case claimed(SlackInboundDeliveryRecord)
    case alreadyDelivered
}

enum SlackInboundJournalError: Error, CustomStringConvertible {
    case malformed
    case saturated(Int)
    case missingClaim(String)

    var description: String {
        switch self {
        case .malformed:
            return "Slack inbound journal is malformed"
        case .saturated(let cap):
            return "Slack inbound journal has reached its pending limit (\(cap))"
        case .missingClaim(let eventId):
            return "Slack inbound journal has no claim for \(eventId)"
        }
    }
}

/// Durable handoff between Socket Mode acknowledgement, local generation, and
/// Slack delivery. Terminal rows are bounded. Pending/ambiguous rows are never
/// evicted: once their cap is reached, admission fails before ACK so Slack can
/// retain and retry the envelope instead of NativeAgent silently dropping it.
public actor SlackInboundDeliveryJournal {
    public struct RecoverySummary: Sendable, Equatable {
        public let pendingCount: Int
        public let unknownCount: Int
        let pendingLimit: Int
        /// Damaged journals renamed aside (`…json.stale-<ts>`) rather than
        /// deleted. Non-zero means accepted-but-undelivered rows may have been
        /// lost from the live journal and are only readable in those files.
        var quarantinedCount: Int = 0
        public var isAtCapacity: Bool { pendingCount >= pendingLimit }
        public var hasQuarantinedEvidence: Bool { quarantinedCount > 0 }
    }

    private struct File: Codable {
        var version = 1
        var records: [SlackInboundDeliveryRecord] = []
        var pendingLimit: Int?
        /// Event ids whose bot-event fan-out has been taken. Absent in journals
        /// written before 0.4.12, which decode as none taken.
        var botEventClaims: [String] = []

        init() {}

        /// Only `botEventClaims`, added in 0.4.12, may be absent in older journals.
        init(from decoder: Decoder) throws {
            let c = try decoder.container(keyedBy: CodingKeys.self)
            version = try c.decode(Int.self, forKey: .version)
            records = try c.decode([SlackInboundDeliveryRecord].self, forKey: .records)
            pendingLimit = try c.decodeIfPresent(Int.self, forKey: .pendingLimit)
            botEventClaims = try c.decodeIfPresent([String].self, forKey: .botEventClaims) ?? []
        }
    }

    private let path: URL
    private let dataRoot: URL
    private let terminalCap = 500
    private let pendingCap = 100
    private let encoder: JSONEncoder
    /// One handler per accepted event in this process, whichever loop's
    /// journal took it: a loop replaced while its handler still runs leaves
    /// that handler the event, and the replacement's recovery skips it.
    nonisolated(unsafe) private static var activeHandlers: Set<String> = []
    nonisolated(unsafe) private static var handlerTasks: [String: Task<Void, Never>] = [:]
    private static let handlerLock = NSLock()

    init(dataRoot: URL) {
        path = Self.path(dataRoot: dataRoot)
        self.dataRoot = dataRoot
        encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.sortedKeys]
    }

    nonisolated static func path(dataRoot: URL) -> URL {
        dataRoot.appendingPathComponent("slack", isDirectory: true)
            .appendingPathComponent("inbound_delivery_journal.json")
    }

    /// Counts only, never raw messages or private attachment URLs. The mounted
    /// Connectors status reader uses this independent durable evidence so a
    /// fresh socket hello cannot hide a queue requiring human recovery.
    public nonisolated static func recoverySummary(dataRoot: URL) throws -> RecoverySummary? {
        let path = path(dataRoot: dataRoot)
        let existed = FileManager.default.fileExists(atPath: path.path)
        let file = existed ? try loadFile(path: path) : File()
        let quarantined = quarantinedEvidencePaths(dataRoot: dataRoot).count
        guard existed || quarantined > 0 else { return nil }
        return RecoverySummary(
            pendingCount: file.records.filter { !$0.phase.isTerminal }.count,
            unknownCount: file.records.filter { $0.phase == .outcomeUnknown }.count,
            pendingLimit: max(1, file.pendingLimit ?? 100),
            quarantinedCount: quarantined
        )
    }

    public nonisolated static func failedReplyClaims(dataRoot: URL) throws -> [(path: URL, at: String)] {
        let path = path(dataRoot: dataRoot)
        let formatter = ISO8601DateFormatter()
        return try loadFile(path: path).records.filter { $0.phase == .failedBeforeAnswer }.map {
            (path: path, at: formatter.string(from: $0.updatedAt))
        }
    }

    /// Damaged journals this actor renamed aside, newest last. Never deleted:
    /// they hold accepted message bodies whose delivery is unproven.
    nonisolated static func quarantinedEvidencePaths(dataRoot: URL) -> [URL] {
        let journal = path(dataRoot: dataRoot)
        let directory = journal.deletingLastPathComponent()
        let prefix = journal.lastPathComponent + quarantineSuffixPrefix
        let entries = (try? FileManager.default.contentsOfDirectory(atPath: directory.path)) ?? []
        return entries
            .filter { $0.hasPrefix(prefix) }
            .sorted()
            .map { directory.appendingPathComponent($0) }
    }

    private static let quarantineSuffixPrefix = ".stale-"

    func claim(_ inbound: SlackInboundMessage, now: Date = Date()) throws -> SlackInboundClaimOutcome {
        try CredentialFileLock.withLock(path) {
            var file = try load()
            if let existing = file.records.first(where: { $0.inbound.eventId == inbound.eventId }) {
                return existing.phase.isTerminal ? .alreadyDelivered : .claimed(existing)
            }
            let pending = file.records.filter { !$0.phase.isTerminal }.count
            guard pending < pendingCap else { throw SlackInboundJournalError.saturated(pendingCap) }
            let record = SlackInboundDeliveryRecord(
                lifeID: try DataRootLife.current(in: dataRoot),
                inbound: inbound,
                phase: .claimed,
                prepared: nil,
                dispatchStartedAt: nil,
                updatedAt: now,
                outcomeDetail: nil
            )
            file.records.append(record)
            try save(file)
            return .claimed(record)
        }
    }

    func acquireHandler(eventId: String) -> Bool {
        Self.handlerLock.withLock { Self.activeHandlers.insert(path.path + "\u{0}" + eventId).inserted }
    }

    /// Accepted human work belongs to the journal, not a socket session. Claim
    /// before launching, retain through settlement, and retire at actual exit.
    func startHandler(eventId: String, operation: @escaping @Sendable () async -> Void) {
        let key = path.path + "\u{0}" + eventId
        Self.handlerLock.withLock {
            guard Self.activeHandlers.insert(key).inserted else { return }
            Self.handlerTasks[key] = Task(priority: .userInitiated) {
                await operation()
                self.releaseHandler(eventId: eventId)
            }
        }
    }

    func reserveReply(_ inbound: SlackInboundMessage, reply: SlackPreparedReply, runId: String,
                      sessionId: String, priorVerdict: String?) throws -> SlackInboundDeliveryRecord {
        try CredentialFileLock.withLock(path) {
            var file = try load()
            if let record = file.records.first(where: { $0.inbound.eventId == inbound.eventId }) {
                guard record.assistantRunId == runId, record.assistantSessionId == sessionId,
                      record.prepared == reply, record.inbound.channelId == inbound.channelId,
                      record.inbound.threadTs == inbound.threadTs else { throw SlackInboundJournalError.malformed }
                return record
            }
            guard file.records.filter({ !$0.phase.isTerminal }).count < pendingCap else { throw SlackInboundJournalError.saturated(pendingCap) }
            let record = SlackInboundDeliveryRecord(lifeID: try DataRootLife.current(in: dataRoot), inbound: inbound,
                phase: priorVerdict == "completed" ? .delivered : priorVerdict == nil ? .prepared : .sentUnconfirmed,
                prepared: reply, dispatchStartedAt: nil, updatedAt: Date(),
                outcomeDetail: priorVerdict == "sent_unconfirmed" ? "legacy_completion_dispatch_unconfirmed" : nil,
                assistantRunId: runId, assistantSessionId: sessionId)
            file.records.append(record)
            try save(file)
            return record
        }
    }

    /// Durable once-only claim for waking bots on this message (0.4.12). The
    /// handler set above is in-memory, so recovery or a retry of an unresolved
    /// row would re-enter handling after a restart; this claim is persisted
    /// beside the delivery rows, in this actor's serialized write, so one
    /// accepted Slack message wakes a bot exactly once. A claim is trimmed only
    /// once its event has no unresolved row left.
    func claimBotEvent(eventId: String) throws -> Bool {
        try CredentialFileLock.withLock(path) {
            var file = try load()
            guard !file.botEventClaims.contains(eventId) else { return false }
            file.botEventClaims.append(eventId)
            if file.botEventClaims.count > Self.botEventClaimCap {
                let unresolved = Set(file.records.filter { !$0.phase.isTerminal }
                    .map { $0.inbound.eventId })
                var drops = file.botEventClaims.count - Self.botEventClaimCap
                file.botEventClaims = file.botEventClaims.filter { id in
                    guard drops > 0, id != eventId, !unresolved.contains(id) else { return true }
                    drops -= 1
                    return false
                }
            }
            try save(file)
            return true
        }
    }

    private static let botEventClaimCap = 1_000

    func releaseHandler(eventId: String) {
        Self.handlerLock.withLock {
            let key = path.path + "\u{0}" + eventId
            Self.handlerTasks.removeValue(forKey: key)
            Self.activeHandlers.remove(key)
        }
    }

    func prepare(eventId: String, reply: SlackPreparedReply, failedBeforeAnswer: Bool = false,
                 now: Date = Date()) throws -> SlackInboundDeliveryRecord {
        try mutate(eventId: eventId) { record in
            record.phase = .prepared
            record.prepared = reply
            record.dispatchStartedAt = nil
            record.updatedAt = now
            record.outcomeDetail = nil
            record.failedBeforeAnswer = failedBeforeAnswer
        }
    }

    func beginGeneration(eventId: String, runId: String, sessionId: String, now: Date = Date()) throws -> SlackInboundDeliveryRecord {
        try mutate(eventId: eventId) { record in
            record.phase = .generating
            record.updatedAt = now
            record.outcomeDetail = nil
            record.assistantRunId = runId
            record.assistantSessionId = sessionId
            record.assistantOriginRunId = runId
        }
    }

    func beginDispatch(eventId: String, now: Date = Date()) throws -> SlackInboundDeliveryRecord {
        try mutate(eventId: eventId) { record in
            record.phase = .dispatching
            record.dispatchStartedAt = now
            record.updatedAt = now
            record.outcomeDetail = nil
        }
    }

    func retryPrepared(eventId: String, detail: String, rejectionReason: String? = nil, now: Date = Date()) throws -> SlackInboundDeliveryRecord {
        try mutate(eventId: eventId) { record in
            if record.phase == .prepared, record.outcomeDetail == detail,
               rejectionReason == nil || record.lastRejection?.preparedFingerprint == record.prepared?.fingerprint { return }
            record.phase = .prepared
            record.dispatchStartedAt = nil
            record.updatedAt = now
            record.outcomeDetail = detail
            if let rejectionReason, let prepared = record.prepared {
                record.lastRejection = .init(reason: rejectionReason, preparedFingerprint: prepared.fingerprint, at: now)
            }
        }
    }

    func markDelivered(eventId: String, now: Date = Date()) throws -> SlackInboundDeliveryRecord {
        try mutate(eventId: eventId) { record in
            record.phase = record.failedBeforeAnswer == true ? .failedBeforeAnswer : .delivered
            record.updatedAt = now
            record.outcomeDetail = nil
        }
    }

    func confirmReplyPart(eventId: String, isText: Bool) throws -> SlackInboundDeliveryRecord {
        try mutate(eventId: eventId) {
            if isText { $0.confirmedText = true }
            else {
                let count = $0.confirmedUploadCount ?? 0
                guard count < ($0.prepared?.uploads.count ?? 0) else { throw SlackInboundJournalError.malformed }
                $0.confirmedUploadCount = count + 1
            }
            $0.phase = .prepared
            $0.dispatchStartedAt = nil
            $0.updatedAt = Date()
        }
    }

    func markOutcomeUnknown(eventId: String, detail: String, now: Date = Date()) throws -> SlackInboundDeliveryRecord {
        try mutate(eventId: eventId) { record in
            record.phase = .outcomeUnknown
            record.updatedAt = now
            record.outcomeDetail = detail
        }
    }

    func settleUnconfirmed(eventId: String, failedBeforeAnswer: Bool = false) throws -> SlackInboundDeliveryRecord {
        try mutate(eventId: eventId) {
            $0.phase = failedBeforeAnswer || $0.failedBeforeAnswer == true ? .failedBeforeAnswer : .sentUnconfirmed
            $0.updatedAt = Date()
        }
    }

    func unresolved() throws -> [SlackInboundDeliveryRecord] {
        try load().records
            .filter { !$0.phase.isTerminal }
            .sorted { $0.updatedAt < $1.updatedAt }
    }

    func record(eventId: String) throws -> SlackInboundDeliveryRecord? {
        try load().records.first { $0.inbound.eventId == eventId }
    }

    func answerRecord(runId: String, originRunId: String) throws -> SlackInboundDeliveryRecord? {
        try load().records.first { $0.assistantRunId == runId || $0.assistantRunId == originRunId || $0.assistantOriginRunId == originRunId || $0.settledAssistantRuns?[runId] != nil }
    }

    func savedUnconfirmedReply(for inbound: SlackInboundMessage) throws -> SlackInboundDeliveryRecord? {
        try load().records.filter {
            $0.phase == .sentUnconfirmed && $0.inbound.teamId == inbound.teamId
                && $0.inbound.channelId == inbound.channelId && $0.inbound.userId == inbound.userId
                && ($0.inbound.threadTs == inbound.threadTs
                    || inbound.threadTs != nil && $0.inbound.replyThreadTs == inbound.threadTs)
        }.max { $0.updatedAt < $1.updatedAt }
    }

    func retryRejectedReply(for inbound: SlackInboundMessage) throws -> SlackInboundDeliveryRecord? {
        try CredentialFileLock.withLock(path) {
            var file = try load()
            guard let command = file.records.firstIndex(where: { $0.inbound.eventId == inbound.eventId && $0.phase == .claimed }),
                  let rejected = file.records.indices.filter({ index in
                      let record = file.records[index]
                      return record.phase == .prepared && record.lastRejection != nil
                          && record.lastRejection?.preparedFingerprint == record.prepared?.fingerprint
                          && record.inbound.teamId == inbound.teamId && record.inbound.channelId == inbound.channelId
                          && record.inbound.userId == inbound.userId
                          && (record.inbound.threadTs == inbound.threadTs
                              || inbound.threadTs != nil && record.inbound.replyThreadTs == inbound.threadTs)
                  }).max(by: { file.records[$0].updatedAt < file.records[$1].updatedAt }) else { return nil }
            file.records[rejected].lastRejection = nil
            file.records[rejected].outcomeDetail = nil
            file.records[rejected].updatedAt = Date()
            // Consume the command with the reset so recovery cannot repeatedly clear a new rejection.
            file.records[command].prepared = file.records[rejected].prepared
            file.records[command].phase = .delivered
            file.records[command].updatedAt = Date()
            let record = file.records[rejected]
            try save(file)
            return record
        }
    }

    func prepareSuccessor(eventId: String, response: SlackPreparedReply, runId: String, sessionId: String) throws {
        _ = try mutate(eventId: eventId) {
            if let priorRun = $0.assistantRunId { $0.settledAssistantRuns = ($0.settledAssistantRuns ?? [:]).merging([priorRun: $0.phase.rawValue], uniquingKeysWith: { first, _ in first }) }
            $0.assistantOriginRunId = $0.assistantOriginRunId ?? $0.assistantRunId
            $0.assistantRunId = runId; $0.assistantSessionId = sessionId
            $0.prepared = response; $0.phase = .prepared; $0.failedBeforeAnswer = false; $0.dispatchStartedAt = nil; $0.updatedAt = Date()
            $0.confirmedText = nil; $0.confirmedUploadCount = nil
        }
    }

    private func mutate(
        eventId: String,
        update: (inout SlackInboundDeliveryRecord) throws -> Void
    ) throws -> SlackInboundDeliveryRecord {
        try CredentialFileLock.withLock(path) {
            var file = try load()
            guard let index = file.records.firstIndex(where: { $0.inbound.eventId == eventId }) else {
                throw SlackInboundJournalError.missingClaim(eventId)
            }
            let previous = file.records[index]
            try update(&file.records[index])
            let result = file.records[index]
            if result != previous { try save(file) }
            return result
        }
    }

    private func load() throws -> File {
        try Self.loadFile(path: path)
    }

    nonisolated private static func loadFile(path: URL) throws -> File {
        guard FileManager.default.fileExists(atPath: path.path) else { return File() }
        let data = try Data(contentsOf: path)
        do {
            let decoder = JSONDecoder()
            decoder.dateDecodingStrategy = .iso8601
            var file = try decoder.decode(File.self, from: data)
            guard file.version == 1,
                  Set(file.records.map { $0.inbound.eventId }).count == file.records.count,
                  file.records.allSatisfy({
                      !$0.inbound.eventId.isEmpty && $0.hasValidUploadProgress
                        && ($0.phase == .claimed || $0.phase == .generating || $0.phase == .interrupted
                            || $0.phase == .outcomeUnknown || $0.phase == .failedBeforeAnswer || $0.phase == .stopped || $0.prepared != nil)
                  }) else { throw SlackInboundJournalError.malformed }
            let life = try DataRootLife.current(in: path.deletingLastPathComponent().deletingLastPathComponent())
            for i in file.records.indices where file.records[i].phase != .delivered && DataRootLife.life(of: file.records[i].lifeID) != life {
                file.records[i].phase = .stopped
                file.records[i].outcomeDetail = DataRootLife.stoppedReason
            }
            return file
        } catch {
            // Unreadable replay evidence cannot authorize a fresh admission.
            throw SlackInboundJournalError.malformed
        }
    }

    private func save(_ source: File) throws {
        guard source.records.allSatisfy(\.hasValidUploadProgress) else { throw SlackInboundJournalError.malformed }
        var file = source
        let terminal = file.records
            .filter { $0.phase.isTerminal }
            .sorted { $0.updatedAt > $1.updatedAt }
        let unresolved = file.records.filter { !$0.phase.isTerminal }
        let referenced = try? CodexCompletionReadout.unsettledAnswerRuns(
            configRoot: InstallPaths.current.bridgeConfigRoot(dataRoot: dataRoot), dataRoot: dataRoot)
        let protected = terminal.filter { record in
            guard let referenced else { return true }
            return !Set(record.settledAssistantRuns?.keys.map { $0 } ?? [])
                .union([record.assistantRunId, record.assistantOriginRunId].compactMap { $0 }).isDisjoint(with: referenced)
        }
        file.records = unresolved + protected + terminal.filter { !protected.contains($0) }.prefix(terminalCap)
        file.pendingLimit = pendingCap
        let directory = path.deletingLastPathComponent()
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        // Creation-time 0600, not chmod after publication: the existing slack
        // directory may be 0755 and these rows contain private message bodies.
        guard NativePrivateFile.write(try encoder.encode(file), to: path) else {
            throw CocoaError(.fileWriteUnknown)
        }
    }
}
