import Foundation
import PersistenceCore
import SwiftUI

// MARK: - Workshop Observatory (L11 — veto visibility)
//
// User's window onto Agent's Workshop: her OPEN self-pursuits, the recent work
// sessions, and any owner cadence items now beating on the pump. The design's L11
// requirement is the reason this panel exists: the digest/panel MUST source from
// STORE QUERIES (SwiftNativeDeskStore.liveState()), NOT the capped 25-item
// DeskProjection — a pursuit can never fall out of User's veto view. So the whole
// data-shaping layer below is a pure fold over a full DeskState + the workshop
// receipts feed, unit-testable without SwiftUI or disk.
//
// The view-models mirror the ContextFlowFallbackReader idiom: `unavailable` is a
// FIRST-CLASS state distinct from a healthy zero — a read that could not complete
// never renders as "0 sessions" or "no pursuits".

// MARK: - Pure view-models (data-shaping, no SwiftUI)

/// A pursuit's blended selection score, flattened for display. Mirrors
/// `WorkshopPump.PursuitChoiceScore` but decoupled so the view never depends on
/// the pump's shape.
struct WorkshopScoreView: Equatable, Sendable {
    let total: Double
    let evidenceStrength: Double
    let momentum: Double
    let closureProximity: Double
    let noProgressPenalty: Double
    let recentAttentionPenalty: Double
}

/// The two hard caps a pursuit lives under, with the current draw against each.
struct WorkshopBudget: Equatable, Sendable {
    let sessionsUsed: Int      // reservations.count over the pursuit's life
    let maxSessions: Int       // pursuit.maxSessions (its doneLooksLike budget)
    let todayCount: Int        // reservations reserved today
    let perDayCap: Int         // SwiftNativeDeskStore.maxWorkSessionsPerPursuitPerDay
}

/// One OPEN self-pursuit, shaped for the owner's veto view and audit needs
/// what she chose to pursue and why, plus the live score + budget + her recent
/// choice rationale and work receipts.
struct WorkshopPursuitRow: Identifiable, Equatable, Sendable {
    let handle: String
    let alias: String
    let title: String
    let privateName: String?
    let why: String
    let doneLooksLike: String
    let status: String
    /// nil when the item is origin=agent but carries no decodable pursuit payload
    /// (a corrupt row) — shown as "score unavailable", never a misleading 0.
    let score: WorkshopScoreView?
    let budget: WorkshopBudget?
    let lastWorkedAt: String?
    /// The most recent "chose: …" rationale from her notes (the recorded volition).
    let latestChoiceRationale: String?
    /// Recent work receipts from her notes (completion + work-log lines), newest
    /// first, bounded. Excludes the "chose:" rationale lines.
    let workReceipts: [String]
    /// Evidence citation tokens (source-mix), for the veto rationale.
    let citations: [String]

    var id: String { handle }
    var displayName: String { (privateName?.isEmpty == false ? privateName : nil) ?? title }

    /// Notes whose text begins with this marker are choice rationales, not work
    /// receipts (the pump writes "chose: …" via appendWorkReceipt before a run).
    static let choiceMarker = "chose:"

    static func from(item: DeskItem, now: Date) -> WorkshopPursuitRow {
        let p = item.pursuit
        let today = DeskClock.dayStamp(now)

        let score = WorkshopPump.choiceScore(for: item, now: now).map {
            WorkshopScoreView(
                total: $0.total,
                evidenceStrength: $0.evidenceStrength,
                momentum: $0.momentum,
                closureProximity: $0.closureProximity,
                noProgressPenalty: $0.noProgressPenalty,
                recentAttentionPenalty: $0.recentAttentionPenalty
            )
        }

        let budget: WorkshopBudget? = p.map { pursuit in
            WorkshopBudget(
                sessionsUsed: pursuit.reservations.count,
                maxSessions: pursuit.maxSessions,
                todayCount: pursuit.reservations.filter { $0.day == today }.count,
                perDayCap: SwiftNativeDeskStore.maxWorkSessionsPerPursuitPerDay
            )
        }

        // Split her notes: "chose: …" lines are volition receipts; everything
        // else is a work receipt. Newest first for display.
        let reversed = Array(item.notes.reversed())
        let latestChoice = reversed.first {
            $0.text.hasPrefix(choiceMarker)
        }?.text
        let receipts = reversed
            .filter { !$0.text.hasPrefix(choiceMarker) }
            .prefix(4)
            .map(\.text)

        return WorkshopPursuitRow(
            handle: item.handle,
            alias: item.alias,
            title: item.title,
            privateName: p?.privateName,
            why: p?.why ?? "",
            doneLooksLike: p?.doneLooksLike ?? "",
            status: item.status.rawValue,
            score: score,
            budget: budget,
            lastWorkedAt: p?.lastWorkedAt,
            latestChoiceRationale: latestChoice,
            workReceipts: Array(receipts),
            citations: p?.evidence.citations.map(\.token) ?? []
        )
    }
}

/// An owner cadence item now beating on the pump (tick/daily/weekly). Not a pursuit —
/// simply due or not.
struct WorkshopCadenceRow: Identifiable, Equatable, Sendable {
    let handle: String
    let title: String
    let cadenceMode: String
    let nextDue: String   // formatted, or "due now"
    let isDue: Bool

    var id: String { handle }
}

/// The whole panel model, folded from a full DeskState. Counts are honest: an
/// unavailable read is represented by a nil model (the panel then renders an
/// "unavailable" notice), never a zeroed-out one.
struct WorkshopObservatoryModel: Equatable, Sendable {
    let openPursuits: [WorkshopPursuitRow]
    let cadenceItems: [WorkshopCadenceRow]
    /// Distinct reservations across ALL pursuits (open + terminal) reserved today
    /// — the same count the store's global 6/day cap is measured against.
    let sessionsToday: Int
    let globalCap: Int
    let maxOpenPursuits: Int

    var openPursuitCount: Int { openPursuits.count }

    /// L11: sourced from the FULL DeskState (store query), never the capped
    /// projection — every open agent pursuit is present so none falls out of the
    /// veto view.
    static func build(state: DeskState, now: Date) -> WorkshopObservatoryModel {
        let today = DeskClock.dayStamp(now)

        // OPEN self-pursuits: origin=agent, non-terminal. (A terminal/canceled
        // pursuit is excluded — it's closed, nothing to veto.) Ordered by live
        // score, highest first, so the pursuit the pump would pick sits on top.
        let openPursuits = state.items
            .filter { $0.origin == .agent && !$0.status.isTerminal }
            .map { WorkshopPursuitRow.from(item: $0, now: now) }
            .sorted { ($0.score?.total ?? -.infinity) > ($1.score?.total ?? -.infinity) }

        // Owner cadence items with a now-live beating cadence.
        let cadenceItems = state.items.compactMap { item -> WorkshopCadenceRow? in
            guard item.origin != .agent, !item.status.isTerminal else { return nil }
            switch item.cadence.mode {
            case .tick, .daily, .weekly: break
            default: return nil
            }
            let due = WorkshopPump.isDue(item.cadence.nextRefreshAt, now: now)
            let next: String
            if due {
                next = "due now"
            } else if let raw = item.cadence.nextRefreshAt,
                      let date = DeskClock.parseISO(raw) {
                next = date.formatted(date: .abbreviated, time: .shortened)
            } else {
                next = item.cadence.nextRefreshAt ?? "—"
            }
            return WorkshopCadenceRow(
                handle: item.handle, title: item.title,
                cadenceMode: item.cadence.mode.rawValue, nextDue: next, isDue: due)
        }

        // Global sessions-today: EVERY pursuit's reservations (terminal ones still
        // count — the store measures the 6/day cap that way).
        let sessionsToday = state.items.reduce(0) { acc, item in
            acc + (item.pursuit?.reservations.filter { $0.day == today }.count ?? 0)
        }

        return WorkshopObservatoryModel(
            openPursuits: openPursuits,
            cadenceItems: cadenceItems,
            sessionsToday: sessionsToday,
            globalCap: SwiftNativeDeskStore.maxWorkSessionsGlobalPerDay,
            maxOpenPursuits: SwiftNativeDeskStore.maxOpenAgentPursuits
        )
    }
}

// MARK: - Workshop receipts reader (data/workshop/receipts.jsonl)

/// One compact workshop session receipt row (mirrors WorkshopReceiptLog.append).
struct WorkshopReceiptRow: Identifiable, Equatable, Sendable {
    let handle: String
    let reservationId: String
    let status: String
    let summary: String
    let model: String?
    let artifactCount: Int
    let ts: String

    var id: String { "\(ts)|\(reservationId)" }

    static func fromJSON(_ value: JSONValue) -> WorkshopReceiptRow? {
        guard case .object(let obj) = value,
              case .string(let handle)? = obj["handle"],
              case .string(let reservationId)? = obj["reservationId"],
              case .string(let status)? = obj["status"] else { return nil }
        let summary: String = { if case .string(let s)? = obj["summary"] { return s } else { return "" } }()
        let model: String? = { if case .string(let m)? = obj["model"] { return m } else { return nil } }()
        let artifactCount: Int = {
            if case .int(let n)? = obj["artifactCount"] { return Int(n) }
            return 0
        }()
        let ts: String = { if case .string(let t)? = obj["ts"] { return t } else { return "" } }()
        return WorkshopReceiptRow(
            handle: handle, reservationId: reservationId, status: status,
            summary: summary, model: model, artifactCount: artifactCount, ts: ts)
    }
}

/// Honest receipts state. `unavailable` (a read that failed, or bytes present but
/// none parseable) is distinct from an empty feed (no sessions yet).
enum WorkshopReceiptsState: Equatable, Sendable {
    case unavailable(String)
    case rows([WorkshopReceiptRow])
}

/// Reads + bounds the workshop receipts feed. The parsing is a pure function over
/// `[String]` lines so it is unit-testable without disk.
enum WorkshopReceiptsReader {
    /// Newest-first bound — a busy week can't bloat the panel.
    static let rowLimit = 20
    static let maxErrorChars = 240

    /// Pure: fold raw JSONL lines (file/append order, newest LAST) into the panel
    /// state, newest FIRST and bounded. An empty feed → `.rows([])` (no sessions
    /// yet, honest). Non-empty bytes that yield ZERO parseable rows → `.unavailable`
    /// (something is on disk but unreadable — never render that as "no sessions").
    static func rows(fromLines lines: [String], limit: Int = rowLimit) -> WorkshopReceiptsState {
        let nonEmpty = lines
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
        guard !nonEmpty.isEmpty else { return .rows([]) }
        let parsed = nonEmpty.compactMap { line -> WorkshopReceiptRow? in
            guard let data = line.data(using: .utf8),
                  let value = try? JSONValue.parse(data) else { return nil }
            return WorkshopReceiptRow.fromJSON(value)
        }
        guard !parsed.isEmpty else {
            return .unavailable("\(nonEmpty.count) receipt row(s) present but none could be parsed")
        }
        // File order is chronological (append) — newest last. Reverse for
        // newest-first, then bound.
        let newestFirst = Array(parsed.reversed().prefix(max(0, limit)))
        return .rows(newestFirst)
    }

    /// Load from the receipts feed. A MISSING file is an honest empty read
    /// (`.rows([])`) — no sessions have run. A read that THROWS (IO error, bad
    /// permissions) is `.unavailable`, never a zero.
    static func load(receiptsPath: URL, limit: Int = rowLimit) -> WorkshopReceiptsState {
        guard FileManager.default.fileExists(atPath: receiptsPath.path) else {
            return .rows([])
        }
        do {
            let contents = try String(contentsOf: receiptsPath, encoding: .utf8)
            return rows(fromLines: contents.components(separatedBy: "\n"), limit: limit)
        } catch {
            return .unavailable(String("\(error)".prefix(maxErrorChars)))
        }
    }
}

// MARK: - Async snapshot (store query + receipts read)

/// Everything the panel renders, loaded off the main actor. `model == nil` means
/// the Desk store read failed (deskUnavailable carries the reason).
struct WorkshopObservatorySnapshot: Equatable, Sendable {
    let model: WorkshopObservatoryModel?
    let deskUnavailable: String?
    let receipts: WorkshopReceiptsState

    /// A one-line hint for the collapsible header while collapsed.
    var hint: String {
        guard let model else { return "unavailable" }
        return "\(model.openPursuitCount) open · \(model.sessionsToday)/\(model.globalCap) today"
    }

    static func load(
        store: SwiftNativeDeskStore,
        receiptsPath: URL,
        now: Date = Date()
    ) async -> WorkshopObservatorySnapshot {
        let model: WorkshopObservatoryModel?
        let deskUnavailable: String?
        do {
            let state = try await store.liveState()
            model = WorkshopObservatoryModel.build(state: state, now: now)
            deskUnavailable = nil
        } catch {
            model = nil
            deskUnavailable = String("\(error)".prefix(WorkshopReceiptsReader.maxErrorChars))
        }
        let receipts = WorkshopReceiptsReader.load(receiptsPath: receiptsPath)
        return WorkshopObservatorySnapshot(
            model: model, deskUnavailable: deskUnavailable, receipts: receipts)
    }
}

// MARK: - The panel

struct WorkshopObservatoryPanel: View {
    let snapshot: WorkshopObservatorySnapshot?
    /// Veto action — closes an agent pursuit (setStatus .canceled + a note). The
    /// parent wires this to the store and refreshes.
    var onVeto: (String) -> Void = { _ in }

    var body: some View {
        VStack(alignment: .leading, spacing: NativeAgentSpacing.md) {
            if let snapshot {
                content(snapshot)
            } else {
                loadingRow
            }
        }
    }

    private var loadingRow: some View {
        Text("Loading workshop state.")
            .font(.caption)
            .foregroundStyle(.secondary)
    }

    @ViewBuilder
    private func content(_ snapshot: WorkshopObservatorySnapshot) -> some View {
        header(snapshot)

        if let deskUnavailable = snapshot.deskUnavailable {
            noticeRow(
                icon: "questionmark.circle", tint: .orange,
                title: "Desk state unavailable",
                detail: deskUnavailable)
        } else if let model = snapshot.model {
            pursuitsSection(model)
            cadenceSection(model)
        }

        Divider()
        receiptsSection(snapshot.receipts)
    }

    // MARK: header

    @ViewBuilder
    private func header(_ snapshot: WorkshopObservatorySnapshot) -> some View {
        if let model = snapshot.model {
            HStack(spacing: NativeAgentSpacing.sm) {
                metricChip(
                    "\(model.openPursuitCount)/\(model.maxOpenPursuits)",
                    label: "open pursuits", tint: .purple)
                metricChip(
                    "\(model.sessionsToday)/\(model.globalCap)",
                    label: "sessions today", tint: .teal)
                Spacer()
            }
        } else {
            // Never render counts as 0 when the read failed.
            Text("Counts unavailable — Desk state could not be read.")
                .font(.caption2)
                .foregroundStyle(.orange)
        }
    }

    private func metricChip(_ value: String, label: String, tint: Color) -> some View {
        VStack(alignment: .leading, spacing: 1) {
            Text(value)
                .font(.callout.weight(.semibold))
                .foregroundStyle(tint)
            Text(label)
                .font(.caption2)
                .foregroundStyle(.secondary)
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 6)
        .background(tint.opacity(0.10), in: RoundedRectangle(cornerRadius: 8))
    }

    // MARK: pursuits (veto surface, L11)

    @ViewBuilder
    private func pursuitsSection(_ model: WorkshopObservatoryModel) -> some View {
        Text("Open self-pursuits")
            .font(NativeAgentFont.section)
        if model.openPursuits.isEmpty {
            Text("No open self-pursuits — the agent has not opened anything, or all are closed.")
                .font(.caption)
                .foregroundStyle(.secondary)
        } else {
            ForEach(model.openPursuits) { pursuit in
                pursuitCard(pursuit)
                Divider()
            }
        }
    }

    @ViewBuilder
    private func pursuitCard(_ pursuit: WorkshopPursuitRow) -> some View {
        VStack(alignment: .leading, spacing: NativeAgentSpacing.xs) {
            HStack(alignment: .firstTextBaseline) {
                Text(pursuit.displayName)
                    .font(.callout.weight(.semibold))
                    .textSelection(.enabled)
                // The veto marker — User sees at a glance this was HER call.
                Text("agent-opened")
                    .font(.caption2.weight(.semibold))
                    .padding(.horizontal, 6)
                    .padding(.vertical, 2)
                    .background(Capsule().fill(Color.purple.opacity(0.18)))
                    .foregroundStyle(.purple)
                Spacer()
                Button("Veto", systemImage: "xmark.circle") {
                    onVeto(pursuit.handle)
                }
                .font(.caption)
                .buttonStyle(.borderless)
                .foregroundStyle(.red)
                .help("Close this pursuit (canceled) with a user-vetoed note.")
            }
            if pursuit.privateName?.isEmpty == false, pursuit.title != pursuit.displayName {
                Text("title: \(pursuit.title)")
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
            }

            labeled("Why", pursuit.why.isEmpty ? "—" : pursuit.why)
            labeled("Done looks like", pursuit.doneLooksLike.isEmpty ? "—" : pursuit.doneLooksLike)

            if !pursuit.citations.isEmpty {
                Text("Evidence: \(pursuit.citations.joined(separator: ", "))")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }

            scoreRow(pursuit.score)
            budgetRow(pursuit.budget)

            HStack {
                Text("Last worked")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                Spacer()
                Text(lastWorkedText(pursuit.lastWorkedAt))
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }

            if let rationale = pursuit.latestChoiceRationale, !rationale.isEmpty {
                Text(rationale)
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .textSelection(.enabled)
                    .lineLimit(3)
            }
            if !pursuit.workReceipts.isEmpty {
                VStack(alignment: .leading, spacing: 2) {
                    ForEach(Array(pursuit.workReceipts.enumerated()), id: \.offset) { _, receipt in
                        Text("• \(receipt)")
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                            .lineLimit(2)
                            .textSelection(.enabled)
                    }
                }
            }
        }
    }

    @ViewBuilder
    private func scoreRow(_ score: WorkshopScoreView?) -> some View {
        if let score {
            VStack(alignment: .leading, spacing: 1) {
                HStack {
                    Text("Choice score")
                        .font(.caption2.weight(.semibold))
                    Spacer()
                    Text(String(format: "%.2f", score.total))
                        .font(.caption2.weight(.semibold))
                        .foregroundStyle(.teal)
                }
                Text(String(
                    format: "ev %.2f · mom %.2f · close %.2f · drag −%.2f · recent −%.2f",
                    score.evidenceStrength, score.momentum, score.closureProximity,
                    score.noProgressPenalty, score.recentAttentionPenalty))
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }
        } else {
            Text("Choice score unavailable (no decodable pursuit payload).")
                .font(.caption2)
                .foregroundStyle(.orange)
        }
    }

    @ViewBuilder
    private func budgetRow(_ budget: WorkshopBudget?) -> some View {
        if let budget {
            HStack {
                Text("Budget")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                Spacer()
                Text("\(budget.sessionsUsed)/\(budget.maxSessions) sessions · \(budget.todayCount)/\(budget.perDayCap) today")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }
        } else {
            Text("Budget unavailable.")
                .font(.caption2)
                .foregroundStyle(.orange)
        }
    }

    // MARK: cadence

    @ViewBuilder
    private func cadenceSection(_ model: WorkshopObservatoryModel) -> some View {
        if !model.cadenceItems.isEmpty {
            Divider()
            Text("Owner cadence items")
                .font(NativeAgentFont.section)
            ForEach(model.cadenceItems) { item in
                HStack {
                    VStack(alignment: .leading, spacing: 1) {
                        Text(item.title)
                            .font(.caption)
                        Text(item.cadenceMode)
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                    }
                    Spacer()
                    Text(item.nextDue)
                        .font(.caption2)
                        .foregroundStyle(item.isDue ? .teal : .secondary)
                }
            }
        }
    }

    // MARK: receipts

    @ViewBuilder
    private func receiptsSection(_ state: WorkshopReceiptsState) -> some View {
        Text("Recent workshop sessions")
            .font(NativeAgentFont.section)
        switch state {
        case .unavailable(let reason):
            noticeRow(
                icon: "questionmark.circle", tint: .orange,
                title: "Session receipts unavailable", detail: reason)
        case .rows(let rows):
            if rows.isEmpty {
                Text("No workshop sessions have run yet.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            } else {
                ForEach(rows) { row in
                    VStack(alignment: .leading, spacing: 2) {
                        HStack {
                            Text(row.status)
                                .font(.caption2.weight(.semibold))
                                .foregroundStyle(statusTint(row.status))
                            Spacer()
                            Text(receiptTimeText(row.ts))
                                .font(.caption2)
                                .foregroundStyle(.secondary)
                        }
                        Text(row.summary.isEmpty ? "(no summary)" : row.summary)
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                            .lineLimit(2)
                            .textSelection(.enabled)
                        Text("\(row.model ?? "model unavailable") · \(row.artifactCount) artifact\(row.artifactCount == 1 ? "" : "s")")
                            .font(.caption2)
                            .foregroundStyle(.tertiary)
                    }
                    Divider()
                }
            }
        }
    }

    // MARK: helpers

    private func labeled(_ label: String, _ value: String) -> some View {
        VStack(alignment: .leading, spacing: 1) {
            Text(label)
                .font(.caption2.weight(.semibold))
                .foregroundStyle(.secondary)
            Text(value)
                .font(.caption2)
                .textSelection(.enabled)
        }
    }

    private func lastWorkedText(_ raw: String?) -> String {
        guard let raw, !raw.isEmpty else { return "never" }
        if let date = DeskClock.parseISO(raw) {
            return date.formatted(date: .abbreviated, time: .shortened)
        }
        return raw
    }

    private func receiptTimeText(_ raw: String) -> String {
        guard !raw.isEmpty else { return "—" }
        if let date = DeskClock.parseISO(raw) {
            return date.formatted(date: .abbreviated, time: .shortened)
        }
        return raw
    }

    private func statusTint(_ status: String) -> Color {
        switch status {
        case "completed": return .green
        case "blocked": return .orange
        case "refused": return .red
        default: return .secondary
        }
    }

    /// Thin wrapper over the shared `ObservatoryNoticeRow` (C10 dedup); call
    /// sites in this panel are unchanged.
    private func noticeRow(icon: String, tint: Color, title: String, detail: String?) -> some View {
        ObservatoryNoticeRow(icon: icon, tint: tint, title: title, detail: detail)
    }
}
