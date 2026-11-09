import Foundation
import NativeAgentShared
import Experiences
import Darwin
import NativeAgentCore
import PersistenceCore
import ProviderRouting
import TrustCenter

// MARK: - Subsystem #10: DreamREMCycle

// MARK: - DreamEntry

/// Round-trip unknown diary fields through extras while keeping canonical wire keys.
public struct DreamEntry: Sendable, Codable, Equatable, Identifiable {
    public var date: String
    public var filename: String?
    public var content: String?
    public var size: Int?
    public var modifiedAt: String?
    public var extras: JSONValue?

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
        "date", "filename", "content", "size", "modified_at", "extras",
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
        self.modifiedAt = try str("modified_at")

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
    /// Keep a stable disabled-cycle identifier with its refusal detail.
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
// Keep gates and schedule projection pure so callers can explain refusal before any cycle work.
// The scheduler owns timing; runners own synthesis, staging, growth eviction and archival.

/// Use one checked saved authority snapshot; defaults apply only to genuinely absent policy fields.
public struct DreamREMGatePolicy: Sendable, Equatable {
    /// The scheduler gate ships enabled.
    public var dreamScheduler: Bool
    /// The personality dream gate defaults enabled.
    public var dreamCycleEnabled: Bool
    /// The REM gate defaults enabled.
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

    /// Resolve all flags from the same validated authority snapshot.
    public init(policy: [String: JSONValue]) throws {
        try self.init(
            dreamScheduler: SwiftNativeTrustCenter.policyFlag(policy, block: "trainingPolicy", key: "dream_scheduler", default: true),
            dreamCycleEnabled: SwiftNativeTrustCenter.policyFlag(policy, block: "personalityPolicy", key: "dream_cycle_enabled", default: true),
            remCycleEnabled: SwiftNativeTrustCenter.policyFlag(policy, block: "trainingPolicy", key: "rem_cycle_enabled", default: true)
        )
    }

    /// Require both scheduler and personality authority for dream execution.
    public var dreamEnabled: Bool { dreamScheduler && dreamCycleEnabled }

    public var remEnabled: Bool { remCycleEnabled }

    public static let dreamDisabledDetail =
        "Enable the Dream cycle toggle in Dreams to run a dream cycle."
    public static let remDisabledDetail =
        "Enable the REM cycle toggle in Dreams to run REM consolidation."
}

/// Civil date keys name a night by its start.
public enum DreamREMSchedule {
    public static func localCalendar() -> Calendar {
        var cal = Calendar(identifier: .gregorian)
        cal.timeZone = .current
        return cal
    }

    public static func todayKey(
        now: Date = Date(),
        calendar: Calendar = .current
    ) -> String {
        let c = calendar.dateComponents([.year, .month, .day], from: now)
        return String(format: "%04d-%02d-%02d", c.year ?? 0, c.month ?? 0, c.day ?? 0)
    }


}

// MARK: - FileBackedDreamDiary

/// Read diary Markdown without models or scheduling; include archives in newest-first browsing.
/// Backups include dream_diary; export and phone sync exclude it, with PrivacyMap/dream_diary ownership.
/// Use nightly day prefixes for REM and exact filenames for theme cues.
public struct FileBackedDreamDiary: Sendable {
    private let diaryDir: URL
    // Do not store non-Sendable FileManager; use its default inline for read-only filesystem operations.
    private var fm: FileManager { .default }

    public init(dataRoot: URL) {
        self.diaryDir = dataRoot.appendingPathComponent("dream_diary", isDirectory: true)
    }

    public enum Location: Sendable { case active, includingArchives }
    public enum Filenames: Sendable { case markdown, dated, nightly }

    public struct DiaryFile: Sendable {
        public let name: String
        public let url: URL
        /// Non-nightly Markdown has no calendar-day identity.
        public let day: String?
        public var stem: String { (name as NSString).deletingPathExtension }
    }

    private static func day(from stem: String) -> String? {
        let day = String(stem.prefix(10))
        guard day.range(of: #"^\d{4}-\d{2}-\d{2}$"#, options: .regularExpression) != nil else { return nil }
        if stem == day { return day }
        // Include collision copies retained by the archive writer under day-plus-UUID names.
        guard stem.dropFirst(10).first == "_", UUID(uuidString: String(stem.dropFirst(11))) != nil else { return nil }
        return day
    }

    /// Discovery cannot choose active/history coverage for callers; use local calendar days for window bounds.
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

    /// Include empty and absent traversal directories so later diary membership changes can reach the watcher.
    public func observationPaths() throws -> [URL] {
        var failure: (any Error)?
        let discovery = diaryFiles(in: .includingArchives, matching: .markdown) { _, error in
            let code = (error as? CocoaError)?.code
            if code != .fileReadNoSuchFile && code != .fileNoSuchFile { failure = error }
        }
        if let failure { throw failure }
        return discovery.directories + discovery.files.map(\.url)
    }

    /// Read and stat once so callers judge missing metadata against one observation.
    private func materialize(_ file: DiaryFile, date: String) throws -> DreamEntry {
        let text = try String(contentsOf: file.url, encoding: .utf8)
        let attrs = try fm.attributesOfItem(atPath: file.url.path)
        return DreamEntry(date: date, filename: file.name, content: text,
            size: (attrs[.size] as? NSNumber)?.intValue,
            modifiedAt: (attrs[.modificationDate] as? Date).map { ISO8601DateFormatter().string(from: $0) })
    }

    public func entriesSince(_ since: Date?) throws -> [DreamEntry] {
        try discover(in: .active, matching: .dated, since: since).map { file in
            try materialize(file, date: file.day!)
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
    ) -> (files: [DiaryFile], storage: String, directories: [URL]) {
        var found: [DiaryFile] = []
        var storage = "readable"
        var directories: [URL] = []
        // An unreadable existing directory is failure; only an absent directory is an empty diary.
        func names(in directory: URL) -> [String] {
            directories.append(directory)
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
        return (found, storage, directories)
    }

    /// Distinguish empty diary from unreadable listing.
    public struct DiaryListing: Sendable {
        public let entries: [DreamEntry]
        public let totalEntries: Int
        public let storage: String
        public let activeFilenames: Set<String>
        public let storageUnreadable: Bool
        public let failures: [String: String]
        public var unreadableEntries: Int { failures.count }

        public var isComplete: Bool { !storageUnreadable && unreadableEntries == 0 }
    }

    /// Carry unreadable items beside readable siblings.
    public func listEntriesChecked(limit: Int) -> DiaryListing {
        let clamped = max(1, limit)
        var unreadableDirectory = false
        let discovered = diaryFiles(in: .includingArchives, matching: .markdown) { directory, _ in
            if fm.fileExists(atPath: directory.path) { unreadableDirectory = true }
        }
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
            activeFilenames: Set(discovered.files.filter { $0.url.deletingLastPathComponent().path == diaryDir.path }.map(\.name)),
            storageUnreadable: unreadableDirectory, failures: failures)
    }

    /// Keep invalid keys and absent files distinct; propagate read/stat failures.
    public enum ByDateResult: Sendable, Equatable {
        case badPath(storage: String)
        case notFound(storage: String)
        case entry(DreamEntry, archived: Bool)
    }

    public func getEntryResult(_ dateKey: String) throws -> ByDateResult {
        func storage() -> String {
            diaryFiles(in: .active, matching: .markdown) { _, _ in }.storage
        }
        let trimmed = dateKey.trimmingCharacters(in: .whitespaces)
        // Validate one nonreserved path segment before resolving a diary key.
        if trimmed.isEmpty { return .badPath(storage: storage()) }
        if ["diary", "today", "run"].contains(trimmed) { return .badPath(storage: storage()) }
        if trimmed.contains("/") || trimmed.contains("\\")
            || trimmed.contains("\0") || trimmed == "." || trimmed == ".."
            || trimmed.contains("..") {
            return .badPath(storage: storage())
        }
        var url = diaryDir.appendingPathComponent("\(trimmed).md")
        // Confine active and archived entries strictly to the diary.
        let resolvedDir = diaryDir.standardizedFileURL.resolvingSymlinksInPath().path
        let resolvedFile = url.standardizedFileURL.resolvingSymlinksInPath().path
        guard let tail = NativeAgentWorkspaceRoot.relativePath(resolvedFile, under: resolvedDir), !tail.isEmpty else { return .badPath(storage: storage()) }

        // Archived entries use the same validated stem and containment rules as active entries.
        if !fm.fileExists(atPath: url.path) {
            let archived = diaryDir.appendingPathComponent("archive", isDirectory: true)
                .appendingPathComponent(String(trimmed.prefix(4)), isDirectory: true)
                .appendingPathComponent("\(trimmed).md")
            guard fm.fileExists(atPath: archived.path) else { return .notFound(storage: storage()) }
            guard let tail = NativeAgentWorkspaceRoot.relativePath(
                archived.standardizedFileURL.resolvingSymlinksInPath().path,
                under: resolvedDir
            ), !tail.isEmpty else {
                return .badPath(storage: storage())
            }
            url = archived
        }
        var entry = try materialize(DiaryFile(name: url.lastPathComponent, url: url, day: nil), date: trimmed)
        entry.size = entry.size ?? 0
        entry.modifiedAt = nil
        return .entry(entry, archived: url.deletingLastPathComponent() != diaryDir)
    }

    /// Return nil only for invalid path or absence; propagate read failures.
    public func getEntry(_ dateKey: String) throws -> DreamEntry? {
        switch try getEntryResult(dateKey) {
        case .badPath, .notFound: return nil
        case .entry(let e, _): return e
        }
    }
}

// MARK: - SwiftNative cycle runners

/// Runners own policy admission; preserve their errors at the facade.
public actor SwiftNativeDreamREMCycle {
    private let dataRoot: URL
    private let dreamRunner: DreamCycleRunner
    private let remConsolidator: REMConsolidator

    public init(
        dataRoot: URL,
        gate: DreamREMGatePolicy? = nil,
        dreamMemoryDeltaProvider: DreamMemoryDeltaProvider? = nil,
        dreamSurpriseProvider: DreamSurpriseProvider? = nil,
        dreamFeltSummaryProvider: DreamFeltSummaryProvider? = nil,
        dreamFeltOriginProvider: DreamFeltOriginProvider? = nil,
        dreamCareNightProvider: DreamCareNightProvider? = nil,
        dreamReceiptSink: DreamReceiptSink? = nil,
        dreamMoodSink: DreamDatedMoodSink? = nil,
        remStageApproval: REMApprovalStager? = nil,
        lifecycleObserver: (any LLMCallLifecycleObserving)? = nil
    ) throws {
        self.dataRoot = dataRoot
        let effectiveGate = try gate ?? DreamREMGatePolicy(policy: SwiftNativeTrustCenter(dataRoot: dataRoot).loadSavedPolicyChecked())
        let llm = makeResidentProviderLLMClient(
            dataRoot: dataRoot, lifecycleObserver: lifecycleObserver)
        let personaRoot = PersistenceCore.defaultPersonaRoot(dataRoot: dataRoot)
        // Manual and scheduled paths share memory, felt tone and mood wiring.
        self.dreamRunner = DreamCycleRunner(
            dataRoot: dataRoot,
            personaRoot: personaRoot,
            llm: llm,
            memoryDeltaProvider: dreamMemoryDeltaProvider ?? { _ in [] },
            surpriseProvider: dreamSurpriseProvider ?? { _, _ in "" },
            feltSummaryProvider: dreamFeltSummaryProvider ?? { nil },
            feltOriginProvider: dreamFeltOriginProvider ?? { [] },
            careNightProvider: dreamCareNightProvider ?? { throw PersistenceCoreError.ioFailure("care night evidence provider is unavailable") },
            receiptSink: dreamReceiptSink ?? { _, _ in throw PersistenceCoreError.ioFailure("dream receipt delivery is unavailable") },
            datedMoodSink: dreamMoodSink,
            gate: effectiveGate
        )
        // Manual and scheduled REM share the same approval stager.
        self.remConsolidator = REMConsolidator(
            dataRoot: dataRoot,
            personaRoot: personaRoot,
            llm: llm,
            gate: effectiveGate,
            stageApproval: remStageApproval
        )
    }

    /// Share gate, runner and deduplication; only trigger provenance and target day differ.
    public func previewDream() async throws -> DreamReport {
        try requireLiveProviders()
        // Preview may assemble, generate and decode only; it cannot mutate lifecycle, journal, memory, mood or care state.
        return try await dreamRunner.runNightlyDreamCycle(trigger: .manual, preview: true)
    }

    public func runDream(force: Bool, trigger: DreamTrigger, delivery: DreamEffectSink? = nil,
                         parent: Turn? = nil, beganAt: Date = Date()) async throws -> DreamReport {
        try requireLiveProviders()
        let report: DreamReport
        do {
            report = try await dreamRunner.runNightlyDreamCycle(force: force, trigger: trigger, delivery: delivery, parent: parent, beganAt: beganAt)
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
        } else if report.entriesWritten > 0 || report.effectsSettled > 0 {
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
        // Force bypasses weekly freshness rather than policy admission.
        return try await remConsolidator.runWeeklyREM(force: force)
    }

    private func requireLiveProviders() throws {
        guard dataRoot.standardizedFileURL == PersistenceCore.defaultDataRoot().standardizedFileURL else {
            throw DreamREMCycleError.underlying("background providers are unavailable for an alternate data root")
        }
    }

}

// MARK: - Factory

// Injected gates preserve checked caller authority; otherwise load saved policy.
// Inject the same approval stager and mood sink so factory runs retain ordinary staging and body effects.
public func makeDreamREMCycle(
    root: URL = PersistenceCore.defaultDataRoot(),
    gate: DreamREMGatePolicy? = nil,
    remStageApproval: REMApprovalStager? = nil,
    dreamMoodSink: DreamDatedMoodSink? = nil,
    lifecycleObserver: (any LLMCallLifecycleObserving)? = nil
) throws -> SwiftNativeDreamREMCycle {
    return try SwiftNativeDreamREMCycle(
        dataRoot: root, gate: gate,
        dreamMoodSink: dreamMoodSink, remStageApproval: remStageApproval,
        lifecycleObserver: lifecycleObserver)
}
import CognitiveSubstrate
// Blueprint: | `DreamREMCycle.swift` | `FileBackedDreamDiary`, `SwiftNativeDreamREMCycle`. |
