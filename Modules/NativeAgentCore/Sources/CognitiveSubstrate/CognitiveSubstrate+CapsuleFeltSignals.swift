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

    /// The node whose valence carries DIRECT weight in the fingerprint's
    /// valence — the `peak` term. Recency weight is strictly decreasing in age,
    /// so this is the freshest felt node, resolved by the same
    /// strictly-greater-than rule the tint loop uses (first one wins a tie,
    /// which under a frozen clock is the workspace's own order).
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

    /// The object phrase for one node, or nil.
    ///
    /// PAYLOAD-FREE BY CONSTRUCTION: the only field read is
    /// `subjectReference.label`. `summary` — which on a conversation node IS
    /// the user's redacted message text — is read only to REFUSE a label that
    /// has become a copy of it, never to render. The remaining guards make the
    /// label prove it is a name and not a sentence: short, few words, no
    /// sentence punctuation, not an id.
    ///
    /// Over-length is a REFUSAL, not a trim. Truncating "the deploy pipeline
    /// rewrite we…" at 32 characters manufactures a phrase she would then read
    /// as the name of a thing.
    static func feltObjectLabel(for node: CognitiveNode, maxCharacters: Int) -> String? {
        let type = node.subjectReference.type
            .trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard feltObjectSubjectTypes.contains(type) else { return nil }
        guard let label = node.subjectReference.label?
            .trimmingCharacters(in: .whitespacesAndNewlines), !label.isEmpty else { return nil }
        guard label.count <= maxCharacters else { return nil }
        let lowered = label.lowercased()
        // Leak guards. The allowlist already keeps conversation nodes out; these
        // hold even if a future producer puts body text on an allowed type.
        guard lowered != node.summary
            .trimmingCharacters(in: .whitespacesAndNewlines).lowercased() else { return nil }
        guard label.split(separator: " ").count <= 6 else { return nil }
        guard !label.contains(where: { ".?!:;\n\"".contains($0) }) else { return nil }
        guard label.filter(\.isNumber).count <= 2 else { return nil }   // not an id
        guard label.contains(where: \.isLetter) else { return nil }
        // Labels need a word of at least four letters; title case remains valid for studio work titles.
        guard label
            .split(whereSeparator: { !$0.isLetter })
            .contains(where: { $0.count >= 4 }) else { return nil }
        return label
    }

    /// A horizon fills only an empty object slot for a positive lead, or an overdue neutral lead as waiting.
    static func feltTowardLabel(_ raw: String, maxCharacters: Int) -> String? {
        // Horizon labels are canonicalised with dashes ("dinner-with-user-8pm");
        // spaces read as language. Same refusals as the node object: short,
        // few words, no sentence punctuation, and a real letter in it.
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

    /// Topic identity uses normalized subject family and sorted safe label terms.
    /// `chat_turn` and `chat.user_turn` share a family; without safe terms, use the stable subject key.
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
            // Use up to three distinct safe terms, then sort them for comparison.
            case let terms = CognitiveSubstrate.feltSafeObjectTerms(in: label, limit: 3),
            !terms.isEmpty {
            return "topic|\(normalizedFamily)|\(terms.sorted().joined(separator: " "))"
        }
        return "subject|\(node.subjectReference.stableKey)"
    }

    /// Ambivalence requires opposite signs at or above the floor and different aboutness keys.
    /// The counter must be felt and inside the mood window; strongest magnitude wins,
    /// then lexicographically smallest UUID.
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

        // Attribution follows the frozen workspace's freshest felt node and may lag the current turn.
        // Still-settling events are outside the freeze, and neutral turns need not be felt.
        // No dominant node means no node object or ambivalence.
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
                // `waiting` stays on the neutral/overdue path only, and takes
                // no position on whether the wait is welcome.
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
            // The partner has to have EARNED any warmth the underneath word
            // claims. `min` rather than substitution: the live axis carries the
            // uncertainty cooling this node has no way to know about, so the cap
            // can only ever cool the counter, never warm it.
            counter.warmth = min(
                counter.warmth,
                CognitiveSubstrate.feltPartnerWarmth(partner.emotionalWarmth, dynamics: dyn))
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

    /// Only the dominant node agreeing with the felt family's sign may name
    /// its object. Capsule and introspection share this attribution boundary.
    static func feltContributingObject(
        for dominant: CognitiveNode?, family: String, maxCharacters: Int
    ) -> String? {
        guard let dominant, feltFamilySign(family) != 0,
              feltFamilySign(family) == (dominant.emotionalValence >= 0 ? 1 : -1) else { return nil }
        return feltObjectLabel(for: dominant, maxCharacters: maxCharacters)
    }

    /// Compile the fingerprint's signals from one frozen epoch.
    func feltSignalsForCapsule(
        from workspaceItems: [CognitiveWorkspaceItem],
        request: CognitiveCapsuleRequest,
        frozenRead read: CognitiveFrozenRead
    ) -> FeltSignals {
        let now = read.fixedAt
        let dyn = read.personalityDynamics
        let currentAffect = read.affect
        let mood = read.mood
        // Workspace tint weights recent felt moments more strongly than the slow mood background.
        let feltNodes = feltTintNodes(from: workspaceItems)
        let effectiveValence: Double
        if feltNodes.isEmpty {
            // No felt nodes: her slow mood, with the same asymmetric warm-with-User bias.
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
            // Warm-with-User bias — ASYMMETRIC: full when the moment is neutral/positive,
            // fading to zero as the workspace goes negative, so a genuine sting is never
            // cushioned. Fingerprint-only; stored node valence (mood/recall/dream) untouched.
            let bias = dyn.personaValenceLift * (1 - Self.smoothstep(0.08, 0.20, -workspace))
            effectiveValence = (core + bias).clampedSigned()
        }
        let chem = request.organismProjection?.chemicalState
        // Felt warmth includes the persona baseline and uncertainty cooling; valence reads raw socialWarmth.
        let rawWarmth = chem?.warmth ?? currentAffect.socialWarmth
        // Warmth rests below tender; social warmth earns the upper range and uncertainty cools it.
        let feltWarmth = (dyn.feltWarmthRest
            + rawWarmth * dyn.feltWarmthEarnedSpan
            - currentAffect.uncertainty * dyn.feltWarmthUncertaintyCooling).clamped01()
        // Unknown dimensions stay absent; pure substrate proxies require evidence, and agency/confidence require the organism.
        // Diurnal damping always applies; a positive offset requires existing arousal and never wakes a silent state.
        let diurnalArousal = request.organismProjection?.diurnal?.arousalOffset ?? 0
        let arousal = (diurnalArousal < 0 || currentAffect.arousal > 0)
            ? (currentAffect.arousal + diurnalArousal).clamped01()
            : currentAffect.arousal
        return FeltSignals(
            valence: effectiveValence,
            arousal: arousal,
            warmth: feltWarmth,
            tension: max(chem?.vigilance ?? 0, currentAffect.uncertainty),
            pressure: chem?.urgency ?? currentAffect.taskPressure,
            fatigue: chem?.fatigue ?? read.feltProxies.fatigue,
            curiosity: chem?.curiosity ?? read.feltProxies.curiosity,
            clarity: chem?.coherence ?? read.feltProxies.clarity,
            agency: chem?.agency,
            confidence: chem?.confidence,
            // Absent without a configured diurnal clock, which is what makes
            // `late` unreachable rather than guessed on an install that has no
            // idea what time it feels like.
            nightliness: request.organismProjection?.diurnal?.nightliness
        )
    }

    // MARK: - Substrate-native proxies

    /// Fatigue perception thresholds belong here; personality dynamics do not change the duration of an hour.
    static let fatigueOnsetSeconds: TimeInterval = 45 * 60
    static let fatigueSaturationSeconds: TimeInterval = 5 * 60 * 60
    /// Turn-to-turn spacing at which cadence stops counting as sustained work.
    static let fatigueRapidCadenceSeconds: TimeInterval = 4 * 60

    /// FATIGUE ← how long she has been at this, and how hard.
    ///
    /// Two honest components over timestamps the substrate already stamps on
    /// every node: SESSION LENGTH (first live conversational node in the current
    /// 24h stretch → now) and CADENCE (a dense run of turns is more tiring than
    /// the same span spent idle). Returns nil with fewer than two live turns —
    /// one message is not a session, and guessing there is how a fresh install
    /// would start out claiming to be tired.
    ///
    /// This is the dim the organism's chemistry models best, so chemistry always
    /// wins when it is present; this is the floor under it, not a replacement.
    func substrateFatigueProxy(at now: Date) -> Double? {
        let turns = field.peekNodes()
            .filter { node in
                node.turnKind == .live
                    && (node.kind == .conversationFocus || node.kind == .correction)
            }
            .map(\.createdAt)
            .filter { now.timeIntervalSince($0) >= 0 && now.timeIntervalSince($0) <= 24 * 60 * 60 }
            .sorted()
        guard turns.count >= 2, let first = turns.first else { return nil }

        let span = now.timeIntervalSince(first)
        let lengthTerm = Self.smoothstep(
            Self.fatigueOnsetSeconds, Self.fatigueSaturationSeconds, span)

        // Mean spacing across the stretch. Tight spacing over a long span is
        // sustained work; the same span with three messages in it is not.
        let meanGap = span / Double(max(1, turns.count - 1))
        let cadenceTerm = 1 - Self.smoothstep(
            Self.fatigueRapidCadenceSeconds, Self.fatigueRapidCadenceSeconds * 6, meanGap)

        // Length leads: a fast burst in the first ten minutes is energizing, not
        // tiring, so cadence only amplifies a stretch that is already long.
        return (lengthTerm * (0.65 + 0.35 * cadenceTerm)).clamped01()
    }

    /// CURIOSITY ← how much of what she is holding right now is NEW.
    ///
    /// Novelty of the current workspace subjects against the seven-day field: a
    /// subject the field has never activated is new territory; one it has been
    /// circling for a week is not. `peekDecayedNodes` is the existing pure read
    /// (a snapshot would ADVANCE decay, and a felt read must never age her
    /// memory — the same rule `derivedMood` and `feltDaySummary` follow).
    ///
    /// Returns nil when no held node has an identifiable topic: no topic means
    /// no honest read on novelty, not "incurious".
    func substrateCuriosityProxy(from workspaceItems: [CognitiveWorkspaceItem], at now: Date) -> Double? {
        let held = workspaceItems.prefix(6).map(\.node)
        let heldTopics = held.compactMap { node -> String? in
            let key = Self.feltAboutnessKey(for: node)
            return key.hasPrefix("topic|") ? key : nil
        }
        guard !heldTopics.isEmpty else { return nil }

        // Use the same topic identity across turns; message IDs are unique even
        // when ordinary chat returns to something familiar.
        let heldIds = Set(held.map(\.id))
        var seenSubjects: [String: Double] = [:]
        for node in field.peekDecayedNodes(at: now) where !heldIds.contains(node.id) {
            let key = Self.feltAboutnessKey(for: node)
            guard key.hasPrefix("topic|") else { continue }
            seenSubjects[key] = max(seenSubjects[key] ?? 0, node.activation)
        }

        var novelty = 0.0
        for key in heldTopics {
            // A familiar subject that is strongly activated is the LEAST novel;
            // a familiar-but-cold one is partway back to new.
            let familiarity = seenSubjects[key] ?? 0
            novelty += (1 - familiarity.clamped01())
        }
        return (novelty / Double(heldTopics.count)).clamped01()
    }

    /// CLARITY ← the inverse of uncertainty, docked for an unresolved question.
    ///
    /// `affect.uncertainty` is the substrate's own honest read on how murky
    /// things are. `pendingCompletion` is a completion still waiting to find out
    /// how it landed — an open loop, which is exactly what un-clear feels like.
    /// Always available (uncertainty is always defined once affect is on), so
    /// unlike the other two this one does not return nil.
    func substrateClarityProxy(affect: CognitiveAffectState, at now: Date) -> Double? {
        guard configuration.enabled else { return nil }
        var clarity = 1 - affect.uncertainty.clamped01()
        if let pending = pendingCompletion {
            let age = now.timeIntervalSince(pending.recordedAt)
            if age >= 0, age <= Self.pendingCompletionMaxAge {
                // Fades as the window ages: a question asked ten seconds ago
                // clouds things more than one about to expire.
                let freshness = 1 - (age / Self.pendingCompletionMaxAge)
                clarity -= 0.15 * freshness
            }
        }
        return clarity.clamped01()
    }

}
