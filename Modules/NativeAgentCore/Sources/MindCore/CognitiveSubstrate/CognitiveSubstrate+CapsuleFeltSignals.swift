import Foundation
import NativeAgentCore
import NativeAgentShared
import PersistenceCore
// Blueprint: | `CognitiveSubstrate+CapsuleFeltSignals.swift` | `CognitiveSubstrate`: felt contributors, exchange-care objects, and ambivalence |

extension CognitiveSubstrate {
    struct FeltFrameLead: Sendable, Equatable {
        let word: FeltFrameWord
        let overlays: [FeltFrameWord]
        let counterAxis: FeltDim?
    }

    /// A rendered felt line retains its carried state so presentation receipts need no string parsing.
    struct FeltLineRender: Sendable, Equatable {
        var text: String
        var family: String
        var object: String?
        var carriedObject: Bool
        var leadWord: FeltFrameLead
        var counterWord: String?
        /// The care whose movement supplied the counter word (`care:<id>`, or `care:held` for one this speaker may not see); nil when a workspace
        /// node did, or there is none.
        var counterSource: String?
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

    static func feltExchangeCares(
        for node: CognitiveNode, among cares: [CognitiveCare], at now: Date
    ) -> (primary: CognitiveCare, ids: Set<UUID>, movementIndex: Int)? {
        let subject = node.subjectReference
        guard subject.isChatTurn, subject.type.lowercased() != "chat.assistant_turn",
              subject.type.lowercased() != "chat_turn" || node.metadata["role"] == .string("user"),
              let session = node.sessionId, NativeAgentChatSessionID.isSafePathComponent(session),
              case .string(let message)? = node.metadata["messageId"], !message.isEmpty,
              subject.id == "\(session):\(message)" else { return nil }
        let source = "exchange:\(session)/\(message)"
        var ids: Set<UUID> = []
        var best: (care: CognitiveCare, magnitude: Double, at: Date, movementIndex: Int)?
        for care in cares where care.mergedInto == nil {
            for (index, move) in care.story.enumerated()
            where move.source == source && move.moved != 0 && feltOwnMovement(move) {
                guard move.at <= now else { continue }
                ids.insert(care.id)
                let magnitude = abs(move.moved)
                if let held = best {
                    if magnitude < held.magnitude { continue }
                    if magnitude == held.magnitude {
                        if move.at < held.at { continue }
                        if move.at == held.at && care.id.uuidString >= held.care.id.uuidString { continue }
                    }
                }
                best = (care, magnitude, move.at, index)
            }
        }
        return best.map { ($0.care, ids, $0.movementIndex) }
    }

    func feltCareObjectLabel(_ care: CognitiveCare, reachable: Set<UUID>) -> String? {
        guard reachable.contains(care.id),
              let name = care.about.trimmedNonEmpty,
              !JSONValueBounding.containsSecretLikeValue(name) else { return nil }
        return capsuleLineText(name, maxCharacters: CognitiveInnerStateReading.careSubjectCharacters)
    }

    static func storedFeltSubjectLabel(for node: CognitiveNode, maxCharacters: Int) -> String? {
        let subject = node.subjectReference
        guard !subject.isChatTurn, subject.type.lowercased() != "organism_horizon",
              !subject.id.isEmpty, let label = subject.label?.trimmedNonEmpty,
              label.count <= maxCharacters else { return nil }
        return label
    }

    /// Render only safe subject labels; read summary solely to reject copied payload. Refuse long labels rather than inventing a name by truncation.
    static func feltObjectLabel(for node: CognitiveNode, maxCharacters: Int) -> String? {
        guard node.subjectReference.type.lowercased() == studioEntrySubjectType,
              let label = storedFeltSubjectLabel(for: node, maxCharacters: maxCharacters) else { return nil }
        let lowered = label.lowercased()
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

    private static func canNameFeltHorizon(_ request: CognitiveCapsuleRequest, turn: Turn?) -> Bool {
        request.fromUser && turn?.steeringStamp().isEmpty == true
    }

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

    static func feltWorkspaceComparisonKey(for node: CognitiveNode) -> String? {
        guard !node.subjectReference.isChatTurn else { return nil }
        let family = node.subjectReference.type
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased()
            .split(separator: ".").first
            .map(String.init) ?? ""
        let normalizedFamily = family.hasSuffix("_turn")
            ? String(family.dropLast("_turn".count))
            : family
        if node.subjectReference.type.lowercased() != "organism_horizon",
            let label = node.subjectReference.label?
            .trimmingCharacters(in: .whitespacesAndNewlines).lowercased(),
            !label.isEmpty,
            // Sorting distinct safe terms makes topic identity independent of word order.
            case let terms = CognitiveSubstrate.feltSafeObjectTerms(in: label),
            !terms.isEmpty {
            return "topic|\(normalizedFamily)|\(terms.sorted().joined(separator: " "))"
        }
        return "subject|\(node.subjectReference.stableKey)"
    }

    func feltAmbivalencePartner(
        of dominant: CognitiveNode,
        direction: Int,
        among workspaceItems: [CognitiveWorkspaceItem],
        at now: Date,
        dynamics dyn: PersonalityDynamicsConfiguration
    ) -> CognitiveNode? {
        let floor = dyn.feltAmbivalenceNodeFloor
        guard abs(dominant.emotionalValence) >= floor else { return nil }
        let dominantSubject = Self.feltWorkspaceComparisonKey(for: dominant)
        let candidates = workspaceItems.map(\.node).filter { node in
            guard node.id != dominant.id else { return false }
            guard Double(direction) * node.emotionalValence >= floor else { return false }
            guard let subject = Self.feltWorkspaceComparisonKey(for: node),
                  subject != dominantSubject else { return false }
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

    static func feltOwnMovement(_ moment: CognitiveCare.Moment) -> Bool {
        moment.by != .them || moment.who == CognitiveCare.ownerKey
    }

    private static func feltCarePartner(
        leadSign: Int,
        leadCare: (id: UUID, movementIndex: Int)?,
        relatedCareIDs: Set<UUID>,
        among cares: [CognitiveCare],
        reachable: [CognitiveCare],
        alongside picked: [FeltFrameWord],
        signals: FeltSignals,
        at now: Date,
        dynamics dyn: PersonalityDynamicsConfiguration
    ) -> (strength: Double, word: FeltFrameWord, source: String)? {
        guard leadSign >= 0 || leadCare != nil else { return nil }
        let direction = leadSign < 0 ? 1.0 : -1.0
        func word(_ felt: String) -> String { felt.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() }
        func charge(_ care: CognitiveCare) -> Double {
            var own = care
            own.story.removeAll { $0.at > now || !feltOwnMovement($0) }
            return direction * own.charge(at: now)
        }
        let seen = Set(reachable.map(\.id))
        // Feelings she has had about what this speaker may see; a hidden care speaks only in these.
        var lived: Set<String> = []
        for care in reachable {
            for moment in care.story where moment.moved != 0 && moment.at <= now && feltOwnMovement(moment) {
                lived.insert(word(moment.felt))
            }
        }
        let intensity = Self.feltIntensity(signals)
        var best: (strength: Double, word: FeltFrameWord, care: CognitiveCare)?
        for care in cares {
            guard leadSign < 0 ? care.id == leadCare?.id : !relatedCareIDs.contains(care.id) else { continue }
            for (index, moment) in care.story.enumerated()
            where (leadSign >= 0 || index != leadCare?.movementIndex) && direction * moment.moved > 0 && feltOwnMovement(moment) {
                let age = now.timeIntervalSince(moment.at)
                guard age >= 0, age <= moodActivationWindow else { continue }
                let strength = abs(care.movementCharge(moment, at: now))
                guard strength >= dyn.feltAmbivalenceNodeFloor else { continue }
                let said = word(moment.felt)
                guard seen.contains(care.id) || lived.contains(said) else { continue }
                // The sentence takes an adjective: a care's own word is said only when it is one of her feeling words.
                guard let word = Self.feltFamilyWords.values.joined().first(where: { $0.name == said })?.frameWord,
                      picked.allSatisfy(word.canAccompany), signals.compatibleWithNamedFeeling(word) else { continue }
                let gates = Self.signalGatedFeltWords.lazy.filter { $0.name == said }
                if !gates.isEmpty, !gates.contains(where: {
                    intensity >= $0.minIntensity && $0.requires.allSatisfy(signals.isPresent) && $0.pick(signals) > 0
                }) { continue }
                if let held = best {
                    if held.strength > strength { continue }
                    if held.strength == strength {
                        guard held.care.id != care.id else { continue }
                        let candidateCharge = charge(care), heldCharge = charge(held.care)
                        if heldCharge > candidateCharge
                            || (heldCharge == candidateCharge && held.care.id.uuidString <= care.id.uuidString) { continue }
                    }
                }
                best = (strength, word, care)
            }
        }
        guard let best else { return nil }
        // A hidden care is never identified, even in her own trace: a peer session can read a why.
        return (best.strength, best.word, seen.contains(best.care.id) ? "care:" + best.care.id.uuidString : "care:held")
    }

    /// The felt line carries the fingerprint, its contributing object and at most one counter word.
    func feltFingerprintLine(
        signals: FeltSignals,
        workspaceItems: [CognitiveWorkspaceItem],
        reachable: [CognitiveCare],
        request: CognitiveCapsuleRequest,
        from read: CognitiveFrozenRead,
        turn: Turn?
    ) -> FeltLineRender? {
        guard read.configuration.enabled else { return nil }
        let now = read.fixedAt
        let dyn = read.personalityDynamics
        guard let parts = CognitiveSubstrate.feltFingerprint(
            signals, intensityFloor: dyn.feltIntensityFloor) else { return nil }

        let dominant = Self.feltDominantNode(
            in: feltTintNodes(from: workspaceItems),
            at: now,
            halfLife: dyn.fingerprintTintHalfLife)

        let leadSign = Self.feltFamilySign(parts.family)
        let contribution = feltObjectContribution(
            for: dominant, leadSign: leadSign, reachable: Set(reachable.map(\.id)),
            from: read, maxCharacters: dyn.feltObjectMaximumLabelCharacters)
        var lead = parts.lead
        let isDreading = lead.name == Self.dreading.name
        let isNamedLead = parts.isNamedLead
        let nodeObject = isNamedLead ? nil : contribution.label
        var object = nodeObject

        // THE FORWARD OBJECT — only into an EMPTY slot, never a second one.
        if !isNamedLead, object == nil,
           let toward = request.toward,
           toward.peerStartedAt == nil,
           let label = Self.feltTowardLabel(
               toward.displayLabel, maxCharacters: dyn.feltObjectMaximumLabelCharacters) {
            let allowsForwardObject = dominant?.subjectReference.isChatTurn != true
                && Self.canNameFeltHorizon(request, turn: turn)
            if allowsForwardObject,
               ((leadSign > 0 || lead.axis == .anticipation) && toward.valenceSign > 0)
                   || (isDreading && toward.valenceSign < 0) {
                object = label
            } else if leadSign == 0, toward.isOverdue,
                      !Self.signalGatedFeltWords.contains(where: { $0.name == lead.name }) {
                // `waiting` stays on the neutral/overdue path only, and takes no position on whether the wait is welcome.
                if allowsForwardObject { object = label }
                lead = FeltFrameWord(name: "waiting", axis: nil, contradicts: [])
            }
        }

        let picked = [lead] + parts.overlays
        let care = Self.feltCarePartner(
            leadSign: leadSign, leadCare: contribution.leadCare, relatedCareIDs: contribution.relatedCareIDs,
            among: Self.capsuleLiveCares(for: request, from: read), reachable: reachable,
            alongside: picked, signals: signals, at: now, dynamics: dyn)
        var second = care?.word
        var counterSource = care?.source
        if let dominant,
           let partner = feltAmbivalencePartner(
               of: dominant, direction: leadSign < 0 ? 1 : -1, among: workspaceItems, at: now, dynamics: dyn) {
            var counter = signals
            counter.valence = partner.emotionalValence
            counter.arousal = partner.emotionalArousal
            // Cap counter warmth with `min`: the live axis carries uncertainty cooling that a stored node cannot know.
            if let warmth = counter.warmth,
               let partnerWarmth = CognitiveSubstrate.feltPartnerWarmth(partner.emotionalWarmth, dynamics: dyn) {
                counter.warmth = min(warmth, partnerWarmth)
            } else { counter.warmth = nil }
            if let word = Self.feltCounterWord(
                counter, alongside: picked, intensityFloor: dyn.feltIntensityFloor),
               abs(partner.emotionalValence) >= (care?.strength ?? 0) {
                second = word
                counterSource = nil
            }
        }

        return FeltLineRender(
            text: CognitiveSubstrate.feltLineText(words: picked.map(\.name), family: parts.family, object: object, second: second?.name),
            family: parts.family,
            object: isDreading || lead.axis == .anticipation ? object : nodeObject,
            carriedObject: object != nil,
            leadWord: FeltFrameLead(word: lead, overlays: parts.overlays, counterAxis: second?.axis),
            counterWord: second?.name,
            counterSource: counterSource)
    }

    static func capsuleLiveCares(for request: CognitiveCapsuleRequest, from read: CognitiveFrozenRead) -> [CognitiveCare] {
        let terms = associationTerms(in: request.userMessage)
        return read.cares.filter { care in
            care.fadedAt == nil && !read.associationSuppressions.contains {
                $0.source == "care:" + care.id.uuidString && suppressionCovers($0.terms, messageTerms: terms)
            }
        }
    }

    /// The frame and the association selectors share the frozen care disclosure and rejection boundary.
    static func capsuleReachableCares(for request: CognitiveCapsuleRequest, from read: CognitiveFrozenRead) -> [CognitiveCare] {
        let speaker = request.speaker.map { CognitiveCareProvenance.personKey($0, aliases: read.carePersonAliases) }
            .flatMap { read.carePeopleAvailable || CognitiveCareProvenance.independentPersonKey($0) ? $0 : nil }
        return capsuleLiveCares(for: request, from: read).filter { care in
            care.with.isEmpty || speaker == CognitiveCare.ownerKey || speaker.map(care.with.contains) == true
        }
    }

    /// Descriptions cover quiet states too; missing chemistry never becomes a feeling. Warmth and bracing are independent dimensions.
    private static func frameFeelingWords(
        request: CognitiveCapsuleRequest, read: CognitiveFrozenRead, leadWord: String?, counterWord: String?
    ) -> [(axis: String, word: String)] {
        var words: [(axis: String, word: String)] = []
        var tension: Double?
        let cognitionAvailable = frameCognitionAvailable(read)
        let feeling = cognitionAvailable ? read.affect.namedFeeling : nil
        if cognitionAvailable {
            let mood = read.mood.valence
            let arousal = read.affect.arousal
            let energy = arousal >= 0.52 ? "keyed up" : arousal <= 0.28 ? "quiet" : "engaged"
            words.append(("mood", mood >= 0.22 ? "good in myself" : mood <= -0.50 ? "heavy in myself" : mood <= -0.20 ? "a little heavy" : "even in myself"))
            words.append(("energy", energy))
            if let leadWord { words.append(("feeling", leadWord)) }
            if let feeling, feeling.strength >= namedFeelingFloor,
               feeling.name.rawValue != leadWord, feeling.name.rawValue != counterWord {
                words.append(("named", feeling.name.rawValue))
            }
            tension = read.affect.uncertainty
        }
        if let chemistry = request.organismProjection?.chemicalState {
            if let uncertainty = tension { tension = max(uncertainty, chemistry.vigilance) }
            else { tension = chemistry.vigilance }
            if let warmth = capsuleFeltWarmth(chemistry.warmth, from: read) {
                words.append((FeltDim.warmth.rawValue, warmth >= 0.62 ? "warm and open" : warmth >= 0.45 ? "quietly warm"
                    : warmth > 0.35 ? "neither warm nor cool" : "reserved"))
            }
            words.append((FeltDim.curiosity.rawValue, chemistry.curiosity >= 0.60 ? "keenly curious" : chemistry.curiosity >= 0.22 ? "curious" : "not drawn toward novelty"))
            words.append((FeltDim.fatigue.rawValue, chemistry.fatigue >= 0.33 ? "worn" : chemistry.fatigue >= 0.15 ? "a little tired" : "not tired"))
        }
        if let tension { words.append(("tension", tension >= 0.60 ? "braced" : tension >= 0.22 ? "a little braced" : "unbraced")) }
        if let prospect = request.organismProjection?.prospect, prospect.anticipation >= feltAnticipationFloor,
           let toward = request.toward, toward.peerStartedAt == nil, toward.valenceSign > 0 {
            words.append(("ahead", "looking forward"))
        }
        return words
    }

    public static let frameRestWords: Set<String> = ["even in myself", "neither warm nor cool", "not drawn toward novelty", "not tired", "unbraced"]

    static func frameCognitionAvailable(_ read: CognitiveFrozenRead) -> Bool {
        guard read.configuration.persistenceEnabled else { return true }
        let health = read.snapshot.persistenceHealth
        return !health.writesBlocked && (health.status == .healthy || health.status == .degraded)
    }

    func feelingFrame(
        request: CognitiveCapsuleRequest,
        read: CognitiveFrozenRead,
        dreamFeeling: String,
        leadWord: FeltFrameLead?,
        counterWord: String?,
        object: String?,
        presentationState: inout CognitiveCapsulePresentationState,
        turn: Turn?
    ) -> CognitiveFeelingFrame {
        let cognitionAvailable = Self.frameCognitionAvailable(read)
        let fingerprint = cognitionAvailable ? leadWord : nil
        let lead = fingerprint?.word
        let namedFeeling = cognitionAvailable ? read.affect.namedFeeling.map { (name: $0.name, strength: $0.strength) } : nil
        func compatible(_ word: String) -> Bool {
            guard let namedFeeling else { return true }
            let name = switch word {
            case "keenly curious": "curious"
            case "looking forward": "expectant"
            default: word
            }
            return Self.compatibleWithNamedFeeling(
                FeltFrameWord(name: name, axis: nil, contradicts: []), namedFeeling: namedFeeling)
        }
        var saidWords: Set<String> = []
        var saidAxes: Set<String> = []
        func say(_ word: String, axis: String?) -> Bool {
            guard !Self.frameRestWords.contains(word), !saidWords.contains(word) else { return false }
            if let axis, !saidAxes.insert(axis).inserted { return false }
            return saidWords.insert(word).inserted
        }
        if let lead { _ = say(lead.name, axis: lead.axis?.rawValue) }
        let counter = (cognitionAvailable ? counterWord : nil).flatMap {
            say($0, axis: fingerprint?.counterAxis?.rawValue) ? $0 : nil
        }
        let overlays = fingerprint?.overlays.compactMap { overlay -> (axis: String, word: String)? in
            guard let axis = overlay.axis?.rawValue, say(overlay.name, axis: axis) else { return nil }
            return (axis, overlay.name)
        } ?? []
        let overlayWords = overlays.map(\.word)
        let words = Self.frameFeelingWords(request: request, read: read, leadWord: lead?.name, counterWord: counter)
        let horizonLabel = words.contains(where: { $0.axis == "ahead" }) && Self.canNameFeltHorizon(request, turn: turn)
            ? request.toward.flatMap {
                Self.feltTowardLabel($0.displayLabel, maxCharacters: read.personalityDynamics.feltObjectMaximumLabelCharacters)
            } : nil
        var description: [String] = []
        var frameWords: [String] = []
        for (axis, word) in words {
            if axis == "feeling" {
                frameWords.append(word)
                if let subject = object {
                    description.append(word == Self.dreading.name ? "\(word) \(subject)" : "\(word) about \(subject)")
                } else {
                    description.append(word)
                }
                description.append(contentsOf: overlayWords)
                frameWords.append(contentsOf: overlayWords)
                continue
            }
            guard compatible(word), say(word, axis: axis == "ahead" ? FeltDim.anticipation.rawValue : axis) else { continue }
            frameWords.append(word)
            if axis == "ahead", let horizonLabel {
                description.append("\(word) to \(horizonLabel)")
            } else {
                description.append(word)
            }
        }
        var sentences = description.isEmpty ? [] : ["I feel " + description.joined(separator: ", ") + "."]
        if Self.canNameFeltHorizon(request, turn: turn), let toward = request.toward,
           let age = toward.peerWaitAge(at: read.fixedAt) {
            let peer = capsuleLineText(toward.displayLabel, maxCharacters: 48)
            if !peer.isEmpty { sentences.append("Waiting on \(peer) since \(age).") }
        }
        if !cognitionAvailable { sentences.append("My mood, energy and cares are unread just now.") }
        if let counter {
            let subject = fingerprint?.counterAxis == .anticipation ? horizonLabel.map { " about \($0)" } ?? "" : ""
            sentences.append("There is also something \(counter)\(subject) underneath.")
            frameWords.append(counter)
        }
        if request.organismProjection == nil { sentences.append("My body's warmth, curiosity and tiredness are unread just now.") }
        else if !words.contains(where: { $0.axis == FeltDim.warmth.rawValue }) { sentences.append("My warmth is unread just now.") }
        let continuity = words + overlays.filter { overlay in !words.contains { $0.axis == overlay.axis } }
        if let shift = feelingShift(for: continuity, where: compatible, presentationState: &presentationState) {
            sentences.append(shift)
        }

        let reachable = cognitionAvailable ? Self.capsuleReachableCares(for: request, from: read) : []
        var charged: [(CognitiveCare, Double)] = []
        for care in reachable {
            let charge = abs(care.charge(at: read.fixedAt))
            if charge > 0 { charged.append((care, charge)) }
        }
        charged.sort { left, right in left.1 != right.1 ? left.1 > right.1 : left.0.id.uuidString < right.0.id.uuidString }
        var named: [CognitiveCare] = charged.prefix(2).map { $0.0 }
        // A hurt has an object: the reachable care hurting most takes the weaker place, so bracing is about something. It holds that place on its
        // own charge, which only her later movement on it or its own clock eases; a larger glad care never pushes it out.
        var hurting: CognitiveCare?
        var deepest = -read.personalityDynamics.feltAmbivalenceNodeFloor
        for care in reachable {
            let charge = care.charge(at: read.fixedAt)
            let first = hurting == nil && charge <= deepest
            let deeper = charge < deepest
            let tied = charge == deepest && care.id.uuidString < (hurting?.id.uuidString ?? "")
            if first || deeper || tied { hurting = care; deepest = charge }
        }
        if let hurting, !named.contains(where: { $0.id == hurting.id }) {
            named = Array(named.prefix(1)) + [hurting]
        }
        let cares: [String] = named.map { care in
            // The hurting care speaks with the word of the movement that hurt, not a later kinder one.
            let hurts = care.id == hurting?.id
            let movement = care.story.last { moment in
                guard moment.at <= read.fixedAt else { return false }
                return hurts ? moment.moved < 0 : moment.moved != 0
            }
            let subject: String
            if care.origin == .seed, let movement, !movement.note.isEmpty { subject = movement.note }
            else { subject = care.about }
            let felt = movement.flatMap { $0.felt.isEmpty ? nil : $0.felt }
            return capsuleLineText(subject, maxCharacters: CognitiveInnerStateReading.careSubjectCharacters)
                + (felt.map { " (\($0))" } ?? "")
        }
        if !cares.isEmpty { sentences.append("On my mind: \(cares.joined(separator: "; ")).") }
        if !read.carePeopleAvailable { sentences.append("The people my cares belong with are unread just now.") }
        sentences.append(dreamFeeling)
        let paragraph = sentences.joined(separator: " ").components(separatedBy: .whitespacesAndNewlines)
            .filter { !$0.isEmpty }.joined(separator: " ")
        presentationState.feltShown = frameWords.isEmpty ? nil : frameWords.joined(separator: ", ")
        return CognitiveFeelingFrame(paragraph: paragraph, words: frameWords)
    }

    /// Only the dominant node agreeing with the felt family's sign may name its object. Capsule and introspection share this attribution boundary.
    func feltContributingObject(
        for dominant: CognitiveNode?, family: String, reachable: Set<UUID>,
        from read: CognitiveFrozenRead, maxCharacters: Int
    ) -> String? {
        feltObjectContribution(
            for: dominant, leadSign: Self.feltFamilySign(family), reachable: reachable,
            from: read, maxCharacters: maxCharacters).label
    }

    private func feltObjectContribution(
        for dominant: CognitiveNode?, leadSign: Int, reachable: Set<UUID>,
        from read: CognitiveFrozenRead, maxCharacters: Int
    ) -> (label: String?, leadCare: (id: UUID, movementIndex: Int)?, relatedCareIDs: Set<UUID>) {
        guard let dominant else { return (nil, nil, []) }
        let agrees = leadSign == (dominant.emotionalValence >= 0 ? 1 : -1)
        if let exchange = Self.feltExchangeCares(for: dominant, among: read.cares, at: read.fixedAt) {
            guard agrees else { return (nil, nil, exchange.ids) }
            return (feltCareObjectLabel(exchange.primary, reachable: reachable), (exchange.primary.id, exchange.movementIndex), exchange.ids)
        }
        return (agrees ? Self.feltObjectLabel(for: dominant, maxCharacters: maxCharacters) : nil, nil, [])
    }

    private static func capsuleFeltWarmth(_ warmth: Double, from read: CognitiveFrozenRead) -> Double? {
        let dyn = read.personalityDynamics
        guard frameCognitionAvailable(read), let warmthSpan = dyn.feltWarmthEarnedSpan else { return nil }
        return (dyn.feltWarmthRest + warmth * warmthSpan
            - read.affect.uncertainty * dyn.feltWarmthUncertaintyCooling).clamped01()
    }

    /// One frozen epoch keeps every fingerprint contributor consistent.
    func feltSignalsForCapsule(
        from workspaceItems: [CognitiveWorkspaceItem],
        request: CognitiveCapsuleRequest,
        frozenRead read: CognitiveFrozenRead
    ) -> FeltSignals? {
        let now = read.fixedAt
        let dyn = read.personalityDynamics
        guard dyn.feltWarmthEarnedSpan != nil else { return nil }
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
        var letdown: Double?
        for node in read.snapshot.nodes where node.kind == .feltResolution && node.turnKind.contributesToLivedState {
            guard node.metadata["resolutionKind"] == .string(OrganismResolutionFeltEvent.Kind.disappointment.rawValue) else { continue }
            let age = now.timeIntervalSince(node.lastActivatedAt)
            guard age >= 0, age <= Self.moodActivationWindow else { continue }
            let magnitude = max(0, -node.emotionalValence) * pow(0.5, age / dyn.moodRecencyHalfLife)
            letdown = max(letdown ?? 0, magnitude)
        }
        let projection = request.organismProjection
        let chem = projection?.chemicalState
        // Felt warmth includes the persona baseline and uncertainty cooling; valence reads raw socialWarmth. Warmth rests at neutral; social warmth earns the
        // upper range and uncertainty cools it.
        let feltWarmth = chem.flatMap { Self.capsuleFeltWarmth($0.warmth, from: read) }
        // Affect keeps its own uncertainty and task pressure. Missing body readings stay absent. Diurnal damping always applies; a positive offset requires
        // existing arousal and never wakes a silent state.
        let diurnalArousal = projection?.diurnal?.arousalOffset ?? 0
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
            nightliness: projection?.diurnal?.nightliness,
            dread: projection?.prospect.map(\.feltDread),
            anticipation: projection?.prospect.map(\.anticipation),
            missShadow: projection?.prospect.map(\.missShadow),
            letdown: letdown,
            tenderness: projection.flatMap { $0.tenderNamed ? $0.chemicalState.tenderness : nil },
            namedFeeling: currentAffect.namedFeeling.map { (name: $0.name, strength: $0.strength) }
        )
    }


}
