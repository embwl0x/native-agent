import Foundation
import PersistenceCore

// A5.5 (2026-07-24): the two piles the daily disk-hygiene watchdog can only
// POINT AT — it is detect-never-delete by design — finally get an owner.
//
//   (a) `data/context/<runId>.json` — per-turn context receipts written by the
//       RETIRED Python daemon. 646 files / ~35MB at HEAD, every one of them
//       stamped May 26 – Jun 2 2026, i.e. nothing has written one since the
//       Swift-native cutover. NOTHING reaps them.
//   (b) `*.bak*` manual/automatic backups scattered across the data root —
//       PersonaEngine `.pre-<ts>-<uid>.bak` copies, RunLedger `.corrupt-*.bak`
//       forensics, Onboarding `.pre-reset-*.bak`, plus a month of hand-made
//       pre-migration snapshots. PersonaEngine bounds ITS OWN accumulation at
//       the source (A5.5(c), PersonaEngine+GrowthVoiceWrites.swift:364) — this
//       is the sweep for the historical backlog and for every other writer.
//
// SAFETY POSTURE. This is the only maintenance step in the repo that removes a
// file whose lifetime is not encoded in its own NAME (TurnTraceRetention deletes
// `<yyyy-MM-dd>.jsonl` — the name IS the expiry). So it carries three extra
// belts that the date-named sweeps do not need:
//
//   1. REPORT-ONLY BY DEFAULT. `isEnabled` is read from a UserDefaults key that
//      is unset on a fresh install, so the tick PLANS and files a receipt for
//      what it WOULD remove, and removes nothing. Same posture as GoldenEvalLoop
//      (which is off-by-default because it spends tokens); this one is
//      off-by-default because it spends files.
//   2. FAIL-CLOSED ON A BLIND JOIN. The orphan test is a join against the chat
//      store. If that store cannot be read — or reads as suspiciously empty
//      while receipt candidates exist — the receipt leg REFUSES to plan and says
//      why. A half-read reference set would classify LIVE receipts as orphans.
//   3. ARCHIVE-THEN-DELETE for backups. `.bak` files move to
//      `<dataRoot>/archive/stale_backups/<relpath>` (the same `archive/`
//      convention WorkshopStorageMigrator.swift:157 and
//      ChatSessionRetention.swift:264 already use) rather than vanishing. A
//      persona snapshot is not a debugging artifact; being wrong about one is
//      unrecoverable. Orphan RECEIPTS are deleted outright — they are
//      dead-daemon telemetry, they are the 35MB the sweep exists to reclaim,
//      and archiving them would move the pile rather than clear it.

// MARK: - Report types

/// One artifact the sweep planned to remove (or did remove).
public struct SweptArtifact: Sendable, Equatable {
    /// Path relative to `dataRoot` — never the absolute home-directory path.
    public let relativePath: String
    public let sizeBytes: Int64
    public let modifiedAt: Date
    /// Why this file was selected. Goes verbatim into the receipt line.
    public let reason: String
    /// Destination relative path when the disposition is archive-then-delete;
    /// nil when the file is deleted outright.
    public let archivedTo: String?

    public init(
        relativePath: String,
        sizeBytes: Int64,
        modifiedAt: Date,
        reason: String,
        archivedTo: String? = nil
    ) {
        self.relativePath = relativePath
        self.sizeBytes = sizeBytes
        self.modifiedAt = modifiedAt
        self.reason = reason
        self.archivedTo = archivedTo
    }
}

/// What one planning pass decided. Nothing here has touched the disk yet.
public struct StaleArtifactSweepPlan: Sendable, Equatable {
    /// `data/context/<uuid>.json` files with no live reference, past the grace
    /// window. EMPTY whenever `receiptsBlockedReason` is non-nil.
    public var orphanReceipts: [SweptArtifact]
    /// `*.bak*` files past the backup grace window.
    public var staleBackups: [SweptArtifact]
    /// Non-nil when the orphan-receipt leg refused to plan (fail-closed). The
    /// backup leg is independent and still plans normally.
    public var receiptsBlockedReason: String?
    /// How many distinct runIds the chat-store join resolved. Surfaced so a
    /// receipt reader can sanity-check the join rather than trusting it.
    public var referencedRunIDCount: Int
    /// True when the per-tick removal cap truncated the plan — the remainder is
    /// picked up next tick. Never silent (`no_silent_caps`).
    public var capped: Bool
    /// True when the backup walk could not enumerate a subtree or ran out of
    /// entry budget — counts below may under-report (`no_silent_caps`).
    public var backupScanPartial: Bool

    public init(
        orphanReceipts: [SweptArtifact] = [],
        staleBackups: [SweptArtifact] = [],
        receiptsBlockedReason: String? = nil,
        referencedRunIDCount: Int = 0,
        capped: Bool = false,
        backupScanPartial: Bool = false
    ) {
        self.orphanReceipts = orphanReceipts
        self.staleBackups = staleBackups
        self.receiptsBlockedReason = receiptsBlockedReason
        self.referencedRunIDCount = referencedRunIDCount
        self.capped = capped
        self.backupScanPartial = backupScanPartial
    }

    public var isEmpty: Bool { orphanReceipts.isEmpty && staleBackups.isEmpty }
    public var totalCount: Int { orphanReceipts.count + staleBackups.count }
    public var totalBytes: Int64 {
        (orphanReceipts + staleBackups).reduce(0) { $0 + $1.sizeBytes }
    }
}

/// Why the orphan-receipt leg refused to plan. Every case means "the reference
/// set could not be PROVEN complete", and the only safe response to an unproven
/// reference set is to delete nothing.
public enum ReceiptJoinRefusal: Error, Sendable, Equatable {
    /// `<dataRoot>/chat` is absent — the join has no left-hand side at all.
    case chatStoreMissing
    /// A chat store file exists but could not be enumerated/read.
    case chatStoreUnreadable(String)
    /// The chat store resolved ZERO runIds while receipt candidates exist. On a
    /// real install this shape is indistinguishable from "the scan went blind",
    /// so it is treated as blindness.
    case referenceSetSuspiciouslyEmpty(candidates: Int)

    public var receiptReason: String {
        switch self {
        case .chatStoreMissing:
            return "chat store missing — cannot prove which receipts are live"
        case .chatStoreUnreadable(let detail):
            return "chat store unreadable (\(detail)) — cannot prove which receipts are live"
        case .referenceSetSuspiciouslyEmpty(let candidates):
            return "chat store resolved 0 runIds while \(candidates) receipt candidate(s) exist "
                + "— treating as a blind scan, not as universal orphanhood"
        }
    }
}

// MARK: - Pure engine

public enum StaleArtifactSweep {
    /// Grace window for a context receipt. A receipt younger than this is kept
    /// EVEN IF unreferenced: the chat store is tailed, sessions get archived,
    /// and a receipt written moments before its message row lands would
    /// otherwise be a live-write race.
    public static let defaultReceiptGraceDays = 14
    /// Grace window for a backup file. Every in-repo `.bak` writer makes its
    /// copy immediately before a destructive edit, so a month is far past any
    /// "I need to undo that" window while still leaving the newest snapshots
    /// PersonaEngine deliberately retains untouched.
    public static let defaultBackupGraceDays = 30
    /// Removals attempted per tick, across both legs. The first real sweep has
    /// ~650 receipts + ~47 backups queued; 200/tick drains it over four days
    /// instead of doing 700 filesystem mutations inside one loop tick.
    public static let defaultMaxPerTick = 200
    /// Recursion bound for the backup walk. Mirrors
    /// `DataRootDiskHygiene.defaultMaxDepth` — the same tree, the same shape.
    public static let defaultMaxDepth = 7
    /// Entry budget for the backup walk, mirroring the hygiene scan's.
    public static let defaultMaxScannedEntries = 50_000

    /// Directory components the backup walk never descends into.
    ///
    /// `archive` is the sweep's OWN destination — descending into it would
    /// re-sweep what a previous tick archived, forever. `workshop` is excluded
    /// by requirement: it is Agent's live artifact bench, and a `.bak` in there
    /// is a work product, not a leftover.
    static let excludedDirectoryComponents: Set<String> = ["archive", "workshop"]

    /// Relative destination root for archived backups.
    static let backupArchiveDirectory = "archive/stale_backups"

    // MARK: Reference join

    /// Every runId that could resolve a context receipt, lowercased.
    ///
    /// PROVEN AGAINST THE READER, not guessed. `SwiftNativeContextClient` is the
    /// only thing in the tree that opens `<dataRoot>/context/<runId>.json`
    /// (`contextReceiptPath`, Context.swift:272-276), and it derives `runId` from
    /// exactly two places:
    ///
    ///   • `message["runId"]` over the chat message JSONL
    ///     (Context.swift:395-403, reading `chatMessagesPath` =
    ///     `<root>/chat/messages/<sessionId>.jsonl`), and
    ///   • `session["startupContextRunId"]` from `<root>/chat/sessions.json`
    ///     (Context.swift:412-421).
    ///
    /// The receipt store is NOT joined to `context/context.sqlite`. That was the
    /// intuitive guess and it is wrong: `context_receipts.id` is a different
    /// namespace (compile/prewarm receipts kept as ROWS, capped in-table), and
    /// at HEAD its 10,000 ids intersect the 646 receipt filenames in ZERO
    /// places. Joining against sqlite would have declared every single receipt
    /// an orphan for the wrong reason.
    ///
    /// This scan is deliberately WIDER than the reader:
    ///   • the reader tails the newest 80 messages per session; this reads every
    ///     line of every message file,
    ///   • the reader only looks at the requested session; this reads all of
    ///     them, including `chat/archive/`,
    ///   • the reader only consults `startupContextRunId`; this also harvests any
    ///     `runId`/`contextRunId` key it finds in the session rows.
    /// Wider is the safe direction: a runId this scan collects but the reader
    /// would never ask for merely spares a file.
    ///
    /// Lowercased on both sides because live runIds are UPPERCASE UUIDs while
    /// the daemon-era filenames are lowercase, and the receipt path is opened on
    /// a case-insensitive APFS volume — so a case-sensitive comparison here
    /// could call a reachable file an orphan.
    public static func referencedRunIDs(dataRoot: URL, candidatesExist: Bool = true) throws -> Set<String> {
        let fm = FileManager.default
        let chatRoot = dataRoot.appendingPathComponent("chat", isDirectory: true)
        var isDir: ObjCBool = false
        guard fm.fileExists(atPath: chatRoot.path, isDirectory: &isDir), isDir.boolValue else {
            throw ReceiptJoinRefusal.chatStoreMissing
        }

        var referenced: Set<String> = []

        func harvest(_ value: Any?) {
            // Python-truthy coercion parity with `Self.coercedString` at the
            // reader (Context.swift:398): an int runId is stringified there, so
            // it must be stringified here too.
            switch value {
            case let s as String where !s.isEmpty: referenced.insert(s.lowercased())
            case let n as NSNumber: referenced.insert("\(n)".lowercased())
            default: break
            }
        }

        func harvestObject(_ any: Any) {
            guard let obj = any as? [String: Any] else { return }
            harvest(obj["runId"])
            harvest(obj["startupContextRunId"])
            harvest(obj["contextRunId"])
        }

        /// Read a JSONL file line-by-line, harvesting every row's runId keys.
        func harvestJSONL(_ url: URL) throws {
            guard fm.fileExists(atPath: url.path) else { return }
            let data: Data
            do {
                data = try Data(contentsOf: url, options: [.mappedIfSafe])
            } catch {
                throw ReceiptJoinRefusal.chatStoreUnreadable(
                    "\(url.lastPathComponent): \(error)")
            }
            let lines = data.split(separator: 0x0A, omittingEmptySubsequences: true)
            for (index, line) in lines.enumerated() {
                guard let row = try? JSONSerialization.jsonObject(with: Data(line)) else {
                    // gpt-5.5 BLOCKING (2026-07-24): a malformed line means the
                    // reference set may be PARTIAL — and a partial-but-nonzero
                    // join deletes. Refuse the whole receipt leg. The single
                    // tolerated shape is a malformed FINAL line: that is the
                    // torn-append signature of a crash mid-write, and the rows
                    // before it are intact.
                    if index == lines.count - 1 { continue }
                    throw ReceiptJoinRefusal.chatStoreUnreadable(
                        "\(url.lastPathComponent): malformed row \(index + 1) of \(lines.count) — reference set would be partial")
                }
                harvestObject(row)
            }
        }

        func harvestJSONLDirectory(_ dir: URL, required: Bool) throws {
            guard fm.fileExists(atPath: dir.path) else {
                // gpt-5.5 BLOCKING (2026-07-24): an ABSENT directory is not the
                // same as "legitimately no messages" — a half-mounted or
                // mid-migration store must not read as empty while receipts sit
                // in the candidate set. The caller only marks a directory
                // required when candidates exist, so a fresh install (no
                // receipts, no chat yet) never trips this.
                if required {
                    throw ReceiptJoinRefusal.chatStoreUnreadable(
                        "\(dir.lastPathComponent)/ is missing — refusing a possibly partial reference set")
                }
                return
            }
            let entries: [URL]
            do {
                entries = try fm.contentsOfDirectory(
                    at: dir, includingPropertiesForKeys: nil, options: [.skipsHiddenFiles])
            } catch {
                throw ReceiptJoinRefusal.chatStoreUnreadable("\(dir.lastPathComponent)/: \(error)")
            }
            for entry in entries where entry.pathExtension == "jsonl" {
                try harvestJSONL(entry)
            }
        }

        // 1. Live + archived per-session message logs. `messages/` is REQUIRED
        //    whenever receipt candidates exist; `archive/messages/` is required
        //    only when a `chat/archive/` tree exists at all — an install that
        //    never archived a session legitimately has no archive, but an
        //    archive root WITHOUT its messages dir is the half-migrated shape
        //    that must refuse.
        try harvestJSONLDirectory(
            chatRoot.appendingPathComponent("messages", isDirectory: true),
            required: candidatesExist)
        let archiveRoot = chatRoot.appendingPathComponent("archive", isDirectory: true)
        try harvestJSONLDirectory(
            archiveRoot.appendingPathComponent("messages", isDirectory: true),
            required: candidatesExist && fm.fileExists(atPath: archiveRoot.path))

        // 2. The session index (an ARRAY of session objects at HEAD; tolerate a
        //    {"sessions": [...]} envelope too rather than silently harvesting
        //    nothing if the shape ever changes).
        let sessionsPath = chatRoot.appendingPathComponent("sessions.json")
        if fm.fileExists(atPath: sessionsPath.path) {
            let data: Data
            do {
                data = try Data(contentsOf: sessionsPath, options: [.mappedIfSafe])
            } catch {
                throw ReceiptJoinRefusal.chatStoreUnreadable("sessions.json: \(error)")
            }
            guard let parsed = try? JSONSerialization.jsonObject(with: data) else {
                // sessions.json EXISTS but does not parse. That is exactly the
                // blind-scan case — refuse rather than proceed with a partial
                // reference set.
                throw ReceiptJoinRefusal.chatStoreUnreadable("sessions.json does not parse")
            }
            let rows: [Any]
            if let array = parsed as? [Any] {
                rows = array
            } else if let obj = parsed as? [String: Any], let array = obj["sessions"] as? [Any] {
                rows = array
            } else {
                rows = []
            }
            for row in rows { harvestObject(row) }
        }

        // 3. Archived session index.
        try harvestJSONL(
            chatRoot
                .appendingPathComponent("archive", isDirectory: true)
                .appendingPathComponent("sessions.jsonl"))

        return referenced
    }

    // MARK: Matchers

    /// `<uuid>.json` — the exact shape the daemon minted. Anything else in
    /// `context/` (context.sqlite, the cache/ evals/ feedback/ hints/ subdirs,
    /// a hand-dropped note) is never a candidate. Never guess at a filename.
    static let receiptNameRegex = try! NSRegularExpression(
        pattern: "^[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12}\\.json$"
    )

    static func isReceiptFileName(_ name: String) -> Bool {
        receiptNameRegex.firstMatch(
            in: name, range: NSRange(name.startIndex..., in: name)) != nil
    }

    /// True when `name` is a backup artifact this sweep may take.
    ///
    /// The rule is deliberately literal: the name must CONTAIN `.bak`. That one
    /// requirement is what makes the "never touch a live store" guarantee
    /// structural rather than list-based — no live store in the tree has `.bak`
    /// in its filename, so `context.sqlite`, its `-wal`/`-shm` sidecars,
    /// `memory.sqlite`, `sessions.json`, and every JSONL feed are unmatchable by
    /// construction. It covers all three in-tree naming conventions:
    ///   `X.bak`, `X.bak.<suffix>`, `X.pre-<ts>-<uid>.bak`.
    ///
    /// The explicit `-wal`/`-shm`/`.lock` exclusions below are belt-and-braces
    /// for a hypothetical `foo.bak-wal`: they cannot fire today, and they are
    /// cheap insurance against a future writer that pairs the two conventions.
    static func isBackupFileName(_ name: String) -> Bool {
        // `.bak` must be a complete dot-separated SEGMENT (`X.bak`,
        // `X.bak.old`, `X.pre-reset.bak`) — a bare substring test would also
        // match a hypothetical live file like `profile.baked.json` (gpt-5.5
        // NIT, 2026-07-24).
        guard name.hasSuffix(".bak") || name.contains(".bak.") else { return false }
        if name.hasSuffix(".lock") { return false }
        if name.contains("-wal") || name.contains("-shm") { return false }
        return true
    }

    // MARK: Planning

    /// Decide what to sweep. Pure with respect to `dataRoot` — reads only.
    ///
    /// The two legs are INDEPENDENT: a refused receipt join still lets the
    /// backup leg plan, because the backup leg's safety does not depend on the
    /// chat store.
    public static func plan(
        dataRoot: URL,
        now: Date = Date(),
        receiptGraceDays: Int = defaultReceiptGraceDays,
        backupGraceDays: Int = defaultBackupGraceDays,
        maxPerTick: Int = defaultMaxPerTick,
        maxDepth: Int = defaultMaxDepth,
        maxScannedEntries: Int = defaultMaxScannedEntries
    ) -> StaleArtifactSweepPlan {
        var plan = StaleArtifactSweepPlan()
        let receiptCutoff = now.addingTimeInterval(-Double(max(1, receiptGraceDays)) * 86_400)
        let backupCutoff = now.addingTimeInterval(-Double(max(1, backupGraceDays)) * 86_400)

        // --- Leg (a): orphan context receipts -------------------------------
        let receiptCandidates = contextReceiptCandidates(dataRoot: dataRoot, cutoff: receiptCutoff)
        do {
            let referenced = try referencedRunIDs(
                dataRoot: dataRoot,
                candidatesExist: !receiptCandidates.isEmpty)
            plan.referencedRunIDCount = referenced.count
            if referenced.isEmpty && !receiptCandidates.isEmpty {
                throw ReceiptJoinRefusal.referenceSetSuspiciouslyEmpty(
                    candidates: receiptCandidates.count)
            }
            for candidate in receiptCandidates {
                let runID = String(candidate.name.dropLast(".json".count)).lowercased()
                guard !referenced.contains(runID) else { continue }
                plan.orphanReceipts.append(SweptArtifact(
                    relativePath: "context/\(candidate.name)",
                    sizeBytes: candidate.size,
                    modifiedAt: candidate.modified,
                    reason: "orphan_context_receipt: no runId reference in the chat store "
                        + "and older than \(receiptGraceDays)d",
                    archivedTo: nil
                ))
            }
        } catch let refusal as ReceiptJoinRefusal {
            plan.orphanReceipts = []
            plan.receiptsBlockedReason = refusal.receiptReason
        } catch {
            plan.orphanReceipts = []
            plan.receiptsBlockedReason = "chat store join failed: \(error)"
        }

        // --- Leg (b): stale backups -----------------------------------------
        let backupScan = backupCandidates(
            dataRoot: dataRoot,
            cutoff: backupCutoff,
            maxDepth: maxDepth,
            maxScannedEntries: maxScannedEntries
        )
        plan.backupScanPartial = backupScan.partial
        for candidate in backupScan.candidates {
            plan.staleBackups.append(SweptArtifact(
                relativePath: candidate.relativePath,
                sizeBytes: candidate.size,
                modifiedAt: candidate.modified,
                reason: "stale_backup: manual/automatic *.bak copy older than \(backupGraceDays)d",
                archivedTo: "\(backupArchiveDirectory)/\(candidate.relativePath)"
            ))
        }

        // Oldest first in both legs, so a capped tick drains deterministically
        // from the far end rather than re-picking whatever the FS enumerates
        // first.
        plan.orphanReceipts.sort { $0.modifiedAt < $1.modifiedAt }
        plan.staleBackups.sort { $0.modifiedAt < $1.modifiedAt }

        // Cap ACROSS both legs. Backups are archived (recoverable) and few;
        // receipts are deleted and many — so backups take the budget first and
        // receipts absorb the truncation.
        let cap = max(0, maxPerTick)
        if plan.totalCount > cap {
            plan.capped = true
            let backupTake = min(plan.staleBackups.count, cap)
            plan.staleBackups = Array(plan.staleBackups.prefix(backupTake))
            plan.orphanReceipts = Array(plan.orphanReceipts.prefix(cap - backupTake))
        }
        return plan
    }

    // MARK: Candidate enumeration

    struct Candidate {
        let url: URL
        let name: String
        let relativePath: String
        let size: Int64
        let modified: Date
    }

    /// Regular `<uuid>.json` files directly inside `<dataRoot>/context`, older
    /// than `cutoff`. Non-recursive on purpose: the daemon only ever wrote them
    /// flat, and the subdirectories (`cache/`, `evals/`, `feedback/`, `hints/`)
    /// belong to live subsystems.
    static func contextReceiptCandidates(dataRoot: URL, cutoff: Date) -> [Candidate] {
        let fm = FileManager.default
        let dir = dataRoot.appendingPathComponent("context", isDirectory: true)
        guard let entries = try? fm.contentsOfDirectory(
            at: dir,
            includingPropertiesForKeys: [
                .isRegularFileKey, .fileSizeKey, .contentModificationDateKey, .isSymbolicLinkKey,
            ],
            options: [.skipsHiddenFiles]
        ) else { return [] }
        var out: [Candidate] = []
        for entry in entries {
            let name = entry.lastPathComponent
            guard isReceiptFileName(name) else { continue }
            guard let values = try? entry.resourceValues(forKeys: [
                .isRegularFileKey, .fileSizeKey, .contentModificationDateKey, .isSymbolicLinkKey,
            ]), values.isSymbolicLink != true, values.isRegularFile == true,
                let modified = values.contentModificationDate else { continue }
            guard modified < cutoff else { continue }
            out.append(Candidate(
                url: entry,
                name: name,
                relativePath: "context/\(name)",
                size: Int64(values.fileSize ?? 0),
                modified: modified
            ))
        }
        return out
    }

    /// Every `*.bak*` regular file under `dataRoot` older than `cutoff`,
    /// skipping the excluded directory components. Symlinks are never followed
    /// and never taken.
    static func backupCandidates(
        dataRoot: URL,
        cutoff: Date,
        maxDepth: Int,
        maxScannedEntries: Int
    ) -> (candidates: [Candidate], partial: Bool) {
        let fm = FileManager.default
        guard fm.fileExists(atPath: dataRoot.path) else { return ([], false) }
        var out: [Candidate] = []
        var scanned = 0
        var budgetExhausted = false
        // gpt-5.5 NIT (2026-07-24): an unreadable subtree or an exhausted entry
        // budget truncates DISCOVERY — the summary must say the scan was
        // partial, or a low count reads as "clean".
        var partial = false

        func walk(_ dir: URL, depth: Int) {
            guard !budgetExhausted else { return }
            guard let entries = try? fm.contentsOfDirectory(
                at: dir,
                includingPropertiesForKeys: [
                    .isDirectoryKey, .isRegularFileKey, .fileSizeKey,
                    .contentModificationDateKey, .isSymbolicLinkKey,
                ],
                options: []
            ) else {
                partial = true
                return
            }
            for entry in entries {
                scanned += 1
                if scanned > maxScannedEntries {
                    budgetExhausted = true
                    partial = true
                    return
                }
                guard let values = try? entry.resourceValues(forKeys: [
                    .isDirectoryKey, .isRegularFileKey, .fileSizeKey,
                    .contentModificationDateKey, .isSymbolicLinkKey,
                ]) else { continue }
                if values.isSymbolicLink == true { continue }
                if values.isDirectory == true {
                    guard !excludedDirectoryComponents.contains(entry.lastPathComponent) else {
                        continue
                    }
                    if depth < maxDepth { walk(entry, depth: depth + 1) }
                    continue
                }
                guard values.isRegularFile == true else { continue }
                guard isBackupFileName(entry.lastPathComponent) else { continue }
                guard let modified = values.contentModificationDate, modified < cutoff else {
                    continue
                }
                out.append(Candidate(
                    url: entry,
                    name: entry.lastPathComponent,
                    relativePath: DataRootDiskHygiene.relativePath(of: entry, under: dataRoot),
                    size: Int64(values.fileSize ?? 0),
                    modified: modified
                ))
            }
        }
        walk(dataRoot, depth: 0)
        return (out, partial)
    }

    // MARK: Apply

    /// Carry out one planned removal. Returns the artifact with its FINAL
    /// disposition (the archive destination can shift on a name collision), or
    /// throws so the caller records a failure instead of a phantom receipt.
    ///
    /// Archive-then-delete is a RENAME, so an interrupted apply leaves the file
    /// at exactly one of the two paths — never at neither.
    static func apply(_ artifact: SweptArtifact, dataRoot: URL) throws -> SweptArtifact {
        let fm = FileManager.default
        let source = dataRoot.appendingPathComponent(artifact.relativePath)
        guard fm.fileExists(atPath: source.path) else {
            // Vanished between plan and apply (a concurrent sweep, or a human).
            // Not an error — but not a receipt-worthy removal either.
            throw SweepApplyOutcome.alreadyGone
        }
        // gpt-5.5 BLOCKING (2026-07-24): revalidate the exact file the PLAN
        // classified before mutating. If the path was replaced after planning
        // (new regular file, symlink, different bytes/mtime), the plan's
        // verdict — including the grace window — no longer applies to what is
        // on disk now. Drift is a SKIP, never a delete.
        guard let values = try? source.resourceValues(forKeys: [
            .isRegularFileKey, .isSymbolicLinkKey, .fileSizeKey, .contentModificationDateKey,
        ]),
            values.isRegularFile == true,
            values.isSymbolicLink != true,
            Int64(values.fileSize ?? -1) == artifact.sizeBytes,
            let modified = values.contentModificationDate,
            abs(modified.timeIntervalSince(artifact.modifiedAt)) < 1.0
        else {
            throw SweepApplyOutcome.driftedSincePlan
        }
        guard let archiveRelative = artifact.archivedTo else {
            try fm.removeItem(at: source)
            return artifact
        }
        var destination = dataRoot.appendingPathComponent(archiveRelative)
        try fm.createDirectory(
            at: destination.deletingLastPathComponent(), withIntermediateDirectories: true)
        var finalRelative = archiveRelative
        var suffix = 1
        while fm.fileExists(atPath: destination.path) {
            finalRelative = "\(archiveRelative).\(suffix)"
            destination = dataRoot.appendingPathComponent(finalRelative)
            suffix += 1
            if suffix > 1000 { throw SweepApplyOutcome.archiveDestinationExhausted }
        }
        try fm.moveItem(at: source, to: destination)
        return SweptArtifact(
            relativePath: artifact.relativePath,
            sizeBytes: artifact.sizeBytes,
            modifiedAt: artifact.modifiedAt,
            reason: artifact.reason,
            archivedTo: finalRelative
        )
    }

    enum SweepApplyOutcome: Error, Sendable {
        case alreadyGone
        case archiveDestinationExhausted
        /// The on-disk file no longer matches the planned type/size/mtime —
        /// mutating it would apply a stale verdict to a different file.
        case driftedSincePlan
    }

    // MARK: Receipt rendering

    /// Built per call rather than cached in a `static let`: `ISO8601DateFormatter`
    /// is not `Sendable`, and a sweep emits at most a few hundred lines a day —
    /// there is nothing to amortize.
    static func receiptTimestamp(_ date: Date) -> String {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime]
        f.timeZone = TimeZone(identifier: "UTC")
        return f.string(from: date)
    }

    /// One removal receipt line. Carries path, bytes, mtime and reason as
    /// required, plus the disposition so a reader can tell an archived backup
    /// from a deleted receipt without re-deriving the rule.
    public static func receiptLine(
        for artifact: SweptArtifact,
        at now: Date,
        dryRun: Bool
    ) -> JSONValue {
        .object([
            "at": .string(receiptTimestamp(now)),
            "loop": .string(StaleArtifactSweepLoop.canonicalLoopId),
            "event": .string(dryRun ? "would_remove" : "removed"),
            "dryRun": .bool(dryRun),
            "path": .string(artifact.relativePath),
            "bytes": .int(artifact.sizeBytes),
            "mtime": .string(receiptTimestamp(artifact.modifiedAt)),
            "reason": .string(artifact.reason),
            "disposition": .string(artifact.archivedTo == nil ? "deleted" : "archived"),
            "archivedTo": artifact.archivedTo.map { JSONValue.string($0) } ?? .null,
        ])
    }

    /// The pre-flight line an APPLYING pass writes before it touches anything.
    /// Doubles as the ledger-writability probe and as the "what was about to
    /// happen" anchor a later forensic read can align the removal lines against.
    public static func passStartLine(
        for plan: StaleArtifactSweepPlan,
        at now: Date,
        maxPerTick: Int
    ) -> JSONValue {
        .object([
            "at": .string(receiptTimestamp(now)),
            "loop": .string(StaleArtifactSweepLoop.canonicalLoopId),
            "event": .string("sweep_pass_start"),
            "dryRun": .bool(false),
            "plannedReceipts": .int(Int64(plan.orphanReceipts.count)),
            "plannedBackups": .int(Int64(plan.staleBackups.count)),
            "plannedBytes": .int(plan.totalBytes),
            "maxPerTick": .int(Int64(maxPerTick)),
            "capped": .bool(plan.capped),
            "referencedRunIds": .int(Int64(plan.referencedRunIDCount)),
            "receiptsBlockedReason": plan.receiptsBlockedReason.map { JSONValue.string($0) } ?? .null,
        ])
    }

    /// The per-pass summary line. In report-only mode this is the ONLY line the
    /// pass writes — a daily 700-line "here is what I would have done" dump
    /// would drown the real removal receipts it is meant to precede.
    public static func summaryLine(
        for plan: StaleArtifactSweepPlan,
        at now: Date,
        dryRun: Bool,
        removed: Int,
        reclaimedBytes: Int64,
        failures: [String]
    ) -> JSONValue {
        .object([
            "at": .string(receiptTimestamp(now)),
            "loop": .string(StaleArtifactSweepLoop.canonicalLoopId),
            "event": .string("sweep_pass"),
            "dryRun": .bool(dryRun),
            "plannedReceipts": .int(Int64(plan.orphanReceipts.count)),
            "plannedBackups": .int(Int64(plan.staleBackups.count)),
            "plannedBytes": .int(plan.totalBytes),
            "removed": .int(Int64(removed)),
            "reclaimedBytes": .int(reclaimedBytes),
            "capped": .bool(plan.capped),
            "referencedRunIds": .int(Int64(plan.referencedRunIDCount)),
            "receiptsBlockedReason": plan.receiptsBlockedReason.map { JSONValue.string($0) } ?? .null,
            "failures": .array(failures.map { JSONValue.string($0) }),
        ])
    }
}

// MARK: - Loop runner

/// Daily stale-artifact sweep. REPORT-ONLY unless `isEnabled()` returns true.
///
/// Single-flight through the shared `reserveOncePerPeriod` day reservation, so a
/// BGTask wake and the in-app scheduler cannot double-run it — and, more
/// importantly for a destructive step, cannot interleave two applies over the
/// same plan.
///
/// Dependency-clean in the same way `DataRootDiskHygieneCheck` is: the receipt
/// append is an injected closure, so BackgroundLoops gains no new dependency and
/// tests can capture receipt lines without touching a real JSONL.
public struct StaleArtifactSweepLoop: LoopRunner {
    public static let canonicalLoopId = "stale_artifact_sweep"

    public var loopId: String { Self.canonicalLoopId }
    public let interval: TimeInterval
    public var tickTimeoutOverride: TimeInterval? { 120 }

    private let dataRoot: URL
    private let clock: @Sendable () -> Date
    /// False (the default posture on a fresh install) ⇒ plan and report, remove
    /// nothing.
    private let isEnabled: @Sendable () -> Bool
    private let receiptGraceDays: Int
    private let backupGraceDays: Int
    private let maxPerTick: Int
    /// Appends one receipt line; returns whether it actually landed. A `false`
    /// BEFORE any removal aborts the pass and rolls the day back — a removal
    /// whose receipt cannot be written must not happen at all.
    private let appendReceipt: @Sendable (JSONValue) async -> Bool

    public init(
        interval: TimeInterval = 24 * 60 * 60,
        dataRoot: URL = PersistenceCore.defaultDataRoot(),
        clock: @escaping @Sendable () -> Date = { Date() },
        isEnabled: @escaping @Sendable () -> Bool,
        receiptGraceDays: Int = StaleArtifactSweep.defaultReceiptGraceDays,
        backupGraceDays: Int = StaleArtifactSweep.defaultBackupGraceDays,
        maxPerTick: Int = StaleArtifactSweep.defaultMaxPerTick,
        appendReceipt: @escaping @Sendable (JSONValue) async -> Bool
    ) {
        self.interval = interval
        self.dataRoot = dataRoot
        self.clock = clock
        self.isEnabled = isEnabled
        self.receiptGraceDays = receiptGraceDays
        self.backupGraceDays = backupGraceDays
        self.maxPerTick = maxPerTick
        self.appendReceipt = appendReceipt
    }

    /// UTC day bucket, matching `DataRootDiskHygieneCheck.dayKey`.
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
            .appendingPathComponent("stale_artifact_sweep_last_run")
        do {
            try FileManager.default.createDirectory(
                at: marker.deletingLastPathComponent(), withIntermediateDirectories: true)
        } catch {
            return .failed(error: "stale artifact sweep marker directory: \(error)")
        }

        let rollback: @Sendable () async -> Void
        let today = Self.dayKey(now)
        switch await reserveOncePerPeriod(
            at: marker, stamp: today, isFresh: { stored in stored?.trimmed == today }
        ) {
        case .alreadyReserved:
            return .skipped(reason: "stale artifact sweep already ran today")
        case .failed(let error):
            return .failed(error: "stale artifact sweep reservation: \(error)")
        case .reserved(_, let rb):
            rollback = rb
        }

        let plan = StaleArtifactSweep.plan(
            dataRoot: dataRoot,
            now: now,
            receiptGraceDays: receiptGraceDays,
            backupGraceDays: backupGraceDays,
            maxPerTick: maxPerTick
        )
        let dryRun = !isEnabled()

        // Nothing to do: still emit the pass summary when the receipt leg is
        // BLOCKED, because a silent no-op would read as "clean" when it actually
        // means "refused to look".
        if plan.isEmpty && plan.receiptsBlockedReason == nil {
            return .completed(result: "stale artifact sweep found nothing "
                + "(\(plan.referencedRunIDCount) referenced runId(s))")
        }

        var removed = 0
        var reclaimed: Int64 = 0
        var unreceipted = 0
        var failures: [String] = []

        if !dryRun {
            // PRE-FLIGHT: prove the receipt ledger accepts a line BEFORE the
            // first file moves. Receipts are written after their mutation (so a
            // line can never claim a removal that did not happen), which leaves
            // one bad shape: remove file, then discover the ledger is dead, and
            // now a file is gone with no audit trail. The realistic cause of a
            // dead ledger — unwritable path, full disk, bad permissions — is
            // present BEFORE the pass starts, so probing first eliminates it.
            guard await appendReceipt(StaleArtifactSweep.passStartLine(
                for: plan, at: now, maxPerTick: maxPerTick
            )) else {
                await rollback()
                return .failed(error: "stale artifact sweep receipt ledger unwritable; "
                    + "removed nothing, reservation rolled back")
            }
            for artifact in plan.staleBackups + plan.orphanReceipts {
                let applied: SweptArtifact
                do {
                    applied = try StaleArtifactSweep.apply(artifact, dataRoot: dataRoot)
                } catch StaleArtifactSweep.SweepApplyOutcome.alreadyGone {
                    continue  // vanished between plan and apply — nothing removed
                } catch StaleArtifactSweep.SweepApplyOutcome.driftedSincePlan {
                    // The on-disk file changed after planning — a stale verdict
                    // must not delete whatever lives there now. Skipped, not a
                    // failure: the next pass replans against current reality.
                    continue
                } catch {
                    failures.append("\(artifact.relativePath): \(error)")
                    continue
                }
                // The mutation has HAPPENED — count it now, unconditionally
                // (gpt-5.5 BLOCKING, 2026-07-24: counting after the receipt
                // append let a mutated-but-unreceipted file report removed:0,
                // and a failed summary could then roll the day back over a file
                // that was already gone).
                removed += 1
                reclaimed += applied.sizeBytes
                // Receipt AFTER the mutation lands, so a receipt line can never
                // claim a removal that did not happen. The reverse ordering
                // (receipt-then-remove) would leave a phantom line on a failed
                // rename.
                guard await appendReceipt(
                    StaleArtifactSweep.receiptLine(for: applied, at: now, dryRun: false)
                ) else {
                    unreceipted += 1
                    failures.append("\(applied.relativePath): REMOVED but receipt append failed")
                    // The receipt ledger is the audit trail for a destructive
                    // step. If it stops accepting lines, stop removing files.
                    break
                }
            }
        }

        let summaryLanded = await appendReceipt(StaleArtifactSweep.summaryLine(
            for: plan, at: now, dryRun: dryRun,
            removed: removed, reclaimedBytes: reclaimed, failures: failures))

        if !summaryLanded && removed == 0 {
            // Nothing was touched and we cannot record the pass — roll the day
            // back so the next tick retries rather than silently skipping.
            // (removed counts every MUTATION, receipted or not, so this branch
            // can never roll back over a file that is already gone.)
            await rollback()
            return .failed(error: "stale artifact sweep receipt append failed; reservation rolled back")
        }

        if dryRun {
            return .completed(result: "stale artifact sweep REPORT-ONLY: would remove "
                + "\(plan.orphanReceipts.count) orphan receipt(s) + \(plan.staleBackups.count) "
                + "stale backup(s), \(DataRootDiskHygiene.humanSize(plan.totalBytes))"
                + (plan.capped ? " [capped at \(maxPerTick)/tick; more remain]" : "")
                + (plan.receiptsBlockedReason.map { " [receipt leg blocked: \($0)]" } ?? ""))
        }
        if !failures.isEmpty {
            return .failed(error: "stale artifact sweep removed \(removed) "
                + "(\(DataRootDiskHygiene.humanSize(reclaimed)))"
                + (unreceipted > 0 ? " [\(unreceipted) removal(s) UNRECEIPTED — ledger died mid-pass]" : "")
                + " with \(failures.count) "
                + "failure(s): \(failures.prefix(3).joined(separator: "; "))")
        }
        return .completed(result: "stale artifact sweep removed \(removed) file(s), "
            + "reclaimed \(DataRootDiskHygiene.humanSize(reclaimed))"
            + (plan.capped ? " [capped at \(maxPerTick)/tick; more remain]" : "")
            + (plan.receiptsBlockedReason.map { " [receipt leg blocked: \($0)]" } ?? ""))
    }
}

private extension String {
    var trimmed: String { trimmingCharacters(in: .whitespacesAndNewlines) }
}
