import Foundation
import NativeAgentCore
import PersistenceCore
import TrustCenter

// Blueprint: | `ApprovalLifecycle.swift` | `ApprovalLifecycleBus`; Post-commit fan-out, no decision authority. |

public enum ApprovalLifecyclePhase: String, Sendable, Equatable {
    case requested
    case resolved
    case executed
}

/// Emit only after durable acceptance so consumers need no UI-specific watchers.
public struct ApprovalLifecycleEvent: Sendable, Equatable {
    public let phase: ApprovalLifecyclePhase
    public let record: ApprovalRecord
    public let result: JSONValue?

    public init(phase: ApprovalLifecyclePhase, record: ApprovalRecord, result: JSONValue? = nil) {
        self.phase = phase
        self.record = record
        self.result = result
    }
}

/// The inbox remains decision authority; this bus only fans out committed lifecycle edges, including replay settlement.
public actor ApprovalLifecycleBus {
    public static let shared = ApprovalLifecycleBus()

    /// A waiting host hands over its turn and primitive dependency as values. Replay cannot restore an ambient implementation around a new dispatcher.
    public struct HostContext: Sendable {
        public let turn: Turn
        public let effectOptions: AuthoredEffectOptions
        public let effectExecutor: AuthoredEffectExecutor?
        public init(turn: Turn, effectOptions: AuthoredEffectOptions, effectExecutor: AuthoredEffectExecutor?) {
            self.turn = turn
            self.effectOptions = effectOptions
            self.effectExecutor = effectExecutor
        }
    }
    private var continuations: [UUID: (host: Bool, reply: AsyncStream<ApprovalLifecycleEvent>.Continuation, context: HostContext?)] = [:]

    public func events(forHostCall hostID: UUID? = nil, context: HostContext? = nil) -> AsyncStream<ApprovalLifecycleEvent> {
        let id = hostID ?? UUID()
        let pair = AsyncStream<ApprovalLifecycleEvent>.makeStream(
            bufferingPolicy: .bufferingNewest(64)
        )
        continuations[id] = (hostID != nil, pair.continuation, context)
        pair.continuation.onTermination = { [weak self] _ in
            Task { await self?.removeContinuation(id) }
        }
        return pair.stream
    }

    public func publish(_ event: ApprovalLifecycleEvent) {
        if event.phase == .resolved || event.phase == .executed {
            if SwiftNativeApprovalInbox.terminalApprovalStatuses.contains(event.record.status),
               let id = hostCallID(event.record) { continuations[id]?.reply.yield(event) }
        }
        for continuation in continuations.values where !continuation.host {
            continuation.reply.yield(event)
        }
    }

    private func removeContinuation(_ id: UUID) {
        continuations.removeValue(forKey: id)?.reply.finish()
    }

    public func finish(_ id: UUID) { removeContinuation(id) }

    public func awaitsHostReply(_ record: ApprovalRecord) -> Bool {
        guard let id = hostCallID(record) else { return false }
        return record.status == "resolved" && continuations[id]?.host == true
    }

    public func hostContext(_ record: ApprovalRecord) -> HostContext? {
        hostCallID(record).flatMap { continuations[$0]?.context }
    }

    private func hostCallID(_ record: ApprovalRecord) -> UUID? {
        guard case .object(let fields) = record.payload, case .string(let raw)? = fields["hostCallID"] else { return nil }
        return UUID(uuidString: raw)
    }

    public nonisolated static func fire(
        _ event: ApprovalLifecycleEvent,
        on bus: ApprovalLifecycleBus = .shared
    ) {
        Task { await bus.publish(event) }
    }
}
