// Kind backfill stages one approval card; only approval writes the proposed kinds through the store.
// Kinds and decay rates belong to the agent and user.
//
// Backfill owns its stamp-file idempotence and pending-approval recovery
// scan; card id == approval id so InboxView's approve/reject routes through
// resolveApproval(id); `canceled` clears the stamp (re-stages next pass),
// `denied` keeps it (a refused backfill is never re-proposed).
//
// Approval creation and pending scans are injected by the app layer.
// The visible inbox CARD is written through LiveNotificationInbox;
// the resolveApproval dispatch branch for `action` lives in the app
// layer (NativeClient).

import Foundation
import GRDB
import NativeAgentCore
import NotificationInbox
import PersistenceCore
import NativeAgentShared

// Blueprint: | `MemoryV2+KindBackfill.swift` | `MemoryKindBackfill`: approval-staged legacy row classifications and checked apply through canonical storage |

/// Staging stamps: local backup/export and memory PrivacyMap, no phone sync.
public enum MemoryKindBackfill {

    /// A distinct action id keeps kind backfill separate from memory repair.
    public static let action = "memory.kind_backfill"

    /// Payload discriminator.
    public static let payloadKindValue = "memory.kind_backfill.rows"

    /// Stamp kind under <dataRoot>/memory/repairs/.
    public static let stampKind = "memory.kind_backfill"

    // MARK: - Row proposal

    public struct RowProposal: Sendable, Equatable {
        public let id: String
        /// MemoryStorage.contentHash of the content at staging time — the
        /// apply-time stale guard (content drift → skip, never overwrite).
        public let contentHash: String
        /// Sentence-clipped preview for the card; never written anywhere.
        public let contentPreview: String
        public let proposedKind: String

        public init(id: String, contentHash: String, contentPreview: String, proposedKind: String) {
            self.id = id
            self.contentHash = contentHash
            self.contentPreview = contentPreview
            self.proposedKind = proposedKind
        }
    }

    // MARK: - Detection

    /// Active rows the backfill may classify: no metadata.kind at all (the
    /// legacy rows) or only the machine write-default stamp. Deliberate
    /// kinds (caller/extractor/approved-backfill) are never re-proposed.
    public static func classifiableRows(storage: MemoryStorage) async throws -> [StoredMemory] {
        try await storage.listMemories(persona: nil, status: "active", limit: nil)
            .filter { MemoryKindStamp.isClassifiable($0.metadata) }
            .sorted { $0.id < $1.id }
    }

    // MARK: - Classification

    /// Default classifier: Apple Foundation Models single-label
    /// classification (on-device). Throws when Apple Intelligence is
    /// unavailable (staging then proposes nothing and retries on a later
    /// pass) AND on a no-match reply (`.classificationNoMatch` — the row is
    /// dropped from the card by `classify` below, never coerced to a
    /// default label; fix-round finding 1). Fail-safe, never fail-wrong.
    public static func foundationModelsClassifier(content: String, taxonomy: [String]) async throws -> String {
        try await OnDeviceClassification.classify(content: content, into: taxonomy)
    }

    /// Classify rows into the canonical taxonomy. Per-row failures or
    /// out-of-taxonomy replies drop the row from THIS card (it stays
    /// kind-less and classifiable later) — a classifier error must never
    /// turn into a junk label on an approval card.
    public static func classify(
        rows: [StoredMemory],
        classifier: @Sendable (String, [String]) async throws -> String
    ) async -> [RowProposal] {
        var out: [RowProposal] = []
        for row in rows {
            guard let label = try? await classifier(row.content, MemoryKindStamp.taxonomy),
                  MemoryKindStamp.taxonomy.contains(label) else { continue }
            out.append(RowProposal(
                id: row.id,
                contentHash: MemoryStorage.contentHash(row.content),
                contentPreview: MemoryTextClip.sentenceClip(row.content, cap: 200),
                proposedKind: label
            ))
        }
        return out
    }

    // MARK: - Staging

    /// Idempotent staging entry point. Returns the approval id when a card exists after
    /// this call (fresh or reused), nil when there was nothing to stage or
    /// staging failed (no stamp is written on failure — retried next pass).
    ///
    /// - createApproval: app-layer closure — creates the approval RECORD
    ///   (SwiftNativeApprovalInbox.create) from a {title, action, risk,
    ///   reason, payload} body and returns its id.
    /// - listPendingBackfills: app-layer closure — pending approval records
    ///   for `action` as (id, payload), for the crash-retry dedupe scan.
    ///   A throw here fails CLOSED (stage nothing; next pass retries).
    @discardableResult
    public static func stageIfNeeded(
        dataRoot: URL,
        storage: MemoryStorage,
        classifier: @Sendable (String, [String]) async throws -> String = foundationModelsClassifier,
        createApproval: @Sendable (JSONValue) async throws -> String,
        listPendingBackfills: @Sendable () async throws -> [(id: String, payload: JSONValue)]
    ) async -> String? {
        if let stamped = readStamp(dataRoot: dataRoot) { return stamped }

        // Crash-retry dedupe BEFORE doing any classification work: a prior
        // launch may have created the approval but died before the stamp.
        let pending: [(id: String, payload: JSONValue)]
        do {
            pending = try await listPendingBackfills()
        } catch {
            nativeLog("[kindBackfill] dedupe scan failed: \(String(describing: error))")
            return nil
        }
        if let existing = pending.first(where: { payloadKind($0.payload) == payloadKindValue }) {
            let rows = rowProposals(fromPayload: existing.payload)
            do {
                try await ensureInboxCard(dataRoot: dataRoot, approvalId: existing.id, rows: rows)
                writeStamp(approvalId: existing.id, dataRoot: dataRoot)
                return existing.id
            } catch {
                nativeLog("[kindBackfill] card ensure failed: \(String(describing: error))")
                return nil
            }
        }

        // Detect + classify. Detection failure (no sqlite yet) → skip.
        let rows: [RowProposal]
        do {
            let candidates = try await classifiableRows(storage: storage)
            guard !candidates.isEmpty else { return nil }
            rows = await classify(rows: candidates, classifier: classifier)
        } catch {
            nativeLog("[kindBackfill] detection failed: \(String(describing: error))")
            return nil
        }
        guard !rows.isEmpty else { return nil }

        let title = "Memory: classify \(rows.count) legacy memories into kinds"
        let reason = "Approve to classify these memories with the proposed kinds through the normal memory write path. "
            + "Only kind metadata changes; content and embeddings stay intact. Replacement still requires explicit, "
            + "fingerprinted intent. Deny to leave every row as it is."
        let body: JSONValue = .object([
            "title": .string(title),
            "action": .string(action),
            "risk": .string("medium"),
            "reason": .string(reason),
            "payload": payload(rows: rows),
        ])
        do {
            let approvalId = try await createApproval(body)
            // Card failure leaves no stamp so an invisible backfill cannot block restaging.
            try await ensureInboxCard(dataRoot: dataRoot, approvalId: approvalId, rows: rows)
            writeStamp(approvalId: approvalId, dataRoot: dataRoot)
            return approvalId
        } catch {
            nativeLog("[kindBackfill] stage failed: \(String(describing: error))")
            return nil
        }
    }

    // MARK: - Payload codec

    static func payload(rows: [RowProposal]) -> JSONValue {
        .object([
            "kind": .string(payloadKindValue),
            "store": .string("memory/memory.sqlite"),
            "taxonomy": .array(MemoryKindStamp.taxonomy.map { .string($0) }),
            "rows": .array(rows.map { row in
                .object([
                    "id": .string(row.id),
                    "content_hash": .string(row.contentHash),
                    "content_preview": .string(row.contentPreview),
                    "current_kind": .null,
                    "proposed_kind": .string(row.proposedKind),
                ])
            }),
        ])
    }

    public static func payloadKind(_ payload: JSONValue) -> String? {
        guard case .object(let obj) = payload,
              case .string(let kind)? = obj["kind"] else { return nil }
        return kind
    }

    /// Parse row proposals out of an approval payload — only what the
    /// approved card actually carried is ever applied.
    public static func rowProposals(fromPayload payload: JSONValue) -> [RowProposal] {
        guard case .object(let obj) = payload,
              case .array(let rows)? = obj["rows"] else { return [] }
        return rows.compactMap { row in
            guard case .object(let r) = row,
                  case .string(let id)? = r["id"], !id.isEmpty,
                  case .string(let hash)? = r["content_hash"], !hash.isEmpty,
                  case .string(let kind)? = r["proposed_kind"], !kind.isEmpty
            else { return nil }
            let preview: String = {
                if case .string(let p)? = r["content_preview"] { return p }
                return ""
            }()
            return RowProposal(id: id, contentHash: hash, contentPreview: preview, proposedKind: kind)
        }
    }

    // MARK: - Apply (on approve)

    public struct ApplyOutcome: Sendable, Equatable {
        public var applied: [String] = []
        public var skippedStale: [String] = []
        public var failed: [String: String] = [:]   // id → reason
        public init() {}
    }

    /// Write the approved kinds. Per-row guards:
    ///   - row gone → failed;
    ///   - content drifted since staging (hash mismatch) → skippedStale;
    ///   - row no longer classifiable (a deliberate kind landed meanwhile)
    ///     → skippedStale;
    ///   - proposed kind not in the taxonomy → failed (never write junk).
    /// Guards and metadata merge share one storage transaction; the usual
    /// UserMD/Spotlight/KG hooks fire after it commits.
    /// NOTE: applying bumps updated_at, so a row backfilled into a
    /// decaying kind starts its decay clock at apply time — conservative
    /// (decay fires later, never earlier; recall quality never reduced).
    public static func apply(
        _ rows: [RowProposal],
        storage: MemoryStorage
    ) async throws -> ApplyOutcome {
        var outcome = ApplyOutcome()
        for row in rows {
            guard MemoryKindStamp.taxonomy.contains(row.proposedKind) else {
                outcome.failed[row.id] = "proposed kind not in taxonomy: \(row.proposedKind)"
                continue
            }
            switch try await storage.applyKindBackfill(row) {
            case true?: outcome.applied.append(row.id)
            case false?: outcome.skippedStale.append(row.id)
            case nil: outcome.failed[row.id] = "row not found"
            }
        }
        return outcome
    }

    // MARK: - Inbox card

    /// Card id == approval id (InboxView routes approve/reject through
    /// inboxAction(id) → resolveApproval(id)). The live inbox owns the file.
    static func ensureInboxCard(
        dataRoot: URL,
        approvalId: String,
        rows: [RowProposal]
    ) async throws {
        // Per-kind counts for the summary line.
        var counts: [String: Int] = [:]
        for row in rows { counts[row.proposedKind, default: 0] += 1 }
        let summary = counts.sorted { $0.value > $1.value }
            .map { "\($0.key) ×\($0.value)" }
            .joined(separator: ", ")
        let detail = rows
            .map { "Memory: \($0.contentPreview)\nProposed category: \($0.proposedKind)" }
            .joined(separator: "\n\n")
        let card: JSONValue = .object([
            "id": .string(approvalId),
            "created_at": .string(MemoryStorage.nowISO8601()),
            "source": .string("memory_kind_backfill"),
            "severity": .string("actionable"),
            "title": .string("Memory: classify \(rows.count) legacy memories into kinds"),
            "summary": .string(String("Proposed kinds: \(summary)".prefix(500))),
            "detail": .string(detail),
            "related_mission_id": .null,
            "related_approval_id": .string(approvalId),
            "related_paths": .array([
                .string(dataRoot.appendingPathComponent("memory/memory.sqlite").path),
            ]),
            "related_groups": .array([]),
            "actions": .array([
                .object(["id": .string("view"), "label": .string("View"),
                         "description": .string("See every row's proposed kind")]),
                .object(["id": .string("approve"), "label": .string("Approve"),
                         "description": .string("Stamp the listed kinds (metadata only)")]),
                .object(["id": .string("reject"), "label": .string("Deny"),
                         "description": .string("Leave every memory exactly as it is")]),
                .object(["id": .string("dismiss"), "label": .string("Dismiss"),
                         "description": .string("Dismiss this card")]),
            ]),
            "status": .string("unread"),
            "read_at": .null,
        ])
        try await LiveNotificationInbox.live(dataRoot: dataRoot).appendUnique(card, id: approvalId)
    }

    // MARK: - Stamps (idempotence + cancel-restage)

    public static func stampPath(dataRoot: URL) -> URL {
        dataRoot
            .appendingPathComponent("memory", isDirectory: true)
            .appendingPathComponent("repairs", isDirectory: true)
            .appendingPathComponent("\(stampKind).staged.json")
    }

    public static func readStamp(dataRoot: URL) -> String? {
        guard let data = try? Data(contentsOf: stampPath(dataRoot: dataRoot)),
              let parsed = try? JSONValue.parse(data),
              case .object(let obj) = parsed,
              case .string(let id)? = obj["approval_id"] else { return nil }
        return id
    }

    static func writeStamp(approvalId: String, dataRoot: URL) {
        let path = stampPath(dataRoot: dataRoot)
        let stamp: JSONValue = .object([
            "kind": .string(stampKind),
            "approval_id": .string(approvalId),
            "staged_at": .string(MemoryStorage.nowISO8601()),
        ])
        do {
            try SwiftNativePersistenceCore.writeDataAtomicDurable(stamp.serializedData(pretty: true), to: path)
        } catch {
            nativeLog("[kindBackfill] stamp write failed: \(String(describing: error))")
        }
    }

    /// Canceled decision (or a failed apply): clear the stamp so the next
    /// pass re-detects and re-stages a fresh card.
    public static func clearStamp(dataRoot: URL) {
        try? FileManager.default.removeItem(at: stampPath(dataRoot: dataRoot))
    }
}

extension MemoryStorage {
    /// Nil means missing; false means the approved classification is stale.
    func applyKindBackfill(_ proposal: MemoryKindBackfill.RowProposal) async throws -> Bool? {
        let result = try await dbPool.write { db -> (Bool?, StoredMemory?) in
            guard var memory = try Row.fetchOne(
                db, sql: "SELECT * FROM memories WHERE id = ?", arguments: [proposal.id]
            ).map(Self.decodeMemory) else { return (nil, nil) }
            guard Self.contentHash(memory.content) == proposal.contentHash,
                  MemoryKindStamp.isClassifiable(memory.metadata) else { return (false, nil) }
            var metadata: [String: JSONValue] = [:]
            if case .object(let existing)? = memory.metadata { metadata = existing }
            let now = Self.nowISO8601()
            metadata["kind"] = .string(proposal.proposedKind)
            metadata["kind_source"] = .string(MemoryKindStamp.backfillSource)
            metadata["kind_backfilled_at"] = .string(now)
            memory.metadata = .object(metadata)
            memory.updatedAt = now
            try Self.validateTemporalEvidence(memory)
            try db.execute(sql: """
                UPDATE memories SET metadata_json = ?, updated_at = ? WHERE id = ?
                """, arguments: [Self.encodeMetadata(memory.metadata), now, memory.id])
            return (true, memory)
        }
        if let memory = result.1 {
            invalidateRecallCache()
            pokeUserMDRegen(persona: memory.personaId)
            await pokeProjectionHooks(memory)
        }
        return result.0
    }
}
