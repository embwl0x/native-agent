import Foundation

public enum ApprovalLifecyclePhase: String, Sendable, Equatable {
    case requested
    case resolved
}

/// A process-local edge emitted only after the canonical approval store has
/// durably accepted a lifecycle transition. Consumers can react without
/// watching every UI surface that happens to create or resolve approvals.
public struct ApprovalLifecycleEvent: Sendable, Equatable {
    public let phase: ApprovalLifecyclePhase
    public let record: ApprovalRecord

    public init(phase: ApprovalLifecyclePhase, record: ApprovalRecord) {
        self.phase = phase
        self.record = record
    }
}

/// Fan-out for durable approval lifecycle edges. The inbox remains the
/// authority; this bus carries no decisions and cannot mutate an approval.
public actor ApprovalLifecycleBus {
    public static let shared = ApprovalLifecycleBus()

    private var continuations: [UUID: AsyncStream<ApprovalLifecycleEvent>.Continuation] = [:]

    public func events() -> AsyncStream<ApprovalLifecycleEvent> {
        let id = UUID()
        let pair = AsyncStream<ApprovalLifecycleEvent>.makeStream(
            bufferingPolicy: .bufferingNewest(64)
        )
        continuations[id] = pair.continuation
        pair.continuation.onTermination = { [weak self] _ in
            Task { await self?.removeContinuation(id) }
        }
        return pair.stream
    }

    public func publish(_ event: ApprovalLifecycleEvent) {
        for continuation in continuations.values {
            continuation.yield(event)
        }
    }

    private func removeContinuation(_ id: UUID) {
        continuations.removeValue(forKey: id)
    }

    public nonisolated static func fire(
        _ event: ApprovalLifecycleEvent,
        on bus: ApprovalLifecycleBus = .shared
    ) {
        Task { await bus.publish(event) }
    }
}
