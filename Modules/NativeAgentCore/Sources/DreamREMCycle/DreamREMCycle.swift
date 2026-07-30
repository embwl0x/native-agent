import Foundation
import NativeAgentCore
import PersistenceCore
import ProviderRouting

// MARK: - Subsystem #10: DreamREMCycle
//
// SwiftNative owns dream/REM reads and manual cycle execution.
//
// The Swift implementation reads dream diary files directly and runs the
// manual dream/REM cycles through DreamCycleRunner and REMConsolidator.

// MARK: - DreamEntry

/// One entry from the dream_diary, preserving the legacy wire shape from
/// `_dream_cycle.list_entries(...)` / `latest_entry()` / `get_entry(date)`.
/// Verified against the retired daemon on 2026-05-30 — the keys are `date`,
/// `filename`, `content`, `size`, and (on list responses) `modified_at`.
/// Anything else that appears on the wire rides in `extras` so this struct
/// does not have to change when a compatibility field appears.
public struct DreamEntry: Sendable, Codable, Equatable {
    public var date: String
    public var filename: String?
    public var content: String?
    public var size: Int?
    public var modifiedAt: String?
    public var extras: JSONValue?

    public init(
        date: String,
        filename: String? = nil,
        content: String? = nil,
        size: Int? = nil,
        modifiedAt: String? = nil,
        extras: JSONValue? = nil
    ) {
        self.date = date
        self.filename = filename
        self.content = content
        self.size = size
        self.modifiedAt = modifiedAt
        self.extras = extras
    }

    private static let knownKeys: Set<String> = [
        "date", "filename", "content", "size", "modified_at", "modifiedAt", "extras",
    ]

    private struct AnyKey: CodingKey, Hashable {
        var stringValue: String
        var intValue: Int? { nil }
        init(_ s: String) { self.stringValue = s }
        init?(stringValue: String) { self.stringValue = stringValue }
        init?(intValue: Int) { return nil }
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: AnyKey.self)
        func str(_ k: String) throws -> String? {
            guard let key = AnyKey(stringValue: k) else { return nil }
            return try c.decodeIfPresent(String.self, forKey: key)
        }
        func intV(_ k: String) throws -> Int? {
            guard let key = AnyKey(stringValue: k) else { return nil }
            return try c.decodeIfPresent(Int.self, forKey: key)
        }
        func jv(_ k: String) throws -> JSONValue? {
            guard let key = AnyKey(stringValue: k) else { return nil }
            return try c.decodeIfPresent(JSONValue.self, forKey: key)
        }

        self.date = (try str("date")) ?? ""
        self.filename = try str("filename")
        self.content = try str("content")
        self.size = try intV("size")
        // Daemon emits snake_case `modified_at`; accept camelCase too.
        let modAtSnake = try str("modified_at")
        let modAtCamel = try str("modifiedAt")
        self.modifiedAt = modAtSnake ?? modAtCamel

        var unknown: [String: JSONValue] = [:]
        for key in c.allKeys where !Self.knownKeys.contains(key.stringValue) {
            if let v = try? c.decode(JSONValue.self, forKey: key) {
                unknown[key.stringValue] = v
            }
        }
        if let explicit = try jv("extras") {
            if case .object(let obj) = explicit {
                for (k, v) in obj { unknown[k] = v }
            } else {
                unknown["_extras_value"] = explicit
            }
        }
        self.extras = unknown.isEmpty ? nil : .object(unknown)
    }

    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: AnyKey.self)
        try c.encode(date, forKey: AnyKey("date"))
        try c.encodeIfPresent(filename, forKey: AnyKey("filename"))
        try c.encodeIfPresent(content, forKey: AnyKey("content"))
        try c.encodeIfPresent(size, forKey: AnyKey("size"))
        try c.encodeIfPresent(modifiedAt, forKey: AnyKey("modified_at"))
        if case .object(let obj)? = extras {
            for (k, v) in obj where !Self.knownKeys.contains(k) {
                try c.encode(v, forKey: AnyKey(k))
            }
        }
    }
}

// MARK: - DreamRunResult / REMRunResult

/// Result of POST /v1/dream/run. Daemon body shape is whatever
/// `_dream_cycle.run_now(force:)` returns; preserve verbatim.
public struct DreamRunResult: Sendable, Codable, Equatable {
    public var rawResponse: JSONValue
    public init(rawResponse: JSONValue) { self.rawResponse = rawResponse }

    enum CodingKeys: String, CodingKey { case rawResponse = "raw_response" }
}

/// Result of POST /v1/rem/run. Daemon body shape is whatever
/// `_rem_cycle.run_now(force:)` returns; preserve verbatim.
public struct REMRunResult: Sendable, Codable, Equatable {
    public var rawResponse: JSONValue
    public init(rawResponse: JSONValue) { self.rawResponse = rawResponse }

    enum CodingKeys: String, CodingKey { case rawResponse = "raw_response" }
}

// MARK: - Errors

public enum DreamREMCycleError: Error, LocalizedError {
    case invalidRequest
    case notFound
    case invalidResponse(status: Int)
    case unavailable
    case underlying(String)
    /// WAVE 35 W15: the cycle's gate is off. Mirrors the daemon POST routes'
    /// 403 (`dream_cycle_disabled` / `rem_cycle_disabled`,
    /// the retired daemon). `detail` carries the SAME message the
    /// daemon would have returned so a Swift pre-check is indistinguishable
    /// from the server's own refusal.
    case cycleDisabled(error: String, detail: String)

    public var errorDescription: String? {
        switch self {
        case .invalidRequest: return "dream/rem: invalid request"
        case .notFound: return "dream/rem: entry not found"
        case .invalidResponse(let s): return "dream/rem: native implementation returned unexpected status \(s)"
        case .unavailable: return "dream/rem: unavailable"
        case .underlying(let m): return "dream/rem: \(m)"
        case .cycleDisabled(_, let detail): return "dream/rem: \(detail)"
        }
    }
}

// MARK: - Protocol

/// DreamREMCycle surface. SwiftNative owns the file-backed read endpoints and
/// the manual dream/REM cycle triggers.
public protocol DreamREMCycleProtocol: Sendable {
    func listDreamDiary(limit: Int?) async throws -> [DreamEntry]
    func getDreamForToday() async throws -> DreamEntry?
    func getDreamForDate(_ date: String) async throws -> DreamEntry?
    func runDream(force: Bool) async throws -> DreamRunResult
    func runREM(force: Bool) async throws -> REMRunResult
}

// MARK: - DreamREMGate / DreamREMSchedule
//
// These helpers are pure Swift computation with NO LLM, NO file I/O, and NO
// persona:
//
//   1. THE GATE — the dream and REM policy checks. Disabled cycles return
//      `dream_cycle_disabled` / `rem_cycle_disabled` WITHOUT touching the LLM.
//      Keeping the gate in Swift lets UI and manual runs explain why a run is
//      blocked before launching a cycle.
//
//   2. THE SCHEDULE — nightly dream at 03:30 Central, written under the
//      previous Central calendar day, and weekly REM on the app schedule.
//      Pure date arithmetic lets the UI show "next dream pass at ..." without
//      crossing a runtime boundary.
//
// The cycle body is Swift too: DreamCycleRunner owns dream synthesis and
// dream_diary writes; REMConsolidator owns weekly REM distillation, proposal
// staging, GROWTH.md cap/eviction, and archival.

/// The two gates the dream/REM cycle consults, in the legacy policy shape.
/// Construct from the Trust policy the Swift app already decodes
/// (`TrustTrainingPolicy` + `personalityPolicy.dream_cycle_enabled`). Defaults
/// preserve the pre-cutover behavior for older policy files.
public struct DreamREMGatePolicy: Sendable, Equatable {
    /// `trainingPolicy.dream_scheduler` — default false.
    public var dreamScheduler: Bool
    /// `personalityPolicy.dream_cycle_enabled` — default true.
    public var dreamCycleEnabled: Bool
    /// `trainingPolicy.rem_cycle_enabled` — default true.
    public var remCycleEnabled: Bool

    public init(
        dreamScheduler: Bool = false,
        dreamCycleEnabled: Bool = true,
        remCycleEnabled: Bool = true
    ) {
        self.dreamScheduler = dreamScheduler
        self.dreamCycleEnabled = dreamCycleEnabled
        self.remCycleEnabled = remCycleEnabled
    }

    /// Dream cycle runs only when both the scheduler and personality gates are on.
    public var dreamEnabled: Bool { dreamScheduler && dreamCycleEnabled }

    /// REM consolidation uses one default-on gate.
    public var remEnabled: Bool { remCycleEnabled }

    /// User-facing details returned when a Swift pre-check blocks a run.
    public static let dreamDisabledDetail =
        "Enable the Trust setting 'Run dream cycle nightly' and keep personalityPolicy.dream_cycle_enabled enabled to run a dream cycle."
    public static let remDisabledDetail =
        "Enable trainingPolicy.rem_cycle_enabled to run REM consolidation."
}

/// Pure-compute next-run schedule for the dream + REM loops. NO LLM, NO I/O.
/// Nightly dreams run on the user's Central-time contract and write the previous
/// Central calendar day's diary key.
public enum DreamREMSchedule {
    public static let timeZoneIdentifier = "America/Chicago"

    /// Dream loop fire time.
    public static let dreamHour = 3
    public static let dreamMinute = 30

    /// REM loop fire time. SINGLE SOURCE OF TRUTH — the App-side scheduler
    /// (NativeAgentDreamCycleSchedule) forwards to these; do not duplicate the
    /// literals there. Legacy weekday numbering is Monday=0 ... Sunday=6, so
    /// weekday 6 is Sunday.
    public static let remHour = 4
    public static let remMinute = 30
    public static let remLegacySundayWeekday = 6

    public static func centralCalendar() -> Calendar {
        var cal = Calendar(identifier: .gregorian)
        cal.timeZone = TimeZone(identifier: timeZoneIdentifier) ?? TimeZone(secondsFromGMT: -6 * 60 * 60)!
        return cal
    }

    /// `%Y-%m-%d` in the supplied calendar.
    public static func todayKey(
        now: Date = Date(),
        calendar: Calendar = .current
    ) -> String {
        let c = calendar.dateComponents([.year, .month, .day], from: now)
        return String(format: "%04d-%02d-%02d", c.year ?? 0, c.month ?? 0, c.day ?? 0)
    }

    /// Nightly dream file stem. A 03:30 Central run on June 17 writes the
    /// June 16 diary entry because the dream reflects the previous day.
    public static func dreamEntryDateKey(
        now: Date = Date(),
        calendar: Calendar = centralCalendar()
    ) -> String {
        let previous = calendar.date(byAdding: .day, value: -1, to: now) ?? now.addingTimeInterval(-86_400)
        return todayKey(now: previous, calendar: calendar)
    }

    /// Today at HH:MM; if that's already past (`target <= now`), roll to
    /// tomorrow. Returns nil only if calendar arithmetic fails.
    public static func nextDreamRun(
        after now: Date = Date(),
        calendar: Calendar = .current
    ) -> Date? {
        nextDailyRun(hour: dreamHour, minute: dreamMinute, after: now, calendar: calendar)
    }

    /// The next occurrence of Sunday at HH:MM. If that target is today but
    /// already passed, bump a full week.
    public static func nextREMRun(
        after now: Date = Date(),
        calendar: Calendar = .current
    ) -> Date? {
        // Translate legacy weekday numbering (Mon=0...Sun=6) to the SAME day
        // by matching on the actual weekday, not Calendar's component number
        // (Calendar weekday is 1=Sunday…7=Saturday and depends on locale's
        // firstWeekday — we avoid that by stepping day-by-day until the
        // Python weekday matches, which is locale-independent).
        guard let todayTarget = calendar.date(
            bySettingHour: remHour, minute: remMinute, second: 0, of: now
        ) else { return nil }

        func legacyWeekday(of date: Date) -> Int {
            // Calendar.component(.weekday) -> 1=Sun...7=Sat. Legacy -> Mon=0...Sun=6.
            // Map: Sun(1)->6, Mon(2)->0, Tue(3)->1, … Sat(7)->5.
            let calWd = calendar.component(.weekday, from: date) // 1…7
            return (calWd + 5) % 7
        }

        let daysAhead = ((remLegacySundayWeekday - legacyWeekday(of: now)) % 7 + 7) % 7
        if daysAhead == 0 {
            // Same weekday: fire today unless HH:MM already passed → +7 days.
            if todayTarget > now { return todayTarget }
            return calendar.date(byAdding: .day, value: 7, to: todayTarget)
        }
        return calendar.date(byAdding: .day, value: daysAhead, to: todayTarget)
    }

    /// Shared daily-cron helper: today at HH:MM, rolled to tomorrow if past.
    private static func nextDailyRun(
        hour: Int, minute: Int, after now: Date, calendar: Calendar
    ) -> Date? {
        guard let target = calendar.date(
            bySettingHour: hour, minute: minute, second: 0, of: now
        ) else { return nil }
        if target > now { return target }
        return calendar.date(byAdding: .day, value: 1, to: target)
    }
}

// MARK: - FileBackedDreamDiary (true read-path port)

/// WAVE 33 W20: Swift-native dream-diary READ surface preserving retired behavior
/// (`the retired daemon` `list_entries` / `latest_entry` / `get_entry`).
/// These three are PURE FILE I/O on the daemon side — they glob
/// `<data_root>/dream_diary/*.md`, read the text, and stat size/mtime. No LLM,
/// no scheduler, no persona. The Dreams-tab read path is native; heavy
/// LLM-driven cycles run through Swift cycle runners.
///
/// Semantics pinned against the daemon source:
///   - list: `sorted(self._diary_dir.glob("*.md"), reverse=True)[:limit]`.
///     Python sorts the full Path lexicographically descending; for
///     `YYYY-MM-DD.md` stems that is newest-first. We sort by FILENAME
///     descending to match (not by stem-parsed date) so the byte order is
///     identical to Python's, including any non-date `.md` files that happen
///     to live in the dir. `date` is `path.stem`, `modified_at` is the
///     UTC ISO mtime.
///   - latest: `list_entries(limit=1)[0]` (L199-201).
///   - by-date: `<diary>/<date_key>.md`; nil when absent. Note the daemon's
///     by-date payload OMITS `modified_at` (L203-212) — we match that omission.
public struct FileBackedDreamDiary: Sendable {
    private let diaryDir: URL
    // `FileManager` is not Sendable, so we use `FileManager.default` inline
    // (it's safe for the read-only stat/read calls we make) rather than storing
    // it on a Sendable struct.
    private var fm: FileManager { .default }

    public init(dataRoot: URL) {
        self.diaryDir = dataRoot.appendingPathComponent("dream_diary", isDirectory: true)
    }

    /// Mirror `list_entries(limit)`: newest-first by filename, capped at `limit`.
    /// `limit` clamp matches the daemon ROUTE (`max(1, min(limit, 365))`); the
    /// daemon route default is 30 when the query param is absent.
    public func listEntries(limit: Int) -> [DreamEntry] {
        let clamped = max(1, min(limit, 365))
        let names = (try? fm.contentsOfDirectory(atPath: diaryDir.path)) ?? []
        let mdNames = names.filter { $0.hasSuffix(".md") }
            .sorted(by: >)   // filename DESCENDING == Python sorted(reverse=True)
            .prefix(clamped)
        let isoOut = ISO8601DateFormatter()
        isoOut.formatOptions = [.withInternetDateTime]
        var out: [DreamEntry] = []
        for name in mdNames {
            let url = diaryDir.appendingPathComponent(name)
            // Daemon wraps the per-file read+stat in try/except and `continue`s
            // on ANY failure — match that: a
            // file we can't read OR can't stat is skipped entirely, not emitted
            // with placeholder size:0/now (that would diverge from Python).
            guard let text = try? String(contentsOf: url, encoding: .utf8),
                  let attrs = try? fm.attributesOfItem(atPath: url.path),
                  let size = (attrs[.size] as? NSNumber)?.intValue,
                  let mtime = attrs[.modificationDate] as? Date
            else { continue }
            out.append(DreamEntry(
                date: (name as NSString).deletingPathExtension,
                filename: name,
                content: text,
                size: size,
                modifiedAt: isoOut.string(from: mtime)
            ))
        }
        return out
    }

    /// Mirror `latest_entry()` == `list_entries(limit=1)` first element.
    public func latestEntry() -> DreamEntry? {
        listEntries(limit: 1).first
    }

    /// Outcome of a by-date read so the caller can distinguish the daemon's
    /// THREE contractual responses:
    ///   - `.badPath`  → daemon 400 `{"error":"bad_path"}` (empty / reserved word
    ///     / multi-segment input the router would never have routed here).
    ///   - `.notFound` → daemon 404 (file does not exist).
    ///   - `.entry`    → daemon 200 with the entry payload.
    /// A genuine read/stat ERROR is NOT collapsed to notFound — it throws, so a
    /// Swift caller surfaces it the way Python's `read_text` would surface a
    /// 500 (Python `get_entry` has no try/except around the read).
    public enum ByDateResult: Sendable, Equatable {
        case badPath
        case notFound
        case entry(DreamEntry)
    }

    /// Mirror `get_entry(date_key)`: read `<diary>/<date_key>.md`. Daemon OMITS
    /// `modified_at` on this payload — we leave it nil to match.
    public func getEntryResult(_ dateKey: String) throws -> ByDateResult {
        let trimmed = dateKey.trimmingCharacters(in: .whitespaces)
        // SECURITY: the daemon's path router only reaches get_entry with a SINGLE
        // path segment (the `"/" not in ...` guard at the retired daemon).
        // A Swift caller could pass a raw string, so we must reject anything that
        // could traverse out of `dream_diary` (`/`, `..`, `.`, NUL) or hit a
        // reserved word — otherwise `appendingPathComponent("../../foo.md")` would
        // escape the diary dir. These all map to the daemon's 400 `bad_path`.
        if trimmed.isEmpty { return .badPath }
        if ["diary", "today", "run"].contains(trimmed) { return .badPath }
        if trimmed.contains("/") || trimmed.contains("\\")
            || trimmed.contains("\0") || trimmed == "." || trimmed == ".."
            || trimmed.contains("..") {
            return .badPath
        }
        let url = diaryDir.appendingPathComponent("\(trimmed).md")
        // Belt-and-suspenders: confirm the resolved file stays inside diaryDir.
        let resolvedDir = diaryDir.standardizedFileURL.resolvingSymlinksInPath().path
        let resolvedFile = url.standardizedFileURL.resolvingSymlinksInPath().path
        let dirPrefix = resolvedDir.hasSuffix("/") ? resolvedDir : resolvedDir + "/"
        guard resolvedFile.hasPrefix(dirPrefix) else { return .badPath }

        guard fm.fileExists(atPath: url.path) else { return .notFound }
        // A read/stat failure on an EXISTING file is a real error, not a "not
        // found" — throw so it isn't silently swallowed (Python lets it raise).
        let text = try String(contentsOf: url, encoding: .utf8)
        let attrs = try fm.attributesOfItem(atPath: url.path)
        let size = (attrs[.size] as? NSNumber)?.intValue ?? 0
        return .entry(DreamEntry(date: trimmed, filename: url.lastPathComponent, content: text, size: size))
    }

    /// Convenience: nil for badPath/notFound, the entry otherwise. Kept for the
    /// `DreamREMCycleProtocol.getDreamForDate` shape which can't distinguish
    /// 400 from 404 (both render as "no entry" in the Dreams UI). Read errors
    /// still propagate.
    public func getEntry(_ dateKey: String) throws -> DreamEntry? {
        switch try getEntryResult(dateKey) {
        case .badPath, .notFound: return nil
        case .entry(let e): return e
        }
    }
}

// MARK: - SwiftNative impl (file-backed reads; HTTP for the LLM cycle)

/// SwiftNative DreamREMCycle: file-backed reads plus native manual runners.
public actor SwiftNativeDreamREMCycle: DreamREMCycleProtocol {
    private let dataRoot: URL
    private let reader: FileBackedDreamDiary
    private let cycleDelegate: (any DreamREMCycleProtocol)?
    private let dreamRunner: DreamCycleRunner?
    private let remConsolidator: REMConsolidator?
    /// WAVE 35 W15: optional pure-compute gate. When supplied, run requests are
    /// pre-checked against the daemon's `is_enabled()` logic; a disabled cycle
    /// throws `DreamREMCycleError.cycleDisabled` WITHOUT a doomed POST (the
    /// daemon would have returned 403 anyway). When nil (the default), behavior
    /// is unchanged: the request is delegated and the daemon enforces the gate
    /// server-side, so the gate is never weakened — only short-circuited early.
    private let gate: DreamREMGatePolicy?

    public init(
        dataRoot: URL,
        cycleDelegate: (any DreamREMCycleProtocol)? = nil,
        dreamRunner: DreamCycleRunner? = nil,
        remConsolidator: REMConsolidator? = nil,
        gate: DreamREMGatePolicy? = nil,
        dreamMemoryDeltaProvider: DreamMemoryDeltaProvider? = nil,
        dreamFeltSummaryProvider: DreamFeltSummaryProvider? = nil,
        dreamMoodSink: DreamMoodSink? = nil,
        remStageApproval: REMApprovalStager? = nil,
        lifecycleObserver: (any LLMCallLifecycleObserving)? = nil
    ) {
        self.dataRoot = dataRoot
        self.reader = FileBackedDreamDiary(dataRoot: dataRoot)
        self.cycleDelegate = cycleDelegate
        let effectiveGate = gate ?? (cycleDelegate == nil ? Self.loadGatePolicy(dataRoot: dataRoot) : nil)
        self.gate = effectiveGate
        if cycleDelegate == nil {
            let llm = Self.makeDefaultLLMClient(lifecycleObserver: lifecycleObserver)
            let personaRoot = PersistenceCore.defaultPersonaRoot(dataRoot: dataRoot)
            // 2026-06-05 dream-design-restore (pass 2): thread the
            // memory-delta provider through so the scheduler-driven run
            // (NativeClient.runDream → SwiftNativeDreamREMCycle) gets the
            // same Self-half wiring as the BackgroundLoopsAssembly path.
            // Without this, the scheduler bypasses the assembly and the
            // Self-half is permanently empty for the nightly run.
            let resolvedDeltaProvider: DreamMemoryDeltaProvider =
                dreamMemoryDeltaProvider ?? { [] }
            // Felt-tone provider threads through for the SAME reason as the
            // delta provider above (2026-07-02): the scheduler-driven run
            // builds its runner HERE, not in BackgroundLoopsAssembly — without
            // this the scheduled nightly dream would silently never feel.
            let resolvedFeltProvider: DreamFeltSummaryProvider =
                dreamFeltSummaryProvider ?? { nil }
            // The dream's mood flows BACK into her slow disposition layer (U2a,
            // 2026-07-09). Threaded here for the same reason as the two providers
            // above: the scheduler-driven nightly builds its runner HERE, not in
            // BackgroundLoopsAssembly — unwired, the scheduled dream would feel the
            // day but the day would never feel the dream.
            let resolvedMoodSink: DreamMoodSink = dreamMoodSink ?? { _ in }
            self.dreamRunner = dreamRunner ?? DreamCycleRunner(
                dataRoot: dataRoot,
                personaRoot: personaRoot,
                llm: llm,
                memoryDeltaProvider: resolvedDeltaProvider,
                feltSummaryProvider: resolvedFeltProvider,
                moodSink: resolvedMoodSink
            )
            // remStageApproval is app-wired (ApprovalInbox + inbox card) so
            // the manual /v1/rem/run path stages approvals like the loop does.
            self.remConsolidator = remConsolidator ?? REMConsolidator(
                dataRoot: dataRoot,
                personaRoot: personaRoot,
                llm: llm,
                gate: effectiveGate ?? DreamREMGatePolicy(),
                stageApproval: remStageApproval
            )
        } else {
            self.dreamRunner = dreamRunner
            self.remConsolidator = remConsolidator
        }
    }

    public func listDreamDiary(limit: Int?) async throws -> [DreamEntry] {
        // nil limit == daemon route default of 30 (the HTTP shell omitted the
        // query param and the daemon route applied 30).
        reader.listEntries(limit: limit ?? 30)
    }

    public func getDreamForToday() async throws -> DreamEntry? {
        reader.latestEntry()
    }

    public func getDreamForDate(_ date: String) async throws -> DreamEntry? {
        try reader.getEntry(date)
    }

    public func runDream(force: Bool) async throws -> DreamRunResult {
        // WAVE 35 W15: pure-compute pre-check mirrors the retired daemon
        // (the POST route 403s when `_dream_cycle.is_enabled()` is false). The
        // `force` flag re-runs even if the target entry exists — it does NOT
        // bypass the gate (the daemon checks the gate BEFORE reading `force`),
        // so we don't let it bypass here either.
        if let gate, !gate.dreamEnabled {
            throw DreamREMCycleError.cycleDisabled(
                error: "dream_cycle_disabled",
                detail: DreamREMGatePolicy.dreamDisabledDetail
            )
        }
        if let cycleDelegate {
            return try await cycleDelegate.runDream(force: force)
        }
        guard let dreamRunner else {
            throw DreamREMCycleError.underlying("native dream runner unavailable")
        }
        let report = try await dreamRunner.runNightlyDreamCycle(force: force)
        return DreamRunResult(rawResponse: .object([
            "ok": .bool(report.errors.isEmpty),
            "backend": .string("swift"),
            "force": .bool(force),
            "sessionsProcessed": .int(Int64(report.sessionsProcessed)),
            "entriesWritten": .int(Int64(report.entriesWritten)),
            "disabled": .bool(report.disabled),
            "errors": .array(report.errors.map { .string($0) }),
        ]))
    }

    public func runREM(force: Bool) async throws -> REMRunResult {
        // WAVE 35 W15: pure-compute pre-check mirrors the retired daemon
        // (the POST route 403s when `_rem_cycle.is_enabled()` is false). As
        // with dream, `force` does not bypass the gate.
        if let gate, !gate.remEnabled {
            throw DreamREMCycleError.cycleDisabled(
                error: "rem_cycle_disabled",
                detail: DreamREMGatePolicy.remDisabledDetail
            )
        }
        if let cycleDelegate {
            return try await cycleDelegate.runREM(force: force)
        }
        guard let remConsolidator else {
            throw DreamREMCycleError.underlying("native REM consolidator unavailable")
        }
        // Manual runs (force) bypass the weekly idempotency marker —
        // without this, /v1/rem/run within 6 days of the scheduled pass
        // silently no-oped (gpt-5.5 review 2026-06-09).
        let report = try await remConsolidator.runWeeklyREM(force: force)
        return REMRunResult(rawResponse: .object([
            "ok": .bool(true),
            "backend": .string("swift"),
            "force": .bool(force),
            "proposalsGenerated": .int(Int64(report.proposalsGenerated)),
            "evidenceDatesMin": .int(Int64(report.evidenceDatesMin)),
            "tombstoneSkips": .int(Int64(report.tombstoneSkips)),
            "growthMDEvicted": .int(Int64(report.growthMDEvicted)),
            "archivedEntries": .int(Int64(report.archivedEntries)),
        ]))
    }

    private nonisolated static func makeDefaultLLMClient(
        lifecycleObserver: (any LLMCallLifecycleObserving)?
    ) -> any LLMClient {
        let router = SwiftNativeProviderRouting()
        return SwiftNativeLLMClient(
            router: router,
            codex: CodexAdapter(),
            anthropic: AnthropicAdapter(),
            openAI: OpenAIAdapter(),
            openAIOAuthDirect: OpenAIOAuthDirectAdapter(),
            anthropicOAuthDirect: AnthropicOAuthDirectAdapter(),
            xaiOAuthDirect: XAIOAuthDirectAdapter(),
            moonshot: MoonshotAdapter(),
            kimiCode: AnthropicAdapter.kimiCode(),
            openRouter: OpenRouterAdapter(),
            lifecycleObserver: lifecycleObserver
        )
    }

    private nonisolated static func loadGatePolicy(dataRoot: URL) -> DreamREMGatePolicy {
        let path = dataRoot
            .appendingPathComponent("trust", isDirectory: true)
            .appendingPathComponent("policy.json")
        guard let data = try? Data(contentsOf: path),
              let parsed = try? JSONValue.parse(data),
              case .object(let root) = parsed else {
            return DreamREMGatePolicy()
        }
        func object(_ key: String) -> [String: JSONValue] {
            if case .object(let obj)? = root[key] { return obj }
            return [:]
        }
        let training = object("trainingPolicy")
        let personality = object("personalityPolicy")
        let dreamScheduler: Bool = {
            if case .bool(let b)? = training["dream_scheduler"] { return b }
            return false
        }()
        let dreamEnabled: Bool = {
            if case .bool(let b)? = personality["dream_cycle_enabled"] { return b }
            return true
        }()
        let remEnabled: Bool = {
            if case .bool(let b)? = training["rem_cycle_enabled"] { return b }
            return true
        }()
        return DreamREMGatePolicy(
            dreamScheduler: dreamScheduler,
            dreamCycleEnabled: dreamEnabled,
            remCycleEnabled: remEnabled
        )
    }
}

// MARK: - Factory

// Native dream/REM factory. `gate` remains optional for callsites that already
// computed policy; nil loads the persisted trust policy in-process.
// `remStageApproval` lets the app pass its ApprovalInbox stager so manual REM
// runs stage approvals the same way the background loop does.
// `dreamMoodSink` threads through so a factory-built cycle that RUNS a dream
// participates in the slow disposition layer (U2a) — without it, the default
// no-op sink means the dream feels the day but the day never feels the dream.
// Today's factory callers are diary reads + REM (no dream), but the parameter
// keeps the U2 path impossible to bypass silently from a future call site.
public func makeDreamREMCycle(
    root: URL = PersistenceCore.defaultDataRoot(),
    gate: DreamREMGatePolicy? = nil,
    remStageApproval: REMApprovalStager? = nil,
    dreamMoodSink: DreamMoodSink? = nil,
    lifecycleObserver: (any LLMCallLifecycleObserving)? = nil
) -> any DreamREMCycleProtocol {
    return SwiftNativeDreamREMCycle(
        dataRoot: root, gate: gate,
        dreamMoodSink: dreamMoodSink, remStageApproval: remStageApproval,
        lifecycleObserver: lifecycleObserver)
}
