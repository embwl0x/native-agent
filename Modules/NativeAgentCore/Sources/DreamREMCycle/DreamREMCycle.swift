import Foundation
import Experiences
import Darwin
import NativeAgentCore
import PersistenceCore
import ProviderRouting
import TrustCenter

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
public struct DreamEntry: Sendable, Codable, Equatable, Identifiable {
    public var date: String
    public var filename: String?
    public var content: String?
    public var size: Int?
    public var modifiedAt: String?
    public var extras: JSONValue?

    /// One entry per night.
    public var id: String { date }

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
    public var reflectionMaterial: [String: CognitiveReflectionCause] = [:]
    public init(rawResponse: JSONValue, reflectionMaterial: [String: CognitiveReflectionCause] = [:]) {
        self.rawResponse = rawResponse
        self.reflectionMaterial = reflectionMaterial
    }

    enum CodingKeys: String, CodingKey { case rawResponse = "raw_response" }
}

/// Result of POST /v1/rem/run. Daemon body shape is whatever
/// `_rem_cycle.run_now(force:)` returns; preserve verbatim.
public struct REMRunResult: Sendable, Codable, Equatable {
    public var rawResponse: JSONValue
    public var reflectionMaterial: [String: CognitiveReflectionCause] = [:]
    public init(rawResponse: JSONValue, reflectionMaterial: [String: CognitiveReflectionCause] = [:]) {
        self.rawResponse = rawResponse
        self.reflectionMaterial = reflectionMaterial
    }

    enum CodingKeys: String, CodingKey { case rawResponse = "raw_response" }
}

// MARK: - Errors

public enum DreamREMCycleError: Error, LocalizedError {
    case underlying(String)
    case remDecodeFailure(String)
    /// WAVE 35 W15: the cycle's gate is off. Mirrors the daemon POST routes'
    /// 403 (`dream_cycle_disabled` / `rem_cycle_disabled`,
    /// the retired daemon). `detail` carries the SAME message the
    /// daemon would have returned so a Swift pre-check is indistinguishable
    /// from the server's own refusal.
    case cycleDisabled(error: String, detail: String)

    public var errorDescription: String? {
        switch self {
        case .underlying(let m), .remDecodeFailure(let m): return "dream/rem: \(m)"
        case .cycleDisabled(_, let detail): return "dream/rem: \(detail)"
        }
    }
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
//   2. THE SCHEDULE — shared local-clock times and diary date keys. The
//      scheduler owns the next run; nightly dreams use the previous local day.
//
// The cycle body is Swift too: DreamCycleRunner owns dream synthesis and
// dream_diary writes; REMConsolidator owns weekly REM distillation, proposal
// staging, GROWTH.md cap/eviction, and archival.

/// The two gates the dream/REM cycle consults, in the legacy policy shape.
/// Construct from the Trust policy the Swift app already decodes
/// (`TrustTrainingPolicy` + `personalityPolicy.dream_cycle_enabled`). Defaults
/// preserve the pre-cutover behavior for older policy files.
public struct DreamREMGatePolicy: Sendable, Equatable {
    /// `trainingPolicy.dream_scheduler` — default TRUE, matching the shipped
    /// `defaultTrustPolicy()` (TrustCenter+Defaults). It was false here, so a
    /// fresh policy.json — which carries no `trainingPolicy` block at all —
    /// never dreamt, while the Trust Center showed the toggle on.
    public var dreamScheduler: Bool
    /// `personalityPolicy.dream_cycle_enabled` — default true.
    public var dreamCycleEnabled: Bool
    /// `trainingPolicy.rem_cycle_enabled` — default true.
    public var remCycleEnabled: Bool

    public init(
        dreamScheduler: Bool = true,
        dreamCycleEnabled: Bool = true,
        remCycleEnabled: Bool = true
    ) {
        self.dreamScheduler = dreamScheduler
        self.dreamCycleEnabled = dreamCycleEnabled
        self.remCycleEnabled = remCycleEnabled
    }

    /// Every switch off. The projection for authority we hold but cannot
    /// trust — never for a fresh root, which has no authority to damage.
    static let damagedAuthority = DreamREMGatePolicy(
        dreamScheduler: false,
        dreamCycleEnabled: false,
        remCycleEnabled: false
    )

    /// The ONE gate-from-disk predicate for this module (DreamCycleRunner uses
    /// it too), mirroring `SwiftNativeTrustCenter.loadRawPolicyChecked` without
    /// the module edge to TrustCenter.
    ///
    /// A genuinely absent path — no directory entry at all — is the only
    /// bootstrap case, and gets the shipped defaults (User: "defaults everything
    /// on"). Everything else is authority we are holding: a dangling symlink
    /// (`lstat` sees the LINK, so the entry is PRESENT and unreadable), bytes
    /// that will not parse, and bytes that parse into the wrong types — such as
    /// `{"trainingPolicy": false}` or `{"dream_scheduler": "false"}` — all fail
    /// closed rather than passing as "field not configured".
    static func fromSavedAuthority(dataRoot: URL) -> DreamREMGatePolicy {
        // The lstat / parse / whole-policy-shape half is the ONE shared
        // predicate in PersistenceCore (2026-09-13), so this gate, the memory
        // and multimodal gates and TrustCenter's own canonical read agree on
        // what "absent" and "damaged" mean. Only the per-field reading below
        // is this module's.
        let root: [String: JSONValue]
        switch SavedTrustPolicyAuthority.read(dataRoot: dataRoot) {
        case .absent:
            return DreamREMGatePolicy()
        case .damaged:
            return .damagedAuthority
        case .present(let object):
            root = object
        }
        var damaged = false
        // A block that is present must be an object; absent is unconfigured.
        func object(_ key: String) -> [String: JSONValue] {
            guard let value = root[key] else { return [:] }
            guard case .object(let obj) = value else {
                damaged = true
                return [:]
            }
            return obj
        }
        // A key that is present must be a boolean; absent takes the shipped
        // default, which is `true` for all three of these.
        func flag(_ section: [String: JSONValue], _ key: String) -> Bool {
            guard let value = section[key] else { return true }
            guard case .bool(let b) = value else {
                damaged = true
                return false
            }
            return b
        }
        let training = object("trainingPolicy")
        let personality = object("personalityPolicy")
        let resolved = DreamREMGatePolicy(
            dreamScheduler: flag(training, "dream_scheduler"),
            dreamCycleEnabled: flag(personality, "dream_cycle_enabled"),
            remCycleEnabled: flag(training, "rem_cycle_enabled")
        )
        return damaged ? .damagedAuthority : resolved
    }

    /// Dream cycle runs only when both the scheduler and personality gates are on.
    public var dreamEnabled: Bool { dreamScheduler && dreamCycleEnabled }

    /// REM consolidation uses one default-on gate.
    public var remEnabled: Bool { remCycleEnabled }

    /// User-facing details returned when a Swift pre-check blocks a run.
    public static let dreamDisabledDetail =
        "Enable the Dream cycle toggle in Dreams to run a dream cycle."
    public static let remDisabledDetail =
        "Enable the REM cycle toggle in Dreams to run REM consolidation."
}

/// Shared schedule values for the dream + REM loops. NO LLM, NO I/O.
/// Nightly dreams run at 03:30 on the MACHINE's own clock and write the
/// previous local calendar day's diary key.
public enum DreamREMSchedule {
    /// Dream loop fire time.
    public static let dreamHour = 3
    public static let dreamMinute = 30

    /// REM loop fire time. SINGLE SOURCE OF TRUTH — the App-side scheduler
    /// (NativeAgentDreamCycleSchedule) forwards to these; do not duplicate the
    /// literals there.
    public static let remHour = 4
    public static let remMinute = 30

    public static func localCalendar() -> Calendar {
        var cal = Calendar(identifier: .gregorian)
        cal.timeZone = .current
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

    /// Nightly dream file stem. A 03:30 local run on June 17 writes the
    /// June 16 diary entry because the dream reflects the previous day.
    public static func dreamEntryDateKey(
        now: Date = Date(),
        calendar: Calendar = localCalendar()
    ) -> String {
        let previous = calendar.date(byAdding: .day, value: -1, to: now) ?? now.addingTimeInterval(-86_400)
        return todayKey(now: previous, calendar: calendar)
    }
}

// MARK: - FileBackedDreamDiary

/// File-backed diary listing and by-date reads, including archived entries.
/// No LLM, scheduler or persona is needed to read a dream.
/// Markdown under dream_diary (including archive): backed up, excluded from
/// production export and phone sync; PrivacyMap: dream_diary.
///
/// Browsing sorts all Markdown by filename descending, carries the full stem
/// as `DreamEntry.date`, and includes archives. REM uses the discovered day
/// prefix; theme cues select exact nightly filenames. By-date reads omit mtime.
public struct FileBackedDreamDiary: Sendable {
    private let diaryDir: URL
    // `FileManager` is not Sendable, so we use `FileManager.default` inline
    // (it's safe for the read-only stat/read calls we make) rather than storing
    // it on a Sendable struct.
    private var fm: FileManager { .default }

    public init(dataRoot: URL) {
        self.diaryDir = dataRoot.appendingPathComponent("dream_diary", isDirectory: true)
    }

    public enum Location: Sendable { case active, includingArchives }
    public enum Filenames: Sendable { case markdown, dated, nightly }

    public struct DiaryFile: Sendable {
        public let name: String
        public let url: URL
        /// Calendar-day prefix, including session-suffixed entries; nil for other Markdown.
        public let day: String?
        public var stem: String { (name as NSString).deletingPathExtension }
    }

    private static let dateStemRegex = try! NSRegularExpression(pattern: "^(\\d{4}-\\d{2}-\\d{2})(?:_.+)?$")

    private static func day(from stem: String) -> String? {
        guard let match = dateStemRegex.firstMatch(in: stem, range: NSRange(stem.startIndex..., in: stem)),
              let range = Range(match.range(at: 1), in: stem) else { return nil }
        return String(stem[range])
    }

    /// Discovery only: callers choose active/history coverage and filename policy.
    /// A date window uses local calendar days, like weekly REM.
    public func discover(
        in location: Location, matching filenames: Filenames,
        since: Date? = nil
    ) throws -> [DiaryFile] {
        var failure: (any Error)?
        let files = diaryFiles(in: location, matching: filenames) { _, error in
            if (error as? CocoaError)?.code != .fileReadNoSuchFile { failure = error }
        }
        if let failure { throw failure }
        return files.filter { file in
            guard let since else { return true }
            guard let day = file.day, let date = Self.localDate(from: day) else { return false }
            return date >= DreamREMSchedule.localCalendar().startOfDay(for: since)
        }
    }

    private static func localDate(from day: String) -> Date? {
        let parts = day.split(separator: "-")
        guard parts.count == 3,
              let year = Int(parts[0]), let month = Int(parts[1]), let day = Int(parts[2]) else { return nil }
        return DreamREMSchedule.localCalendar().date(from: DateComponents(year: year, month: month, day: day))
    }

    private func diaryFiles(
        in location: Location, matching filenames: Filenames,
        onFailure: (URL, any Error) -> Void
    ) -> [DiaryFile] {
        var found: [DiaryFile] = []
        // A directory that EXISTS but cannot be listed is a read failure, not
        // an empty diary. A directory that is simply absent is the empty case.
        func names(in directory: URL) -> [String] {
            do { return try fm.contentsOfDirectory(atPath: directory.path) } catch {
                onFailure(directory, error)
                return []
            }
        }
        func collect(in directory: URL) {
            for name in names(in: directory) {
                guard (filenames == .dated ? name.lowercased() : name).hasSuffix(".md") else { continue }
                let stem = (name as NSString).deletingPathExtension
                let day = Self.day(from: stem)
                if filenames == .dated && day == nil { continue }
                if filenames == .nightly && (day == nil || day != stem) { continue }
                found.append(DiaryFile(name: name, url: directory.appendingPathComponent(name), day: day))
            }
        }
        collect(in: diaryDir)
        if location == .includingArchives {
            let archive = diaryDir.appendingPathComponent("archive", isDirectory: true)
            for year in names(in: archive) {
                collect(in: archive.appendingPathComponent(year, isDirectory: true))
            }
        }
        return found
    }

    /// A listing that says what it could NOT read. `listEntries` returns the
    /// entries alone, so "no dreams" and "the diary could not be read" arrived
    /// at the caller identically — and the agent told her she had never dreamt.
    public struct DiaryListing: Sendable {
        public let entries: [DreamEntry]
        public let totalEntries: Int
        /// The diary (or an archive year) is there and could not be listed.
        public let storageUnreadable: Bool
        /// Files that were listed but could not be read or stat'ed this pass.
        public let failures: [String: String]
        public var unreadableEntries: Int { failures.count }

        public var isComplete: Bool { !storageUnreadable && unreadableEntries == 0 }
    }

    public func listEntries(limit: Int) -> [DreamEntry] {
        listEntriesChecked(limit: limit).entries
    }

    /// The same listing, with what it could not read carried out alongside it.
    public func listEntriesChecked(limit: Int) -> DiaryListing {
        let clamped = max(1, limit)
        var unreadableDirectory = false
        let discovered = diaryFiles(in: .includingArchives, matching: .markdown) { directory, _ in
            if fm.fileExists(atPath: directory.path) { unreadableDirectory = true }
        }
        // Filename DESCENDING == Python sorted(reverse=True); the archived
        // files carry the same `YYYY-MM-DD` stems, so one sort still orders
        // the merged diary newest-first.
        let files = discovered
            .sorted { $0.name > $1.name }
            .prefix(clamped)
        let isoOut = ISO8601DateFormatter()
        isoOut.formatOptions = [.withInternetDateTime]
        var out: [DreamEntry] = []
        var failures: [String: String] = [:]
        for file in files {
            let (name, url) = (file.name, file.url)
            do {
            let text = try String(contentsOf: url, encoding: .utf8)
            let attrs = try fm.attributesOfItem(atPath: url.path)
            guard let size = (attrs[.size] as? NSNumber)?.intValue,
                  let mtime = attrs[.modificationDate] as? Date else {
                throw CocoaError(.fileReadUnknown)
            }
            out.append(DreamEntry(
                date: file.stem,
                filename: name,
                content: text,
                size: size,
                modifiedAt: isoOut.string(from: mtime)
            ))
            } catch { failures[url.path] = error.localizedDescription }
        }
        return DiaryListing(
            entries: out, totalEntries: discovered.count,
            storageUnreadable: unreadableDirectory, failures: failures)
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
        var url = diaryDir.appendingPathComponent("\(trimmed).md")
        // Belt-and-suspenders: confirm the resolved file stays inside diaryDir.
        let resolvedDir = diaryDir.standardizedFileURL.resolvingSymlinksInPath().path
        let resolvedFile = url.standardizedFileURL.resolvingSymlinksInPath().path
        let dirPrefix = resolvedDir.hasSuffix("/") ? resolvedDir : resolvedDir + "/"
        guard resolvedFile.hasPrefix(dirPrefix) else { return .badPath }

        // Not in the top directory: weekly REM may have moved it to
        // `archive/<year>/`. Same stem, same containment rules — the date key
        // has already been proven to carry no separators.
        if !fm.fileExists(atPath: url.path) {
            let archived = diaryDir.appendingPathComponent("archive", isDirectory: true)
                .appendingPathComponent(String(trimmed.prefix(4)), isDirectory: true)
                .appendingPathComponent("\(trimmed).md")
            guard fm.fileExists(atPath: archived.path) else { return .notFound }
            guard archived.standardizedFileURL.resolvingSymlinksInPath().path.hasPrefix(dirPrefix) else {
                return .badPath
            }
            url = archived
        }
        // A read/stat failure on an EXISTING file is a real error, not a "not
        // found" — throw so it isn't silently swallowed (Python lets it raise).
        let text = try String(contentsOf: url, encoding: .utf8)
        let attrs = try fm.attributesOfItem(atPath: url.path)
        let size = (attrs[.size] as? NSNumber)?.intValue ?? 0
        return .entry(DreamEntry(date: trimmed, filename: url.lastPathComponent, content: text, size: size))
    }

    /// Convenience: nil for badPath/notFound, the entry otherwise. Read errors
    /// still propagate.
    public func getEntry(_ dateKey: String) throws -> DreamEntry? {
        switch try getEntryResult(dateKey) {
        case .badPath, .notFound: return nil
        case .entry(let e): return e
        }
    }
}

// MARK: - SwiftNative cycle runners

/// Native dream/REM runners with the same gate for prechecks and execution.
public actor SwiftNativeDreamREMCycle {
    private let dataRoot: URL
    private let dreamRunner: DreamCycleRunner
    private let remConsolidator: REMConsolidator
    private let gate: DreamREMGatePolicy

    public init(
        dataRoot: URL,
        gate: DreamREMGatePolicy? = nil,
        dreamMemoryDeltaProvider: DreamMemoryDeltaProvider? = nil,
        dreamFeltSummaryProvider: DreamFeltSummaryProvider? = nil,
        dreamFeltOriginProvider: DreamFeltOriginProvider? = nil,
        dreamReceiptSink: DreamReceiptSink? = nil,
        dreamMoodSink: DreamDatedMoodSink? = nil,
        remStageApproval: REMApprovalStager? = nil,
        lifecycleObserver: (any LLMCallLifecycleObserving)? = nil
    ) {
        self.dataRoot = dataRoot
        let effectiveGate = gate ?? Self.loadGatePolicy(dataRoot: dataRoot)
        self.gate = effectiveGate
        let llm = Self.makeDefaultLLMClient(lifecycleObserver: lifecycleObserver)
        let personaRoot = PersistenceCore.defaultPersonaRoot(dataRoot: dataRoot)
        // Both scheduler and manual paths carry memory, felt tone and the
        // returning mood through these same runners.
        self.dreamRunner = DreamCycleRunner(
            dataRoot: dataRoot,
            personaRoot: personaRoot,
            llm: llm,
            memoryDeltaProvider: dreamMemoryDeltaProvider ?? { _ in [] },
            feltSummaryProvider: dreamFeltSummaryProvider ?? { nil },
            feltOriginProvider: dreamFeltOriginProvider ?? { [] },
            receiptSink: dreamReceiptSink ?? { _, _ in },
            datedMoodSink: dreamMoodSink ?? { _, _ in true },
            gate: effectiveGate
        )
        // The app wires the same approval stager for manual and scheduled REM.
        self.remConsolidator = REMConsolidator(
            dataRoot: dataRoot,
            personaRoot: personaRoot,
            llm: llm,
            gate: effectiveGate,
            stageApproval: remStageApproval
        )
    }

    /// The single dream path, with the waking lane named. A manual pass calls
    /// it with `.manual`. Same gate, same
    /// runner, same dedupe — only the receipt and the target day differ.
    public func runDream(force: Bool, trigger: DreamTrigger) async throws -> DreamRunResult {
        // WAVE 35 W15: pure-compute pre-check mirrors the retired daemon
        // (the POST route 403s when `_dream_cycle.is_enabled()` is false). The
        // `force` flag re-runs even if the target entry exists — it does NOT
        // bypass the gate (the daemon checks the gate BEFORE reading `force`),
        // so we don't let it bypass here either.
        if !gate.dreamEnabled {
            throw DreamREMCycleError.cycleDisabled(
                error: "dream_cycle_disabled",
                detail: DreamREMGatePolicy.dreamDisabledDetail
            )
        }
        let report: DreamReport
        do {
            report = try await dreamRunner.runNightlyDreamCycle(force: force, trigger: trigger)
        } catch {
            await RepairOwed.owe(dataRoot, id: "dream-repair:" + UUID().uuidString, kind: .run,
                operation: "dream", owner: "dream cycle", words: error.localizedDescription,
                nextCall: ToolFailureError.call("app", ["action": .string("mind.dream")])).value
            throw error
        }
        if !report.errors.isEmpty {
            let fields: [String: JSONValue] = if case .object(let fields)? = report.repair { fields } else { [:] }
            let owner: String = if case .string(let owner)? = fields["owner"] { owner } else { "dream cycle" }
            let tap: String? = if case .string(let tap)? = fields["tap"] { tap } else { nil }
            await RepairOwed.owe(dataRoot, id: "dream-repair:" + UUID().uuidString, kind: .run,
                operation: "dream", owner: owner, words: report.errors.joined(separator: "\n"),
                nextCall: tap == nil ? ToolFailureError.call("app", ["action": .string("mind.dream")]) : nil,
                tap: tap).value
        } else if report.entriesWritten > 0 {
            await RepairOwed.settle(dataRoot, operation: "dream",
                evidence: .init(source: "dream_diary", id: NativeTimestampFormat.fractionalZulu(Date()))).value
        }
        var response: [String: JSONValue] = [
            "ok": .bool(report.errors.isEmpty),
            "backend": .string("swift"),
            "force": .bool(force),
            "trigger": .string(report.trigger.rawValue),
            "sessionsProcessed": .int(Int64(report.sessionsProcessed)),
            "entriesWritten": .int(Int64(report.entriesWritten)),
            "disabled": .bool(report.disabled),
            "errors": .array(report.errors.map { .string($0) }),
        ]
        if let skipReason = report.skipReason {
            response["skipReason"] = .string(skipReason)
        }
        if !report.errors.isEmpty {
            response["remedy"] = report.repair ?? Repair.remedy(owner: "dream cycle",
                nextCall: .object(["tool": .string("app"), "input": .object(["action": .string("mind.dream")])]), tap: nil)
        }
        return DreamRunResult(rawResponse: .object(response), reflectionMaterial: report.reflectionMaterial)
    }

    public func repairREM() async throws -> Int {
        try await remConsolidator.repairPendingWork()
    }

    public func runREM(force: Bool) async throws -> REMRunResult {
        // WAVE 35 W15: pure-compute pre-check mirrors the retired daemon
        // (the POST route 403s when `_rem_cycle.is_enabled()` is false). As
        // with dream, `force` does not bypass the gate.
        if !gate.remEnabled {
            throw DreamREMCycleError.cycleDisabled(
                error: "rem_cycle_disabled",
                detail: DreamREMGatePolicy.remDisabledDetail
            )
        }
        // Manual runs (force) bypass the weekly idempotency marker —
        // without this, /v1/rem/run within 6 days of the scheduled pass
        // silently no-oped (gpt-5.5 review 2026-06-09).
        let report = try await remConsolidator.runWeeklyREM(force: force)
        var response: [String: JSONValue] = [
            "ok": .bool(true),
            "backend": .string("swift"),
            "force": .bool(force),
            "proposalsGenerated": .int(Int64(report.proposalsGenerated)),
            "evidenceDatesMin": .int(Int64(report.evidenceDatesMin)),
            "tombstoneSkips": .int(Int64(report.tombstoneSkips)),
            "growthMDEvicted": .int(Int64(report.growthMDEvicted)),
            "archivedEntries": .int(Int64(report.archivedEntries)),
        ]
        // 2026-09-06: carry the skip reason out, the way the dream path does.
        // A pass that lost the run reservation reports zero of everything, and
        // without this the caller cannot tell it from a quiet week.
        if let skipReason = report.skipReason {
            response["skipReason"] = .string(skipReason)
        }
        return REMRunResult(rawResponse: .object(response), reflectionMaterial: report.reflectionMaterial)
    }

    private nonisolated static func makeDefaultLLMClient(
        lifecycleObserver: (any LLMCallLifecycleObserving)?
    ) -> any LLMClient {
        let router = SwiftNativeProviderRouting()
        return SwiftNativeLLMClient(
            router: router,
            codex: CodexAdapter(),
            anthropic: AnthropicAdapter(session: ProviderStreamGuard.stallOnlySession),
            openAI: OpenAIAdapter(session: ProviderStreamGuard.stallOnlySession),
            openAIOAuthDirect: OpenAIOAuthDirectAdapter(session: ProviderStreamGuard.stallOnlySession),
            anthropicOAuthDirect: AnthropicOAuthDirectAdapter(session: ProviderStreamGuard.stallOnlySession),
            xaiOAuthDirect: XAIOAuthDirectAdapter(session: ProviderStreamGuard.stallOnlySession),
            moonshot: MoonshotAdapter(session: ProviderStreamGuard.stallOnlySession),
            kimiCode: AnthropicAdapter.kimiCode(session: ProviderStreamGuard.stallOnlySession),
            openRouter: OpenRouterAdapter(session: ProviderStreamGuard.stallOnlySession),
            lifecycleObserver: lifecycleObserver
        )
    }

    private nonisolated static func loadGatePolicy(dataRoot: URL) -> DreamREMGatePolicy {
        DreamREMGatePolicy.fromSavedAuthority(dataRoot: dataRoot)
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
public func makeDreamREMCycle(
    root: URL = PersistenceCore.defaultDataRoot(),
    gate: DreamREMGatePolicy? = nil,
    remStageApproval: REMApprovalStager? = nil,
    dreamMoodSink: DreamDatedMoodSink? = nil,
    lifecycleObserver: (any LLMCallLifecycleObserving)? = nil
) -> SwiftNativeDreamREMCycle {
    return SwiftNativeDreamREMCycle(
        dataRoot: root, gate: gate,
        dreamMoodSink: dreamMoodSink, remStageApproval: remStageApproval,
        lifecycleObserver: lifecycleObserver)
}
import CognitiveSubstrate
// Blueprint: | `DreamREMCycle.swift` | `FileBackedDreamDiary`: typed active/archive discovery, filename/day extraction, checked browsing and by-date reads |
