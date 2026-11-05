import Foundation
import NativeAgentShared
import NativeAgentCore
import PersistenceCore
import Synchronization
#if canImport(CryptoKit)
import CryptoKit
#endif

// Blueprint: | `MacControlOperationStore.swift` | `MacControlOperationStore`: Payload-free lifecycle, recovery admission and cancellation |

/// Keep operation lifecycle payload-free so shell text, file data and app contents cannot enter durable replay records. Domain audit evidence retains its own
/// bounds.
public enum MacControlOperationState: String, Codable, Sendable, CaseIterable {
    case accepted
    case started
    case cancelRequested = "cancel_requested"
    case cancelAcknowledged = "cancel_acknowledged"
    case timedOut = "timed_out"
    case outcomeUnknown = "outcome_unknown"
    case completed
    case failed
    case blocked
    case refused

    public var isTerminal: Bool {
        switch self {
        case .cancelAcknowledged, .timedOut, .outcomeUnknown, .completed, .failed, .blocked, .refused:
            return true
        case .accepted, .started, .cancelRequested:
            return false
        }
    }
}

public struct MacControlOperationRecord: Codable, Sendable, Equatable {
    public let operationId: String
    public let action: String
    /// Hash canonical action/body without operation identity to bind idempotency to exact intent without retaining user payload.
    public let requestDigest: String
    public var state: MacControlOperationState
    public let acceptedAt: Date
    public var startedAt: Date?
    public var deadlineAt: Date?
    public var cancelRequestedAt: Date?
    public var terminalAt: Date?
    public var verification: MotorVerificationState
    public var expectedNextEvidence: String?
    /// Bounded machine outcome such as `exit_1`, `policy_refused`, or `restart_interrupted`. Never user/application payload.
    public var outcomeCode: String?

    public init(
        operationId: String,
        action: String,
        requestDigest: String,
        state: MacControlOperationState,
        acceptedAt: Date,
        startedAt: Date? = nil,
        deadlineAt: Date? = nil,
        cancelRequestedAt: Date? = nil,
        terminalAt: Date? = nil,
        verification: MotorVerificationState = .notStarted,
        expectedNextEvidence: String? = nil,
        outcomeCode: String? = nil
    ) {
        self.operationId = operationId
        self.action = action
        self.requestDigest = requestDigest
        self.state = state
        self.acceptedAt = acceptedAt
        self.startedAt = startedAt
        self.deadlineAt = deadlineAt
        self.cancelRequestedAt = cancelRequestedAt
        self.terminalAt = terminalAt
        self.verification = verification
        self.expectedNextEvidence = expectedNextEvidence
        self.outcomeCode = outcomeCode
    }
}

public enum MacControlOperationBeginOutcome: Sendable, Equatable {
    case accepted(MacControlOperationRecord)
    case replay(MacControlOperationRecord)
    case duplicateActive(MacControlOperationRecord)
}

public enum MacControlOperationStoreError: Error, Sendable, Equatable, LocalizedError {
    case invalidOperationId
    case corruptStore
    case operationNotFound
    case actionMismatch
    case requestMismatch
    case recoveryUnavailable(String)
    case illegalTransition(from: MacControlOperationState, to: MacControlOperationState)

    public var errorDescription: String? {
        switch self {
        case .invalidOperationId: return "invalid_operation_id: Use operation_id with 1–128 UTF-8 bytes: letters, numbers, dot, underscore, colon or hyphen."
        case .corruptStore: return """
            mac_operation_store_corrupt: Repair mac_control/operations.json under the app data root, preserving the original bytes. Inspect affected apps \
            with mac.look before any further action; prior effects are not established by this error.
            """
        case .operationNotFound: return """
            mac_operation_not_found: No record exists for this operation_id. Check the identity from its original receipt; inspect the affected app with \
            mac.look before creating new work.
            """
        case .actionMismatch: return """
            operation_action_mismatch: This operation_id belongs to another action. Use the original receipt to reconcile that action before assigning a new \
            operation_id to different work.
            """
        case .requestMismatch: return """
            operation_request_mismatch: This operation_id belongs to another request. Reconcile the original receipt before assigning a new operation_id to \
            changed args.
            """
        case .recoveryUnavailable(let cause):
            return """
                mac_operation_recovery_unavailable: Mac actions are unavailable: \(cause). Preserve and repair mac_control/operations.json under the app data \
                root, inspect affected apps with mac.look to reconcile unknown effects, then restart NativeAgent to recover. Looking and other surfaces \
                remain available; do not repeat an uncertain action.
                """
        case .illegalTransition(let from, let to):
            return """
                illegal_mac_operation_transition: \(from.rawValue) -> \(to.rawValue). Preserve the existing record in mac_control/operations.json and inspect \
                the affected app with mac.look; do not replay the action to repair its lifecycle.
                """
        }
    }
}

/// Durable compare-and-set owner shared by Core Mac Control and the app bridge. Every mutation rereads under the cross-process flock, so a second process or a
/// second actor instance cannot race a duplicate side effect into existence.
public actor MacControlOperationStore: MotorActionReadModelProviding {
    public static let maxRetainedOperations = 500
    // Shared by every client of this canonical path, not by one actor instance. Absence means launch recovery has not completed, never permission to act.
    private enum Recovery: Sendable { case ready, unavailable(String) }
    private static let recovery = Mutex<[URL: Recovery]>([:])

    public nonisolated var recoveryIssue: String? {
        switch Self.recovery.withLock({ $0[path] }) {
        case .ready: return nil
        case .unavailable(let cause): return MacControlOperationStoreError.recoveryUnavailable(cause).localizedDescription
        case nil: return MacControlOperationStoreError.recoveryUnavailable("Startup recovery has not completed").localizedDescription
        }
    }

    private struct Snapshot: Codable, Sendable {
        var schemaVersion: Int
        var operations: [MacControlOperationRecord]
    }

    private let path: URL
    nonisolated var registryIdentity: URL { path }
    private let now: @Sendable () -> Date

    public init(
        dataRoot: URL,
        now: @escaping @Sendable () -> Date = { Date() }
    ) {
        self.path = dataRoot.standardizedFileURL
            .appendingPathComponent("mac_control", isDirectory: true)
            .appendingPathComponent("operations.json")
        self.now = now
    }

    public nonisolated static func validOperationId(_ value: String) -> Bool {
        guard !value.isEmpty, value.utf8.count <= 128 else { return false }
        return value.unicodeScalars.allSatisfy { scalar in
            CharacterSet.alphanumerics.contains(scalar)
                || [46, 95, 58, 45].contains(scalar.value)
        }
    }

    public nonisolated static func requestDigest(
        action rawAction: String,
        body rawBody: [String: JSONValue]
    ) throws -> String {
        let action = rawAction.trimmingCharacters(in: .whitespacesAndNewlines)
            .trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        var body = rawBody
        body.removeValue(forKey: "operationId")
        body.removeValue(forKey: "operation_id")
        let canonical = try JSONValue.object([
            "action": .string(action),
            "body": .object(body),
        ]).serializedData(pretty: false)
        #if canImport(CryptoKit)
        return SHA256.hash(data: canonical).map { String(format: "%02x", $0) }.joined()
        #else
        throw MacControlOperationStoreError.requestMismatch
        #endif
    }

    public nonisolated static func validRequestDigest(_ value: String) -> Bool {
        guard value.utf8.count == 64 else { return false }
        return value.unicodeScalars.allSatisfy {
            CharacterSet(charactersIn: "0123456789abcdef").contains($0)
        }
    }

    public func begin(
        operationId: String,
        action: String,
        requestDigest: String,
        deadlineAt: Date? = nil
    ) async throws -> MacControlOperationBeginOutcome {
        guard Self.validOperationId(operationId) else {
            throw MacControlOperationStoreError.invalidOperationId
        }
        guard Self.validRequestDigest(requestDigest) else {
            throw MacControlOperationStoreError.requestMismatch
        }
        if let issue = recoveryIssue {
            throw ToolFailureError(issue, effects: .none, owner: "mac_operation_recovery",
                code: "mac_operation_recovery_unavailable", status: .refused,
                instruction: """
                    Preserve and repair mac_control/operations.json, inspect affected apps with mac.look to reconcile unknown effects, then restart \
                    NativeAgent.
                    """, recovery: .repair)
        }
        return try await mutate { snapshot in
            if let existing = snapshot.operations.first(where: { $0.operationId == operationId }) {
                guard existing.action == action else {
                    throw MacControlOperationStoreError.actionMismatch
                }
                guard existing.requestDigest == requestDigest else {
                    throw MacControlOperationStoreError.requestMismatch
                }
                return existing.state.isTerminal ? .replay(existing) : .duplicateActive(existing)
            }
            let acceptedAt = now()
            let record = MacControlOperationRecord(
                operationId: operationId,
                action: Self.clip(action, limit: 128),
                requestDigest: requestDigest,
                state: .accepted,
                acceptedAt: acceptedAt,
                deadlineAt: deadlineAt,
                verification: .notStarted,
                expectedNextEvidence: "Mac Control execution start"
            )
            snapshot.operations.insert(record, at: 0)
            Self.bound(&snapshot.operations)
            return .accepted(record)
        }
    }

    @discardableResult
    public func transition(
        operationId: String,
        to next: MacControlOperationState,
        verification: MotorVerificationState? = nil,
        expectedNextEvidence: String? = nil,
        outcomeCode: String? = nil,
        acknowledgePreStartCancellation: Bool = false,
        settlingActualExit: Bool = false
    ) async throws -> MacControlOperationRecord {
        try await mutate { snapshot in
            guard let index = snapshot.operations.firstIndex(where: { $0.operationId == operationId }) else {
                throw MacControlOperationStoreError.operationNotFound
            }
            let current = snapshot.operations[index]
            if acknowledgePreStartCancellation, current.state == .cancelAcknowledged,
               current.startedAt == nil { return current }
            let cancelledBeforeStart = acknowledgePreStartCancellation
                && current.state == .cancelRequested && current.startedAt == nil
            let next = cancelledBeforeStart ? MacControlOperationState.cancelAcknowledged : next
            // Only the original body's actual-exit settlement can replace a reporting wait's unknown effect. Restart uncertainty stays final.
            let settlesWait = settlingActualExit && current.state == .outcomeUnknown
                && current.terminalAt == nil
                && [.completed, .failed, .timedOut, .cancelAcknowledged, .outcomeUnknown].contains(next)
            if current.state == next && !settlesWait { return current }
            guard settlesWait || Self.legalTransitions[current.state, default: []].contains(next) else {
                throw MacControlOperationStoreError.illegalTransition(from: current.state, to: next)
            }
            var updated = current
            let timestamp = now()
            updated.state = next
            if next == .started { updated.startedAt = timestamp }
            if next == .cancelRequested { updated.cancelRequestedAt = timestamp }
            if next.isTerminal { updated.terminalAt = timestamp }
            if cancelledBeforeStart {
                updated.verification = .notRequired
                updated.expectedNextEvidence = nil
                updated.outcomeCode = "cancelled_before_start"
            } else {
                if let verification { updated.verification = verification }
                updated.expectedNextEvidence = expectedNextEvidence.map { Self.clip($0, limit: 256) }
                updated.outcomeCode = outcomeCode.map { Self.clip($0, limit: 128) }
            }
            snapshot.operations[index] = updated
            Self.bound(&snapshot.operations)
            return updated
        }
    }

    /// A reporting deadline never settles or retires the body's real result.
    func responseUnavailable(operationId: String, timedOut: Bool) async throws -> MacControlOperationRecord {
        try await mutate { snapshot in
            guard let index = snapshot.operations.firstIndex(where: { $0.operationId == operationId }) else {
                throw MacControlOperationStoreError.operationNotFound
            }
            if snapshot.operations[index].state.isTerminal { return snapshot.operations[index] }
            snapshot.operations[index].state = .outcomeUnknown
            snapshot.operations[index].verification = .unverified
            snapshot.operations[index].expectedNextEvidence = "Original body exit and separate effect observation; do not replay"
            snapshot.operations[index].outcomeCode = timedOut ? "deadline_effect_unknown" : "cancel_effect_unknown"
            // No terminalAt: the body still owns exactly one terminal settlement.
            return snapshot.operations[index]
        }
    }

    public func record(operationId: String) async throws -> MacControlOperationRecord? {
        let snapshot = try await load()
        return snapshot.operations.first { $0.operationId == operationId }
    }

    /// Register before reading: every durable writer, including another store instance or process, wakes settlement. The caller owns the grace, not the
    /// lifetime of the still-running execution.
    func waitForCancellationSettlement(operationId: String, until deadline: ContinuousClock.Instant) async throws -> MacControlOperationRecord? {
        let changes = FileChangeEvents(paths: [path])
        defer { changes.cancel() }
        return try await withThrowingTaskGroup(of: MacControlOperationRecord?.self) { group in
            defer { group.cancelAll() }
            group.addTask { [self] in
                for await _ in changes.stream {
                    try Task.checkCancellation()
                    let current = try await record(operationId: operationId)
                    if current?.state != .cancelRequested { return current }
                }
                try Task.checkCancellation()
                return nil
            }
            group.addTask {
                try await Task.sleep(until: deadline, clock: .continuous)
                return nil
            }
            return try await group.next() ?? nil
        }
    }

    /// Restart cannot retain prior-process execution ownership. Mark interrupted rows terminal without replay; full startup recovery and action-scoped bridge
    /// recovery keep distinct scopes.
    @discardableResult
    public func recoverInterruptedOperations(action: String? = nil) async throws -> Int {
        do {
            let count = try await mutate { snapshot in
                var recovered = 0
                let timestamp = now()
                for index in snapshot.operations.indices where !snapshot.operations[index].state.isTerminal || snapshot.operations[index].terminalAt == nil {
                    if let action, snapshot.operations[index].action != action { continue }
                    let priorState = snapshot.operations[index].state
                    // `accepted` is durably recorded before execution begins, so an interruption there proves no effect started. Once the operation reached
                    // `started` (or cancellation raced it), a restart cannot honestly infer whether the external effect happened. Preserve that ambiguity and
                    // forbid blind replay.
                    let effectMayHaveStarted = priorState == .started
                        || priorState == .cancelRequested || priorState == .outcomeUnknown
                    snapshot.operations[index].state = effectMayHaveStarted
                        ? .outcomeUnknown
                        : .failed
                    snapshot.operations[index].terminalAt = timestamp
                    snapshot.operations[index].verification = effectMayHaveStarted
                        ? .unknown
                        : .failed
                    snapshot.operations[index].expectedNextEvidence = effectMayHaveStarted
                        ? "Separate observation of intended effect; do not retry automatically"
                        : nil
                    snapshot.operations[index].outcomeCode = "restart_interrupted"
                    recovered += 1
                }
                return recovered
            }
            // Only whole-owner launch recovery can open admission.
            if action == nil {
                Self.recovery.withLock { $0[path] = .ready }
            }
            return count
        } catch {
            Self.recovery.withLock { $0[path] = .unavailable(error.localizedDescription) }
            throw error
        }
    }

    public func motorActionReadModel(actionId: String) async throws -> MotorActionReadModel? {
        guard let record = try await record(operationId: actionId) else { return nil }
        return MotorActionReadModel(
            domain: "mac_control",
            actionIdentity: CausalTransitionEvidence.opaqueIdentity(record.operationId),
            phase: Self.motorPhase(record.state),
            domainState: record.state.rawValue,
            verification: record.verification,
            expectedNextEvidence: record.expectedNextEvidence,
            updatedAt: Self.iso8601(record.terminalAt ?? record.cancelRequestedAt ?? record.startedAt ?? record.acceptedAt),
            cancellationIdentity: record.state.isTerminal ? nil : record.operationId,
            deadline: record.state.isTerminal ? nil : record.deadlineAt.map { deadlineAt in
                MotorActionDeadlineReadModel(
                    scope: .operation,
                    timeoutSeconds: max(1, Int((deadlineAt.timeIntervalSince(record.acceptedAt)).rounded()))
                )
            }
        )
    }

    private func load() async throws -> Snapshot {
        guard FileManager.default.fileExists(atPath: path.path) else {
            return Snapshot(schemaVersion: 1, operations: [])
        }
        do {
            let data = try Data(contentsOf: path)
            let snapshot = try JSONDecoder.nativeAgent.decode(Snapshot.self, from: data)
            guard snapshot.schemaVersion == 1,
                  snapshot.operations.allSatisfy({
                      Self.validOperationId($0.operationId)
                          && Self.validRequestDigest($0.requestDigest)
                  }) else {
                throw MacControlOperationStoreError.corruptStore
            }
            return snapshot
        } catch let error as MacControlOperationStoreError {
            throw error
        } catch {
            throw MacControlOperationStoreError.corruptStore
        }
    }

    private func mutate<T: Sendable>(
        _ body: @Sendable (inout Snapshot) throws -> T
    ) async throws -> T {
        try await SwiftNativePersistenceCore.withFileLock(path) { [path] in
            var snapshot = try await self.load()
            let result = try body(&snapshot)
            let encoded = try JSONEncoder.nativeAgent.encode(snapshot)
            try SwiftNativePersistenceCore.atomicWrite(encoded, to: path)
            return result
        }
    }

    private static let legalTransitions: [MacControlOperationState: Set<MacControlOperationState>] = [
        .accepted: [.started, .blocked, .refused, .cancelRequested, .cancelAcknowledged, .failed],
        .started: [.cancelRequested, .cancelAcknowledged, .timedOut, .outcomeUnknown, .completed, .failed],
        .cancelRequested: [.cancelAcknowledged, .timedOut, .outcomeUnknown, .completed, .failed],
        .cancelAcknowledged: [],
        .timedOut: [],
        .outcomeUnknown: [],
        .completed: [],
        .failed: [],
        .blocked: [],
        .refused: [],
    ]

    private static func motorPhase(_ state: MacControlOperationState) -> MotorActionPhase {
        switch state {
        case .accepted: return .ready
        case .started: return .running
        case .cancelRequested: return .running
        case .cancelAcknowledged: return .cancelled
        case .timedOut: return .expired
        case .outcomeUnknown: return .waitingExternal
        case .completed: return .succeeded
        case .failed: return .failed
        case .blocked, .refused: return .blocked
        }
    }

    private static func bound(_ operations: inout [MacControlOperationRecord]) {
        guard operations.count > maxRetainedOperations else { return }
        // Never evict an active operation. Keep newest terminal rows up to the cap in addition to every active row.
        let active = operations.filter { !$0.state.isTerminal || $0.terminalAt == nil }
        let terminalBudget = max(0, maxRetainedOperations - active.count)
        operations = active + Array(operations.filter { $0.state.isTerminal && $0.terminalAt != nil }.prefix(terminalBudget))
    }

    private static func clip(_ value: String, limit: Int) -> String {
        String(value.prefix(limit))
    }

    private static func iso8601(_ date: Date) -> String {
        NativeTimestampFormat.fractionalZulu(date)
    }
}

private extension JSONEncoder {
    static var nativeAgent: JSONEncoder {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.sortedKeys]
        return encoder
    }
}

private extension JSONDecoder {
    static var nativeAgent: JSONDecoder {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return decoder
    }
}
