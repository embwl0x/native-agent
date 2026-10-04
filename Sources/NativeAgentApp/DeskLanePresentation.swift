import SwiftUI
import AppKit
import BackgroundLoops
import PersistenceCore
import Desk
import GitHubConnector
import WorkshopExecution

/// HER HOUR, on the Desk — personality-depth item 9.
///
/// One line, at the bottom, saying what she did with the hour that was hers. It
/// is a TRACE, not a task: it has no action, no count, no badge, and it never
/// becomes a row User has to clear. The lane writes no desk ops (Agent's veto —
/// her aesthetic life is not board work), so this reads the lane's own bounded
/// file directly and renders its newest entry.
///
/// ABSENT when the lane is not installed. Not "off", not a placeholder, not a
/// zero — absent, exactly the way the lane itself is absent when the switch is
/// off. A Desk that shows "Her hour: disabled" would be advertising a feature at
/// a man who turned it off.
enum DeskHerHourPresentation {
    enum State: Sendable, Equatable {
        case absent
        /// Her own closing line, plus how long ago. Nothing else: no verdict,
        /// no outcome adjective we chose, no progress.
        case line(text: String, symbol: String)
    }

    /// The whole rule. Pure, so the Desk's claim about her hour is testable
    /// without a running app or an installed lane.
    static func state(
        installed: Bool,
        entry: StudioWanderLane.TraceEntry?,
        now: Date
    ) -> State {
        guard installed, let entry else { return .absent }
        let words = entry.line.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !words.isEmpty else { return .absent }
        let when = DeskRelativeTimePresentation.text(forISO: entry.at, now: now)
        return .line(text: "\(bounded(words)) · \(when)", symbol: symbol(entry.outcome))
    }

    /// Icons, not labels. The three endings are equal in standing — a decline is
    /// not a lesser outcome — so none of them gets a word here that ranks it.
    static func symbol(_ outcome: StudioWanderLane.Outcome) -> String {
        switch outcome {
        case .chose: return "eye"
        case .declined: return "moon.zzz"
        case .noArtifact: return "eye.slash"
        }
    }

    static let maximumCharacters = 160

    private static func bounded(_ value: String) -> String {
        value.truncated(to: maximumCharacters, keeping: maximumCharacters - 1)
    }
}

enum DeskGitHubCallbackFailurePresentation {
    struct Detail: Equatable, Sendable {
        let message: String
        let noWorkObserved: Bool?
    }

    private static let failedStatuses: Set<String> = [
        "failed", "failure", "error", "stalled", "timeout", "timed_out",
        "canceled", "cancelled", "completed_without_reply",
    ]
    private static let successfulStatuses: Set<String> = ["completed", "ok", "success"]

    static func detail(for item: GitHubCommandItem) -> Detail? {
        let status = (item.lastCallbackStatus ?? "")
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased()
        let error = nonEmpty(item.lastCallbackErrorMessage)
        let noWorkObserved = item.lastCallbackNoWorkObserved

        if failedStatuses.contains(status) {
            return Detail(
                message: error ?? fallbackMessage(for: status),
                noWorkObserved: noWorkObserved
            )
        }

        // A non-success status paired with an error/resend-safety field is
        // conflicting callback evidence. Surface it rather than silently
        // treating an unknown producer spelling as a healthy completion.
        guard !successfulStatuses.contains(status), error != nil || noWorkObserved != nil else {
            return nil
        }
        let statusText = status.isEmpty ? "no usable status" : "status \(status)"
        return Detail(
            message: error ?? "Codex callback returned \(statusText) without an error detail.",
            noWorkObserved: noWorkObserved
        )
    }

    private static func nonEmpty(_ value: String?) -> String? {
        guard let value else { return nil }
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }

    private static func fallbackMessage(for status: String) -> String {
        switch status {
        case "completed_without_reply":
            return "Codex callback ended without a final result."
        case "stalled":
            return "Codex callback stalled without an error detail."
        case "timeout", "timed_out":
            return "Codex callback timed out without an error detail."
        default:
            return "Codex callback failed without an error detail."
        }
    }
}

/// Stable ordering shared by the primary Desk sections.
enum DeskAttentionStrip {
    static func sortedApprovals(
        _ approvals: [WorkshopExecution.WorkshopExecutionRecord]
    ) -> [WorkshopExecution.WorkshopExecutionRecord] {
        approvals.sorted { l, r in
            if l.createdAt != r.createdAt { return l.createdAt > r.createdAt }
            if l.updatedAt != r.updatedAt { return l.updatedAt > r.updatedAt }
            return l.id < r.id
        }
    }

    static func sortedGitHubItems(_ items: [GitHubCommandItem]) -> [GitHubCommandItem] {
        items.sorted { l, r in
            if l.updatedAt != r.updatedAt { return l.updatedAt > r.updatedAt }
            if l.createdAt != r.createdAt { return l.createdAt > r.createdAt }
            return l.itemId < r.itemId
        }
    }

    static func sortedDeskItems(_ items: [DeskItem]) -> [DeskItem] {
        items.sorted { l, r in
            if l.updatedAt != r.updatedAt { return l.updatedAt > r.updatedAt }
            if l.openedAt != r.openedAt { return l.openedAt > r.openedAt }
            return l.handle < r.handle
        }
    }

}

enum DeskGitHubBucket: String, CaseIterable, Sendable {
    case actionNeeded = "Action needed"
    case legacyWork = "Finishing prior work"
    case needsUser = "Needs you"
    case waiting = "Waiting upstream"
    case attention = "Attention"
    case resolved = "Recently resolved"

    static func bucket(for state: GitHubCommandItemState) -> Self {
        switch state {
        case .detected, .needsCodex: return .actionNeeded
        case .codexWorking, .verifying: return .legacyWork
        case .needsUser: return .needsUser
        case .waitingUpstream: return .waiting
        case .attention: return .attention
        case .resolved: return .resolved
        }
    }


}
