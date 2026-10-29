// Canonical inventory retirement and execution of previously approved
// truncated-row repairs. Legacy notes.jsonl staging, rewriting and stamps
// are retired; existing notes and backup files are left on disk.

import Foundation
import ApprovalInbox
import NativeAgentCore
import PersistenceCore
import NativeAgentShared
// Blueprint: | `MemoryRepairOneShot.swift` | `archiveInventoryRows` and approved canonical truncated-row execution with safety snapshots; legacy notes staging, scanning, purge, stamps and outcome files are retired without touching existing files |

/// Inventory completion and pre-repair SQLite snapshots are locally backed
/// up/exported and listed under memory in PrivacyMap, never phone-synced.
/// Off-disk backup excludes memory/backups.
public enum MemoryRepairOneShot {

    public static let action = "memory.repair"
    static let truncatedRowsKind = "memory.repair.truncated_rows"
    static let inventoryRowsKind = "memory.repair.inventory_rows"
    /// Sources of the retired inventory lanes: skill pointers are found
    /// through `find` and `ability.read`, executions live in Desk and Workshop
    /// history; neither is recalled as a memory.
    static let inventorySources = ["skill-index", "workshop:"]

    // MARK: - Inventory rows: archived once, no card

    /// Archives every active row the retired inventory lanes wrote, through the
    /// store's own archive (no tombstone, row stays walkable). The done receipt
    /// is written only after every row archived; a failure leaves it for the
    /// next launch.
    package static func archiveInventoryRows(dataRoot: URL) async {
        let done = receiptPath(kind: inventoryRowsKind, name: "done", dataRoot: dataRoot)
        guard !FileManager.default.fileExists(atPath: done.path) else { return }
        var archived = 0
        do {
            let storage = try await SwiftNativeMemoryV2.resolvedStorage(dataRoot: dataRoot)
            for source in inventorySources {
                for id in try await storage.laneMemoryIDs(sourcePrefix: source) {
                    guard try await storage.updateMemory(id: id, patch: MemoryPatch(status: "archived")) != nil else {
                        throw MemoryV2Error.recordNotFound
                    }
                    archived += 1
                }
            }
        } catch {
            nativeLog("[memoryRepair] \(inventoryRowsKind) stopped after \(archived) rows; next launch retries: \(String(describing: error))")
            return
        }
        writeReceipt(
            kind: inventoryRowsKind, name: "done", status: "complete",
            detail: "Archived \(archived) rows from \(inventorySources.joined(separator: ", ")); nothing writes them any more.",
            dataRoot: dataRoot
        )
    }

    private static func receiptPath(kind: String, name: String, dataRoot: URL) -> URL {
        dataRoot
            .appendingPathComponent("memory/repairs", isDirectory: true)
            .appendingPathComponent("\(kind).\(name).json")
    }

    private static func writeReceipt(
        kind: String,
        name: String,
        status: String,
        detail: String,
        dataRoot: URL
    ) {
        let path = receiptPath(kind: kind, name: name, dataRoot: dataRoot)
        let value: JSONValue = .object([
            "kind": .string(kind),
            "status": .string(status),
            "detail": .string(detail),
            "at": .string(ISO8601DateFormatter().string(from: Date())),
        ])
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        if let data = try? encoder.encode(value) {
            try? SwiftNativePersistenceCore.writeDataAtomicDurable(data, to: path)
        }
    }

    /// Execute an approved truncated-row repair against canonical storage with
    /// its safety snapshot, then annotate the approval's terminal result.
    /// Reconciliation stale-skips already applied rows; retired kinds fail
    /// through the existing unknown-kind outcome without touching legacy files.
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
                default:
                    nativeLog("[memoryRepair] unknown repair kind: \(kind)")
                    _ = try? await SwiftNativeApprovalInbox(root: dataRoot).annotateExecution(
                        rec.id,
                        executedAction: .object(["kind": .string(kind), "error": .string("unknown kind")]),
                        detail: "memory repair FAILED: unknown repair kind '\(kind)'")
                }
            } catch {
                nativeLog("[memoryRepair] apply failed for \(kind): \(String(describing: error))")
                _ = try? await SwiftNativeApprovalInbox(root: dataRoot).annotateExecution(
                    rec.id,
                    executedAction: .object([
                        "kind": .string(kind),
                        "error": .string("\(error)"),
                    ]),
                    detail: "memory repair FAILED: \(error.localizedDescription)")
            }
        case "denied":
            // Denial leaves the canonical store untouched.
            _ = try? await SwiftNativeApprovalInbox(root: dataRoot).annotateExecution(
                rec.id,
                executedAction: .object([
                    "op": .string("memory_repair_deny"),
                    "kind": .string(kind),
                ]),
                detail: "memory repair denied — store untouched; will not be re-proposed")
        default: // canceled
            _ = try? await SwiftNativeApprovalInbox(root: dataRoot).annotateExecution(
                rec.id,
                executedAction: .object([
                    "op": .string("memory_repair_cancel"),
                    "kind": .string(kind),
                ]),
                detail: "memory repair canceled — store untouched")
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

    /// Back up before approved edits; stale words skip, tombstoned words fail.
    /// The canonical runtime supplies vectors unless a provider is injected.
    /// Embedding failure still repairs the words and records the vector owed.
    static func applyTruncatedRowsRepair(
        dataRoot: URL,
        repairs: [TruncatedRowRepair],
        embedder: (any EmbeddingProvider)? = nil
    ) async throws -> TruncatedRepairOutcome {
        var outcome = TruncatedRepairOutcome()
        guard !repairs.isEmpty else { return outcome }
        outcome.backupPath = try await backupSQLiteStore(dataRoot: dataRoot)
        let memory = SwiftNativeMemoryV2.resolvedOwner(dataRoot: dataRoot, alternateRootEmbedder: embedder)
        guard let storage = await memory.underlyingStorage() else { throw MemoryV2Error.storageUnavailable }
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
            let batch: MemoryEmbeddingBatch?
            if let embedder { batch = try? await embedder.embedWithEpoch([repair.proposedText]) }
            else { batch = try? await memory.embedForDerivedContextWithEpoch([repair.proposedText]) }
            if let batch, let vec = batch.vectors.first {
                if try await storage.matchesTombstone(
                    embedding: vec,
                    embeddingEpoch: batch.epoch
                ) {
                    outcome.failed[repair.id] = "proposed text is a paraphrase of a rejected claim"
                    continue
                }
                newEmbedding = vec
            }
            let patch = MemoryPatch(
                content: repair.proposedText,
                embedding: newEmbedding,
                embeddingEpoch: newEmbedding == nil ? nil : batch?.epoch.rawValue
            )
            guard try await storage.updateMemory(
                id: repair.id, patch: patch, expectedContent: repair.currentText
            ) != nil else {
                outcome.skippedStale.append(repair.id)
                continue
            }
            outcome.applied.append(repair.id)
            if newEmbedding != nil { outcome.embeddingRefreshed.append(repair.id) }
        }
        return outcome
    }

    // MARK: - Payload and SQLite safety snapshot

    static func payloadKind(_ payload: JSONValue) -> String? {
        guard case .object(let obj) = payload,
              case .string(let kind)? = obj["kind"] else { return nil }
        return kind
    }

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
