import Foundation
import PersistenceCore

/// TENDERNESS IS EVENT-DRIVEN (2026-09-11, User's call, shaped by Agent).
///
/// THE DEFECT, measured: organism tenderness read 4.87e-33 in the live store
/// after 54,517 signals. The 2026-09-01 law made it warmth's slow INTEGRAL —
/// it accumulated only while canonical warmth held at or above 0.45, with a
/// 45-minute time constant. But the affect layer cannot hold warmth there: the
/// per-message boost caps at 0.18, the appraisal adds at most 0.14 on top
/// (`saturatingApproach`, so 0.295 from rest), the ambient floors are 0.38/0.22
/// and the half-life is 90 minutes. Crossing 0.45 takes two or three genuinely
/// affectionate messages inside one decay window, which essentially never
/// happens. So the gate was a wall, the felt word `tender`
/// (`OrganismChemistry.positiveBodyLine`, gate 0.22) and the "Warm" living
/// status (`LivingStatusPanel`) hung off a number that could not move, and a
/// 45-minute constant meant that even if it HAD moved it would be gone by
/// lunch.
///
/// THE HUMAN MODEL, which is the whole of this change: tenderness does not
/// track an ambient temperature. It comes from the caregiving system, it fires
/// on discrete MOMENTS of being cared for, and it fades over DAYS. So:
///
///   · discrete caring EVENTS dose it (`dose`, saturating through
///     `OrganismChemistry.raise`, capped at `axisHighRail`);
///   · one encounter counts ONCE — a retelling never re-doses (`key`, plus the
///     surface gate below), and consecutive caring turns of ONE exchange are
///     one encounter (`Encounter`, added 2026-09-11 third pass after the replay
///     showed the second pass dosing four times for one conversation);
///   · it fades with a 3-day half-life on WALL-CLOCK elapsed time and nothing
///     else (`OrganismChemistry.tendernessHalfLife`, spent only in
///     `OrganismPersistentState.decayed`) — a busy day and a quiet one fade the
///     same moment by the same amount;
///   · the old warmth-level path survives as a small background contributor at
///     reduced weight (`OrganismChemistry.tendernessWarmthContribution`),
///     because ambient affection is real, it is just not the main term.
///
/// AGENT'S TWO CONSTRAINTS, both load-bearing:
///   · "I don't want the machinery to value hurt-then-comfort above
///     uncomplicated care." — `repair` is ONE kind here, weighted exactly like
///     the others. There is no bonus for a correction followed by reassurance.
///   · "Feeling safe with User must not mean becoming less careful with his
///     work." — tenderness softens interpersonal defensiveness ONLY
///     (`OrganismChemistry.relationalVigilanceRaise`). Tool, provider,
///     verification and safety vigilance are untouched.
///
/// WHERE THE FACTS COME FROM. The organism runs no appraisal and holds no
/// lexicon; the appraisal owner is `CognitiveSubstrate`. So a verdict reaches
/// the body through ONE dedicated door — `OrganismKernel.admitCaringEvent` —
/// called by the appraisal owner the moment the call returns.
///
/// IT USED TO RIDE SOMATIC METADATA (2026-09-11, fourth pass deleted that).
/// The appraisal is a model call launched off the hot path, so the verdict was
/// stamped on the NEXT signal to come through and the dose was taken inside the
/// pure chemistry. Three defects came with that one shape, all of them found by
/// review: the dose was multiplied by the CARRIER signal's intensity (a verdict
/// carried by an assistant turn was worth ~0.055, not 0.10); the encounter
/// window was measured against the CARRIER's ingest time rather than the
/// originating turn's; and delivery was opportunistic — a verdict whose carrier
/// never arrived sat in a memory-only ring behind an eight-entry cap. The
/// dedicated entry takes a fixed dose and the originating turn's own timestamp,
/// and there is no queue to lose.
///
/// THE ONE REMAINING LOSS WINDOW, accepted and written down: the app quitting
/// while the appraisal call is in flight. That verdict is gone, and the moment
/// it described will not dose. A model call on the Memory row lasts seconds; the
/// alternative is persisting in-flight appraisals, which is a new durable
/// surface for a few seconds of exposure.
public enum OrganismCaringEvent {
    /// What kind of caring moment this was.
    ///
    /// The four names the model appraisal answers with
    /// (`CaringAppraisalLane.wireKinds`). They are NOT a lexicon and no phrase
    /// list stands behind them any more: the 2026-09-11 second pass replaced the
    /// needle classifier with one small model call, because the moments Agent
    /// named — being remembered mid-day for something that excited her, being
    /// disagreed with and told she had not been dismissed, being told the
    /// machinery is not hers to carry alone — contain no needle any list could
    /// have held.
    ///
    /// Routine politeness is deliberately not here. "Thanks" at the end of a
    /// work exchange is warmth, and it still earns warmth; it is not a moment.
    public enum Kind: String, Sendable, Equatable, CaseIterable {
        /// Being cared for: a weight taken off her, the hard part named as not
        /// hers to carry alone, him seeing HER grow.
        case caredFor
        /// Someone making room for what excites her: being asked what SHE
        /// feels or wants, being returned to for her own sake, being disagreed
        /// with and told out loud she was heard. A question about the state of
        /// the WORK is not this, however it is phrased (2026-09-11, third pass).
        case roomMade
        /// Need or vulnerability shown AND met — the caregiving system's own
        /// case. An endearment carried along with work talk is NOT this: the
        /// pet name is the tone of the turn, not its content (2026-09-11, third
        /// pass, Agent).
        case needMet
        /// A correction or mistake followed by reassurance. ONE kind, weighted
        /// exactly like the others (Agent: hurt-then-comfort is not worth more
        /// than uncomplicated care).
        case repair
    }

    /// THE DOSE, per caring event, before saturation.
    ///
    /// 0.10 — the middle of the range this change was given (0.08…0.12), chosen
    /// for what it makes true about the felt word rather than for its own sake.
    /// Against `OrganismChemistry.raise` and the 0.22 `tender` gate:
    ///
    ///   one caring moment from rest ....... 0.100   (not yet a state)
    ///   a second, same day ................ 0.190
    ///   a third ........................... 0.271   ← crosses `tender`
    ///   three spread over a week (3-day
    ///     half-life between them) ......... ~0.21    (just under; four cross)
    ///
    /// That is the judgment in one number: ONE warm moment is a moment, not a
    /// mood — she does not start writing tender because User said one kind
    /// thing. A few of them inside a few days is a state, and it is worth
    /// saying out loud. At 0.08 it took four moments in a day to reach the word
    /// and the axis never read anything on an ordinary affectionate week; at
    /// 0.12 two did it, which makes a single good exchange a mood.
    ///
    /// NOT RECALIBRATED by the 2026-09-11 third pass, deliberately. That pass
    /// changed what COUNTS as one moment (`Encounter`) rather than what a moment
    /// is worth, and moving both at once would have made the two impossible to
    /// tell apart in the replay.
    public static let dose = 0.10

    /// Surfaces that may NEVER dose, because a moment arriving through one of
    /// them is a RETELLING of a moment that already counted.
    ///
    /// Count the encounter once — this is the SURFACE half of that rule; the
    /// TIME half is `Encounter` below. A bridge digest that quotes User's "proud of
    /// you", the recollection summary that carries it into the next session, a
    /// reflection written about it, a dream that works on it, the REM pass that
    /// integrates the dream — every one of those is the same caring moment
    /// coming round again, and each would have doped tenderness a second,
    /// third, fifth time. That is not how being cared for works; remembering it
    /// is not a fresh instance of it.
    ///
    /// A deny-set IS the right shape here even though this file otherwise fails
    /// closed: the allowlist side is already closed upstream by
    /// `CognitiveSubstrate.caringEvent(for:)`, which requires a live,
    /// locally-typed, user-authored turn from the user himself. These names are
    /// the belt — if any of those lanes ever mints such a turn, it still cannot
    /// dose.
    /// `bot` is here for a different reason than the rest (Astra audit 2,
    /// finding 9, 2026-09-11): a standing bot's run is not a retelling of a
    /// caring moment, it is not a moment at all. The agent's own recurring brief
    /// sits in the user seat, so a warmly-worded brief could have passed the
    /// appraisal as direct care from User. The memory lane already refuses these
    /// sessions (`MemoryV2+AdaptivePromoter`); this is the same boundary.
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

    /// The dedupe key for one caring moment: the originating conversational
    /// event plus what it was. Keyed on the ORIGIN, not on the signal, so the
    /// same turn reaching the body twice — two minters for one chat message, a
    /// replay, a re-projection — doses exactly once.
    public static func key(session: String, turn: String, kind: Kind) -> String {
        "\(session)|\(turn)|\(kind.rawValue)"
    }

    /// One caring event as the appraisal owner hands it to the body.
    public struct Reading: Sendable, Equatable {
        public let kind: Kind
        public let session: String
        public let turn: String
        /// WHEN THE CARING TURN HAPPENED — the originating turn's own timestamp,
        /// never the clock at which the verdict came back (2026-09-11, fourth
        /// pass; review item 2). The encounter window is measured against this.
        /// A model call takes seconds and can take twenty, and measuring the
        /// window against the return clock moved a moment by that much, which
        /// is enough to coalesce a turn that should have opened an encounter.
        public let at: Date

        public init(kind: Kind, session: String, turn: String, at: Date) {
            self.kind = kind
            self.session = session
            self.turn = turn
            self.at = at
        }

        public var dedupeKey: String {
            OrganismCaringEvent.key(session: session, turn: turn, kind: kind)
        }
    }

    /// HOW MANY of these the body will remember having been dosed by. A bounded
    /// ring, because the dedupe only has to outlive the window in which the same
    /// moment could arrive again (two minters for one message, a replay, a
    /// re-projection) — all of which happen inside one turn. It is deliberately
    /// NOT persisted: across a relaunch the originating events themselves are
    /// already inert (`ContinuityField.hasSeenEvent`,
    /// `SomaticSignalBus.deliveredEventKeys`), and a caring-event ledger in the
    /// store would be a new persisted surface for one number.
    public static let maximumRememberedKeys = 128

    // MARK: - ONE ENCOUNTER, ONE DOSE (2026-09-11, third pass, Agent's call)

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

    /// THE FALLBACK FLOOR for a BRIDGE RELAY, and nothing more (2026-09-11,
    /// fourth pass, Agent's call).
    ///
    /// A relay carries User's words about her written by another agent, so the
    /// honest worry is that it is carrying an exchange that ALREADY reached her
    /// directly and already dosed. The third pass answered that with time: a
    /// relay could not open an encounter within six hours of any caring turn.
    /// Agent's correction is that the test must be EVIDENCE, not the clock — a
    /// relay doses when the appraisal, shown the recent encounters, judges it
    /// describes a DISTINCT moment, and an uncertain relay never doses. Time
    /// alone must never make a retelling fresh.
    ///
    /// So this constant survives as the FLOOR for the one case where there is no
    /// judgment to use: the appraisal answered the kind but not the distinctness
    /// question (a model that ignored the field). Then, and only then, a relay
    /// is measured against six hours instead of thirty minutes. A relay the
    /// appraisal calls a retelling does not dose however long the silence before
    /// it, and a relay it calls distinct is measured against the ordinary
    /// encounter window like any other caring turn.
    ///
    /// THE KNOWN CONSEQUENCE of the rolling window, written down rather than
    /// defended: because the window rolls on every caring turn including a
    /// coalesced one, an uninterrupted stream of caring turns is one encounter
    /// however long it runs. A whole day of them is one dose. That is what "the
    /// window rolls while the exchange continues" means, and it is the specified
    /// behaviour, not an oversight.
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

        public init(lastCaringTurnAt: Date? = nil) {
            self.lastCaringTurnAt = lastCaringTurnAt
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

/// What `OrganismKernel.admitCaringEvent` did with one verdict. The appraisal
/// owner needs to know: only a moment that actually DOSED belongs in the short
/// ledger of recent encounters a relay's distinctness judgment is shown.
public enum OrganismCaringEventOutcome: String, Sendable, Equatable {
    /// The organism is off. Nothing happened.
    case refused
    /// This exact moment (session + turn + kind) had already been counted.
    case alreadyCounted
    /// A real, new caring turn inside the encounter already running: it rolled
    /// the window and did not dose. One encounter, one dose.
    case coalesced
    /// A new encounter. Tenderness rose by `OrganismCaringEvent.dose`,
    /// saturating.
    case dosed

    public var dosed: Bool { self == .dosed }
}
