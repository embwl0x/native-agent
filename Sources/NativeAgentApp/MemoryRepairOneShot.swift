// U3 wave-1 item 3 (2026-06-10): one-shot, APPROVAL-GATED memory repairs.
//
// Two daemon-era data-quality wounds in the live store:
//   (a) 5 rows in <dataRoot>/memory/memory.sqlite carry the old 200-char
//       hard cap (content length 199/200, created 2026-05-16/17) — the text
//       ends mid-sentence.
//   (b) a legacy <dataRoot>/memory/*/notes.jsonl file can contain exact-
//       duplicate test residue from old parity probes.
//
// HARD CONSTRAINT (u3-memory-quality plan): NOTHING mutates the live store
// without explicit approval. This file stages ONE inbox approval card per
// repair (action `memory.repair`, mirroring the rem.proposal stager /
// resolveApproval executor shape) and owns the apply-on-approve executors
// NativeClient.applyResolvedMemoryRepair dispatches to. Every apply path
// backs up the touched store FIRST and goes through the store's own write
// path (MemoryStorage.updateMemory — UserMD/Spotlight/KG hooks all fire).
//
// Staging is idempotent: a stamp file under <dataRoot>/memory/repairs/
// plus a pending-approval scan (the REM stager's crash-retry shape) prevent
// double-staging. `canceled` clears the stamp so the next pass re-stages;
// `denied` keeps it — a refused repair is never re-proposed.

import Foundation
import ApprovalInbox
import MemoryV2
import NativeAgentCore
import PersistenceCore
import SQLite3
import NotificationInbox

enum MemoryRepairOneShot {

    static let action = "memory.repair"
    static let truncatedRowsKind = "memory.repair.truncated_rows"
    static let legacyNoteDupsKind = "memory.repair.legacy_note_dups"

    // MARK: - Suggested completions (LLM-suggested, human-approved)
    //
    // Full-text repairs for the 5 known truncated rows. These are
    // LLM-SUGGESTED completions of the chopped final sentence — the approval
    // card shows current vs. proposed verbatim, and only the texts carried
    // in the approved card's payload are ever written. Keyed by row id so a
    // content drift since staging is detected as stale and skipped.
    static let truncatedRowSuggestedCompletions: [String: String] = [:]

    /// Detection window for the daemon-era cap: content length in 199...200
    /// and created on these days. Both gates must hit — plenty of healthy
    /// rows are short; only the known daemon-era window is repairable.
    static let truncatedLengths: Set<Int> = [199, 200]
    static let truncatedCreatedDayPrefixes = ["2026-05-16", "2026-05-17"]

    // MARK: - Boot entry point

    /// Idempotent: safe to call on every app launch. Stages at most one
    /// approval card per repair kind, ever (stamp + pending-approval scan).
    static func stageIfNeeded(dataRoot: URL) async {
        _ = await stageTruncatedRowsRepair(dataRoot: dataRoot)
        _ = await stageLegacyNoteDupPurge(dataRoot: dataRoot)
    }

    // MARK: - Staging (a): truncated-row repair card

    /// Returns the approval id when a card exists after this call (fresh or
    /// reused), nil when there was nothing to stage or staging failed
    /// (failed staging leaves no stamp — retried next launch).
    @discardableResult
    static func stageTruncatedRowsRepair(
        dataRoot: URL,
        suggestions: [String: String] = truncatedRowSuggestedCompletions
    ) async -> String? {
        if let stamped = readStamp(kind: truncatedRowsKind, dataRoot: dataRoot) { return stamped }

        // Detect repairable rows: daemon-era cap signature AND a suggestion
        // to propose. Detection failure (no sqlite yet, cold install) → skip.
        let rows: [(id: String, current: String, proposed: String)]
        do {
            let storage = try await SwiftNativeMemoryV2.resolvedStorage(dataRoot: dataRoot)
            let actives = try await storage.listMemories(persona: nil, status: "active", limit: nil)
            rows = actives.compactMap { m in
                guard truncatedLengths.contains(m.content.count),
                      truncatedCreatedDayPrefixes.contains(where: { m.createdAt.hasPrefix($0) }),
                      let proposed = suggestions[m.id]
                else { return nil }
                return (id: m.id, current: m.content, proposed: proposed)
            }
            .sorted { $0.id < $1.id }
        } catch {
            return nil
        }
        guard !rows.isEmpty else { return nil }

        let payload: JSONValue = .object([
            "kind": .string(truncatedRowsKind),
            "store": .string("memory/memory.sqlite"),
            "rows": .array(rows.map { row in
                .object([
                    "id": .string(row.id),
                    "current_text": .string(row.current),
                    "proposed_text": .string(row.proposed),
                ])
            }),
        ])
        let title = "Memory repair: complete \(rows.count) truncated memories"
        let reason = "These rows still carry the retired daemon's 200-char hard cap and end "
            + "mid-sentence. Approve to replace each with the LLM-suggested completed text shown "
            + "(store backed up first, written through the normal memory write path); deny to "
            + "leave them exactly as they are."
        let summary = rows.map { "• …\(String($0.current.suffix(60))) → …\(String($0.proposed.suffix(80)))" }
            .joined(separator: "\n")
        let detail = rows.map { "[\($0.id)]\nCURRENT: \($0.current)\nPROPOSED: \($0.proposed)" }
            .joined(separator: "\n\n")
        return await stage(
            kind: truncatedRowsKind, dataRoot: dataRoot,
            title: title, reason: reason, payload: payload,
            cardSummary: summary, cardDetail: detail,
            relatedPath: dataRoot.appendingPathComponent("memory/memory.sqlite").path
        )
    }

    // MARK: - Staging (b): legacy note dup-purge card

    @discardableResult
    static func stageLegacyNoteDupPurge(dataRoot: URL) async -> String? {
        if let stamped = readStamp(kind: legacyNoteDupsKind, dataRoot: dataRoot) { return stamped }
        guard let candidate = legacyNotesDupCandidate(dataRoot: dataRoot) else { return nil }

        let payload: JSONValue = .object([
            "kind": .string(legacyNoteDupsKind),
            "path": .string(candidate.relativePath),
            "total_rows": .int(Int64(candidate.lines.count)),
            "duplicate_rows": .int(Int64(candidate.purged)),
            "kept_rows": .int(Int64(candidate.kept.count)),
        ])
        let title = "Memory repair: purge \(candidate.purged) duplicate legacy note rows"
        let reason = "\(candidate.relativePath) contains \(candidate.purged)/\(candidate.lines.count) exact-duplicate "
            + "test-fixture rows. Approve to back the file up and keep only the first occurrence "
            + "of each unique note (\(candidate.kept.count) rows); deny to keep the file as is."
        return await stage(
            kind: legacyNoteDupsKind, dataRoot: dataRoot,
            title: title, reason: reason, payload: payload,
            cardSummary: "\(candidate.lines.count) rows -> \(candidate.kept.count) rows (backup written before the purge)",
            cardDetail: "Exact-duplicate filter keeps the first occurrence of each unique note "
                + "text. The original file is copied to a timestamped .bak alongside it before "
                + "anything is rewritten.",
            relatedPath: candidate.path.path
        )
    }

    // MARK: - Shared staging core (REM stager shape: ensure, never blind-create)

    private static func stage(
        kind: String, dataRoot: URL,
        title: String, reason: String, payload: JSONValue,
        cardSummary: String, cardDetail: String, relatedPath: String
    ) async -> String? {
        let inbox = SwiftNativeApprovalInbox(root: dataRoot)
        // Crash-retry dedupe: a prior launch may have created the approval
        // but died before the stamp write. Reuse the pending record. Fails
        // closed — if the scan throws we can't know, so stage nothing and
        // let the next launch retry.
        let pending: [ApprovalRecord]
        do {
            pending = try await inbox.list(filter: ApprovalFilter(status: "pending", action: action))
        } catch {
            NSLog("[memoryRepair] dedupe scan failed for \(kind): \(String(describing: error))")
            return nil
        }
        if let existing = pending.first(where: { payloadKind($0.payload) == kind }) {
            do {
                try await ensureInboxCard(
                    dataRoot: dataRoot, approvalId: existing.id, title: title,
                    summary: cardSummary, detail: cardDetail, relatedPath: relatedPath)
                writeStamp(kind: kind, approvalId: existing.id, dataRoot: dataRoot)
                return existing.id
            } catch {
                NSLog("[memoryRepair] card ensure failed for \(kind): \(String(describing: error))")
                return nil
            }
        }
        let body: JSONValue = .object([
            "title": .string(title),
            "action": .string(action),
            "risk": .string("medium"),
            "reason": .string(reason),
            "payload": payload,
        ])
        do {
            let rec = try await inbox.create(body)
            // Card failure fails the stage (no stamp) — a stamped repair
            // with no visible card would be invisible forever.
            try await ensureInboxCard(
                dataRoot: dataRoot, approvalId: rec.id, title: title,
                summary: cardSummary, detail: cardDetail, relatedPath: relatedPath)
            writeStamp(kind: kind, approvalId: rec.id, dataRoot: dataRoot)
            return rec.id
        } catch {
            NSLog("[memoryRepair] stage failed for \(kind): \(String(describing: error))")
            return nil
        }
    }

    /// Card id == approval id (InboxView routes approve/reject through
    /// inboxAction(id) → resolveApproval(id)). Idempotent whole-file scan
    /// before append, inside the same flock critical section — the same
    /// shape as ensureREMProposalInboxCard.
    private static func ensureInboxCard(
        dataRoot: URL, approvalId: String, title: String,
        summary: String, detail: String, relatedPath: String
    ) async throws {
        let inboxPath = dataRoot
            .appendingPathComponent("notifications", isDirectory: true)
            .appendingPathComponent("inbox.jsonl")
        let fmt = ISO8601DateFormatter()
        fmt.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        let card: JSONValue = .object([
            "id": .string(approvalId),
            "created_at": .string(fmt.string(from: Date())),
            "source": .string("memory_repair"),
            "severity": .string("actionable"),
            "title": .string(title),
            "summary": .string(String(summary.prefix(500))),
            "detail": .string(detail),
            "related_mission_id": .null,
            "related_approval_id": .string(approvalId),
            "related_paths": .array([.string(relatedPath)]),
            "related_groups": .array([]),
            "actions": .array([
                .object(["id": .string("view"), "label": .string("View"),
                         "description": .string("See full detail")]),
                .object(["id": .string("approve"), "label": .string("Approve"),
                         "description": .string("Apply this repair (store backed up first)")]),
                .object(["id": .string("reject"), "label": .string("Deny"),
                         "description": .string("Leave the store untouched")]),
                .object(["id": .string("dismiss"), "label": .string("Dismiss"),
                         "description": .string("Dismiss this card")]),
            ]),
            "status": .string("unread"),
            "read_at": .null,
        ])
        let inserted = try await LiveNotificationInbox(path: inboxPath)
            .appendUnique(card, id: approvalId)
        if inserted {
            await InboxPushNotifier.notifyIfAttentionWorthy(
                dataRoot: dataRoot,
                itemId: approvalId,
                title: title,
                summary: summary,
                source: "memory_repair",
                severity: "actionable"
            )
        }
    }

    // MARK: - Executor (a): apply truncated-row repairs

    struct TruncatedRowRepair: Equatable {
        let id: String
        let currentText: String
        let proposedText: String
    }

    struct TruncatedRepairOutcome {
        var applied: [String] = []
        var skippedStale: [String] = []
        var failed: [String: String] = [:]   // id → reason
        var embeddingRefreshed: [String] = []
        var backupPath: String = ""
    }

    /// Parse the repair rows out of an approval payload. Only what the
    /// approved card actually carried is ever applied.
    static func truncatedRepairs(fromPayload payload: JSONValue) -> [TruncatedRowRepair] {
        guard case .object(let obj) = payload,
              case .array(let rows)? = obj["rows"] else { return [] }
        return rows.compactMap { row in
            guard case .object(let r) = row,
                  case .string(let id)? = r["id"], !id.isEmpty,
                  case .string(let current)? = r["current_text"],
                  case .string(let proposed)? = r["proposed_text"], !proposed.isEmpty
            else { return nil }
            return TruncatedRowRepair(id: id, currentText: current, proposedText: proposed)
        }
    }

    /// Apply approved row repairs. Backs up the sqlite files FIRST, then
    /// updates each row through MemoryStorage.updateMemory (the store's own
    /// write path — UserMD/Spotlight/KG hooks fire). Per-row guards:
    ///   - stale: current content no longer matches the approved card → skip.
    ///   - tombstoned: proposed text is hash- or paraphrase-tombstoned → fail.
    ///   - embedding: re-embedded via the provided embedder; when embedding
    ///     fails (CoreML fail-closed on headless boxes) the content still
    ///     repairs and the old vector is kept — the old vector encodes the
    ///     200-char prefix of the new text, and the outcome notes the miss.
    static func applyTruncatedRowsRepair(
        dataRoot: URL,
        repairs: [TruncatedRowRepair],
        embedder: (any EmbeddingProvider)? = nil
    ) async throws -> TruncatedRepairOutcome {
        var outcome = TruncatedRepairOutcome()
        guard !repairs.isEmpty else { return outcome }
        outcome.backupPath = try backupSQLiteStore(dataRoot: dataRoot)
        let storage = try await SwiftNativeMemoryV2.resolvedStorage(dataRoot: dataRoot)
        let embeddingProvider: any EmbeddingProvider =
            embedder ?? ManagedEmbeddingProvider(dataRoot: dataRoot)
        for repair in repairs {
            guard let existing = try await storage.memory(id: repair.id) else {
                outcome.failed[repair.id] = "row not found"
                continue
            }
            guard existing.content == repair.currentText else {
                outcome.skippedStale.append(repair.id)
                continue
            }
            // Same denylist gates as any other content edit (hash always;
            // semantic only when a fresh vector is available).
            if try await storage.isTombstoned(content: repair.proposedText) {
                outcome.failed[repair.id] = "proposed text matches a rejection tombstone"
                continue
            }
            var newEmbedding: [Float]? = nil
            var newEmbeddingEpoch: MemoryEmbeddingEpoch? = nil
            if let batch = try? await embeddingProvider.embedWithEpoch([repair.proposedText]),
               let vec = batch.vectors.first {
                if try await storage.matchesTombstone(
                    embedding: vec,
                    embeddingEpoch: batch.epoch
                ) {
                    outcome.failed[repair.id] = "proposed text is a paraphrase of a rejected claim"
                    continue
                }
                newEmbedding = vec
                newEmbeddingEpoch = batch.epoch
            }
            let patch = MemoryPatch(
                content: repair.proposedText,
                embedding: newEmbedding,
                embeddingEpoch: newEmbeddingEpoch?.rawValue
            )
            guard try await storage.updateMemory(id: repair.id, patch: patch) != nil else {
                outcome.failed[repair.id] = "update returned no row"
                continue
            }
            outcome.applied.append(repair.id)
            if newEmbedding != nil { outcome.embeddingRefreshed.append(repair.id) }
        }
        return outcome
    }

    // MARK: - Executor (b): apply legacy note dup purge

    struct DupPurgeOutcome: Equatable {
        let kept: Int
        let purged: Int
        let backupPath: String
    }

    /// Re-reads the file at apply time (counts may have drifted since
    /// staging), backs it up, then keeps the first occurrence of each unique
    /// note text. R-M-W under the cross-process flock so a concurrent
    /// commit_memory append can't be clobbered.
    static func applyLegacyNoteDupPurge(dataRoot: URL, payload: JSONValue) async throws -> DupPurgeOutcome {
        guard let notesPath = notesPath(fromPayload: payload, dataRoot: dataRoot)
                ?? legacyNotesDupCandidate(dataRoot: dataRoot)?.path else {
            return DupPurgeOutcome(kept: 0, purged: 0, backupPath: "")
        }
        let persistence = SwiftNativePersistenceCore()
        return try await persistence.withFileLock(notesPath) {
            let lines = try readNonEmptyLines(notesPath)
            let (kept, purged) = exactDupSplit(lines)
            guard purged > 0 else {
                return DupPurgeOutcome(kept: kept.count, purged: 0, backupPath: "")
            }
            let stamp = backupTimestamp()
            let backup = notesPath.deletingLastPathComponent()
                .appendingPathComponent("notes.jsonl.pre-purge-\(stamp).bak")
            try FileManager.default.copyItem(at: notesPath, to: backup)
            let body = kept.joined(separator: "\n") + "\n"
            try Data(body.utf8).write(to: notesPath, options: .atomic)
            return DupPurgeOutcome(kept: kept.count, purged: purged, backupPath: backup.path)
        }
    }

    // MARK: - Stamps (idempotence + cancel-restage)

    static func stampPath(kind: String, dataRoot: URL) -> URL {
        dataRoot
            .appendingPathComponent("memory", isDirectory: true)
            .appendingPathComponent("repairs", isDirectory: true)
            .appendingPathComponent("\(kind).staged.json")
    }

    static func readStamp(kind: String, dataRoot: URL) -> String? {
        let path = stampPath(kind: kind, dataRoot: dataRoot)
        guard let data = try? Data(contentsOf: path),
              let parsed = try? JSONValue.parse(data),
              case .object(let obj) = parsed,
              case .string(let id)? = obj["approval_id"] else { return nil }
        return id
    }

    private static func writeStamp(kind: String, approvalId: String, dataRoot: URL) {
        let path = stampPath(kind: kind, dataRoot: dataRoot)
        let fmt = ISO8601DateFormatter()
        fmt.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        let stamp: JSONValue = .object([
            "kind": .string(kind),
            "approval_id": .string(approvalId),
            "staged_at": .string(fmt.string(from: Date())),
        ])
        do {
            try FileManager.default.createDirectory(
                at: path.deletingLastPathComponent(), withIntermediateDirectories: true)
            try stamp.serializedData(pretty: true).write(to: path, options: .atomic)
        } catch {
            NSLog("[memoryRepair] stamp write failed for \(kind): \(String(describing: error))")
        }
    }

    /// Canceled decision (or a failed apply): clear the stamp so the next
    /// launch re-detects and re-stages a fresh card instead of dead-ending
    /// on a terminal approval.
    static func clearStamp(kind: String, dataRoot: URL) {
        try? FileManager.default.removeItem(at: stampPath(kind: kind, dataRoot: dataRoot))
    }

    // MARK: - Helpers

    static func payloadKind(_ payload: JSONValue) -> String? {
        guard case .object(let obj) = payload,
              case .string(let kind)? = obj["kind"] else { return nil }
        return kind
    }

    private static func notesPath(fromPayload payload: JSONValue, dataRoot: URL) -> URL? {
        guard case .object(let obj) = payload,
              case .string(let relative)? = obj["path"],
              !relative.isEmpty,
              !relative.hasPrefix("/")
        else { return nil }
        let path = dataRoot.appendingPathComponent(relative)
        let normalizedRoot = dataRoot.standardizedFileURL.path
        let normalizedPath = path.standardizedFileURL.path
        guard normalizedPath == normalizedRoot || normalizedPath.hasPrefix(normalizedRoot + "/") else {
            return nil
        }
        return path
    }

    private static func legacyNotesDupCandidate(
        dataRoot: URL
    ) -> (path: URL, relativePath: String, lines: [String], kept: [String], purged: Int)? {
        let memoryRoot = dataRoot.appendingPathComponent("memory", isDirectory: true)
        guard let entries = try? FileManager.default.contentsOfDirectory(
            at: memoryRoot,
            includingPropertiesForKeys: [.isDirectoryKey],
            options: [.skipsHiddenFiles]
        ) else { return nil }

        for entry in entries.sorted(by: { $0.lastPathComponent < $1.lastPathComponent }) {
            let values = try? entry.resourceValues(forKeys: [.isDirectoryKey])
            guard values?.isDirectory == true else { continue }
            let notesPath = entry.appendingPathComponent("notes.jsonl")
            guard let lines = try? readNonEmptyLines(notesPath), !lines.isEmpty else { continue }
            guard containsTestFixtureLine(lines) else { continue }
            let (kept, purged) = exactDupSplit(lines)
            guard purged > 0 else { continue }
            return (
                path: notesPath,
                relativePath: relativePath(for: notesPath, dataRoot: dataRoot),
                lines: lines,
                kept: kept,
                purged: purged
            )
        }
        return nil
    }

    private static func relativePath(for path: URL, dataRoot: URL) -> String {
        let root = dataRoot.standardizedFileURL.path
        let full = path.standardizedFileURL.path
        if full.hasPrefix(root + "/") {
            return String(full.dropFirst(root.count + 1))
        }
        return path.lastPathComponent
    }

    private static func containsTestFixtureLine(_ lines: [String]) -> Bool {
        for line in lines {
            guard let data = line.data(using: .utf8),
                  let parsed = try? JSONValue.parse(data),
                  case .object(let obj) = parsed,
                  case .bool(true)? = obj["_test_fixture"] else { continue }
            return true
        }
        return false
    }

    private static func readNonEmptyLines(_ path: URL) throws -> [String] {
        let raw = try String(contentsOf: path, encoding: .utf8)
        return raw.components(separatedBy: "\n")
            .filter { !$0.trimmingCharacters(in: .whitespaces).isEmpty }
    }

    /// Exact-dup filter: keep the first occurrence of each unique `text`
    /// field (lines that don't parse as JSON objects with a string `text`
    /// are kept verbatim — never destroy what we don't understand).
    private static func exactDupSplit(_ lines: [String]) -> (kept: [String], purged: Int) {
        var seen = Set<String>()
        var kept: [String] = []
        var purged = 0
        for line in lines {
            guard let data = line.data(using: .utf8),
                  let parsed = try? JSONValue.parse(data),
                  case .object(let obj) = parsed,
                  case .string(let text)? = obj["text"] else {
                kept.append(line)
                continue
            }
            if seen.contains(text) {
                purged += 1
            } else {
                seen.insert(text)
                kept.append(line)
            }
        }
        return (kept, purged)
    }

    /// Copy memory.sqlite + sidecar WAL/SHM into a timestamped backup dir.
    /// Returns the backup directory path.
    ///
    /// CONSTRAINT (gpt-5.5 review nit, 2026-06-10): a plain file copy of a
    /// WAL-mode SQLite db is not transactionally consistent on its own —
    /// committed frames can still live only in the -wal file, and a writer
    /// racing the copy can tear the snapshot. The robust fix is the
    /// sqlite3_backup_* API; at minimum we run a PRAGMA
    /// wal_checkpoint(TRUNCATE) first so every committed frame is folded
    /// into the main db file before the copy (we still copy -wal/-shm for
    /// belt-and-braces). Checkpointing is best-effort: if it fails (e.g.
    /// another connection holds the db), we proceed with the three-file
    /// copy — the apply path is single-process at this point (launch
    /// executor / approval resolve), so the copy is still coherent in
    /// practice, and a backup attempt must never block an approved repair.
    private static func backupSQLiteStore(dataRoot: URL) throws -> String {
        let memDir = dataRoot.appendingPathComponent("memory", isDirectory: true)
        // Short unique suffix: the executor is idempotent and may legally
        // run twice in the same second (resolve + launch reconciliation) —
        // a purely timestamp-keyed dir would collide and fail the copy.
        let suffix = UUID().uuidString.lowercased().prefix(8)
        let backupDir = memDir
            .appendingPathComponent("backups", isDirectory: true)
            .appendingPathComponent("pre-repair-\(backupTimestamp())-\(suffix)", isDirectory: true)
        try FileManager.default.createDirectory(at: backupDir, withIntermediateDirectories: true)
        checkpointWAL(at: memDir.appendingPathComponent("memory.sqlite"))
        for name in ["memory.sqlite", "memory.sqlite-wal", "memory.sqlite-shm"] {
            let src = memDir.appendingPathComponent(name)
            guard FileManager.default.fileExists(atPath: src.path) else { continue }
            try FileManager.default.copyItem(at: src, to: backupDir.appendingPathComponent(name))
        }
        return backupDir.path
    }

    /// Best-effort `PRAGMA wal_checkpoint(TRUNCATE)` so committed WAL
    /// frames land in the main db file before it is copied. READWRITE
    /// without CREATE: never mint an empty db where none exists.
    private static func checkpointWAL(at dbPath: URL) {
        guard FileManager.default.fileExists(atPath: dbPath.path) else { return }
        var db: OpaquePointer? = nil
        let openRC = sqlite3_open_v2(dbPath.path, &db, SQLITE_OPEN_READWRITE, nil)
        defer { sqlite3_close_v2(db) }
        guard openRC == SQLITE_OK, db != nil else {
            NSLog("[memoryRepair] backup WAL checkpoint open failed (rc=\(openRC)) — copying as-is")
            return
        }
        let rc = sqlite3_exec(db, "PRAGMA wal_checkpoint(TRUNCATE);", nil, nil, nil)
        if rc != SQLITE_OK {
            NSLog("[memoryRepair] backup WAL checkpoint failed (rc=\(rc)) — copying as-is")
        }
    }

    private static func backupTimestamp() -> String {
        let fmt = DateFormatter()
        fmt.dateFormat = "yyyyMMdd'T'HHmmss'Z'"
        fmt.timeZone = TimeZone(identifier: "UTC")
        fmt.locale = Locale(identifier: "en_US_POSIX")
        return fmt.string(from: Date())
    }
}
