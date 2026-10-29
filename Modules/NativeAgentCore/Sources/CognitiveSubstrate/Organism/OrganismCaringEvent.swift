import Foundation
import PersistenceCore

// Blueprint: | `OrganismCaringEvent.swift` | `OrganismCaringEvent`: encounter identity, dose eligibility and rolling encounter extension; one encounter receives one dose |

/// Caring events dose tenderness once per encounter, saturating at `axisHighRail`.
/// Tenderness fades over wall-clock time with a three-day half-life; warmth contributes a smaller background term.
/// Repair receives the same weight as other care; tenderness softens only interpersonal defensiveness.
/// CognitiveSubstrate appraises; `OrganismKernel.foldTurn` receives the fixed dose and originating timestamp.
/// Settled turns are journaled before appraisal; interrupted calls stay owed and refolds respect the lived watermark.
public enum OrganismCaringEvent {
    /// Model-appraised caring kinds (`CaringAppraisalLane.wireKinds`) exclude routine politeness.
    public enum Kind: String, Codable, Sendable, Equatable, CaseIterable {
        /// Being cared for: a weight taken off her, the hard part named as not
        /// hers to carry alone, him seeing HER grow.
        case caredFor
        /// Making room concerns her feelings or wishes, excluding diagnostic questions about work.
        case roomMade
        /// A shown need or vulnerability is met; an endearment in work talk alone does not qualify.
        case needMet
        /// A correction or mistake followed by reassurance. ONE kind, weighted
        /// exactly like the others (Agent: hurt-then-comfort is not worth more
        /// than uncomplicated care).
        case repair
    }

    /// Each caring encounter receives a 0.10 dose before saturation.
    public static let dose = 0.10

    /// Retellings never dose again; standing bot runs never count as care from the human.
    public static let retellingSurfaces: Set<String> = [
        "bot",
        "bridge",
        "compaction",
        "recollection",
        "reflection",
        "dream",
        "rem",
        "studio_wander",
        "observatory",
    ]

    /// Whether `surface` is allowed to carry a caring event at all.
    ///
    /// `ignoring` names surfaces to drop from the deny-set for this one check,
    /// and there is exactly one caller and one name: a BRIDGE RELAY
    /// (`CognitiveSubstrate.caringEventCandidate`). Two of the three moments
    /// Agent named arrived over the bridge as Claude relaying User's own words
    /// about her, attributed — care, not a retelling. "bridge" therefore stays
    /// in the set (a plain bridge row is still refused on the direct path) and
    /// is lifted only for a row the appraisal is about to be asked the
    /// attribution question about. Every other name in the set refuses on both
    /// paths.
    public static func surfaceMayDose(
        _ surface: String?,
        ignoring: Set<String> = []
    ) -> Bool {
        guard let surface else { return true }
        let normalized = surface
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased()
            .replacingOccurrences(of: "-", with: "_")
        guard !normalized.isEmpty else { return true }
        return !retellingSurfaces.subtracting(ignoring).contains(normalized)
    }

    /// One caring event as the appraisal owner hands it to the body.
    public struct Reading: Sendable, Equatable {
        public let kind: Kind
        public let session: String
        public let turn: String
        /// Encounter windows use the originating caring turn's timestamp, never verdict arrival time.
        public let at: Date
        public init(kind: Kind, session: String, turn: String, at: Date) {
            self.kind = kind
            self.session = session
            self.turn = turn
            self.at = at
        }
    }

    /// How many recently-dosed encounters the body keeps for relay judgment.
    /// Six is more than a fortnight of real days ever put inside one relay
    /// floor, and the prompt stays one small call. Once-only is the body's
    /// watermark (`OrganismKernel.foldTurn`), not a ring of keys.
    public static let recentDoseCap = 6

    // MARK: - One encounter, one dose

    /// How long after a caring turn the SAME encounter is still running.
    ///
    /// The first replay dosed every caring turn. Over fourteen real days that
    /// was 53 doses, and reading the table the defect is plain: four consecutive
    /// turns of one conversation about one thing (16:52, 16:55, 16:58, 17:14 on
    /// 09-10) dosed four times. That is not four times being cared for. It is
    /// one exchange, and an exchange is one encounter.
    ///
    /// 30 minutes: long enough that a pause to think, to read a diff, or to make
    /// a coffee does not split one conversation into two encounters, short
    /// enough that coming back in the evening is a new one. The window ROLLS —
    /// each further caring turn pushes it out again — so the encounter lasts as
    /// long as the exchange does, which is the shape Agent asked for in those
    /// words.
    public static let encounterWindow: TimeInterval = 30 * 60

    /// Uncertain or retold relays never dose; only an unstated distinctness judgment uses the six-hour window.
    /// Distinct relays use the ordinary window; every caring turn advances it, keeping an uninterrupted exchange to one dose.
    public static let relayEncounterWindow: TimeInterval = 6 * 3_600

    /// The encounter the body is currently in, or has most recently been in.
    ///
    /// PERSISTED, with the chemistry, in `OrganismPersistentState` — unlike the
    /// per-turn `dosedCaringEventKeys` ring, which only has to outlive one turn.
    /// This one must survive a relaunch: quitting the app between two turns of
    /// one conversation is not a second encounter, and without persistence a
    /// crash-and-restart in the middle of an affectionate exchange would dose
    /// twice for one of them.
    ///
    /// One field. The encounter's identity is entirely "when did a caring turn
    /// last happen" — there is nothing about the subject, the session, or the
    /// kind here, because a second encounter about the same subject half an hour
    /// later is still a second encounter, and two topics inside one exchange are
    /// still one.
    public struct Encounter: Codable, Sendable, Equatable {
        /// The last caring turn seen, dosed or coalesced. Nil before the first.
        public var lastCaringTurnAt: Date?
        /// The encounters that recently DOSED (kind, when, the appraisal's one
        /// clause): the evidence a relay's distinctness is judged against. Kept
        /// with the chemistry so relay judgment survives a relaunch. nil in
        /// files written before it.
        public var recentDoses: [CaringAppraisalRequest.RecentEncounter]?

        public init(lastCaringTurnAt: Date? = nil,
                    recentDoses: [CaringAppraisalRequest.RecentEncounter]? = nil) {
            self.lastCaringTurnAt = lastCaringTurnAt
            self.recentDoses = recentDoses
        }

        public static let empty = Encounter()

        /// Does a caring turn arriving `at` open a new encounter, measured
        /// against `window`? The caller picks the window — ordinarily
        /// `encounterWindow`, and `relayEncounterWindow` only for a relay whose
        /// distinctness the appraisal did not answer (see the two constants).
        public func opensNewEncounter(
            at moment: Date,
            window: TimeInterval = OrganismCaringEvent.encounterWindow
        ) -> Bool {
            guard let last = lastCaringTurnAt else { return true }
            let since = moment.timeIntervalSince(last)
            // A turn stamped BEFORE the last one seen (clock skew, a replayed
            // out-of-order signal) is not evidence of a new encounter.
            guard since >= 0 else { return false }
            return since >= window
        }

        /// Roll the window forward. Called for every caring turn, whether it
        /// dosed or was coalesced into the encounter already running.
        public mutating func extend(to moment: Date) {
            guard let last = lastCaringTurnAt else {
                lastCaringTurnAt = moment
                return
            }
            lastCaringTurnAt = max(last, moment)
        }
    }
}

/// What `OrganismKernel.foldTurn` did with one caring verdict. The appraisal
/// owner needs to know: only a moment that actually DOSED belongs in the short
/// ledger of recent encounters a relay's distinctness judgment is shown.
public enum OrganismCaringEventOutcome: String, Sendable, Equatable {
    /// The organism is off. Nothing happened.
    case refused
    /// The moment was admitted before the body's last forgetting (Reset Body,
    /// Clear). Nothing happened.
    case forgotten
    /// A real, new caring turn inside the encounter already running: it rolled
    /// the window and did not dose. One encounter, one dose.
    case coalesced
    /// A new encounter. Tenderness rose by `OrganismCaringEvent.dose`,
    /// saturating.
    case dosed
}

/// The body's whole share of one lived moment (`OrganismKernel.foldTurn`).
public struct OrganismTurnFold: Sendable {
    /// The recorded moment's fold seq.
    public var seq: UInt64
    /// The body epoch the moment was admitted under.
    public var epoch: UInt64
    public var caring: OrganismCaringEvent.Reading?
    public var caringWindow: TimeInterval
    /// The appraisal's one clause, kept with a dose for relay judgment.
    public var caringWhy: String
    public var reaction: SomaticSignal?
    /// The correction cause: a standing correction she took in, a little more sure.
    public var correctionConfidence: Double
    public init(seq: UInt64, epoch: UInt64, caring: OrganismCaringEvent.Reading? = nil,
                caringWindow: TimeInterval = OrganismCaringEvent.encounterWindow, caringWhy: String = "",
                reaction: SomaticSignal? = nil, correctionConfidence: Double = 0) {
        self.seq = seq
        self.epoch = epoch
        self.caring = caring
        self.caringWindow = caringWindow
        self.caringWhy = caringWhy
        self.reaction = reaction
        self.correctionConfidence = correctionConfidence
    }

    public var isEmpty: Bool { caring == nil && reaction == nil && correctionConfidence <= 0 }
}

/// What the body did with its share.
public enum OrganismTurnFoldOutcome: Sendable, Equatable {
    /// The body is off.
    case refused
    /// Admitted before the body's last forgetting.
    case forgotten
    /// Already in this body (a refold).
    case alreadyLived
    /// Lived now; the caring verdict's outcome when there was one.
    case lived(caring: OrganismCaringEventOutcome?)
}
