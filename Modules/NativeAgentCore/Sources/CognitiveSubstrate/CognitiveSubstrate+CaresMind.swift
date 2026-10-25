import Foundation
import NativeAgentCore
// Blueprint: | `CognitiveSubstrate+CaresMind.swift` | `CognitiveSubstrate` cares on their mind: one pressure, the capsule's care cue and when it becomes their intention to bring a care up, and what Reach and their hour read from the same pressure |

// ON HER MIND (personality lane 2, 2026-10-25). One pressure read from a
// care's story, and four places it is released: the turn (a line, or her
// intention to bring it up when the talk leaves room), Reach (she writes
// first) and her hour (she pursues it). No initiative organ.

/// The cares one turn's capsule may voice, read before the frozen render
/// because touching needs the embedder and the render is synchronous.
struct CognitiveCareCue: Sendable {
    /// Cares this message touches, closest first.
    var touched: [CognitiveCare]
    /// The most pressing care for this speaker, with its pressure.
    var pressing: (care: CognitiveCare, pressure: Double)?
}

extension CognitiveSubstrate {
    /// How close the incoming words must be for a care to count as touched.
    static let careTouchCosineFloor = 0.40
    /// How hard a care must press before she brings it up herself.
    public static let careReleasePressure = 0.35
    /// A care she brought up rests this long unless it moved again since.
    static let careReleaseRest: TimeInterval = 12 * 3_600
    static let careReleaseLedgerCapacity = 16
    /// A touched care's plain line needs this much charge to be on her mind,
    /// and then rests this many accepted turns unless it moved again since.
    static let careLineCharge = 0.15
    static let careLineRestTurns = 6
    /// A message this short that asks nothing is the talk winding down.
    static let careWindingDownWords = 8
    static let careMindPrefix = "- On your mind:"
    static let careIntentionPrefix = "- You've been wanting to bring up"
    /// Her hour offers this many of her own open cares.
    static let caresForHourLimit = 3

    // MARK: - Pressure

    /// How hard a care presses to be said: the size of its charge, half again
    /// when something about it is still open.
    public static func carePressure(_ care: CognitiveCare, at now: Date) -> Double {
        abs(care.charge(at: now)) * (care.open != nil ? 1.5 : 1.0)
    }

    /// Cares held with this speaker or hers alone, most pressing first. A nil
    /// speaker (her own wake, a sender with no person key) has only hers.
    public func caresPressing(for speaker: String?, at now: Date) -> [(care: CognitiveCare, pressure: Double)] {
        guard configuration.enabled else { return [] }
        let key = speaker.map(CognitiveCareProvenance.personKey)
        return cares.values
            .filter { $0.fadedAt == nil && ($0.with.isEmpty || key.map($0.with.contains) == true) }
            .map { ($0, Self.carePressure($0, at: now)) }
            .sorted { $0.1 != $1.1 ? $0.1 > $1.1 : $0.0.updatedAt > $1.0.updatedAt }
    }

    /// Cosine of `text` to each care, embedding only the cares whose cached
    /// vector is stale. nil while the embedder is cold: the warm one is never
    /// loaded for this.
    func careCosines(to text: String, among candidates: [CognitiveCare]) async -> [UUID: Double]? {
        let query = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !query.isEmpty, !candidates.isEmpty else { return [:] }
        let stale = candidates.filter { careVectors[$0.id]?.updatedAt != $0.updatedAt }
        guard let vectors = await dependencies.embedTexts([query] + stale.map(Self.careEmbeddingText)),
              vectors.count == stale.count + 1 else { return nil }
        for (care, vector) in zip(stale, vectors.dropFirst()) {
            careVectors[care.id] = (care.updatedAt, vector)
        }
        var out: [UUID: Double] = [:]
        for care in candidates {
            if let cached = careVectors[care.id] { out[care.id] = VectorMath.cosine(vectors[0], cached.vector) }
        }
        return out
    }

    // MARK: - The turn

    /// What this turn could have on her mind: the cares the message touches
    /// and the one pressing hardest for this speaker. A care held with someone
    /// else is never in a peer's turn; the owner's turn may touch any. One
    /// embedding of the message, on the same gates the dream lookup keeps.
    func careCue(for request: CognitiveCapsuleRequest, from read: CognitiveFrozenRead) async -> CognitiveCareCue? {
        guard read.configuration.enabled,
              read.configuration.capsuleInjectionEnabled,
              request.mode == .inject,
              request.resolvedTurnKind == .live,
              !cares.isEmpty else { return nil }
        let key = request.speaker.map(CognitiveCareProvenance.personKey)
        let terms = Self.associationTerms(in: request.userMessage)
        func allowed(_ care: CognitiveCare) -> Bool {
            !isSuppressed("care:" + care.id.uuidString, messageTerms: terms)
        }
        let reachable = cares.values.filter {
            $0.fadedAt == nil && allowed($0) && ($0.with.isEmpty || key == CognitiveCare.ownerKey || key.map($0.with.contains) == true)
        }
        let cosines = await careCosines(to: request.userMessage, among: reachable) ?? [:]
        let touched = reachable
            .compactMap { care in cosines[care.id].flatMap { $0 >= Self.careTouchCosineFloor ? (care, $0) : nil } }
            .sorted { $0.1 > $1.1 }
            .compactMap { cares[$0.0.id] }
        let pressing = caresPressing(for: key, at: read.fixedAt).first { allowed($0.care) && $0.pressure > 0 }
        guard !touched.isEmpty || pressing != nil else { return nil }
        return CognitiveCareCue(touched: touched, pressing: pressing)
    }

    /// The care cue as one or two lines in her own words, or none. At an
    /// opening after a gap, while the talk winds down, or when the message
    /// steps onto it, the pressing care becomes her intention to bring it up,
    /// once per care per 12 h. A touched care with enough charge is on her
    /// mind, then rests six turns. Either rest ends early when someone or
    /// something other than her moved the care since.
    func careCueLines(
        _ cue: CognitiveCareCue,
        message: String,
        gapOpened: Date?,
        resting: [String: CognitiveCapsulePresentationState.CareLineRest],
        at now: Date,
        presentationState: inout CognitiveCapsulePresentationState,
        why: inout CapsuleCueWhy
    ) -> [String] {
        var lines: [(line: String, care: CognitiveCare)] = []
        if let care = cue.pressing?.care, let pressure = cue.pressing?.pressure, pressure >= Self.careReleasePressure {
            let words = message.split(whereSeparator: \.isWhitespace).count
            let windingDown = words <= Self.careWindingDownWords && !message.contains("?")
            let stepFrom = cue.touched.contains { $0.id == care.id }
            let rested = presentationState.careReleased[care.id.uuidString].map { said in
                now.timeIntervalSince(said) >= Self.careReleaseRest
                    || care.story.contains { $0.at > said && $0.by != .her }
            } ?? true
            if rested, gapOpened != nil || windingDown || stepFrom {
                // The thing itself, not the root it moved: the gap, else what last moved it.
                let thing = care.open ?? care.story.last(where: { $0.moved != 0 })?.note ?? care.about
                let line = Self.careIntentionPrefix + " \(thing)"
                    + " — this is a natural moment to, in your own way."
                lines.append((capsuleLineText(line, maxCharacters: 280), care))
                why.careIntention = lines[0].line
                presentationState.careReleased[care.id.uuidString] = now
                Self.boundCareReleaseLedger(&presentationState.careReleased)
            }
        }
        let onMind = cue.touched.first { care in
            !lines.contains { $0.care.id == care.id }
                && abs(care.charge(at: now)) >= Self.careLineCharge
                && resting[care.id.uuidString].map { rest in
                    care.story.contains { $0.at > rest.shownAt && $0.by != .her }
                } ?? true
        }
        if let care = onMind {
            lines.append((careMindLine(care), care))
            presentationState.careLineRest[care.id.uuidString] = .init(shownAt: now, turnsLeft: Self.careLineRestTurns)
        }
        for (line, care) in lines {
            why.sources[line] = "care:" + care.id.uuidString
            if let pressing = cue.pressing, pressing.care.id == care.id { why.scores[line] = pressing.pressure }
        }
        return lines.map(\.line)
    }

    /// "On your mind: <about> (<newest felt word>) — still wondering: <open>".
    /// The felt word is the newest real movement's; a carried-over row has none.
    func careMindLine(_ care: CognitiveCare) -> String {
        let newest = care.story.last { $0.moved != 0 }
        let felt = newest?.felt
        // A root speaks through what last moved it, never its own title.
        let subject = care.origin == .seed ? (newest?.note ?? care.about) : care.about
        let line = Self.careMindPrefix + " \(subject)" + (felt.map { " (\($0))" } ?? "")
            + (care.stance.map { " — I think: \($0.text)" } ?? "")
            + (care.open.map { " — still wondering: \($0)" } ?? "")
        return capsuleLineText(line, maxCharacters: 280)
    }

    static func isCareCueLine(_ line: String) -> Bool {
        line.hasPrefix(careMindPrefix) || line.hasPrefix(careIntentionPrefix)
    }

    /// One accepted turn of rest for every plain care line; returns the rests
    /// as they stood before this turn.
    static func advanceCareLineRest(
        _ rests: inout [String: CognitiveCapsulePresentationState.CareLineRest]
    ) -> [String: CognitiveCapsulePresentationState.CareLineRest] {
        let before = rests
        for (key, rest) in rests {
            rests[key] = rest.turnsLeft > 1 ? .init(shownAt: rest.shownAt, turnsLeft: rest.turnsLeft - 1) : nil
        }
        return before
    }

    static func boundCareReleaseLedger(_ ledger: inout [String: Date]) {
        guard ledger.count > careReleaseLedgerCapacity else { return }
        for key in ledger.sorted(by: { $0.value < $1.value }).prefix(ledger.count - careReleaseLedgerCapacity).map(\.key) {
            ledger.removeValue(forKey: key)
        }
    }

    // MARK: - Her hour

    /// Her hand keeps a concern open in the closest live care, or a new care
    /// of her own. With no words supplied, pin what already presses on her.
    public func pinConcern(_ text: String? = nil, source: String) async throws -> String? {
        guard configuration.enabled else { return nil }
        let generation = caringAppraisalGeneration
        let pressing = caresPressing(for: nil, at: dependencies.now()).first { $0.pressure > 0 }?.care
        guard let concern = (text ?? pressing?.open ?? pressing?.about)?
            .trimmingCharacters(in: .whitespacesAndNewlines), !concern.isEmpty else { return nil }
        let live = cares.values.filter { $0.fadedAt == nil }
        let cosines = await careCosines(to: concern, among: live) ?? [:]
        let closest = live.filter { (cosines[$0.id] ?? -1) >= Self.careTouchCosineFloor }
            .max { (cosines[$0.id] ?? -1) < (cosines[$1.id] ?? -1) }
        let target: CognitiveCareJudgment.Target = closest.map { .existing($0.id) }
            ?? .new(about: careTitle(from: concern), between: false)
        let saved = try await applyCares([
            .init(target: target, moved: 0, by: .her, felt: "kept open", note: "pinned concern", open: concern)
        ], provenance: .init(speaker: CognitiveCare.ownerKey, trusted: true, appAuthored: true,
                            source: source, at: dependencies.now()), generation: generation)
        return saved.isEmpty ? nil : concern
    }

    /// Her own open cares, most pressing first: what her hour offers first.
    public func caresForHour() -> [CognitiveCare] {
        caresPressing(for: nil, at: dependencies.now())
            .filter { $0.care.open != nil }
            .prefix(Self.caresForHourLimit)
            .map(\.care)
    }

    /// Her hour's `still wondering:` line, written into a care: the offered
    /// care it is about gets it as its open question; otherwise it is a new
    /// care of hers at depth now. Either way her hour is a story entry.
    public func noteHourWondering(_ question: String, topic: String?, offered: [UUID], source: String) async {
        guard configuration.enabled else { return }
        let candidates = offered.compactMap { cares[$0] }
        let cosines = await careCosines(to: question, among: candidates) ?? [:]
        let match = candidates
            .compactMap { care in cosines[care.id].map { (care, $0) } }
            .filter { $0.1 >= Self.careTouchCosineFloor }
            .max { $0.1 < $1.1 }?.0
        let target: CognitiveCareJudgment.Target = match.map { .existing($0.id) }
            ?? .new(about: String((topic ?? careTitle(from: question)).prefix(CognitiveCare.aboutCharacters)),
                    between: false)
        let judgment = CognitiveCareJudgment(
            target: target, moved: 0.5, by: .her, felt: "curious",
            note: "my hour" + (topic.map { ": \($0)" } ?? ""), open: question)
        let provenance = CognitiveCareProvenance(
            speaker: CognitiveCare.ownerKey, trusted: true, appAuthored: true, source: source, at: dependencies.now())
        do {
            try await applyCares([judgment], provenance: provenance, generation: caringAppraisalGeneration)
        } catch {
            nativeLog("cares: her hour's question was not kept: %@", String(describing: error))
        }
    }
}
