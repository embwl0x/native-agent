import Foundation
import NativeAgentCore
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
    /// Decode failures keep the weekly pass owed for retry.
    struct Distillation: Sendable {
        var proposals: [REMProposalRow] = []
        var parseErrors: [String] = []
        var targetMismatchDrops = 0
        var evidenceDateDrops = 0
        var decodeFailures = 0
        var passageDrops = 0
    }

    private struct LLMPassageDTO: Decodable {
        let date: String
        let quote: String
    }

    /// Use an object reply because it supports reliable model output and future fields.
    private struct LLMProposalReply: Decodable {
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

    private struct LLMProposalDTO: Decodable {
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
        system: String? = nil,
        model: String? = nil,
        surface: String,
        systemGrowthBody: String? = nil
    ) async throws -> Distillation {
        var diagnostics = Distillation()
        if entries.isEmpty { return diagnostics }
        let entryDateSet = Set(entries.map { $0.date })
        var evidence: [String: [(content: String, claims: [String: [String]])]] = [:]
        for entry in entries {
            guard let content = entry.content else { continue }
            let sections = DreamEntryProvenance.readClaims(in: content, as: DreamEntryProvenance.self)
            // Refuse damaged-section bypasses rather than turning unreadable evidence into fewer claims.
            if let gap = sections.compactMap(\.unavailable).first {
                throw PersistenceCoreError.ioFailure("dream_diary/\(entry.filename ?? entry.date): \(gap)")
            }
            let claims = Dictionary(grouping: sections.flatMap(\.claims),
                                    by: { DreamEntryProvenance.plain($0.quote) }).mapValues { $0.flatMap(\.sourceRefs) }
            evidence[entry.date, default: []].append((DreamEntryProvenance.plain(content), claims))
        }

        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        let entriesJSON = String(decoding: try encoder.encode(entries), as: UTF8.self)

        // Reuse exact live GROWTH only when it matches the target.
        let targetContext = try (system != nil && systemGrowthBody == growthBody
            ? completionPolicy("rem-proposal", section: "growth-context")
            : growthBody)
        let prompt = try completionPolicy("rem-proposal", section: "prompt", arguments: [
            entriesJSON,
            targetContext,
            entryDateSet.sorted().joined(separator: ", "),
            String(REMConstants.whatChangedCap),
            REMProposalStore.growthPassageBoundSentence,
            String(REMConstants._REM_PROPOSAL_TEXT_CAP)
        ])
        let call = LLMCall(turn: nil, surface: surface, purpose: "rem")
        var raw = try await llm.complete(
            prompt: prompt, system: system, model: model, tools: nil, call: call
        )
        var proposals = parseLLMResponse(raw, diagnostics: &diagnostics)
        // A reply that cannot be read is asked for again at once, told what was wrong; only three unreadable replies are a failure.
        var asks = 1
        while diagnostics.decodeFailures > 0, asks < 3 {
            let fault = diagnostics.parseErrors.last { $0.hasPrefix("decode failure:") } ?? "decode failure"
            diagnostics.decodeFailures = 0
            diagnostics.parseErrors.removeAll { $0.hasPrefix("decode failure:") }
            raw = try await llm.complete(
                prompt: prompt + "\n\nYour last reply could not be read (" + String(fault.prefix(300))
                    + "). Reply again with one JSON object of the form {\"proposals\": [...]} and nothing else.",
                system: system, model: model, tools: nil, call: call
            )
            proposals = parseLLMResponse(raw, diagnostics: &diagnostics)
            asks += 1
        }

        // Accept evidence dates only from the call's frozen entry set.
        var kept: [REMProposalRow] = []
        for p in proposals {
            let bad = p.evidenceDates.contains { d in
                !Self.isValidDate(d) || !entryDateSet.contains(d)
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
                } else if let entry = entries.first(where: {
                    replaced.source == "dream:\($0.date)" && !replaced.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                        && $0.content?.contains(replaced.text) == true
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
    func bindSupport(_ proposal: REMProposalRow,
        evidence: [String: [(content: String, claims: [String: [String]])]],
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
            let refs = Set(contents.flatMap { $0.claims[normalized] ?? [] }).sorted()
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

    private func parseLLMResponse(_ raw: String, diagnostics: inout Distillation) -> [REMProposalRow] {
        do {
            let dtos = try JSONValue.decodeCompletion(raw, as: LLMProposalReply.self).proposals
            let createdAt = ISO8601DateFormatter().string(from: Date())
            var result: [REMProposalRow] = []
            for dto in dtos {
                let dtoTarget = Self.normalizedTargetDoc(dto.targetDoc)
                if dtoTarget != "GROWTH.md" {
                    diagnostics.targetMismatchDrops += 1
                    continue
                }
                let normalized = Self.normalizeProposalText(dto.proposalText, targetDoc: dtoTarget)
                guard normalized.unicodeScalars.count <= REMConstants._REM_PROPOSAL_TEXT_CAP else {
                    diagnostics.parseErrors.append("proposal text exceeds \(REMConstants._REM_PROPOSAL_TEXT_CAP) characters")
                    continue
                }
                // Empty normalized text cannot stage a blank approval card.
                guard !normalized.isEmpty else {
                    diagnostics.parseErrors.append(
                        "proposal text empty after normalize (raw: \(String(dto.proposalText.prefix(80))))"
                    )
                    continue
                }
                result.append(REMProposalRow(
                    id: UUID().uuidString,
                    targetDoc: dtoTarget,
                    proposalText: normalized,
                    evidenceDates: dto.evidenceDates,
                    confidence: dto.confidence,
                    createdAt: createdAt,
                    // Keep raw quotes until bindSupport verifies them against their named entries.
                    supportingPassages: (dto.supportingPassages ?? []).map {
                        REMSupportingPassage(dreamDate: $0.date, quote: $0.quote)
                    },
                    whatChanged: Self.normalizedWhatChanged(dto.whatChanged),
                    replaced: dto.replaced
                ))
            }
            return result
        } catch {
            diagnostics.parseErrors.append("decode failure: \(error)")
            diagnostics.decodeFailures += 1
            return []
        }
    }

    public nonisolated static func normalizeProposalText(_ raw: String, targetDoc: String) -> String {
        guard normalizedTargetDoc(targetDoc) == "GROWTH.md" else { return "" }
        let text = raw.replacingOccurrences(of: "\r\n", with: "\n")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        // Validate shape without extracting or rewriting meaning.
        guard text.range(of: #"(?m)^ {0,3}#{1,6}(?:[ \t]|$)"#, options: .regularExpression) == nil else { return "" }
        return text
    }

    public nonisolated static func normalizedTargetDoc(_ targetDoc: String) -> String {
        REMProposalStore.normalizedTargetDoc(targetDoc)
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
