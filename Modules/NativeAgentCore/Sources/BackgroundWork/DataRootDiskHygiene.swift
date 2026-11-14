import Foundation
import NativeAgentShared
import NativeAgentCore
import BackgroundLoops
import ChatSessionWork
import Context
import DoctorChecks
import PersistenceCore
import TurnTrace
import ApprovalInbox
import MemoryV2
import DreamREMCycle
import AgentWorkspace
import Desk
import AttentionRouting
import Privacy
import ProviderRouting
import Experiences
import ToolRegistry
import Cognition
// Blueprint: | `DataRootDiskHygiene.swift` | Disk matters point to locked saved cleanup offers; reclamation settles its receipt |

public struct MaintenanceBackgroundWork: Sendable {
    let port: any MaintenanceBackgroundWorkPort

    public init(port: any MaintenanceBackgroundWorkPort) { self.port = port }

    /// Daily read-only accounting; only the card's action executes owner reclamation plans.
    public func makeDataRootDiskHygieneLoop(
        dataRoot: URL = PersistenceCore.defaultDataRoot()
    ) -> DataRootDiskHygieneCheck {
        DataRootDiskHygieneCheck(
            dataRoot: dataRoot,
            fileNotice: { report in await fileDiskHygieneNotice(dataRoot: dataRoot, report: report) }
        )
    }

    public let diskHygieneCardId = "disk-hygiene"

    private func diskStorageOwners(dataRoot: URL) -> [DiskStorageOwner] {
        port.diskStorageOwners(dataRoot: dataRoot) + [
            DiskStorageOwner(id: "residue", plan: {
                let roots = DataRootDiskHygiene.residueRelativePrefixes
                var candidates: [String: DiskStorageOwner.Candidate] = [:]
                for path in roots where FileManager.default.fileExists(atPath: dataRoot.appendingPathComponent(path).path) {
                    candidates[path] = try DiskStorageOwner.candidate(path, dataRoot: dataRoot)
                }
                return DiskStorageOwner.Plan(owner: "residue", roots: roots,
                    policy: "Unused HuggingFace residue moves to Trash.", candidates: candidates)
            }, reclaim: { saved in
                saved.candidates.sorted(by: { $0.key < $1.key }).map { path, token in
                    guard DataRootDiskHygiene.residueRelativePrefixes.contains(path) else {
                        return DiskStorageOwner.Outcome(relativePath: path, skippedReason: "not declared by this owner; kept")
                    }
                    return DiskStorageOwner.trash(path, candidate: token, dataRoot: dataRoot)
                }
            })
        ]
    }

    public func fileDiskHygieneNotice(dataRoot: URL, report: DiskHygieneReport) async -> Bool {
        guard !report.readFailed else {
            nativeLog("Disk hygiene accounting incomplete; prior notice preserved: %@", report.readFailures.joined(separator: "; "))
            return false
        }
        // Bounded accounting remains useful but cannot clear a notice.
        let partial = report.truncated || report.depthTruncated
        guard report.tripped else {
            if partial { return true }
            do {
                try await BodyNotice.resolve(key: diskHygieneCardId, from: "disk_hygiene", dataRoot: dataRoot)
                return true
            } catch {
                nativeLog("Disk hygiene: resolved notice could not be archived: %@", String(describing: error))
                return false
            }
        }
        var plans: [DiskStorageOwner.Plan] = []
        var planReads: [JSONValue] = []
        for owner in diskStorageOwners(dataRoot: dataRoot) {
            do {
                plans.append(try await owner.plan())
                planReads.append(.object(["owner": .string(owner.id), "status": .string("available")]))
            } catch {
                planReads.append(.object(["owner": .string(owner.id), "status": .string("unavailable"),
                                          "error": .string(error.localizedDescription)]))
            }
        }
        var usage = report.storageBytes.filter { !$0.key.contains("/") }
        for plan in plans {
            var bytes: Int64 = 0
            for root in plan.roots {
                let size = report.storageBytes[root] ?? 0
                bytes += size
                let top = String(root.split(separator: "/").first ?? "")
                usage[top, default: 0] -= size
            }
            usage[plan.owner, default: 0] += bytes
        }
        let reclaimable = plans.reduce(Int64(0)) { sum, plan in
            sum + plan.candidates.values.reduce(0) { $0 + $1.sizeBytes }
        }
        let finding = (usage.filter { $0.value > DataRootDiskHygiene.defaultDirectoryThreshold }
            .keys.sorted() + (report.totalOverBudget ? ["dynamic"] : [])
            + report.largeFiles.map { "file:\($0.relativePath)" }.sorted()
            + plans.filter { !$0.candidates.isEmpty }.map { "reclaim:\($0.owner)" }.sorted()
            + ["reclaim-tier:\(reclaimable / DataRootDiskHygiene.defaultDirectoryThreshold)"])
            .joined(separator: "|")
        let usageRows: [JSONValue] = usage.map { owner, bytes in
            let plan = plans.first { $0.owner == owner }
            let reclaim = plan?.candidates.values.reduce(Int64(0)) { $0 + $1.sizeBytes } ?? 0
            return .object(["owner": .string(owner), "bytes": .int(bytes),
                            "size": .string(DataRootDiskHygiene.humanSize(bytes)),
                            "reclaimSize": .string(DataRootDiskHygiene.humanSize(reclaim)),
                            "policy": plan.map { .string($0.policy) } ?? .null])
        }
        var actions: [PartFace.Action] = []
        if reclaimable > 0 { actions.append(.init(id: "act", label: "Clean Up", role: .primary)) }
        actions += [.init(id: "archive", label: "Archive"), .init(id: "dismiss", label: "Dismiss")]
        do {
            let content = try await port.assistanceCard(dataRoot: dataRoot, input: .object([
                "kind": .string("storage"), "usage": .array(usageRows), "planReads": .array(planReads),
                "plans": .array(plans.map { .object(["notes": .array($0.notes.map(JSONValue.string))]) }),
                "reclaimable": .int(reclaimable),
                "dynamicSize": .string(DataRootDiskHygiene.humanSize(report.dynamicBytes)),
                "budgetSize": .string(DataRootDiskHygiene.humanSize(DataRootDiskHygiene.defaultTotalThreshold)),
                "modelSize": .string(DataRootDiskHygiene.humanSize(report.staticModelBytes)),
                "reclaimSize": .string(DataRootDiskHygiene.humanSize(reclaimable)),
                "accounting": .object(["status": .string(report.truncated || report.depthTruncated || report.readFailed ? "partial" : "available"),
                    "truncated": .bool(report.truncated), "depthTruncated": .bool(report.depthTruncated), "readFailed": .bool(report.readFailed)])
            ]))
            let forPerson = ForPerson.at(dataRoot)
            let latest = try await forPerson.matters().first { $0.face?.from == "disk_hygiene" }
            if let latest, latest.face?.row?.tone == .done {
                guard let at = NativeTimestampFormat.parseISO8601FractionalFirst(latest.updatedAt ?? latest.at) else {
                    throw diskFailure(409, "The cleanup receipt has no readable time; a later scan cannot be established.")
                }
                if at > report.startedAt {
                    throw diskFailure(409, "Disk cleanup completed after this scan; fresh accounting is required.")
                }
            }
            var episodeFinding = finding
            if let latest, latest.progress != "resolved", latest.outcome?.domain != "disk_hygiene" {
                let saved = try readDiskOffer(latest)
                let old = try diskFinding(saved.finding)
                let new = try diskFinding(finding)
                if new.keys.isSubset(of: old.keys), new.tier <= old.tier { episodeFinding = saved.finding }
            }
            let findingID = episodeFinding
            let offer = DiskCleanupOffer(finding: episodeFinding, plans: plans)
            let choices = actions
            try await BodyNotice.tell(key: diskHygieneCardId, from: "disk_hygiene",
                finding: findingID, dataRoot: dataRoot) { id in
                if let cleaned = try await forPerson.matters().first(where: {
                    $0.face?.from == "disk_hygiene" && $0.face?.row?.tone == .done
                }) {
                    guard let at = NativeTimestampFormat.parseISO8601FractionalFirst(cleaned.updatedAt ?? cleaned.at) else {
                        throw diskFailure(409, "The cleanup receipt time is unreadable; the scan's order is unknown.")
                    }
                    if at > report.startedAt { throw diskFailure(409, "Cleanup completed after this scan; fresh accounting is required.") }
                }
                if let current = try await forPerson.matter(id),
                   ForPerson.reading(current) == .archived || ForPerson.reading(current) == .dismissed { return }
                let path = dataRoot.appendingPathComponent("disk/cleanup/" + id + ".json")
                try FileManager.default.createDirectory(at: path.deletingLastPathComponent(), withIntermediateDirectories: true)
                try await SwiftNativePersistenceCore.withFileLock(path) {
                    if let current = try await forPerson.matter(id),
                       current.face?.row?.tone == .done || current.outcome?.domain == "disk_hygiene" {
                        throw diskFailure(409, "Disk cleanup settled this offer; fresh accounting is required.")
                    }
                    try JSONEncoder().encode(offer).write(to: path, options: .atomic)
                    try await port.tell(Matter(id: id, form: reclaimable > 0 ? .ask : .words, from: "disk_hygiene",
                        title: content.title, summary: content.summary, words: content.detail, choices: choices,
                        artifacts: [.init(source: Matter.files, id: path.path)]),
                        dataRoot: dataRoot, reach: reclaimable > 0 ? .person(from: nil) : .inbox, turn: nil)
                }
            }
            return true
        } catch {
            nativeLog("Disk hygiene: plan could not be saved: %@", String(describing: error))
            return false
        }
    }

    private struct DiskCleanupOffer: Codable, Sendable {
        let finding: String
        let plans: [DiskStorageOwner.Plan]
    }

    private func diskFinding(_ finding: String) throws -> (keys: Set<String>, tier: Int64) {
        let parts = finding.split(separator: "|").map(String.init)
        let tiers = parts.filter { $0.hasPrefix("reclaim-tier:") }
        guard tiers.count == 1, let tier = Int64(tiers[0].dropFirst("reclaim-tier:".count)), tier >= 0 else {
            throw diskFailure(409, "The saved disk finding is unreadable; no cleanup scope was inferred.")
        }
        return (Set(parts.filter { !$0.hasPrefix("reclaim-tier:") }), tier)
    }

    private func diskFailure(_ code: Int, _ words: String) -> NSError {
        NSError(domain: "NativeAgentDisk", code: code, userInfo: [NSLocalizedDescriptionKey: words])
    }

    private func diskOfferPath(_ matter: Experience) throws -> URL {
        guard let path = matter.face?.artifacts.first(where: { $0.source == Matter.files })?.id else {
            throw diskFailure(409, "No saved cleanup offer. Refresh the disk finding before cleaning up.")
        }
        return URL(fileURLWithPath: path)
    }

    private func readDiskOffer(_ matter: Experience) throws -> DiskCleanupOffer {
        try JSONDecoder().decode(DiskCleanupOffer.self, from: Data(contentsOf: diskOfferPath(matter)))
    }

    /// Clean Up runs exactly the disk owner's saved offer; it never scans or expands its scope.
    public func cleanUpDiskHygiene(dataRoot: URL = PersistenceCore.defaultDataRoot(), matterID: String? = nil) async throws -> String {
        let forPerson = ForPerson.at(dataRoot)
        let selected: Experience?
        if let matterID { selected = try await forPerson.matter(matterID) }
        else { selected = try await forPerson.matters().first { $0.face?.from == "disk_hygiene" } }
        guard let selected, selected.face?.from == "disk_hygiene" else {
            throw diskFailure(409, "No saved cleanup offer. Refresh the disk finding before cleaning up.")
        }
        let path = try diskOfferPath(selected)
        return try await SwiftNativePersistenceCore.withFileLock(path) {
            guard let current = try await forPerson.matter(selected.id),
                  ForPerson.reading(current) == .unread || ForPerson.reading(current) == .read,
                  current.face?.row?.tone == .attention else {
                throw diskFailure(409, "This cleanup offer is already settled; no files were moved.")
            }
            let offer = try readDiskOffer(current)
            guard offer.plans.contains(where: { !$0.candidates.isEmpty }) else {
                throw diskFailure(409, "No safely reclaimable bytes are offered. Storage was kept.")
            }
            let owners = diskStorageOwners(dataRoot: dataRoot)
            var outcomes: [DiskStorageOwner.Outcome] = []
            for plan in offer.plans where !plan.candidates.isEmpty {
                do {
                    guard let owner = owners.first(where: { $0.id == plan.owner }) else {
                        throw diskFailure(409, "Storage owner is unavailable; kept.")
                    }
                    outcomes += try await owner.reclaim(plan)
                } catch {
                    outcomes += plan.candidates.keys.sorted().map {
                        DiskStorageOwner.Outcome(relativePath: $0, skippedReason: error.localizedDescription)
                    }
                }
            }
            let reclaimed = outcomes.filter { $0.skippedReason == nil }.reduce(Int64(0)) { $0 + $1.sizeBytes }
            let skipped = outcomes.filter { $0.skippedReason != nil }.count
            let summary = "Reclaimed \(DataRootDiskHygiene.humanSize(reclaimed)) from app storage to Trash; \(skipped) skipped."
            let receipt = summary + "\n" + outcomes.map {
                if let reason = $0.skippedReason { return "• Skipped \($0.relativePath): \(reason)" }
                return "• Moved \($0.relativePath) to Trash: \(DataRootDiskHygiene.humanSize($0.sizeBytes))"
            }.joined(separator: "\n") + "\nTrash is recoverable and still occupies disk space until you empty it."
            let result: Result<Void, Error> = await settle {
                do {
                    try await forPerson.tell(Matter(id: current.id, form: .done, from: "disk_hygiene",
                        title: "Disk cleanup", summary: summary, words: receipt,
                        artifacts: [.init(source: Matter.files, id: path.path)]), doors: [])
                    try await forPerson.answered(current.id, evidence: .init(source: Matter.files, id: path.path))
                    try await forPerson.putAway(current.id, .resolved)
                    return .success(())
                } catch { return .failure(error) }
            }
            do { try result.get() }
            catch { throw diskFailure(500, receipt + "\nCleanup completed, but its receipt could not be saved: " + error.localizedDescription) }
            if reclaimed == 0, skipped > 0 { throw diskFailure(409, receipt) }
            return summary
        }
    }

}

public struct DiskHygieneOffender: Sendable, Equatable {
    /// Relative paths keep the notification from exposing the absolute home-directory path.
    public let relativePath: String
    public let sizeBytes: Int64

    public init(relativePath: String, sizeBytes: Int64) {
        self.relativePath = relativePath
        self.sizeBytes = sizeBytes
    }
}

public struct DiskHygieneReport: Sendable, Equatable {
    public let startedAt: Date
    public let storageBytes: [String: Int64]
    public let largeFiles: [DiskHygieneOffender]
    /// Only deepest oversized subtrees appear; residue roots appear regardless of size.
    public let largeDirectories: [DiskHygieneOffender]
    public let totalBytes: Int64
    public let staticModelBytes: Int64
    public var dynamicBytes: Int64 { totalBytes - staticModelBytes }
    public let totalOverBudget: Bool
    /// The file budget stopped the walk; totals and offenders may undercount.
    public let truncated: Bool
    /// The depth bound left directories unscanned, independently of the file budget.
    public let depthTruncated: Bool
    public let readFailed: Bool
    public let readFailures: [String]

    public var tripped: Bool {
        !largeFiles.isEmpty || !largeDirectories.isEmpty || totalOverBudget
    }

    public init(
        largeFiles: [DiskHygieneOffender],
        totalBytes: Int64,
        totalOverBudget: Bool,
        truncated: Bool = false,
        depthTruncated: Bool = false,
        readFailed: Bool = false,
        readFailures: [String] = [],
        largeDirectories: [DiskHygieneOffender] = [],
        staticModelBytes: Int64 = 0,
        storageBytes: [String: Int64] = [:],
        startedAt: Date = Date()
    ) {
        self.largeFiles = largeFiles
        self.largeDirectories = largeDirectories
        self.totalBytes = totalBytes
        self.staticModelBytes = staticModelBytes
        self.storageBytes = storageBytes
        self.startedAt = startedAt
        self.totalOverBudget = totalOverBudget
        self.truncated = truncated
        self.depthTruncated = depthTruncated
        self.readFailed = readFailed || !readFailures.isEmpty
        self.readFailures = readFailures
    }
}

/// Read-only disk-usage scanner over `dataRoot`; cleanup is a separate action.
public enum DataRootDiskHygiene {
    public static let defaultSingleFileThreshold: Int64 = 1024 * 1024 * 1024
    public static let defaultTotalThreshold: Int64 = 1024 * 1024 * 1024

    public static let defaultDirectoryThreshold: Int64 = 128 * 1024 * 1024

    /// Bound synchronous scanning to protect responsiveness.
    public static let defaultMaxScannedEntries = 50_000

    /// A depth limit complements the entry budget for deeply nested trees.
    public static let defaultMaxDepth = 7

    /// Sum regular files without following symlinks; a missing root has no storage to scan.
    /// File and depth budgets bound the walk and mark incomplete accounting.
    public static func scan(
        dataRoot: URL,
        maxDepth: Int = defaultMaxDepth,
        singleFileThreshold: Int64 = defaultSingleFileThreshold,
        totalThreshold: Int64 = defaultTotalThreshold,
        maxScannedEntries: Int = defaultMaxScannedEntries,
        directoryThreshold: Int64 = defaultDirectoryThreshold
    ) -> DiskHygieneReport {
        let startedAt = Date()
        let fm = FileManager.default
        var total: Int64 = 0
        var staticModelBytes: Int64 = 0
        var readFailed = false
        var readFailures: [String] = []
        let staticFiles: Set<String>
        do { staticFiles = try CoreMLEmbedderCheck.installedModelStorageFiles(dataRoot: dataRoot) }
        catch {
            nativeLog("Disk hygiene: installed model assets unavailable for accounting: %@", String(describing: error))
            staticFiles = []
            readFailed = true
            readFailures.append("installed embedding metadata: \(error.localizedDescription)")
        }
        var offenders: [DiskHygieneOffender] = []
        var scanned = 0
        var truncated = false
        var depthTruncated = false
        var directoryBytes: [String: Int64] = [:]
        var fileBytes: [String: Int64] = [:]
        /// Descendant tracking suppresses duplicate ancestors of the deepest offender.
        var hasOffendingChild: Set<String> = []

        @discardableResult
        func walk(_ dir: URL, depth: Int) -> Int64 {
            var subtree: Int64 = 0
            defer {
                if depth > 0 {
                    let rel = relativePath(of: dir, under: dataRoot)
                    directoryBytes[rel] = subtree
                    if subtree > directoryThreshold {
                        var parent = (rel as NSString).deletingLastPathComponent
                        while !parent.isEmpty {
                            hasOffendingChild.insert(parent)
                            parent = (parent as NSString).deletingLastPathComponent
                        }
                    }
                }
            }
            guard !truncated else { return subtree }
            let entries: [URL]
            do {
                entries = try fm.contentsOfDirectory(at: dir,
                    includingPropertiesForKeys: [.isDirectoryKey, .isRegularFileKey, .fileSizeKey, .isSymbolicLinkKey], options: [])
            } catch {
                readFailed = true
                readFailures.append("\(relativePath(of: dir, under: dataRoot)): \(error.localizedDescription)")
                return subtree
            }
            for entry in entries {
                scanned += 1
                if scanned > maxScannedEntries { truncated = true; return subtree }
                let values: URLResourceValues
                do {
                    values = try entry.resourceValues(forKeys: [
                        .isDirectoryKey, .isRegularFileKey, .fileSizeKey, .isSymbolicLinkKey])
                    guard values.isSymbolicLink != nil, values.isDirectory != nil,
                          values.isRegularFile != nil else { throw CocoaError(.fileReadUnknown) }
                } catch {
                    readFailed = true
                    readFailures.append("\(relativePath(of: entry, under: dataRoot)): \(error.localizedDescription)")
                    continue
                }
                if values.isSymbolicLink == true { continue }
                if values.isDirectory == true {
                    if depth < maxDepth {
                        subtree += walk(entry, depth: depth + 1)
                    } else {
                        // Unvisited directories make accounting incomplete, never a clean bill.
                        depthTruncated = true
                    }
                    continue
                }
                if values.isRegularFile == true {
                    guard let fileSize = values.fileSize else {
                        readFailed = true
                        readFailures.append("\(relativePath(of: entry, under: dataRoot)): file size unavailable")
                        continue
                    }
                    let size = Int64(fileSize)
                    total += size
                    if staticFiles.contains(entry.standardizedFileURL.path) {
                        staticModelBytes += size
                        continue
                    }
                    subtree += size
                    fileBytes[relativePath(of: entry, under: dataRoot)] = size
                    if size > singleFileThreshold {
                        offenders.append(DiskHygieneOffender(
                            relativePath: relativePath(of: entry, under: dataRoot),
                            sizeBytes: size
                        ))
                    }
                }
            }
            return subtree
        }

        do {
            _ = try fm.attributesOfItem(atPath: dataRoot.path)
            walk(dataRoot, depth: 0)
        } catch CocoaError.fileReadNoSuchFile {
            // A missing data root has no storage to scan.
        } catch {
            readFailed = true
            readFailures.append("data root: \(error.localizedDescription)")
        }
        offenders.sort { $0.sizeBytes > $1.sizeBytes }
        let directoryOffenders = directoryBytes
            .filter { rel, bytes in
                (bytes > directoryThreshold && !hasOffendingChild.contains(rel))
                    // Residue is actionable at any size and belongs to one finding at its root.
                    || isResidue(relativePath: rel)
            }
            .filter { rel, _ in
                // A residue store's own subtree is one finding, not one per level.
                !isResidueDescendant(relativePath: rel)
            }
            .map { DiskHygieneOffender(relativePath: $0.key, sizeBytes: $0.value) }
            .sorted { $0.sizeBytes > $1.sizeBytes }
        return DiskHygieneReport(
            largeFiles: offenders,
            totalBytes: total,
            totalOverBudget: total - staticModelBytes > totalThreshold,
            truncated: truncated,
            depthTruncated: depthTruncated,
            readFailed: readFailed,
            readFailures: readFailures,
            largeDirectories: directoryOffenders,
            staticModelBytes: staticModelBytes,
            storageBytes: directoryBytes.merging(fileBytes) { a, _ in a },
            startedAt: startedAt
        )
    }

    /// Fold case because typical APFS volumes address differently cased paths as the same directory.
    public static func isResidue(relativePath: String) -> Bool {
        let normalized = relativePath.lowercased()
        return residueRelativePrefixes.contains { $0.lowercased() == normalized }
    }

    /// Suppress descendants so each residue store is reported once at its root.
    static func isResidueDescendant(relativePath: String) -> Bool {
        let normalized = relativePath.lowercased()
        return residueRelativePrefixes.contains {
            normalized.hasPrefix($0.lowercased() + "/")
        }
    }

    /// Keep paths relative or basename-only so notifications never expose the absolute path.
    static func relativePath(of entry: URL, under root: URL) -> String {
        NativeAgentWorkspaceRoot.relativePath(entry.standardizedFileURL.path, under: root.standardizedFileURL.path)
            ?? entry.lastPathComponent
    }

    // MARK: - Residue

    /// Unused HuggingFace storage is reported at any size and may be trashed by cleanup.
    public static let residueRelativePrefixes = ["extras/hf_cache"]

    public static func humanSize(_ bytes: Int64) -> String {
        let units = ["B", "KB", "MB", "GB", "TB"]
        var value = Double(bytes)
        var unit = 0
        while value >= 1024, unit < units.count - 1 {
            value /= 1024
            unit += 1
        }
        return String(format: unit == 0 ? "%.0f %@" : "%.1f %@", value, units[unit])
    }
}

/// Accounting never deletes; only the saved cleanup action may reclaim storage.
/// Shared daily reservation prevents BGTask and in-app drivers from duplicating a scan.
/// The persisted day books local midnight; an unreserved day keeps the hourly failure retry.
public struct DataRootDiskHygieneCheck: EventDeadlineLoopRunner {
    public let loopId: String = "data_root_disk_hygiene"
    public let wake: OrganWake
    public var tickTimeoutOverride: TimeInterval? { 120 }

    private let dataRoot: URL
    private let clock: @Sendable () -> Date
    private let maxDepth: Int
    private let singleFileThreshold: Int64
    private let totalThreshold: Int64
    private let directoryThreshold: Int64
    /// Returns whether the notice landed; failure releases the daily reservation for retry.
    private let fileNotice: @Sendable (DiskHygieneReport) async -> Bool

    public init(
        interval: TimeInterval = 24 * 60 * 60,
        dataRoot: URL = PersistenceCore.defaultDataRoot(),
        clock: @escaping @Sendable () -> Date = { Date() },
        maxDepth: Int = DataRootDiskHygiene.defaultMaxDepth,
        singleFileThreshold: Int64 = DataRootDiskHygiene.defaultSingleFileThreshold,
        totalThreshold: Int64 = DataRootDiskHygiene.defaultTotalThreshold,
        directoryThreshold: Int64 = DataRootDiskHygiene.defaultDirectoryThreshold,
        fileNotice: @escaping @Sendable (DiskHygieneReport) async -> Bool
    ) {
        self.directoryThreshold = directoryThreshold
        self.wake = .every(interval)
        self.dataRoot = dataRoot
        self.clock = clock
        self.maxDepth = maxDepth
        self.singleFileThreshold = singleFileThreshold
        self.totalThreshold = totalThreshold
        self.fileNotice = fileNotice
    }

    /// Calendar-day keys prevent duplicate accounting across every driver.
    static func dayKey(_ date: Date) -> String {
        NativeTimestampFormat.calendarDay(date)
    }

    private var marker: URL {
        dataRoot
            .appendingPathComponent("logs", isDirectory: true)
            .appendingPathComponent("disk_hygiene_last_run")
    }

    public func physiologyEvents() -> AsyncStream<Void> {
        // Do not watch the reservation itself: a failed notice restores it,
        // and that self-write must not become an immediate retry loop.
        EventDeadlinePhysiology.storeAndFileEvents(
            paths: [],
            notifications: [.NSSystemTimeZoneDidChange, .NSSystemClockDidChange],
            loopId: loopId
        )
    }

    public func nextMeaningfulDeadline(after now: Date) async -> Date? {
        guard (try? String(contentsOf: marker, encoding: .utf8)) == Self.dayKey(now) else {
            // Retry hourly only while the day remains unreserved.
            return now.addingTimeInterval(60 * 60)
        }
        let calendar = Calendar.current
        return calendar.date(byAdding: .day, value: 1, to: calendar.startOfDay(for: now))
    }

    public func tickOutcome() async -> LoopTickOutcome {
        let now = clock()
        do {
            try FileManager.default.createDirectory(
                at: marker.deletingLastPathComponent(), withIntermediateDirectories: true)
        } catch {
            return .failed(error: "disk hygiene marker directory: \(error)")
        }
        let rollback: @Sendable () async -> Void
        switch await reserveOncePerPeriod(key: Self.dayKey(now), at: marker) {
        case .alreadyReserved:
            return .notNeeded("disk hygiene already ran today")
        case .failed(let error):
            return .failed(error: "disk hygiene reservation: \(error)")
        case .reserved(_, let rb):
            rollback = rb
        }
        let report = DataRootDiskHygiene.scan(
            dataRoot: dataRoot,
            maxDepth: maxDepth,
            singleFileThreshold: singleFileThreshold,
            totalThreshold: totalThreshold,
            directoryThreshold: directoryThreshold
        )
        // A bound is not a transient read failure: consume the day and retain the partial findings.
        guard !report.readFailed else {
            await rollback()
            return .failed(error: "Disk accounting incomplete; prior notice preserved and day not consumed. "
                + report.readFailures.joined(separator: "; "))
        }
        // A complete report retires stale notices or publishes findings; failed publication releases the day.
        guard await fileNotice(report) else {
            await rollback()
            return .failed(error: "disk hygiene notice delivery failed; reservation rolled back")
        }
        guard report.tripped else {
            return .skipped(reason: (report.truncated || report.depthTruncated ? "disk accounting partial (a bound was reached); prior notice kept; "
                : "") + "disk clean (\(DataRootDiskHygiene.humanSize(report.totalBytes)))")
        }
        return .completed(result:
            "disk hygiene flagged \(report.largeFiles.count) large file(s), "
            + "\(report.largeDirectories.count) large director(ies), "
            + "total \(DataRootDiskHygiene.humanSize(report.totalBytes))")
    }
}
