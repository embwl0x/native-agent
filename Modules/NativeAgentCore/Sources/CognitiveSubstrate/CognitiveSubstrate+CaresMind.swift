import Foundation
import NativeAgentCore
// Blueprint: | `CognitiveSubstrate+CaresMind.swift` | `CognitiveSubstrate` cares on their mind: one pressure, the capsule's care cue, intentions, watch touches and rest, Reach and their hour |

// One pressure from a care's story feeds turn cues, intentions, Reach and her hour.

/// The cares one turn's capsule may voice, read before the frozen render
/// because touching needs the embedder and the render is synchronous.
struct CognitiveCareCue: Sendable {
    /// Cares this message touches, closest first.
    var touched: [CognitiveCare]
    /// The most pressing care for this speaker, with its pressure.
    var pressing: (care: CognitiveCare, pressure: Double)?
}

/// What a watch's line touches among her cares (`careTouched`).
public enum CognitiveCareTouch: Sendable {
    case touches(CognitiveCare, resting: Bool)
    case untouched
    /// Nothing could judge it, so nothing says it does not matter.
    case unweighed
}

extension CognitiveSubstrate {
    /// How hard a care must press before she brings it up herself.
    public static let careReleasePressure = 0.35
    /// A care she brought up rests this long unless it moved again since.
    static let careReleaseRest: TimeInterval = 12 * 3_600
    static let dateLedgerCapacity = 16
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
        return Self.caresPressing(among: Array(cares.values), for: speaker, at: now)
    }

    private static func caresPressing(among candidates: [CognitiveCare], for speaker: String?, at now: Date)
        -> [(care: CognitiveCare, pressure: Double)] {
        let key = speaker.map(CognitiveCareProvenance.personKey)
        return candidates
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
        // Score against these candidates even if another lookup changes the
        // resident cache while embedding suspends.
        var selected: [UUID: [Float]] = [:]
        var stale: [CognitiveCare] = []
        let epoch = mindEpoch
        for care in candidates {
            if let cached = careVectors[care.id], cached.text == Self.careEmbeddingText(care) {
                selected[care.id] = cached.vector
            } else { stale.append(care) }
        }
        guard let vectors = await dependencies.embedTexts([query] + stale.map(Self.careEmbeddingText)),
              vectors.count == stale.count + 1 else { return nil }
        for (care, vector) in zip(stale, vectors.dropFirst()) {
            selected[care.id] = vector
            if !forgettingInFlight, mindEpoch == epoch {
                careVectors[care.id] = (Self.careEmbeddingText(care), vector)
            }
        }
        var out: [UUID: Double] = [:]
        for care in candidates {
            if let vector = selected[care.id] { out[care.id] = VectorMath.cosine(vectors[0], vector) }
        }
        return out
    }

    // MARK: - The turn

    /// What this turn could have on her mind: the cares the message touches
    /// and the one pressing hardest for this speaker. A care held with someone
    /// else is never in a peer's turn; the owner's turn may touch any. One
    /// embedding of the message, on the same gates the dream lookup keeps.
    func careCue(for request: CognitiveCapsuleRequest, from read: CognitiveFrozenRead,
                 among reachable: [CognitiveCare]) async -> CognitiveCareCue? {
        guard read.configuration.enabled,
              read.configuration.capsuleInjectionEnabled,
              request.mode == .inject,
              request.resolvedTurnKind == .live,
              !reachable.isEmpty else { return nil }
        let touched = await caresTouched(by: request.userMessage, among: reachable) ?? []
        let pressing = Self.caresPressing(among: reachable, for: request.speaker.map(CognitiveCareProvenance.personKey), at: read.fixedAt)
            .first { $0.pressure > 0 }
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
            let rested = Self.careRested(care, since: presentationState.careReleased[care.id.uuidString], at: now)
            if rested, gapOpened != nil || windingDown || stepFrom {
                // The thing itself, not the root it moved: the gap, else what last moved it.
                let thing = care.open ?? care.story.last(where: { $0.moved != 0 })?.note ?? care.about
                let line = Self.careIntentionPrefix + " \(thing)"
                    + " — this is a natural moment to, in your own way."
                lines.append((capsuleLineText(line, maxCharacters: 280), care))
                why.careIntention = lines[0].line
                presentationState.careReleased[care.id.uuidString] = now
                Self.boundDateLedger(&presentationState.careReleased)
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

    /// Brought up at `said`, a care rests 12 h, or until someone or something
    /// other than her moved it since.
    static func careRested(_ care: CognitiveCare, since said: Date?, at now: Date) -> Bool {
        guard let said else { return true }
        return now.timeIntervalSince(said) >= careReleaseRest || care.story.contains { $0.at > said && $0.by != .her }
    }

    /// The cares `text` touches, closest first (`caresStandingOut`), on the
    /// warm vector cache. nil while the embedder is cold.
    func caresTouched(by text: String, among candidates: [CognitiveCare]) async -> [CognitiveCare]? {
        guard let cosines = await careCosines(to: text, among: candidates) else { return nil }
        return Self.caresStandingOut(cosines, among: candidates).map(\.care)
    }

    /// The cares a text touches, closest first: each one's cosine stands out
    /// from the text's cosines to the other candidates past chance for an
    /// attention decision (`VectorMath.chanceBar(.attention)`: 1 + √(2 ln n)
    /// deviations among n candidates). Compressed-high cosines move the mean,
    /// not the standing against the others.
    /// `eligible` limits which may be the one touched; every candidate counts
    /// among the others.
    static func caresStandingOut(_ cosines: [UUID: Double], among candidates: [CognitiveCare],
                                 eligible: (CognitiveCare) -> Bool = { _ in true })
        -> [(care: CognitiveCare, cosine: Double)] {
        let values = candidates.compactMap { care in cosines[care.id].map { (care: care, cosine: $0) } }
        let bar = VectorMath.chanceBar(.attention, among: values.count)
        return zip(values, VectorMath.standout(values.map(\.cosine)))
            .compactMap { value, standing -> (care: CognitiveCare, cosine: Double)? in
                guard eligible(value.care), let standing, standing >= bar else { return nil }
                return value
            }
            .sorted { $0.cosine > $1.cosine }
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
        for (key, rest) in before {
            rests[key] = rest.turnsLeft > 1 ? .init(shownAt: rest.shownAt, turnsLeft: rest.turnsLeft - 1) : nil
        }
        return before
    }

    static func boundDateLedger(_ ledger: inout [String: Date]) {
        guard ledger.count > dateLedgerCapacity else { return }
        for key in ledger.sorted(by: { $0.value < $1.value }).prefix(ledger.count - dateLedgerCapacity).map(\.key) {
            ledger.removeValue(forKey: key)
        }
    }

    // MARK: - What crosses into her mind

    /// What a watch's line (a part's arrival, a sense's news) touches among her
    /// live cares that can change, never a life root (origin `.seed`: almost
    /// any line resembles one), by the care cue's own law: the closest care
    /// that stands out for the line (`caresStandingOut`; the life roots count
    /// among the others) with the plain line's charge. `resting` while this watch
    /// already woke her about it and the care has not rested since, as her
    /// intention rests. `unweighed` with no judge: the inner life off, no live
    /// cares, or the embedder cold.
    public func careTouched(by line: String, watch: String) async -> CognitiveCareTouch {
        let live = cares.values.filter { $0.fadedAt == nil }
        guard configuration.enabled, !live.isEmpty else { return .unweighed }
        let now = dependencies.now()
        let terms = Self.associationTerms(in: line)
        let weighed = live.filter { !isSuppressed("care:" + $0.id.uuidString, messageTerms: terms) }
        guard let cosines = await careCosines(to: line, among: weighed) else { return .unweighed }
        // The care cue's law, past chance: two deviations was what the best of
        // 23 cares reaches by chance alone, so "Battery is at 40 percent" woke
        // her about a teammate care (10-26).
        let touched = Self.caresStandingOut(cosines, among: weighed) { $0.origin != .seed }.map(\.care)
        guard let care = touched.first(where: { abs($0.charge(at: now)) >= Self.careLineCharge }) else { return .untouched }
        return .touches(care, resting: !Self.careRested(care, since: careWatchWoke[watch + "|" + care.id.uuidString], at: now))
    }

    /// This watch woke her about this care; kept in the capsule cadence ledger.
    public func watchWoke(_ watch: String, about care: CognitiveCare) async {
        careWatchWoke[watch + "|" + care.id.uuidString] = dependencies.now()
        Self.boundDateLedger(&careWatchWoke)
        capsulePresentationDirty = true
        await flushCapsulePresentationIfNeeded(at: dependencies.now())
    }

    // MARK: - Her hour

    /// Her hand keeps a concern open in the care she names, in its own words
    /// (its `about`, as her mind shows it), or else in a care of its own. Which
    /// care it belongs to is hers to say, never a cosine's. With no words
    /// supplied, pin what already presses on her, in that care. A question
    /// needs a care that can hold it, never a life root.
    public func pinConcern(_ text: String? = nil, in named: String? = nil, source: String) async throws -> String? {
        guard configuration.enabled else { return nil }
        let generation = caringAppraisalGeneration
        let pressing = caresPressing(for: nil, at: dependencies.now())
            .first { $0.pressure > 0 && $0.care.origin != .seed }?.care
        guard let concern = (text ?? pressing?.open ?? pressing?.about)?
            .trimmingCharacters(in: .whitespacesAndNewlines), !concern.isEmpty else { return nil }
        let trimmed = named?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        let words: String? = trimmed.isEmpty ? nil : trimmed
        let holder: CognitiveCare?
        if let words {
            let key = Self.normalizedCareText(words)
            holder = cares.values.first { $0.origin != .seed && Self.normalizedCareText($0.about) == key }
        } else {
            holder = text == nil ? pressing : nil
        }
        let target: CognitiveCareJudgment.Target = holder.map { .existing($0.id) }
            ?? .new(about: String((words ?? careTitle(from: concern)).prefix(CognitiveCare.aboutCharacters)), between: false)
        let saved = try await applyCares([
            .init(target: target, moved: 0, by: .her, felt: "kept open", note: "pinned concern", open: concern)
        ], provenance: .init(speaker: CognitiveCare.ownerKey, trusted: true, appAuthored: true,
                            source: source, at: dependencies.now()), generation: generation)
        return saved.isEmpty ? nil : concern
    }

    /// A moment from the retired moment lane, kept once as the care movement
    /// it was: true when it is in her saved cares. A story that already points
    /// at its exchange has it (saved again first, as a Reach landing is);
    /// otherwise it moves the live care it touches (`caresStandingOut`: no
    /// call wrote these, so the care law places them) or starts one of hers.
    /// Throws while the inner life is off or the embedder cannot answer, so
    /// the move waits for a launch that can place it.
    public func keepMomentInCares(_ note: String, moved: Double, felt: String,
                                  provenance: CognitiveCareProvenance) async throws -> Bool {
        guard configuration.enabled else { throw CognitiveCareNotSaved(detail: "the inner life is off") }
        await waitForMaintenanceTransition()
        if let kept = cares.values.first(where: { $0.story.contains { $0.source == provenance.source } }) {
            try await saveCares([kept.id], at: dependencies.now()).get()
            return true
        }
        let live = cares.values.filter { $0.fadedAt == nil }
        guard let cosines = await careCosines(to: note, among: live) else {
            throw CognitiveCareNotSaved(detail: "the embedder is cold, no care could be matched")
        }
        let target: CognitiveCareJudgment.Target = Self.caresStandingOut(cosines, among: live).first
            .map { .existing($0.care.id) } ?? .new(about: careTitle(from: note), between: false)
        let judgment = CognitiveCareJudgment(target: target, moved: moved,
                                             by: provenance.appAuthored ? .her : .them, felt: felt, note: note)
        let saved = try await applyCares([judgment], provenance: provenance, generation: caringAppraisalGeneration)
        return !saved.isEmpty
    }

    /// How a Reach landed, in the care that sent it: the person answered within
    /// its window (welcomed, a small move toward it) or did not (unanswered,
    /// moved 0: silence is a fact in her story, not a push; Reach already rests
    /// the subject a week). True when it is in the care's saved
    /// story: already (the offer is its source, saved again first, since a
    /// failed write leaves it resident only), now, or the care is gone and
    /// there is nothing to move.
    public func noteReachLanded(care id: UUID, answered: Bool, person: String, source: String,
                                at: Date) async throws -> Bool {
        guard configuration.enabled else { throw CognitiveCareNotSaved(detail: "the inner life is off") }
        await waitForMaintenanceTransition()
        guard let care = cares[id] else { return true }
        if care.story.contains(where: { $0.source == source }) {
            try await saveCares([id], at: dependencies.now()).get()
            return true
        }
        let lead = answered ? "\(person) answered when I reached out about " : "I reached out about "
        let tail = answered ? "" : " and heard nothing back"
        let about = capsuleLineText(care.about, maxCharacters: CognitiveCare.noteCharacters - lead.count - tail.count)
        let judgment = CognitiveCareJudgment(
            target: .existing(id), moved: answered ? 0.2 : 0, by: .them,
            felt: answered ? "welcomed" : "unanswered", note: lead + about + tail)
        let provenance = CognitiveCareProvenance(
            speaker: CognitiveCare.ownerKey, trusted: true, appAuthored: false, source: source, at: at)
        let saved = try await applyCares([judgment], provenance: provenance, generation: caringAppraisalGeneration)
        return !saved.isEmpty
    }

    /// Her own open cares, most pressing first: what her hour offers first.
    public func caresForHour() -> (cares: [CognitiveCare], generation: UInt64) {
        let offered = caresPressing(for: nil, at: dependencies.now())
            .filter { $0.care.open != nil }
            .prefix(Self.caresForHourLimit)
            .map(\.care)
        return (offered, caringAppraisalGeneration)
    }

    /// Her hour's `still wondering:` line, written into a care: the offered
    /// care she said it carries on (`continuing`, named by her hour) gets it as
    /// its open question; otherwise it is a new care of hers at depth now.
    /// Either way her hour is a story entry.
    public func noteHourWondering(_ question: String, topic: String?, continuing: UUID?, generation: UInt64, source: String) async throws -> Bool {
        guard configuration.enabled else { throw CognitiveCareNotSaved(detail: "the inner life is off") }
        await waitForMaintenanceTransition()
        // Once per source: a retry of the same hour finds its entry already in
        // a care's story saves it again before acknowledging durability.
        if let kept = cares.values.first(where: { $0.story.contains(where: { $0.source == source }) }) {
            try await saveCares([kept.id], at: dependencies.now()).get()
            return true
        }
        var match: CognitiveCare?
        if let continuing, let care = cares[continuing], care.origin != .seed { match = care }
        let target: CognitiveCareJudgment.Target = match.map { .existing($0.id) }
            ?? .new(about: String((topic ?? careTitle(from: question)).prefix(CognitiveCare.aboutCharacters)),
                    between: false)
        let judgment = CognitiveCareJudgment(
            target: target, moved: 0.5, by: .her, felt: "curious",
            note: "my hour" + (topic.map { ": \($0)" } ?? ""), open: question)
        let provenance = CognitiveCareProvenance(
            speaker: CognitiveCare.ownerKey, trusted: true, appAuthored: true, source: source, at: dependencies.now())
        let saved = try await applyCares([judgment], provenance: provenance, generation: generation)
        return !saved.isEmpty
    }
}
