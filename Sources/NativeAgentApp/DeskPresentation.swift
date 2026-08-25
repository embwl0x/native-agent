import Foundation
import PersistenceCore
import WorkshopExecution

// MARK: - Desk presentation facts
//
// These are deliberately value-only descriptions of the state that DeskView
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

/// The Desk's reader-facing truth state.  This is deliberately separate from
/// row layout: a successful empty read is quiet, while an unavailable read is
/// a visible uncertainty and prevents the whole board from claiming it is
/// clear.  DeskView consumes this projection directly so the wording and the
/// no-silent-zero rule are testable without mounting SwiftUI.
enum DeskHonestyPresentation {
    struct UnavailableNotice: Equatable, Sendable {
        let title: String
        let detail: String
    }

    enum LaneBody: Equatable, Sendable {
        case unavailable(UnavailableNotice)
        case quiet(String)
        case rows
    }

    enum BoardBody: Equatable, Sendable {
        case loading
        case clear
        case populated
    }

    static let githubQuietCopy =
        "The watcher is quiet. Tracked GitHub changes appear here and notify you when attention is needed; nothing starts automatically."
    static let executionQuietCopy = "Quiet right now — nothing running."

    static func githubLane(_ lane: DeskLaneState<GitHubCommandItem>) -> LaneBody {
        if let reason = lane.unavailableReason {
            return .unavailable(UnavailableNotice(
                title: "GitHub Watcher state unavailable",
                detail: reason))
        }
        return lane.items.isEmpty ? .quiet(githubQuietCopy) : .rows
    }

    static func executionLane(
        _ lane: DeskLaneState<WorkshopExecution.WorkshopExecutionRecord>,
        hasRenderedBenchRows: Bool
    ) -> LaneBody {
        if let reason = lane.unavailableReason {
            return .unavailable(UnavailableNotice(
                title: "Execution lane unavailable",
                detail: reason))
        }
        return hasRenderedBenchRows ? .rows : .quiet(executionQuietCopy)
    }

    static func boardBody(
        itemCount: Int,
        executionCount: Int,
        githubItemCount: Int,
        loadError: String?,
        hasLoadedOnce: Bool,
        hasUnavailableLane: Bool
    ) -> BoardBody {
        guard itemCount == 0,
              executionCount == 0,
              githubItemCount == 0,
              loadError == nil,
              !hasUnavailableLane
        else {
            return .populated
        }
        return hasLoadedOnce ? .clear : .loading
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

    static func statusLabel(_ status: DeskStatus) -> String {
        status.displayLabel
    }

    static func nagBellSymbol(config: DeskNagConfig, now: Date) -> String {
        if config.isMuted(now: now) { return "bell.slash" }
        return config.enabled ? "bell.fill" : "bell"
    }

    /// A blocker with no live alias is not actionable UI.  The rendered pill
    /// and its navigation target therefore come from the same resolved list.
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

    static func visiblePrefix<T>(_ values: [T], showingAll: Bool, cap: Int = 8) -> [T] {
        showingAll ? values : Array(values.prefix(max(cap, 0)))
    }

    /// The one Desk-wide definition of a row requiring attention. An explicit
    /// waiting owner is meaningful state even when the row is neither blocked
    /// nor flagged, so summaries and the attention strip must share this rule.
    static func needsEyes(_ item: DeskItem) -> Bool {
        item.status == .blocked || item.status == .flag || (item.waitingOn?.isEmpty == false)
    }

    static func githubProjectNeedsEyes(_ items: [DeskItem]) -> Int {
        items.lazy.filter(needsEyes).count
    }

    static func paletteTargetIsActionable(_ handle: String, activeHandles: Set<String>) -> Bool {
        activeHandles.contains(handle)
    }

    /// The whole-board store failure is rendered next to lane failures, so it
    /// shares their precise bounded-error contract instead of creating a second
    /// arbitrary limit at the top of the Desk.
    static func boundedLoadFailure(_ detail: String) -> String {
        DeskLaneState<DeskItem>.boundedReason(detail)
    }

    /// Maps the actual Desk-store read failure into the banner's visible,
    /// bounded state. A custom error may provide no localized detail; that is
    /// still a failure, never an empty or clear desk.
    static func loadFailure(_ error: any Error) -> String {
        let detail = error.localizedDescription.trimmingCharacters(in: .whitespacesAndNewlines)
        let visibleDetail = detail.isEmpty
            ? "The storage read failed without details."
            : detail
        return boundedLoadFailure("Couldn't load the bench: \(visibleDetail)")
    }

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
        let plain: String
        switch seconds {
        case ..<90: plain = "just now"
        case ..<3600: plain = "\(Int(seconds / 60))m ago"
        case ..<86_400: plain = "\(Int(seconds / 3600))h ago"
        default: plain = "\(days)d ago"
        }
        let stale = days >= staleThresholdDays
            && item.status != .blocked && item.status != .flag && !item.status.isTerminal
        return Freshness(text: stale ? "\(days)d stale" : plain, isStale: stale, isKnown: true)
    }

    struct PursuitCard: Sendable, Equatable {
        let title: String
        let sessionLabel: String
        let holdLabel: String?
        let doneLabel: String
    }

    /// The pursuits lane includes every self-authored project, including a
    /// legacy/corrupt row whose optional `pursuit` payload could not decode.
    /// The latter gets an explicit integrity card instead of disappearing
    /// behind a section count.
    enum PursuitCardState: Sendable, Equatable {
        case rendered(PursuitCard)
        case payloadUnreadable
        case notPursuit
    }

    static func pursuitCardState(for item: DeskItem) -> PursuitCardState {
        guard DeskBoardLayout.isPursuitLaneItem(item) else { return .notPursuit }
        guard let card = pursuitCard(for: item) else { return .payloadUnreadable }
        return .rendered(card)
    }

    static func pursuitCard(for item: DeskItem) -> PursuitCard? {
        guard let pursuit = item.pursuit else { return nil }
        let holdLabel: String?
        if item.status == .blocked, let reason = item.blockedReason, !reason.isEmpty {
            holdLabel = reason
        } else if let waiting = item.waitingOn, !waiting.isEmpty {
            holdLabel = "waiting on \(waiting)"
        } else {
            holdLabel = nil
        }
        return PursuitCard(
            title: pursuit.privateName ?? item.title,
            sessionLabel: "\(pursuit.reservations.count)/\(pursuit.maxSessions) sessions",
            holdLabel: holdLabel,
            doneLabel: pursuit.doneLooksLike)
    }
}

/// The exact rows an Agent pursuits header counts and renders. A row that
/// survived the Desk state decoder but lost its optional pursuit payload still
/// appears here as a visible integrity warning, so the count cannot claim a
/// card that the section drops.
enum DeskPursuitSectionPresentation {
    static let unreadablePayloadLabel = "Pursuit payload unreadable"
    static let unreadablePayloadDetail = "This self-authored project could not be rendered as a pursuit. Repair its saved pursuit payload before acting on it."

    struct Row: Identifiable, Sendable, Equatable {
        let item: DeskItem
        let cardState: DeskItemPresentation.PursuitCardState

        var id: String { item.handle }
    }

    static func rows(from activeItems: [DeskItem]) -> [Row] {
        DeskBoardLayout.pursuits(activeItems).map { item in
            Row(item: item, cardState: DeskItemPresentation.pursuitCardState(for: item))
        }
    }

    static func headerCount(for rows: [Row]) -> Int? {
        rows.isEmpty ? nil : rows.count
    }
}

/// Human vocabulary for the GitHub Watcher state pill. Persisted enum names
/// are machine identifiers and must never become a visible fallback label.
enum DeskGitHubStatePillPresentation {
    enum Tone: Equatable {
        case warning
        case working
        case checking
        case neutral
        case failure
        case success
    }

    struct Pill: Equatable {
        let label: String
        let tone: Tone
    }

    static let stalledCallbackStatus = "stalled"

    static func pill(for item: GitHubCommandItem) -> Pill {
        switch item.state {
        case .detected, .needsCodex:
            return Pill(label: "Action needed", tone: .warning)
        case .codexWorking:
            return Pill(label: "Codex working", tone: .working)
        case .verifying:
            return Pill(label: "Verifying", tone: .checking)
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
        return Pill(label: label, tone: .failure)
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

enum DeskActionPresentation {
    struct Notice: Sendable, Equatable {
        let symbol: String
        let tone: DeskPresentationTone
    }

    static func notice(isError: Bool) -> Notice {
        isError
            ? Notice(symbol: "exclamationmark.triangle", tone: .warning)
            : Notice(symbol: "checkmark.circle", tone: .success)
    }
}

enum DeskFinishedPresentation {
    static func sectionCount(groupCount: Int, recentExecutionCount: Int) -> Int {
        max(groupCount, 0) + max(recentExecutionCount, 0)
    }
}
