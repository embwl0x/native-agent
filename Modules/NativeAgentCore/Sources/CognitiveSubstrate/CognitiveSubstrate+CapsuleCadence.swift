import Foundation
import NativeAgentCore
import PersistenceCore
import TurnTrace
// Blueprint: | `CognitiveSubstrate+CapsuleCadence.swift` | `CognitiveSubstrate`: fingerprint cadence and the Since gap cue |

extension CognitiveSubstrate {
    /// Her reflection preview keeps every cue that passed its own gate.
    static let cadenceExemptCapsuleSurface = "reflection"

    // MARK: - Fingerprint cadence

    struct FingerprintCadenceVerdict: Sendable, Equatable {
        var speak: Bool
        /// Pre-reset count of consecutive readings of this family.
        var run: Int
    }

    /// Cadence eligibility; live assembly also requires `run == 1`.
    /// Reflection uses `speak` alone. A timed same-family verdict retains its
    /// pre-reset run, so it does not itself deliver another live fingerprint.
    func fingerprintCadenceVerdict(
        family: String,
        at now: Date,
        dynamics dyn: PersonalityDynamicsConfiguration,
        presentationState: inout CognitiveCapsulePresentationState
    ) -> FingerprintCadenceVerdict {
        let sameFamily = presentationState.fingerprintFamily == family
        let run = sameFamily ? min(presentationState.fingerprintCount, Int.max - 1) + 1 : 1

        var speak = true
        if sameFamily, dyn.fingerprintFamilyRepeatLimit > 0,
           run > dyn.fingerprintFamilyRepeatLimit {
            let sinceSurfaced = presentationState.fingerprintLastSurfacedAt
                .map { now.timeIntervalSince($0) } ?? 0
            // Expiry permits a cadence verdict; assembly still gates delivery.
            speak = sinceSurfaced >= dyn.fingerprintSuppressionWindow
        }

        presentationState.fingerprintFamily = family
        // Reset the stored count after an eligible over-limit reading, retaining the verdict's run.
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
    /// User's own turns define the gap across doors; only events inside it speak.
    ///
    /// GAP-GATED SO IT CAN NEVER BECOME PER-TURN: at least
    /// `sessionBridgeGapHours` since User's last turn, at most once per gap.
    func feltSessionBridgeLine(
        from read: CognitiveFrozenRead,
        presentationState: inout CognitiveCapsulePresentationState,
        fromUser: Bool,
        previousUserTurn: Date?,
        gapItems: [String]?
    ) -> String? {
        guard read.configuration.enabled, fromUser else { return nil }
        let now = read.fixedAt
        let dyn = read.personalityDynamics
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
        // opens at this very turn, so it always qualifies.
        presentationState.lastSessionBridgeAt = opened
        // Owed until it is shown: if it loses the slot, the commit keeps this
        // and restores the bridge key (`keepUnshownCuesOwed`).
        presentationState.owedSinceGap = opened
        return line
    }

}
