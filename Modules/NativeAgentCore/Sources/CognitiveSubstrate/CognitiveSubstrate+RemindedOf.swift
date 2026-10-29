// CognitiveSubstrate+RemindedOf.swift
// The felt line recalls a care's newest movement through cached vectors without a provider call.
// Recalls require sign agreement, accepted-turn cadence and a per-moment 24-hour repeat gap.

import Foundation
import NativeAgentCore
import PersistenceCore

// Blueprint: | `CognitiveSubstrate+RemindedOf.swift` | `CognitiveSubstrate` unbidden association: the felt line drags up a care's newest movement; cadence and selection revalidation |

/// One time a care moved her, as the unbidden line needs it.
public struct CognitiveRecalledMoment: Sendable, Equatable, Identifiable {
    /// `<care id>@<seconds>`: the repeat ledger's key, never rendered.
    public let id: String
    public let careID: UUID
    /// What she is reminded OF: her note. Rendered through the same capsule
    /// signal renderer the `- Since:` bridge uses, and capped there.
    public let text: String
    /// How far it moved her, −1…1. A movement at exactly 0 is a note, not a
    /// feeling, and never matches a felt line.
    public let valence: Double
    /// When it happened — the relative age on the line comes from this.
    public let occurredAt: Date
    /// Cosine of the felt line to the care, 0…1.
    public let score: Double

    public init(careID: UUID, text: String, valence: Double, occurredAt: Date, score: Double) {
        self.id = "\(careID.uuidString)@\(String(format: "%.0f", occurredAt.timeIntervalSince1970.rounded(.towardZero) + 0))"
        self.careID = careID
        self.text = text
        self.valence = valence.clampedSigned()
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

    // MARK: - Constants

    /// Accepted turns between two unbidden recalls. Six, so it reads as
    /// something that happens to her rather than a feature that runs.
    static let remindedOfMinTurns = 6
    /// A diffuse felt line with no object needs REAL weight before it may drag
    /// anything up; a line that already names its object does not.
    static let remindedOfValenceFloor = 0.35
    /// One moment surfaces at most once a day, however well it scores.
    static let remindedOfRepeatWindow: TimeInterval = 24 * 60 * 60
    /// The first N characters of the moment, per the line's contract.
    static let remindedOfMaximumCharacters = 120

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

    /// The one moment this felt line is allowed to drag up, if any, among the
    /// moments of the cares it touches. Pure.
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
    /// affect read, and one embedding of the felt line at most.
    ///
    /// Called from `prepareFrozenCapsulePresentation` rather than from the
    /// render, because the render is synchronous by construction (it must be:
    /// it mutates a copied presentation value inside one admission) and the
    /// embedding is not. Carry the frozen felt inputs into rendering so the
    /// lookup and capsule use the same computation.
    func remindedOfMoment(
        for request: CognitiveCapsuleRequest,
        from read: CognitiveFrozenRead,
        among reachable: [CognitiveCare],
        felt: inout (signals: FeltSignals, fingerprint: FeltLineRender?)?
    ) async -> CognitiveRecalledMoment? {
        guard read.configuration.enabled,
              read.configuration.capsuleInjectionEnabled,
              request.mode == .inject,
              request.resolvedTurnKind == .live else { return nil }
        guard Self.remindedOfCadenceAllows(read.capsulePresentationState) else { return nil }

        let items = read.workspace.items.filter { capsuleEligibleWorkspaceNode($0.node) }
        let dyn = read.personalityDynamics
        let signals = feltSignalsForCapsule(
            from: items,
            request: request,
            frozenRead: read)
        let fingerprint = feltFingerprintLine(
            signals: signals,
            workspaceItems: items,
            request: request,
            at: read.fixedAt,
            dynamics: dyn,
            affectEnabled: read.configuration.enabled)
        felt = (signals, fingerprint)
        guard let fingerprint else { return nil }
        // THE TWO WAYS A FEELING IS SPECIFIC ENOUGH TO DRAG SOMETHING UP: it
        // already names what it is about, or it is strong. A faint, objectless
        // "quiet" is not a cue; asking with it would return whatever the store
        // happened to have.
        guard fingerprint.carriedObject
                || abs(signals.valence) >= Self.remindedOfValenceFloor else { return nil }
        let sign = Self.feltFamilySign(fingerprint.family)
        guard sign != 0 else { return nil }

        // Query the felt line against the turn's reachable cares; only a care
        // that stands out for that feeling supplies a moment.
        guard let cosines = await careCosines(to: fingerprint.text, among: reachable) else { return nil }
        let moments = Self.caresStandingOut(cosines, among: reachable).compactMap { touched -> CognitiveRecalledMoment? in
            guard let newest = touched.care.story.last(where: { $0.moved != 0 && !$0.note.isEmpty }) else { return nil }
            return CognitiveRecalledMoment(careID: touched.care.id, text: newest.note, valence: newest.moved,
                                           occurredAt: newest.at, score: touched.cosine)
        }
        return Self.remindedOfSelection(
            from: moments,
            familySign: sign,
            at: read.fixedAt,
            surfaced: read.capsulePresentationState.remindedOfSurfaced)
    }

    /// RE-CHECK AFTER THE AWAIT. `remindedOfMoment` suspends on the felt
    /// line's embedding, and the substrate is an actor: another turn can be accepted and
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
        let live = capsulePresentationState
        guard Self.remindedOfCadenceAllows(live) else { return nil }
        if let last = live.remindedOfSurfaced[moment.id],
           read.fixedAt.timeIntervalSince(last) < Self.remindedOfRepeatWindow {
            return nil
        }
        return moment
    }
}
