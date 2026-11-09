import Foundation
// Blueprint: | `CognitiveSubstrate+CapsuleCadence.swift` | `CognitiveSubstrate`: fingerprint cadence and the Since gap cue |

extension CognitiveSubstrate {
    /// The agent's reflection preview keeps every cue that passed its own gate.
    static let cadenceExemptCapsuleSurface = "reflection"

    /// Stage the next reference in the copied state; only completed-reply settlement can publish it.
    func feelingShift(
        for words: [(axis: String, word: String)],
        presentationState: inout CognitiveCapsulePresentationState
    ) -> String? {
        var changed: [String] = []
        if let previous = presentationState.fingerprintFamily {
            let old = previous.split(separator: "|").compactMap { value -> (String, String)? in
                let pair = value.split(separator: ":", maxSplits: 1)
                guard let axis = pair.first, let word = pair.dropFirst().first else { return nil }
                return (String(axis), String(word))
            }
            let prior = Dictionary(old, uniquingKeysWith: { first, _ in first })
            changed = words.filter { value in prior[value.axis].map { $0 != value.word } == true }.map(\.word)
        }
        presentationState.fingerprintFamily = words.isEmpty ? nil : words.map { $0.axis + ":" + $0.word }.joined(separator: "|")
        return changed.isEmpty ? nil : "My feeling has shifted: \(changed.joined(separator: ", "))."
    }

    // MARK: - W4/P7 — the session bridge ("since we last talked")

    /// The user's verified turns define gaps across doors. Only events inside a gap may speak, once after `sessionBridgeGapHours`.
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
        // A user turn with nothing to bridge closes any owed gap.
        presentationState.owedSinceGap = nil
        guard let opened, let all = gapItems, !all.isEmpty else { return nil }
        let shown = all.prefix(3).joined(separator: "; ")
            + (all.count > 3 ? " (+\(all.count - 3) more)" : "")
        let line = capsuleLineText(
            "- Since: \(userAddress) was away \(Self.sinceGapPhrase(now.timeIntervalSince(opened)));"
                + " meanwhile \(shown).",
            maxCharacters: 320)
        guard line.hasPrefix("- Since:") else { return nil }
        // Keyed to the GAP (when it opened), not to this turn: the next gap opens at this very turn, so it always qualifies.
        presentationState.lastSessionBridgeAt = opened
        // Owed until it is shown: if it loses the slot, the commit keeps this and restores the bridge key (`keepUnshownCuesOwed`).
        presentationState.owedSinceGap = opened
        return line
    }

}
