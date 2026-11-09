import AgentConversations
import Foundation
import PersistenceCore
import NativeAgentShared
import Desk
// Blueprint: | `DeskActivityPresentation.swift` | Desk availability, movement and expiry; a job carrying an item is its movement |
public enum DeskLaneState<Row: Sendable>: Sendable {
    case unavailable(String)
    case rows([Row])
    public static var maxReasonChars: Int { 240 }
    /// Bound untrusted errors at the state boundary so a store failure cannot take over the board.
    public static func boundedReason(_ reason: String) -> String {
        String(reason.prefix(maxReasonChars))
    }
    public var items: [Row] {
        if case .rows(let rows) = self { return rows }
        return []
    }
    public var unavailableReason: String? {
        if case .unavailable(let reason) = self { return reason }
        return nil
    }
    public static func failed(_ error: any Error) -> DeskLaneState {
        .unavailable(boundedReason("\(error)"))
    }
}
public enum DeskMovementPresentation {
    /// Each Desk item's newest job that carries it.
    public static func evidence(_ jobs: [AgentJob]) -> [String: DeskExecutionEvidence] {
        let carried = jobs.compactMap { job in job.desk.map { ($0, job) } }
        return Dictionary(grouping: carried, by: { $0.0 })
            .compactMapValues { entries in entries.map { $0.1 }.max { $0.updatedAt < $1.updatedAt }.map(evidence(of:)) }
    }

    /// A working job moves with its last event; one that needs the person waits on them.
    public static func evidence(of job: AgentJob) -> DeskExecutionEvidence {
        let at = NativeTimestampFormat.fractionalZulu(job.updatedAt)
        let status = switch job.state {
        case .working: "running"
        case .needsYou: "blocked_on_approval"
        default: job.state.rawValue
        }
        return DeskExecutionEvidence(deskHandle: job.desk, status: status, updatedAt: at, lastMovementAt: job.state == .working ? at : nil)
    }
    public static func activity(_ item: DeskItem, evidence: DeskExecutionEvidence?, now: Date) -> DeskActivityState {
        DeskActivityState.item(status: item.status.rawValue, kind: item.kind.rawValue,
            deferred: DeskSequencing.isDeferred(item, now: now), updatedAt: item.updatedAt, evidence: evidence, now: now)
    }
}
/// Whether any Desk item is moving right now, whether the board reading behind it is stale, and when either changes.
public enum DeskLiveActivityPresentation {
    public static let defaultActiveWindow: TimeInterval = DeskActivityState.movementWindow
    public static let staleAfter: TimeInterval = 5 * 60
    private static let boundaryEpsilon: TimeInterval = 0.001
    public struct Content: Sendable, Equatable {
        public let isStale: Bool
        /// Sleep to the next stale-snapshot or expired-movement boundary instead of polling.
        public let nextRefreshAt: Date?
    }
    public enum State: Sendable, Equatable {
        case unavailable(String)
        case quiet
        case rows(Content)
        public var nextRefreshAt: Date? {
            guard case .rows(let content) = self else { return nil }
            return content.nextRefreshAt
        }
    }
    public static func make(
        deskItems: DeskLaneState<DeskItem>,
        jobs: DeskLaneState<AgentJob>,
        evidence: [String: DeskExecutionEvidence],
        generatedTs: String?,
        now: Date,
        activeWindow: TimeInterval = defaultActiveWindow,
        staleLimit: TimeInterval = staleAfter
    ) -> State {
        if let reason = deskItems.unavailableReason {
            return .unavailable(reason)
        }
        if let reason = jobs.unavailableReason {
            return .unavailable(reason)
        }
        let window = max(0, activeWindow)
        let moving = deskItems.items.compactMap { item -> Date? in
            guard !item.requiresOwnerInput,
                  DeskMovementPresentation.activity(item, evidence: evidence[item.handle], now: now) == .working,
                  let updated = DeskActivityState.movementDate(evidence[item.handle]?.lastMovementAt)
            else { return nil }
            return max(0, now.timeIntervalSince(updated)) <= window ? updated : nil
        }
        guard !moving.isEmpty else { return .quiet }
        guard let generatedTs,
              let generatedAt = DeskPage.parseTimestamp(generatedTs)
        else {
            return .unavailable("The Desk snapshot has no readable generated timestamp.")
        }
        let limit = max(0, staleLimit)
        let stale = max(0, now.timeIntervalSince(generatedAt)) > limit
        var boundaries = moving.compactMap { updated -> Date? in
            let expiry = updated.addingTimeInterval(window + boundaryEpsilon)
            return expiry > now ? expiry : nil
        }
        if !stale {
            let staleBoundary = generatedAt.addingTimeInterval(limit + boundaryEpsilon)
            if staleBoundary > now { boundaries.append(staleBoundary) }
        }
        return .rows(Content(isStale: stale, nextRefreshAt: boundaries.min()))
    }
}
