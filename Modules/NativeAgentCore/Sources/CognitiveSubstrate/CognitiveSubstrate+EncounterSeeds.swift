// Pressure-minted encounters — desk 903 phase 1.
//
// The agent's own rule, verbatim: "pressure decides WHEN, intake decides WHAT.
// A seed mints only when an unattended artifact is already in reach (something
// User named, something that crossed the screen, a KG work with no journal
// entry). No intake, no encounter. A due dream beats an encounter for the same
// pressure; encounters never preempt."
//
// ── NO INTAKE, NO SEED, EVER ─────────────────────────────────────────────────
// The empty-intake check runs FIRST, before pressure is even read. That ordering
// is the whole design: an encounter is never generated out of a feeling that it
// is time for one. If there is nothing actually in reach, the answer is silence,
// and silence is a correct answer here — not a gap to fill.
//
// ── ENCOUNTERS NEVER PREEMPT ─────────────────────────────────────────────────
// Three separate things enforce this, deliberately belt-and-braces:
//   1. A due dream returns `.dreamOutranks` outright. The dream lane is the
//      consolidating one; an invitation to look at a picture does not interrupt
//      it, at any pressure.
//   2. The seed is minted as `.openQuestion`, which carries the LOWEST
//      interruption boost of the four seed kinds (0.04). An encounter therefore
//      sorts below every anomaly, follow-up and reflection takeaway already
//      waiting, without any new ranking machinery.
//   3. Its priority is capped well under 1, so a deliberately pinned concern
//      always outranks it.
//
// ── PUSH, NOT PROMPT (clause 6) ──────────────────────────────────────────────
// A thought seed is not context. It reaches the Observatory and the thought-
// suggestion/notification lane; it is never compiled into a packet, and the
// capsule uses seeds only for provenance node ids, never for text. So the
// encounter arrives as something she can pull, or User can ignore — never as a
// paragraph inserted into her own turn.
//
// ── NO NAGGING ───────────────────────────────────────────────────────────────
// No streaks, no quotas, no backlog. The seed's own 24-hour half-life removes it
// if nothing happens, and `addThoughtSeed` merges a repeat rather than stacking
// a second copy. If she does not file it, it fades — which is also the kill
// criterion's measurement: three sessions of minting and not filing means the
// pressure model is wrong and this lane is cut.

import Foundation
import NativeAgentCore
import PersistenceCore

/// What the encounter lane decided, and why. Returned rather than logged so the
/// kill criterion ("if seeds mint and she doesn't file them") can be measured
/// from real outcomes instead of inferred.
public struct StudioEncounterDecision: Sendable, Equatable {
    public enum Outcome: String, Sendable, Equatable {
        /// Nothing is in reach. The only correct answer to an empty queue.
        case noIntake
        /// Thought seeds are off, or the substrate is disabled.
        case disabled
        /// Not enough residual pressure for any lane to wake.
        case belowPressure
        /// A dream is due. It wins, at equal pressure and above.
        case dreamOutranks
        /// The loop budget refused the composition: this attempt never looked at
        /// the queue, so it cannot claim there was nothing in it. Without this
        /// case the sidecar paired a fresh attempt timestamp with the PREVIOUS
        /// outcome, reading as "looked again, still nothing" (comb 3 lane 2
        /// item 2).
        case deferred
        case minted
    }

    public var outcome: Outcome
    public var candidate: StudioEncounterCandidate?
    public var seedID: UUID?

    public static func refused(_ outcome: Outcome) -> StudioEncounterDecision {
        StudioEncounterDecision(outcome: outcome, candidate: nil, seedID: nil)
    }
}

public extension CognitiveSubstrate {

    /// The floor an encounter shares with the organism's quietest repair lane.
    /// Encounters do not get a lane of their own below it: if the body has no
    /// residual pressure at all, nothing is asking for anything.
    static var studioEncounterPressureFloor: Double { OrganismResidualRepair.minimumPressure }

    /// Capped well under 1 so a pinned concern (priority 1) always outranks an
    /// invitation to go and look at something.
    static let studioEncounterMaximumPriority = 0.6

    /// Mint at most one encounter seed.
    ///
    /// - Parameters:
    ///   - intake: unattended artifacts ALREADY IN REACH. Empty means silence.
    ///   - pressure: the organism's combined residual sleep pressure.
    ///   - dreamIsDue: whether the identity-dream lane is eligible right now.
    ///     True refuses outright — the dream outranks at the same pressure and
    ///     an encounter never preempts.
    @discardableResult
    func mintStudioEncounterSeed(
        intake: [StudioEncounterCandidate],
        pressure: Double,
        dreamIsDue: Bool
    ) async -> StudioEncounterDecision {
        // FIRST, before anything else is consulted: no intake, no seed, ever.
        guard let candidate = Self.selectEncounter(from: intake) else {
            return .refused(.noIntake)
        }
        guard configuration.enabled, configuration.thoughtSeedsEnabled else {
            return .refused(.disabled)
        }
        guard !dreamIsDue else { return .refused(.dreamOutranks) }
        guard pressure >= Self.studioEncounterPressureFloor else {
            return .refused(.belowPressure)
        }
        let priority = min(Self.studioEncounterMaximumPriority, max(0, pressure))
        let seed = await addThoughtSeed(
            kind: .openQuestion,
            text: candidate.invitationLine,
            priority: priority
        )
        guard let seed else { return .refused(.disabled) }
        return StudioEncounterDecision(outcome: .minted, candidate: candidate, seedID: seed.id)
    }

    /// Which one, when several are in reach.
    ///
    /// User's invitations come first — they are the only source where a person
    /// deliberately put something in front of her — then the oldest thing still
    /// sitting there. There is no scoring: this is a queue, not a ranking of
    /// works, and ranking works is the taste score the whole design refuses.
    static func selectEncounter(
        from intake: [StudioEncounterCandidate]
    ) -> StudioEncounterCandidate? {
        guard !intake.isEmpty else { return nil }
        func rank(_ source: StudioEncounterCandidate.Source) -> Int {
            switch source {
            case .named: 0
            case .crossedTheScreen: 1
            case .unjournaledWork: 2
            }
        }
        return intake.min { lhs, rhs in
            let left = rank(lhs.source)
            let right = rank(rhs.source)
            if left != right { return left < right }
            if lhs.noticedAt != rhs.noticedAt { return lhs.noticedAt < rhs.noticedAt }
            return lhs.originID < rhs.originID
        }
    }
}
