import Foundation
import CognitiveSubstrate
import CryptoKit
import NativeAgentCore
import PersistenceCore
import TurnTrace
import ToolRegistry
import MemoryV2
import Context
import PersonaEngine
import ProviderRouting
import TrustCenter
import Dispatcher
import MacControl
import SwarmRuns
import WorkshopExecution
// Blueprint: | `SwiftToolDispatcher+MemoryTools.swift` | `SwiftToolDispatcher`: counted/capped recall and versioned record pages, `cappedRecallK`, `recallHitsJSON`, `provenanceMetadata` |

// MARK: - Memory tools

extension SwiftToolDispatcher {
    /// Project typed memory causes through the shared tool envelope.
    static func memoryFailure(_ error: any Error) -> JSONValue {
        let cause: any Error
        switch error {
        case let error as MemoryV2Error: cause = error.failure
        case let error as MemoryStorageError: cause = error.failure
        case let error as EmbeddingError: cause = error.failure
        case let error as UserMDGeneratorError: cause = error.failure
        default: cause = error
        }
        let result = ChatToolOutcome.failure(error: cause)
        if case .object(var fields) = result,
           let storage = error as? MemoryStorageError, let evidence = storage.epochEvidence {
            fields["evidence"] = evidence
            return .object(fields)
        }
        return result
    }

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
    static func recallHitsJSON(_ hits: [MemoryRecallHit], dataRoot: URL) -> [JSONValue] {
        var remainingBudget = recallContentBudgetChars
        var budgetSpent = false
        return hits.map { hit in
            var d: [String: JSONValue] = [
                "preview": .string(hit.preview),
                "score": .double(hit.score),
            ]
            d.merge(MemoryDataProvenance.fields(in: hit.extras, dataRoot: dataRoot)) { _, value in value }
            if let id = memoryHitId(hit) {
                d["id"] = .string(id)
            }
            let temporal = memoryHitTemporalData(hit)
            if !temporal.isEmpty {
                d["temporal"] = .object(temporal)
                d["temporal_note"] = .string(
                    "Recorded validity dates are not a current-status check; observed_at is when evidence was observed.")
            }
            if let provenance = memoryProvenanceDisplay(hit.extras) {
                d["provenance"] = .string(provenance)
            }
            if case .object(let extras)? = hit.extras {
                for key in ["sense_versions", "sense_warning", "origin"] {
                    if let value = extras[key] { d[key] = value }
                }
            }
            // Recall and context use the same readable age tag.
            if let ts = hit.ts, let recorded = MemoryRecallScoring.parseTimestamp(ts) {
                d["age"] = .string(ContextMemoryLead.ageTag(
                    recordedAt: recorded, now: Date(), calendar: Calendar.current
                ))
            }
            // Content is capped upstream; this projection preserves ranking and row selection.
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

    /// Unknown provenance is absent; an invalid display name is dropped without rejecting the memory.
    /// Bounded display names prevent delimiters or control characters from forging provenance claims.
    static func provenanceMetadata(_ input: [String: JSONValue]) -> [String: JSONValue] {
        func text(_ key: String) -> String? {
            guard case .string(let raw)? = input[key] else { return nil }
            let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
            return trimmed.isEmpty ? nil : trimmed
        }
        guard let raw = text("provenance")?.lowercased(),
              let kind = ContextMemoryProvenance.Kind(rawValue: raw) else { return [:] }
        var out: [String: JSONValue] = ["provenance": .string(kind.rawValue)]
        if let by = (text("provenance_by") ?? text("source")).flatMap(ContextMemoryLead.validDisplayName) {
            out["provenance_by"] = .string(by)
        }
        return out
    }

    /// Recall and context share one provenance vocabulary; unstamped rows remain absent.
    static func memoryProvenanceDisplay(_ extras: JSONValue?) -> String? {
        guard case .object(let object)? = extras,
              case .string(let raw)? = object["provenance"],
              let kind = ContextMemoryProvenance.Kind(rawValue: raw.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()) else { return nil }
        // Revalidate stored names so recall cannot carry a forged provenance claim.
        let by = object["provenance_by"]?.stringValue.flatMap(ContextMemoryLead.validDisplayName)
        return ContextMemoryProvenance(kind: kind, by: by).text
    }


    func impl_recall_memory(
        input: [String: JSONValue],
        surface: String = "chat"
    ) async throws -> JSONValue {
        // Strict structured bindings may populate unused optionals with null
        // or empty strings. Those are absence, not a second requested mode.
        let supplied = input.filter { key, value in
            if value == .null { return false }
            // A zero offset alone does not request paging.
            if key == "offset", value == .int(0) || value == .double(0) || value == .string("0") { return false }
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
        guard supplied["max_characters"] == nil,
              supplied["expected_content_sha256"] == nil else {
            throw AutonomyGateError.toolDenied(reason: "max_characters and expected_content_sha256 require memory_id.")
        }
        let offset: Int
        if let raw = supplied["offset"] {
            offset = raw.exactIntegerValue ?? -1
            guard offset >= 0 else {
                throw AutonomyGateError.toolDenied(reason: "offset must be a nonnegative representable integer from next_offset.")
            }
        } else { offset = 0 }
        let query = try requireString(input, "query")
        let k = Self.jsonInt(input["k"]) ?? Self.jsonInt(input["limit"]) ?? 5
        // Bound the requested hit count before recall.
        let cappedK = Self.cappedRecallK(k)
        let response: MemoryV2RecallResponse
        let hits: [MemoryRecallHit]
        let disclosureFilteredCount: Int
        do {
            response = try await memoryV2.recall(MemoryV2RecallRequest(
                text: query,
                topK: cappedK,
                // Slot id → MemoryV2 persona vocabulary; resident recalls
                // unfiltered for every persona slot.
                persona: nil,
                surface: surface,
                requiresRelevance: true,
                offset: offset
            ))
            hits = response.hits
            disclosureFilteredCount = response.disclosureFilteredCount
            TurnTraceBus.fireFromContext(kind: "memory.recall", surface: surface,
                payload: .object(response.timings.mapValues { .double($0) }))
        } catch {
            try Task.checkCancellation()
            // The owner supplies the cause and recovery; recall adds only its
            // availability fields, never a diagnosis inferred from failure.
            if case .object(var failure) = Self.memoryFailure(error) {
                failure["memory_available"] = .bool(false)
                failure["hits"] = .array([])
                return .object(failure)
            }
            throw error
        }
        let arr = Self.recallHitsJSON(hits, dataRoot: dataRoot)
        var result: [String: JSONValue] = [
            "status": .string("ok"),
            "memory_available": .bool(true),
            "disclosure_filtered_count": .int(Int64(disclosureFilteredCount)),
            "hits": .array(arr),
            "count": .int(Int64(hits.count)),
            "offset": .int(Int64(offset)),
            "limit": .int(Int64(cappedK)),
            "has_more": .bool(response.hasMore),
            "next_offset": response.nextOffset.map { .int(Int64($0)) } ?? .null,
        ]
        if response.capped { result["capped"] = .bool(true) }
        else { result["total"] = .int(Int64(response.total)) }
        if let next = response.nextOffset {
            result["read_more"] = .object(["tool": .string("recall_memory"), "query": .string(query),
                "k": .int(Int64(cappedK)), "offset": .int(Int64(next))])
            // has_more means memories not yet judged, not hits held back.
            result["detail"] = .string("These are the relevant ones among the \(next) likeliest memories; "
                + "the rest have not been judged yet. read_more judges the next ones.")
        }
        if hits.isEmpty, disclosureFilteredCount == 0, !response.hasMore {
            result["detail"] = .string("No relevant saved memory found for this query.")
        }
        return .object(result)
    }

    private func readMemoryPage(id: String, input: [String: JSONValue], surface: String) async throws -> JSONValue {
        func integer(_ key: String, default fallback: Int) throws -> Int {
            guard let raw = input[key] else { return fallback }
            guard let value = raw.exactIntegerValue else {
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
            id: id, persona: nil, surface: surface
        ) else {
            // Missing, retired, tombstoned and disallowed IDs are indistinguishable.
            // Never query KG as an alternate way around this exact-record gate.
            return .object(["status": .string("not_found"),
                "detail": .string("Memory id \(id) was not found for this recall. Call memory.recall with query to find matching ids, or memory.list to list ids.")])
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
            "count": .int(Int64(content.count)), "total": .int(Int64(fullCount)),
            "has_more": .bool(next < fullCount),
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
        if let provenance = Self.memoryProvenanceDisplay(record.extras) {
            result["provenance"] = .string(provenance)
        }
        result.merge(MemoryDataProvenance.fields(in: record.extras, dataRoot: dataRoot)) { _, value in value }
        if let origin = MemoryMoments.recallOrigin(source: record.sourceRunId, metadata: record.extras, dataRoot: dataRoot) {
            result["origin"] = origin
        }
        if let warning = MemorySenseProvenance.warning(in: record.extras) {
            result["sense_warning"] = .string(warning)
        }
        if case .object(let extras)? = record.extras, let versions = extras["sense_versions"] {
            result["sense_versions"] = versions
        }
        let temporal = memoryTemporalData(record)
        if !temporal.isEmpty {
            result["temporal"] = .object(temporal)
            result["temporal_note"] = .string("Recorded validity dates are not a current-status check; observed_at is when evidence was observed.")
        }
        // Why this is believed, not just what is believed. The record has
        // carried an evidence column since v7 and the exact read never showed
        // it, so "I remember that" and "I have a source for that" were
        // indistinguishable. Absence is stated rather than implied.
        var evidenceTruncated = false
        if let projected = Self.memoryEvidenceProjection(record.evidence, truncated: &evidenceTruncated) {
            result["evidence"] = projected
            result["evidence_present"] = .bool(true)
            // Always present when evidence is: the note points at this field,
            // so its absence must not be the only way to read "nothing was cut".
            result["evidence_truncated"] = .bool(evidenceTruncated)
            result["evidence_note"] = .string("Recorded at write time, as recorded, bounded for display; evidence_truncated says whether anything was cut — the memory's own claim about its source, not independent verification.")
        } else {
            result["evidence_present"] = .bool(false)
            result["evidence_note"] = .string("No evidence was recorded with this memory. Its text is an assertion with no stored source.")
        }
        return .object(result)
    }

    /// A bounded, shape-preserving view of the stored evidence. The column is
    /// free-form JSON lifted from the write's metadata, so it is clamped
    /// (strings, breadth, depth) rather than reinterpreted: inventing a schema
    /// here would misreport what was actually recorded. Returns nil when there
    /// is nothing recorded, so the caller can say so explicitly.
    static func memoryEvidenceProjection(
        _ value: JSONValue?, depth: Int = 0, truncated: inout Bool
    ) -> JSONValue? {
        guard let value, value != .null else { return nil }
        switch value {
        case .string(let text):
            guard text.count > 400 else { return .string(text) }
            truncated = true
            return .string(String(text.prefix(400)) + "…")
        case .array(let items):
            guard depth < 3 else { truncated = true; return .string("…") }
            if items.count > 6 { truncated = true }
            return .array(items.prefix(6).compactMap {
                memoryEvidenceProjection($0, depth: depth + 1, truncated: &truncated)
            })
        case .object(let object):
            guard depth < 3 else { truncated = true; return .string("…") }
            let keys = object.keys.sorted()
            if keys.count > 12 { truncated = true }
            var out: [String: JSONValue] = [:]
            for key in keys.prefix(12) {
                if let projected = memoryEvidenceProjection(object[key], depth: depth + 1, truncated: &truncated) {
                    out[key] = projected
                }
            }
            return out.isEmpty ? nil : .object(out)
        default:
            return value
        }
    }

    private func memoryTemporalData(_ record: MemoryRecord) -> [String: JSONValue] {
        let extras: [String: JSONValue] = [
            "valid_from": record.validFrom.map(JSONValue.string) ?? .null,
            "valid_to": record.validTo.map(JSONValue.string) ?? .null,
            "observed_at": record.observedAt.map(JSONValue.string) ?? .null,
        ]
        return Self.memoryHitTemporalData(MemoryRecallHit(score: 0, preview: "", extras: .object(extras)))
    }

    /// Only correction, instruction, preference, note and unclaimed kinds may carry context scope.
    func kindAcceptsContextTopics(_ kind: String?) -> Bool {
        guard let kind else { return true }
        return ["correction", "instruction", "preference", MemoryKindStamp.genericCommitKind].contains(
            kind.trimmingCharacters(in: .whitespacesAndNewlines).lowercased())
    }

    /// MemoryV2 owns the durable write, duplicate policy and metadata kind stamping.
    func impl_commit_memory(input: [String: JSONValue]) async throws -> JSONValue {
        // Collect all argument faults into one refusal.
        var problems: [String] = []
        var supersedes: [String] = []
        if let supplied = input["supersedes"], supplied != .null {
            if case .array(let ids) = supplied,
               ids.allSatisfy({ if case .string(let id) = $0 { return !id.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }; return false }) {
                supersedes = Array(Set(Self.stringArray(supplied).map {
                    $0.trimmingCharacters(in: .whitespacesAndNewlines)
                })).sorted()
            } else {
                problems.append("'supersedes' must be an array of non-empty memory ids")
            }
        }

        // Missing/unknown kinds use the store default and backfill; explicit `instruction` preserves agreement lookup.
        let requestedKind = optionalString(input, "kind")
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() }
            .flatMap { $0.isEmpty ? nil : $0 }
        let kind = requestedKind.flatMap {
            MemoryKindStamp.writerKinds.contains($0) || $0 == "instruction" ? $0 : nil
        }

        var text = ""
        if case .string(let rawText)? = input["text"] {
            text = rawText.trimmingCharacters(in: .whitespacesAndNewlines)
            if text.isEmpty {
                // A no-op write is never a successful commit.
                problems.append("'text' must be a non-empty string")
            }
        } else {
            problems.append("'text' is required and must be a string")
        }

        // Scope hints never reject a memory; accepted kinds keep up to eight valid phrases.
        var validatedTopics: [JSONValue]?
        if kindAcceptsContextTopics(kind), case .array(let values)? = input["context_topics"] {
            // Empty optional arrays are omission; never store an empty scope.
            let topics: [JSONValue] = values
                .compactMap { value in
                    guard case .string(let raw) = value else { return nil }
                    let topic = raw.trimmingCharacters(in: .whitespacesAndNewlines)
                    guard !topic.isEmpty, topic.count <= 120 else { return nil }
                    return JSONValue.string(topic)
                }
                .prefix(8)
                .map { $0 }
            if !topics.isEmpty { validatedTopics = topics }
        }

        guard problems.isEmpty else {
            throw AutonomyGateError.toolDenied(
                reason: "SwiftToolDispatcher: commit_memory rejected "
                    + "\(problems.count) argument problem(s): "
                    + problems.joined(separator: "; ")
            )
        }
        let tags = Self.stringArray(input["tags"])
        let confidence = input["confidence"]?.numberValue(coercingStrings: false, finiteOnly: false) ?? 0.8
        let importance = input["importance"]?.numberValue(coercingStrings: false, finiteOnly: false) ?? 0.5

        // Build metadata. kind rides metadata.kind (the convention
        // MemoryKindStamp / MemoryRecallScoring.kind(of:) read); store() honors
        // a caller kind verbatim. tags/confidence/importance carried alongside.
        var meta: [String: JSONValue] = [
            "confidence": .double(confidence),
            "importance": .double(importance),
        ]
        if let kind { meta["kind"] = .string(kind) }
        if !tags.isEmpty {
            meta["tags"] = .array(tags.map { .string($0) })
        }
        // Flat provenance serves recall and context; absence stays absent.
        for (key, value) in Self.provenanceMetadata(input) {
            meta[key] = value
        }
        // The turn it was kept in, stamped the way moments are: a correction
        // knows the exchange that caused it (the miss ledger links it).
        meta.merge(MemoryMoments.turnMetadata(turnId: TurnTraceContext.turnId, origin: AfterTurnSource.origin)) { current, _ in current }
        // Her own save: the turn that saved it is its source, and its time.
        let origin = AfterTurnSource.origin
        meta.merge(MemoryMoments.sourceMetadata(sessionId: origin?.sessionId, messageId: origin?.messageId,
            turnId: TurnTraceContext.turnId, at: origin?.occurredAt ?? Date(), speaker: "self", words: nil)) { current, _ in current }
        if let validatedTopics {
            meta["context_topics"] = .array(validatedTopics)
        }
        // The miss ledger's lesson, named once, here.
        if kind == "correction" {
            meta["lesson"] = .string(MemoryRecoveryReadout.lesson(metadata: .object(meta), text: text))
        }

        let record: MemoryRecord
        let corrects = optionalString(input, "corrects")
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }.flatMap { $0.isEmpty ? nil : $0 }
        let correctionReason = optionalString(input, "correction_reason")
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }.flatMap { $0.isEmpty ? nil : $0 }
        do {
            record = try await memoryV2.store(
                content: text,
                source: "chat.commit_memory",
                metadata: .object(meta),
                supersedes: supersedes,
                corrects: corrects,
                correctionReason: correctionReason
            )
        } catch {
            // Keep the owner's refusal, cancellation or failure and its recovery.
            return Self.memoryFailure(error)
        }

        // Stall-visibility trace. Best-effort: a trace IO failure must not fail
        // the tool — the write already succeeded.
        await emitMemoryCommitTrace(
            id: record.id,
            kind: record.memoryKind ?? kind ?? MemoryKindStamp.defaultKind,
            source: "chat.commit_memory",
            textLength: text.count
        )
        // A replacement awaiting admission demotes what it replaces only when its vector lands.
        let admitted = Self.memoryMetadataValue(record.extras, key: MemoryStorage.pendingAdmissionKey) != .bool(true)
        for id in supersedes where admitted {
            await FluidContextToolScope.current?.recordAppliedMemoryCorrection(recordID: id, replacementID: record.id)
        }

        // Replacement admission owns the lineage write; report its canonical
        // outcome or the intent still owed by a cold save.
        var correctionField: JSONValue = .null
        if let corrects, !supersedes.contains(corrects) {
            if corrects == record.id {
                correctionField = .object([
                    "corrected_id": .string(corrects),
                    "applied": .bool(false),
                    "note": .string("The saved text resolved to the same existing memory. No self-correction was applied; this call did not retire that record."),
                ])
            } else {
                do {
                    let pending = MemoryStorage.owedSupersessions(record.extras).contains { $0.targetId == corrects }
                    let target = try await memoryV2.authorityRecord(id: corrects)
                    let marked = target.map { Self.memoryMetadataValue($0.extras, key: "corrected_by") == .string(record.id) } ?? false
                    if marked {
                        await FluidContextToolScope.current?.recordAppliedMemoryCorrection(
                            recordID: corrects, replacementID: record.id
                        )
                    }
                    correctionField = .object([
                        "corrected_id": .string(corrects),
                        "applied": .bool(marked),
                        "pending_admission": .bool(pending && !marked),
                        "note": .string(marked
                            ? "Old memory marked corrected; it no longer surfaces in recall."
                            : (pending ? "Replacement saved pending vector admission; correction will apply atomically if the target still matches when admitted."
                                : "Correction was not applied: the old memory was missing or no longer eligible.")),
                    ])
                } catch {
                    // A storage failure is NOT the same as an ineligible id —
                    // report it as what it is, never as a benign miss.
                    correctionField = .object([
                        "corrected_id": .string(corrects),
                        "applied": .bool(false),
                        "note": .string("The save completed; reading its correction outcome failed (\(error)). Inspect the canonical records before retrying."),
                    ])
                }
            }
        }

        var payload: [String: JSONValue] = [
            "status": .string("ok"),
            "id": .string(record.id),
            "layer": .string(record.layer ?? "semantic"),
            // Report the stored kind independently of its storage layer.
            "kind": .string(record.memoryKind ?? kind ?? MemoryKindStamp.defaultKind),
        ]
        if let requestedKind, requestedKind != kind { payload["kind_requested"] = .string(requestedKind) }
        if case .object = correctionField { payload["correction"] = correctionField }
        if !supersedes.isEmpty {
            payload[admitted ? "superseded" : "supersedes_once_admitted"] = .array(supersedes.map(JSONValue.string))
        } else if let validatedTopics {
            // Scope narrows automatic context; matching agreement subjects never imply replacement lineage.
            let topics = Set(validatedTopics.compactMap { value -> String? in
                guard case .string(let topic) = value else { return nil }
                return topic.lowercased()
            })
            do {
                let existing = try await memoryV2.listMemory(kind: nil).filter { row in
                    guard row.id != record.id, (row.status ?? "active") == "active",
                          MemoryLifecycle.isRecallEligible(row.lifecycle),
                          let disclosure = MemoryRecordDisclosurePolicy.classify(row),
                          disclosure.permits(surface: ChatTurnRuntimeContext.current?.surface ?? "chat", personaID: record.personaId)
                    else { return false }
                    let rowTopics = Set(Self.stringArray(Self.memoryMetadataValue(row.extras, key: "context_topics")).map { $0.lowercased() })
                    let rowKind = row.memoryKind ?? MemoryRecallScoring.kind(of: row.extras)
                    if !rowTopics.isEmpty { return rowTopics == topics }
                    // Legacy agreements may have declared their subject only
                    // as tags. Exact labels are evidence; similarity is not.
                    guard rowKind == "instruction" || rowKind == "correction" else { return false }
                    return topics.isDisjoint(with: MemoryRecoveryReadout.genericSubjects)
                        && topics.isSubset(of: Set((row.tags ?? []).map { $0.lowercased() }))
                }.sorted {
                    let left = MemoryRecallScoring.parseTimestamp($0.updatedAt ?? $0.createdAt) ?? .distantPast
                    let right = MemoryRecallScoring.parseTimestamp($1.updatedAt ?? $1.createdAt) ?? .distantPast
                    return left == right ? $0.id < $1.id : left > right
                }
                var remaining = Self.recallContentBudgetChars
                payload["existing_agreements"] = .array(existing.prefix(8).map { row in
                    var fields: [String: JSONValue] = ["id": .string(row.id), "recorded_at": .string(row.createdAt)]
                    if let provenance = Self.memoryProvenanceDisplay(row.extras) { fields["provenance"] = .string(provenance) }
                    if let origin = MemoryMoments.recallOrigin(source: row.sourceRunId, metadata: row.extras, dataRoot: dataRoot) { fields["origin"] = origin }
                    if row.text.count <= remaining {
                        fields["text"] = .string(row.text)
                        fields.merge(MemoryDataProvenance.fields(in: row.extras)) { _, value in value }
                        remaining -= row.text.count
                    } else {
                        fields["content_omitted"] = .bool(true)
                        fields["full_content_chars"] = .int(Int64(row.text.count))
                    }
                    fields["read_more"] = .object(["action": .string("memory.recall"), "memory_id": .string(row.id)])
                    return .object(fields)
                })
                payload["existing_agreements_count"] = .int(Int64(existing.count))
                if existing.count > 8 {
                    payload["existing_agreements_more"] = .object([
                        "action": .string("memory.recall"), "query": .string(topics.sorted().joined(separator: " ")),
                    ])
                }
                if !existing.isEmpty {
                    payload["agreement_note"] = .string("These active records declare the same subject/scope; they are not automatically replacements. If the new decision explicitly changes one, use its id with supersedes or corrects. The old rule then stays in history and leaves automatic context. Similarity and age grant no authority.")
                }
            } catch {
                if error is CancellationError { throw error }
                payload["existing_agreements_error"] = .string("Saved, but the existing-agreement lookup failed: \(error)")
            }
        }
        return .object(payload)
    }

    private static func memoryMetadataValue(_ extras: JSONValue?, key: String) -> JSONValue? {
        guard case .object(let fields)? = extras else { return nil }
        return fields[key]
    }

    /// Record memory identity and measurements without the committed text.
    private func emitMemoryCommitTrace(
        id: String,
        kind: String,
        source: String,
        textLength: Int
    ) async {
        let turnId = TurnTraceContext.turnId ?? "unknown"
        let payload: JSONValue = .object([
            "id": .string(id),
            "kind": .string(kind),
            "source": .string(source),
            "textLength": .int(Int64(textLength)),
            "turnId": .string(turnId),
        ])
        let event = TurnTraceEvent(kind: "memory.commit", title: "commit_memory", status: "ok",
            payload: payload, createdAt: ISO8601DateFormatter().string(from: Date()), turnId: TurnTraceContext.turnId)
        if TurnTraceContext.turnId != nil { TurnTraceBus.fire(event, on: TurnTraceContext.bus ?? .shared) }
        else { await TurnTracePersistLane(dataRootOverride: dataRoot).append(event) }
    }
}
