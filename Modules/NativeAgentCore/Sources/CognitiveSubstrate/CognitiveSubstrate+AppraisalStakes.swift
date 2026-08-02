// CognitiveSubstrate+AppraisalStakes.swift
// COGNITION STEP 1 (APPRAISAL) · D-2 — appraise against STAKES, not event class.
// (2026-08-02)
//
// The measured defect (appraisal-gap-analysis-v2.md): of her 40 `feltResolution`
// nodes across four weeks, 26 were the SAME sentence —
//   "Relief — the provider-anthropic-oauth-direct path I was braced for landed fine."
// The anticipation layer was bracing for, and feeling relief about, HER OWN
// PLUMBING. Provider calls succeed constantly, so she felt mild relief
// constantly, and the felt layer became noise with a positive bias.
//
// The mechanism was event-class appraisal: `OrganismResolutionFelt` mints a felt
// event whenever a *braced* prediction resolves, and "braced" is a property of
// the BODY's confidence in a path, not of anything she cares about. Lazarus and
// Scherer are explicit that this is the wrong direction of derivation: an event
// produces emotion through what it means for a concern that was AT STAKE.
//
// So: a felt resolution is admitted only when a concern she holds was actually
// at stake. THE SUCCESS METRIC IS FEWER FELT NODES. This is a signal-to-noise
// fix — felt volume should fall sharply, and what remains should mean something.
//
// Scope discipline: this gates the `.organismResolutionFelt` class ONLY. Every
// other event kind is admitted exactly as before — this is not a general
// admission filter, and it must never become one.

import Foundation

extension CognitiveSubstrate {

    /// The ONLY prediction path kinds whose resolution is stake-bearing by
    /// construction: `approvalResolution` (a gate a PERSON has to walk through)
    /// and `workflowAdvance` (a commitment moving). A person and a promise are
    /// on the other end of each.
    ///
    /// This is an ALLOWLIST, and that direction is the fix (gpt-5.5 review B1,
    /// 2026-08-02). It used to be a denylist of mechanical kinds
    /// (tool/provider/phone), which meant "not one of those three ⇒ pass": a
    /// typo (`provider_completion`), an absent label, or any future mechanical
    /// kind (`calendarDelivery`, `syncCompletion`, …) walked straight past D-2
    /// and minted exactly the meaningless-feeling noise this gate exists to
    /// stop, under a different name. Fail closed: an unrecognised label is
    /// machinery until one of HER concerns says otherwise.
    ///
    /// These are `OrganismPredictionKind` raw values; the runtime carries the
    /// resolved path kind on the felt event's `subject.label`.
    static let stakeBearingResolutionPathKinds: Set<String> = [
        OrganismPredictionKind.approvalResolution.rawValue,
        OrganismPredictionKind.workflowAdvance.rawValue,
    ]

    /// Prediction path kinds whose resolution is MACHINERY, not stake — the body
    /// noticing its own infrastructure work out. Kept as documentation of the
    /// measured population (see `AppraisalStakesTests.measuredFeltPopulation`);
    /// admission is decided by `stakeBearingResolutionPathKinds` alone, so an
    /// unknown kind is treated the same as these.
    static let mechanicalResolutionPathKinds: Set<String> = [
        OrganismPredictionKind.toolCompletion.rawValue,
        OrganismPredictionKind.providerCompletion.rawValue,
        OrganismPredictionKind.phoneDelivery.rawValue,
    ]

    /// Was a concern she holds actually at stake in this felt resolution?
    ///
    /// Pure and synchronous (it runs inside the await-free ingest segment). Two
    /// gates, in order:
    ///
    /// 1. **Path provenance.** A resolution on a person-or-promise path
    ///    (`approvalResolution`, `workflowAdvance`) is at stake: a commitment to
    ///    User resolving, an approval he has to give, a piece of work she said she
    ///    would move. Admitted.
    /// 2. **Her own concerns.** A resolution on ANY OTHER path — mechanical,
    ///    mislabelled, unlabelled, or a kind that did not exist when this was
    ///    written — is admitted
    ///    only if one of the concerns SHE FORMED — a lived concern, derived from
    ///    a User-approved active standing view (D-1) — actually names the thing
    ///    that resolved. If she has settled the view "the anthropic oauth path is
    ///    what keeps breaking our releases", then relief about that path is a
    ///    real feeling and it lands. Absent such a view, a provider call
    ///    succeeding touches nothing she holds and produces no felt resolution.
    ///
    /// Floor concerns deliberately do NOT open gate 2. The aboutness string is
    /// machine text (`tool:commit_memory`, `provider-anthropic-oauth-direct`), and
    /// shipped keyword lists trip on machine identifiers by accident — "commit"
    /// is in the followThrough floor. A floor keyword hitting a machine token is
    /// a coincidence; one of HER views naming it is evidence.
    ///
    /// An unknown, absent or misspelled path kind is treated as mechanical —
    /// gate 1 is an allowlist, not a denylist. Conservative in the direction of
    /// the metric: when in doubt, she feels nothing about it.
    func feltResolutionIsAtStake(_ event: CognitiveEvent) -> Bool {
        guard event.kind == .organismResolutionFelt else { return true }

        let pathKind = (event.subject.label ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        if Self.stakeBearingResolutionPathKinds.contains(pathKind) {
            return true
        }

        // Aboutness: everything that names WHAT resolved. `subject.id` carries
        // the resolved organ ("provider-anthropic-oauth-direct#a1b2c3d4"); the
        // summary carries the phrasing the runtime composed around it.
        let aboutness = "\(event.summary) \(event.subject.id) \(event.subject.label ?? "")"
        return livedConcernHit(in: aboutness)
    }
}
