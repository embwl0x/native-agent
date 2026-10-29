import Foundation
import TurnTrace
import NativeAgentCore
import PersistenceCore
// Blueprint: | `CognitiveSubstrate+CapsuleSoundEcho.swift` | `CognitiveSubstrate`: `soundEchoRegisterScore`, `soundEchoLandingFactor`, `soundEchoShouldSpeak` |

extension CognitiveSubstrate {
    // MARK: - Self-exemplar voice echo

    /// Shared felt-layer baseline; live selection uses the frozen read's dynamics.
    public static let defaultDynamics = PersonalityDynamicsConfiguration.default

    /// Match the room by raw Euclidean (warmth, valence) distance, scaled by tolerance.
    /// Age decay lets older exemplars yield to recent voice within the exemplar window.
    static func soundEchoRegisterScore(
        warmth: Double,
        valence: Double,
        targetWarmth: Double,
        targetValence: Double,
        age: TimeInterval,
        tolerance: Double = defaultDynamics.soundEchoRegisterTolerance,
        halfLife: TimeInterval = defaultDynamics.soundEchoRecencyHalfLife
    ) -> Double {
        // Smooth decay preserves closeness ordering even when no exemplar is a close match.
        let dw = warmth - targetWarmth
        let dv = valence - targetValence
        let distance = (dw * dw + dv * dv).squareRoot()
        let fit = 1 / (1 + distance / max(0.0001, tolerance))
        guard age >= 0 else { return fit }
        return fit * pow(0.5, age / halfLife)
    }

    /// Multiply register fit and age decay by (1 + λ·landing), bounded to 1 ± λ with λ in 0…0.5.
    static func soundEchoLandingFactor(landing: Double, weight: Double) -> Double {
        1 + max(0, min(0.5, weight)) * landing.clampedSigned()
    }

    // MARK: - Sound echo cadence

    /// Occasional cues carry information; an every-turn cue becomes a standing instruction.
    /// Pure, state-free cadence seeded from newest activity reproduces frozen reads.
    static func soundEchoShouldSpeak(
        seed: Double,
        dutyCycle: Int = defaultDynamics.soundEchoDutyCycle
    ) -> Bool {
        guard dutyCycle > 1 else { return true }
        // Cheap avalanche so adjacent timestamps don't land in the same bucket.
        var x = seed.bitPattern &* 0x9E37_79B9_7F4A_7C15
        x ^= x >> 29
        x = x &* 0xBF58_476D_1CE4_E5B9
        x ^= x >> 32
        return Int(truncatingIfNeeded: x % UInt64(dutyCycle)) == 0
    }

    // MARK: - Felt-mode register target

    /// Mode nudges the room's warmth target without naming a behavior or rewriting exemplars.
    /// Play and care lean warmer; repair, bracing and frustration lean toward working voice.
    /// Grief and seeking leave room warmth alone; play's lean follows persona humor.
    static func soundEchoRegisterTarget(
        roomWarmth: Double,
        mode: FeltMode?,
        dynamics: PersonalityDynamicsConfiguration
    ) -> Double {
        guard let mode else { return roomWarmth }
        // Bound the mode's influence so room warmth stays the anchor.
        let maximumNudge = 0.20
        let nudge: Double
        switch mode {
        case .play:      nudge = maximumNudge * (0.5 + dynamics.playModeWeight * 0.5)
        case .care:      nudge = maximumNudge * 0.5
        case .repair:    nudge = -maximumNudge * 0.75
        case .bracing:   nudge = -maximumNudge
        case .frustration: nudge = -maximumNudge * 0.75
        case .grief, .seeking: nudge = 0
        }
        return (roomWarmth + nudge).clamped01()
    }

    struct SoundEchoSelection: Sendable, Equatable {
        /// Exemplar only; the capsule assembler owns the rut line's single cadence gate.
        var line: String?
        /// Stable rut identity (kind + phrase), or nil when none exists.
        var wornSignature: String?
        /// The one line that NAMES the rut, spoken through the same cadence
        /// gate as the signature. Nil exactly when `wornSignature` is nil.
        var rutLine: String? = nil
        /// Her newest reply used a rutted form again.
        var rutFedAgain: Bool = false

        static let silent = SoundEchoSelection(line: nil, wornSignature: nil)
    }

    /// Select an attested voice against this frozen turn's felt register.
    func soundEchoSelection(
        from read: CognitiveFrozenRead,
        mode: FeltMode?,
        roomValence: Double,
        currentSessionId: String?,
        surface: String?,
        emitReceipts: Bool = true
    ) -> SoundEchoSelection {
        guard read.configuration.enabled else { return .silent }
        let now = read.fixedAt
        let dyn = read.personalityDynamics
        let fieldNodes = read.snapshot.nodes
        // Her OWN live conversation turns only — never User's words as her voice,
        // never tool/system summaries (the feltDaySummary injection-safety rule).
        // Her words cross from one conversation to another only on a private
        // surface (the disclosure law); a shared one hears only its own.
        let crossesSessions = surface.map(dependencies.surfaceIsPrivate) ?? false
        let herTurns = fieldNodes.filter { node in
            // Owner conversations remain her own sources. Peer replies may
            // echo only in that conversation or after an explicit Trust grant.
            let sameSession = Self.cleanedSessionId(currentSessionId).map {
                $0 == Self.cleanedSessionId(metadataString(node.metadata["sessionId"]))
            } ?? false
            let peer = Self.peerIdentity(metadata: node.metadata, dataRoot: conversationDataRoot)
            let sourceAllowed = sameSession || crossesSessions && (peer.map {
                read.trustedPeerIds.contains($0)
            } ?? true)
            return sourceAllowed && node.turnKind == .live
                && node.kind == .conversationFocus
                && node.subjectReference.type == "chat.assistant_turn"
                && now.timeIntervalSince(node.createdAt) >= 0
        }
        // A recalled turn is active now, not newly spoken now. The Sound
        // line describes recent conversation, so admission and ranking use
        // the original per-turn creation time rather than reactivation.
        let assistantTurns = herTurns.filter {
            now.timeIntervalSince($0.createdAt) <= dyn.soundEchoWindow
        }

        // Count recent replies, not days, so a rut cools when wording changes.
        // Name repeated addresses, openers or closers, never body vocabulary or recipients.
        // The source privacy gate above also bounds this cross-session awareness.
        let recentAssistantTurns = herTurns
            .sorted {
                if $0.createdAt != $1.createdAt {
                    return $0.createdAt > $1.createdAt
                }
                return $0.id.uuidString < $1.id.uuidString
            }
            .prefix(dyn.soundRutRecentTurnLimit)
        let ruts = Self.verbalRut(
            in: recentAssistantTurns.map { node in
                var full: Int?
                if case .int(let count)? = node.metadata[Self.replyCharacterCountMetadataKey] {
                    full = Int(clamping: count)
                }
                // The node keeps the first 500 characters of a reply; a long
                // reply's last ~300 ride as `replyTail`. A cut reply without a
                // tail has no trustworthy closing edge.
                var tail: String?
                if case .string(let text)? = node.metadata[Self.replyTailMetadataKey] {
                    tail = text
                }
                let complete = full.map { $0 <= node.summary.count } ?? (node.summary.count < 500)
                return (node.summary, tail, complete)
            },
            minimum: Self.verbalRutMinimumReplies
        )
        let rutSignature = Self.verbalRutSignature(ruts)
        let rutLine = verbalRutLine(ruts)
        let rutFedAgain = ruts.contains(where: \.inNewest)
        func quiet() -> SoundEchoSelection {
            SoundEchoSelection(
                line: nil,
                wornSignature: rutSignature, rutLine: rutLine, rutFedAgain: rutFedAgain)
        }
        guard !assistantTurns.isEmpty else { return quiet() }
        // The warmth floor excludes never-minted stock phrasing; valence ranks register without gating admission.
        let admitted = assistantTurns.filter { $0.emotionalWarmth >= dyn.soundEchoWarmthFloor }
        let candidates = admitted
        // Newest activity advances occasional echo cadence reproducibly for a frozen read.
        let latestActivity = fieldNodes
            .map(\.lastActivatedAt)
            .max()?
            .timeIntervalSince1970 ?? now.timeIntervalSince1970
        let shouldEcho = Self.soundEchoShouldSpeak(seed: latestActivity, dutyCycle: dyn.soundEchoDutyCycle)
        if !shouldEcho {
            if emitReceipts, !candidates.isEmpty {
                TurnTraceBus.fireFromContext(kind: "shim.fired", payload: .object(["id": .string("C02"), "site": .string("CognitiveSubstrate+CapsuleSoundEcho.swift:soundEchoSelection")]))
            }
            return quiet()
        }
        if candidates.isEmpty {
            return quiet()
        }
        // Mirror the register that fits the room now.
        let targetWarmth = Self.soundEchoRegisterTarget(
            roomWarmth: read.affect.socialWarmth,
            mode: mode,
            dynamics: dyn)
        let targetValence = roomValence.clampedSigned()
        func score(_ node: CognitiveNode) -> Double {
            let fit = Self.soundEchoRegisterScore(
                warmth: node.emotionalWarmth,
                valence: node.emotionalValence,
                targetWarmth: targetWarmth,
                targetValence: targetValence,
                age: now.timeIntervalSince(node.createdAt),
                tolerance: dyn.soundEchoRegisterTolerance,
                halfLife: dyn.soundEchoRecencyHalfLife)
            // Landing verdicts re-rank inside the register band.
            let landing = read.soundLandingScores[node.id] ?? 0
            return fit * Self.soundEchoLandingFactor(
                landing: landing,
                weight: dyn.soundEchoLandingWeight)
        }
        let ranked = candidates.map { (node: $0, score: score($0)) }.sorted { lhs, rhs in
            if lhs.score != rhs.score { return lhs.score > rhs.score }
            if lhs.node.createdAt != rhs.node.createdAt { return lhs.node.createdAt > rhs.node.createdAt }
            return lhs.node.id.uuidString < rhs.node.id.uuidString
        }.map(\.node)
        // Never quote a named rut phrase or share distinctive words across chosen fragments.
        // Prefer unworn words; allow worn words only when no fragment survives that preference.
        var dampedFragments = false
        defer {
            if emitReceipts, dampedFragments {
                TurnTraceBus.fireFromContext(kind: "shim.fired", payload: .object(["id": .string("C04"), "site": .string("CognitiveSubstrate+CapsuleSoundEcho.swift:soundEchoSelection")]))
            }
        }
        let fragged: [(fragment: String, tokens: Set<String>)] = ranked.compactMap { node in
            guard let f = soundEchoFragment(node.summary, maxCharacters: dyn.soundEchoFragmentMaxCharacters) else { return nil }
            if ruts.contains(where: { Self.containsRutPhrase(f, $0.phrase) }) {
                dampedFragments = true
                return nil
            }
            return (f, Self.distinctiveEchoTokens(f))
        }
        guard !fragged.isEmpty else {
            return quiet()
        }
        var tokenCounts: [String: Int] = [:]
        for entry in fragged {
            for t in entry.tokens { tokenCounts[t, default: 0] += 1 }
        }
        let wornFragmentTokens = Set(tokenCounts.filter { $0.value >= dyn.wornEchoThreshold }.keys)

        var fragments: [String] = []
        var seen = Set<String>()
        var usedTokens = Set<String>()
        func pick(allowWorn: Bool) {
            for entry in fragged {
                guard fragments.count < dyn.soundEchoCount else { return }
                if !allowWorn, !entry.tokens.isDisjoint(with: wornFragmentTokens) {
                    dampedFragments = true
                    continue
                }
                guard entry.tokens.isDisjoint(with: usedTokens) else {
                    dampedFragments = true
                    continue
                }
                if seen.insert(entry.fragment.lowercased()).inserted {
                    fragments.append("\u{201C}\(entry.fragment)\u{201D}")
                    usedTokens.formUnion(entry.tokens)
                }
            }
        }
        pick(allowWorn: false)
        if fragments.isEmpty { pick(allowWorn: true) }
        guard !fragments.isEmpty else {
            return quiet()
        }
        // Warmth records the room at encode; assistant completion itself is no proof the line landed.
        let line = "- Sound: lately you've sounded like \(fragments.joined(separator: " · "))"
        return SoundEchoSelection(
            line: line,
            wornSignature: rutSignature,
            rutLine: rutLine,
            rutFedAgain: rutFedAgain
        )
    }

    /// A form of address, stock opener or stock closer she keeps reaching for.
    struct VerbalRut: Sendable, Equatable {
        enum Kind: Int, Sendable {
            case address, opener, closer
            var name: String { ["address", "opener", "closer"][rawValue] }
        }
        var kind: Kind
        /// Lowercased words, as she wrote them.
        var phrase: String
        var count: Int
        var window: Int
        /// The newest reply carries this form.
        var inNewest = false
        var signature: String { "\(kind.name):\(phrase)" }
    }

    /// A form must recur in at least this many of the window's replies before
    /// it is a rut and not a coincidence.
    static let verbalRutMinimumReplies = 4

    /// Courtesy and function words that close a clause after a comma without
    /// naming anyone ("fair hit, though." · "done, thanks."). Grammar, not a
    /// list of pet names.
    static let notAnAddress: Set<String> = [
        "too", "though", "tho", "anyway", "anyways", "again", "please", "yet",
        "now", "then", "instead", "honestly", "right", "okay", "ok", "either",
        "already", "lol", "haha", "maybe", "probably", "really", "still",
        "first", "today", "tonight", "tomorrow", "yesterday", "here", "there",
        "sure", "yes", "no", "yeah", "yep", "nope", "even", "ever", "all",
        "both", "etc", "anymore", "later", "soon", "together",
        "thanks", "thank", "thx", "ty", "cheers", "sorry", "done", "good",
        "great", "cool", "nice", "fine", "deal", "noted", "exactly", "indeed",
        "agreed", "true", "correct", "definitely", "absolutely", "sadly",
        "apparently", "obviously", "otherwise", "anyhow", "besides",
    ]

    /// Every repeated form in her recent replies (newest first), counted once
    /// per reply; up to two at or above `minimum`, most frequent first (address before
    /// opener before closer on a tie). Pure and deterministic.
    static func verbalRut(
        in replies: [(text: String, tail: String?, complete: Bool)],
        minimum: Int
    ) -> [VerbalRut] {
        struct Form: Hashable { var kind: Int; var phrase: String }
        var counts: [Form: Int] = [:]
        var newestForms = Set<Form>()
        for (index, reply) in replies.enumerated() {
            let head = soundRutSentences(reply.text)
            guard let first = head.first else { continue }
            // A cut head's last sentence may itself be cut, and a tail starts
            // mid-sentence, so both broken edges are skipped.
            var sentences = reply.complete ? head : Array(head.dropLast())
            var hasEnd = reply.complete
            if !reply.complete, let tail = reply.tail {
                sentences += soundRutSentences(tail).dropFirst()
                hasEnd = true
            }
            var forms = Set<Form>()
            // A vocative can close any sentence ("That's elite trolling, boss.").
            for sentence in sentences {
                if let word = trailingVocative(sentence) {
                    forms.insert(Form(kind: VerbalRut.Kind.address.rawValue, phrase: word))
                }
            }
            // The opening clause, when it is a stock phrase (≤3 words before
            // the first break): "good morning", "honestly", "not yet".
            let clause = first.prefix { !",.!?:;—–".contains($0) }
            let openerWords = rutWords(String(clause))
            if (1...3).contains(openerWords.count) {
                forms.insert(Form(
                    kind: VerbalRut.Kind.opener.rawValue,
                    phrase: openerWords.joined(separator: " ")))
            }
            if hasEnd, sentences.count > 1, let last = sentences.last {
                let closerWords = rutWords(last)
                if (1...4).contains(closerWords.count) {
                    forms.insert(Form(
                        kind: VerbalRut.Kind.closer.rawValue,
                        phrase: closerWords.joined(separator: " ")))
                }
            }
            for form in forms { counts[form, default: 0] += 1 }
            if index == 0 { newestForms = forms }
        }
        // Up to two forms, most frequent first, so a loud rut cannot hide a
        // second real one.
        return counts
            .filter({ $0.value >= minimum })
            .sorted(by: { lhs, rhs in
                if lhs.value != rhs.value { return lhs.value > rhs.value }
                if lhs.key.kind != rhs.key.kind { return lhs.key.kind < rhs.key.kind }
                return lhs.key.phrase < rhs.key.phrase
            })
            .prefix(2)
            .compactMap { entry in
                VerbalRut.Kind(rawValue: entry.key.kind).map {
                    VerbalRut(kind: $0, phrase: entry.key.phrase,
                              count: entry.value, window: replies.count,
                              inNewest: newestForms.contains(entry.key))
                }
            }
    }

    /// Gate identity of the rut SET: sorted, so a reorder is not news but a
    /// form joining or leaving is.
    static func verbalRutSignature(_ ruts: [VerbalRut]) -> String? {
        ruts.isEmpty ? nil : ruts.map(\.signature).sorted().joined(separator: "|")
    }

    /// The one line naming the rut(s). Concrete, so it carries signal.
    func verbalRutLine(_ ruts: [VerbalRut]) -> String? {
        guard let first = ruts.first else { return nil }
        guard ruts.count > 1 else { return verbalRutLine(first) }
        func form(_ rut: VerbalRut) -> String {
            let phrase = rut.phrase.prefix(1).uppercased() + rut.phrase.dropFirst()
            switch rut.kind {
            case .address: return "\u{201C}, \(rut.phrase).\u{201D}"
            case .opener: return "\u{201C}\(phrase)\u{2026}\u{201D}"
            case .closer: return "\u{201C}\u{2026}\(rut.phrase)\u{201D}"
            }
        }
        let named = ruts.map { "\(form($0)) (\($0.count))" }.joined(separator: " and ")
        let verb = ruts.allSatisfy { $0.kind == .address } ? "have closed lines" : "keep coming back"
        return "- Sound: \(named) \(verb) in your last \(first.window) replies — let the moment pick the words"
    }

    func verbalRutLine(_ rut: VerbalRut) -> String {
        // Worded by FORM, never as a claim about who was meant.
        let tally = "\(rut.count) of your last \(rut.window) replies"
        let phrase = rut.phrase.prefix(1).uppercased() + rut.phrase.dropFirst()
        switch rut.kind {
        case .address:
            return "- Sound: \u{201C}, \(rut.phrase).\u{201D} has closed a line in \(tally) — let the moment pick the word"
        case .opener:
            return "- Sound: you've opened \(tally) with \u{201C}\(phrase)\u{201D} — let the moment pick the words"
        case .closer:
            return "- Sound: you've closed \(tally) with \u{201C}\(phrase)\u{201D} — let the moment pick the words"
        }
    }

    /// ", X" closing a sentence, with only punctuation/emoji/markup after it.
    static func trailingVocative(_ sentence: String) -> String? {
        guard let comma = sentence.lastIndex(of: ",") else { return nil }
        let after = String(sentence[sentence.index(after: comma)...])
        let words = rutWords(after)
        guard words.count == 1, let word = words.first,
              word.count >= 2, !notAnAddress.contains(word) else { return nil }
        return word
    }

    /// Lowercased letter words; apostrophes kept inside a word.
    static func rutWords(_ text: String) -> [String] {
        text.lowercased()
            .replacingOccurrences(of: "\u{2019}", with: "'")
            .split { !($0.isLetter || $0 == "'") }
            .map { $0.trimmingCharacters(in: CharacterSet(charactersIn: "'")) }
            .filter { !$0.isEmpty }
    }

    static func containsRutPhrase(_ text: String, _ phrase: String) -> Bool {
        let needle = phrase.split(separator: " ").map(String.init)
        let hay = rutWords(text)
        guard !needle.isEmpty, hay.count >= needle.count else { return false }
        return (0...(hay.count - needle.count)).contains {
            Array(hay[$0..<($0 + needle.count)]) == needle
        }
    }

    /// Name a first rut immediately; changed signatures must clear `soundRutMinimumTurnGap`.
    /// Unchanged ruts repeat after `soundRutRepeatTurnGap` accepted turns or `soundRutRepeatWindow`.
    /// Feeding a rut earns one early repeat per signature after the minimum gap.
    /// Call once per render, even without a rut, so lapsed signatures are forgotten.
    /// Mutate only the copied presentation state; accepted live completions advance its counter, even with an empty capsule.
    nonisolated func soundRutAwarenessShouldSpeak(
        signature: String?,
        at now: Date,
        dynamics dyn: PersonalityDynamicsConfiguration,
        presentationState: inout CognitiveCapsulePresentationState,
        fedAgain: Bool = false
    ) -> Bool {
        guard let signature else {
            // The rut lapsed. Forget it so its RETURN reads as a change rather
            // than as the same old nag resuming mid-cooldown.
            presentationState.soundRutSignature = nil
            presentationState.soundRutEarlyRepeatSpent = false
            return false
        }
        let previous = presentationState.soundRutSignature
        let turnsSince = presentationState.soundRutTurnsSinceSurfaced
        let elapsed = presentationState.soundRutLastSurfacedAt
            .map { now.timeIntervalSince($0) }
        let speak: Bool
        var earlyRepeat = false
        if previous == nil {
            // Never told about this rut: saying it once is the whole point.
            speak = true
        } else if previous != signature {
            speak = turnsSince >= dyn.soundRutMinimumTurnGap
        } else {
            let due = turnsSince >= dyn.soundRutRepeatTurnGap
                || (elapsed.map { $0 >= dyn.soundRutRepeatWindow } ?? false)
            earlyRepeat = !due && fedAgain
                && !presentationState.soundRutEarlyRepeatSpent
                && turnsSince >= dyn.soundRutMinimumTurnGap
            speak = due || earlyRepeat
        }
        if speak {
            presentationState.soundRutEarlyRepeatSpent =
                previous == signature && (earlyRepeat || presentationState.soundRutEarlyRepeatSpent)
            presentationState.soundRutSignature = signature
            presentationState.soundRutLastSurfacedAt = now
            presentationState.soundRutTurnsSinceSurfaced = 0
        }
        // A change that has NOT cleared the gap deliberately leaves the stored
        // signature alone, so it still reads as news on the next capsule.
        return speak
    }

    /// Sentences of one assistant turn, her own words only: quoted material and
    /// any trailing "User message:" payload removed. Awareness-only —
    /// `soundEchoFragment` remains the exemplar source.
    static func soundRutSentences(_ summary: String) -> [String] {
        var cleaned = summary
        if let quoted = cleaned.range(of: "User message:", options: [.caseInsensitive]) {
            cleaned = String(cleaned[..<quoted.lowerBound])
        }
        cleaned = cleaned
            // Exact quoted material is content being discussed or verified,
            // not the assistant's register. Counting it would call a repeated
            // checksum, title, or approved persona sentence a verbal tic.
            .replacingOccurrences(
                of: #"[“\"][^\"“”]{1,800}[\"”]"#,
                with: " ",
                options: [.regularExpression]
            )
            .replacingOccurrences(of: "\\s+", with: " ", options: [.regularExpression])
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard !cleaned.isEmpty else { return [] }

        func sentences(in text: String) -> [String] {
            var out: [String] = []
            var current = ""
            current.reserveCapacity(min(text.count, 240))
            for character in text {
                current.append(character)
                if ".!?".contains(character) {
                    let sentence = current.trimmingCharacters(in: .whitespacesAndNewlines)
                    if sentence.contains(where: \.isLetter) { out.append(sentence) }
                    current = ""
                }
            }
            let remainder = current.trimmingCharacters(in: .whitespacesAndNewlines)
            if remainder.contains(where: \.isLetter) { out.append(remainder) }
            return out
        }

        // Bounded work; the node summary is already capped upstream.
        return sentences(in: String(cleaned.prefix(1_600)))
    }

    // How many of the window's candidate fragments a distinctive word must
    // appear in before it counts as WORN (a verbal rut, not a coincidence) —
    // `wornEchoThreshold`.

    /// The words that make a fragment "sound like" something: lowercased,
    /// letters-only, ≥4 chars, minus function words. Deliberately small and
    /// generic — this is a diversity heuristic, never a censor list.
    static let echoStopwords: Set<String> = [
        "that", "this", "with", "have", "from", "your", "youre", "just",
        "what", "about", "been", "were", "they", "them", "there", "here",
        "when", "then", "than", "like", "really", "still", "into", "onto",
        "over", "some", "more", "most", "very", "much", "cant", "dont",
        "wont", "didnt", "youve", "weve", "theyre", "going", "gonna",
    ]

    static func distinctiveEchoTokens(_ text: String) -> Set<String> {
        var tokens: Set<String> = []
        var current = ""
        for ch in text.lowercased() {
            if ch.isLetter { current.append(ch) }
            else {
                if current.count >= 4, !echoStopwords.contains(current) { tokens.insert(current) }
                current = ""
            }
        }
        if current.count >= 4, !echoStopwords.contains(current) { tokens.insert(current) }
        return tokens
    }

    /// Keep her words before any "User message:" payload; reject role-framed or directive content.
    /// Return nil when no usable voice fits the quotation bounds.
    private func soundEchoFragment(_ summary: String, maxCharacters: Int) -> String? {
        var cleaned = summary
        if let quoted = cleaned.range(of: "User message:", options: [.caseInsensitive]) {
            cleaned = String(cleaned[..<quoted.lowerBound])
        }
        cleaned = cleaned
            .replacingOccurrences(of: "\\s+", with: " ", options: [.regularExpression])
            .trimmingCharacters(in: .whitespacesAndNewlines)
        cleaned = String(cleaned.prefix(400))
        guard isUsefulCapsuleSignalText(cleaned), !isOperationalSubconsciousNoise(cleaned.lowercased()) else { return nil }
        let lower = cleaned.lowercased()
        let neverHerVoice = ["system:", "assistant:", "[from:", "```", "http://", "https://"]
        guard !neverHerVoice.contains(where: { lower.contains($0) }) else { return nil }
        var sentence = ""
        for character in cleaned {
            sentence.append(character)
            if ".!?".contains(character), sentence.count >= 20 { break }
        }
        let fragment = sentence.trimmingCharacters(in: .whitespacesAndNewlines)
        guard fragment.count >= 15 else { return nil }
        // Quote whole thoughts; skip oversized fragments rather than truncate them.
        guard fragment.count <= maxCharacters else { return nil }
        return fragment
    }

}
