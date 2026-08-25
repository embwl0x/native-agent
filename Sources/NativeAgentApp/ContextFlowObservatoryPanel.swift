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
    static let enabledFlagKey = "contextFlow.enabled"
    static let shadowFlagKey = "contextFlow.shadow"

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
              case .bool(true)? = flags[enabledFlagKey]
        else { return false }
        if case .bool(true)? = flags[shadowFlagKey] { return false }
        return true
    }

    static func isShadowMode(_ event: TurnTraceEvent) -> Bool {
        guard case .object(let payload) = event.payload,
              case .object(let flags)? = payload["flags"],
              case .bool(true)? = flags[enabledFlagKey],
              case .bool(true)? = flags[shadowFlagKey]
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

/// The live runtime's health read has a distinct configured-off result: no
/// coordinator is expected in that case, unlike an unavailable read.
enum ContextFlowObservatoryHealthState: Sendable, Equatable {
    case unavailable
    case off
    case health(ContextFlowCoordinatorHealth)
}

/// The Context Flow health projection deliberately keeps "no health was
/// readable", "configured off", and "reported an error" separate. The
/// Observatory must not turn any of those into the same reassuring zero-value
/// table.
struct ContextFlowHealthRowsPresentation: Equatable {
    struct Row: Identifiable, Equatable {
        let label: String
        let value: String

        var id: String { label }
    }

    enum State: Equatable {
        case unavailable
        case off
        case stopped
        case attention
        case running
    }

    let state: State
    let rows: [Row]
    let errorDetail: String?

    init(healthState: ContextFlowObservatoryHealthState) {
        switch healthState {
        case .unavailable:
            self.init(health: nil)
        case .off:
            self.init(
                state: .off,
                rows: [Row(label: "Mode", value: ContextFlowMode.off.rawValue)],
                errorDetail: nil
            )
        case .health(let health):
            self.init(health: health)
        }
    }

    private init(state: State, rows: [Row], errorDetail: String?) {
        self.state = state
        self.rows = rows
        self.errorDetail = errorDetail
    }

    init(health: ContextFlowCoordinatorHealth?) {
        guard let health else {
            self.state = .unavailable
            self.rows = []
            self.errorDetail = nil
            return
        }

        self.rows = Self.rows(for: health)
        if let error = health.lastError {
            self.state = .attention
            let trimmed = error.trimmingCharacters(in: .whitespacesAndNewlines)
            self.errorDetail = trimmed.isEmpty
                ? "Context Flow reported an unspecified error."
                : trimmed
        } else {
            self.errorDetail = nil
            if health.mode == .off {
                self.state = .off
            } else if !health.started {
                self.state = .stopped
            } else {
                self.state = .running
            }
        }
    }

    var statusText: String? {
        return switch state {
        case .unavailable: "Context Flow health is unavailable."
        case .off: "Context Flow is off."
        case .stopped: "Context Flow has not started."
        case .attention: "Context Flow needs attention."
        case .running: nil
        }
    }

    static func generationText(_ generation: Int64?) -> String {
        generation.map(String.init) ?? "none"
    }

    private static func rows(for health: ContextFlowCoordinatorHealth) -> [Row] {
        var rows = [
            Row(label: "Mode", value: health.mode.rawValue),
            Row(label: "Store generation", value: generationText(health.activeStoreGenerationID)),
            Row(label: "RAM generation", value: generationText(health.activeArenaGenerationID)),
            Row(label: "Registered sources", value: String(health.registeredSourceCount)),
            Row(label: "Degraded sources", value: String(health.degradedSourceCount)),
            Row(
                label: "Arena",
                value: ByteCountFormatter.string(
                    fromByteCount: Int64(health.arenaMetrics.residentLogicalBytes),
                    countStyle: .memory
                )
            ),
            Row(label: "Pressure", value: health.arenaMetrics.pressure.rawValue),
            Row(label: "Active leases", value: String(health.arenaMetrics.activeLeaseCount)),
            Row(label: "Prewarm queue", value: String(health.pendingPrewarmHints)),
            Row(label: "Prewarm receipts", value: String(health.prewarmUsefulnessReceipts)),
        ]
        if let reconciled = health.lastReconciledAt {
            rows.append(Row(
                label: "Reconciled",
                value: reconciled.formatted(date: .omitted, time: .standard)
            ))
        }
        return rows
    }
}

struct ContextFlowObservatoryPanel: View {
    let healthState: ContextFlowObservatoryHealthState
    var fallback: ContextFlowFallbackState?

    var body: some View {
        let presentation = ContextFlowHealthRowsPresentation(healthState: healthState)
        VStack(alignment: .leading, spacing: NativeAgentSpacing.sm) {
            if let fallback {
                fallbackChip(fallback)
            }
            if let statusText = presentation.statusText {
                Text(statusText)
                    .font(.caption)
                    .foregroundStyle(presentation.state == .attention ? .orange : .secondary)
            }
            ForEach(presentation.rows) { healthRow in
                row(healthRow.label, healthRow.value)
            }
            if let error = presentation.errorDetail {
                Divider()
                Text(error)
                    .font(.caption2)
                    .foregroundStyle(.orange)
                    .textSelection(.enabled)
            }
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
