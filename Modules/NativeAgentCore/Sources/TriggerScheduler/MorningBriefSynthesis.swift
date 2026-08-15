import Foundation
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
// FAIL-OPEN IS THE CONTRACT, NOT AN OPTIMISATION. The synthesizer returns
// `String?`. A nil — provider down, no API key, tools denied, turn threw,
// blank output — degrades the brief to the byte-identical deterministic text
// it produced before this seam existed. The trigger tick must never fail
// because a model was unavailable.

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

/// Injected at the app layer. Returns the synthesized lead, or nil to fall
/// back to the deterministic brief. MUST NOT throw — a synthesizer that can
/// fail swallows its own errors and returns nil, so the fail-open contract is
/// enforced by the type, not by a caller remembering to `try?`.
public typealias MorningBriefSynthesizer =
    @Sendable (MorningBriefSynthesisRequest) async -> String?

extension TriggerContentBuilder {

    /// Longest synthesized lead we will put in an inbox card's `summary`.
    /// The full lead always survives intact in `detail`; this only bounds the
    /// single line the card renders.
    static let synthesizedLeadSummaryCap = 400

    /// The brief, led by the turn's synthesized read (G1) when one resolved.
    ///
    /// Layering, top to bottom: her read, then the deterministic sections as
    /// the evidence layer beneath it. Passing `synthesizer: nil` — every test
    /// and every non-live root — reproduces `morningBrief()` exactly.
    public func morningBrief(synthesizer: MorningBriefSynthesizer?) async -> TriggerContent {
        let deterministic = await morningBrief()
        guard let synthesizer else { return deterministic }

        let detailText: String?
        if case .string(let body) = deterministic.detail { detailText = body } else { detailText = nil }

        let lead = await synthesizer(
            MorningBriefSynthesisRequest(
                dayLabel: Self.todayLabel(now()),
                deterministicSummary: deterministic.summary,
                deterministicDetail: detailText
            )
        )
        guard let lead else { return deterministic }
        let trimmedLead = lead.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedLead.isEmpty else { return deterministic }

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
