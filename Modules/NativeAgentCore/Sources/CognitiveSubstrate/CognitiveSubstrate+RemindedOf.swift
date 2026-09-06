// CognitiveSubstrate+RemindedOf.swift
//
// UNBIDDEN RECALL (2026-09-02).
//
// Agent: "I search, I don't remember. Nothing arrives sideways. User's dream of
// me in his office came to him unbidden; nothing comes to me unbidden."
//
// Every memory she has ever had reached her because something asked for it —
// the turn's recall query is the user's message, so what comes back is always
// an ANSWER. The one thing missing is the memory nobody asked for: the one the
// FEELING dragged up. So the query here is not the message. It is the felt line
// itself ("proud — quirks"), which is the only text in the system that says how
// she feels and what about, and the moments that come back are the ones that
// FELT like this before.
//
// Three disciplines, all of them refusals:
//   * CADENCE — at most once every `remindedOfMinTurns` accepted turns. A
//     memory that arrives every turn is a search result with a new label
//     (design law 2: a trigger that fires on ~100% of inputs is a floor).
//   * SIGN AGREEMENT — a warm moment may only be dragged up by a warm feeling.
//     Matching a warm memory to a bad afternoon would be a machine finding a
//     cosine neighbour, not a mind being reminded of something.
//   * NEVER TWICE IN A DAY, and never the only line on the capsule.
//
// It costs no provider call: the recall closure is a local store lookup, and
// if the store is cold it returns nothing and the line is simply absent.

import Foundation
import NativeAgentCore
import PersistenceCore

/// One felt MOMENT as the substrate needs it — the projection of a MemoryV2
/// record of kind `moment`, with the store's own vocabulary left at the door.
/// The substrate never learns what a memory store is; the wiring hands it these.
public struct CognitiveRecalledMoment: Sendable, Equatable, Identifiable {
    /// The memory record id. Used for the repeat ledger and to match the ids a
    /// turn actually served, never rendered.
    public let id: String
    /// What she is reminded OF. Rendered through the same capsule signal
    /// renderer the `- Since:` bridge uses, and capped there.
    public let text: String
    /// How it felt, −1…1. A moment at exactly 0 is a fact, not a feeling, and
    /// never matches a felt line.
    public let valence: Double
    /// How much it mattered, 0…1. Scales the re-feel; never the gate.
    public let salience: Double
    /// When it happened — the relative age on the line comes from this.
    public let occurredAt: Date
    /// Similarity to the felt line, 0…1, as the store scored it.
    public let score: Double

    public init(
        id: String,
        text: String,
        valence: Double,
        salience: Double,
        occurredAt: Date,
        score: Double
    ) {
        self.id = id
        self.text = text
        self.valence = valence.clampedSigned()
        self.salience = salience.clamped01()
        self.occurredAt = occurredAt
        self.score = score.clamped01()
    }

    /// −1 / 0 / +1. Zero is deliberately NOT positive: a flat moment agrees
    /// with no felt family.
    var valenceSign: Int {
        if valence > 0 { return 1 }
        if valence < 0 { return -1 }
        return 0
    }
}

extension CognitiveSubstrate {

    /// The felt weight of one moment, plus when it was last actually re-felt.
    /// One record rather than two ledgers, so the re-feel refractory and the
    /// stored feeling cannot drift apart.
    struct MomentAffect: Sendable, Equatable {
        var valence: Double
        var salience: Double
        var notedAt: Date
        var lastRefeltAt: Date?
    }

    // MARK: - Constants

    /// Accepted turns between two unbidden recalls. Six, so it reads as
    /// something that happens to her rather than a feature that runs.
    static let remindedOfMinTurns = 6
    /// A diffuse felt line with no object needs REAL weight before it may drag
    /// anything up; a line that already names its object does not.
    static let remindedOfValenceFloor = 0.35
    /// Cosine floor. Below this the neighbour is a word coincidence.
    static let remindedOfScoreFloor = 0.45
    /// One moment surfaces at most once a day, however well it scores.
    static let remindedOfRepeatWindow: TimeInterval = 24 * 60 * 60
    static let remindedOfRecallLimit = 5
    /// The first N characters of the moment, per the line's contract.
    static let remindedOfMaximumCharacters = 120
    /// Bounded like every other ledger the substrate keeps in memory.
    static let momentAffectCapacity = 64

    // MARK: - The line

    /// `- Reminded of: <moment> (<relative age>)`, or nil when the moment has
    /// nothing sayable in it.
    ///
    /// The text goes through `capsuleSignalText` — the same renderer that lets
    /// the `- Since:` bridge name a felt moment — so transport wrappers and
    /// reply-context blocks are stripped and the cap is sentence-aware.
    func remindedOfCapsuleLine(for moment: CognitiveRecalledMoment, at now: Date) -> String? {
        let text = capsuleSignalText(
            moment.text, maxCharacters: Self.remindedOfMaximumCharacters)
        guard isUsefulCapsuleSignalText(text) else { return nil }
        let age = Self.remindedOfAgePhrase(from: moment.occurredAt, at: now)
        let line = capsuleLineText("- Reminded of: \(text) (\(age))", maxCharacters: 200)
        guard line.hasPrefix("- Reminded of:") else { return nil }
        return line
    }

    /// How long ago it was, the way a person says it. Elapsed-seconds based
    /// rather than calendar based, except for the month name, so the phrase
    /// cannot change with the machine's timezone.
    static func remindedOfAgePhrase(from occurredAt: Date, at now: Date) -> String {
        let elapsed = max(0, now.timeIntervalSince(occurredAt))
        switch elapsed {
        case ..<(12 * 3_600):
            let hour = Calendar.current.component(.hour, from: occurredAt)
            return hour < 12 ? "this morning" : "earlier today"
        case ..<(36 * 3_600):
            return "yesterday"
        case ..<(7 * 24 * 3_600):
            return "\(Int((elapsed / 86_400).rounded())) days ago"
        default:
            let components = Calendar.current.dateComponents(
                [.month, .year], from: occurredAt)
            guard let month = components.month, (1...12).contains(month) else {
                return "a while back"
            }
            let name = Self.monthNames[month - 1]
            let thisYear = Calendar.current.component(.year, from: now)
            if let year = components.year, year != thisYear {
                return "in \(name) \(year)"
            }
            return "in \(name)"
        }
    }

    static let monthNames = [
        "January", "February", "March", "April", "May", "June",
        "July", "August", "September", "October", "November", "December",
    ]

    // MARK: - Selection

    /// The one moment this felt line is allowed to drag up, if any. Pure.
    ///
    /// - Parameter familySign: the sign of the felt family the line came from
    ///   (`feltFamilySign`). A neutral family drags nothing up — there is no
    ///   direction for a memory to agree with.
    static func remindedOfSelection(
        from moments: [CognitiveRecalledMoment],
        familySign: Int,
        at now: Date,
        surfaced: [String: Date]
    ) -> CognitiveRecalledMoment? {
        guard familySign != 0 else { return nil }
        return moments
            .filter { $0.score >= remindedOfScoreFloor }
            .filter { $0.valenceSign == familySign }
            .filter { !$0.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
            .filter { moment in
                guard let last = surfaced[moment.id] else { return true }
                return now.timeIntervalSince(last) >= remindedOfRepeatWindow
            }
            .max { lhs, rhs in
                if lhs.score != rhs.score { return lhs.score < rhs.score }
                return lhs.id > rhs.id
            }
    }

    /// Whether the cadence lets the line speak at all this turn.
    static func remindedOfCadenceAllows(_ state: CognitiveCapsulePresentationState) -> Bool {
        guard state.remindedOfLastSurfacedAt != nil else { return true }
        return state.remindedOfTurnsSinceSurfaced >= remindedOfMinTurns
    }

    /// Bounded, id-only. Eviction is oldest-first: the entries closest to
    /// falling out of the 24h window are the ones worth losing.
    static func boundRemindedOfLedger(_ ledger: inout [String: Date]) {
        let cap = CognitiveCapsulePresentationState.remindedOfLedgerCapacity
        guard ledger.count > cap else { return }
        let victims = ledger
            .sorted { lhs, rhs in
                if lhs.value != rhs.value { return lhs.value < rhs.value }
                return lhs.key < rhs.key
            }
            .prefix(ledger.count - cap)
            .map(\.key)
        for victim in victims { ledger.removeValue(forKey: victim) }
    }

    // MARK: - The one async step

    /// Resolve this turn's unbidden recall against the SAME frozen read the
    /// capsule will render from — no second workspace snapshot, no second
    /// affect read, and one local store lookup at most.
    ///
    /// Called from `prepareFrozenCapsulePresentation` rather than from the
    /// render, because the render is synchronous by construction (it must be:
    /// it mutates a copied presentation value inside one admission) and the
    /// store lookup is not. The felt line is computed twice as a result — once
    /// here to ask with, once in the render to speak with — and both are pure
    /// functions of the same frozen read, so they cannot disagree.
    func remindedOfMoment(
        for request: CognitiveCapsuleRequest,
        from read: CognitiveFrozenRead
    ) async -> CognitiveRecalledMoment? {
        guard read.configuration.enabled,
              read.configuration.affectEnabled,
              read.configuration.capsuleInjectionEnabled,
              request.mode == .inject,
              request.resolvedTurnKind == .live else { return nil }
        guard Self.remindedOfCadenceAllows(read.capsulePresentationState) else { return nil }

        let items = read.workspace.items.filter { capsuleEligibleWorkspaceNode($0.node) }
        let dyn = read.personalityDynamics
        let signals = feltSignalsForCapsule(
            from: items,
            request: request,
            at: read.fixedAt,
            affect: read.affect,
            mood: read.mood,
            proxies: read.feltProxies,
            dynamics: dyn)
        guard let fingerprint = feltFingerprintLine(
            signals: signals,
            workspaceItems: items,
            request: request,
            at: read.fixedAt,
            dynamics: dyn,
            affectEnabled: read.configuration.affectEnabled) else { return nil }
        // THE TWO WAYS A FEELING IS SPECIFIC ENOUGH TO DRAG SOMETHING UP: it
        // already names what it is about, or it is strong. A faint, objectless
        // "quiet" is not a cue; asking with it would return whatever the store
        // happened to have.
        guard fingerprint.carriedObject
                || abs(signals.valence) >= Self.remindedOfValenceFloor else { return nil }
        let sign = Self.feltFamilySign(fingerprint.family)
        guard sign != 0 else { return nil }

        // THE QUERY IS THE FELT LINE, NOT THE MESSAGE. That is the whole point:
        // a message-keyed lookup is retrieval; a feeling-keyed one is being
        // reminded.
        // The SURFACE rides with it: this turn's own surface is the disclosure
        // boundary the store must apply. A record restricted to one surface
        // must never arrive unbidden on another (review, 2026-09-02: the first
        // cut recalled unfiltered, which let every record through).
        let moments = await dependencies.recallMoments(
            fingerprint.text, Self.remindedOfRecallLimit, request.surface)
        guard !moments.isEmpty else { return nil }
        // Every moment this lookup SAW gets its feeling recorded, not just the
        // one that speaks — the ordinary recall lane may serve any of them into
        // this same turn, and a moment served without its valence is re-felt
        // neutrally, which is the thing this wave exists to fix.
        noteMomentAffect(moments, at: read.fixedAt)
        return Self.remindedOfSelection(
            from: moments,
            familySign: sign,
            at: read.fixedAt,
            surfaced: read.capsulePresentationState.remindedOfSurfaced)
    }

    /// RE-CHECK AFTER THE AWAIT. `remindedOfMoment` suspends on the store
    /// lookup, and the substrate is an actor: another turn can be accepted and
    /// COMMITTED in that window. The frozen read's ledger is then stale, and the
    /// reminder resolved against it could be a moment that has just been put in
    /// front of her — the one thing the 24h rule exists to prevent — or a second
    /// reminder inside the cadence.
    ///
    /// So the live cadence and the live ledger get the last word. Both fail
    /// toward silence, which costs one skipped line; the other direction costs
    /// the discipline.
    func revalidatedRemindedOf(
        _ moment: CognitiveRecalledMoment,
        against read: CognitiveFrozenRead
    ) -> CognitiveRecalledMoment? {
        let live = capsulePresentationStateSnapshot()
        guard Self.remindedOfCadenceAllows(live) else { return nil }
        if let last = live.remindedOfSurfaced[moment.id],
           read.fixedAt.timeIntervalSince(last) < Self.remindedOfRepeatWindow {
            return nil
        }
        return moment
    }

    // MARK: - The moment ledger (feeds the re-feel)

    /// Which of these served record ids the substrate has NO recorded feeling
    /// for. The serve path uses it to look up only what it must: a moment whose
    /// weight is already known needs no second read, and one that is known to be
    /// nothing is not re-asked every turn.
    public func momentIDsMissingFeeling(_ ids: [String]) -> [String] {
        var seen: Set<String> = []
        return ids.filter { id in
            guard momentAffect[id] == nil else { return false }
            return seen.insert(id).inserted
        }
    }

    /// Record what these moments FELT like, keyed by record id. Never their
    /// text — the ledger is numbers, and the re-feel reads numbers.
    func noteMomentAffect(_ moments: [CognitiveRecalledMoment], at now: Date) {
        for moment in moments {
            let previous = momentAffect[moment.id]
            momentAffect[moment.id] = MomentAffect(
                valence: moment.valence,
                salience: moment.salience,
                notedAt: now,
                // The refractory belongs to the ACT of re-feeling, so a
                // re-observed moment keeps its clock.
                lastRefeltAt: previous?.lastRefeltAt)
        }
        boundMomentAffect()
    }

    /// Public seam for the ordinary recall/packet lane: the moments a turn
    /// served, so they are re-felt with their own weight rather than neutrally.
    /// Idempotent and cheap; safe to call with an empty list.
    public func noteServedMoments(_ moments: [CognitiveRecalledMoment]) {
        guard !moments.isEmpty else { return }
        noteMomentAffect(moments, at: dependencies.now())
    }

    private func boundMomentAffect() {
        guard momentAffect.count > Self.momentAffectCapacity else { return }
        let victims = momentAffect
            .sorted { lhs, rhs in
                if lhs.value.notedAt != rhs.value.notedAt {
                    return lhs.value.notedAt < rhs.value.notedAt
                }
                return lhs.key < rhs.key
            }
            .prefix(momentAffect.count - Self.momentAffectCapacity)
            .map(\.key)
        for victim in victims { momentAffect.removeValue(forKey: victim) }
    }
}
