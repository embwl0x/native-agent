import Foundation
import Darwin
import ChatOrchestration
import NativeAgentCore
import PersistenceCore

/// Why a terminal phase is trustworthy. The value is deliberately closed and
/// payload-free so a presentation state can explain its confidence without
/// retaining provider output, tool arguments, or transport bodies.
enum MacChatTurnTerminalEvidence: String, Codable, Sendable, Equatable {
    case finalResponsePersisted = "final_response_persisted"
    case explicitTypedFailure = "explicit_typed_failure"
    case cancellationAcknowledged = "cancellation_acknowledged"
    case interruptedOutcomeUnknown = "interrupted_outcome_unknown"
}

/// The one Mac-owned lifecycle state for an accepted turn. Operational
/// activity and terminal evidence both reduce into the same shared-kernel
/// presentation value; cancellation request is separate because requesting a
/// stop is not proof that the turn stopped.
struct MacChatTurnLifecycleState: Sendable, Equatable {
    let identity: MacChatTurnIdentity
    let presentation: TurnPresentationState
    let cancellationRequestedAt: Date?
    let terminalEvidence: MacChatTurnTerminalEvidence?

    init(identity: MacChatTurnIdentity, startedAt: Date) {
        self.identity = identity
        presentation = TurnPresentationReducer.initialState(at: startedAt)
        cancellationRequestedAt = nil
        terminalEvidence = nil
    }

    init(
        identity: MacChatTurnIdentity,
        presentation: TurnPresentationState,
        cancellationRequestedAt: Date?,
        terminalEvidence: MacChatTurnTerminalEvidence?
    ) {
        self.identity = identity
        self.presentation = presentation
        self.cancellationRequestedAt = cancellationRequestedAt
        self.terminalEvidence = terminalEvidence
    }

    func effectivePhase(
        at instant: Date,
        stalledAfter: TimeInterval = TurnPresentationReducer.defaultStalledAfter
    ) -> TurnPresentationPhase {
        TurnPresentationReducer.effectivePhase(
            presentation,
            secondsSinceMovement: max(0, instant.timeIntervalSince(presentation.lastMovementAt)),
            stalledAfter: stalledAfter
        )
    }
}

struct MacChatTurnLifecycleInput: Sendable, Equatable {
    enum Kind: Sendable, Equatable {
        case working(action: String?)
        case activity(MacChatTurnActivity)
        case streamProgress(accumulatedUTF16Length: Int)
        case retrying(action: String?)
        case waiting(action: String?)
        case blocked(reason: String?)
        case cancellationRequested
        case completed
        case failed(reason: String?)
        case cancellationConfirmed
        case outcomeUnknown(reason: String?)
    }

    let identity: MacChatTurnIdentity
    let kind: Kind
    let occurredAt: Date
}

enum MacChatTurnLifecycleReducer {
    static func reduce(
        _ state: MacChatTurnLifecycleState,
        input: MacChatTurnLifecycleInput
    ) -> MacChatTurnLifecycleState {
        guard input.identity == state.identity, !state.presentation.isTerminal else {
            return state
        }

        let nextPresentation: TurnPresentationState
        let nextCancellationRequestedAt: Date?
        let nextTerminalEvidence: MacChatTurnTerminalEvidence?

        switch input.kind {
        case .working(let action):
            nextPresentation = lifecycle(
                state.presentation,
                .working(action: action),
                at: input.occurredAt
            )
            nextCancellationRequestedAt = state.cancellationRequestedAt
            nextTerminalEvidence = nil
        case .activity(let activity):
            // Activity is movement evidence only. A malformed boundary value
            // must never smuggle in an immutable terminal without the closed
            // terminal-evidence vocabulary below.
            guard activity.identity == state.identity,
                  !activity.phase.isTerminal else { return state }
            nextPresentation = TurnPresentationReducer.recordActivity(
                state.presentation,
                phase: activity.phase,
                detail: activity.actionSummary,
                delegateName: activity.delegateDisplayName,
                at: activity.occurredAt,
                resetStreamLength: activity.phase == .retrying,
                additionalRedactor: additionalRedactor
            )
            nextCancellationRequestedAt = state.cancellationRequestedAt
            nextTerminalEvidence = nil
        case .streamProgress(let accumulatedUTF16Length):
            nextPresentation = TurnPresentationReducer.recordStreamProgress(
                state.presentation,
                accumulatedUTF16Length: accumulatedUTF16Length,
                at: input.occurredAt
            )
            nextCancellationRequestedAt = state.cancellationRequestedAt
            nextTerminalEvidence = nil
        case .retrying(let action):
            nextPresentation = lifecycle(
                state.presentation,
                .retrying(action: action),
                at: input.occurredAt
            )
            nextCancellationRequestedAt = state.cancellationRequestedAt
            nextTerminalEvidence = nil
        case .waiting(let action):
            nextPresentation = lifecycle(
                state.presentation,
                .waiting(action: action),
                at: input.occurredAt
            )
            nextCancellationRequestedAt = state.cancellationRequestedAt
            nextTerminalEvidence = nil
        case .blocked(let reason):
            nextPresentation = lifecycle(
                state.presentation,
                .blocked(reason: reason),
                at: input.occurredAt
            )
            nextCancellationRequestedAt = state.cancellationRequestedAt
            nextTerminalEvidence = nil
        case .cancellationRequested:
            nextPresentation = state.presentation
            let requestedAt = max(input.occurredAt, state.presentation.startedAt)
            nextCancellationRequestedAt = state.cancellationRequestedAt.map {
                min($0, requestedAt)
            } ?? requestedAt
            nextTerminalEvidence = nil
        case .completed:
            nextPresentation = lifecycle(
                state.presentation,
                .completed(summary: nil),
                at: max(input.occurredAt, state.cancellationRequestedAt ?? input.occurredAt)
            )
            nextCancellationRequestedAt = state.cancellationRequestedAt
            nextTerminalEvidence = .finalResponsePersisted
        case .failed(let reason):
            nextPresentation = lifecycle(
                state.presentation,
                .failed(reason: reason),
                at: max(input.occurredAt, state.cancellationRequestedAt ?? input.occurredAt)
            )
            nextCancellationRequestedAt = state.cancellationRequestedAt
            nextTerminalEvidence = .explicitTypedFailure
        case .cancellationConfirmed:
            nextPresentation = lifecycle(
                state.presentation,
                .canceled(reason: nil),
                at: max(input.occurredAt, state.cancellationRequestedAt ?? input.occurredAt)
            )
            nextCancellationRequestedAt = state.cancellationRequestedAt
            nextTerminalEvidence = .cancellationAcknowledged
        case .outcomeUnknown(let reason):
            nextPresentation = lifecycle(
                state.presentation,
                .outcomeUnknown(reason: reason),
                at: max(input.occurredAt, state.cancellationRequestedAt ?? input.occurredAt)
            )
            nextCancellationRequestedAt = state.cancellationRequestedAt
            nextTerminalEvidence = .interruptedOutcomeUnknown
        }

        guard nextPresentation != state.presentation
                || nextCancellationRequestedAt != state.cancellationRequestedAt
                || nextTerminalEvidence != state.terminalEvidence else {
            return state
        }
        return MacChatTurnLifecycleState(
            identity: state.identity,
            presentation: nextPresentation,
            cancellationRequestedAt: nextCancellationRequestedAt,
            terminalEvidence: nextTerminalEvidence
        )
    }

    private static func lifecycle(
        _ state: TurnPresentationState,
        _ event: TurnPresentationLifecycleEvent,
        at instant: Date
    ) -> TurnPresentationState {
        TurnPresentationReducer.reduce(
            state,
            lifecycle: event,
            at: instant,
            additionalRedactor: additionalRedactor
        )
    }

    private static let additionalRedactor: TurnPresentationReducer.AdditionalRedactor = {
        NativeAppSecretRedactor.redactText($0)
    }
}

/// Minimal durable projection of the authoritative state. It stores no prompt,
/// reply, raw tool/provider material, or accumulated stream text.
struct MacChatPersistedTurnLifecycle: Codable, Sendable, Equatable {
    let sessionId: String
    let turnId: String
    let phase: TurnPresentationPhase
    let startedAt: Date
    let lastMovementAt: Date
    let endedAt: Date?
    let currentAction: String?
    let delegateName: String?
    let cancellationRequestedAt: Date?
    let terminalEvidence: MacChatTurnTerminalEvidence?

    init?(state: MacChatTurnLifecycleState) {
        guard let sessionId = NativeAgentChatSessionID.normalizedPathComponent(
                  state.identity.sessionId
              ),
              sessionId == state.identity.sessionId,
              let turnId = Self.safeIdentity(state.identity.turnId, limit: 128),
              turnId == state.identity.turnId else {
            return nil
        }
        let presentation = state.presentation
        guard presentation.startedAt.timeIntervalSince1970.isFinite,
              presentation.lastMovementAt.timeIntervalSince1970.isFinite,
              presentation.lastMovementAt >= presentation.startedAt,
              presentation.endedAt.map({
                  $0.timeIntervalSince1970.isFinite && $0 == presentation.lastMovementAt
              }) ?? true,
              state.cancellationRequestedAt.map({
                  $0.timeIntervalSince1970.isFinite && $0 >= presentation.startedAt
              }) ?? true,
              state.cancellationRequestedAt.map({ requestedAt in
                  presentation.endedAt.map { requestedAt <= $0 } ?? true
              }) ?? true else {
            return nil
        }
        self.sessionId = sessionId
        self.turnId = turnId
        phase = presentation.phase
        startedAt = presentation.startedAt
        lastMovementAt = presentation.lastMovementAt
        endedAt = presentation.endedAt
        currentAction = Self.safeText(presentation.currentAction)
        delegateName = Self.safeText(presentation.delegateName)
        cancellationRequestedAt = state.cancellationRequestedAt
        terminalEvidence = state.terminalEvidence
        guard hasValidTerminalPairing else { return nil }
    }

    var identity: MacChatTurnIdentity {
        MacChatTurnIdentity(sessionId: sessionId, turnId: turnId)
    }

    var updatedAt: Date {
        endedAt ?? cancellationRequestedAt ?? lastMovementAt
    }

    var isTerminal: Bool { phase.isTerminal }

    func restoredState() -> MacChatTurnLifecycleState? {
        guard NativeAgentChatSessionID.normalizedPathComponent(sessionId) == sessionId,
              Self.safeIdentity(turnId, limit: 128) == turnId,
              Self.safeText(currentAction) == currentAction,
              Self.safeText(delegateName) == delegateName,
              startedAt.timeIntervalSince1970.isFinite,
              lastMovementAt.timeIntervalSince1970.isFinite,
              lastMovementAt >= startedAt,
              endedAt.map({ $0.timeIntervalSince1970.isFinite && $0 >= lastMovementAt }) ?? true,
              endedAt.map({ $0 == lastMovementAt }) ?? true,
              cancellationRequestedAt.map({
                  $0.timeIntervalSince1970.isFinite && $0 >= startedAt
              }) ?? true,
              cancellationRequestedAt.map({ requestedAt in
                  endedAt.map { requestedAt <= $0 } ?? true
              }) ?? true,
              phase.isTerminal == (endedAt != nil),
              hasValidTerminalPairing else {
            return nil
        }

        var presentation = TurnPresentationReducer.initialState(at: startedAt)
        if phase != .acknowledged {
            presentation = TurnPresentationReducer.recordActivity(
                presentation,
                phase: phase,
                detail: Self.safeText(currentAction),
                delegateName: Self.safeText(delegateName),
                at: lastMovementAt,
                resetStreamLength: phase == .retrying,
                additionalRedactor: { NativeAppSecretRedactor.redactText($0) }
            )
        }
        return MacChatTurnLifecycleState(
            identity: identity,
            presentation: presentation,
            cancellationRequestedAt: cancellationRequestedAt,
            terminalEvidence: terminalEvidence
        )
    }

    private var hasValidTerminalPairing: Bool {
        switch (phase, terminalEvidence) {
        case (.completed, .finalResponsePersisted),
             (.failed, .explicitTypedFailure),
             (.canceled, .cancellationAcknowledged),
             (.outcomeUnknown, .interruptedOutcomeUnknown):
            return true
        case (.acknowledged, nil), (.working, nil), (.tool, nil),
             (.delegation, nil), (.retrying, nil), (.waiting, nil),
             (.blocked, nil), (.stalled, nil):
            return true
        default:
            return false
        }
    }

    private static func safeIdentity(_ raw: String, limit: Int) -> String? {
        let value = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !value.isEmpty,
              value.unicodeScalars.count <= limit,
              value.utf8.count <= limit * 4,
              value.unicodeScalars.allSatisfy({
                  !CharacterSet.controlCharacters.contains($0)
              }) else {
            return nil
        }
        return value
    }

    private static func safeText(_ raw: String?) -> String? {
        guard let sanitized = TurnPresentationReducer.sanitized(
            raw,
            additionalRedactor: { NativeAppSecretRedactor.redactText($0) }
        ) else { return nil }
        let scalars = sanitized.unicodeScalars
        guard scalars.count > TurnPresentationReducer.textLimit else { return sanitized }
        return String(scalars.prefix(TurnPresentationReducer.textLimit - 1)) + "…"
    }
}

protocol MacChatTurnLifecycleStorage: Sendable {
    func load() async throws -> [MacChatPersistedTurnLifecycle]
    func save(_ records: [MacChatPersistedTurnLifecycle]) async throws
}

struct MacChatTurnLifecycleFileStorage: MacChatTurnLifecycleStorage {
    static let maximumBytes = 512 * 1_024

    private struct Envelope: Codable, Sendable {
        let schemaVersion: Int
        let turns: [MacChatPersistedTurnLifecycle]
    }

    let fileURL: URL

    func load() async throws -> [MacChatPersistedTurnLifecycle] {
        var info = stat()
        let result = fileURL.path.withCString { lstat($0, &info) }
        if result != 0 {
            guard errno == ENOENT else {
                throw MacChatTurnLifecycleStoreError.invalidRecord
            }
            return []
        }
        guard (info.st_mode & S_IFMT) == S_IFREG,
              info.st_size >= 0,
              info.st_size <= off_t(Self.maximumBytes) else {
            throw MacChatTurnLifecycleStoreError.invalidRecord
        }
        let envelope = try JSONDecoder().decode(Envelope.self, from: Data(contentsOf: fileURL))
        guard envelope.schemaVersion == 1 else {
            throw MacChatTurnLifecycleStoreError.unsupportedSchema
        }
        return envelope.turns
    }

    func save(_ records: [MacChatPersistedTurnLifecycle]) async throws {
        let envelope = Envelope(schemaVersion: 1, turns: records)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        let data = try encoder.encode(envelope)
        guard data.count <= Self.maximumBytes else {
            throw MacChatTurnLifecycleStoreError.invalidRecord
        }
        try await SwiftNativePersistenceCore().writeDataAtomicDurable(data, to: fileURL)
    }
}

enum MacChatTurnLifecycleStoreError: Error, Sendable, Equatable {
    case capacityExceeded(Int)
    case invalidRecord
    case missingExactTurn
    case unsupportedSchema
}

/// Bounded actor-owned persistence for the same lifecycle state AppModel
/// projects. Begin may replace the prior turn for a session; every later write
/// is exact-turn-only so a stale task cannot overwrite a newer generation.
actor MacChatTurnLifecycleStore {
    static var liveFileURL: URL {
        PersistenceCore.defaultDataRoot()
            .appendingPathComponent("chat", isDirectory: true)
            .appendingPathComponent("mac_turn_lifecycle.json")
    }

    private let storage: any MacChatTurnLifecycleStorage
    private let maximumRecords: Int
    private var loadedRecords: [MacChatPersistedTurnLifecycle]?
    private var mutationInProgress = false
    private var mutationWaiters: [CheckedContinuation<Void, Never>] = []

    init(storage: any MacChatTurnLifecycleStorage, maximumRecords: Int = 64) {
        self.storage = storage
        self.maximumRecords = max(1, maximumRecords)
    }

    init(fileURL: URL = MacChatTurnLifecycleStore.liveFileURL, maximumRecords: Int = 64) {
        storage = MacChatTurnLifecycleFileStorage(fileURL: fileURL)
        self.maximumRecords = max(1, maximumRecords)
    }

    func begin(_ state: MacChatTurnLifecycleState) async throws {
        await acquireMutation()
        defer { releaseMutation() }
        guard let record = MacChatPersistedTurnLifecycle(state: state),
              !record.isTerminal else {
            throw MacChatTurnLifecycleStoreError.invalidRecord
        }
        var records = try await currentRecords()
        let addingSession = !records.contains { $0.sessionId == record.sessionId }
        if addingSession, records.count >= maximumRecords {
            // Never evict an accepted turn whose outcome still needs repair.
            // Old terminal projections are presentation history only, so the
            // oldest one is the safe bounded-capacity victim.
            guard let terminalIndex = records.firstIndex(where: \.isTerminal) else {
                throw MacChatTurnLifecycleStoreError.capacityExceeded(maximumRecords)
            }
            records.remove(at: terminalIndex)
        }
        records.removeAll { $0.sessionId == record.sessionId }
        records.append(record)
        try await commit(records)
    }

    @discardableResult
    func update(_ state: MacChatTurnLifecycleState) async throws -> Bool {
        await acquireMutation()
        defer { releaseMutation() }
        guard let record = MacChatPersistedTurnLifecycle(state: state) else {
            throw MacChatTurnLifecycleStoreError.invalidRecord
        }
        var records = try await currentRecords()
        guard let index = records.firstIndex(where: {
            $0.sessionId == record.sessionId && $0.turnId == record.turnId
        }) else { return false }
        if records[index].isTerminal { return records[index] == record }
        records[index] = record
        try await commit(records)
        return true
    }

    @discardableResult
    func migrate(
        state: MacChatTurnLifecycleState,
        from oldSessionId: String
    ) async throws -> Bool {
        await acquireMutation()
        defer { releaseMutation() }
        guard let record = MacChatPersistedTurnLifecycle(state: state) else {
            throw MacChatTurnLifecycleStoreError.invalidRecord
        }
        var records = try await currentRecords()
        guard let oldIndex = records.firstIndex(where: {
            $0.sessionId == oldSessionId && $0.turnId == record.turnId
        }) else { return false }
        records.remove(at: oldIndex)
        // Process-level routing already excludes a concurrently active
        // destination generation. A remaining destination row is bounded
        // restart history (terminal or orphaned), which the current exact
        // accepted turn supersedes.
        records.removeAll { $0.sessionId == record.sessionId }
        records.append(record)
        try await commit(records)
        return true
    }

    func remove(sessionId: String, turnId: String? = nil) async throws {
        await acquireMutation()
        defer { releaseMutation() }
        var records = try await currentRecords()
        let priorCount = records.count
        records.removeAll { record in
            record.sessionId == sessionId && (turnId == nil || record.turnId == turnId)
        }
        guard records.count != priorCount else { return }
        try await commit(records)
    }

    func records() async throws -> [MacChatPersistedTurnLifecycle] {
        await acquireMutation()
        defer { releaseMutation() }
        return try await currentRecords()
    }

    private func currentRecords() async throws -> [MacChatPersistedTurnLifecycle] {
        if let loadedRecords { return loadedRecords }
        let loaded = try await storage.load()
        guard loaded.count <= maximumRecords,
              loaded.allSatisfy({ $0.restoredState() != nil }),
              Set(loaded.map(\.sessionId)).count == loaded.count else {
            throw MacChatTurnLifecycleStoreError.invalidRecord
        }
        let sorted = Self.sorted(loaded)
        loadedRecords = sorted
        return sorted
    }

    private func commit(_ records: [MacChatPersistedTurnLifecycle]) async throws {
        let sorted = Self.sorted(records)
        try await storage.save(sorted)
        loadedRecords = sorted
    }

    private func acquireMutation() async {
        guard mutationInProgress else {
            mutationInProgress = true
            return
        }
        await withCheckedContinuation { continuation in
            mutationWaiters.append(continuation)
        }
    }

    private func releaseMutation() {
        guard !mutationWaiters.isEmpty else {
            mutationInProgress = false
            return
        }
        mutationWaiters.removeFirst().resume()
    }

    private static func sorted(
        _ records: [MacChatPersistedTurnLifecycle]
    ) -> [MacChatPersistedTurnLifecycle] {
        records.sorted {
            if $0.updatedAt == $1.updatedAt { return $0.sessionId < $1.sessionId }
            return $0.updatedAt < $1.updatedAt
        }
    }
}

enum MacChatTurnTranscriptTerminalProof: Sendable, Equatable {
    case completed
    case failed
    case canceled
    case absent
    case unavailable
}

protocol MacChatTurnTranscriptProofReading: Sendable {
    func proof(for identity: MacChatTurnIdentity) async throws -> MacChatTurnTranscriptTerminalProof
}

enum MacChatTurnTranscriptProofReaderError: Error, Sendable, Equatable {
    case invalidEvidence
}

/// Strict, bounded reader for the canonical transcript receipt. Only the
/// payload-free terminal classification escapes this boundary; model text,
/// tool rows, provider material, and metadata dictionaries are discarded.
actor MacChatTurnTranscriptProofReader: MacChatTurnTranscriptProofReading {
    static let maximumBytes = 2 * 1_024 * 1_024
    static let maximumLines = 512

    private let dataRoot: URL
    private let persistence = SwiftNativePersistenceCore()

    init(dataRoot: URL = PersistenceCore.defaultDataRoot()) {
        self.dataRoot = dataRoot
    }

    func proof(
        for identity: MacChatTurnIdentity
    ) async throws -> MacChatTurnTranscriptTerminalProof {
        guard let safeSessionId = NativeAgentChatSessionID.normalizedPathComponent(
            identity.sessionId
        ) else {
            throw MacChatTurnTranscriptProofReaderError.invalidEvidence
        }
        let path = dataRoot
            .appendingPathComponent("chat", isDirectory: true)
            .appendingPathComponent("messages", isDirectory: true)
            .appendingPathComponent("\(safeSessionId).jsonl")
        var info = stat()
        let result = path.path.withCString { lstat($0, &info) }
        if result != 0 {
            guard errno == ENOENT else {
                throw MacChatTurnTranscriptProofReaderError.invalidEvidence
            }
            return .absent
        }
        guard (info.st_mode & S_IFMT) == S_IFREG else {
            // `fileExists` follows symlinks and reports a dangling symlink as
            // absent. Both forms make canonical evidence unavailable, not a
            // trustworthy negative receipt.
            throw MacChatTurnTranscriptProofReaderError.invalidEvidence
        }
        return try await persistence.withFileLock(path) {
            try Self.readLocked(path: path, identity: identity)
        }
    }

    private nonisolated static func readLocked(
        path: URL,
        identity: MacChatTurnIdentity
    ) throws -> MacChatTurnTranscriptTerminalProof {
        let values = try path.resourceValues(forKeys: [
            .isRegularFileKey,
            .isSymbolicLinkKey,
            .fileSizeKey,
        ])
        guard values.isRegularFile == true,
              values.isSymbolicLink != true,
              let fileSize = values.fileSize,
              fileSize >= 0 else {
            throw MacChatTurnTranscriptProofReaderError.invalidEvidence
        }
        guard fileSize > 0 else { return .absent }

        let handle = try FileHandle(forReadingFrom: path)
        defer { try? handle.close() }
        let byteCount = min(fileSize, maximumBytes)
        let start = fileSize - byteCount
        try handle.seek(toOffset: UInt64(start))
        var data = try handle.read(upToCount: byteCount) ?? Data()
        if start > 0 {
            guard let newline = data.firstIndex(of: 0x0A) else {
                throw MacChatTurnTranscriptProofReaderError.invalidEvidence
            }
            data.removeSubrange(data.startIndex...newline)
        }
        guard data.isEmpty || data.last == 0x0A,
              let text = String(data: data, encoding: .utf8) else {
            throw MacChatTurnTranscriptProofReaderError.invalidEvidence
        }
        var lines = text.components(separatedBy: "\n")
        if lines.last?.isEmpty == true { lines.removeLast() }
        guard lines.allSatisfy({ !$0.trimmingCharacters(in: .whitespaces).isEmpty }) else {
            throw MacChatTurnTranscriptProofReaderError.invalidEvidence
        }
        if lines.count > maximumLines {
            lines = Array(lines.suffix(maximumLines))
        }

        var rows: [[String: JSONValue]] = []
        rows.reserveCapacity(lines.count)
        for line in lines {
            guard let data = line.data(using: .utf8),
                  case .object(let row) = try JSONValue.parse(data) else {
                throw MacChatTurnTranscriptProofReaderError.invalidEvidence
            }
            rows.append(row)
        }
        return try classify(rows: rows, identity: identity)
    }

    private nonisolated static func classify(
        rows: [[String: JSONValue]],
        identity: MacChatTurnIdentity
    ) throws -> MacChatTurnTranscriptTerminalProof {
        for row in rows.reversed() {
            guard case .string("assistant")? = row["role"],
                  case .object(let metadata)? = row["metadata"],
                  case .string(let turnId)? = metadata["turnTraceId"],
                  turnId == identity.turnId else {
                continue
            }
            guard
                  case .string(let rowMessageId)? = row["id"],
                  case .string(let rowSessionId)? = row["sessionId"],
                  rowSessionId == identity.sessionId,
                  case .string(let rowSource)? = row["source"],
                  case .object(let observation)? = metadata["outcomeObservation"],
                  let receipt = ResponseOutcomeObservationV2(jsonValue: .object(observation)),
                  receipt.turnID == identity.turnId,
                  receipt.messageID == rowMessageId,
                  receipt.sessionID == identity.sessionId,
                  receipt.surface == rowSource else {
                throw MacChatTurnTranscriptProofReaderError.invalidEvidence
            }
            let partial = try strictBoolean(metadata["partial"])
            let canceled = try strictBoolean(metadata["cancelled"])
            switch receipt.responsePersistence {
            case "persisted" where !partial && !canceled:
                return .completed
            case "failed" where !partial && !canceled:
                return .failed
            case "cancelled" where partial && canceled:
                return .canceled
            default:
                return .absent
            }
        }
        return .absent
    }

    private nonisolated static func strictBoolean(_ value: JSONValue?) throws -> Bool {
        switch value {
        case nil:
            return false
        case .bool(let value):
            return value
        default:
            throw MacChatTurnTranscriptProofReaderError.invalidEvidence
        }
    }
}

/// Process-local terminal signal retained by the stream adapter. A final is
/// intentionally weaker than transcript proof because the text-compatibility
/// lane can emit it before its durable assistant append finishes.
enum MacChatTurnObservedTerminalSignal: Sendable, Equatable {
    case finalResponse
    case explicitFailure(String)
    /// A cancellation this process observed as a TYPED event at its own
    /// boundary. Never derived from provider or transport text.
    case cancellationAcknowledged
    /// The turn ended on a terminal whose meaning untyped text cannot settle
    /// (classically an error body that reads exactly "cancelled"). This is
    /// deliberately weaker than every other signal: it can only ever resolve
    /// to outcome-unknown, so a failure can never be laundered into a quiet
    /// cancel and a cancel can never be laundered into a failure.
    case ambiguousTermination
    case none
}

enum MacChatTurnLifecycleTerminalResolver {
    static func signalAfterConsumerCancellation(
        _ observedSignal: MacChatTurnObservedTerminalSignal
    ) -> MacChatTurnObservedTerminalSignal {
        switch observedSignal {
        case .explicitFailure, .cancellationAcknowledged, .ambiguousTermination:
            return observedSignal
        case .finalResponse, .none:
            return .none
        }
    }

    static func resolve(
        transcriptProof: MacChatTurnTranscriptTerminalProof,
        observedSignal: MacChatTurnObservedTerminalSignal
    ) -> MacChatTurnLifecycleInput.Kind {
        // Canonical exact-turn persistence outranks a later transport error.
        switch transcriptProof {
        case .completed:
            return .completed
        case .failed:
            return .failed(reason: nil)
        case .canceled:
            return .cancellationConfirmed
        case .absent:
            break
        case .unavailable:
            return .outcomeUnknown(
                reason: "Canonical turn evidence could not be read safely."
            )
        }

        switch observedSignal {
        case .cancellationAcknowledged:
            return .cancellationConfirmed
        case .explicitFailure(let reason):
            return .failed(reason: reason)
        case .ambiguousTermination:
            return .outcomeUnknown(
                reason: "The turn stopped without a provable cancellation receipt."
            )
        case .finalResponse, .none:
            return .outcomeUnknown(
                reason: "The turn ended without a provable terminal outcome."
            )
        }
    }
}

enum MacChatTurnLifecycleRestartRepair {
    static func repair(
        record: MacChatPersistedTurnLifecycle,
        transcriptProof: MacChatTurnTranscriptTerminalProof,
        at instant: Date
    ) -> MacChatTurnLifecycleState? {
        guard let restored = record.restoredState() else { return nil }
        guard !restored.presentation.isTerminal else { return restored }
        let kind: MacChatTurnLifecycleInput.Kind
        switch transcriptProof {
        case .completed: kind = .completed
        case .failed: kind = .failed(reason: nil)
        case .canceled: kind = .cancellationConfirmed
        case .absent:
            kind = .outcomeUnknown(
                reason: "The prior process ended before the turn outcome could be confirmed."
            )
        case .unavailable:
            kind = .outcomeUnknown(
                reason: "Canonical turn evidence could not be read safely after restart."
            )
        }
        return MacChatTurnLifecycleReducer.reduce(
            restored,
            input: MacChatTurnLifecycleInput(
                identity: restored.identity,
                kind: kind,
                occurredAt: max(instant, restored.presentation.lastMovementAt)
            )
        )
    }
}
