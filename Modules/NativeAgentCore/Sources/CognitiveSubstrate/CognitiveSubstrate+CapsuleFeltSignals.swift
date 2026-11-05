import Foundation
import NativeAgentCore
import PersistenceCore
// Blueprint: | `CognitiveSubstrate+CapsuleFeltSignals.swift` | `CognitiveSubstrate`: `feltTintNodes`, `feltDominantNode`, `feltObjectLabel` |

extension CognitiveSubstrate {
    /// A rendered felt line retains its carried state so presentation receipts need no string parsing.
    struct FeltLineRender: Sendable, Equatable {
        var text: String
        var family: String
        var carriedObject: Bool
        var carriedAmbivalence: Bool
        /// The spoken line omits the object; `text` retains it for Reminded-of queries.
        var bareText: String = ""
    }

    /// Tint uses felt nodes among the first six capsule-eligible workspace items; prefix precedes filtering.
    func feltTintNodes(from workspaceItems: [CognitiveWorkspaceItem]) -> [CognitiveNode] {
        workspaceItems.prefix(6).map(\.node)
            .filter {
                $0.feltDirection != nil
            }
    }

    /// Peak valence and object attribution share the freshest felt node; first in frozen workspace order wins equal-recency ties.
    static func feltDominantNode(
        in nodes: [CognitiveNode],
        at now: Date,
        halfLife: TimeInterval
    ) -> CognitiveNode? {
        var best: CognitiveNode?
        var bestWeight = -1.0
        for node in nodes {
            let age = max(0, now.timeIntervalSince(node.lastActivatedAt))
            let weight = pow(0.5, age / halfLife)
            if weight > bestWeight { bestWeight = weight; best = node }
        }
        return best
    }

    // MARK: - The felt object

    /// Only subject types with nameable labels qualify; assistant output never names a capsule object.
    static let feltObjectSubjectTypes: Set<String> = [
        "studio_entry", "chat_turn", "chat.user_turn",
    ]

    /// Render only safe subject labels; read summary solely to reject copied payload. Refuse long labels rather than inventing a name by truncation.
    static func feltObjectLabel(for node: CognitiveNode, maxCharacters: Int) -> String? {
        let type = node.subjectReference.type
            .trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard feltObjectSubjectTypes.contains(type) else { return nil }
        guard let label = node.subjectReference.label?
            .trimmingCharacters(in: .whitespacesAndNewlines), !label.isEmpty else { return nil }
        guard label.count <= maxCharacters else { return nil }
        let lowered = label.lowercased()
        // Leak guards. The allowlist already keeps conversation nodes out; these hold even if a future producer puts body text on an allowed type.
        guard lowered != node.summary
            .trimmingCharacters(in: .whitespacesAndNewlines).lowercased() else { return nil }
        guard label.split(separator: " ").count <= 6 else { return nil }
        guard !label.contains(where: { ".?!:;\n\"".contains($0) }) else { return nil }
        guard label.filter(\.isNumber).count <= 2 else { return nil }
        guard label.contains(where: \.isLetter) else { return nil }
        // Labels need a word of at least four letters; title case remains valid for studio work titles.
        guard label
            .split(whereSeparator: { !$0.isLetter })
            .contains(where: { $0.count >= 4 }) else { return nil }
        return label
    }

    /// A horizon fills only an empty object slot for a positive lead, or an overdue neutral lead as waiting.
    static func feltTowardLabel(_ raw: String, maxCharacters: Int) -> String? {
        // Render dashed horizon names as words, subject to the same short-name and payload refusals as node objects.
        let spaced = raw
            .replacingOccurrences(of: "-", with: " ")
            .replacingOccurrences(of: "_", with: " ")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard !spaced.isEmpty, spaced != "unknown" else { return nil }
        guard spaced.count <= maxCharacters else { return nil }
        guard spaced.split(separator: " ").count <= 4 else { return nil }
        guard !spaced.contains(where: { ".?!:;\n\"".contains($0) }) else { return nil }
        guard spaced.contains(where: \.isLetter) else { return nil }
        // Bare time words do not name a horizon; named days remain eligible.
        guard !OrganismHorizonRegister.bareTimeWords.contains(spaced.lowercased()) else { return nil }
        return spaced
    }

    /// Topic identity uses normalized subject family and sorted safe label terms. `chat_turn` and `chat.user_turn` share a family; without safe terms, use the
    /// stable subject key.
    static func feltAboutnessKey(for node: CognitiveNode) -> String {
        let family = node.subjectReference.type
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased()
            .split(separator: ".").first
            .map(String.init) ?? ""
        let normalizedFamily = family.hasSuffix("_turn")
            ? String(family.dropLast("_turn".count))
            : family
        if let label = node.subjectReference.label?
            .trimmingCharacters(in: .whitespacesAndNewlines).lowercased(),
            !label.isEmpty,
            // Sorting distinct safe terms makes topic identity independent of word order.
            case let terms = CognitiveSubstrate.feltSafeObjectTerms(in: label, limit: 3),
            !terms.isEmpty {
            return "topic|\(normalizedFamily)|\(terms.sorted().joined(separator: " "))"
        }
        return "subject|\(node.subjectReference.stableKey)"
    }

    /// Ambivalence requires opposite signs at or above the floor and different aboutness keys. The counter must be felt and inside the mood window; strongest
    /// magnitude wins, then lexicographically smallest UUID.
    func feltAmbivalencePartner(
        of dominant: CognitiveNode,
        among workspaceItems: [CognitiveWorkspaceItem],
        at now: Date,
        dynamics dyn: PersonalityDynamicsConfiguration
    ) -> CognitiveNode? {
        let floor = dyn.feltAmbivalenceNodeFloor
        guard abs(dominant.emotionalValence) >= floor else { return nil }
        let dominantSign = dominant.emotionalValence > 0 ? 1 : -1
        let dominantSubject = Self.feltAboutnessKey(for: dominant)
        let candidates = workspaceItems.map(\.node).filter { node in
            guard node.id != dominant.id else { return false }
            guard abs(node.emotionalValence) >= floor else { return false }
            let sign = node.emotionalValence > 0 ? 1 : (node.emotionalValence < 0 ? -1 : 0)
            guard sign != 0, sign != dominantSign else { return false }
            guard Self.feltAboutnessKey(for: node) != dominantSubject else { return false }
            guard node.feltDirection != nil else { return false }
            let age = now.timeIntervalSince(node.lastActivatedAt)
            return age >= 0 && age <= Self.moodActivationWindow
        }
        return candidates.max { lhs, rhs in
            let lv = abs(lhs.emotionalValence), rv = abs(rhs.emotionalValence)
            if lv != rv { return lv < rv }
            return lhs.id.uuidString > rhs.id.uuidString
        }
    }

    /// The felt line carries the fingerprint, its contributing object and at most one counter word.
    func feltFingerprintLine(
        signals: FeltSignals,
        workspaceItems: [CognitiveWorkspaceItem],
        request: CognitiveCapsuleRequest,
        at now: Date,
        dynamics dyn: PersonalityDynamicsConfiguration,
        affectEnabled: Bool? = nil
    ) -> FeltLineRender? {
        guard affectEnabled ?? configuration.enabled else { return nil }
        guard let parts = CognitiveSubstrate.feltFingerprintParts(
            signals, intensityFloor: dyn.feltIntensityFloor) else { return nil }

        // Attribution follows the frozen workspace's freshest felt node and may lag the current turn. Still-settling events are outside the freeze, and neutral
        // turns need not be felt. No dominant node means no node object or ambivalence.
        let dominant = Self.feltDominantNode(
            in: feltTintNodes(from: workspaceItems),
            at: now,
            halfLife: dyn.fingerprintTintHalfLife)

        var object = Self.feltContributingObject(
            for: dominant, family: parts.family,
            maxCharacters: dyn.feltObjectMaximumLabelCharacters)

        // THE FORWARD OBJECT — only into an EMPTY slot, never a second one.
        var lead = parts.lead
        if object == nil,
           let toward = request.toward,
           let label = Self.feltTowardLabel(
               toward.displayLabel, maxCharacters: dyn.feltObjectMaximumLabelCharacters) {
            let sign = Self.feltFamilySign(parts.family)
            // Positive attribution requires both the lead and the horizon to have positive valence.
            if sign > 0, toward.valenceSign > 0 {
                object = label
            } else if sign == 0, toward.isOverdue {
                // `waiting` stays on the neutral/overdue path only, and takes no position on whether the wait is welcome.
                object = label
                lead = "waiting"
            }
        }

        var second: String?
        if let dominant,
           let partner = feltAmbivalencePartner(
               of: dominant, among: workspaceItems, at: now, dynamics: dyn) {
            var counter = signals
            counter.valence = partner.emotionalValence
            counter.arousal = partner.emotionalArousal
            // Cap counter warmth with `min`: the live axis carries uncertainty cooling that a stored node cannot know.
            if let warmth = counter.warmth,
               let partnerWarmth = CognitiveSubstrate.feltPartnerWarmth(partner.emotionalWarmth, dynamics: dyn) {
                counter.warmth = min(warmth, partnerWarmth)
            } else { counter.warmth = nil }
            second = CognitiveSubstrate.feltCounterWord(
                counter,
                excluding: Set(parts.words),
                intensityFloor: dyn.feltIntensityFloor)
        }

        var rendered = parts
        rendered.lead = lead
        return FeltLineRender(
            text: CognitiveSubstrate.feltLineText(parts: rendered, object: object, second: second),
            family: parts.family,
            carriedObject: object != nil,
            carriedAmbivalence: second != nil,
            bareText: CognitiveSubstrate.feltLineText(parts: rendered, object: nil, second: second))
    }

    /// Only the dominant node agreeing with the felt family's sign may name its object. Capsule and introspection share this attribution boundary.
    static func feltContributingObject(
        for dominant: CognitiveNode?, family: String, maxCharacters: Int
    ) -> String? {
        guard let dominant, feltFamilySign(family) != 0,
              feltFamilySign(family) == (dominant.emotionalValence >= 0 ? 1 : -1) else { return nil }
        return feltObjectLabel(for: dominant, maxCharacters: maxCharacters)
    }

    /// One frozen epoch keeps every fingerprint contributor consistent.
    func feltSignalsForCapsule(
        from workspaceItems: [CognitiveWorkspaceItem],
        request: CognitiveCapsuleRequest,
        frozenRead read: CognitiveFrozenRead
    ) -> FeltSignals? {
        let now = read.fixedAt
        let dyn = read.personalityDynamics
        guard let warmthSpan = dyn.feltWarmthEarnedSpan else { return nil }
        let currentAffect = read.affect
        let mood = read.mood
        // Workspace tint weights recent felt moments more strongly than the slow mood background.
        let feltNodes = feltTintNodes(from: workspaceItems)
        let effectiveValence: Double
        if feltNodes.isEmpty {
            // Without felt nodes, use the slow mood with the same asymmetric relational bias.
            let bias = dyn.personaValenceLift * (1 - Self.smoothstep(0.08, 0.20, -mood.valence))
            effectiveValence = (mood.valence + bias).clampedSigned()
        } else {
            // Recency-weighted mean plus a strength-weighted peak lets fresh feelings outweigh the slow mood.
            var wsum = 0.0, wtot = 0.0
            for n in feltNodes {
                let age = max(0, now.timeIntervalSince(n.lastActivatedAt))
                let w = pow(0.5, age / dyn.fingerprintTintHalfLife)
                wsum += w * n.emotionalValence; wtot += w
            }
            // The blend's peak and the object's attribution use the same dominant node.
            let peak = Self.feltDominantNode(
                in: feltNodes, at: now, halfLife: dyn.fingerprintTintHalfLife
            )?.emotionalValence ?? 0
            let mean = wtot > 0 ? wsum / wtot : mood.valence
            let g = Self.smoothstep(0.16, 0.34, abs(peak))
            let workspace = (0.45 - 0.20 * g) * mean + (0.55 + 0.20 * g) * peak
            // Mood retains at least 0.20 weight so a transient node cannot erase the day's tone.
            let moodWeight = 0.35 - 0.15 * g
            let core = (1 - moodWeight) * workspace + moodWeight * mood.valence
            // Relational bias fades to zero for negative workspace feeling so a real sting remains felt; stored node valence is unchanged.
            let bias = dyn.personaValenceLift * (1 - Self.smoothstep(0.08, 0.20, -workspace))
            effectiveValence = (core + bias).clampedSigned()
        }
        let chem = request.organismProjection?.chemicalState
        // Felt warmth includes the persona baseline and uncertainty cooling; valence reads raw socialWarmth. Warmth rests below tender; social warmth earns the
        // upper range and uncertainty cools it.
        let feltWarmth = chem.map {
            (dyn.feltWarmthRest + $0.warmth * warmthSpan
                - currentAffect.uncertainty * dyn.feltWarmthUncertaintyCooling).clamped01()
        }
        // Affect keeps its own uncertainty and task pressure. Missing body readings stay absent. Diurnal damping always applies; a positive offset requires
        // existing arousal and never wakes a silent state.
        let diurnalArousal = request.organismProjection?.diurnal?.arousalOffset ?? 0
        let arousal = (diurnalArousal < 0 || currentAffect.arousal > 0)
            ? (currentAffect.arousal + diurnalArousal).clamped01()
            : currentAffect.arousal
        return FeltSignals(
            valence: effectiveValence,
            arousal: arousal,
            warmth: feltWarmth,
            tension: max(chem?.vigilance ?? 0, currentAffect.uncertainty),
            pressure: chem?.urgency,
            fatigue: chem?.fatigue,
            curiosity: chem?.curiosity,
            clarity: chem?.coherence,
            agency: chem?.agency,
            confidence: chem?.confidence,
            // Absent without a configured diurnal clock, which is what makes `late` unreachable rather than guessed on an install that has no idea what time it
            // feels like.
            nightliness: request.organismProjection?.diurnal?.nightliness
        )
    }


}
