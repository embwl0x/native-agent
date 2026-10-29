import Foundation
import CryptoKit
import MemoryV2
import NativeAgentCore
import PersistenceCore
import ProviderRouting
// Blueprint: | `REMConsolidator+GrowthEviction.swift` | `REMConsolidator`: `runGrowthEviction` |

extension REMConsolidator {
    // MARK: GROWTH.md eviction-to-KG

    /// Over the character cap, distill the oldest contiguous exact approved
    /// paragraphs to the KG and remove them; all other authored text stays.
    /// Returns characters evicted, or zero when no passage qualifies.
    func runGrowthEviction(proposalRows: [REMProposalRow]? = nil) async throws -> Int {
        let proposalRows = try proposalRows ?? REMProposalStore(dataRoot: dataRoot).loadAllStrictly()
        let growth = personaRoot.appendingPathComponent("GROWTH.md")
        guard FileManager.default.fileExists(atPath: growth.path) else { return 0 }

        // Distill outside GROWTH.md's shared writer lock; splice under it only if the exact slice still stands.
        let planned = Self.evictionRange(
            in: try String(contentsOf: growth, encoding: .utf8), proposalRows: proposalRows
        )
        // A distill failure surfaces inside the lock, after the repair pass.
        let distilled: Result<(slice: String, node: KGNode), Error>?
        if let planned {
            do { distilled = .success((planned.slice, try await distillToKGNode(planned.slice))) }
            catch { distilled = .failure(error) }
        } else { distilled = nil }
        return try await SwiftNativePersistenceCore.withFileLock(growth) {
            try await self.evictGrowthUnderLock(growth: growth, proposalRows: proposalRows, distilled: distilled)
        }
    }

    /// The oldest evictable slice of an over-cap body, or nil.
    private static func evictionRange(
        in body: String, proposalRows: [REMProposalRow]
    ) -> (range: Range<String.Index>, slice: String)? {
        if body.count <= REMConstants._REM_GROWTH_CHAR_CAP { return nil }

        // Exact approved paragraphs are the only evictable boundaries.
        let approvedRows = proposalRows
            .filter { $0.status == "approved" && REMProposalStore.supportsProposalTarget($0.targetDoc) }
        let lessons = Set(approvedRows.map { $0.proposalText.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }.flatMap { REMGrowthWriter.entryParagraphRanges(body, $0) })
            .sorted { $0.lowerBound == $1.lowerBound ? $0.upperBound > $1.upperBound : $0.lowerBound < $1.lowerBound }
        guard var range = lessons.first else { return nil }
        // Keep one contiguous passage for recovery; only whitespace may join
        // approved paragraphs, and authored text ends the pass.
        for next in lessons.dropFirst() {
            if body[range].count >= REMConstants._REM_GROWTH_EVICT_CHARS { break }
            guard next.lowerBound >= range.upperBound else { continue }
            guard body[range.upperBound..<next.lowerBound].allSatisfy(\.isWhitespace) else { break }
            range = range.lowerBound..<next.upperBound
        }
        return (range, String(body[range]))
    }

    /// The locked critical section of `runGrowthEviction`. Must only be
    /// called while holding the GROWTH.md flock.
    private func evictGrowthUnderLock(
        growth: URL, proposalRows: [REMProposalRow], distilled: Result<(slice: String, node: KGNode), Error>?
    ) async throws -> Int {
        // An unreadable GROWTH.md aborts the pass; pending history stays pending.
        let body = try String(contentsOf: growth, encoding: .utf8)
        // Reconcile pending history against the locked body before the cap can skip this pass.
        await REMGrowthEvictionHistory.reconcilePending(
            growthBody: body,
            dataRoot: dataRoot,
            kgNodeExists: { [dataRoot] id in
                await Self.growthDistillationNodeExists(id: id, dataRoot: dataRoot)
            }
        )
        // Failed distillation leaves the source passage intact in GROWTH.md.
        guard let planned = Self.evictionRange(in: body, proposalRows: proposalRows),
              let distilled = try distilled?.get(), planned.slice == distilled.slice else { return 0 }
        let evictedSlice = planned.slice
        let evictableStart = planned.range.lowerBound, cursor = planned.range.upperBound
        let approvedRows = proposalRows
            .filter { $0.status == "approved" && REMProposalStore.supportsProposalTarget($0.targetDoc) }
        let kgNode = distilled.node
        // Retain the exact passage under the data root before the KG merge or GROWTH splice.
        // Record pending before eviction and committed only after the splice; pending alone means retained.
        let historyRecord = REMGrowthEvictionRecord(
            id: kgNode.id,
            evictedAt: kgNode.createdAt,
            summary: kgNode.summary,
            passage: evictedSlice,
            sourceLines: kgNode.sourceLines,
            proposalRefs: Self.proposalRefs(in: evictedSlice, rows: approvedRows),
            state: .pending
        )
        try await REMGrowthEvictionHistory.append(historyRecord, dataRoot: dataRoot)
        // A cancel during the distill above (its own LLM call) must not fall
        // through to the KG+GROWTH commit pair below. One guard here covers both
        // writes: the KG-first ordering means a throw leaves GROWTH.md intact and
        // the KG untouched.
        try Task.checkCancellation()
        // KG must retain the passage before GROWTH removes it; failure aborts the pass.
        try await appendKGNode(kgNode)

        // Splice the evicted section out, leaving the preamble + remainder.
        // ONLY reached when the KG merge above succeeded.
        var rebuilt = String(body[..<evictableStart])
        rebuilt += String(body[cursor...])
        try SwiftNativePersistenceCore.writeDataAtomicDurable(Data(rebuilt.utf8), to: growth)
        // The splice landed: NOW the eviction is true, and the history may say
        // so. A failure here leaves the pending row standing — the passage is
        // retained and the record still doesn't overclaim.
        var committed = historyRecord
        committed.state = .committed
        try await REMGrowthEvictionHistory.append(committed, dataRoot: dataRoot)
        return evictedSlice.count
    }

    private struct KGNode: Codable {
        let id: String
        let summary: String
        let sourceLines: Int
        let createdAt: String
    }

    /// The approved proposals whose text sits inside this evicted slice — the
    /// approvals the retained passage came in by. Read-only over rows the store
    /// already holds; nothing new is persisted here.
    fileprivate static func proposalRefs(
        in slice: String,
        rows: [REMProposalRow]
    ) -> [REMGrowthEvictionProposalRef] {
        rows.compactMap { row in
            let text = row.proposalText.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !text.isEmpty, slice.contains(text) else { return nil }
            return REMGrowthEvictionProposalRef(
                proposalId: row.id,
                targetDoc: row.targetDoc,
                createdAt: row.createdAt,
                approvalId: row.approvalId,
                evidenceDates: row.evidenceDates
            )
        }
    }

    private func distillToKGNode(_ text: String) async throws -> KGNode {
        let prompt = try completionPolicy("growth-compression", section: "prompt", arguments: [text])
        let raw = try await llm.complete(
            prompt: prompt, system: try completionPolicy("growth-compression", section: "system"),
            model: nil, surface: "rem", purpose: "rem", tools: nil
        )
        let summary = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        // An empty response fails eviction with the GROWTH source intact.
        guard !summary.isEmpty else {
            throw NSError(
                domain: "REMConsolidator",
                code: -210,
                userInfo: [NSLocalizedDescriptionKey:
                    "GROWTH distillation returned an empty summary; refusing to "
                    + "evict the source slice."]
            )
        }
        let id = Self.growthDistillationID(text)
        return KGNode(
            // Stable over the source slice, not the model summary. If the KG
            // commit succeeds but the following GROWTH.md splice fails, the
            // next pass upserts this same entity instead of minting a duplicate.
            id: id,
            // THE NODE POINTS AT THE ORIGINAL. The id is already shared with the
            // retained-passage record, but a compressed node whose pointer is an
            // unwritten convention is a node nobody expands — so it says where
            // the full passage is, in both the SQLite and legacy-JSON paths.
            // The 400-character bound is the summary's; the pointer after it stays whole.
            summary: String(summary.prefix(400)) + "\n\n" + REMGrowthEvictionHistory.pointer(id: id),
            sourceLines: text.split(separator: "\n").count,
            createdAt: isoNow()
        )
    }

    private static func growthDistillationID(_ source: String) -> String {
        let digest = SHA256.hash(data: Data(source.utf8))
            .map { String(format: "%02x", $0) }
            .joined()
        return "growth_\(digest)"
    }

    /// Corroborating identity for a reconciled eviction: the distilled node
    /// carrying the record's id in the graph (memory.sqlite). Any failure
    /// reads as "not present" — reconciliation then leaves the row pending,
    /// which is the safe side.
    fileprivate static func growthDistillationNodeExists(id: String, dataRoot: URL) async -> Bool {
        let sqliteURL = dataRoot
            .appendingPathComponent("memory", isDirectory: true)
            .appendingPathComponent("memory.sqlite")
        guard let indexer = try? SwiftNativeKnowledgeGraphIndexer(memorySQLitePath: sqliteURL),
              let exists = try? await indexer.growthDistillationExists(id: id) else {
            return false
        }
        return exists
    }

    /// Merge a GROWTH-eviction distillation node into the graph in
    /// memory.sqlite. THROWS on any failure (no store yet included), and the
    /// caller (`runGrowthEviction`) must NOT splice the GROWTH.md slice unless
    /// this call succeeded — otherwise the slice would be gone from both
    /// GROWTH and the graph.
    private func appendKGNode(_ node: KGNode) async throws {
        let kgDir = dataRoot.appendingPathComponent("memory", isDirectory: true)
        let indexer = try SwiftNativeKnowledgeGraphIndexer(
            memorySQLitePath: kgDir.appendingPathComponent("memory.sqlite")
        )
        try await indexer.upsertGrowthDistillation(
            id: node.id,
            summary: node.summary,
            sourceLines: node.sourceLines,
            createdAt: node.createdAt,
            // The graph's own one-time legacy import source; a no-op once
            // `.kg_migrated_to_sqlite_v1` stands.
            legacyJSONPath: kgDir.appendingPathComponent("knowledge_graph.json")
        )
    }

    private func isoNow() -> String {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime]
        return f.string(from: clock())
    }
}
