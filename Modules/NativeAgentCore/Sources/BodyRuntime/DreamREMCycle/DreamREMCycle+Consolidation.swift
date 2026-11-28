import Foundation
import NativeAgentCore
import NativeAgentShared
import PersistenceCore

// Blueprint: | `DreamREMCycle+Consolidation.swift` | `REMConsolidator`. |

/// Bind verbatim support to its dream entry and source evidence so approval can inspect actual writing rather than a paraphrased claim.
public struct REMSupportingPassage: Sendable, Codable, Equatable {
    /// Distinguish the dream's date from when its source material happened.
    public var dreamDate: String
    /// Reject quotes absent from their named entry before constructing support.
    public var quote: String
    /// Unestablished lived dates remain unavailable rather than supporting recurrence.
    public var livedDates: [String]
    /// Group claim-bound citations by exchange only when known.
    public var sourceRefs: [String]
    /// Only the claim-bound writer can attest support; unrelated citations cannot.
    public var claimBound: Bool

    public init(
        dreamDate: String,
        quote: String,
        livedDates: [String] = [],
        sourceRefs: [String] = [],
        claimBound: Bool = false
    ) {
        self.dreamDate = dreamDate
        self.quote = quote
        self.livedDates = livedDates
        self.sourceRefs = sourceRefs
        self.claimBound = claimBound
    }
}

/// Repeated dreams of one occasion are dwelling, never recurrence or noise.
public enum REMSupportKind: String, Sendable, Codable, Equatable {
    case recurring
    /// Keep repeated dreams of one occasion labelled without counting them as a pattern.
    case dweltOn = "dwelt_on"
    /// Absent provenance leaves recurrence unknown rather than supported.
    case provenanceUnavailable = "provenance_unavailable"
    /// Correction graduation cites its canonical memory so approval can graduate the actual retained source.
    case standing
}

extension REMConsolidator {
    private typealias SupportEvidence = [String: [(content: String, claims: [(quote: String, shownQuote: String, sourceRefs: [String])])]]

    /// Decode failures keep the weekly pass owed for retry.
    struct Distillation: Sendable {
        var proposals: [REMProposalRow] = []
        var boundProposals = 0
        var tombstoneSkips = 0
        var parseErrors: [String] = []
        var targetMismatchDrops = 0
        var evidenceDateDrops = 0
        var passageDrops = 0
    }

    private struct LLMPassageDTO: Decodable, Sendable {
        let date: String
        let quote: String
    }

    /// Use an object reply because it supports reliable model output and future fields.
    private struct LLMProposalReply: Decodable, Sendable {
        let proposals: [LLMProposalDTO]
        private enum CodingKeys: String, CodingKey { case proposals }
        /// A model sometimes answers with the list alone; the list is the same reply.
        init(from decoder: Decoder) throws {
            if let keyed = try? decoder.container(keyedBy: CodingKeys.self) {
                proposals = try keyed.decode([LLMProposalDTO].self, forKey: .proposals)
            } else {
                // The list alone must hold proposals: an empty array found anywhere inside a malformed reply is not one.
                let list = try [LLMProposalDTO](from: decoder)
                guard !list.isEmpty else {
                    throw DecodingError.dataCorrupted(.init(codingPath: decoder.codingPath, debugDescription: "An empty list is not a proposal reply."))
                }
                proposals = list
            }
        }
    }

    private struct LLMProposalDTO: Decodable, Sendable {
        let targetDoc: String
        let proposalText: String
        let evidenceDates: [String]
        let confidence: Double
        /// A proposal without a supplied passage has no verifiable support.
        let supportingPassages: [LLMPassageDTO]?
        let whatChanged: String?
        let replaced: REMReplacement?

        private enum CodingKeys: String, CodingKey {
            case targetDoc, proposalText, evidenceDates, confidence, supportingPassages, whatChanged, replaced
        }

        init(from decoder: Decoder) throws {
            let c = try decoder.container(keyedBy: CodingKeys.self)
            targetDoc = try c.decode(String.self, forKey: .targetDoc)
            proposalText = try c.decode(String.self, forKey: .proposalText)
            evidenceDates = try c.decode([String].self, forKey: .evidenceDates)
            confidence = try c.decode(Double.self, forKey: .confidence)
            guard confidence.isFinite, (0...1).contains(confidence) else {
                throw DecodingError.dataCorruptedError(forKey: .confidence, in: c,
                    debugDescription: "confidence must be a finite number in 0...1")
            }
            supportingPassages = try c.decodeIfPresent([LLMPassageDTO].self, forKey: .supportingPassages)
            whatChanged = try c.decodeIfPresent(String.self, forKey: .whatChanged)
            replaced = try c.decodeIfPresent(REMReplacement.self, forKey: .replaced)
        }
    }

    private static func isValidDate(_ s: String) -> Bool {
        s.range(of: #"^\d{4}-\d{2}-\d{2}$"#, options: .regularExpression) != nil
    }

    func consolidate(
        entries: [DreamEntry],
        growthBody: String,
        identities: [String: String],
        tombStore: REMTombstoneStore,
        system: String? = nil,
        model: String? = nil,
        surface: String,
        systemGrowthBody: String? = nil
    ) async throws -> Distillation {
        let entryDateSet = Set(entries.map { $0.date })
        let redactedEntries = entries.map { entry in
            DreamEntry(date: entry.date, filename: entry.filename.map(DreamPart.redact),
                content: entry.content.map(DreamPart.redact), size: entry.size, modifiedAt: entry.modifiedAt)
        }
        var evidence: SupportEvidence = [:]
        for (entry, shown) in zip(entries, redactedEntries) {
            guard let content = entry.content, let shownContent = shown.content else { continue }
            let sections = DreamEntryProvenance.readClaims(in: content, as: DreamEntryProvenance.self)
            // Refuse damaged-section bypasses rather than turning unreadable evidence into fewer claims.
            if let gap = sections.compactMap(\.unavailable).first {
                throw PersistenceCoreError.ioFailure("dream_diary/\(entry.filename ?? entry.date): \(gap)")
            }
            let originals = sections.flatMap(\.claims)
            let shownClaims = DreamEntryProvenance.readClaims(in: shownContent, as: DreamEntryProvenance.self).flatMap(\.claims)
            guard originals.count == shownClaims.count else { continue }
            let claims = zip(originals, shownClaims).map { claim, visible in
                (quote: DreamEntryProvenance.plain(claim.quote),
                 shownQuote: DreamEntryProvenance.plain(visible.quote),
                 sourceRefs: claim.sourceRefs.filter { DreamPart.redact($0) == $0 })
            }
            evidence[entry.date, default: []].append((DreamEntryProvenance.plain(shownContent), claims))
        }

        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        let entriesJSON = String(decoding: try encoder.encode(redactedEntries), as: UTF8.self)

        // Reuse exact live GROWTH only when it matches the target.
        let material = evidence
        let sourcePairs = Array(zip(entries, redactedEntries))
        let llm = self.llm
        var partEvidence = [
            "dates": entryDateSet.sorted().joined(separator: ", "), "whatChangedCap": String(REMConstants.whatChangedCap),
            "passageBound": REMProposalStore.growthPassageBoundSentence, "textCap": String(REMConstants._REM_PROPOSAL_TEXT_CAP),
            "proposalCap": String(REMConstants._REM_MAX_PROPOSALS),
        ]
        if system == nil || systemGrowthBody != growthBody { partEvidence["growth"] = DreamPart.redact(growthBody) }
        let part = DreamPart(mode: .rem, evidence: partEvidence, required: ["growth", "dates"], remEntries: entriesJSON) { prompt in
            let reply = try await Self.readREMReply(llm: llm, prompt: prompt, system: system, model: model, surface: surface)
            var distilled = Self.bindProposals(reply.proposals, entries: sourcePairs, dates: entryDateSet,
                evidence: material, growthBody: growthBody, identities: identities)
            let eligible = distilled.proposals.filter {
                max($0.supportingExperienceCount(identities: identities) ?? 0, $0.dreamDateCount) >= REMConstants.minimumEvidenceCount
            }
            distilled.boundProposals = distilled.proposals.count
            distilled.proposals = try await tombStore.filterTombstoned(eligible)
            distilled.tombstoneSkips = eligible.count - distilled.proposals.count
            let candidates = distilled.proposals.map { proposal in
                JSONValue.object(["id": .string(proposal.id), "text": .string(proposal.proposalText),
                    "experiences": .int(Int64(proposal.supportingExperienceCount(identities: identities) ?? 0)),
                    "support": proposal.support.map { .string($0.rawValue) } ?? .null])
            }
            return (.object(["proposals": .array(candidates)]), .rem(distilled))
        } validate: { value, reading in
            guard case .rem(var distilled)? = reading, let result = value.objectValue, result.count == 1,
                  let proposed = result["proposals"]?.arrayValue,
                  proposed.count <= REMConstants._REM_MAX_PROPOSALS else {
                throw PartCallError(code: "bad_dream_policy", message: "REM must return a bounded list of proposal IDs.")
            }
            let byID = Dictionary(uniqueKeysWithValues: distilled.proposals.map { ($0.id, $0) })
            let picked = proposed.compactMap { $0.stringValue.flatMap { byID[$0] } }
            guard picked.count == proposed.count, Set(picked.map(\.id)).count == picked.count else {
                throw PartCallError(code: "bad_dream_policy", message: "REM may select each verified proposal ID at most once.")
            }
            distilled.proposals = picked
            return .rem(distilled)
        }
        guard case .rem(let reading) = try await part.read(root: dataRoot) else {
            throw DreamREMCycleError.underlying("The dream cycle returned a reading for the wrong mode.")
        }
        return reading
    }

    private static func readREMReply(llm: any LLMClient, prompt: String, system: String?, model: String?, surface: String) async throws -> LLMProposalReply {
        let call = LLMCall(turn: nil, surface: surface, purpose: "rem")
        // A reply that cannot be read is asked for again at once, told what was wrong; only three unreadable replies are a failure.
        var request = prompt
        var asks = 0
        while true {
            let raw = try await llm.complete(prompt: request, system: system, model: model, tools: nil, call: call)
            asks += 1
            do { return try JSONValue.decodeCompletion(raw, as: LLMProposalReply.self) }
            catch {
                let fault = "decode failure: " + DreamPart.redact(String(describing: error))
                guard asks < 3 else {
                    throw DreamREMCycleError.remDecodeFailure("REM distillation could not decode the model's reply (1 failure(s)): " + fault)
                }
                request = prompt + "\n\nYour last reply could not be read (" + String(fault.prefix(300))
                    + "). Reply again with one JSON object of the form {\"proposals\": [...]} and nothing else."
            }
        }
    }

    private static func bindProposals(_ rows: [LLMProposalDTO], entries: [(DreamEntry, DreamEntry)], dates: Set<String>,
        evidence: SupportEvidence, growthBody: String,
        identities: [String: String]) -> Distillation {
        var diagnostics = Distillation()
        let proposals = proposalRows(rows, diagnostics: &diagnostics)
        var kept: [REMProposalRow] = []
        for p in proposals {
            let bad = p.evidenceDates.contains { d in
                !Self.isValidDate(d) || !dates.contains(d)
            }
            if bad {
                diagnostics.evidenceDateDrops += 1
                continue
            }
            var bound = bindSupport(p, evidence: evidence, identities: identities, diagnostics: &diagnostics)
            if let replaced = p.replaced {
                // Retain exact source bytes and actual file identity; the model's claim alone cannot establish displaced content.
                if replaced.source == "GROWTH.md", !replaced.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
                   REMGrowthWriter.containsEntryParagraph(growthBody, replaced.text) {
                    bound.replaced = replaced
                } else if let (entry, _) = entries.first(where: { original, shown in
                    replaced.source == "dream:\(original.date)" && !replaced.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                        && original.content?.contains(replaced.text) == true && shown.content?.contains(replaced.text) == true
                }) {
                    bound.replaced = REMReplacement(
                        source: "dream_diary/\(entry.filename ?? "\(entry.date).md")", text: replaced.text)
                } else {
                    bound.replaced = nil
                    diagnostics.parseErrors.append("replaced content could not be bound to its source; not recorded")
                }
            }
            kept.append(bound)
        }
        diagnostics.proposals = kept
        return diagnostics
    }

    /// Use only matching same-night entries' sources for claim support.
    private static func bindSupport(_ proposal: REMProposalRow,
        evidence: SupportEvidence,
        identities: [String: String], diagnostics: inout Distillation) -> REMProposalRow {
        var passages: [REMSupportingPassage] = []
        for passage in proposal.supportingPassages ?? [] {
            let quote = passage.quote.trimmingCharacters(in: .whitespacesAndNewlines)
            let normalized = DreamEntryProvenance.plain(quote)
            let contents = (evidence[passage.dreamDate] ?? []).filter { $0.content.contains(normalized) }
            guard !quote.isEmpty, !contents.isEmpty else {
                diagnostics.passageDrops += 1
                continue
            }
            let claims = contents.flatMap { $0.claims }.filter { $0.shownQuote.contains(normalized) }
            let exact = claims.filter { $0.quote == normalized }
            var matches = exact
            if exact.isEmpty, normalized.count >= 24 {
                let containing = claims.filter { $0.quote.contains(normalized) }
                if containing.count == 1 { matches = containing }
            }
            let refs = Set(matches.flatMap { $0.sourceRefs }).sorted()
            guard !refs.isEmpty else {
                diagnostics.passageDrops += 1
                continue
            }
            passages.append(REMSupportingPassage(
                dreamDate: passage.dreamDate,
                quote: quote,
                // Use the source's own lived-date tail rather than guessing from an identifier.
                livedDates: Array(Set(refs.compactMap { ref in
                    ref.split(separator: "@").last.map(String.init).flatMap { Self.isValidDate($0) ? $0 : nil }
                })).sorted(),
                sourceRefs: refs,
                claimBound: true
            ))
        }

        let lived = Set(passages.flatMap(\.livedDates))
        var bound = proposal
        bound.evidenceDates = Array(Set(passages.map(\.dreamDate))).sorted()
        bound.supportingPassages = passages.isEmpty ? nil : passages
        let experiences = bound.supportingExperienceCount(identities: identities) ?? 0

        let support: REMSupportKind
        if experiences >= REMConstants.minimumEvidenceCount {
            support = .recurring
        } else if experiences > 0 {
            support = .dweltOn
        } else {
            support = .provenanceUnavailable
        }

        bound.livedDates = lived.isEmpty ? nil : lived.sorted()
        bound.support = support
        return bound
    }

    private static func proposalRows(_ dtos: [LLMProposalDTO], diagnostics: inout Distillation) -> [REMProposalRow] {
        let createdAt = ISO8601DateFormatter().string(from: Date())
        var result: [REMProposalRow] = []
        for dto in dtos {
            let dtoTarget = REMProposalStore.normalizedTargetDoc(dto.targetDoc)
            if dtoTarget != "GROWTH.md" {
                diagnostics.targetMismatchDrops += 1
                continue
            }
            let redacted = DreamPart.redact(dto.proposalText)
            let normalized = Self.normalizeProposalText(redacted, targetDoc: dtoTarget)
            guard normalized.unicodeScalars.count <= REMConstants._REM_PROPOSAL_TEXT_CAP else {
                diagnostics.parseErrors.append("proposal text exceeds \(REMConstants._REM_PROPOSAL_TEXT_CAP) characters")
                continue
            }
            // Empty normalized text cannot stage a blank approval card.
            guard !normalized.isEmpty else {
                diagnostics.parseErrors.append(
                    "proposal text empty after normalize (raw: \(String(redacted.prefix(80))))"
                )
                continue
            }
            if let reason = REMProposalStore.growthPassageRefusal(normalized) {
                diagnostics.parseErrors.append("proposal text refused: \(reason)")
                continue
            }
            result.append(REMProposalRow(
                id: UUID().uuidString,
                targetDoc: dtoTarget,
                proposalText: normalized,
                evidenceDates: dto.evidenceDates,
                confidence: dto.confidence,
                createdAt: createdAt,
                supportingPassages: (dto.supportingPassages ?? []).map {
                    REMSupportingPassage(dreamDate: $0.date, quote: DreamPart.redact($0.quote))
                },
                whatChanged: Self.normalizedWhatChanged(dto.whatChanged.map(DreamPart.redact)),
                replaced: dto.replaced.flatMap { DreamPart.redact($0.text) == $0.text && DreamPart.redact($0.source) == $0.source ? $0 : nil }
            ))
        }
        return result
    }

    public nonisolated static func normalizeProposalText(_ raw: String, targetDoc: String) -> String {
        guard REMProposalStore.normalizedTargetDoc(targetDoc) == "GROWTH.md" else { return "" }
        let text = raw.replacingOccurrences(of: "\r\n", with: "\n")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        // Validate shape without extracting or rewriting meaning.
        guard text.range(of: #"(?m)^ {0,3}#{1,6}(?:[ \t]|$)"#, options: .regularExpression) == nil else { return "" }
        return text
    }

    /// Cut at a sentence or word boundary; empty changed text remains absent.
    nonisolated static func normalizedWhatChanged(_ raw: String?) -> String? {
        let text = (raw ?? "").replacingOccurrences(of: #"\s+"#, with: " ", options: .regularExpression)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard text.count >= 8 else { return nil }
        let cap = REMConstants.whatChangedCap
        guard text.count > cap else { return text }
        let window = String(text.prefix(cap))
        if let end = window.lastIndex(where: { ".!?".contains($0) }), window.distance(from: window.startIndex, to: end) >= cap / 2 {
            return String(window[...end])
        }
        let words = window.split(separator: " ").dropLast().joined(separator: " ")
        return words.isEmpty ? window : words + "…"
    }

}
