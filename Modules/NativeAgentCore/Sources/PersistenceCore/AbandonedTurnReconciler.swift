import Foundation
import NativeAgentCore

// MARK: - Terminal reconciliation for abandoned accepted turns
//
// A turn writes `turn.accepted` when the orchestrator takes it and a terminal
// row (`turn.terminal` / `turn.cancelled` / `turn.failed`) when it ends. A
// process that dies mid-turn writes neither a terminal nor an error, so the
// turn stays accepted forever and every reader that counts outcomes silently
// counts it as neither success nor failure.
//
// Measured 2026-09-11 over data/turn_traces: 1470 accepted turns since Aug 29,
// 33 of them with no terminal row of any kind — 9 in the audit's four-day
// window (e.g. a29e5e8c… 2026-09-10T14:32:51Z, 3623211e… 2026-09-09T21:07:54Z).
//
// WHAT THIS IS NOT: it does not replay, retry, resume or repair anything. It
// writes the one row the evidence supports — "this turn was accepted, nothing
// ever finished it" — so an unfinished turn is a RECORDED outcome instead of an
// invisible gap.
public struct AbandonedTurnReconciler: Sendable {
    /// A turn older than this cannot still be running: the whole-turn wall
    /// clock's progress ceiling is 6h, and that bounds a turn that keeps
    /// earning extensions. Anything past it is over, one way or another.
    public static let abandonedAfterSeconds: TimeInterval = 6 * 60 * 60

    /// Day files read by an ordinary sweep. Three covers a turn accepted near
    /// midnight plus the 6h window, and keeps the sweep's cost fixed. A sweep
    /// that finds a stale cursor scans back further — see `daysToScan`.
    public static let dayWindow = 3

    /// Upper bound on the catch-up scan after a gap. Without it, an install
    /// that has been off for months would read its whole trace history.
    public static let maximumDayWindow = 30

    /// This process's epoch. A turn accepted at or after it belongs to THIS
    /// run: it is either live right now or it already wrote its own terminal,
    /// and either way this sweep has no business judging it (GPT-5.6 round
    /// review, 2026-09-11 — the sweep could stamp "abandoned" on a long
    /// productive turn that was still running). Reconciliation is only ever
    /// about turns a PREVIOUS process left accepted.
    ///
    /// Resolved on first use; the launch hook touches it at startup so it is
    /// the launch time in production.
    public static let processEpoch = Date()

    private let dataRoot: URL
    private let lane: TurnTracePersistLane
    private let now: @Sendable () -> Date
    private let processEpoch: Date

    public init(
        dataRoot: URL? = nil,
        lane: TurnTracePersistLane = TurnTracePersistLane(),
        now: @escaping @Sendable () -> Date = { Date() },
        processEpoch: Date = AbandonedTurnReconciler.processEpoch
    ) {
        self.lane = lane
        self.dataRoot = dataRoot ?? lane.resolvedDataRoot()
        self.now = now
        self.processEpoch = processEpoch
    }

    public struct Outcome: Sendable, Equatable {
        public let acceptedScanned: Int
        public let reconciled: [String]
        /// Accepted turns with no terminal that are still INSIDE the wall-clock
        /// window — they may be running right now, so they are left alone.
        public let tooRecentToJudge: Int

        public init(acceptedScanned: Int, reconciled: [String], tooRecentToJudge: Int) {
            self.acceptedScanned = acceptedScanned
            self.reconciled = reconciled
            self.tooRecentToJudge = tooRecentToJudge
        }
    }

    private struct Accepted {
        let ts: Date
        let sessionId: String?
        let surface: String?
    }

    /// One bounded pass. Returns what it wrote so a caller can log or test it.
    @discardableResult
    public func sweep() async -> Outcome {
        let today = now()
        var accepted: [String: Accepted] = [:]
        var terminated: Set<String> = []

        let scan = scanRange(today: today)
        for dayOffset in scan.newestOffset...scan.oldestOffset {
            guard let day = Self.dayCalendar.date(byAdding: .day, value: -dayOffset, to: today)
            else { continue }
            let path = lane.path(for: day)
            // A MISSING day file is an empty day. An UNREADABLE one is not:
            // a torn or transiently locked file could hide a real terminal or
            // an accepted turn, so the sweep stops here and writes nothing —
            // the cursor does not move, and the next sweep tries again
            // (GPT-5.6 round review r3, 2026-09-11).
            guard FileManager.default.fileExists(atPath: path.path) else { continue }
            guard let handle = try? String(contentsOf: path, encoding: .utf8) else {
                return Outcome(acceptedScanned: 0, reconciled: [], tooRecentToJudge: 0)
            }
            for line in handle.split(separator: "\n", omittingEmptySubsequences: true) {
                guard let data = String(line).data(using: .utf8),
                      let value = try? JSONValue.parse(data),
                      case .object(let row) = value,
                      case .string(let kind)? = row["kind"],
                      case .string(let turnId)? = row["turnId"],
                      !turnId.isEmpty, turnId != "unknown" else { continue }
                switch kind {
                case "turn.accepted":
                    guard accepted[turnId] == nil else { continue }
                    guard case .string(let stamp)? = row["ts"],
                          let ts = Self.iso8601(stamp) else { continue }
                    accepted[turnId] = Accepted(
                        ts: ts,
                        sessionId: Self.string(row["sessionId"]),
                        surface: Self.string(row["surface"])
                    )
                case "turn.terminal", "turn.cancelled", "turn.failed":
                    terminated.insert(turnId)
                default:
                    continue
                }
            }
        }

        var tooRecent = 0
        var written: [String] = []
        let candidates = accepted
            .filter { !terminated.contains($0.key) }
            .sorted { $0.value.ts < $1.value.ts }
        for (turnId, row) in candidates {
            let age = today.timeIntervalSince(row.ts)
            guard age > Self.abandonedAfterSeconds else {
                tooRecent += 1
                continue
            }
            // A turn this process accepted is never abandoned by this process.
            guard row.ts < processEpoch else {
                tooRecent += 1
                continue
            }
            let minutes = Int((age / 60).rounded())
            // CHECK AND APPEND IN ONE CRITICAL SECTION. The scan above is
            // unlocked, so a real terminal can land between it and this write;
            // the guard re-reads the target day file under the lane's own
            // write lock and stands down if one did (GPT-5.6 round review,
            // 2026-09-11). A terminal always wins over an abandoned verdict.
            //
            // ACROSS DAY FILES. The guard only sees the file this row is being
            // appended to (today's). A real terminal for a turn accepted
            // yesterday evening lands in the turn's OWN day file, or in the
            // next one if it crossed local midnight — neither of which is
            // today's when the sweep runs a day later. Those are read here too,
            // so an abandoned verdict never stands next to a real terminal.
            // They are passed as `alsoLocking` so the predicate reads them
            // UNDER THEIR OWN LOCKS, inside the same critical section as the
            // append — a real terminal can no longer land between the sibling
            // read and the synthetic write (GPT-5.6 round review, 2026-09-11).
            //
            // CALENDAR DAYS, not 86_400s: across a DST transition a fixed
            // interval names the day after (or before) the real neighbour, so
            // the file the true terminal landed in would never be locked or
            // read (GPT-5.6 round review r2, 2026-09-11). Sorted so every
            // caller takes these nested locks in the same order.
            let siblingDays = Set(
                ([row.ts]
                    + [-1, 1].compactMap {
                        Self.dayCalendar.date(byAdding: .day, value: $0, to: row.ts)
                    })
                    .map { lane.path(for: $0) }
            )
            .filter { $0 != lane.path(for: today) }
            .sorted { $0.path < $1.path }
            let wrote = await lane.appendGuarded(
                TurnTraceEvent(
                    turnId: turnId,
                    ts: today,
                    kind: "turn.terminal",
                    sessionId: row.sessionId,
                    surface: row.surface,
                    payload: .object([
                        "schema": .string("turn.lifecycle.v1"),
                        "status": .string("abandoned"),
                        "observedBy": .string("terminal_reconciliation"),
                        "reason": .string("abandoned: no terminal after \(minutes) minutes"),
                        "acceptedAt": .string(Self.iso8601String(row.ts)),
                    ])
                ),
                alsoLocking: siblingDays,
                shouldAppend: { current in
                    if Self.containsTerminal(forTurn: turnId, in: current) { return false }
                    for path in siblingDays {
                        // Missing sibling: nothing there. Unreadable sibling:
                        // it may hold the real terminal, so refuse to write.
                        guard FileManager.default.fileExists(atPath: path.path) else { continue }
                        guard let text = try? String(contentsOf: path, encoding: .utf8) else {
                            return false
                        }
                        if Self.containsTerminal(forTurn: turnId, in: text) { return false }
                    }
                    return true
                }
            )
            if wrote { written.append(turnId) }
        }
        // Every eligible candidate in the days ACTUALLY SCANNED has now been
        // judged, so the cursor advances over exactly those days and no
        // further. When the backlog was longer than `maximumDayWindow` the
        // newest scanned day is not today: the unscanned remainder stays
        // behind the cursor and the next sweep continues from there, instead
        // of the old jump to today that abandoned it forever (GPT-5.6 round
        // review, 2026-09-11).
        if let newestScannedDay = Self.dayCalendar.date(
            byAdding: .day, value: -scan.newestOffset, to: today
        ) {
            writeCursor(day: newestScannedDay)
        }
        return Outcome(
            acceptedScanned: accepted.count,
            reconciled: written,
            tooRecentToJudge: tooRecent
        )
    }

    /// Day-offsets from `today` this sweep reads (0 = today), oldest offset
    /// last. Ordinarily `dayWindow` days ending today; after a gap it reaches
    /// back to the last swept day so a turn abandoned outside the ordinary
    /// window is not missed. When the gap is longer than `maximumDayWindow`
    /// the window sits at the OLD end of the backlog — the sweep drains the
    /// oldest unswept days first and the cursor advances by that much, so the
    /// next sweep continues where this one stopped rather than skipping to
    /// today.
    private func scanRange(today: Date) -> (newestOffset: Int, oldestOffset: Int) {
        // No cursor (first run, or a corrupt file) is NOT "start at today":
        // that records today as swept and strands every older trace file
        // forever, which is also the migration path for every install made
        // before the cursor existed. Start one day BEFORE the oldest day file
        // that actually exists and let the ordinary 30-day window walk
        // forward, oldest-first, over successive sweeps (GPT-5.6 round review
        // r2, 2026-09-11).
        guard let cursorDay = persistedCursorDay() ?? oldestTraceDay().flatMap({
            Self.dayCalendar.date(byAdding: .day, value: -1, to: $0)
        }) else {
            // Nothing has ever been traced. Ordinary window ending today.
            return (0, Self.dayWindow - 1)
        }
        let calendar = Self.dayCalendar
        let lastOffset = max(0, calendar.dateComponents(
            [.day],
            from: calendar.startOfDay(for: cursorDay),
            to: calendar.startOfDay(for: today)
        ).day ?? 0)
        // Days back that still need a look, counting the cursor day itself.
        let unswept = max(Self.dayWindow, lastOffset + 1)
        let window = min(Self.maximumDayWindow, unswept)
        let oldestOffset = unswept - 1
        return (oldestOffset - (window - 1), oldestOffset)
    }

    /// The day recorded by the last sweep, if the cursor file is readable.
    private func persistedCursorDay() -> Date? {
        guard let raw = try? String(contentsOf: cursorPath, encoding: .utf8),
              let value = try? JSONValue.parse(Data(raw.utf8)),
              case .object(let obj) = value,
              case .string(let day)? = obj["lastSweptDay"],
              let last = TurnTracePersistLane.dayFormatter.date(from: day) else { return nil }
        return last
    }

    /// Oldest `yyyy-MM-dd.jsonl` day file on disk, or nil when none exist.
    /// Read from the lane's own directory so writer root overrides apply.
    private func oldestTraceDay() -> Date? {
        let dir = lane.path(for: now()).deletingLastPathComponent()
        guard let entries = try? FileManager.default.contentsOfDirectory(
            at: dir, includingPropertiesForKeys: nil
        ) else { return nil }
        return entries
            .filter { $0.pathExtension == "jsonl" }
            .compactMap {
                TurnTracePersistLane.dayFormatter.date(
                    from: $0.deletingPathExtension().lastPathComponent
                )
            }
            .min()
    }

    /// Day arithmetic in exactly the timezone the ledger file names are
    /// formatted in. A fixed 86,400s "day" can name the wrong calendar day on
    /// a 23- or 25-hour local day, which means reading and locking the wrong
    /// ledger file.
    static let dayCalendar: Calendar = {
        var calendar = Calendar.current
        calendar.timeZone = TurnTracePersistLane.dayFormatter.timeZone
        return calendar
    }()

    private var cursorPath: URL {
        dataRoot
            .appendingPathComponent("turn_traces", isDirectory: true)
            .appendingPathComponent("abandoned-reconciler-cursor.json")
    }

    private func writeCursor(day date: Date) {
        let dir = cursorPath.deletingLastPathComponent()
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let day = TurnTracePersistLane.dayFormatter.string(from: date)
        try? Data("{\"lastSweptDay\":\"\(day)\"}".utf8).write(to: cursorPath, options: .atomic)
    }

    /// Does this JSONL text already carry a terminal row for `turnId`? The
    /// substring pre-check keeps a 20k-line day file from being parsed for a
    /// turn it never mentions.
    static func containsTerminal(forTurn turnId: String, in text: String) -> Bool {
        guard text.contains(turnId) else { return false }
        for line in text.split(separator: "\n", omittingEmptySubsequences: true) {
            guard line.contains(turnId),
                  let data = String(line).data(using: .utf8),
                  let value = try? JSONValue.parse(data),
                  case .object(let row) = value,
                  case .string(let rowTurnId)? = row["turnId"],
                  rowTurnId == turnId,
                  case .string(let kind)? = row["kind"] else { continue }
            if kind == "turn.terminal" || kind == "turn.cancelled" || kind == "turn.failed" {
                return true
            }
        }
        return false
    }

    private static func string(_ value: JSONValue?) -> String? {
        if case .string(let text)? = value, !text.isEmpty { return text }
        return nil
    }

    private static func iso8601(_ raw: String) -> Date? {
        let withFraction = ISO8601DateFormatter()
        withFraction.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        if let parsed = withFraction.date(from: raw) { return parsed }
        return ISO8601DateFormatter().date(from: raw)
    }

    private static func iso8601String(_ date: Date) -> String {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return formatter.string(from: date)
    }
}
