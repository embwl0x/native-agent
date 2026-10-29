import Foundation
import NativeAgentCore
import PersistenceCore

// Blueprint: | `DreamREMCycle+Consolidation.swift` | `REMConsolidator`: one explicitly routed GROWTH completion and proposal parsing with verbatim source-bound supporting passages |

/// One passage a candidate actually rests on: the verbatim words from ONE dream
/// entry, bound to that entry's date and to the sources behind it. Not a
/// paraphrase and not a date list — the text itself, so an approval can be read
/// against what was written rather than against a claim about it.
public struct REMSupportingPassage: Sendable, Codable, Equatable {
    /// The diary entry's date — the date of the DREAM, not of the living.
    public var dreamDate: String
    /// Verbatim from that entry. A quote that is not in the entry is dropped
    /// before it gets here.
    public var quote: String
    /// The dates the material behind that entry actually HAPPENED on. Empty
    /// when the entry carries no provenance (legacy entries): unavailable, and
    /// labelled as such — never counted as support.
    public var livedDates: [String]
    /// The claim's row citations, grouped by exchange when known.
    public var sourceRefs: [String]
    /// Only the claim-bound writer sets this; old diary-wide refs are not support.
    public var claimBound: Bool?

    public init(
        dreamDate: String,
        quote: String,
        livedDates: [String] = [],
        sourceRefs: [String] = [],
        claimBound: Bool? = nil
    ) {
        self.dreamDate = dreamDate
        self.quote = quote
        self.livedDates = livedDates
        self.sourceRefs = sourceRefs
        self.claimBound = claimBound
    }
}

/// Repeated dreams about one lived occasion are labelled as dwelling, never recurrence or noise.
public enum REMSupportKind: String, Sendable, Codable, Equatable {
    /// Two or more distinct experiences supporting the cited claims.
    case recurring
    /// Dreamt on several nights, but all of it is one lived occasion. Kept,
    /// labelled, and never counted as a pattern.
    case dweltOn = "dwelt_on"
    /// The entries behind it carry no provenance, so whether it recurred is
    /// NOT KNOWN. Said plainly instead of being read as support.
    case provenanceUnavailable = "provenance_unavailable"
    /// Not a dream: a correction recalled in nearly every conversation, which
    /// the weekly sweep offers to GROWTH. Its one passage cites `memory:<id>`;
    /// approving graduates that memory.
    case standing
}

extension REMConsolidator {
    /// Per-invocation output; decode failures keep the weekly pass owed for retry.
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

    private struct LLMProposalDTO: Decodable {
        let targetDoc: String
        let proposalText: String
        let evidenceDates: [String]
        let confidence: Double
        /// The words the candidate rests on, per dream entry. Optional so an
        /// older/sloppier reply still parses — a proposal with no verifiable
        /// passage simply carries none and is labelled accordingly.
        let supportingPassages: [LLMPassageDTO]?
        /// What surprised her or changed; absent in older replies.
        let whatChanged: String?

        private enum CodingKeys: String, CodingKey {
            case targetDoc, proposalText, evidenceDates, confidence, supportingPassages, whatChanged
        }

        // A smaller model often writes the confidence as "0.8": take the number either way.
        init(from decoder: Decoder) throws {
            let c = try decoder.container(keyedBy: CodingKeys.self)
            targetDoc = try c.decode(String.self, forKey: .targetDoc)
            proposalText = try c.decode(String.self, forKey: .proposalText)
            evidenceDates = try c.decode([String].self, forKey: .evidenceDates)
            if let number = try? c.decode(Double.self, forKey: .confidence) {
                confidence = number
            } else if let text = try? c.decode(String.self, forKey: .confidence),
                      let number = Double(text.trimmingCharacters(in: .whitespaces)) {
                confidence = number
            } else {
                confidence = try c.decode(Double.self, forKey: .confidence)
            }
            supportingPassages = try c.decodeIfPresent([LLMPassageDTO].self, forKey: .supportingPassages)
            whatChanged = try c.decodeIfPresent(String.self, forKey: .whatChanged)
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
        var evidence: [String: [(content: String, claims: [String: [String]], legacy: Bool)]] = [:]
        for entry in entries {
            guard let content = entry.content else { continue }
            let claims = Dictionary(grouping: DreamEntryProvenance.readClaims(in: content, as: DreamEntryProvenance.self),
                                    by: { DreamEntryProvenance.plain($0.quote) }).mapValues { $0.flatMap(\.sourceRefs) }
            evidence[entry.date, default: []].append((DreamEntryProvenance.plain(content), claims,
                !content.contains("<!-- claim-sources") && !content.contains("<!-- dream-peers")))
        }

        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        let entriesJSON = String(decoding: try encoder.encode(entries), as: UTF8.self)

        // Reuse the system's exact GROWTH body only when it matches the target.
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
        let raw = try await llm.complete(
            prompt: prompt, system: system, model: model, surface: surface, purpose: "rem", tools: nil
        )
        let proposals = parseLLMResponse(raw, diagnostics: &diagnostics)

        // Evidence dates must be YYYY-MM-DD dates from this call's frozen entry set.
        var kept: [REMProposalRow] = []
        for p in proposals {
            let bad = p.evidenceDates.contains { d in
                !Self.isValidDate(d) || !entryDateSet.contains(d)
            }
            if bad {
                diagnostics.evidenceDateDrops += 1
                continue
            }
            kept.append(bindSupport(p, evidence: evidence, identities: identities, diagnostics: &diagnostics))
        }
        diagnostics.proposals = kept
        return diagnostics
    }

    /// A claim carries matching same-night entries' own sources, never diary-wide inputs.
    func bindSupport(_ proposal: REMProposalRow,
        evidence: [String: [(content: String, claims: [String: [String]], legacy: Bool)]],
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
            // Only matching entries can establish legacy eligibility.
            guard !refs.isEmpty || contents.contains(where: \.legacy) else {
                diagnostics.passageDrops += 1
                continue
            }
            passages.append(REMSupportingPassage(
                dreamDate: passage.dreamDate,
                quote: quote,
                // A lived date is a reference's own `@date` tail, never a fragment of its id.
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
            let dtos = try JSONValue.decodeCompletion(raw, as: [LLMProposalDTO].self)
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
                    // Carried raw here; `bindSupport` is what verifies each
                    // quote against the entry it names.
                    supportingPassages: (dto.supportingPassages ?? []).map {
                        REMSupportingPassage(dreamDate: $0.date, quote: $0.quote)
                    },
                    whatChanged: Self.normalizedWhatChanged(dto.whatChanged)
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
        // Validate the body shape; never extract or rewrite its meaning.
        guard text.range(of: #"(?m)^ {0,3}#{1,6}(?:[ \t]|$)"#, options: .regularExpression) == nil else { return "" }
        return text
    }

    public nonisolated static func normalizedTargetDoc(_ targetDoc: String) -> String {
        REMProposalStore.normalizedTargetDoc(targetDoc)
    }

    /// One line, at most `whatChangedCap` characters, cut at a sentence or a
    /// word; nil when there is nothing in it.
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
