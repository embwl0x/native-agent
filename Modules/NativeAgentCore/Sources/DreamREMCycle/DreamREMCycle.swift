import Foundation
import NativeAgentShared
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

/// Dream diary wire keys are `date`, `filename`, `content`, `size` and `modified_at`; unknown fields ride in `extras`.
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

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: JSONKey.self)
        func str(_ k: String) throws -> String? {
            return try c.decodeIfPresent(String.self, forKey: JSONKey(k))
        }
        func intV(_ k: String) throws -> Int? {
            return try c.decodeIfPresent(Int.self, forKey: JSONKey(k))
        }
        func jv(_ k: String) throws -> JSONValue? {
            return try c.decodeIfPresent(JSONValue.self, forKey: JSONKey(k))
        }

        self.date = (try str("date")) ?? ""
        self.filename = try str("filename")
        self.content = try str("content")
        self.size = try intV("size")
        // Prefer snake_case `modified_at` while accepting camelCase input.
        let modAtSnake = try str("modified_at")
        let modAtCamel = try str("modifiedAt")
        self.modifiedAt = modAtSnake ?? modAtCamel

        var unknown = c.unknownFields(excluding: Self.knownKeys)
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
        var c = encoder.container(keyedBy: JSONKey.self)
        try c.encode(date, forKey: JSONKey("date"))
        try c.encodeIfPresent(filename, forKey: JSONKey("filename"))
        try c.encodeIfPresent(content, forKey: JSONKey("content"))
        try c.encodeIfPresent(size, forKey: JSONKey("size"))
        try c.encodeIfPresent(modifiedAt, forKey: JSONKey("modified_at"))
        try c.encodeUnknownFields(extras, excluding: Self.knownKeys)
    }
}

// MARK: - Errors

public enum DreamREMCycleError: Error, LocalizedError {
    case underlying(String)
    case remDecodeFailure(String)
    case oversizedConversationInput
    /// A disabled cycle carries its stable error identifier and refusal detail.
    case cycleDisabled(error: String, detail: String)

    public var errorDescription: String? {
        switch self {
        case .oversizedConversationInput:
            return "dream/rem: oversized_conversation_input — no complete exchange fits the dream input budget; the watermark was preserved."
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
    /// `trainingPolicy.dream_scheduler` — shipped default true.
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

    /// All three flags come from the same validated authority snapshot.
    public init(authority: SavedTrustPolicyAuthority) {
        self.init(
            dreamScheduler: authority.flag(block: "trainingPolicy", key: "dream_scheduler", default: true),
            dreamCycleEnabled: authority.flag(block: "personalityPolicy", key: "dream_cycle_enabled", default: true),
            remCycleEnabled: authority.flag(block: "trainingPolicy", key: "rem_cycle_enabled", default: true)
        )
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

    private static func day(from stem: String) -> String? {
        guard stem.range(of: #"^\d{4}-\d{2}-\d{2}(?:_.+)?$"#, options: .regularExpression) != nil else { return nil }
        return String(stem.prefix(10))
    }

    /// Discovery only: callers choose active/history coverage and filename policy.
    /// A date window uses local calendar days, like weekly REM.
    public func discover(
        in location: Location, matching filenames: Filenames,
        since: Date? = nil
    ) throws -> [DiaryFile] {
        var failure: (any Error)?
        let discovery = diaryFiles(in: location, matching: filenames) { _, error in
            if (error as? CocoaError)?.code != .fileReadNoSuchFile { failure = error }
        }
        if let failure { throw failure }
        return discovery.files.filter { file in
            guard let since else { return true }
            guard let day = file.day, let date = Self.localDate(from: day) else { return false }
            return date >= DreamREMSchedule.localCalendar().startOfDay(for: since)
        }
    }

    /// Read and stat once; callers decide whether missing metadata is acceptable.
    private func materialize(_ file: DiaryFile, date: String) throws -> DreamEntry {
        let text = try String(contentsOf: file.url, encoding: .utf8)
        let attrs = try fm.attributesOfItem(atPath: file.url.path)
        return DreamEntry(date: date, filename: file.name, content: text,
            size: (attrs[.size] as? NSNumber)?.intValue,
            modifiedAt: (attrs[.modificationDate] as? Date).map { ISO8601DateFormatter().string(from: $0) })
    }

    /// REM reads active dated entries, oldest first, with the day prefix as identity.
    public func entriesSince(_ since: Date?) throws -> [DreamEntry] {
        try discover(in: .active, matching: .dated, since: since).map { file in
            var entry = try materialize(file, date: file.day!)
            entry.size = entry.size ?? (try? Data(contentsOf: file.url))?.count ?? 0
            entry.modifiedAt = entry.modifiedAt ?? ISO8601DateFormatter().string(from: Date())
            return entry
        }.sorted {
            $0.date == $1.date ? ($0.filename ?? "") < ($1.filename ?? "") : $0.date < $1.date
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
    ) -> (files: [DiaryFile], storage: String) {
        var found: [DiaryFile] = []
        var storage = "readable"
        // A directory that EXISTS but cannot be listed is a read failure, not
        // an empty diary. A directory that is simply absent is the empty case.
        func names(in directory: URL) -> [String] {
            do { return try fm.contentsOfDirectory(atPath: directory.path) } catch {
                if directory == diaryDir {
                    var isDirectory: ObjCBool = false
                    storage = fm.fileExists(atPath: directory.path, isDirectory: &isDirectory)
                        && isDirectory.boolValue ? "unreadable" : "missing"
                }
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
        return (found, storage)
    }

    /// A listing that distinguishes no dreams from an unreadable diary.
    public struct DiaryListing: Sendable {
        public let entries: [DreamEntry]
        public let totalEntries: Int
        public let storage: String
        public let activeFilenames: Set<String>
        /// The diary (or an archive year) is there and could not be listed.
        public let storageUnreadable: Bool
        /// Files that were listed but could not be read or stat'ed this pass.
        public let failures: [String: String]
        public var unreadableEntries: Int { failures.count }

        public var isComplete: Bool { !storageUnreadable && unreadableEntries == 0 }
    }

    /// The same listing, with what it could not read carried out alongside it.
    public func listEntriesChecked(limit: Int) -> DiaryListing {
        let clamped = max(1, limit)
        var unreadableDirectory = false
        let discovered = diaryFiles(in: .includingArchives, matching: .markdown) { directory, _ in
            if fm.fileExists(atPath: directory.path) { unreadableDirectory = true }
        }
        // One filename sort orders the merged diary newest-first.
        let files = discovered.files
            .sorted { $0.name > $1.name }
            .prefix(clamped)
        var out: [DreamEntry] = []
        var failures: [String: String] = [:]
        for file in files {
            do {
                let entry = try materialize(file, date: file.stem)
                guard entry.size != nil, entry.modifiedAt != nil else { throw CocoaError(.fileReadUnknown) }
                out.append(entry)
            } catch { failures[file.url.path] = error.localizedDescription }
        }
        return DiaryListing(
            entries: out, totalEntries: discovered.files.count,
            storage: discovered.storage,
            activeFilenames: Set(discovered.files.filter { $0.url.deletingLastPathComponent() == diaryDir }.map(\.name)),
            storageUnreadable: unreadableDirectory, failures: failures)
    }

    /// Invalid keys and absent files are distinct; read/stat failures throw.
    public enum ByDateResult: Sendable, Equatable {
        case badPath(storage: String)
        case notFound(storage: String)
        case entry(DreamEntry, archived: Bool)
    }

    /// Read an active or archived entry by stem, omitting modification time.
    public func getEntryResult(_ dateKey: String) throws -> ByDateResult {
        func storage() -> String {
            diaryFiles(in: .active, matching: .markdown) { _, _ in }.storage
        }
        let trimmed = dateKey.trimmingCharacters(in: .whitespaces)
        // A key is one path segment, confined to the diary and outside reserved names.
        if trimmed.isEmpty { return .badPath(storage: storage()) }
        if ["diary", "today", "run"].contains(trimmed) { return .badPath(storage: storage()) }
        if trimmed.contains("/") || trimmed.contains("\\")
            || trimmed.contains("\0") || trimmed == "." || trimmed == ".."
            || trimmed.contains("..") {
            return .badPath(storage: storage())
        }
        var url = diaryDir.appendingPathComponent("\(trimmed).md")
        // Both active and archived entries must stay strictly inside the diary.
        let resolvedDir = diaryDir.standardizedFileURL.resolvingSymlinksInPath().path
        let resolvedFile = url.standardizedFileURL.resolvingSymlinksInPath().path
        guard let tail = NativeAgentWorkspaceRoot.relativePath(resolvedFile, under: resolvedDir), !tail.isEmpty else { return .badPath(storage: storage()) }

        // Not in the top directory: weekly REM may have moved it to
        // `archive/<year>/`. Same stem, same containment rules — the date key
        // has already been proven to carry no separators.
        if !fm.fileExists(atPath: url.path) {
            let archived = diaryDir.appendingPathComponent("archive", isDirectory: true)
                .appendingPathComponent(String(trimmed.prefix(4)), isDirectory: true)
                .appendingPathComponent("\(trimmed).md")
            guard fm.fileExists(atPath: archived.path) else { return .notFound(storage: storage()) }
            guard let tail = NativeAgentWorkspaceRoot.relativePath(archived.standardizedFileURL.resolvingSymlinksInPath().path, under: resolvedDir), !tail.isEmpty else {
                return .badPath(storage: storage())
            }
            url = archived
        }
        var entry = try materialize(DiaryFile(name: url.lastPathComponent, url: url, day: nil), date: trimmed)
        entry.size = entry.size ?? 0
        entry.modifiedAt = nil
        return .entry(entry, archived: url.deletingLastPathComponent() != diaryDir)
    }

    /// Convenience: nil for badPath/notFound, the entry otherwise. Read errors
    /// still propagate.
    public func getEntry(_ dateKey: String) throws -> DreamEntry? {
        switch try getEntryResult(dateKey) {
        case .badPath, .notFound: return nil
        case .entry(let e, _): return e
        }
    }
}

// MARK: - SwiftNative cycle runners

/// Native dream/REM runners own policy admission; the facade preserves public errors.
public actor SwiftNativeDreamREMCycle {
    private let dataRoot: URL
    private let dreamRunner: DreamCycleRunner
    private let remConsolidator: REMConsolidator

    public init(
        dataRoot: URL,
        gate: DreamREMGatePolicy? = nil,
        dreamMemoryDeltaProvider: DreamMemoryDeltaProvider? = nil,
        dreamFeltSummaryProvider: DreamFeltSummaryProvider? = nil,
        dreamFeltOriginProvider: DreamFeltOriginProvider? = nil,
        dreamCareNightProvider: DreamCareNightProvider? = nil,
        dreamReceiptSink: DreamReceiptSink? = nil,
        dreamMoodSink: DreamDatedMoodSink? = nil,
        remStageApproval: REMApprovalStager? = nil,
        lifecycleObserver: (any LLMCallLifecycleObserving)? = nil
    ) {
        self.dataRoot = dataRoot
        let effectiveGate = gate ?? DreamREMGatePolicy(authority: .read(dataRoot: dataRoot))
        let llm = makeResidentProviderLLMClient(
            dataRoot: dataRoot, lifecycleObserver: lifecycleObserver, stallOnlyTransport: true)
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
            careNightProvider: dreamCareNightProvider ?? { nil },
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

    /// Manual and scheduled dreams share one gate, runner and dedupe; the trigger selects receipt and target day.
    public func runDream(force: Bool, trigger: DreamTrigger) async throws -> DreamReport {
        try requireLiveProviders()
        let report: DreamReport
        do {
            report = try await dreamRunner.runNightlyDreamCycle(force: force, trigger: trigger)
        } catch {
            await RepairOwed.owe(dataRoot, id: "dream-repair:" + UUID().uuidString, kind: .run,
                operation: "dream", owner: "dream cycle", words: error.localizedDescription,
                nextCall: ToolFailureError.call("app", ["action": .string("mind.dream")])).value
            throw error
        }
        if report.disabled {
            throw DreamREMCycleError.cycleDisabled(
                error: "dream_cycle_disabled",
                detail: DreamREMGatePolicy.dreamDisabledDetail
            )
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
        return report
    }

    public func repairREM() async throws -> Int {
        try await remConsolidator.repairPendingWork()
    }

    public func runREM(force: Bool) async throws -> REMReport {
        try requireLiveProviders()
        // Force bypasses the weekly marker, never the owner's policy gate.
        return try await remConsolidator.runWeeklyREM(force: force)
    }

    private func requireLiveProviders() throws {
        guard dataRoot.standardizedFileURL == PersistenceCore.defaultDataRoot().standardizedFileURL else {
            throw DreamREMCycleError.underlying("background providers are unavailable for an alternate data root")
        }
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
