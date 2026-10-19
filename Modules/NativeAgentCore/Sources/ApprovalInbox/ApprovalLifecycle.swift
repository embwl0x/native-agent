import Foundation
import NativeAgentCore
import PersistenceCore

public enum ApprovalLifecyclePhase: String, Sendable, Equatable {
    case requested
    case resolved
    case executed
}

/// A process-local edge emitted only after the canonical approval store has
/// durably accepted a lifecycle transition. Consumers can react without
/// watching every UI surface that happens to create or resolve approvals.
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

/// Fan-out for durable approval lifecycle edges. The inbox remains the
/// authority; this bus carries no decisions and cannot mutate an approval.
public actor ApprovalLifecycleBus {
    public static let shared = ApprovalLifecycleBus()

    public typealias HostContext = @Sendable (@escaping @Sendable () async throws -> JSONValue) async throws -> JSONValue
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
            if event.phase == .executed { return }
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
