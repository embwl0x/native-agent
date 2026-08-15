import Foundation
import PersistenceCore

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
    /// Single files larger than `singleFileThreshold`, largest first.
    public let largeFiles: [DiskHygieneOffender]
    /// Total bytes of every regular file walked (bounded by `maxDepth`).
    public let totalBytes: Int64
    /// Whether `totalBytes` exceeded `totalThreshold`.
    public let totalOverBudget: Bool
    /// True when the walk hit its file budget and stopped early — totals and
    /// offenders may UNDERCOUNT. Surfaced in the notice so a truncated scan
    /// never reads as a clean bill (gpt-5.5 fix round: bounded walk).
    public let truncated: Bool
    /// True when at least one directory was NOT descended into because it sat
    /// deeper than `maxDepth` — so files below it are UNSCANNED and excluded
    /// from `totalBytes`/`largeFiles`. Distinct from `truncated` (the file-count
    /// budget): a future deep dynamic store past the depth bound is visible as
    /// "unscanned" here rather than silently invisible (A5.1, W5#P1-1).
    public let depthTruncated: Bool

    /// True when the scan found anything worth a notification.
    public var tripped: Bool { !largeFiles.isEmpty || totalOverBudget }

    public init(
        largeFiles: [DiskHygieneOffender],
        totalBytes: Int64,
        totalOverBudget: Bool,
        truncated: Bool = false,
        depthTruncated: Bool = false
    ) {
        self.largeFiles = largeFiles
        self.totalBytes = totalBytes
        self.totalOverBudget = totalOverBudget
        self.truncated = truncated
        self.depthTruncated = depthTruncated
    }
}

/// Pure, read-only disk-usage scanner over `dataRoot` (tightness round 2, item
/// 6 — User: "make sure we dont pile up logs like that again burning tons of hard
/// disk" after a 194MB dead-daemon log was found). NEVER deletes anything — it
/// only measures and reports so a human decides.
public enum DataRootDiskHygiene {
    /// A single file this large trips a notification (default 1 GB). Raised from
    /// 64 MB (2026-08-11, User: "push the tripwire closer to our 2gb limit") —
    /// the old bound permanently flagged the 86.7 MB MiniLM embedder blob, a
    /// wanted file nobody should delete, so the card was a daily false alarm.
    public static let defaultSingleFileThreshold: Int64 = 1024 * 1024 * 1024
    /// Total `dataRoot` bytes this large trips a notification (default 2 GB).
    public static let defaultTotalThreshold: Int64 = 2 * 1024 * 1024 * 1024

    /// Walk `dataRoot` to `maxDepth` (dataRoot itself is depth 0), summing every
    /// regular file's size and collecting the ones over `singleFileThreshold`.
    /// Symlinks are NOT followed (size scan, not a traversal that could loop).
    /// A missing `dataRoot` yields an empty, untripped report.
    /// Hard budget on stat'd entries per scan. The walk is synchronous inside a
    /// loop tick, so a pathological data root (millions of shallow files) must
    /// terminate the scan, not the tick timeout (gpt-5.5 fix round). 50k stats
    /// complete in well under a second on APFS; a real data root is ~thousands.
    public static let defaultMaxScannedEntries = 50_000

    /// Default recursion bound. Raised from 4 → 7 (A5.1, W5#P1-1): the deepest
    /// known real store is the MiniLM HuggingFace cache blob at
    /// `extras/hf_cache/hub/models--…/blobs/<hash>` — a file at path-depth 6.
    /// Stat'ing it requires descending INTO `blobs` (path-depth 5), which the
    /// gate `depth < maxDepth` only allows at maxDepth ≥ 5. Seven adds two
    /// levels of headroom for a future nested dynamic store; the 50k-entry
    /// `maxScannedEntries` budget remains the real terminator, so the deeper
    /// bound cannot blow up a launch tick.
    public static let defaultMaxDepth = 7

    public static func scan(
        dataRoot: URL,
        maxDepth: Int = defaultMaxDepth,
        singleFileThreshold: Int64 = defaultSingleFileThreshold,
        totalThreshold: Int64 = defaultTotalThreshold,
        maxScannedEntries: Int = defaultMaxScannedEntries
    ) -> DiskHygieneReport {
        let fm = FileManager.default
        var total: Int64 = 0
        var offenders: [DiskHygieneOffender] = []
        var scanned = 0
        var truncated = false
        var depthTruncated = false

        func walk(_ dir: URL, depth: Int) {
            guard !truncated,
                  let entries = try? fm.contentsOfDirectory(
                at: dir,
                includingPropertiesForKeys: [.isDirectoryKey, .isRegularFileKey, .fileSizeKey, .isSymbolicLinkKey],
                options: []
            ) else { return }
            for entry in entries {
                scanned += 1
                if scanned > maxScannedEntries { truncated = true; return }
                let values = try? entry.resourceValues(forKeys: [
                    .isDirectoryKey, .isRegularFileKey, .fileSizeKey, .isSymbolicLinkKey,
                ])
                if values?.isSymbolicLink == true { continue }
                if values?.isDirectory == true {
                    if depth < maxDepth {
                        walk(entry, depth: depth + 1)
                    } else {
                        // A real directory sat past the depth bound — its files
                        // are UNSCANNED, so flag it rather than silently
                        // undercounting and reading as a clean bill.
                        depthTruncated = true
                    }
                    continue
                }
                if values?.isRegularFile == true {
                    let size = Int64(values?.fileSize ?? 0)
                    total += size
                    if size > singleFileThreshold {
                        offenders.append(DiskHygieneOffender(
                            relativePath: relativePath(of: entry, under: dataRoot),
                            sizeBytes: size
                        ))
                    }
                }
            }
        }

        if fm.fileExists(atPath: dataRoot.path) {
            walk(dataRoot, depth: 0)
        }
        offenders.sort { $0.sizeBytes > $1.sizeBytes }
        return DiskHygieneReport(
            largeFiles: offenders,
            totalBytes: total,
            totalOverBudget: total > totalThreshold,
            truncated: truncated,
            depthTruncated: depthTruncated
        )
    }

    /// `entry`'s path relative to `root`, falling back to the last path
    /// component when it is not under `root` (never leaks the absolute path).
    static func relativePath(of entry: URL, under root: URL) -> String {
        let rootParts = root.standardizedFileURL.pathComponents
        let entryParts = entry.standardizedFileURL.pathComponents
        guard entryParts.count > rootParts.count,
              Array(entryParts.prefix(rootParts.count)) == rootParts else {
            return entry.lastPathComponent
        }
        return entryParts.dropFirst(rootParts.count).joined(separator: "/")
    }

    // MARK: - Cleanup (user-initiated only)

    /// Relative-path prefixes the cleanup pass refuses to touch even when a
    /// file under them trips the size threshold. These are wanted permanent
    /// stores — trashing the MiniLM embedder blob would only force a
    /// re-download.
    public static let protectedRelativePrefixes = ["extras/hf_cache"]

    /// What happened to one requested path during a cleanup pass.
    public struct CleanupOutcome: Sendable, Equatable {
        public let relativePath: String
        public let sizeBytes: Int64
        /// nil = moved to the Trash; non-nil = skipped, with the reason.
        public let skippedReason: String?

        public init(relativePath: String, sizeBytes: Int64, skippedReason: String?) {
            self.relativePath = relativePath
            self.sizeBytes = sizeBytes
            self.skippedReason = skippedReason
        }
    }

    /// The result of one user-initiated cleanup pass.
    public struct CleanupResult: Sendable, Equatable {
        public let outcomes: [CleanupOutcome]

        public init(outcomes: [CleanupOutcome]) { self.outcomes = outcomes }

        public var trashed: [CleanupOutcome] { outcomes.filter { $0.skippedReason == nil } }
        public var skipped: [CleanupOutcome] { outcomes.filter { $0.skippedReason != nil } }
        public var freedBytes: Int64 { trashed.reduce(0) { $0 + $1.sizeBytes } }
    }

    /// Move the given dataRoot-relative files to the Trash (reversible — never a
    /// hard delete). ONLY ever called from an explicit user action (the inbox
    /// card's "Clean Up" button); no background loop invokes this. Guards:
    /// a path that resolves outside `dataRoot`, a protected store, a missing
    /// file, or anything that isn't a regular file is skipped with a reason,
    /// never trashed. `trash` is injectable for tests; the default is
    /// `FileManager.trashItem`.
    public static func cleanup(
        dataRoot: URL,
        relativePaths: [String],
        trash: (URL) throws -> Void = { url in
            try FileManager.default.trashItem(at: url, resultingItemURL: nil)
        }
    ) -> CleanupResult {
        let fm = FileManager.default
        let rootParts = dataRoot.standardizedFileURL.pathComponents
        // Symlink-resolved root for the second containment check below. (On
        // macOS the temp/home trees are full of benign aliases like
        // /var → /private/var, so BOTH sides must be resolved consistently.)
        let resolvedRootParts = dataRoot.standardizedFileURL
            .resolvingSymlinksInPath().pathComponents
        var outcomes: [CleanupOutcome] = []
        for rel in relativePaths {
            let candidate = dataRoot.appendingPathComponent(rel).standardizedFileURL
            let size = (try? candidate.resourceValues(forKeys: [.fileSizeKey]).fileSize)
                .map(Int64.init) ?? 0
            func skip(_ reason: String) {
                outcomes.append(CleanupOutcome(
                    relativePath: rel, sizeBytes: size, skippedReason: reason))
            }
            // Containment, twice (gpt-5.5 review BLOCKING): (1) lexically —
            // refuse absolute inputs outright (appendPathComponent would
            // splice them INSIDE the root, silently changing the target) and
            // `..` traversal; (2) symlink-resolved — a symlinked PARENT
            // component under dataRoot must not smuggle the real target
            // outside it. The trash below operates on the resolved path, so
            // what was verified is what moves. Residual check-to-move race is
            // accepted: the inputs come from our own scan of the app's own
            // data root, and an actor who can swap directories for symlinks
            // there already owns the data outright.
            let parts = candidate.pathComponents
            guard !rel.hasPrefix("/"),
                  parts.count > rootParts.count,
                  Array(parts.prefix(rootParts.count)) == rootParts else {
                skip("outside the data directory")
                continue
            }
            // Leaf symlink check on the UNRESOLVED path — after resolution the
            // link is indistinguishable from its target, and trashing a link's
            // target is not what "skip symlinks" means.
            if (try? candidate.resourceValues(forKeys: [.isSymbolicLinkKey]))?
                .isSymbolicLink == true {
                skip("not a regular file")
                continue
            }
            let resolved = candidate.resolvingSymlinksInPath()
            let resolvedParts = resolved.pathComponents
            guard resolvedParts.count > resolvedRootParts.count,
                  Array(resolvedParts.prefix(resolvedRootParts.count)) == resolvedRootParts else {
                skip("outside the data directory")
                continue
            }
            // Case-folded protected-prefix compare (gpt-5.5 review: APFS is
            // typically case-insensitive, so `Extras/HF_Cache/…` addresses the
            // protected store while dodging a case-sensitive prefix match).
            let normalizedRel = parts.dropFirst(rootParts.count)
                .joined(separator: "/").lowercased()
            if protectedRelativePrefixes.contains(where: {
                let p = $0.lowercased()
                return normalizedRel == p || normalizedRel.hasPrefix(p + "/")
            }) {
                skip("protected store (model cache — would just re-download)")
                continue
            }
            let values = try? resolved.resourceValues(forKeys: [.isRegularFileKey])
            guard values?.isRegularFile == true else {
                skip(fm.fileExists(atPath: resolved.path)
                    ? "not a regular file" : "already gone")
                continue
            }
            do {
                try trash(resolved)
                outcomes.append(CleanupOutcome(
                    relativePath: rel, sizeBytes: size, skippedReason: nil))
            } catch {
                skip("could not move to Trash: \(error.localizedDescription)")
            }
        }
        return CleanupResult(outcomes: outcomes)
    }

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

/// Once-per-day disk-hygiene watchdog. Walks `dataRoot`, and when a single file
/// is oversized or the whole tree is over budget, files ONE notification-inbox
/// card listing the offenders. NEVER deletes anything.
///
/// Dependency-clean: the inbox write is an injected closure (BackgroundLoops
/// does not depend on NotificationInbox) — the assembly wires it to the same
/// `notifications/inbox.jsonl` upsert path HeartbeatLoop uses. The daily
/// reservation runs through the shared `reserveOncePerPeriod` primitive so a
/// BGTask wake and the in-app scheduler cannot double-run it the same day.
public struct DataRootDiskHygieneCheck: LoopRunner {
    public let loopId: String = "data_root_disk_hygiene"
    public let interval: TimeInterval
    public var tickTimeoutOverride: TimeInterval? { 120 }

    private let dataRoot: URL
    private let clock: @Sendable () -> Date
    private let maxDepth: Int
    private let singleFileThreshold: Int64
    private let totalThreshold: Int64
    /// Files ONE inbox card for the tripped report; returns whether the card
    /// actually landed. Injected so this module gains no NotificationInbox
    /// dependency. A `false` return rolls back the daily reservation so the
    /// next tick retries — a tripped scan whose notice failed must not count
    /// as "ran today" (gpt-5.5 fix round).
    private let fileNotice: @Sendable (DiskHygieneReport) async -> Bool

    public init(
        interval: TimeInterval = 24 * 60 * 60,
        dataRoot: URL = PersistenceCore.defaultDataRoot(),
        clock: @escaping @Sendable () -> Date = { Date() },
        maxDepth: Int = DataRootDiskHygiene.defaultMaxDepth,
        singleFileThreshold: Int64 = DataRootDiskHygiene.defaultSingleFileThreshold,
        totalThreshold: Int64 = DataRootDiskHygiene.defaultTotalThreshold,
        fileNotice: @escaping @Sendable (DiskHygieneReport) async -> Bool
    ) {
        self.interval = interval
        self.dataRoot = dataRoot
        self.clock = clock
        self.maxDepth = maxDepth
        self.singleFileThreshold = singleFileThreshold
        self.totalThreshold = totalThreshold
        self.fileNotice = fileNotice
    }

    /// Day bucket (UTC yyyy-MM-dd) used as the reservation key so the scan runs
    /// at most once per calendar day across every driver.
    static func dayKey(_ date: Date) -> String {
        let f = DateFormatter()
        f.calendar = Calendar(identifier: .gregorian)
        f.locale = Locale(identifier: "en_US_POSIX")
        f.timeZone = TimeZone(identifier: "UTC")
        f.dateFormat = "yyyy-MM-dd"
        return f.string(from: date)
    }

    public func tickOutcome() async -> LoopTickOutcome {
        let now = clock()
        let marker = dataRoot
            .appendingPathComponent("logs", isDirectory: true)
            .appendingPathComponent("disk_hygiene_last_run")
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
            totalThreshold: totalThreshold
        )
        guard report.tripped else {
            return .completed(result: "disk clean (\(DataRootDiskHygiene.humanSize(report.totalBytes)))"
                + (report.truncated ? " [scan truncated at file budget]" : "")
                + (report.depthTruncated ? " [depth-truncated: a store past maxDepth is unscanned]" : ""))
        }
        // Day counts as consumed only when the notice actually landed —
        // otherwise roll back so the next tick retries the delivery.
        let delivered = await fileNotice(report)
        guard delivered else {
            await rollback()
            return .failed(error: "disk hygiene notice delivery failed; reservation rolled back")
        }
        return .completed(result:
            "disk hygiene flagged \(report.largeFiles.count) large file(s), "
            + "total \(DataRootDiskHygiene.humanSize(report.totalBytes))"
            + (report.truncated ? " [scan truncated at file budget]" : "")
            + (report.depthTruncated ? " [depth-truncated: a store past maxDepth is unscanned]" : ""))
    }
}
