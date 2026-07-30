// U3 wave-2 item 5b (2026-06-10): approval-gated LLM kind backfill for the
// legacy kind-less rows (32 at audit time).
//
// Decay/supersession shipped in wave 1 but are inert because no live row
// carries metadata.kind. This stages ONE inbox approval card proposing an
// LLM-classified kind per legacy row; apply-on-approve writes metadata.kind
// through the store's own write path. NOTHING mutates silently — kinds/rates
// are Agent/user-owned semantics (u3-memory-quality hard constraint).
//
// Plumbing shape mirrors the wave-1 repair stager (MemoryRepairOneShot /
// the REM stager): stamp-file idempotence + pending-approval crash-retry
// scan; card id == approval id so InboxView's approve/reject routes through
// resolveApproval(id); `canceled` clears the stamp (re-stages next pass),
// `denied` keeps it (a refused backfill is never re-proposed).
//
// Module boundary (UPDATED 2026-06-10, wave-2 integration decision): the
// old "MemoryV2 never imports ApprovalInbox" rule is RETIRED — ApprovalInbox
// is a leaf module (PersistenceCore only, no cycle) and the consolidation
// gate now uses SwiftNativeApprovalInbox directly. This file predates that
// call and keeps the closure-injection shape (approval RECORD create +
// pending-scan injected by the app layer): it works, it's tested, and
// rewriting it buys nothing. New MemoryV2 code may import ApprovalInbox
// directly. The visible inbox CARD is plain PersistenceCore JSONL written
// here; the resolveApproval dispatch branch for `action` lives in the app
// layer (NativeClient).

import Foundation
import NativeAgentCore
import PersistenceCore

public enum MemoryKindBackfill {

    /// Approval action id. Distinct from wave-1's "memory.repair" so the
    /// existing repair executor can never half-fire on this payload.
    public static let action = "memory.kind_backfill"

    /// Payload discriminator (mirrors the wave-1 payload "kind" convention).
    public static let payloadKindValue = "memory.kind_backfill.rows"

    /// Stamp kind under <dataRoot>/memory/repairs/ (same idempotence dir the
    /// wave-1 stagers use).
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
        try await AppleFoundationModelsAdapter.classify(content: content, into: taxonomy)
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

    /// Idempotent staging entry point (call on launch, after the wave-1
    /// repair stagers). Returns the approval id when a card exists after
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
            NSLog("[kindBackfill] dedupe scan failed: \(String(describing: error))")
            return nil
        }
        if let existing = pending.first(where: { payloadKind($0.payload) == payloadKindValue }) {
            let rows = rowProposals(fromPayload: existing.payload)
            do {
                try await ensureInboxCard(dataRoot: dataRoot, approvalId: existing.id, rows: rows)
                writeStamp(approvalId: existing.id, dataRoot: dataRoot)
                return existing.id
            } catch {
                NSLog("[kindBackfill] card ensure failed: \(String(describing: error))")
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
            NSLog("[kindBackfill] detection failed: \(String(describing: error))")
            return nil
        }
        guard !rows.isEmpty else { return nil }

        let title = "Memory: classify \(rows.count) legacy memories into kinds"
        let reason = "These memories carry no kind, so the kind-scoped decay and "
            + "supersession semantics you approved can't see them. Approve to stamp each row "
            + "with the LLM-proposed kind listed (metadata only — content, embeddings and "
            + "ranking inputs other than kind are untouched, written through the normal memory "
            + "write path); deny to leave every row exactly as it is."
        let body: JSONValue = .object([
            "title": .string(title),
            "action": .string(action),
            "risk": .string("medium"),
            "reason": .string(reason),
            "payload": payload(rows: rows),
        ])
        do {
            let approvalId = try await createApproval(body)
            // Card failure fails the stage (no stamp) — a stamped backfill
            // with no visible card would be invisible forever (wave-1 rule).
            try await ensureInboxCard(dataRoot: dataRoot, approvalId: approvalId, rows: rows)
            writeStamp(approvalId: approvalId, dataRoot: dataRoot)
            return approvalId
        } catch {
            NSLog("[kindBackfill] stage failed: \(String(describing: error))")
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
    /// Metadata is read-merge-written through MemoryStorage.updateMemory so
    /// the UserMD/Spotlight/KG hooks fire. KNOWN narrow race (same as the
    /// bridge's pin path): a concurrent metadata write between read and
    /// write loses — acceptable for a user-tapped approval apply.
    /// NOTE: updateMemory bumps updated_at, so a row backfilled into a
    /// decaying kind starts its decay clock at apply time — conservative
    /// (decay fires later, never earlier; recall quality never reduced).
    public static func apply(
        _ rows: [RowProposal],
        storage: MemoryStorage
    ) async throws -> ApplyOutcome {
        var outcome = ApplyOutcome()
        for row in rows {
            guard let mem = try await storage.memory(id: row.id) else {
                outcome.failed[row.id] = "row not found"
                continue
            }
            guard MemoryStorage.contentHash(mem.content) == row.contentHash else {
                outcome.skippedStale.append(row.id)
                continue
            }
            guard MemoryKindStamp.isClassifiable(mem.metadata) else {
                outcome.skippedStale.append(row.id)
                continue
            }
            guard MemoryKindStamp.taxonomy.contains(row.proposedKind) else {
                outcome.failed[row.id] = "proposed kind not in taxonomy: \(row.proposedKind)"
                continue
            }
            var meta: [String: JSONValue] = [:]
            if case .object(let existing)? = mem.metadata { meta = existing }
            meta["kind"] = .string(row.proposedKind)
            meta["kind_source"] = .string(MemoryKindStamp.backfillSource)
            meta["kind_backfilled_at"] = .string(MemoryStorage.nowISO8601())
            let patch = MemoryPatch(metadata: .object(meta))
            guard try await storage.updateMemory(id: row.id, patch: patch) != nil else {
                outcome.failed[row.id] = "update returned no row"
                continue
            }
            outcome.applied.append(row.id)
        }
        return outcome
    }

    // MARK: - Inbox card (PersistenceCore — wave-1 ensureInboxCard shape)

    /// Card id == approval id (InboxView routes approve/reject through
    /// inboxAction(id) → resolveApproval(id)). Idempotent whole-file scan
    /// before append, inside the same flock critical section.
    static func ensureInboxCard(
        dataRoot: URL,
        approvalId: String,
        rows: [RowProposal]
    ) async throws {
        let inboxPath = dataRoot
            .appendingPathComponent("notifications", isDirectory: true)
            .appendingPathComponent("inbox.jsonl")
        // Per-kind counts for the summary line.
        var counts: [String: Int] = [:]
        for row in rows { counts[row.proposedKind, default: 0] += 1 }
        let summary = counts.sorted { $0.value > $1.value }
            .map { "\($0.key) ×\($0.value)" }
            .joined(separator: ", ")
        let detail = rows
            .map { "[\($0.id)]\nPROPOSED KIND: \($0.proposedKind)\nMEMORY: \($0.contentPreview)" }
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
        // Idempotent append: shared bounded-scan helper replaces the per-append
        // whole-inbox slurp. The staged-stamp file remains the primary re-stage
        // guard; this is the second layer.
        try await appendUniqueById(card, to: inboxPath, using: SwiftNativePersistenceCore())
    }

    // MARK: - Stamps (idempotence + cancel-restage; wave-1 shape)

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
            try FileManager.default.createDirectory(
                at: path.deletingLastPathComponent(), withIntermediateDirectories: true)
            try stamp.serializedData(pretty: true).write(to: path, options: .atomic)
        } catch {
            NSLog("[kindBackfill] stamp write failed: \(String(describing: error))")
        }
    }

    /// Canceled decision (or a failed apply): clear the stamp so the next
    /// pass re-detects and re-stages a fresh card.
    public static func clearStamp(dataRoot: URL) {
        try? FileManager.default.removeItem(at: stampPath(dataRoot: dataRoot))
    }
}
