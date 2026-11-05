import Foundation
import CryptoKit
import MemoryV2
import NativeAgentCore
import PersistenceCore
import ProviderRouting
// Blueprint: | `REMConsolidator+GrowthEviction.swift` | `REMConsolidator`: `runGrowthEviction` |

extension REMConsolidator {
    // MARK: GROWTH.md eviction-to-KG

    /// Evict only contiguous exact approved paragraphs; preserve other authored text.
    func runGrowthEviction(proposalRows: [REMProposalRow]? = nil) async throws -> Int {
        let proposalRows = try proposalRows ?? REMProposalStore(dataRoot: dataRoot).loadAllStrictly()
        let growth = personaRoot.appendingPathComponent("GROWTH.md")
        guard FileManager.default.fileExists(atPath: growth.path) else { return 0 }

        // Distill outside the shared GROWTH lock; splice only if the exact slice still stands under it.
        let planned = Self.evictionRange(
            in: try String(contentsOf: growth, encoding: .utf8), proposalRows: proposalRows
        )
        // Surface distillation failure only after locked repair can settle prior work.
        let distilled: Result<(slice: String, node: KGNode), Error>?
        if let planned {
            do { distilled = .success((planned.slice, try await distillToKGNode(planned.slice))) }
            catch { distilled = .failure(error) }
        } else { distilled = nil }
        return try await SwiftNativePersistenceCore.withFileLock(growth) {
            try await self.evictGrowthUnderLock(growth: growth, proposalRows: proposalRows, distilled: distilled)
        }
    }

    private static func evictionRange(
        in body: String, proposalRows: [REMProposalRow]
    ) -> (range: Range<String.Index>, slice: String)? {
        if body.count <= REMConstants._REM_GROWTH_CHAR_CAP { return nil }

        // Only exact approved paragraphs establish evictable boundaries.
        let approvedRows = proposalRows
            .filter { $0.status == "approved" && REMProposalStore.supportsProposalTarget($0.targetDoc) }
        let lessons = Set(approvedRows.map { $0.proposalText.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }.flatMap { REMGrowthWriter.entryParagraphRanges(body, $0) })
            .sorted { $0.lowerBound == $1.lowerBound ? $0.upperBound > $1.upperBound : $0.lowerBound < $1.lowerBound }
        guard var range = lessons.first else { return nil }
        // Keep one recoverable contiguous passage; authored text ends selection and only whitespace may join approved paragraphs.
        for next in lessons.dropFirst() {
            if body[range].count >= REMConstants._REM_GROWTH_EVICT_CHARS { break }
            guard next.lowerBound >= range.upperBound else { continue }
            guard body[range.upperBound..<next.lowerBound].allSatisfy(\.isWhitespace) else { break }
            range = range.lowerBound..<next.upperBound
        }
        return (range, String(body[range]))
    }

    /// The caller must hold the GROWTH file lock.
    private func evictGrowthUnderLock(
        growth: URL, proposalRows: [REMProposalRow], distilled: Result<(slice: String, node: KGNode), Error>?
    ) async throws -> Int {
        // Unreadable GROWTH aborts while retained history stays pending.
        let body = try String(contentsOf: growth, encoding: .utf8)
        // Reconcile pending history before the size cap can skip the pass.
        try await REMGrowthEvictionHistory.reconcilePending(
            growthBody: body,
            dataRoot: dataRoot,
            kgNodeExists: { [dataRoot] id in
                try await Self.growthDistillationNodeExists(id: id, dataRoot: dataRoot)
            }
        )
        // Failed distillation preserves the GROWTH source.
        guard let planned = Self.evictionRange(in: body, proposalRows: proposalRows),
              let distilled = try distilled?.get(), planned.slice == distilled.slice else { return 0 }
        let evictedSlice = planned.slice
        let evictableStart = planned.range.lowerBound, cursor = planned.range.upperBound
        let approvedRows = proposalRows
            .filter { $0.status == "approved" && REMProposalStore.supportsProposalTarget($0.targetDoc) }
        let kgNode = distilled.node
        // Retain exact source and pending history before graph merge or splice; only a successful splice can certify eviction.
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
        // Check cancellation before either commit so cancellation during distillation leaves graph and GROWTH untouched.
        try Task.checkCancellation()
        // Retain the passage in the graph before removing it from GROWTH; merge failure aborts.
        try await appendKGNode(kgNode)

        var rebuilt = String(body[..<evictableStart])
        rebuilt += String(body[cursor...])
        try SwiftNativePersistenceCore.writeDataAtomicDurable(Data(rebuilt.utf8), to: growth)
        // Mark committed only after the splice; failed history writes leave retention pending without overclaiming eviction.
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

    /// Derive approval provenance from existing proposal rows without persisting a second authority.
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
            model: nil, tools: nil, call: LLMCall(turn: nil, surface: "rem", purpose: "rem")
        )
        let summary = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        // An empty response fails eviction with source intact.
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
            // Key by exact source passage so a retry after graph-only success upserts instead of duplicating.
            id: id,
            // Keep the canonical retained-passage pointer whole after the bounded summary so compressed nodes remain expandable.
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

    /// Corroborate eviction with the matching graph node; unavailable graph evidence leaves original history pending.
    fileprivate static func growthDistillationNodeExists(id: String, dataRoot: URL) async throws -> Bool {
        let sqliteURL = dataRoot
            .appendingPathComponent("memory", isDirectory: true)
            .appendingPathComponent("memory.sqlite")
        let indexer = try SwiftNativeKnowledgeGraphIndexer(memorySQLitePath: sqliteURL)
        return try await indexer.growthDistillationExists(id: id)
    }

    /// Graph merge must succeed before GROWTH removal so the passage cannot disappear from both stores.
    private func appendKGNode(_ node: KGNode) async throws {
        let kgDir = dataRoot.appendingPathComponent("memory", isDirectory: true)
        let indexer = try SwiftNativeKnowledgeGraphIndexer(
            memorySQLitePath: kgDir.appendingPathComponent("memory.sqlite")
        )
        try await indexer.upsertGrowthDistillation(
            id: node.id,
            summary: node.summary,
            sourceLines: node.sourceLines,
            createdAt: node.createdAt
        )
    }

    private func isoNow() -> String {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime]
        return f.string(from: clock())
    }
}
