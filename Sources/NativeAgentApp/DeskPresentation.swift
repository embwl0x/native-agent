import Foundation
import PersistenceCore
import Desk
import GitHubConnector
import WorkshopExecution
import NativeAgentShared

enum DeskMovementPresentation {
    static func evidence(_ executions: [WorkshopExecution.WorkshopExecutionRecord]) -> [String: DeskExecutionEvidence] {
        Dictionary(grouping: executions.filter { $0.deskHandle != nil }, by: { $0.deskHandle! })
            .compactMapValues { rows in
                rows.max { $0.updatedAt < $1.updatedAt }.map {
                    DeskExecutionEvidence(deskHandle: $0.deskHandle, status: $0.status, updatedAt: $0.updatedAt, lastMovementAt: $0.lastMovementAt)
                }
            }
    }

    static func activity(_ item: DeskItem, evidence: DeskExecutionEvidence?, now: Date) -> DeskActivityState {
        DeskActivityState.item(status: item.status.rawValue, kind: item.kind.rawValue,
            deferred: item.deferUntil != nil, updatedAt: item.updatedAt, evidence: evidence, now: now)
    }
}

// MARK: - Desk presentation facts
//
// These are deliberately value-only descriptions of the state that DeskPageView
// renders.  Store and runner code retain ownership of truth; this layer makes
// the final translation into a human claim executable without inspecting a
// SwiftUI body in tests.

enum DeskPresentationTone: Sendable, Equatable {
    case neutral
    case info
    case success
    case warning
    case danger
}

/// Shared relative-time vocabulary for every timestamp rendered on Desk rows.
/// Callers provide the frozen presentation clock, which keeps tests and exact
/// freshness boundaries deterministic without introducing a timer.
enum DeskRelativeTimePresentation {
    static func text(forISO raw: String, now: Date) -> String {
        guard let date = UserDisplayFormatters.parseISOTimestamp(raw) else {
            return "unknown"
        }
        return text(for: date, now: now)
    }

    static func text(for date: Date, now: Date) -> String {
        let seconds = now.timeIntervalSince(date)
        if seconds < 0 {
            let remaining = -seconds
            switch remaining {
            case ..<60: return "in less than a minute"
            case ..<3_600: return "in \(Int(ceil(remaining / 60)))m"
            case ..<86_400: return "in \(Int(ceil(remaining / 3_600)))h"
            default: return "in \(Int(ceil(remaining / 86_400)))d"
            }
        }
        switch seconds {
        case ..<90: return "just now"
        case ..<3_600: return "\(Int(seconds / 60))m ago"
        case ..<86_400: return "\(Int(seconds / 3_600))h ago"
        default: return "\(Int(seconds / 86_400))d ago"
        }
    }

    /// The next change in this vocabulary, rather than a periodic clock tick.
    static func nextRefreshAt(for date: Date, now: Date) -> Date {
        let remaining = date.timeIntervalSince(now)
        if remaining > 0 {
            let unit: TimeInterval
            switch remaining {
            case ..<60: return date
            case ..<3_600: unit = 60
            case ..<86_400: unit = 3_600
            default: unit = 86_400
            }
            let boundary = max(unit, (ceil(remaining / unit) - 1) * unit)
            return date.addingTimeInterval(-boundary + 0.001)
        }
        let seconds = max(0, now.timeIntervalSince(date))
        let boundary: TimeInterval
        switch seconds {
        case ..<90: boundary = 90
        case ..<3_600: boundary = (floor(seconds / 60) + 1) * 60
        case ..<86_400: boundary = (floor(seconds / 3_600) + 1) * 3_600
        default: boundary = (floor(seconds / 86_400) + 1) * 86_400
        }
        return date.addingTimeInterval(boundary)
    }
}

enum DeskHonestyPresentation {
    struct UnavailableNotice: Equatable, Sendable {
        let title: String
        let detail: String
    }

}

// MARK: - Live Activity

/// The pure, value-only model behind Desk's glancing Live Activity header.
/// Canonical Desk and execution rows supply the evidence; this projection neither writes
/// status nor promotes `laneOf` into the real `parent` hierarchy.
enum DeskLiveActivityPresentation {
    static let defaultActiveWindow: TimeInterval = DeskActivityState.movementWindow
    static let staleAfter: TimeInterval = 5 * 60
    static let visibleRowCap = 4
    private static let boundaryEpsilon: TimeInterval = 0.001

    struct Progress: Sendable, Equatable {
        let done: Int
        let total: Int
        let note: String?

        var fraction: Double { Double(done) / Double(total) }
    }

    struct Row: Identifiable, Sendable, Equatable {
        let id: String
        let summary: String
        let assignee: String
        let assigneeSymbol: String
        let lastUpdateText: String
        let progress: Progress?
    }

    struct Content: Sendable, Equatable {
        let rows: [Row]
        let overflowCount: Int
        let asOfText: String
        let isStale: Bool
        /// The next semantic boundary only: snapshot becomes stale or one
        /// active row ages out. DeskLiveReloader sleeps to this exact instant;
        /// there is no periodic freshness timer.
        let nextRefreshAt: Date?

        /// Every row eligible for this section, including the deterministic
        /// overflow disclosed by "+N more". This is never a hidden store total.
        var eligibleRowCount: Int { rows.count + overflowCount }
    }

    enum State: Sendable, Equatable {
        case unavailable(DeskHonestyPresentation.UnavailableNotice)
        case quiet
        case rows(Content)

        var nextRefreshAt: Date? {
            guard case .rows(let content) = self else { return nil }
            return content.nextRefreshAt
        }
    }

    static func make(
        deskItems: DeskLaneState<DeskItem>,
        executions: DeskLaneState<WorkshopExecution.WorkshopExecutionRecord>,
        generatedTs: String?,
        now: Date,
        activeWindow: TimeInterval = defaultActiveWindow,
        rowCap: Int = visibleRowCap,
        staleLimit: TimeInterval = staleAfter
    ) -> State {
        if let reason = deskItems.unavailableReason {
            return .unavailable(.init(title: "Live Activity unavailable", detail: reason))
        }
        if let reason = executions.unavailableReason {
            return .unavailable(.init(title: "Live Activity unavailable", detail: reason))
        }

        let window = max(0, activeWindow)
        let evidence = DeskMovementPresentation.evidence(executions.items)
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
              let generatedAt = UserDisplayFormatters.parseISOTimestamp(generatedTs)
        else {
            return .unavailable(.init(
                title: "Live Activity unavailable",
                detail: "The Desk snapshot has no readable generated timestamp."))
        }

        let limit = max(0, staleLimit)
        let snapshotAge = max(0, now.timeIntervalSince(generatedAt))
        let stale = snapshotAge > limit
        let cap = max(0, rowCap)
        let visible = candidates.prefix(cap).map { item, updated in
            Row(
                id: item.handle,
                summary: humanSummary(item),
                assignee: assigneeLabel(item.assignee),
                assigneeSymbol: assigneeSymbol(item.assignee),
                lastUpdateText: "last update \(DeskRelativeTimePresentation.text(for: updated, now: now))",
                progress: item.progress.map {
                    Progress(done: $0.done, total: $0.total, note: $0.note)
                }
            )
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
            asOfText: "as of \(DeskRelativeTimePresentation.text(for: generatedAt, now: now))",
            isStale: stale,
            nextRefreshAt: boundaries.min()
        ))
    }

    static func relativeAge(_ date: Date, now: Date) -> String {
        DeskRelativeTimePresentation.text(for: date, now: now)
    }

    static func humanSummary(_ item: DeskItem) -> String {
        let summary = item.summary?.trimmingCharacters(in: .whitespacesAndNewlines)
        if let summary, !summary.isEmpty { return summary }
        let title = item.title.trimmingCharacters(in: .whitespacesAndNewlines)
        return title.isEmpty ? "Untitled desk item" : title
    }

    static func assigneeLabel(_ value: String?) -> String {
        let trimmed = value?.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let trimmed, !trimmed.isEmpty else { return "Unassigned" }
        return trimmed
    }

    static func assigneeSymbol(_ value: String?) -> String {
        switch value?.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() {
        case "codex": return "chevron.left.forwardslash.chevron.right"
        case "claude": return "sparkles"
        case "agent": return "brain.head.profile"
        default: return "person.crop.circle"
        }
    }
}

// MARK: - Delegation program families

/// `laneOf` is intentionally consumed only here, as a read model. Canonical
/// `DeskItem.parent`, sequencing, archive guards, and board grouping remain
/// untouched; a delegation family is visual context, not a second hierarchy.
enum DeskProgramFamilyPresentation {
    struct Lane: Identifiable, Sendable, Equatable {
        let id: String
        let title: String
        let assignee: String
        let assigneeSymbol: String
        let status: DeskStatus
        let progress: DeskLiveActivityPresentation.Progress?
    }

    struct Family: Identifiable, Sendable, Equatable {
        let id: String
        let parentTitle: String
        let parentSummary: String
        let lanes: [Lane]
        fileprivate let newestUpdate: Date?
    }

    static func families(from deskItems: DeskLaneState<DeskItem>, executions: DeskLaneState<WorkshopExecution.WorkshopExecutionRecord>, now: Date) -> [Family] {
        guard deskItems.unavailableReason == nil, executions.unavailableReason == nil else { return [] }
        return families(from: deskItems.items, executions: executions.items, now: now)
    }

    static func families(from items: [DeskItem], executions: [WorkshopExecution.WorkshopExecutionRecord], now: Date) -> [Family] {
        let evidence = DeskMovementPresentation.evidence(executions)
        // A canonical store cannot produce duplicate handles, but this is a UI
        // projection over durable bytes: retaining the first row is safer than
        // trapping if a damaged/manual fixture reaches the presentation seam.
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

        return items.compactMap { parent -> Family? in
            guard let lanes = lanesByParent[parent.handle], !lanes.isEmpty,
                  ([parent] + lanes).contains(where: {
                      !$0.requiresOwnerInput && DeskMovementPresentation.activity($0, evidence: evidence[$0.handle], now: now) == .working
                  })
            else { return nil }
            let newest = ([parent] + lanes)
                .compactMap { UserDisplayFormatters.parseISOTimestamp($0.updatedAt) }
                .max()
            return Family(
                id: parent.handle,
                parentTitle: parent.title,
                parentSummary: DeskLiveActivityPresentation.humanSummary(parent),
                lanes: lanes.map { lane in
                    Lane(
                        id: lane.handle,
                        title: DeskLiveActivityPresentation.humanSummary(lane),
                        assignee: DeskLiveActivityPresentation.assigneeLabel(lane.assignee),
                        assigneeSymbol: DeskLiveActivityPresentation.assigneeSymbol(lane.assignee),
                        status: lane.status,
                        progress: lane.progress.map {
                            .init(done: $0.done, total: $0.total, note: $0.note)
                        }
                    )
                },
                newestUpdate: newest
            )
        }.sorted { left, right in
            if left.newestUpdate != right.newestUpdate {
                return (left.newestUpdate ?? .distantPast) > (right.newestUpdate ?? .distantPast)
            }
            return left.id < right.id
        }
    }
}

enum DeskExecutionPresentation {
    struct Pill: Sendable, Equatable {
        let label: String
        let tone: DeskPresentationTone
    }

    struct Slice: Sendable, Equatable {
        let benchIDs: [String]
        let approvalIDs: [String]
        let recentDoneIDs: [String]
    }

    private static let terminalStatuses: Set<String> = ["completed", "failed", "cancelled"]

    /// Unknown states belong on the bench rather than silently disappearing.
    static func slice(_ executions: [WorkshopExecution.WorkshopExecutionRecord]) -> Slice {
        let approval = executions.filter { $0.status == "blocked_on_approval" }
        let bench = executions.filter {
            $0.status != "blocked_on_approval" && !terminalStatuses.contains($0.status)
        }
        let recent = Array(executions
            .filter { terminalStatuses.contains($0.status) }
            .sorted { $0.updatedAt > $1.updatedAt })
        return Slice(
            benchIDs: bench.map(\.id),
            approvalIDs: approval.map(\.id),
            recentDoneIDs: recent.map(\.id))
    }

    static func pill(for status: String) -> Pill {
        switch status {
        case "running": return Pill(label: "running", tone: .info)
        case "queued": return Pill(label: "queued", tone: .neutral)
        case "blocked_on_approval": return Pill(label: "needs approval", tone: .warning)
        case "completed": return Pill(label: "done", tone: .success)
        case "failed": return Pill(label: "failed", tone: .danger)
        case "cancelled": return Pill(label: "cancelled", tone: .neutral)
        default:
            let human = status.replacingOccurrences(of: "_", with: " ")
                .trimmingCharacters(in: .whitespacesAndNewlines)
            return Pill(label: human.isEmpty ? "unknown status" : "unknown: \(human)", tone: .neutral)
        }
    }

    static func progress(status: String, planCount: Int, completedCount: Int) -> String? {
        guard status == "running", planCount > 0 else { return nil }
        return "step \(min(max(completedCount + 1, 1), planCount)) of \(planCount)"
    }

    static func verificationLabel(_ verification: WorkshopVerificationRecord) -> String {
        switch verification.status {
        case .satisfied:
            let methods = verification.methods.map { method in
                switch method {
                case "exact_output": return "exact output"
                case "file_bytes": return "file bytes"
                default: return method.replacingOccurrences(of: "_", with: " ")
                }
            }.filter { !$0.isEmpty }.joined(separator: " + ")
            return methods.isEmpty ? "verified" : "verified: \(methods)"
        case .failed:
            return "verification failed"
        case .unverified:
            return "completed; outcome not independently verified"
        }
    }
}

enum DeskItemPresentation {
    struct BlockedPill: Sendable, Equatable {
        let text: String
        let targetHandle: String
    }

    static func blockedPill(
        plan: DeskSequencing.ItemPlan,
        aliases: [String: String],
        cap: Int = 3
    ) -> BlockedPill? {
        let resolved = plan.effectiveBlockers.compactMap { handle in
            aliases[handle].map { (handle: handle, alias: $0) }
        }
        guard let first = resolved.first else { return nil }
        let shown = resolved.prefix(max(cap, 1)).map(\.alias).joined(separator: ", ")
        let overflow = resolved.count - min(resolved.count, max(cap, 1))
        return BlockedPill(
            text: "waiting on \(shown)" + (overflow > 0 ? " +\(overflow)" : ""),
            targetHandle: first.handle)
    }

    static func nagBellSymbol(config: DeskNagConfig, now: Date) -> String {
        if config.isMuted(now: now) { return "bell.slash" }
        return config.enabled ? "bell.fill" : "bell"
    }

    /// The one Desk-wide definition of a row requiring attention. An explicit
    /// waiting owner is meaningful state even when the row is neither blocked
    /// nor flagged, so summaries and the attention strip must share this rule.
    static func needsEyes(_ item: DeskItem) -> Bool {
        item.status == .blocked || item.status == .flag || (item.waitingOn?.isEmpty == false)
    }

    /// The whole-board store failure is rendered next to lane failures, so it
    /// shares their precise bounded-error contract instead of creating a second
    /// arbitrary limit at the top of the Desk.
    struct Freshness: Sendable, Equatable {
        let text: String
        let isStale: Bool
        let isKnown: Bool
    }

    static let staleThresholdDays = 7

    /// The row's timestamp claim. A malformed timestamp is unknown, never
    /// fresh; blocked and flagged rows retain a plain age because their status
    /// already carries the urgent signal.
    static func freshness(for item: DeskItem, now: Date) -> Freshness {
        guard let date = UserDisplayFormatters.parseISOTimestamp(item.updatedAt) else {
            return Freshness(text: "unknown", isStale: false, isKnown: false)
        }
        let seconds = max(0, now.timeIntervalSince(date))
        let days = Int(seconds / 86_400)
        let plain = DeskRelativeTimePresentation.text(for: date, now: now)
        let stale = days >= staleThresholdDays
            && item.status != .blocked && item.status != .flag && !item.status.isTerminal
        return Freshness(text: stale ? "\(days)d stale" : plain, isStale: stale, isKnown: true)
    }

}

enum DeskPursuitSectionPresentation {
    static let unreadablePayloadLabel = "Project details unavailable"
    static let unreadablePayloadDetail = "The saved details of this project could not be read. They need to be repaired before you can act on it."

}

enum DeskPursuitVetoControl {
    static let help = "Close this pursuit (canceled) with a user-vetoed note."
}

/// What the Desk says after a veto settles. Every outcome gets a line — a
/// refused write must never look like a completed one.
enum DeskPursuitVetoNotice {
    static func receipt(for outcome: WorkshopObservatoryVetoHandler.Outcome) -> DeskActionNotice {
        switch outcome {
        case .completed:
            return DeskActionNotice(text: "Pursuit vetoed and closed.", isError: false)
        case .alreadyVetoed:
            return DeskActionNotice(text: "Pursuit was already vetoed.", isError: false)
        case .inFlight:
            return DeskActionNotice(text: "That veto is still being written.", isError: false)
        case .failed(let detail):
            return DeskActionNotice(text: "Veto failed: \(detail)", isError: true)
        }
    }
}

/// Score, budget and the recorded reason a pursuit row carries next to its
/// Veto control — the facts an owner needs to veto on. Folded by the SAME pure
/// projection the observatory used (`WorkshopPursuitRow.from`), so moving the
/// control did not fork the numbers behind it.
enum DeskPursuitVetoRationale {
    static func row(for item: DeskItem, now: Date) -> WorkshopPursuitRow? {
        guard item.pursuit != nil else { return nil }
        return WorkshopPursuitRow.from(item: item, now: now)
    }

    /// "score 1.83" — nil when the pursuit payload gave no score, so the row
    /// says nothing rather than showing a misleading 0.
    static func scoreLabel(_ score: WorkshopScoreView?) -> String? {
        guard let score else { return nil }
        return "score \(String(format: "%.2f", score.total))"
    }

    /// "2/3 sessions · 1/2 today" — the two hard caps the pursuit lives under.
    static func budgetLabel(_ budget: WorkshopBudget?) -> String? {
        guard let budget else { return nil }
        return "\(budget.sessionsUsed)/\(budget.maxSessions) sessions · "
            + "\(budget.todayCount)/\(budget.perDayCap) today"
    }

    /// Her most recent recorded "chose: …" rationale, stripped of the marker.
    static func reasonLabel(_ rationale: String?) -> String? {
        guard let rationale else { return nil }
        let trimmed = rationale
            .trimmingCharacters(in: .whitespacesAndNewlines)
        let body = trimmed.hasPrefix(WorkshopPursuitRow.choiceMarker)
            ? String(trimmed.dropFirst(WorkshopPursuitRow.choiceMarker.count))
            : trimmed
        let cleaned = body.trimmingCharacters(in: .whitespacesAndNewlines)
        return cleaned.isEmpty ? nil : cleaned
    }
}

/// Human vocabulary for the GitHub Watcher state pill. Persisted enum names
/// are machine identifiers and must never become a visible fallback label.
enum DeskGitHubStatePillPresentation {
    struct Pill: Equatable {
        let label: String
        let tone: DeskPresentationTone
    }

    static let stalledCallbackStatus = "stalled"

    static func pill(for item: GitHubCommandItem) -> Pill {
        switch item.state {
        case .detected, .needsCodex:
            return Pill(label: "Action needed", tone: .warning)
        case .codexWorking:
            return Pill(label: "Codex working", tone: .info)
        case .verifying:
            return Pill(label: "Verifying", tone: .info)
        case .needsUser:
            return Pill(label: "Needs you", tone: .warning)
        case let .waitingUpstream(kind):
            return Pill(label: waitingLabel(for: kind), tone: .neutral)
        case let .attention(reason):
            return attentionPill(reason: reason, callbackStatus: item.lastCallbackStatus)
        case .resolved:
            return Pill(label: "Resolved", tone: .success)
        }
    }

    static func waitingLabel(for kind: GitHubCommandWaitingKind) -> String {
        switch kind {
        case .review: return "Waiting for review"
        case .ci: return "Waiting for checks"
        case .maintainer: return "Waiting for maintainer"
        case .readyToMerge: return "Ready to merge"
        }
    }

    private static func attentionPill(
        reason: GitHubCommandAttentionReason,
        callbackStatus: String?
    ) -> Pill {
        let label: String
        switch reason {
        case .dispatchFailed: label = "Dispatch failed"
        case .codexFailed:
            label = normalizedCallbackStatus(callbackStatus) == stalledCallbackStatus
                ? "Codex stalled"
                : "Codex no result"
        case .verificationFailed: label = "GitHub still actionable"
        case .verificationReadFailed: label = "GitHub verification unreadable"
        case .callbackOverdue: label = "Codex stalled"
        case .codexBusy: label = "Legacy Codex retry"
        case .stale: label = "Stale observation"
        case .contradictoryState: label = "State needs review"
        }
        return Pill(label: label, tone: .danger)
    }

    private static func normalizedCallbackStatus(_ status: String?) -> String {
        status?.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() ?? ""
    }
}

/// The ordered status-critical facts rendered above a Desk row's free-text
/// detail. The board and pursuits share this exact projection, so a blocker
/// never becomes navigable in one lane but inert or absent in the other.
enum DeskSequencingPillPresentation {
    enum Kind: String, Sendable, Equatable {
        case rollup
        case blocked
        case cycle
        case deferred
        case nextUp
    }

    struct Pill: Identifiable, Sendable, Equatable {
        let kind: Kind
        let text: String
        let targetHandle: String?

        var id: String { kind.rawValue }
    }

    static func pills(
        item: DeskItem,
        itemPlan: DeskSequencing.ItemPlan,
        isNextUp: Bool,
        aliases: [String: String],
        blockerAliasCap: Int = 3
    ) -> [Pill] {
        var result: [Pill] = []
        if itemPlan.totalCount > 0 {
            result.append(Pill(
                kind: .rollup,
                text: "\(itemPlan.doneCount)/\(itemPlan.totalCount) closed",
                targetHandle: nil
            ))
        }
        if let blocked = DeskItemPresentation.blockedPill(
            plan: itemPlan,
            aliases: aliases,
            cap: blockerAliasCap
        ) {
            result.append(Pill(
                kind: .blocked,
                text: blocked.text,
                targetHandle: blocked.targetHandle
            ))
        }
        if itemPlan.blockedByCycle {
            result.append(Pill(
                kind: .cycle,
                text: "⚠ these block each other",
                targetHandle: nil
            ))
        }
        if itemPlan.isDeferred {
            let day = item.deferUntil.flatMap(DeskSequencing.deferDisplayDay)
            result.append(Pill(
                kind: .deferred,
                text: day.map { "until \($0)" } ?? "deferred; date unavailable",
                targetHandle: nil
            ))
        }
        if isNextUp {
            result.append(Pill(kind: .nextUp, text: "start here", targetHandle: nil))
        }
        return result
    }
}
