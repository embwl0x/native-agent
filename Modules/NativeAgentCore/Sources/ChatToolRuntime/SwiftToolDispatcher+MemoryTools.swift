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
// Blueprint: | `SwiftToolDispatcher+MemoryTools.swift` | `SwiftToolDispatcher`, `cappedRecallK`, `recallHitsJSON`, `telling`; bounded recall |

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
    /// A total content budget bounds recall independently of requested k; later hits remain preview-only.
    static let recallContentBudgetChars: Int = 12_000

    static func cappedRecallK(_ requested: Int) -> Int {
        min(max(1, requested), maxRecallK)
    }

    /// Spend content budget in rank order; once a row does not fit, all later rows remain preview-only.
    static func recallHitsJSON(_ hits: [MemoryRecallHit], dataRoot: URL) -> [JSONValue] {
        let trust = MemoryDataProvenance.reading(hits.map(\.extras))
        var remainingBudget = recallContentBudgetChars
        var budgetSpent = false
        return hits.map { hit in
            var d: [String: JSONValue] = [
                "preview": .string(hit.preview),
                "score": .double(hit.score),
            ]
            d.merge(MemoryDataProvenance.fields(in: hit.extras, trust: trust)) { _, value in value }
            if let id = memoryHitId(hit) {
                d["id"] = .string(id)
            }
            let temporal = memoryHitTemporalData(hit)
            if !temporal.isEmpty {
                d["temporal"] = .object(temporal)
                d["temporal_note"] = .string(
                    "Recorded validity dates are not a current-status check; observed_at is when evidence was observed.")
            }
            d["provenance"] = .string(MemoryDataProvenance.lead(hit.extras, trust: trust))
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

    /// Keep meaningful canonical dates without restoring storage timestamp, session, or retrieval-backend noise. Never forward arbitrary extras or truncate an
    /// invalid date into something that looks authoritative.
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

    /// One telling as the agent states it: how (one of the stated ways), by (a name of at most 40 letters, digits, spaces and . - ') and since (an
    /// ISO-8601 date-time, not after now). Nothing stated is nil; a time with no how is kept from then, since nothing says how. Names enter
    /// model-facing lines, so a name that could forge a delimiter is refused, never trimmed into another.
    static func telling(how rawHow: JSONValue?, by rawBy: JSONValue?, since rawSince: JSONValue?,
                        names: (how: String, by: String, since: String)) throws -> MemoryRoot.Telling? {
        func text(_ value: JSONValue?, _ name: String) throws -> String? {
            switch value {
            case nil, .null?: return nil
            case .string(let raw)?:
                let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
                return trimmed.isEmpty ? nil : trimmed
            default: throw ToolFailureError("\(name) must be text.", argumentPath: name, effects: .none, status: .refused, recovery: .correctArguments)
            }
        }
        let ways = MemoryRoot.How.stated.map(\.rawValue).joined(separator: ", ")
        let by = try text(rawBy, names.by)
        let since = try text(rawSince, names.since)
        let stated = try text(rawHow, names.how)
        if stated == nil, by != nil {
            throw ToolFailureError("\(names.by) goes with \(names.how).", argumentPath: names.how, accepted: ways, effects: .none,
                code: "memory_provenance_required", status: .refused, instruction: "Name how you know it in \(names.how), with \(names.by).",
                recovery: .correctArguments)
        }
        guard stated != nil || since != nil else { return nil }
        // No how stated is the stem's kept, never a guess at how.
        var how = MemoryRoot.How.kept
        if let stated {
            guard let parsed = MemoryRoot.How(rawValue: stated.lowercased()), MemoryRoot.How.stated.contains(parsed) else {
                throw ToolFailureError("\(names.how) must be one of \(ways).", argumentPath: names.how, accepted: ways, effects: .none,
                    code: "memory_provenance_invalid", status: .refused, instruction: "Correct \(names.how).", recovery: .correctArguments)
            }
            how = parsed
        }
        if let by, MemoryRoot.validName(by) == nil {
            throw ToolFailureError("\(names.by) must be a name of at most \(MemoryRoot.nameLimit) letters, digits, spaces and . - '.",
                argumentPath: names.by, accepted: "a short name, e.g. my backup", effects: .none, code: "memory_provenance_by_invalid",
                status: .refused, instruction: "Correct \(names.by).", recovery: .correctArguments)
        }
        var date: Date?
        if let since {
            guard let parsed = MemoryRecallScoring.parseTimestamp(since), parsed <= Date() else {
                throw ToolFailureError("\(names.since) must be an ISO-8601 date-time such as 2026-10-20T00:16:38Z, not after now.",
                    argumentPath: names.since, accepted: "an ISO-8601 date-time, not after now", effects: .none, code: "memory_since_invalid",
                    status: .refused, instruction: "Correct \(names.since), or omit it for what you learn now.", recovery: .correctArguments)
            }
            date = parsed
        }
        return MemoryRoot.Telling(how: how, by: by, since: date)
    }


    func impl_recall_memory(
        turn: Turn,
        input: [String: JSONValue],
        surface: String = "chat"
    ) async throws -> JSONValue {
        // Strict structured bindings may populate unused optionals with null or empty strings. Those are absence, not a second requested mode.
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
        let cappedK = Self.cappedRecallK(k)
        let response: MemoryV2RecallResponse
        let hits: [MemoryRecallHit]
        let disclosureFilteredCount: Int
        do {
            response = try await memoryV2.recall(MemoryV2RecallRequest(
                text: query,
                topK: cappedK,
                // Slot id → MemoryV2 persona vocabulary; resident recalls unfiltered for every persona slot.
                persona: nil,
                surface: surface,
                requiresRelevance: true,
                offset: offset
            ), turn: turn)
            hits = response.hits
            disclosureFilteredCount = response.disclosureFilteredCount
            TurnTraceBus.fireFromContext(kind: "memory.recall", surface: surface,
                payload: .object(response.timings.mapValues { .double($0) }), turn: turn)
        } catch {
            try Task.checkCancellation()
            // The owner supplies the cause and recovery; recall adds only its availability fields, never a diagnosis inferred from failure.
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
            // Missing, inactive, tombstoned and disallowed IDs stay indistinguishable; KG must not bypass this exact-record gate.
            return .object(["status": .string("not_found"),
                "detail": .string("""
                    Memory id \(id) was not found for this recall. Call memory.recall with query to find matching ids, or memory.list to list \
                    ids.
                    """)])
        }
        let text = MemoryTextClip.memoryDisplayText(record.text, kind: record.memoryKind)
        let contentHash = SHA256.hash(data: Data(text.utf8)).map { String(format: "%02x", $0) }.joined()
        // Eligibility was checked before exposing any version information. The hash describes exactly the normalized display text whose Character offsets are
        // paged, not storage bookkeeping timestamps.
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
            result["consistency_note"] = .string("""
                This continuation was not version-verified. Compare content_sha256 with earlier pages before combining them; use read_more to \
                keep subsequent pages bound to this version.
                """)
        }
        let trust = MemoryDataProvenance.reading([record.extras])
        result["provenance"] = .string(MemoryDataProvenance.lead(record.extras, trust: trust))
        result["roots"] = MemoryDataProvenance.rootsJSON(record.extras, trust: trust)
        result.merge(MemoryDataProvenance.fields(in: record.extras, trust: trust)) { _, value in value }
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
        // Keep evidence distinct from belief; explicitly disclose when no source was recorded.
        var evidenceTruncated = false
        if let projected = Self.memoryEvidenceProjection(record.evidence, truncated: &evidenceTruncated) {
            result["evidence"] = projected
            result["evidence_present"] = .bool(true)
            // Always present when evidence is: the note points at this field, so its absence must not be the only way to read "nothing was cut".
            result["evidence_truncated"] = .bool(evidenceTruncated)
            result["evidence_note"] = .string("""
                Recorded at write time, as recorded, bounded for display; evidence_truncated says whether anything was cut — the memory's own \
                claim about its source, not independent verification.
                """)
        } else {
            result["evidence_present"] = .bool(false)
            result["evidence_note"] = .string("No evidence was recorded with this memory. Its text is an assertion with no stored source.")
        }
        return .object(result)
    }

    /// A bounded, shape-preserving view of the stored evidence. The column is free-form JSON lifted from the write's metadata, so it is clamped (strings,
    /// breadth, depth) rather than reinterpreted: inventing a schema here would misreport what was actually recorded. Returns nil when there is nothing
    /// recorded, so the caller can say so explicitly.
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

    /// MemoryV2 owns the durable write, duplicate policy and metadata kind stamping.
    func impl_commit_memory(turn: Turn, invocation: ChatToolInvocation, input: [String: JSONValue]) async throws -> JSONValue {
        // Collect faults so one refusal names every required correction.
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

        var kind: String?
        if let supplied = input["kind"], supplied != .null {
            if case .string(let value) = supplied, MemoryKindStamp.commitKinds.contains(value) {
                kind = value
            } else {
                problems.append("'kind' must be one of: " + MemoryKindStamp.commitKinds.joined(separator: ", ") + "; omit it when none fits")
            }
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

        var validatedTopics: [JSONValue]?
        if let supplied = input["context_topics"], supplied != .null {
            do { validatedTopics = try MemoryCommitArguments.contextTopics(supplied, kind: kind) }
            catch { problems.append(error.localizedDescription) }
        }
        func numeric(_ key: String, omitted: Double) -> Double {
            guard let supplied = input[key], supplied != .null else { return omitted }
            guard let value = supplied.numberValue(coercingStrings: false, finiteOnly: true),
                  (0...1).contains(value) else {
                problems.append("'\(key)' must be a finite number in 0...1")
                return omitted // Used only to collect faults; the guard below refuses the write.
            }
            return value
        }
        let confidence = numeric("confidence", omitted: 0.8)
        let importance = numeric("importance", omitted: 0.5)
        // How the agent knows it is this telling's root; its since is when the agent first knew it, and the write itself stays evidence.
        var telling: MemoryRoot.Telling?
        do {
            telling = try Self.telling(how: input["provenance"], by: input["provenance_by"], since: input["since"],
                                       names: ("provenance", "provenance_by", "since"))
        } catch { problems.append(error.localizedDescription) }
        let since = telling?.since

        guard problems.isEmpty else {
            throw AutonomyGateError.toolDenied(
                reason: "SwiftToolDispatcher: commit_memory rejected "
                    + "\(problems.count) argument problem(s): "
                    + problems.joined(separator: "; ")
            )
        }
        let tags = Self.stringArray(input["tags"])

        // Stamp metadata.kind using the vocabulary MemoryKindStamp and MemoryRecallScoring.kind(of:) read.
        var meta: [String: JSONValue] = [
            "confidence": .double(confidence),
            "importance": .double(importance),
        ]
        if let kind { meta["kind"] = .string(kind) }
        if !tags.isEmpty {
            meta["tags"] = .array(tags.map { .string($0) })
        }
        // Keep the saving turn’s exchange identity so the miss ledger can link corrections.
        meta.merge(MemoryDataProvenance.turnMetadata(turnId: turn.id, origin: turn.afterTurnOrigin)) { current, _ in current }
        // The agent's own save: the turn that saved it is its source; its time is when the agent first knew it.
        let origin = turn.afterTurnOrigin
        meta.merge(MemoryDataProvenance.sourceMetadata(sessionId: origin?.sessionId, messageId: origin?.messageId,
            turnId: turn.id, at: since ?? origin?.occurredAt ?? Date(), speaker: "self", words: nil)) { current, _ in current }
        if let validatedTopics {
            meta["context_topics"] = .array(validatedTopics)
        }
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
                correctionReason: correctionReason,
                // Nothing stated is kept: nothing says how the agent knows it.
                context: .init(turn: turn, senseReads: invocation.senseRead?.senseReads ?? invocation.senseReads,
                               telling: telling ?? MemoryRoot.Telling(how: .kept))
            )
        } catch {
            // Keep the owner's refusal, cancellation or failure and its recovery.
            return Self.memoryFailure(error)
        }

        // Trace failure cannot negate the already committed write.
        await emitMemoryCommitTrace(
            turn: turn,
            id: record.id,
            kind: record.memoryKind ?? kind ?? MemoryKindStamp.defaultKind,
            source: "chat.commit_memory",
            textLength: text.count
        )
        // A replacement awaiting admission demotes what it replaces only when its vector lands.
        let admitted = Self.memoryMetadataValue(record.extras, key: MemoryStorage.pendingAdmissionKey) != .bool(true)
        for id in supersedes where admitted {
            await invocation.preparedContext?.recordAppliedMemoryCorrection(recordID: id, replacementID: record.id)
        }

        // Replacement admission owns the lineage write; report its canonical outcome or the intent still owed by a cold save.
        var correctionField: JSONValue = .null
        if let corrects, !supersedes.contains(corrects) {
            if corrects == record.id {
                correctionField = .object([
                    "corrected_id": .string(corrects),
                    "applied": .bool(false),
                    "note": .string("""
                        The saved text resolved to the same existing memory. No self-correction was applied; this call did not retire that \
                        record.
                        """),
                ])
            } else {
                do {
                    let pending = try MemoryStorage.owedSupersessions(record.extras).contains { $0.targetId == corrects }
                    let target = try await memoryV2.authorityRecord(id: corrects)
                    let marked = target.map { Self.memoryMetadataValue($0.extras, key: "corrected_by") == .string(record.id) } ?? false
                    if marked {
                        await invocation.preparedContext?.recordAppliedMemoryCorrection(
                            recordID: corrects, replacementID: record.id
                        )
                    }
                    correctionField = .object([
                        "corrected_id": .string(corrects),
                        "applied": .bool(marked),
                        "pending_admission": .bool(pending && !marked),
                        "note": .string(marked
                            ? "Old memory marked corrected; it no longer surfaces in recall."
                            : (pending ? """
                                Replacement saved pending vector admission; correction will apply atomically if the target still matches when \
                                admitted.
                                """
                                : "Correction was not applied: the old memory was missing or no longer eligible.")),
                    ])
                } catch {
                    // A storage failure is NOT the same as an ineligible id — report it as what it is, never as a benign miss.
                    correctionField = .object([
                        "corrected_id": .string(corrects),
                        "applied": .null,
                        "read_error": .string(String(describing: error)),
                        "note": .string("The save completed; reading its correction outcome failed (\(error)). Inspect the canonical records before retrying."),
                    ])
                }
            }
        }

        let trust = MemoryDataProvenance.reading([record.extras])
        let firstKnown = MemoryDataProvenance.firstKnown(record.extras, trust: trust)
        var payload: [String: JSONValue] = [
            "status": .string("ok"),
            "id": .string(record.id),
            "layer": .string(record.layer ?? "semantic"),
            // Report the stored kind independently of its storage layer.
            "kind": .string(record.memoryKind ?? kind ?? MemoryKindStamp.defaultKind),
            // What was kept, as the store holds it: when it was first known, how it is known, and any steer its words carry.
            "since": firstKnown.map(JSONValue.string) ?? .null,
            "provenance": .string(MemoryDataProvenance.lead(record.extras, trust: trust)),
            "roots": MemoryDataProvenance.rootsJSON(record.extras, trust: trust),
        ]
        payload.merge(MemoryDataProvenance.fields(in: record.extras, trust: trust)) { current, _ in current }
        let first = firstKnown.flatMap(MemoryRecallScoring.parseTimestamp)
        if let since, first.map({ abs($0.timeIntervalSince(since)) >= 1 }) != false {
            payload["since_note"] = .string("""
                These words were already kept, so they keep that memory's first time (\(firstKnown ?? "unreadable")); a time moves back only \
                for words no untrusted agent steered.
                """)
        }
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
                          disclosure.permits(surface: turn.runtime?.surface ?? "chat", personaID: record.personaId)
                    else { return false }
                    let rowTopics = Set(Self.stringArray(Self.memoryMetadataValue(row.extras, key: "context_topics")).map { $0.lowercased() })
                    return !rowTopics.isEmpty && rowTopics == topics
                }.sorted {
                    let left = MemoryRecallScoring.parseTimestamp($0.updatedAt ?? $0.createdAt) ?? .distantPast
                    let right = MemoryRecallScoring.parseTimestamp($1.updatedAt ?? $1.createdAt) ?? .distantPast
                    return left == right ? $0.id < $1.id : left > right
                }
                var remaining = Self.recallContentBudgetChars
                let agreementTrust = MemoryDataProvenance.reading(Array(existing.prefix(8)).map(\.extras))
                payload["existing_agreements"] = .array(existing.prefix(8).map { row in
                    var fields: [String: JSONValue] = ["id": .string(row.id), "recorded_at": .string(row.createdAt)]
                    fields["provenance"] = .string(MemoryDataProvenance.lead(row.extras, trust: agreementTrust))
                    if let origin = MemoryMoments.recallOrigin(source: row.sourceRunId, metadata: row.extras, dataRoot: dataRoot) { fields["origin"] = origin }
                    if row.text.count <= remaining {
                        fields["text"] = .string(row.text)
                        fields.merge(MemoryDataProvenance.fields(in: row.extras, trust: agreementTrust)) { _, value in value }
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
                    payload["agreement_note"] = .string("""
                        These active records declare the same subject/scope; they are not automatically replacements. If the new decision \
                        explicitly changes one, use its id with supersedes or corrects. The old rule then stays in history and leaves automatic \
                        context. Similarity and age grant no authority.
                        """)
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
        turn: Turn,
        id: String,
        kind: String,
        source: String,
        textLength: Int
    ) async {
        let payload: JSONValue = .object([
            "id": .string(id),
            "kind": .string(kind),
            "source": .string(source),
            "textLength": .int(Int64(textLength)),
            "turnId": .string(turn.id),
        ])
        let event = TurnTraceEvent(kind: "memory.commit", title: "commit_memory", status: "ok",
            payload: payload, createdAt: ISO8601DateFormatter().string(from: Date()), turnId: turn.id, turn: turn)
        if TurnTraceContext.turnId != nil { TurnTraceBus.fire(event, on: TurnTraceContext.bus ?? .shared) }
        else { await TurnTracePersistLane(dataRootOverride: dataRoot).append(event) }
    }
}
