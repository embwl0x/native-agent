// Only approval writes proposed kinds. Match card and approval IDs so inbox decisions reach the same owner. Stamp staging idempotently; cancellation permits
// restaging, denial prevents reproposal. Inject approval creation and pending scans from the app; ForPerson owns the visible matter.

import Foundation
import Experiences
import GRDB
import NativeAgentCore
import PersistenceCore
import NativeAgentShared

// Blueprint: | `MemoryV2+KindBackfill.swift` | Approved canonical category writes; the approval is the one matter the person sees and its owner draws its face |

/// Staging stamps: local backup/export and memory PrivacyMap, no phone sync.
public enum MemoryKindBackfill {

    /// A distinct action id keeps kind backfill separate from memory repair.
    public static let action = "memory.kind_backfill"

    public static let payloadKindValue = "memory.kind_backfill.rows"

    public static let stampKind = "memory.kind_backfill"

    // MARK: - Row proposal

    public struct RowProposal: Sendable, Equatable {
        public let id: String
        /// MemoryStorage.contentHash of the content at staging time — the apply-time stale guard (content drift → skip, never overwrite).
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

    /// Only missing or machine-default kinds are classifiable; deliberate kinds must never be reproposed.
    public static func classifiableRows(storage: MemoryStorage) async throws -> [StoredMemory] {
        try await storage.listMemories(persona: nil, status: "active", limit: nil)
            .filter { MemoryKindStamp.isClassifiable($0.metadata) }
            .sorted { $0.id < $1.id }
    }

    // MARK: - Classification

    /// Classifier unavailability and nonmember replies throw; complete-set classification owns failure scope.
    public static func foundationModelsClassifier(content: String, taxonomy: [String]) async throws -> String {
        try await OnDeviceClassification.classify(content: content, into: taxonomy)
    }

    /// Classify the complete candidate set. A failed row keeps the whole proposed classification owed; no damaged inference disappears from a card. A row the
    /// classifier cannot label stays exactly as it is and is named; the rest are proposed. Only a classifier that is unavailable fails the pass.
    public static func classify(
        rows: [StoredMemory],
        classifier: @Sendable (String, [String]) async throws -> String
    ) async throws -> (proposals: [RowProposal], unclassified: [(id: String, reason: String)]) {
        var out: [RowProposal] = []
        var unclassified: [(id: String, reason: String)] = []
        for row in rows {
            let label: String
            do { label = try await classifier(row.content, MemoryKindStamp.taxonomy) }
            catch FoundationModelsError.unavailable { throw FoundationModelsError.unavailable }
            catch {
                unclassified.append((row.id, error.localizedDescription))
                continue
            }
            guard MemoryKindStamp.taxonomy.contains(label) else {
                unclassified.append((row.id, "returned an unknown kind: \(label)"))
                continue
            }
            out.append(RowProposal(
                id: row.id,
                contentHash: MemoryStorage.contentHash(row.content),
                contentPreview: MemoryTextClip.sentenceClip(row.content, cap: 200),
                proposedKind: label
            ))
        }
        return (out, unclassified)
    }

    // MARK: - Staging

    /// Reuse pending approvals before staging so interrupted stamp writes cannot duplicate cards. Write no stamp on failed staging; pending-scan failure stages
    /// nothing and leaves later recovery possible.
    @discardableResult
    public static func stageIfNeeded(
        dataRoot: URL,
        storage: MemoryStorage,
        classifier: @Sendable (String, [String]) async throws -> String = foundationModelsClassifier,
        createApproval: @Sendable (JSONValue) async throws -> String,
        approvalIsPending: @Sendable (String) async throws -> Bool,
        listPendingBackfills: @Sendable () async throws -> [(id: String, payload: JSONValue)]
    ) async -> String? {
        do {
            if let stamped = try readStamp(dataRoot: dataRoot) { return stamped }
        } catch {
            oweFailure(error, dataRoot: dataRoot)
            return nil
        }

        // Find prior approvals before classification so an interrupted stamp write cannot duplicate the card.
        let pending: [(id: String, payload: JSONValue)]
        do {
            pending = try await listPendingBackfills()
        } catch {
            nativeLog("[kindBackfill] dedupe scan failed: \(String(describing: error))")
            oweFailure(error, dataRoot: dataRoot)
            return nil
        }
        if let existing = pending.first(where: { payloadKind($0.payload) == payloadKindValue }) {
            do {
                try writeStamp(approvalId: existing.id, dataRoot: dataRoot)
                return existing.id
            } catch {
                nativeLog("[kindBackfill] card ensure failed: \(String(describing: error))")
                oweFailure(error, dataRoot: dataRoot)
                return nil
            }
        }

        let rows: [RowProposal]
        let unclassified: [(id: String, reason: String)]
        do {
            let candidates = try await classifiableRows(storage: storage)
            guard !candidates.isEmpty else { return nil }
            (rows, unclassified) = try await classify(rows: candidates, classifier: classifier)
        } catch {
            nativeLog("[kindBackfill] detection failed: \(String(describing: error))")
            oweFailure(error, dataRoot: dataRoot)
            return nil
        }
        guard !rows.isEmpty else { return nil }

        let title = cardTitle(rows.count)
        let reason = "Approve to classify these memories with the proposed kinds through the normal memory write path. "
            + "Only kind metadata changes; content and embeddings stay intact. Replacement still requires explicit, "
            + "fingerprinted intent. Deny to leave every row as it is."
            + (unclassified.isEmpty ? "" : " \(unclassified.count) more could not be classified and stay as they are: "
                + unclassified.map { "\($0.id) (\($0.reason))" }.joined(separator: "; ") + ".")
        let body: JSONValue = .object([
            "title": .string(title),
            "action": .string(action),
            "risk": .string("medium"),
            "reason": .string(reason),
            "payload": payload(rows: rows),
        ])
        do {
            let approvalId = try await createApproval(body)
            guard try await approvalIsPending(approvalId) else {
                try writeStamp(approvalId: approvalId, dataRoot: dataRoot)
                return approvalId
            }
            try writeStamp(approvalId: approvalId, dataRoot: dataRoot)
            return approvalId
        } catch {
            nativeLog("[kindBackfill] stage failed: \(String(describing: error))")
            oweFailure(error, dataRoot: dataRoot)
            return nil
        }
    }

    /// Rows carry a missing kind, the write-time default or an unsourced note; current writes still produce them.
    static func cardTitle(_ count: Int) -> String {
        "Memory: classify \(count) unclassified memories into kinds"
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

    /// Apply only row proposals actually carried by the approved payload.
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
        public var failed: [String: String] = [:]
        public init() {}
    }

    /// Validate target existence, staged content hash, classifiable kind and taxonomy inside one merge transaction. Missing or invalid rows fail; changed rows
    /// skip as stale. Fire normal projections after commit. Applying updates the decay clock conservatively, never aging a row before approval.
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

    // MARK: - Stamps (idempotence + cancel-restage)

    public static func stampPath(dataRoot: URL) -> URL {
        dataRoot
            .appendingPathComponent("memory", isDirectory: true)
            .appendingPathComponent("repairs", isDirectory: true)
            .appendingPathComponent("\(stampKind).staged.json")
    }

    public static func readStamp(dataRoot: URL) throws -> String? {
        let data: Data
        do { data = try Data(contentsOf: stampPath(dataRoot: dataRoot)) }
        catch let error as CocoaError where error.code == .fileReadNoSuchFile { return nil }
        let parsed = try JSONValue.parse(data)
        guard
              case .object(let obj) = parsed,
              case .string(let id)? = obj["approval_id"], !id.isEmpty else {
            throw MemoryV2Error.underlying("Memory kind-backfill stamp is malformed: \(stampPath(dataRoot: dataRoot).path)")
        }
        return id
    }

    static func writeStamp(approvalId: String, dataRoot: URL) throws {
        let path = stampPath(dataRoot: dataRoot)
        let stamp: JSONValue = .object([
            "kind": .string(stampKind),
            "approval_id": .string(approvalId),
            "staged_at": .string(MemoryStorage.nowISO8601()),
        ])
        try SwiftNativePersistenceCore.writeDataAtomicDurable(stamp.serializedData(pretty: true), to: path)
        RepairOwed.settle(dataRoot, operation: "memory.kind_backfill",
            evidence: .init(source: "approval", id: approvalId))
    }

    private static func oweFailure(_ error: Error, dataRoot: URL) {
        guard !(error is CancellationError) else { return }
        RepairOwed.owe(dataRoot, id: "kind-backfill:" + UUID().uuidString,
            kind: .act, operation: "memory.kind_backfill", owner: "MemoryKindBackfill",
            words: "Memory classification is still owed: \(error.localizedDescription). Repair the classifier or named store before staging the complete card.")
    }

    /// Canceled decision (or a failed apply): clear the stamp so the next pass re-detects and re-stages a fresh card.
    public static func clearStamp(dataRoot: URL) {
        do { try FileManager.default.removeItem(at: stampPath(dataRoot: dataRoot)) }
        catch let error as CocoaError where error.code == .fileNoSuchFile { return }
        catch { oweFailure(error, dataRoot: dataRoot) }
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
