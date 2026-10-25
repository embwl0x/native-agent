import Foundation
import NativeAgentCore
import PersistenceCore
import TurnTrace
// Blueprint: | `CognitiveSubstrate+CapsuleCadence.swift` | `CognitiveSubstrate`: fingerprint cadence and the Since gap cue |

extension CognitiveSubstrate {
    /// Her reflection preview keeps every cue that passed its own gate.
    static let cadenceExemptCapsuleSurface = "reflection"

    // MARK: - W4/P4 — fingerprint cadence + suppress-when-unchanged

    struct FingerprintCadenceVerdict: Sendable, Equatable {
        var speak: Bool
        /// How many consecutive capsules have now reported this family.
        var run: Int
    }

    /// Whether the fingerprint line speaks this capsule.
    ///
    /// SUPPRESS-WHEN-UNCHANGED: after `fingerprintFamilyRepeatLimit`
    ///    consecutive capsules reporting the same felt FAMILY, the line goes
    ///    quiet. It re-surfaces the moment the family changes, or when
    ///    `fingerprintSuppressionWindow` expires since it last actually spoke —
    ///    so a genuinely persistent state is never muted indefinitely, which is
    ///    the load-bearing risk here (the fingerprint is the most-read line the
    ///    agent gets). Family, not WORD: the overlay words shuffle turn to turn
    ///    while the underlying state sits still, and it is the state sitting
    ///    still that makes it a mantra.
    ///
    func fingerprintCadenceVerdict(
        family: String,
        at now: Date,
        dynamics dyn: PersonalityDynamicsConfiguration,
        presentationState: inout CognitiveCapsulePresentationState
    ) -> FingerprintCadenceVerdict {
        let sameFamily = presentationState.fingerprintFamily == family
        let run = sameFamily ? presentationState.fingerprintCount + 1 : 1

        var speak = true
        if sameFamily, dyn.fingerprintFamilyRepeatLimit > 0,
           run > dyn.fingerprintFamilyRepeatLimit {
            let sinceSurfaced = presentationState.fingerprintLastSurfacedAt
                .map { now.timeIntervalSince($0) } ?? 0
            // The window is the escape hatch, not the rule: quiet until it
            // expires, then one line, then quiet again if nothing has moved.
            speak = sinceSurfaced >= dyn.fingerprintSuppressionWindow
        }

        presentationState.fingerprintFamily = family
        // A re-surfaced line restarts the run, so the next suppression costs
        // the full K capsules again rather than one.
        presentationState.fingerprintCount =
            speak && sameFamily && run > dyn.fingerprintFamilyRepeatLimit ? 1 : run
        presentationState.fingerprintLastSurfacedAt = speak
            ? now
            : (presentationState.fingerprintLastSurfacedAt ?? now)
        return FingerprintCadenceVerdict(speak: speak, run: run)
    }

    // MARK: - W4/P7 — the session bridge ("since we last talked")

    /// ONE line, on the first turn User takes after a real gap, saying what
    /// actually happened while he was away.
    ///
    /// Phase 5 B2 (2026-10-03). The gap used to run from the last live capsule
    /// of ANY conversation, so a peer thread or one of her own wakes at 3am
    /// closed User's night (replayed on the week to 10-03: 4 bridges, 8 real
    /// absences). It runs on User's own turns now, across every door, and a
    /// door switch is just the next turn. The content used to be the
    /// strongest-felt moment from BEFORE the gap; it is now what happened IN
    /// it (moments, Desk outcomes, notable agent work, read locally by the
    /// wiring), and an empty gap says nothing.
    ///
    /// GAP-GATED SO IT CAN NEVER BECOME PER-TURN: at least
    /// `sessionBridgeGapHours` since User's last turn, at most once per gap.
    func feltSessionBridgeLine(
        at now: Date,
        dynamics dyn: PersonalityDynamicsConfiguration,
        presentationState: inout CognitiveCapsulePresentationState,
        fromUser: Bool,
        previousUserTurn: Date?,
        gapItems: [String]?,
        cognitionEnabled: Bool? = nil,
        affectEnabled: Bool? = nil
    ) -> String? {
        guard cognitionEnabled ?? configuration.enabled,
              affectEnabled ?? configuration.enabled,
              fromUser else { return nil }
        let opened = Self.sinceGapOpened(presentationState, previousUserTurn: previousUserTurn, dynamics: dyn, at: now)
        // A User turn with nothing to bridge closes any owed gap.
        presentationState.owedSinceGap = nil
        guard let opened, let all = gapItems, !all.isEmpty else { return nil }
        let shown = all.prefix(3).joined(separator: "; ")
            + (all.count > 3 ? " (+\(all.count - 3) more)" : "")
        let line = capsuleLineText(
            "- Since: \(userAddress) was away \(Self.sinceGapPhrase(now.timeIntervalSince(opened)));"
                + " meanwhile \(shown).",
            maxCharacters: 320)
        guard line.hasPrefix("- Since:") else { return nil }
        // Keyed to the GAP (when it opened), not to this turn: the next gap
        // opens at this very turn, so it always qualifies (Sol, 10-03).
        presentationState.lastSessionBridgeAt = opened
        // Owed until it is shown: if it loses the slot, the commit keeps this
        // and restores the bridge key (`keepUnshownCuesOwed`).
        presentationState.owedSinceGap = opened
        return line
    }

}
