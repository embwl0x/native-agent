import Foundation
import NativeAgentCore
import PersistenceCore

// MARK: - Bounded reader for the per-day turn-trace feed
//
// Shared by `PromptPrefixHealthCheck` and `SubconsciousVitalsCheck`. It exists
// so both rows obey the same three rules, written once:
//
//   1. BOUNDED. The feed is 20k rows/day and grows without a ceiling. A health
//      row may not turn into an unbounded read, so each day file is TAILED to
//      `budgetPerDay` bytes and the first partial line of a tailed read is
//      dropped. A day that had to be tailed is REPORTED, so "n rows" can never
//      be mistaken for "all rows".
//   2. OFF THE TURN. Nothing here is wired to a timer, a chat hook, or the
//      cognition runtime. Reading only happens inside `DoctorCheck.run()`,
//      which is a nonisolated async function executed on the cooperative pool
//      by `SwiftNativeDoctorChecks.runAll` — never on the main actor and never
//      on a turn. `DoctorScanCache` keeps a Doctor session from paying the
//      read twice.
//   3. HONEST ABOUT WHAT IT COULD NOT READ. A day file that EXISTS but cannot
//      be opened/decoded is an `unreadableDay`, never a zero. Absent day files
//      are simply absent — that is a different fact, and the callers report it
//      as UNMEASURED rather than as health.

/// One parsed turn-trace row, reduced to the envelope the Doctor rows need.
struct TurnTraceRow: Sendable {
    let kind: String
    let ts: Date
    let turnId: String
    let sessionId: String?
    let surface: String?
    let payload: [String: JSONValue]
}

/// What a window scan could and could not see. Every field here exists so a
/// caller can say what it measured instead of implying it measured everything.
struct TurnTraceScanSummary: Sendable {
    /// Day files that existed and were read (whole or tailed).
    var daysPresent: [String] = []
    /// Day files that existed but could not be opened or decoded. Any entry
    /// here makes the owning check FAIL — an unreadable input is not a zero.
    var unreadableDays: [String] = []
    /// Day files whose head was cut by the byte budget.
    var truncatedDays: [String] = []
    /// Lines that were non-empty but did not parse as a trace row object.
    var malformedLines: Int = 0
    /// Rows matching the requested kinds that were handed to the caller.
    var matchedRows: Int = 0

    var isEmptyFeed: Bool { daysPresent.isEmpty && unreadableDays.isEmpty }
}

// MARK: - DoctorMeasurementWindow
//
// 2026-09-02, live incident: both new rows graded a rolling 7-day window, so
// they were grading PRE-FIX history — turns from before the change they exist
// to watch. The verdicts were arithmetically true and operationally a lie:
// "prefix cache is broken" described a build that is no longer running.
//
// The floor is therefore the moment the CURRENT BUILD started running, read
// from the launch descriptor the app already writes on startup
// (`data/macctl_bridge.json`, which carries the same NativeAgentBuildIdentity
// fields plus `writtenAt`). A stamp from a DIFFERENT build says nothing about
// this one, so it is refused rather than used. With no usable stamp the floor
// falls back to the last 24h — short enough that pre-fix history cannot
// dominate, and the row SAYS which floor it used either way.

struct DoctorMeasurementWindow: Sendable {
    /// Rows older than this are not this build's behavior and are not read.
    let floor: Date
    /// The clause the check prints, so the operator always knows what window
    /// produced the number.
    let describedAs: String
    /// True when no usable build launch stamp was found.
    let isFallback: Bool

    /// Day files worth opening for this floor, capped so a bogus stamp can
    /// never widen the bounded read.
    func dayFilesToRead(now: Date, maximum: Int) -> Int {
        let span = now.timeIntervalSince(floor)
        guard span > 0 else { return 1 }
        return max(1, min(maximum, Int(span / 86_400) + 2))
    }
}

enum DoctorWindowFloor {
    /// Fallback window when the running build's launch cannot be established.
    static let fallbackWindow: TimeInterval = 24 * 60 * 60

    static func resolve(
        root: URL,
        now: Date,
        identity: NativeAgentBuildIdentity = .current
    ) -> DoctorMeasurementWindow {
        guard let stamp = launchStamp(root: root, identity: identity), stamp <= now else {
            return DoctorMeasurementWindow(
                floor: now.addingTimeInterval(-fallbackWindow),
                describedAs: "no launch stamp for the running build on disk, so the window"
                    + " falls back to the last 24h",
                isFallback: true
            )
        }
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime]
        return DoctorMeasurementWindow(
            floor: stamp,
            describedAs: "since this build launched at \(formatter.string(from: stamp))",
            isFallback: false
        )
    }

    /// The launch descriptor's `writtenAt`, but ONLY when its build identity is
    /// the build now running. A stamp left by a previous build would put the
    /// floor before the change under observation, which is the whole bug.
    private static func launchStamp(root: URL, identity: NativeAgentBuildIdentity) -> Date? {
        let path = root.appendingPathComponent("macctl_bridge.json")
        guard let data = try? Data(contentsOf: path),
              let value = try? JSONValue.parse(data),
              case .object(let object) = value,
              let writtenAt = object["writtenAt"]?.stringValue,
              let stamp = TurnTraceWindowReader.parseISO8601(writtenAt)
        else { return nil }
        guard object["build"]?.stringValue == identity.build,
              object["version"]?.stringValue == identity.version
        else { return nil }
        // A revision recorded on the stamp must match the running one. Absent
        // on either side is tolerated (older bundles did not stamp it); a
        // DISAGREEMENT is not.
        if let stamped = object["sourceRevision"]?.stringValue,
           let running = identity.sourceRevision,
           stamped.lowercased() != running.lowercased() {
            return nil
        }
        return stamp
    }
}

enum TurnTraceWindowReader {
    /// Per-day tail budget. 1 MiB holds roughly a day of this feed's rows; a
    /// busier day is tailed and SAYS it was tailed.
    static let defaultBudgetPerDay = 1 * 1024 * 1024

    /// Scan the last `days` day files under `<root>/turn_traces`, newest day
    /// first is irrelevant — rows are handed to `handle` in file order and the
    /// callers sort by `ts` themselves.
    ///
    /// `kinds` is a cheap prefilter applied as a substring test on the raw line
    /// before any JSON parsing, which is what keeps a 20k-row day affordable.
    /// `floor` is the measurement window's lower bound — rows older than it
    /// belong to a build that is no longer running and are not this row's
    /// business. `days` still caps how many day FILES may be opened, so the
    /// read stays bounded no matter what the floor says.
    static func scan(
        root: URL,
        now: Date,
        days: Int,
        floor: Date,
        kinds: Set<String>,
        budgetPerDay: Int = defaultBudgetPerDay,
        handle: (TurnTraceRow) -> Void
    ) -> TurnTraceScanSummary {
        var summary = TurnTraceScanSummary()
        let dir = root.appendingPathComponent("turn_traces", isDirectory: true)
        let formatter = DateFormatter()
        formatter.calendar = Calendar(identifier: .gregorian)
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone.current
        formatter.dateFormat = "yyyy-MM-dd"

        // The floor wins over the day count: opening yesterday's file is fine,
        // counting a row from before this build launched is not.
        let cutoff = floor

        for offset in 0..<max(days, 1) {
            let day = now.addingTimeInterval(-Double(offset) * 24 * 60 * 60)
            let name = formatter.string(from: day)
            let path = dir.appendingPathComponent("\(name).jsonl")
            guard FileManager.default.fileExists(atPath: path.path) else { continue }

            guard let (text, truncated) = tail(path, budget: budgetPerDay) else {
                // The file is THERE and unreadable. Rule 3.
                summary.unreadableDays.append(name)
                continue
            }
            summary.daysPresent.append(name)
            if truncated { summary.truncatedDays.append(name) }

            for line in text.split(separator: "\n", omittingEmptySubsequences: true) {
                guard kinds.contains(where: { line.contains($0) }) else { continue }
                // The substring hit above is only a CANDIDATE: a valid
                // context.ready or provider.requestStarted row can mention a
                // requested kind inside its payload. Parse first, and decide
                // "malformed" only on a line that genuinely failed to parse as
                // a trace row. A row that parsed fine and simply carries a
                // different top-level kind is someone else's row, not a defect.
                guard let data = String(line).data(using: .utf8),
                      let value = try? JSONValue.parse(data),
                      case .object(let row) = value
                else {
                    summary.malformedLines += 1
                    continue
                }
                guard case .string(let kind)? = row["kind"] else {
                    // A trace row with no top-level kind really is malformed.
                    summary.malformedLines += 1
                    continue
                }
                // Not ours. Silence, not a corruption warning.
                guard kinds.contains(kind) else { continue }
                guard case .string(let ts)? = row["ts"],
                      let stamp = parseISO8601(ts)
                else {
                    // One of ours, but undatable — that is a real defect.
                    summary.malformedLines += 1
                    continue
                }
                guard stamp >= cutoff else { continue }
                var payload: [String: JSONValue] = [:]
                if case .object(let object)? = row["payload"] { payload = object }
                let turnId: String = {
                    if case .string(let value)? = row["turnId"] { return value }
                    return ""
                }()
                summary.matchedRows += 1
                handle(
                    TurnTraceRow(
                        kind: kind,
                        ts: stamp,
                        turnId: turnId,
                        sessionId: stringValue(row["sessionId"]),
                        surface: stringValue(row["surface"]),
                        payload: payload
                    )
                )
            }
        }
        return summary
    }

    /// Read at most `budget` bytes from the END of `path`. Returns nil only
    /// when the file exists but cannot be read or decoded — the caller turns
    /// that into a FAIL. The bool says whether the head was cut.
    private static func tail(_ path: URL, budget: Int) -> (String, Bool)? {
        guard let handle = try? FileHandle(forReadingFrom: path) else { return nil }
        defer { try? handle.close() }
        guard let size = try? handle.seekToEnd() else { return nil }
        let base = size > UInt64(budget) ? size - UInt64(budget) : 0
        let truncated = base > 0
        // A byte-offset tail can land mid-UTF8. Nudge the start forward a few
        // bytes rather than calling a perfectly readable day unreadable. A
        // WHOLE-file read that will not decode really is unreadable, so the
        // nudge only applies to a tailed read.
        for nudge in 0...(truncated ? 4 : 0) {
            let start = base + UInt64(nudge)
            guard start <= size,
                  (try? handle.seek(toOffset: start)) != nil,
                  let data = try? handle.readToEnd(),
                  var text = String(data: data, encoding: .utf8)
            else { continue }
            if truncated, let newline = text.firstIndex(of: "\n") {
                // Drop the partial first line the byte cut produced.
                text = String(text[text.index(after: newline)...])
            }
            return (text, truncated)
        }
        return nil
    }

    static func parseISO8601(_ raw: String) -> Date? {
        let fractional = ISO8601DateFormatter()
        fractional.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        if let date = fractional.date(from: raw) { return date }
        return ISO8601DateFormatter().date(from: raw)
    }

    static func stringValue(_ value: JSONValue?) -> String? {
        if case .string(let string)? = value, !string.isEmpty { return string }
        return nil
    }
}

// MARK: - JSONValue numeric accessors
//
// The feed writes token counts as ints and ratios as doubles; a reader that
// only handles one of them silently drops half the data.

extension JSONValue {
    var intValue: Int? {
        switch self {
        case .int(let value): return Int(value)
        case .double(let value): return Int(exactly: value.rounded())
        default: return nil
        }
    }

    var doubleValue: Double? {
        switch self {
        case .int(let value): return Double(value)
        case .double(let value): return value
        default: return nil
        }
    }

    var boolValue: Bool? {
        if case .bool(let value) = self { return value }
        return nil
    }

    var stringValue: String? {
        if case .string(let value) = self { return value }
        return nil
    }
}

// MARK: - DoctorScanCache
//
// User's constraint: these rows must never cost a turn, and opening Doctor must
// not re-read the feed for every render. One short-lived memo per check
// instance — long enough that a Doctor session pays the scan once, short enough
// that pressing Run Doctor a minute later MEASURES AGAIN rather than replaying
// a stale row. A cached row is never presented as fresher than it is.
actor DoctorScanCache {
    private var cached: (result: CheckResult, at: Date)?
    private let ttl: TimeInterval

    init(ttl: TimeInterval = 60) {
        self.ttl = ttl
    }

    /// The still-fresh memo, or nil when the caller must measure again.
    func fresh(now: Date) -> CheckResult? {
        guard let cached, now.timeIntervalSince(cached.at) < ttl else { return nil }
        return cached.result
    }

    func store(_ result: CheckResult, at moment: Date) {
        cached = (result, moment)
    }
}
