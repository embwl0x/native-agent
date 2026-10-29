import Foundation
import Cognition
import OSLog
import PersistenceCore
import StandingBots
import NativeAgentShared
import Desk
import TriggerScheduler
import WorkshopExecution
// Blueprint: | `DeskActivityPresentation.swift` | Desk lane availability, movement evidence, live activity expiry, program-family eligibility and execution progress |
public enum DeskLaneState<Row: Sendable>: Sendable {
    case unavailable(String)
    case rows([Row])
    public static var maxReasonChars: Int { 240 }
    /// Every failure notice on the Desk uses this cap. Keeping the truncation
    /// at the state boundary makes an unreadable store visible without letting
    /// an untrusted error string take over the board.
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
    /// A throwing read: the error text IS the reason, bounded.
    public static func failed(_ error: any Error) -> DeskLaneState {
        .unavailable(boundedReason("\(error)"))
    }
}
extension DeskLaneState where Row == WorkshopExecutionRecord {
    public static func classify(rows: [WorkshopExecutionRecord], root: URL) -> DeskLaneState {
        if let failure = rows.first(where: { $0.id == "queue-unavailable" && $0.status == "unavailable" }),
           case .object(let result) = failure.result, case .string(let detail)? = result["error"] {
            var isDirectory: ObjCBool = false
            let reason = FileManager.default.fileExists(atPath: root.path, isDirectory: &isDirectory) && !isDirectory.boolValue
                ? "execution root is not a directory" : detail
            return .unavailable(boundedReason("Couldn't read the execution record(s) store — \(reason)"))
        }
        return .rows(rows)
    }
}
public enum DeskMovementPresentation {
    public static func evidence(_ executions: [WorkshopExecution.WorkshopExecutionRecord]) -> [String: DeskExecutionEvidence] {
        let handled = executions.compactMap { row in row.deskHandle.map { ($0, row) } }
        return Dictionary(grouping: handled, by: { $0.0 })
            .compactMapValues { entries in
                let rows = entries.map { $0.1 }
                return rows.max { $0.updatedAt < $1.updatedAt }.map {
                    DeskExecutionEvidence(deskHandle: $0.deskHandle, status: $0.status, updatedAt: $0.updatedAt, lastMovementAt: $0.lastMovementAt)
                }
            }
    }
    public static func activity(_ item: DeskItem, evidence: DeskExecutionEvidence?, now: Date) -> DeskActivityState {
        DeskActivityState.item(status: item.status.rawValue, kind: item.kind.rawValue,
            deferred: item.deferUntil != nil, updatedAt: item.updatedAt, evidence: evidence, now: now)
    }
}
public enum DeskLiveActivityPresentation {
    public static let defaultActiveWindow: TimeInterval = DeskActivityState.movementWindow
    public static let staleAfter: TimeInterval = 5 * 60
    public static let visibleRowCap = 4
    private static let boundaryEpsilon: TimeInterval = 0.001
    public struct Row: Identifiable, Sendable, Equatable {
        public let item: DeskItem
        public let updatedAt: Date
        public let now: Date
        public var id: String { item.handle }
        public var summary: String {
            let summary = item.summary?.trimmingCharacters(in: .whitespacesAndNewlines)
            if let summary, !summary.isEmpty { return summary }
            let title = item.title.trimmingCharacters(in: .whitespacesAndNewlines)
            return title.isEmpty ? "Untitled desk item" : title
        }
        public var assignee: String {
            let trimmed = item.assignee?.trimmingCharacters(in: .whitespacesAndNewlines)
            guard let trimmed, !trimmed.isEmpty else { return "Unassigned" }
            return trimmed
        }
        public var lastUpdateText: String { "last update \(DeskRelativeTimePresentation.text(for: updatedAt, now: now))" }
        public var progress: DeskProgress? { item.progress }
    }
    public struct Content: Sendable, Equatable {
        public let rows: [Row]
        public let overflowCount: Int
        public let generatedAt: Date
        public let now: Date
        public let isStale: Bool
        public var asOfText: String { "as of \(DeskRelativeTimePresentation.text(for: generatedAt, now: now))" }
        /// The next semantic boundary only: snapshot becomes stale or one
        /// active row ages out. DeskFacade sleeps to this exact instant;
        /// there is no periodic freshness timer.
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
        executions: DeskLaneState<WorkshopExecution.WorkshopExecutionRecord>,
        evidence: [String: DeskExecutionEvidence],
        generatedTs: String?,
        now: Date,
        activeWindow: TimeInterval = defaultActiveWindow,
        rowCap: Int = visibleRowCap,
        staleLimit: TimeInterval = staleAfter
    ) -> State {
        if let reason = deskItems.unavailableReason {
            return .unavailable(reason)
        }
        if let reason = executions.unavailableReason {
            return .unavailable(reason)
        }
        let window = max(0, activeWindow)
        let candidates = deskItems.items.compactMap { item -> (DeskItem, Date)? in
            guard !item.requiresOwnerInput,
                  DeskMovementPresentation.activity(item, evidence: evidence[item.handle], now: now) == .working,
                  let updated = DeskActivityState.movementDate(evidence[item.handle]?.lastMovementAt)
            else { return nil }
            guard max(0, now.timeIntervalSince(updated)) <= window else { return nil }
            return (item, updated)
        }.sorted { left, right in
            if left.1 != right.1 { return left.1 > right.1 }
            if left.0.updatedAt != right.0.updatedAt {
                return left.0.updatedAt > right.0.updatedAt
            }
            return left.0.handle < right.0.handle
        }
        // Blank slate and ordinary quiet state collapse completely, including
        // a blank generatedTs from an empty canonical feed.
        guard !candidates.isEmpty else { return .quiet }
        guard let generatedTs,
              let generatedAt = DeskPage.parseTimestamp(generatedTs)
        else {
            return .unavailable("The Desk snapshot has no readable generated timestamp.")
        }
        let limit = max(0, staleLimit)
        let snapshotAge = max(0, now.timeIntervalSince(generatedAt))
        let stale = snapshotAge > limit
        let cap = max(0, rowCap)
        let visible = candidates.prefix(cap).map { item, updated in
            Row(item: item, updatedAt: updated, now: now)
        }
        var boundaries = candidates.compactMap { _, updated -> Date? in
            let expiry = updated.addingTimeInterval(window + boundaryEpsilon)
            return expiry > now ? expiry : nil
        }
        if !stale {
            let staleBoundary = generatedAt.addingTimeInterval(limit + boundaryEpsilon)
            if staleBoundary > now { boundaries.append(staleBoundary) }
        }
        return .rows(Content(
            rows: visible,
            overflowCount: max(0, candidates.count - visible.count),
            generatedAt: generatedAt,
            now: now,
            isStale: stale,
            nextRefreshAt: boundaries.min()
        ))
    }
}
public enum DeskProgramFamilyPresentation {
    public static func workingParentIDs(from items: [DeskItem], evidence: [String: DeskExecutionEvidence], now: Date) -> Set<String> {
        // Retain the first row for duplicate handles in the durable bytes.
        let byHandle = items.reduce(into: [String: DeskItem]()) { result, item in
            if result[item.handle] == nil { result[item.handle] = item }
        }
        var lanesByParent: [String: [DeskItem]] = [:]
        for item in items {
            guard let raw = item.laneOf?.trimmingCharacters(in: .whitespacesAndNewlines),
                  !raw.isEmpty,
                  raw != item.handle,
                  byHandle[raw] != nil
            else { continue }
            lanesByParent[raw, default: []].append(item)
        }
        return Set(items.compactMap { parent -> String? in
            guard let lanes = lanesByParent[parent.handle], !lanes.isEmpty,
                  ([parent] + lanes).contains(where: {
                      !$0.requiresOwnerInput && DeskMovementPresentation.activity($0, evidence: evidence[$0.handle], now: now) == .working
                  })
            else { return nil }
            return parent.handle
        })
    }
}
public enum DeskExecutionPresentation {}
extension DeskExecutionPresentation {
    public static func progress(status: String, planCount: Int, completedCount: Int) -> String? {
        guard status == "running", planCount > 0 else { return nil }
        return "step \(min(max(completedCount, 0), planCount - 1) + 1) of \(planCount)"
    }
}
