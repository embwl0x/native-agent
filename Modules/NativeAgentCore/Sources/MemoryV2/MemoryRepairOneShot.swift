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
// applyResolvedMemoryRepair dispatches to. Every apply path
// backs up the touched store FIRST and goes through the store's own write
// path (MemoryStorage.updateMemory — UserMD/Spotlight/KG hooks all fire).
//
// Staging is idempotent: a stamp file under <dataRoot>/memory/repairs/
// plus a pending-approval scan (the REM stager's crash-retry shape) prevent
// double-staging. `canceled` clears the stamp so the next pass re-stages;
// `denied` keeps it — a refused repair is never re-proposed.

import Foundation
import ApprovalInbox
import TrustCenter
import NativeAgentCore
import PersistenceCore

/// App-owned card delivery; repair policy and persistence remain in MemoryV2.
public protocol MemoryRepairPresentationPort: Sendable {
    func ensureInboxCard(
        dataRoot: URL, approvalId: String, title: String,
        summary: String, detail: String, relatedPath: String
    ) async throws
}

public enum MemoryRepairOneShot {

    public static let action = "memory.repair"
    static let truncatedRowsKind = "memory.repair.truncated_rows"
    static let legacyNoteDupsKind = "memory.repair.legacy_note_dups"

    // MARK: - Boot entry point

    /// Idempotent: safe to call on every app launch. Stages at most one
    /// approval card per repair kind, ever (stamp + pending-approval scan).
    public static func stageIfNeeded(dataRoot: URL, presentation: any MemoryRepairPresentationPort) async {
        _ = await stageLegacyNoteDupPurge(dataRoot: dataRoot, presentation: presentation)
    }

    // MARK: - Staging: legacy note dup-purge card

    @discardableResult
    static func stageLegacyNoteDupPurge(dataRoot: URL, presentation: any MemoryRepairPresentationPort) async -> String? {
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
            kind: legacyNoteDupsKind, dataRoot: dataRoot, presentation: presentation,
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
        kind: String, dataRoot: URL, presentation: any MemoryRepairPresentationPort,
        title: String, reason: String, payload: JSONValue,
        cardSummary: String, cardDetail: String, relatedPath: String
    ) async -> String? {
        let yolo = await SwiftNativeSecurityCenter(dataRoot: dataRoot)
            .fullMacYoloAuthority(
                tool: action,
                origin: SecurityOriginContext(
                    surface: "desk",
                    source: "memory_repair_one_shot",
                    isRemote: false
                )
            )
        if yolo.admitted {
            let timestamp = ISO8601DateFormatter().string(from: Date())
            let admitted = ApprovalRecord(
                id: "full-mac-yolo-\(UUID().uuidString.lowercased())",
                title: title,
                action: action,
                risk: "medium",
                reason: "Admitted by active Full Mac authority",
                status: "resolved",
                payload: payload,
                payloadPreview: "",
                createdAt: timestamp,
                resolvedAt: timestamp,
                decision: "approved",
                decidedBy: "full_mac_yolo",
                remoteResolvable: false,
                localOnly: true
            )
            await applyResolvedMemoryRepair(from: admitted, dataRoot: dataRoot)
            writeFullMacOutcome(
                kind: kind, status: "admitted",
                detail: "Executed through the canonical memory repair executor without an approval prompt.",
                dataRoot: dataRoot
            )
            return nil
        }
        if yolo.state == .explicitlyBlocked {
            writeFullMacOutcome(
                kind: kind, status: "refused",
                detail: "memory.repair is explicitly blocked; no approval was staged.",
                dataRoot: dataRoot
            )
            return nil
        }
        let inbox = SwiftNativeApprovalInbox(root: dataRoot)
        // Crash-retry dedupe: a prior launch may have created the approval
        // but died before the stamp write. Reuse the pending record. Fails
        // closed — if the scan throws we can't know, so stage nothing and
        // let the next launch retry.
        let pending: [ApprovalRecord]
        do {
            pending = try await inbox.list(filter: ApprovalFilter(status: "pending", action: action))
        } catch {
            nativeLog("[memoryRepair] dedupe scan failed for \(kind): \(String(describing: error))")
            return nil
        }
        if let existing = pending.first(where: { payloadKind($0.payload) == kind }) {
            do {
                try await presentation.ensureInboxCard(
                    dataRoot: dataRoot, approvalId: existing.id, title: title,
                    summary: cardSummary, detail: cardDetail, relatedPath: relatedPath)
                writeStamp(kind: kind, approvalId: existing.id, dataRoot: dataRoot)
                return existing.id
            } catch {
                nativeLog("[memoryRepair] card ensure failed for \(kind): \(String(describing: error))")
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
            try await presentation.ensureInboxCard(
                dataRoot: dataRoot, approvalId: rec.id, title: title,
                summary: cardSummary, detail: cardDetail, relatedPath: relatedPath)
            writeStamp(kind: kind, approvalId: rec.id, dataRoot: dataRoot)
            return rec.id
        } catch {
            nativeLog("[memoryRepair] stage failed for \(kind): \(String(describing: error))")
            return nil
        }
    }

    private static func writeFullMacOutcome(
        kind: String,
        status: String,
        detail: String,
        dataRoot: URL
    ) {
        let path = dataRoot
            .appendingPathComponent("memory/repairs", isDirectory: true)
            .appendingPathComponent("\(kind).full_mac_outcome.json")
        try? FileManager.default.createDirectory(
            at: path.deletingLastPathComponent(), withIntermediateDirectories: true)
        let value: JSONValue = .object([
            "kind": .string(kind),
            "status": .string(status),
            "detail": .string(detail),
            "at": .string(ISO8601DateFormatter().string(from: Date())),
        ])
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        if let data = try? encoder.encode(value) {
            try? data.write(to: path, options: .atomic)
        }
    }

    /// Applies a resolved memory.repair record (U3 wave-1 item 3 — mirror of
    /// applyResolvedREMProposal's shape). Approved → run the matching
    /// MemoryRepairOneShot executor (sqlite truncated-row completion or
    /// legacy note duplicate purge), which backs the store up FIRST and mutates
    /// only what the approved card's payload carries. Denied → store stays
    /// untouched and the staging stamp stays (a refused repair is never
    /// re-proposed). Canceled / apply-failure → stamp cleared so the next
    /// launch re-detects and re-stages a fresh card. Every branch annotates
    /// the approval record; an approved record must never read as silently
    /// applied (W8 lesson).
    /// Static + root-injectable (review blocker fix, 2026-06-10) so the
    /// app's on-launch crash-window reconciliation can run the SAME executor
    /// against any data root. Self-guarding and idempotent: re-running an
    /// already-applied repair stale-skips every row (truncated kind) or
    /// finds zero remaining legacy-note duplicates — no double mutation.
    public static func applyResolvedMemoryRepair(
        from rec: ApprovalRecord,
        dataRoot: URL
    ) async {
        // Self-defensive: only ever acts on a resolved memory.repair record.
        guard rec.action == "memory.repair",
              rec.status == "resolved",
              let decision = rec.decision else { return }
        guard let kind = MemoryRepairOneShot.payloadKind(rec.payload) else {
            nativeLog("[memoryRepair] missing payload kind on approval \(rec.id)")
            _ = try? await SwiftNativeApprovalInbox(root: dataRoot).annotateExecution(
                rec.id,
                executedAction: .object(["error": .string("missing payload kind")]),
                detail: "Memory repair \(decision) FAILED: payload carries no repair kind")
            return
        }
        switch decision {
        case "approved":
            do {
                switch kind {
                case MemoryRepairOneShot.truncatedRowsKind:
                    let repairs = MemoryRepairOneShot.truncatedRepairs(fromPayload: rec.payload)
                    let outcome = try await MemoryRepairOneShot.applyTruncatedRowsRepair(
                        dataRoot: dataRoot, repairs: repairs)
                    let unrefreshed = outcome.applied.count - outcome.embeddingRefreshed.count
                    _ = try? await SwiftNativeApprovalInbox(root: dataRoot).annotateExecution(
                        rec.id,
                        executedAction: .object([
                            "op": .string("memory_repair_truncated_rows"),
                            "applied": .array(outcome.applied.map { .string($0) }),
                            "skippedStale": .array(outcome.skippedStale.map { .string($0) }),
                            "failed": .object(outcome.failed.mapValues { .string($0) }),
                            "backupPath": .string(outcome.backupPath),
                        ]),
                        detail: "memory repair applied: \(outcome.applied.count) rows completed"
                            + (outcome.skippedStale.isEmpty ? "" : ", \(outcome.skippedStale.count) stale-skipped")
                            + (outcome.failed.isEmpty ? "" : ", \(outcome.failed.count) FAILED")
                            + (unrefreshed > 0 ? ", \(unrefreshed) without embedding refresh" : "")
                            + " — backup at \(outcome.backupPath)")
                case MemoryRepairOneShot.legacyNoteDupsKind:
                    let outcome = try await MemoryRepairOneShot.applyLegacyNoteDupPurge(dataRoot: dataRoot, payload: rec.payload)
                    _ = try? await SwiftNativeApprovalInbox(root: dataRoot).annotateExecution(
                        rec.id,
                        executedAction: .object([
                            "op": .string("memory_repair_legacy_note_dups"),
                            "kept": .int(Int64(outcome.kept)),
                            "purged": .int(Int64(outcome.purged)),
                            "backupPath": .string(outcome.backupPath),
                        ]),
                        detail: outcome.purged > 0
                            ? "legacy note purge applied: \(outcome.purged) duplicates removed, "
                                + "\(outcome.kept) rows kept — backup at \(outcome.backupPath)"
                            : "legacy note purge: no duplicates remained at apply time; file untouched")
                default:
                    nativeLog("[memoryRepair] unknown repair kind: \(kind)")
                    _ = try? await SwiftNativeApprovalInbox(root: dataRoot).annotateExecution(
                        rec.id,
                        executedAction: .object(["kind": .string(kind), "error": .string("unknown kind")]),
                        detail: "memory repair FAILED: unknown repair kind '\(kind)'")
                }
            } catch {
                nativeLog("[memoryRepair] apply failed for \(kind): \(String(describing: error))")
                // The approval record is terminal; clear the staging stamp so
                // the next launch re-detects whatever is still broken and
                // stages a fresh card instead of dead-ending.
                MemoryRepairOneShot.clearStamp(kind: kind, dataRoot: dataRoot)
                _ = try? await SwiftNativeApprovalInbox(root: dataRoot).annotateExecution(
                    rec.id,
                    executedAction: .object([
                        "kind": .string(kind),
                        "error": .string("\(error)"),
                    ]),
                    detail: "memory repair FAILED: \(error.localizedDescription) — stamp cleared; "
                        + "next launch re-stages whatever is still repairable")
            }
        case "denied":
            // Store untouched; stamp stays so the refused repair is never
            // re-proposed.
            _ = try? await SwiftNativeApprovalInbox(root: dataRoot).annotateExecution(
                rec.id,
                executedAction: .object([
                    "op": .string("memory_repair_deny"),
                    "kind": .string(kind),
                ]),
                detail: "memory repair denied — store untouched; will not be re-proposed")
        default: // canceled
            MemoryRepairOneShot.clearStamp(kind: kind, dataRoot: dataRoot)
            _ = try? await SwiftNativeApprovalInbox(root: dataRoot).annotateExecution(
                rec.id,
                executedAction: .object([
                    "op": .string("memory_repair_cancel"),
                    "kind": .string(kind),
                ]),
                detail: "memory repair canceled — stamp cleared; next launch re-stages it")
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
        outcome.backupPath = try await backupSQLiteStore(dataRoot: dataRoot)
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
            nativeLog("[memoryRepair] stamp write failed for \(kind): \(String(describing: error))")
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

    /// Online backup of memory.sqlite into a timestamped backup dir, through
    /// MemoryStorage's own pool (sqlite3_backup, verified before it returns).
    /// Returns the backup directory path.
    private static func backupSQLiteStore(dataRoot: URL) async throws -> String {
        let memDir = dataRoot.appendingPathComponent("memory", isDirectory: true)
        // Short unique suffix: the executor is idempotent and may legally
        // run twice in the same second (resolve + launch reconciliation) —
        // a purely timestamp-keyed dir would collide and fail the copy.
        let suffix = UUID().uuidString.lowercased().prefix(8)
        let backupDir = memDir
            .appendingPathComponent("backups", isDirectory: true)
            .appendingPathComponent("pre-repair-\(backupTimestamp())-\(suffix)", isDirectory: true)
        try await MemoryStorage.createConsistentBackup(
            dataRoot: dataRoot,
            destinationDatabaseURL: backupDir.appendingPathComponent("memory.sqlite")
        )
        return backupDir.path
    }

    private static func backupTimestamp() -> String {
        let fmt = DateFormatter()
        fmt.dateFormat = "yyyyMMdd'T'HHmmss'Z'"
        fmt.timeZone = TimeZone(identifier: "UTC")
        fmt.locale = Locale(identifier: "en_US_POSIX")
        return fmt.string(from: Date())
    }
}
