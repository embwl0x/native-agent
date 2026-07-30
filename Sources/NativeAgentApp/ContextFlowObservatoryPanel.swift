import Context
import Foundation
import PersistenceCore
import SwiftUI

// MARK: - Per-turn fallback truth (M12 honesty chip)
//
// ContextFlow active-mode turns can silently fall back to the legacy context
// path when `coordinator.prepareTurn` throws — the turn engine records this on
// the per-turn `context.summary` trace event as the flag
// `contextFlow.fallback` (+ the `contextFlow.fallbackError` label). Those
// events are persisted by TurnTracePersistLane to
// `data/turn_traces/<yyyy-MM-dd>.jsonl`. We READ that same ledger via the
// canonical TurnTraceRecentReader — we do NOT keep a parallel counter that
// could drift from the turn engine's truth.

/// Counts derived from the recent turn-trace tail.
struct ContextFlowFallbackSummary: Equatable, Sendable {
    /// Distinct recent turns carrying a Context Flow summary in any mode.
    let observedTurns: Int
    /// How many observed turns ran in observe-only (shadow) mode.
    let shadowTurns: Int
    /// Number of `context.summary` turn events inspected (the recent window).
    let windowTurns: Int
    /// How many of those turns fell back to the legacy context path.
    let fallbackCount: Int
    /// The `contextFlow.fallbackError` string from the MOST RECENT fallen-back
    /// turn, bounded. `nil` when no fallback carried an error label.
    let latestError: String?
}

/// Honest fallback state for the Observatory chip. `unavailable` is distinct
/// from a healthy zero: a read that could not complete must never render as
/// "no fallbacks" (M12 rule — read failures must not look like health).
enum ContextFlowFallbackState: Equatable, Sendable {
    case unavailable(String)
    case summary(ContextFlowFallbackSummary)
}

/// Reads and counts ContextFlow per-turn fallbacks from the persisted turn
/// traces. The counting is a pure function over `[TurnTraceEvent]` so it is
/// unit-testable without disk.
enum ContextFlowFallbackReader {
    /// The turn-trace event kind the turn engine emits once per turn with the
    /// contextFlow flags/labels attached (ChatOrchestration+TurnEngine.swift).
    static let turnSummaryKind = "context.summary"
    static let fallbackFlagKey = "contextFlow.fallback"
    static let fallbackErrorKey = "contextFlow.fallbackError"

    /// Most-recent turns to inspect for the chip.
    static let windowLimit = 50
    /// Bound the surfaced error so an oversized label can't bloat the panel.
    static let maxErrorChars = 240

    /// Pure: summarize contextFlow fallbacks across the most recent `window`
    /// DISTINCT TURNS (gpt-5.5 HIGH, 2026-07-10: one user turn can emit
    /// several `context.summary` events — a rebuild per tool-loop iteration —
    /// so counting events both shrank the window and multi-counted a single
    /// turn's fallback). Events newest-LAST (persist append order): the LAST
    /// summary per turnId wins, then the newest `window` turns are kept.
    /// Events with turnId "unknown"/empty can't be correlated — each stays its
    /// own pseudo-turn rather than collapsing unrelated turns into one.
    ///
    /// The fallback denominator counts ACTIVE-mode turns only. Shadow turns
    /// cannot vouch for clean active circulation, but remain visible through
    /// `observedTurns`/`shadowTurns` so observe-only work is not mislabeled as
    /// "no recent turns."
    static func summarize(
        events: [TurnTraceEvent],
        window: Int = windowLimit
    ) -> ContextFlowFallbackSummary {
        var latestPerTurn: [String: TurnTraceEvent] = [:]
        var order: [String] = []
        var pseudoTurn = 0
        for event in events where event.kind == turnSummaryKind {
            let rawID = event.turnId.trimmingCharacters(in: .whitespacesAndNewlines)
            let key: String
            if rawID.isEmpty || rawID == "unknown" {
                pseudoTurn += 1
                key = "pseudo-\(pseudoTurn)"
            } else {
                key = rawID
            }
            if latestPerTurn[key] == nil { order.append(key) }
            latestPerTurn[key] = event   // newest-last append order: last wins
        }
        let recentTurnKeys = order.suffix(max(0, window))
        var observedTurns = 0
        var shadowTurns = 0
        var activeTurns = 0
        var fallbackCount = 0
        var latestError: String?
        for key in recentTurnKeys {
            guard let event = latestPerTurn[key] else { continue }
            observedTurns += 1
            if isShadowMode(event) { shadowTurns += 1 }
            if isFallback(event) {
                // A fallback is by definition an active-mode turn (only the
                // active branch sets the flag).
                activeTurns += 1
                fallbackCount += 1
                if let error = fallbackError(event) { latestError = error }
            } else if isActiveMode(event) {
                activeTurns += 1
            }
            // shadow/off summaries: observed, but not part of the active
            // denominator — they can't vouch for clean circulation.
        }
        return ContextFlowFallbackSummary(
            observedTurns: observedTurns,
            shadowTurns: shadowTurns,
            windowTurns: activeTurns,
            fallbackCount: fallbackCount,
            latestError: latestError
        )
    }

    /// Active-mode summary: contextFlow enabled and NOT shadow.
    static func isActiveMode(_ event: TurnTraceEvent) -> Bool {
        guard case .object(let payload) = event.payload,
              case .object(let flags)? = payload["flags"],
              case .bool(true)? = flags["contextFlow.enabled"]
        else { return false }
        if case .bool(true)? = flags["contextFlow.shadow"] { return false }
        return true
    }

    static func isShadowMode(_ event: TurnTraceEvent) -> Bool {
        guard case .object(let payload) = event.payload,
              case .object(let flags)? = payload["flags"],
              case .bool(true)? = flags["contextFlow.enabled"],
              case .bool(true)? = flags["contextFlow.shadow"]
        else { return false }
        return true
    }

    static func isFallback(_ event: TurnTraceEvent) -> Bool {
        guard case .object(let payload) = event.payload,
              case .object(let flags)? = payload["flags"],
              case .bool(let value)? = flags[fallbackFlagKey]
        else { return false }
        return value
    }

    static func fallbackError(_ event: TurnTraceEvent) -> String? {
        guard case .object(let payload) = event.payload,
              case .object(let labels)? = payload["labels"],
              case .string(let raw)? = labels[fallbackErrorKey]
        else { return nil }
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        return String(trimmed.prefix(maxErrorChars))
    }

    /// Load + summarize from the live (or injected) trace ledger. A read that
    /// throws → `.unavailable` (honest), NOT a zero-fallback summary. A missing
    /// file is an honest empty read → `.summary` with `windowTurns == 0` (no
    /// turns observed yet), which the UI renders as a neutral state, not green.
    ///
    /// Reads YESTERDAY + TODAY (gpt-5.5 HIGH, 2026-07-10): the trace ledger is
    /// day-keyed, so a today-only read went blind at midnight — a 23:59
    /// fallback vanished at 00:00 and the chip re-greened on an empty file.
    /// Yesterday's events come first so append order (newest-last) holds
    /// across the concatenation.
    static func load(
        reader: TurnTraceRecentReader = TurnTraceRecentReader(),
        now: Date = Date()
    ) async -> ContextFlowFallbackState {
        do {
            let yesterday = now.addingTimeInterval(-86_400)
            let earlier = try await reader.read(now: yesterday)
            let today = try await reader.read(now: now)
            return .summary(summarize(events: earlier.events + today.events))
        } catch {
            let reason = String("\(error)".prefix(maxErrorChars))
            return .unavailable(reason)
        }
    }
}

struct ContextFlowObservatoryPanel: View {
    let health: ContextFlowCoordinatorHealth?
    var fallback: ContextFlowFallbackState?

    var body: some View {
        VStack(alignment: .leading, spacing: NativeAgentSpacing.sm) {
            if let fallback {
                fallbackChip(fallback)
            }
            if let health {
                healthRows(health)
            } else {
                Text("Context Flow is not running.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
    }

    @ViewBuilder
    private func healthRows(_ health: ContextFlowCoordinatorHealth) -> some View {
        row("Mode", health.mode.rawValue)
        row("Store generation", generationText(health.activeStoreGenerationID))
        row("RAM generation", generationText(health.activeArenaGenerationID))
        row("Registered sources", String(health.registeredSourceCount))
        row("Degraded sources", String(health.degradedSourceCount))
        row(
            "Arena",
            ByteCountFormatter.string(
                fromByteCount: Int64(health.arenaMetrics.residentLogicalBytes),
                countStyle: .memory
            )
        )
        row("Pressure", health.arenaMetrics.pressure.rawValue)
        row("Active leases", String(health.arenaMetrics.activeLeaseCount))
        row("Prewarm queue", String(health.pendingPrewarmHints))
        row("Prewarm receipts", String(health.prewarmUsefulnessReceipts))
        if let reconciled = health.lastReconciledAt {
            row("Reconciled", reconciled.formatted(date: .omitted, time: .standard))
        }
        if let error = health.lastError {
            Divider()
            Text(error)
                .font(.caption2)
                .foregroundStyle(.orange)
                .textSelection(.enabled)
        }
    }

    // MARK: - Fallback chip

    @ViewBuilder
    private func fallbackChip(_ state: ContextFlowFallbackState) -> some View {
        switch state {
        case .unavailable(let reason):
            // A read failure renders as an honest 'unavailable', NEVER a
            // healthy zero.
            noticeRow(
                icon: "questionmark.circle",
                tint: .orange,
                title: "Fallback status unavailable",
                detail: reason
            )
        case .summary(let summary):
            if summary.windowTurns == 0 {
                if summary.shadowTurns > 0 {
                    noticeRow(
                        icon: "eye",
                        tint: .blue,
                        title: "Observed · \(summary.shadowTurns) recent shadow \(turnWord(summary.shadowTurns))",
                        detail: "Observe Only measures selection but does not supply it to replies."
                    )
                } else if summary.observedTurns > 0 {
                    noticeRow(
                        icon: "pause.circle",
                        tint: .secondary,
                        title: "Fluid Context was off for \(summary.observedTurns) recent \(turnWord(summary.observedTurns))",
                        detail: nil
                    )
                } else {
                    noticeRow(
                        icon: "circle.dashed",
                        tint: .secondary,
                        title: "No recent turns to report",
                        detail: nil
                    )
                }
            } else if summary.fallbackCount == 0 {
                noticeRow(
                    icon: "checkmark.circle",
                    tint: .green,
                    title: "Circulating · \(summary.windowTurns) recent \(turnWord(summary.windowTurns)), no fallbacks",
                    detail: summary.shadowTurns > 0
                        ? "Also observed \(summary.shadowTurns) shadow \(turnWord(summary.shadowTurns))."
                        : nil
                )
            } else {
                noticeRow(
                    icon: "exclamationmark.triangle",
                    tint: .orange,
                    title: "\(summary.fallbackCount) of \(summary.windowTurns) recent \(turnWord(summary.windowTurns)) fell back to the legacy context path",
                    detail: summary.latestError.map { "Latest error · \($0)" }
                )
            }
        }
    }

    private func turnWord(_ count: Int) -> String {
        count == 1 ? "turn" : "turns"
    }

    /// Thin wrapper over the shared `ObservatoryNoticeRow` (C10 dedup); call
    /// sites in this panel are unchanged.
    private func noticeRow(
        icon: String,
        tint: Color,
        title: String,
        detail: String?
    ) -> some View {
        ObservatoryNoticeRow(icon: icon, tint: tint, title: title, detail: detail)
    }

    private func generationText(_ generation: Int64?) -> String {
        generation.map(String.init) ?? "none"
    }

    private func row(_ label: String, _ value: String) -> some View {
        HStack {
            Text(label)
            Spacer()
            Text(value)
                .foregroundStyle(.secondary)
        }
        .font(.caption)
    }
}
