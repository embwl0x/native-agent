import Foundation
import CryptoKit
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
            let temporal = memoryHitTemporalData(hit)
            if !temporal.isEmpty {
                d["temporal"] = .object(temporal)
                d["temporal_note"] = .string(
                    "Recorded validity dates are not a current-status check; observed_at is when evidence was observed.")
            }
            // U3 wave-1 item 1: surface the full memory text (sentence-
            // safe capped at memoryRecallContentCap upstream) — returning
            // only the 200-char preview was the read-side truncation
            // Agent felt. Ranking and row selection are unchanged.
            if let content = hit.content {
                let fullCharacterCount = memoryHitFullContentCharacterCount(hit, content: content)
                let upstreamTruncated = fullCharacterCount > Int64(content.count)
                if !budgetSpent, content.count <= remainingBudget {
                    d["content"] = .string(content)
                    remainingBudget -= content.count
                    if upstreamTruncated {
                        d["content_truncated"] = .bool(true)
                        d["full_content_chars"] = .int(fullCharacterCount)
                        d["content_note"] = .string(
                            "Excerpt only — the stored memory exceeds the per-result content limit. "
                            + "A narrower query or lower k does not remove that limit.")
                    }
                } else {
                    budgetSpent = true
                    d["content_truncated"] = .bool(true)
                    d["full_content_chars"] = .int(fullCharacterCount)
                    d["content_note"] = .string(
                        "content omitted — total recall content budget "
                        + "(\(recallContentBudgetChars) chars) spent on higher-ranked hits; "
                        + (upstreamTruncated
                            ? "preview only. Narrow the query or lower k for the bounded excerpt, not the full stored memory."
                            : "preview only. Narrow the query or lower k for full text."))
                }
            }
            if d["content_truncated"] == .bool(true), let id = memoryHitId(hit) {
                d["read_more"] = .object([
                    "tool": .string("recall_memory"), "memory_id": .string(id),
                    "offset": .int(0), "max_characters": .int(Int64(memoryRecallContentCap)),
                ])
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

    private static func memoryHitFullContentCharacterCount(_ hit: MemoryRecallHit, content: String) -> Int64 {
        guard case .object(let extras)? = hit.extras,
              case .int(let count)? = extras["full_content_chars"],
              count >= Int64(content.count) else { return Int64(content.count) }
        return count
    }

    /// Keep meaningful canonical dates without restoring storage timestamp,
    /// session, or retrieval-backend noise. Never forward arbitrary extras or
    /// truncate an invalid date into something that looks authoritative.
    private static func memoryHitTemporalData(_ hit: MemoryRecallHit) -> [String: JSONValue] {
        guard case .object(let extras)? = hit.extras else { return [:] }
        var temporal: [String: JSONValue] = [:]
        for key in ["valid_from", "valid_to", "observed_at"] {
            guard case .string(let value)? = extras[key],
                  value.utf8.count <= 64,
                  MemoryRecallScoring.parseTimestamp(value) != nil else { continue }
            temporal[key] = .string(value)
        }
        return temporal
    }


    func impl_recall_memory(
        input: [String: JSONValue],
        surface: String = "chat"
    ) async throws -> JSONValue {
        // Strict structured bindings may populate unused optionals with null
        // or empty strings. Those are absence, not a second requested mode.
        let supplied = input.filter { _, value in
            if value == .null { return false }
            if case .string(let text) = value {
                return !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            }
            return true
        }
        if let rawID = supplied["memory_id"] {
            guard case .string(let id) = rawID,
                  !id.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
                  supplied["query"] == nil, supplied["k"] == nil, supplied["limit"] == nil else {
                throw AutonomyGateError.toolDenied(reason: "Use either query search or memory_id paging, not both.")
            }
            return try await readMemoryPage(id: id, input: supplied, surface: surface)
        }
        guard supplied["offset"] == nil, supplied["max_characters"] == nil,
              supplied["expected_content_sha256"] == nil else {
            throw AutonomyGateError.toolDenied(reason: "offset, max_characters, and expected_content_sha256 require memory_id.")
        }
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
            try Task.checkCancellation()
            // Keep the KG fallback usable, but never describe a MemoryV2 outage
            // as an ordinary successful empty recall. The model can answer from
            // fallback evidence while remaining honest about degraded memory.
            let fallback = try await knowledgeGraphRecallFallback(query: query, k: cappedK, surface: surface)
            return .object([
                "status": .string("degraded"),
                "memory_available": .bool(false),
                "fallback_source": .string("knowledge_graph"),
                "error": .string(fallback.canonicalUnavailable ? "canonical_memory_unavailable" : "semantic_memory_unavailable"),
                "hits": .array(fallback.hits),
            ])
        }
        let arr: [JSONValue]
        if hits.isEmpty, disclosureFilteredCount == 0 {
            // KG is a candidate source, never an alternate authority. Storage
            // can exclude retired records before disclosureFilteredCount is
            // computed, so even this zero-count path must recheck each record.
            let fallback = try await knowledgeGraphRecallFallback(query: query, k: cappedK, surface: surface)
            if fallback.canonicalUnavailable {
                return .object([
                    "status": .string("degraded"), "memory_available": .bool(false),
                    "fallback_source": .string("knowledge_graph"),
                    "error": .string("canonical_memory_unavailable"), "hits": .array([]),
                ])
            }
            arr = fallback.hits
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

    private func readMemoryPage(id: String, input: [String: JSONValue], surface: String) async throws -> JSONValue {
        func integer(_ key: String, default fallback: Int) throws -> Int {
            guard let raw = input[key] else { return fallback }
            let value: Int?
            switch raw {
            case .int(let number): value = Int(exactly: number)
            case .double(let number): value = Int(exactly: number)
            default: value = nil
            }
            guard let value else {
                throw AutonomyGateError.toolDenied(reason: "\(key) must be a representable integer.")
            }
            return value
        }
        let offset = try integer("offset", default: 0)
        let requested = try integer("max_characters", default: memoryRecallContentCap)
        guard offset >= 0, requested > 0 else {
            throw AutonomyGateError.toolDenied(reason: "offset must be nonnegative and max_characters must be positive.")
        }
        let expectedHash: String?
        if let raw = input["expected_content_sha256"] {
            guard case .string(let value) = raw, value.utf8.count == 64,
                  value.lowercased().utf8.allSatisfy({ (48...57).contains($0) || (97...102).contains($0) }) else {
                throw AutonomyGateError.toolDenied(reason: "expected_content_sha256 must be a 64-character hexadecimal hash from a previous page.")
            }
            expectedHash = value.lowercased()
        } else {
            expectedHash = nil
        }
        guard let record = try await memoryV2.readMemoryRecord(
            id: id, persona: memoryRecallPersonaFilter(ChatTurnRuntimeContext.current?.personaID), surface: surface
        ) else {
            // Missing, retired, tombstoned and disallowed IDs are indistinguishable.
            // Never query KG as an alternate way around this exact-record gate.
            return .object(["status": .string("not_found")])
        }
        let text = MemoryTextClip.memoryDisplayText(record.text, kind: record.memoryKind)
        let contentHash = SHA256.hash(data: Data(text.utf8)).map { String(format: "%02x", $0) }.joined()
        // Eligibility was checked before exposing any version information.
        // The hash describes exactly the normalized display text whose
        // Character offsets are paged, not storage bookkeeping timestamps.
        if let expectedHash, expectedHash != contentHash {
            return .object([
                "status": .string("record_changed"), "id": .string(record.id),
                "content_sha256": .string(contentHash), "restart_at": .int(0),
                "note": .string("The memory text changed. Discard earlier pages and restart at offset 0; do not combine versions."),
            ])
        }
        let fullCount = text.count
        let start = min(offset, fullCount)
        let content = String(text.dropFirst(start).prefix(min(requested, memoryRecallContentCap)))
        let next = start + content.count
        var result: [String: JSONValue] = [
            "status": .string("ok"), "id": .string(record.id),
            "content_sha256": .string(contentHash),
            "content": .string(content), "offset": .int(Int64(start)),
            "full_content_chars": .int(Int64(fullCount)),
            "content_truncated": .bool(start > 0 || next < fullCount),
            "next_offset": next < fullCount ? .int(Int64(next)) : .null,
        ]
        if next < fullCount {
            result["read_more"] = .object([
                "tool": .string("recall_memory"), "memory_id": .string(record.id),
                "offset": .int(Int64(next)), "max_characters": .int(Int64(min(requested, memoryRecallContentCap))),
                "expected_content_sha256": .string(contentHash),
            ])
        }
        if offset > 0, expectedHash == nil {
            result["consistency_note"] = .string("This continuation was not version-verified. Compare content_sha256 with earlier pages before combining them; use read_more to keep subsequent pages bound to this version.")
        }
        let temporal = memoryTemporalData(record)
        if !temporal.isEmpty {
            result["temporal"] = .object(temporal)
            result["temporal_note"] = .string("Recorded validity dates are not a current-status check; observed_at is when evidence was observed.")
        }
        return .object(result)
    }

    private func memoryTemporalData(_ record: MemoryRecord) -> [String: JSONValue] {
        let extras: [String: JSONValue] = [
            "valid_from": record.validFrom.map(JSONValue.string) ?? .null,
            "valid_to": record.validTo.map(JSONValue.string) ?? .null,
            "observed_at": record.observedAt.map(JSONValue.string) ?? .null,
        ]
        return Self.memoryHitTemporalData(MemoryRecallHit(score: 0, preview: "", extras: .object(extras)))
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
        if let rawTopics = input["context_topics"] {
            guard case .array(let values) = rawTopics else {
                throw AutonomyGateError.toolDenied(reason: "context_topics must be an array")
            }
            // Strict provider schemas can materialize every optional array as
            // `[]`. That is the wire-equivalent of omission, not an attempt to
            // scope an ordinary fact as a correction.
            if values.isEmpty {
                // Leave the metadata absent so recall cannot mistake an empty
                // strict-schema placeholder for a real contextual boundary.
            } else if kind.lowercased() != "correction" || values.count > 8 {
                throw AutonomyGateError.toolDenied(reason: "context_topics requires a correction and 1–8 topic phrases")
            } else {
                var topics: [JSONValue] = []
                for value in values {
                    guard case .string(let raw) = value else {
                        throw AutonomyGateError.toolDenied(reason: "context_topics must contain strings")
                    }
                    let topic = raw.trimmingCharacters(in: .whitespacesAndNewlines)
                    guard !topic.isEmpty, topic.count <= 120 else {
                        throw AutonomyGateError.toolDenied(reason: "context_topics must contain nonempty phrases of at most 120 characters")
                    }
                    topics.append(.string(topic))
                }
                meta["context_topics"] = .array(topics)
            }
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
            if corrects == record.id {
                correctionField = .object([
                    "corrected_id": .string(corrects),
                    "applied": .bool(false),
                    "note": .string("The saved text resolved to the same existing memory. No self-correction was applied; this call did not retire that record."),
                ])
            } else {
                do {
                    let marked = try await memoryV2.markCorrected(
                        id: corrects,
                        by: record.id,
                        reason: (reason?.isEmpty == false) ? reason : nil
                    )
                    if marked {
                        await FluidContextToolScope.current?.recordAppliedMemoryCorrection(
                            recordID: corrects, replacementID: record.id
                        )
                    }
                    correctionField = .object([
                        "corrected_id": .string(corrects),
                        "applied": .bool(marked),
                        "note": .string(marked
                            ? "Old memory marked corrected; it no longer surfaces in recall."
                            : "Correction was not applied: the old memory or its replacement was missing or no longer active and recall-eligible. The save completed before this check; no correction lineage was written."),
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
            try await appendPathOwnedJSONL(
                row, to: tracesPath, using: persistence,
                logLabel: "SwiftToolDispatcher.memoryCommit"
            )
        } catch {
            FileHandle.standardError.write(
                Data("SwiftToolDispatcher: memory.commit trace append failed: \(error)\n".utf8)
            )
        }
    }


    private func knowledgeGraphRecallFallback(
        query: String, k: Int, surface: String
    ) async throws -> (hits: [JSONValue], canonicalUnavailable: Bool) {
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
        var hits: [MemoryRecallHit] = []
        var ranks: [Int] = []
        var seen: Set<String> = []
        // Preserve the existing candidate bound; no scan or extra ranking.
        for (rank, item) in results.prefix(max(0, k)).enumerated() {
            try Task.checkCancellation()
            // Aggregate entities' last_memory_id is not complete provenance.
            // Unlinked legacy graph prose remains available via search_kg, not
            // as a way around canonical memory disclosure or retirement.
            guard case .object(let entity) = item,
                  jsonString(entity["type"])?.lowercased() == "fact",
                  let id = jsonString(entity["memory_id"])?
                    .trimmingCharacters(in: .whitespacesAndNewlines),
                  !id.isEmpty, id.utf8.count <= 512, seen.insert(id).inserted else { continue }
            let record: MemoryRecord?
            do {
                record = try await memoryV2.readMemoryRecord(
                    id: id, persona: memoryRecallPersonaFilter(ChatTurnRuntimeContext.current?.personaID),
                    surface: surface
                )
            } catch {
                try Task.checkCancellation()
                // Without the canonical owner, no graph summary can establish
                // current eligibility. Discard partial evidence on this failure.
                return ([], true)
            }
            guard let record else { continue }
            let text = MemoryTextClip.memoryDisplayText(record.text, kind: record.memoryKind)
            var extras = memoryTemporalData(record)
            extras["id"] = .string(record.id)
            extras["full_content_chars"] = .int(Int64(text.count))
            hits.append(MemoryRecallHit(
                score: 0, preview: MemoryTextClip.sentenceClip(text, cap: 300),
                content: MemoryTextClip.sentenceClip(text, cap: memoryRecallContentCap),
                extras: .object(extras)
            ))
            ranks.append(rank + 1)
        }
        let rendered = zip(Self.recallHitsJSON(hits), ranks).map { value, rank -> JSONValue in
            guard case .object(var object) = value else { return value }
            // KG order is not a semantic similarity score. Do not fabricate one.
            object.removeValue(forKey: "score")
            object["kg_rank"] = .int(Int64(rank))
            object["retrieval_source"] = .string("knowledge_graph_candidate_canonical_memory")
            return .object(object)
        }
        return (rendered, false)
    }

}
