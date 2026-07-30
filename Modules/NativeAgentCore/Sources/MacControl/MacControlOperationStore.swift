import Foundation
import PersistenceCore
#if canImport(CryptoKit)
import CryptoKit
#endif

/// Canonical, payload-free lifecycle state for one Mac Control operation.
///
/// The action body, shell text, file contents, and application content never
/// enter this store. Domain audit logs may retain their separately bounded
/// evidence, but this store alone owns whether an operation was accepted,
/// started, cancelled, timed out, or completed.
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
    /// SHA-256 over the canonical action + request body with operation identity
    /// removed. This binds an idempotency key to one exact intent without
    /// retaining shell text, file content, notification text, or other payload.
    public let requestDigest: String?
    public var state: MacControlOperationState
    public let acceptedAt: Date
    public var startedAt: Date?
    public var deadlineAt: Date?
    public var cancelRequestedAt: Date?
    public var terminalAt: Date?
    public var verification: MotorVerificationState
    public var expectedNextEvidence: String?
    /// Bounded machine outcome such as `exit_1`, `policy_refused`, or
    /// `restart_interrupted`. Never user/application payload.
    public var outcomeCode: String?

    public init(
        operationId: String,
        action: String,
        requestDigest: String? = nil,
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
    case illegalTransition(from: MacControlOperationState, to: MacControlOperationState)

    public var errorDescription: String? {
        switch self {
        case .invalidOperationId: return "invalid Mac Control operation identity"
        case .corruptStore: return "Mac Control operation store is corrupt"
        case .operationNotFound: return "Mac Control operation was not found"
        case .actionMismatch: return "Mac Control operation identity belongs to another action"
        case .requestMismatch: return "Mac Control operation identity belongs to another request"
        case .illegalTransition(let from, let to):
            return "illegal Mac Control transition: \(from.rawValue) -> \(to.rawValue)"
        }
    }
}

/// Durable compare-and-set owner shared by Core Mac Control and the app bridge.
/// Every mutation rereads under the cross-process flock, so a second process or
/// a second actor instance cannot race a duplicate side effect into existence.
public actor MacControlOperationStore: MotorActionReadModelProviding {
    public static let maxRetainedOperations = 500

    private struct Snapshot: Codable, Sendable {
        var schemaVersion: Int
        var operations: [MacControlOperationRecord]
    }

    private let path: URL
    private let persistence: SwiftNativePersistenceCore
    private let now: @Sendable () -> Date

    public init(
        dataRoot: URL,
        persistence: SwiftNativePersistenceCore = SwiftNativePersistenceCore(),
        now: @escaping @Sendable () -> Date = { Date() }
    ) {
        self.path = dataRoot
            .appendingPathComponent("mac_control", isDirectory: true)
            .appendingPathComponent("operations.json")
        self.persistence = persistence
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

    public nonisolated static func validRequestDigest(_ value: String?) -> Bool {
        guard let value, value.utf8.count == 64 else { return false }
        return value.unicodeScalars.allSatisfy {
            CharacterSet(charactersIn: "0123456789abcdef").contains($0)
        }
    }

    public func begin(
        operationId: String,
        action: String,
        requestDigest: String,
        deadlineSeconds: Int? = nil
    ) async throws -> MacControlOperationBeginOutcome {
        guard Self.validOperationId(operationId) else {
            throw MacControlOperationStoreError.invalidOperationId
        }
        guard Self.validRequestDigest(requestDigest) else {
            throw MacControlOperationStoreError.requestMismatch
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
            let deadlineAt = deadlineSeconds.map {
                acceptedAt.addingTimeInterval(TimeInterval(max(1, min($0, 120))))
            }
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
        outcomeCode: String? = nil
    ) async throws -> MacControlOperationRecord {
        try await mutate { snapshot in
            guard let index = snapshot.operations.firstIndex(where: { $0.operationId == operationId }) else {
                throw MacControlOperationStoreError.operationNotFound
            }
            let current = snapshot.operations[index]
            if current.state == next {
                return current
            }
            guard Self.legalTransitions[current.state, default: []].contains(next) else {
                throw MacControlOperationStoreError.illegalTransition(from: current.state, to: next)
            }
            var updated = current
            let timestamp = now()
            updated.state = next
            if next == .started { updated.startedAt = timestamp }
            if next == .cancelRequested { updated.cancelRequestedAt = timestamp }
            if next.isTerminal { updated.terminalAt = timestamp }
            if let verification { updated.verification = verification }
            updated.expectedNextEvidence = expectedNextEvidence.map { Self.clip($0, limit: 256) }
            updated.outcomeCode = outcomeCode.map { Self.clip($0, limit: 128) }
            snapshot.operations[index] = updated
            Self.bound(&snapshot.operations)
            return updated
        }
    }

    public func record(operationId: String) async throws -> MacControlOperationRecord? {
        let snapshot = try await load()
        return snapshot.operations.first { $0.operationId == operationId }
    }

    /// On restart no process can still be owned by the prior app instance.
    /// Mark interrupted rows terminal rather than silently replaying them.
    @discardableResult
    public func recoverInterruptedOperations() async throws -> Int {
        try await mutate { snapshot in
            var recovered = 0
            let timestamp = now()
            for index in snapshot.operations.indices where !snapshot.operations[index].state.isTerminal {
                let priorState = snapshot.operations[index].state
                // `accepted` is durably recorded before execution begins, so
                // an interruption there proves no effect started. Once the
                // operation reached `started` (or cancellation raced it), a
                // restart cannot honestly infer whether the external effect
                // happened. Preserve that ambiguity and forbid blind replay.
                let effectMayHaveStarted = priorState == .started
                    || priorState == .cancelRequested
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
                          && ($0.requestDigest == nil || Self.validRequestDigest($0.requestDigest))
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
        try await persistence.withFileLock(path) { [path, persistence] in
            var snapshot: Snapshot
            if FileManager.default.fileExists(atPath: path.path) {
                do {
                    let data = try Data(contentsOf: path)
                    snapshot = try JSONDecoder.nativeAgent.decode(Snapshot.self, from: data)
                    guard snapshot.schemaVersion == 1,
                          snapshot.operations.allSatisfy({
                              Self.validOperationId($0.operationId)
                                  && ($0.requestDigest == nil || Self.validRequestDigest($0.requestDigest))
                          }) else {
                        throw MacControlOperationStoreError.corruptStore
                    }
                } catch let error as MacControlOperationStoreError {
                    throw error
                } catch {
                    throw MacControlOperationStoreError.corruptStore
                }
            } else {
                snapshot = Snapshot(schemaVersion: 1, operations: [])
            }
            let result = try body(&snapshot)
            let encoded = try JSONEncoder.nativeAgent.encode(snapshot)
            let json = try JSONValue.parse(encoded)
            try await persistence.writeJSON(json, to: path)
            return result
        }
    }

    private static let legalTransitions: [MacControlOperationState: Set<MacControlOperationState>] = [
        .accepted: [.started, .blocked, .refused, .cancelRequested, .failed],
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
        // Never evict an active operation. Keep newest terminal rows up to the
        // cap in addition to every active row.
        let active = operations.filter { !$0.state.isTerminal }
        let terminalBudget = max(0, maxRetainedOperations - active.count)
        operations = active + Array(operations.filter { $0.state.isTerminal }.prefix(terminalBudget))
    }

    private static func clip(_ value: String, limit: Int) -> String {
        String(value.prefix(limit))
    }

    private static func iso8601(_ date: Date) -> String {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return formatter.string(from: date)
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
