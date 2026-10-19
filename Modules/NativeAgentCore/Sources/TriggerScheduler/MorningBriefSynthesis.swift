import Foundation
import NativeAgentCore
import PersistenceCore

// MARK: - Morning-brief synthesis seam (L5 G3 + G1)
//
// THE MERGE. Before this, "morning brief" named two unrelated mechanisms: the
// `time` trigger (counts, no LLM, no tools — owns schedule/dedup/push) and the
// install-on-click `.morningBriefing` blueprint (a real tool-capable turn that
// can read calendar and mail — owned nothing and almost never ran). This seam
// makes the trigger FIRE the blueprint turn: the trigger keeps schedule, dedup
// and push; the turn supplies the read.
//
// WHY A CLOSURE AND NOT A DIRECT CALL. TriggerScheduler's target deps are
// ["PersistenceCore", "WorkshopExecution"] on purpose (TriggerContent.swift:19-23):
// importing ChatOrchestration here would drag MemoryV2, ProviderRouting,
// CognitiveSubstrate and twenty more into the 60s scheduler tick's module
// graph. The synthesizer is therefore injected from the app layer, exactly
// like `notifier` and `workshopRunner` already are.
//
/// Everything the synthesizer is allowed to see: the deterministic brief that
/// already resolved. The evidence layer is the prompt; the turn's job is the
/// read on top of it, not a second gathering pass over the same files.
public struct MorningBriefSynthesisRequest: Sendable, Equatable {
    /// Human day label, e.g. "Monday, August 11".
    public let dayLabel: String
    /// The deterministic one-line summary (counts).
    public let deterministicSummary: String
    /// The deterministic markdown sections, nil when nothing resolved.
    public let deterministicDetail: String?

    public init(dayLabel: String, deterministicSummary: String, deterministicDetail: String?) {
        self.dayLabel = dayLabel
        self.deterministicSummary = deterministicSummary
        self.deterministicDetail = deterministicDetail
    }
}

/// The synthesized lead is required; a failed read leaves the brief owed.
public typealias MorningBriefSynthesizer =
    @Sendable (MorningBriefSynthesisRequest) async throws -> String

extension TriggerContentBuilder {

    /// Longest synthesized lead we will put in an inbox card's `summary`.
    /// The full lead always survives intact in `detail`; this only bounds the
    /// single line the card renders.
    static let synthesizedLeadSummaryCap = 400

    /// The brief, led by the turn's synthesized read (G1) when one resolved.
    ///
    /// Her read leads; the deterministic sections preserve its evidence.
    public func morningBrief(synthesizer: MorningBriefSynthesizer?) async throws -> TriggerContent {
        let deterministic = await morningBrief()
        guard let synthesizer else {
            throw TriggerSchedulerError.persistenceFailure("Morning-brief synthesis is not connected to its turn owner.")
        }

        let detailText: String?
        if case .string(let body) = deterministic.detail { detailText = body } else { detailText = nil }

        let lead = try await synthesizer(
            MorningBriefSynthesisRequest(
                dayLabel: Self.todayLabel(now()),
                deterministicSummary: deterministic.summary,
                deterministicDetail: detailText
            )
        )
        let trimmedLead = lead.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedLead.isEmpty else {
            throw TriggerSchedulerError.persistenceFailure("Morning-brief synthesis returned no lead.")
        }

        // Card summary: the lead, bounded. Detail: the lead in full, then the
        // deterministic evidence under a rule so it reads as backing material
        // rather than as a competing brief.
        let cappedLead = trimmedLead.count > Self.synthesizedLeadSummaryCap
            ? String(trimmedLead.prefix(Self.synthesizedLeadSummaryCap)) + "…"
            : trimmedLead
        let detail: JSONValue
        if let detailText, !detailText.isEmpty {
            detail = .string("\(trimmedLead)\n\n---\n\n\(detailText)")
        } else {
            detail = .string(trimmedLead)
        }
        return TriggerContent(
            title: deterministic.title,
            summary: cappedLead,
            detail: detail
        )
    }
}
