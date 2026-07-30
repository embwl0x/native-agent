import Foundation
import NativeAgentCore
import PersistenceCore
import MemoryV2
import MCPDispatcher
import KnowledgeGraph
import PersonaEngine
import ProviderRouting
import TrustCenter
import Dispatcher
import MacControl
import Context
import SwarmRuns
import WorkshopExecution

// MARK: - Memory tools

extension SwiftToolDispatcher {
    static let maxRecallK: Int = 20
    /// Total `content` character budget across one recall result set.
    /// Full content rides along for the top-ranked hits until the budget
    /// is spent; every hit after that returns preview-only with an
    /// explanatory note. Worst case at the per-row cap
    /// (memoryRecallContentCap = 2000) that is 6 full rows (~3k tokens) —
    /// bounded no matter what k was requested.
    static let recallContentBudgetChars: Int = 12_000

    /// Clamp a requested recall k into [1, maxRecallK].
    static func cappedRecallK(_ requested: Int) -> Int {
        min(max(1, requested), maxRecallK)
    }

    /// Serialize recall hits with the total-content budget applied IN RANK
    /// ORDER: once a hit's content no longer fits the remaining budget,
    /// that hit and every later one degrade to preview-only with a note.
    /// Ranking, row selection, previews, and metadata are untouched.
    static func recallHitsJSON(_ hits: [MemoryRecallHit]) -> [JSONValue] {
        var remainingBudget = recallContentBudgetChars
        var budgetSpent = false
        return hits.map { hit in
            var d: [String: JSONValue] = [
                "preview": .string(hit.preview),
                "score": .double(hit.score),
            ]
            if let id = memoryHitId(hit) {
                d["id"] = .string(id)
            }
            // U3 wave-1 item 1: surface the full memory text (sentence-
            // safe capped at memoryRecallContentCap upstream) — returning
            // only the 200-char preview was the read-side truncation
            // Agent felt. Ranking and row selection are unchanged.
            if let content = hit.content {
                if !budgetSpent, content.count <= remainingBudget {
                    d["content"] = .string(content)
                    remainingBudget -= content.count
                } else {
                    budgetSpent = true
                    d["content_note"] = .string(
                        "content omitted — total recall content budget "
                        + "(\(recallContentBudgetChars) chars) spent on higher-ranked hits; "
                        + "preview only. Narrow the query or lower k for full text.")
                }
            }
            return .object(d)
        }
    }

    private static func memoryHitId(_ hit: MemoryRecallHit) -> String? {
        guard case .object(let extras)? = hit.extras,
              case .string(let id)? = extras["id"] else {
            return nil
        }
        let trimmed = id.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }


    func impl_recall_memory(
        input: [String: JSONValue],
        surface: String = "chat"
    ) async throws -> JSONValue {
        let query = try requireString(input, "query")
        let k = optionalInt(input, "k") ?? optionalInt(input, "limit") ?? 5
        // Review blocker (2026-06-10): k had no ceiling — clamp to
        // [1, maxRecallK] before it reaches the recaller.
        let cappedK = Self.cappedRecallK(k)
        let hits: [MemoryRecallHit]
        let disclosureFilteredCount: Int
        do {
            let response = try await memoryV2.recall(MemoryV2RecallRequest(
                text: query,
                topK: cappedK,
                // Slot id → MemoryV2 persona vocabulary; resident recalls
                // unfiltered (see memoryRecallPersonaFilter).
                persona: memoryRecallPersonaFilter(ChatTurnRuntimeContext.current?.personaID),
                surface: surface
            ))
            hits = response.hits
            disclosureFilteredCount = response.disclosureFilteredCount
        } catch {
            // Keep the KG fallback usable, but never describe a MemoryV2 outage
            // as an ordinary successful empty recall. The model can answer from
            // fallback evidence while remaining honest about degraded memory.
            return .object([
                "status": .string("degraded"),
                "memory_available": .bool(false),
                "fallback_source": .string("knowledge_graph"),
                "error": .string("semantic_memory_unavailable"),
                "hits": .array(try await knowledgeGraphRecallFallback(query: query, k: cappedK)),
            ])
        }
        let arr: [JSONValue]
        if hits.isEmpty, disclosureFilteredCount == 0 {
            // Swift-native cutover memory parity: the Swift memory table can be empty
            // after cutover while the native KG already contains useful long-
            // term facts. Preserve `recall_memory` as Agent's broad recall
            // surface by falling back to KG entity summaries only when
            // semantic memories return no hits. The disclosureFilteredCount
            // guard is load-bearing (gpt-5.5, 2026-07-20): KG facts are
            // indexed FROM memory records and the KG read path has no
            // disclosure check — falling back on a filtered-empty result
            // would leak denied local_private content to restricted surfaces
            // through the side door.
            arr = try await knowledgeGraphRecallFallback(query: query, k: cappedK)
        } else {
            // Review blocker (2026-06-10): per-result-set content budget —
            // see recallHitsJSON / recallContentBudgetChars.
            arr = Self.recallHitsJSON(hits)
        }
        return .object([
            "status": .string("ok"),
            "memory_available": .bool(true),
            "disclosure_filtered_count": .int(Int64(disclosureFilteredCount)),
            "hits": .array(arr),
        ])
    }

    /// commit_memory — Agent's long-term memory WRITE path. Daemon parity for
    /// the tool deleted in the Python→Swift chat cutover (~2026-05-17).
    ///
    /// Routes to `SwiftNativeMemoryV2.shared.store(content:source:metadata:)`.
    /// `kind` is threaded through `metadata.kind` so it rides U3's existing
    /// write-time kind stamper (MemoryKindStamp.stampingDefaultKind, called
    /// inside store()) — a caller-provided kind is honored verbatim and never
    /// overwritten; we do NOT invent a parallel metadata shape. tags /
    /// confidence / importance ride alongside in the same metadata object.
    ///
    /// Duplicate policy remains owned by MemoryV2's canonical write gates and
    /// approval-gated consolidation. The rejected detached dedup observer no
    /// longer runs after inserts.
    ///
    /// On a successful store we emit a `memory.commit` event into the traces
    /// ledger (traces/events.jsonl) for stall-visibility — the same append path
    /// LLMCallTelemetry / ChatToolDispatchTracer use. Trace failure is loud
    /// (logged to stderr) but NEVER fails the tool: the durable write already
    /// landed.
    func impl_commit_memory(input: [String: JSONValue]) async throws -> JSONValue {
        let text = try requireString(input, "text")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else {
            // Empty-text rejection: a no-op write is never a successful commit.
            throw AutonomyGateError.toolDenied(
                reason: "SwiftToolDispatcher: commit_memory requires non-empty 'text'"
            )
        }

        // Schema defaults mirror the daemon: kind "note", confidence 0.8,
        // importance 0.5, tags [].
        let kind = optionalString(input, "kind")?
            .trimmingCharacters(in: .whitespacesAndNewlines) ?? "note"
        let tags = Self.stringArray(input["tags"])
        let confidence = Self.optionalNumber(input["confidence"]) ?? 0.8
        let importance = Self.optionalNumber(input["importance"]) ?? 0.5

        // Build metadata. kind rides metadata.kind (the convention
        // MemoryKindStamp / MemoryRecallScoring.kind(of:) read); store() honors
        // a caller kind verbatim. tags/confidence/importance carried alongside.
        var meta: [String: JSONValue] = [
            "kind": .string(kind),
            "confidence": .double(confidence),
            "importance": .double(importance),
        ]
        if !tags.isEmpty {
            meta["tags"] = .array(tags.map { .string($0) })
        }

        let record: MemoryRecord
        do {
            record = try await memoryV2.store(
                content: text,
                source: "chat.commit_memory",
                metadata: .object(meta)
            )
        } catch {
            // Tombstoned (denylist/paraphrase) or storage-unavailable: surface a
            // failure envelope the tool loop classifies as failed, not a crash.
            return .object([
                "status": .string("failed"),
                "reason": .string("\(error)"),
            ])
        }

        // Stall-visibility trace. Best-effort: a trace IO failure must not fail
        // the tool — the write already succeeded.
        await emitMemoryCommitTrace(
            id: record.id,
            kind: kind,
            source: "chat.commit_memory",
            textLength: text.count
        )

        // R13: first-class correction lineage. When the model names the memory
        // this fact CORRECTS, mark the old row lifecycle=corrected with a
        // lineage link to the new one (single transaction in storage). The
        // outcome is reported honestly either way — a miss (unknown id /
        // already-terminal row) is not a silent no-op.
        var correctionField: JSONValue = .null
        if let corrects = optionalString(input, "corrects")?
            .trimmingCharacters(in: .whitespacesAndNewlines), !corrects.isEmpty {
            let reason = optionalString(input, "correction_reason")?
                .trimmingCharacters(in: .whitespacesAndNewlines)
            do {
                let marked = try await memoryV2.markCorrected(
                    id: corrects,
                    by: record.id,
                    reason: (reason?.isEmpty == false) ? reason : nil
                )
                correctionField = .object([
                    "corrected_id": .string(corrects),
                    "applied": .bool(marked),
                    "note": .string(marked
                        ? "Old memory marked corrected; it no longer surfaces in recall."
                        : "No active memory with that id was eligible to correct (unknown id, or already corrected/deleted). The new fact was still saved."),
                ])
            } catch {
                // A storage failure is NOT the same as an ineligible id —
                // report it as what it is, never as a benign miss.
                correctionField = .object([
                    "corrected_id": .string(corrects),
                    "applied": .bool(false),
                    "note": .string("Correction write failed (\(error)). The new fact was still saved; retry the correction."),
                ])
            }
        }

        // Return payload mirrors the daemon: {id, layer, status ok}.
        var payload: [String: JSONValue] = [
            "status": .string("ok"),
            "id": .string(record.id),
            "layer": .string(record.layer ?? "semantic"),
        ]
        if case .object = correctionField { payload["correction"] = correctionField }
        return .object(payload)
    }

    /// Append a `memory.commit` row to `<dataRoot>/traces/events.jsonl` using
    /// the same flock + appendJSONL path as ChatToolDispatchTracer /
    /// LLMCallTelemetry. Non-fatal: logs to stderr on failure.
    private func emitMemoryCommitTrace(
        id: String,
        kind: String,
        source: String,
        textLength: Int
    ) async {
        let tracesPath = dataRoot
            .appendingPathComponent("traces", isDirectory: true)
            .appendingPathComponent("events.jsonl")
        // Turn Inspector W1: correlate the commit to its turn. Unbound → "unknown".
        let turnId = TurnTraceContext.turnId ?? "unknown"
        let payload: JSONValue = .object([
            "id": .string(id),
            "kind": .string(kind),
            "source": .string(source),
            "textLength": .int(Int64(textLength)),
            "turnId": .string(turnId),
        ])
        // Turn Inspector W1: mirror onto the bus + per-day turn_traces lane
        // (fire-and-forget; skipped when no turn is bound). Carries the memory
        // id / kind / source / length only — never the committed text body.
        TurnTraceBus.fireFromContext(kind: "memory.commit", payload: payload)
        let row: JSONValue = .object([
            "id": .string(UUID().uuidString.lowercased()),
            "kind": .string("memory.commit"),
            "title": .string("commit_memory"),
            "status": .string("ok"),
            "payload": payload,
            "createdAt": .string(ISO8601DateFormatter().string(from: Date())),
        ])
        let persistence = SwiftNativePersistenceCore()
        do {
            // Same 5000-line cap discipline as ChatToolDispatchTrace — a new
            // uncapped writer would regrow the feed W-G just bounded.
            try await appendJSONLCapped(
                row, to: tracesPath, using: persistence,
                logLabel: "SwiftToolDispatcher.memoryCommit"
            )
        } catch {
            FileHandle.standardError.write(
                Data("SwiftToolDispatcher: memory.commit trace append failed: \(error)\n".utf8)
            )
        }
    }


    private func knowledgeGraphRecallFallback(query: String, k: Int) async throws -> [JSONValue] {
        let reader = SwiftNativeKnowledgeGraphReader(
            graphPath: knowledgeGraphPath,
            flushURL: nil
        )
        let result = try await reader.searchChecked(q: query)
        guard case .object(let obj) = result,
              case .array(let results)? = obj["results"]
        else {
            throw KnowledgeGraphReadError.malformedEnvelope(
                "recall fallback did not receive a results array"
            )
        }
        return Array(results.prefix(max(0, k))).enumerated().map { rank, item in
            guard case .object(let ent) = item else { return .object([:]) }
            let name = jsonString(ent["name"]) ?? "unknown"
            let type = jsonString(ent["type"]) ?? "entity"
            let summary = jsonString(ent["summary"]) ?? ""
            let mentions = jsonInt(ent["mention_count"]) ?? 0
            let preview = kgRecallPreview(
                name: name,
                type: type,
                summary: summary,
                factKind: jsonString(ent["fact_kind"])
            )
            var d: [String: JSONValue] = [
                "preview": .string(String(preview.prefix(300))),
                "score": .double(max(0.1, 0.72 - Double(rank) * 0.03)),
                "kg_entity_name": .string(name),
                "kg_entity_type": .string(type),
                "kg_rank": .int(Int64(rank + 1)),
                "mention_count": .int(Int64(mentions)),
            ]
            if let id = ent["id"] { d["kg_entity_id"] = id }
            return .object(d)
        }
    }

    private func kgRecallPreview(
        name: String,
        type: String,
        summary: String,
        factKind: String?
    ) -> String {
        let cleanSummary = cleanKGMemorySummary(summary, kind: factKind)
        guard type.lowercased() == "fact" else {
            if cleanSummary.isEmpty { return "\(type): \(name)" }
            return "\(type): \(name) - \(cleanSummary)"
        }

        let cleanName = cleanKGMemorySummary(name, kind: factKind)
        let body = cleanSummary.isEmpty ? cleanName : cleanSummary
        let label = (factKind?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == false)
            ? factKind!
            : "fact"
        return body.isEmpty ? "fact: \(name)" : "\(label): \(body)"
    }

    private func cleanKGMemorySummary(_ text: String, kind: String?) -> String {
        var cleaned = text
            .replacingOccurrences(
                of: #"(?i)^(?:Memory fact|Mentioned in memory)\s*:\s*"#,
                with: "",
                options: .regularExpression
            )
            .replacingOccurrences(
                of: #"(?i)^(?:Fact|Decision|Preference|Identity|Relationship|Goal|Project|Operational|Milestone|Schedule)\s*:\s*"#,
                with: "",
                options: .regularExpression
            )
            .trimmingCharacters(in: .whitespacesAndNewlines)
        cleaned = MemoryTextClip.memoryDisplayText(cleaned, kind: kind)
        return cleaned
    }
}
