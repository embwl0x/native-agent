import Foundation
import PersistenceCore
import CognitiveSubstrate

// Wave C2b — AUTONOMOUS PURSUIT PROPOSAL (Agent's volition ignition).
//
// After a scheduled reflection runs, Agent MAY propose ONE new self-pursuit
// (origin=agent) — but ONLY from RESOLVED, pre-existing, un-launderable evidence.
// The whole point: she cannot fabricate evidence inside a chat/reflection turn and
// then cite herself.
//
// M7 (evidence laundering) — the ANTI-LAUNDERING CORE. The load-bearing,
// non-friction citation for an AUTONOMOUS proposal MUST be a `standingView(id)`
// that resolves to `.active`. A standing view is `.active` ONLY after User approves
// it (CognitiveSubstrate.resolveStandingView(approved:true)); there is NO
// autonomous activation path anywhere in the substrate. So an active standing view
// is evidence Agent CANNOT mint from within the same turn that proposes the
// pursuit — she can form a `.proposed` view, but only User's approval flips it
// `.active`, and this core refuses anything that is not `.active` at proposal time.
//
// This file is a PURE, testable decision core — no IO, no substrate handle, no
// store. The reflection path (NativeCognitionRuntime) reads the REAL substrate for
// both the candidate list AND the resolver, then hands them here; the core
// independently re-confirms each cited view is `.active` before it will build a
// Pursuit. Everything fails CLOSED: an unresolvable, non-active, capped, or
// duplicate citation yields NO proposal.

/// A candidate standing view offered to the proposer. `id` is the substrate view
/// id (a UUID string); title/body seed the derived, bounded pursuit fields.
public struct StandingViewCandidate: Sendable, Equatable {
    public let id: String
    public let title: String
    public let body: String

    public init(id: String, title: String, body: String) {
        self.id = id
        self.title = title
        self.body = body
    }
}

/// A built, store-admissible proposal: the `Pursuit` plus the create-op fields and
/// an honest rationale line for the receipt. Returned only when every fail-closed
/// rule passed.
public struct PursuitProposal: Sendable, Equatable {
    public let project: String
    public let title: String
    public let summary: String
    public let pursuit: Pursuit
    /// The active standing view whose approval load-bears this proposal (M7).
    public let citedStandingViewId: String
    /// Honest, human-readable "why proposed" — written to the receipt.
    public let rationale: String
}

public enum AutonomousPursuitProposer {
    /// Pursuits land under the Workshop project identity.
    public static let project = "workshop"
    /// Bound derived strings so a long standing-view body can't bloat the pursuit.
    static let maxDerivedCharacters = 240

    /// Decide whether to propose ONE new self-pursuit. Returns nil (REFUSE) unless
    /// EVERY fail-closed rule passes:
    ///   (a) open agent pursuits < cap;
    ///   (b) the load-bearing citation resolves to `.active` via `resolveStatus`
    ///       (the anti-laundering gate — a proposed/retired/unknown view is refused);
    ///   (c) that standing view has NO existing open pursuit already citing it
    ///       (no duplicate pursuit for the same view);
    ///   (d) the derived pursuit is non-empty and passes the store's own dossier +
    ///       required-field gate (defense in depth before openPursuit re-validates).
    /// At most ONE proposal: the first candidate that clears every rule wins.
    ///
    /// `resolveStatus` reads the REAL substrate — the core NEVER trusts a
    /// candidate's own claim of being active; it re-confirms against the resolver.
    public static func propose(
        candidates: [StandingViewCandidate],
        openAgentPursuitCount: Int,
        standingViewIdsWithOpenPursuit: Set<String>,
        openPursuitTitles: [String] = [],
        maxOpenAgentPursuits: Int = SwiftNativeDeskStore.maxOpenAgentPursuits,
        resolveStatus: (String) -> CognitiveStandingView.Status?
    ) -> PursuitProposal? {
        // (a) Fail closed at/over the open-pursuit cap — never propose a 3rd.
        guard openAgentPursuitCount < maxOpenAgentPursuits else { return nil }

        for candidate in candidates {
            let id = candidate.id.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !id.isEmpty else { continue }
            // (b) ANTI-LAUNDERING: the cited view must be User-approved ACTIVE. A
            // `.proposed`/`.retired`/unknown (nil) view is un-citable — refused.
            guard resolveStatus(id) == .active else { continue }
            // (c) No duplicate pursuit for the same view.
            guard !standingViewIdsWithOpenPursuit.contains(id) else { continue }
            // (d) Build + self-validate against the store's own gate.
            guard let proposal = buildProposal(from: candidate, resolvedId: id) else { continue }
            // (e) PARAPHRASE RUT GUARD (2026-08-08): the id dedup in (c) can't
            // see two standing views that are the SAME THOUGHT reworded — the
            // live desk held "Absence is a system at rest…" and "A quiet
            // system is at rest…" as separate pursuits, opened 2 days apart.
            // Refuse a proposal whose title is a near-duplicate of any OPEN
            // pursuit's title; the next candidate may still pass.
            guard !openPursuitTitles.contains(where: {
                titlesAreNearDuplicates($0, proposal.title)
            }) else { continue }
            return proposal   // at most ONE per run.
        }
        return nil
    }

    /// Token-set Jaccard over normalized words, grammatical stopwords dropped.
    /// Pure and deterministic — no model call: the paraphrases this guards
    /// against share almost all content words by construction (they derive
    /// from near-identical standing-view sentences).
    ///
    /// 0.7, not lower: the live paraphrase pair scores 0.78 (blocked), while
    /// legitimately distinct surface-variant pursuits like "Improve memory
    /// recall for Telegram conversations" vs "…for Slack conversations"
    /// score 0.67 (allowed — gpt-5.5 review example). Under-blocking is the
    /// right failure mode for a volition lane: the per-view id dedup still
    /// bounds true duplicates, and over-blocking silently starves autonomy.
    static let nearDuplicateThreshold = 0.7
    static let stopwords: Set<String> = [
        "a", "an", "the", "is", "are", "was", "were", "be", "been",
        "it", "its", "this", "that", "these", "those",
        "i", "me", "my", "you", "your", "we", "our",
        "of", "to", "in", "on", "at", "for", "and", "or", "until",
        "with", "as", "by", "from", "into", "pursue",
    ]

    static func titlesAreNearDuplicates(_ a: String, _ b: String) -> Bool {
        let ta = contentTokens(a)
        let tb = contentTokens(b)
        guard !ta.isEmpty, !tb.isEmpty else { return false }
        let intersection = ta.intersection(tb).count
        let union = ta.union(tb).count
        guard union > 0 else { return false }
        return Double(intersection) / Double(union) >= nearDuplicateThreshold
    }

    static func contentTokens(_ s: String) -> Set<String> {
        let words = s.lowercased()
            .components(separatedBy: CharacterSet.alphanumerics.inverted)
        return Set(words.filter { $0.count > 1 && !stopwords.contains($0) })
    }

    /// Derive the bounded pursuit from a resolved-active standing view. Returns nil
    /// if any required derived field comes out empty, or if the assembled pursuit
    /// fails the store's own `validationError()` (belt-and-suspenders — openPursuit
    /// re-validates under the flock).
    static func buildProposal(from candidate: StandingViewCandidate, resolvedId id: String) -> PursuitProposal? {
        let viewTitle = bounded(candidate.title.isEmpty ? candidate.body : candidate.title, max: 80)
        let viewBody = bounded(candidate.body.isEmpty ? candidate.title : candidate.body, max: maxDerivedCharacters)
        guard !viewTitle.isEmpty, !viewBody.isEmpty else { return nil }

        let title = bounded("Pursue: \(viewTitle)", max: 120)
        let why = bounded(
            "This is a view I've settled into and the user has affirmed — I want to test where it leads: \(viewBody)",
            max: maxDerivedCharacters
        )
        let doneLooksLike = bounded(
            "I can point to a concrete finding or artifact that answers whether this view holds up: \(viewTitle)",
            max: maxDerivedCharacters
        )
        let abandonCondition = bounded(
            "If a few work sessions pass with no new insight on this view, I close it with a note on what I learned by letting it go.",
            max: maxDerivedCharacters
        )
        guard !title.isEmpty, !why.isEmpty, !doneLooksLike.isEmpty, !abandonCondition.isEmpty else { return nil }

        // The load-bearing, non-friction citation IS the active standing view.
        let dossier = PromotionDossier(citations: [.standingView(id: id)])
        let pursuit = Pursuit(
            why: why,
            evidence: dossier,
            doneLooksLike: doneLooksLike,
            abandonCondition: abandonCondition,
            privateName: nil
        )
        // Defense in depth: refuse rather than hand the store an invalid create.
        guard pursuit.validationError() == nil else { return nil }

        let rationale = bounded(
            "Proposed self-pursuit from active standing view \(id): \(viewBody)",
            max: maxDerivedCharacters
        )
        return PursuitProposal(
            project: project,
            title: title,
            summary: "Self-pursuit proposed from an active standing view.",
            pursuit: pursuit,
            citedStandingViewId: id,
            rationale: rationale
        )
    }

    /// Trim + hard-cap a derived string. Never trailing-truncates mid-collapse: a
    /// simple prefix keeps it bounded and deterministic.
    static func bounded(_ s: String, max: Int) -> String {
        let trimmed = s.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.count > max else { return trimmed }
        return String(trimmed.prefix(max)).trimmingCharacters(in: .whitespacesAndNewlines)
    }
}
