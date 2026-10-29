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
import NotificationInbox
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
// Blueprint: | `DataRootDiskHygiene.swift` | `MaintenanceBackgroundWork` stores its port and disk card identity; `DataRootDiskHygiene`, reports and daily accounting; maintenance-assistance supplies storage prose; native owners retain unavailable plan reads, saved cleanup scope, receipts and acknowledgment by finding identity; no JS under the publication lock |

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
        guard !report.truncated, !report.depthTruncated, !report.readFailed else {
            nativeLog("Disk hygiene accounting incomplete; prior notice preserved: %@", report.readFailures.joined(separator: "; "))
            return false
        }
        guard report.tripped else {
            do {
                let now = Date()
                _ = try await LiveNotificationInbox.live(dataRoot: dataRoot).archiveActive(
                    ids: [diskHygieneCardId], readAt: now.ISO8601Format(), createdNoLaterThan: now,
                    metadata: ["automatically_resolved": .bool(true), "actions": .array([]), "cleanup_plans": .array([])])
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
        var actions: [JSONValue] = []
        if reclaimable > 0 {
            actions.append(.object(["id": .string("act"), "label": .string("Clean Up"),
                "description": .string("Move the listed owner-approved bytes to Trash")]))
        }
        actions += [
            .object(["id": .string("archive"), "label": .string("Archive"), "description": .string("Archive this card")]),
            .object(["id": .string("dismiss"), "label": .string("Dismiss"), "description": .string("Dismiss this card")])
        ]
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
            let card: JSONValue = .object([
                "id": .string(diskHygieneCardId), "created_at": .string(Date().ISO8601Format()),
                "source": .string("disk_hygiene"), "severity": .string(reclaimable > 0 ? "actionable" : "info"),
                "title": .string(content.title), "summary": .string(content.summary),
                "detail": .string(content.detail), "finding_identity": .string(finding),
                "cleanup_plans": try JSONValue.fromEncodable(plans), "actions": .array(actions),
                "related_paths": .array([]), "related_groups": .array([]),
                "related_mission_id": .null, "related_approval_id": .null,
                "status": .string("unread"), "read_at": .null])
            guard let notify = await upsertDiskHygieneCard(dataRoot: dataRoot, card: card, preserveStatus: true,
                scanStartedAt: report.startedAt) else { return false }
            if notify {
                await port.notifyIfAttentionWorthy(dataRoot: dataRoot, itemId: diskHygieneCardId,
                    title: content.title, summary: content.summary, source: "disk_hygiene",
                    severity: reclaimable > 0 ? "actionable" : "info")
            }
            return true
        } catch {
            nativeLog("Disk hygiene: plan could not be saved: %@", String(describing: error))
            return false
        }
    }

    /// Both the card and inbox.clean_up execute this saved plan, never a larger fresh one.
    public func cleanUpDiskHygiene(dataRoot: URL = PersistenceCore.defaultDataRoot()) async throws -> String {
        let inboxPath = dataRoot.appendingPathComponent("notifications/inbox.jsonl")
        // Prepare the newest saved card before locking; the locked read owns its scope.
        if let row = try await LiveNotificationInbox.live(dataRoot: dataRoot).rows().last(where: {
            $0.objectValue?["id"] == .string(diskHygieneCardId)
        }), row.objectValue?["cleanup_plans"] == nil {
            guard await fileDiskHygieneNotice(dataRoot: dataRoot, report: DataRootDiskHygiene.scan(dataRoot: dataRoot)) else {
                throw NSError(domain: "NativeAgentDisk", code: 500, userInfo: [NSLocalizedDescriptionKey:
                    "Disk finding could not be refreshed; nothing was moved."])
            }
            throw NSError(domain: "NativeAgentDisk", code: 409, userInfo: [NSLocalizedDescriptionKey:
                "Disk finding refreshed. Review its current cleanup plan before running Clean Up."])
        }
        return try await SwiftNativePersistenceCore.withFileLock(inboxPath) {
            let lines = try LiveNotificationInbox.readLines(inboxPath)
            guard let object = lines.last(where: {
                      $0.row?.objectValue?["id"] == .string(diskHygieneCardId)
                  })?.row?.objectValue,
                  let plans = object["cleanup_plans"] else {
                throw NSError(domain: "NativeAgentDisk", code: 409, userInfo: [NSLocalizedDescriptionKey:
                    "No saved cleanup plan. Refresh the disk finding before cleaning up."])
            }
            let card = (object, try JSONDecoder().decode([DiskStorageOwner.Plan].self, from: plans.serializedData(pretty: false)))
            let owners = diskStorageOwners(dataRoot: dataRoot)
            guard card.1.contains(where: { !$0.candidates.isEmpty }) else {
                throw NSError(domain: "NativeAgentDisk", code: 409, userInfo: [NSLocalizedDescriptionKey:
                    "No safely reclaimable bytes are offered by this card. Its storage is kept for the reasons shown."])
            }
            var outcomes: [DiskStorageOwner.Outcome] = []
            for plan in card.1 where !plan.candidates.isEmpty {
                do {
                    guard let owner = owners.first(where: { $0.id == plan.owner }) else {
                        throw NSError(domain: "NativeAgentDisk", code: 409, userInfo: [NSLocalizedDescriptionKey: "Storage owner is unavailable; kept."])
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
            var replacement = card.0
            replacement["cleanup_detail"] = .string(receipt)
            replacement["detail"] = .string(receipt)
            replacement["summary"] = .string(summary)
            replacement["title"] = .string("Disk cleanup")
            replacement["severity"] = .string(skipped == 0 ? "info" : "actionable")
            replacement["status"] = .string("read")
            replacement["read_at"] = .string(Date().ISO8601Format())
            replacement["cleanup_completed_at"] = .double(Date().timeIntervalSince1970)
            replacement["cleanup_plans"] = .array([])
            if case .array(let actions)? = replacement["actions"] {
                replacement["actions"] = .array(actions.filter {
                    guard case .object(let action) = $0 else { return true }
                    return action["id"] != .string("act")
                })
            }
            guard await upsertDiskHygieneCard(dataRoot: dataRoot, card: .object(replacement), preserveStatus: false) != nil else {
                throw NSError(domain: "NativeAgentDisk", code: 500, userInfo: [NSLocalizedDescriptionKey:
                    receipt + "\nCleanup completed, but its card could not be saved."])
            }
            if reclaimed == 0, skipped > 0 {
                throw NSError(domain: "NativeAgentDisk", code: 409, userInfo: [NSLocalizedDescriptionKey: receipt])
            }
            return summary
        }
    }

    /// Preserve acknowledgment by owner/budget finding, and retain the last cleanup receipt.
    private func upsertDiskHygieneCard(
        dataRoot: URL,
        card: JSONValue,
        preserveStatus: Bool,
        scanStartedAt: Date? = nil
    ) async -> Bool? {
        do {
            return try await LiveNotificationInbox.live(dataRoot: dataRoot)
                .upsert(id: diskHygieneCardId) { existing in
                    guard case .object(let obj)? = existing else { return (card, true) }
                    var notify = false
                    if let scanStartedAt, case .double(let completed)? = obj["cleanup_completed_at"],
                       completed > scanStartedAt.timeIntervalSince1970 {
                        throw NSError(domain: "NativeAgentDisk", code: 409, userInfo: [NSLocalizedDescriptionKey:
                            "Disk cleanup completed after this scan; a fresh accounting is required."])
                    }
                    var replacement = card
                    if preserveStatus, case .object(var newObj) = card {
                        newObj["cleanup_completed_at"] = obj["cleanup_completed_at"]
                        func identity(_ value: JSONValue?) -> (Set<String>, Int64) {
                            guard case .string(let value) = value else { return ([], 0) }
                            let parts = value.split(separator: "|").map(String.init)
                            let tier = parts.first { $0.hasPrefix("reclaim-tier:") }
                                .flatMap { Int64($0.dropFirst("reclaim-tier:".count)) } ?? 0
                            return (Set(parts.filter { !$0.hasPrefix("reclaim-tier:") }), tier)
                        }
                        let oldFinding = identity(obj["finding_identity"])
                        let newFinding = identity(newObj["finding_identity"])
                        let sameFinding = obj["finding_identity"] == nil
                            || (newFinding.0.isSubset(of: oldFinding.0) && newFinding.1 <= oldFinding.1)
                        if sameFinding, obj["automatically_resolved"] != .bool(true) {
                            newObj["status"] = obj["status"] ?? .string("unread")
                            newObj["read_at"] = obj["read_at"] ?? .null
                        } else { notify = true }
                        if case .string(let receipt)? = obj["cleanup_detail"],
                           case .string(let detail)? = newObj["detail"] {
                            newObj["cleanup_detail"] = .string(receipt)
                            newObj["detail"] = .string(detail + "\n\nLast cleanup:\n" + receipt)
                        }
                        replacement = .object(newObj)
                    }
                    return (replacement, notify)
                }
        } catch {
            // A failed upsert must report failure so the loop rolls back the
            // daily reservation and retries delivery on the next tick.
            FileHandle.standardError.write(Data(
                "DataRootDiskHygieneCheck: notice upsert failed: \(error)\n".utf8))
            return nil
        }
    }
}

/// One oversized file the disk-hygiene scan found.
public struct DiskHygieneOffender: Sendable, Equatable {
    /// Path relative to `dataRoot` (so the notification never leaks the absolute
    /// home-directory path).
    public let relativePath: String
    public let sizeBytes: Int64

    public init(relativePath: String, sizeBytes: Int64) {
        self.relativePath = relativePath
        self.sizeBytes = sizeBytes
    }
}

/// The result of one `dataRoot` size scan.
public struct DiskHygieneReport: Sendable, Equatable {
    public let startedAt: Date
    public let storageBytes: [String: Int64]
    /// Single files larger than `singleFileThreshold`, largest first.
    public let largeFiles: [DiskHygieneOffender]
    /// Deepest over-threshold directory subtrees, plus any residue root regardless of size.
    public let largeDirectories: [DiskHygieneOffender]
    /// Total bytes of every regular file walked (bounded by `maxDepth`).
    public let totalBytes: Int64
    public let staticModelBytes: Int64
    public var dynamicBytes: Int64 { totalBytes - staticModelBytes }
    /// Whether dynamic bytes exceeded `totalThreshold`.
    public let totalOverBudget: Bool
    /// The file budget stopped the walk; totals and offenders may undercount.
    public let truncated: Bool
    /// The depth bound left directories unscanned, independently of the file budget.
    public let depthTruncated: Bool
    /// A directory or required file attribute could not be read.
    public let readFailed: Bool
    public let readFailures: [String]

    /// True when the scan found anything worth a notification.
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
    /// A single file this large trips a notification (default 1 GB).
    /// Residue is identified separately by `residueRelativePrefixes`.
    public static let defaultSingleFileThreshold: Int64 = 1024 * 1024 * 1024
    /// Dynamic `dataRoot` bytes above 1 GB trip a notification.
    public static let defaultTotalThreshold: Int64 = 1024 * 1024 * 1024

    /// A directory subtree above 128 MB trips a notification.
    public static let defaultDirectoryThreshold: Int64 = 128 * 1024 * 1024

    /// Bound each synchronous scan to 50,000 entries.
    public static let defaultMaxScannedEntries = 50_000

    /// Descend at most seven levels; the entry budget also bounds the walk.
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
        /// relative path → subtree bytes, for every directory descended into.
        var directoryBytes: [String: Int64] = [:]
        var fileBytes: [String: Int64] = [:]
        /// Relative paths of directories holding an over-threshold descendant,
        /// so only the deepest offender in a branch is reported.
        var hasOffendingChild: Set<String> = []

        /// Returns the bytes `dir`'s subtree contributed.
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
                        // A real directory sat past the depth bound — its files
                        // are UNSCANNED, so flag it rather than silently
                        // undercounting and reading as a clean bill.
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
                    // Residue is reported whatever it weighs, and reported at
                    // the residue root rather than at whichever descendant
                    // happens to be fattest.
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

    /// True when `relativePath` IS a residue store's root. Case folded because
    /// APFS is typically case-insensitive, so `Extras/HF_Cache` addresses the
    /// same directory as `extras/hf_cache`.
    public static func isResidue(relativePath: String) -> Bool {
        let normalized = relativePath.lowercased()
        return residueRelativePrefixes.contains { $0.lowercased() == normalized }
    }

    /// True when `relativePath` sits strictly UNDER a residue store's root — so
    /// the branch is reported once, at the root, instead of once per level.
    static func isResidueDescendant(relativePath: String) -> Bool {
        let normalized = relativePath.lowercased()
        return residueRelativePrefixes.contains {
            normalized.hasPrefix($0.lowercased() + "/")
        }
    }

    /// `entry`'s path relative to `root`, falling back to the last path
    /// component when it is not under `root` (never leaks the absolute path).
    static func relativePath(of entry: URL, under root: URL) -> String {
        NativeAgentWorkspaceRoot.relativePath(entry.standardizedFileURL.path, under: root.standardizedFileURL.path)
            ?? entry.lastPathComponent
    }

    // MARK: - Residue

    /// Unused HuggingFace storage is reported at any size and may be trashed by cleanup.
    public static let residueRelativePrefixes = ["extras/hf_cache"]

    /// A human-readable byte size (e.g. "194.0 MB").
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

/// Once-per-day disk accounting. Walks `dataRoot`, and when a single file
/// is oversized or the whole tree is over budget, files ONE notification-inbox
/// card listing the offenders. NEVER deletes anything.
///
/// The owning factory wires the inbox write to the same
/// `notifications/inbox.jsonl` upsert path HeartbeatLoop uses. The daily
/// reservation runs through the shared `reserveOncePerPeriod` primitive so a
/// BGTask wake and the in-app scheduler cannot double-run it the same day.
/// Startup reconciles immediately; the persisted day books the next local
/// midnight. Only an unreserved day retains the hourly failure retry.
public struct DataRootDiskHygieneCheck: EventDeadlineLoopRunner {
    public let loopId: String = "data_root_disk_hygiene"
    public let interval: TimeInterval
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
        self.interval = interval
        self.dataRoot = dataRoot
        self.clock = clock
        self.maxDepth = maxDepth
        self.singleFileThreshold = singleFileThreshold
        self.totalThreshold = totalThreshold
        self.fileNotice = fileNotice
    }

    /// Day bucket (yyyy-MM-dd) used as the reservation key so the scan runs
    /// at most once per calendar day across every driver.
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
            // Preserve the existing hourly retry while today's scan/notice
            // remains unreserved, without waking hourly after it succeeds.
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
            return .skipped(reason: "disk hygiene already ran today")
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
        guard !report.readFailed, !report.truncated, !report.depthTruncated else {
            await rollback()
            return .failed(error: "Disk accounting incomplete; prior notice preserved and day not consumed. "
                + "file-budget truncated: \(report.truncated); depth truncated: \(report.depthTruncated). "
                + report.readFailures.joined(separator: "; "))
        }
        // A complete report retires stale notices or publishes findings; failed publication releases the day.
        guard await fileNotice(report) else {
            await rollback()
            return .failed(error: "disk hygiene notice delivery failed; reservation rolled back")
        }
        guard report.tripped else {
            return .skipped(reason: "disk clean (\(DataRootDiskHygiene.humanSize(report.totalBytes)))")
        }
        return .completed(result:
            "disk hygiene flagged \(report.largeFiles.count) large file(s), "
            + "\(report.largeDirectories.count) large director(ies), "
            + "total \(DataRootDiskHygiene.humanSize(report.totalBytes))")
    }
}
