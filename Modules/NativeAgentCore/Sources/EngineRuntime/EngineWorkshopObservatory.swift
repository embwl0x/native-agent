import Foundation
import PersistenceCore
import Desk
import WorkshopExecution

// MARK: - Pure view-models (data-shaping, no SwiftUI)

/// A pursuit's blended selection score, flattened for display. Mirrors
/// `WorkshopPump.PursuitChoiceScore` but decoupled so the view never depends on
/// the pump's shape.
public struct WorkshopScoreView: Equatable, Sendable {
    public let total: Double
    public let evidenceStrength: Double
    public let momentum: Double
    public let closureProximity: Double
    public let noProgressPenalty: Double
    public let recentAttentionPenalty: Double
}

/// The two hard caps a pursuit lives under, with the current draw against each.
public struct WorkshopBudget: Equatable, Sendable {
    public let sessionsUsed: Int      // reservations.count over the pursuit's life
    public let maxSessions: Int       // pursuit.maxSessions (its doneLooksLike budget)
    public let todayCount: Int        // reservations reserved today
    public let perDayCap: Int         // SwiftNativeDeskStore.maxWorkSessionsPerPursuitPerDay
}

/// One OPEN self-pursuit, shaped for the owner's veto view and audit needs
/// what she chose to pursue and why, plus the live score + budget + her recent
/// choice rationale and work receipts.
public struct WorkshopPursuitRow: Identifiable, Equatable, Sendable {
    public let handle: String
    public let alias: String
    public let title: String
    public let privateName: String?
    public let why: String
    public let doneLooksLike: String
    public let status: String
    /// nil when the item is origin=agent but carries no decodable pursuit payload
    /// (a corrupt row) — shown as "score unavailable", never a misleading 0.
    public let score: WorkshopScoreView?
    public let budget: WorkshopBudget?
    public let lastWorkedAt: String?
    /// The most recent "chose: …" rationale from her notes (the recorded volition).
    public let latestChoiceRationale: String?
    /// Recent work receipts from her notes (completion + work-log lines), newest
    /// first, bounded. Excludes the "chose:" rationale lines.
    public let workReceipts: [String]
    /// Evidence citation tokens (source-mix), for the veto rationale.
    public let citations: [String]

    public var id: String { handle }
    public var displayName: String { (privateName?.isEmpty == false ? privateName : nil) ?? title }

    /// Notes whose text begins with this marker are choice rationales, not work
    /// receipts (the pump writes "chose: …" via appendWorkReceipt before a run).
    public static let choiceMarker = "chose:"

    public static func from(item: DeskItem, now: Date) -> WorkshopPursuitRow {
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
public struct WorkshopCadenceRow: Identifiable, Equatable, Sendable {
    public let handle: String
    public let title: String
    public let cadenceMode: String
    public let nextDue: String   // formatted, or "due now"
    public let isDue: Bool

    public var id: String { handle }
}

/// The whole panel model, folded from a full DeskState. Counts are honest: an
/// unavailable read is represented by a nil model (the panel then renders an
/// "unavailable" notice), never a zeroed-out one.
public struct WorkshopObservatoryModel: Equatable, Sendable {
    public let openPursuits: [WorkshopPursuitRow]
    public let cadenceItems: [WorkshopCadenceRow]
    /// Distinct reservations across ALL pursuits (open + terminal) reserved today
    /// — the same count the store's global 6/day cap is measured against.
    public let sessionsToday: Int
    public let globalCap: Int
    public let maxOpenPursuits: Int

    public var openPursuitCount: Int { openPursuits.count }

    /// L11: sourced from the FULL DeskState (store query), never the capped
    /// projection — every open agent pursuit is present so none falls out of the
    /// veto view.
    public static func build(state: DeskState, now: Date) -> WorkshopObservatoryModel {
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
public struct WorkshopReceiptRow: Identifiable, Equatable, Sendable {
    public let handle: String
    public let reservationId: String
    public let status: String
    public let summary: String
    public let model: String?
    public let artifactCount: Int
    public let ts: String

    public var id: String { "\(ts)|\(reservationId)" }

    public static func fromJSON(_ value: JSONValue) -> WorkshopReceiptRow? {
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
public enum WorkshopReceiptsState: Equatable, Sendable {
    case unavailable(String)
    case rows([WorkshopReceiptRow])
}

/// Reads + bounds the workshop receipts feed. The parsing is a pure function over
/// `[String]` lines so it is unit-testable without disk.
public enum WorkshopReceiptsReader {
    /// Newest-first bound — a busy week can't bloat the panel.
    public static let rowLimit = 20
    public static let maxErrorChars = 240

    /// Pure: fold raw JSONL lines (file/append order, newest LAST) into the panel
    /// state, newest FIRST and bounded. An empty feed → `.rows([])` (no sessions
    /// yet, honest). Non-empty bytes that yield ZERO parseable rows → `.unavailable`
    /// (something is on disk but unreadable — never render that as "no sessions").
    public static func rows(fromLines lines: [String], limit: Int = rowLimit) -> WorkshopReceiptsState {
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
    public static func load(receiptsPath: URL, limit: Int = rowLimit) -> WorkshopReceiptsState {
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
public struct WorkshopObservatorySnapshot: Equatable, Sendable {
    public let model: WorkshopObservatoryModel?
    public let deskUnavailable: String?
    public let receipts: WorkshopReceiptsState

    /// A one-line hint for the collapsible header while collapsed.
    public var hint: String {
        guard let model else { return "unavailable" }
        return "\(model.openPursuitCount) open · \(model.sessionsToday)/\(model.globalCap) today"
    }

    public static func load(
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
