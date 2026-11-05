import Foundation
import PersistenceCore

// Blueprint: | `OrganismCaringEvent.swift` | `OrganismCaringEvent`: rolling encounters and once-per-encounter dosing |

/// Dose once per journaled encounter and save fold proof with chemistry; tenderness decays on wall time and softens only interpersonal defensiveness.
public enum OrganismCaringEvent {
    /// Model-appraised caring kinds (`CaringAppraisalLane.wireKinds`) exclude routine politeness.
    public enum Kind: String, Codable, Sendable, Equatable, CaseIterable {
        /// Care must recognize the agent or relieve a weight, not merely discuss work.
        case caredFor
        /// Making room concerns the agent's feelings or wishes, excluding diagnostic questions about work.
        case roomMade
        /// A shown need or vulnerability is met; an endearment in work talk alone does not qualify.
        case needMet
        /// Repair earns the same dose as uncomplicated care; hurt followed by comfort is not worth more.
        case repair
    }

    /// Each caring encounter receives a 0.10 dose before saturation.
    public static let dose = 0.10

    /// Retellings never dose again; standing bot runs never count as care from the human.
    public static let retellingSurfaces: Set<String> = [
        "bot",
        "bridge",
        "reflection",
        "dream",
        "rem",
        "studio_wander",
        "observatory",
    ]

    /// Only relay appraisal may exempt `bridge` from the denied surfaces; attribution must still be judged and other retelling surfaces remain refused.
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

    /// The appraisal owner supplies the body's caring evidence.
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

    /// Keep six recent doses for bounded relay judgment; the fold watermark, not this ring, enforces once-only effects.
    public static let recentDoseCap = 6

    // MARK: - One encounter, one dose

    /// A rolling thirty-minute window covers thinking pauses without splitting an exchange; every further caring turn extends the same encounter.
    public static let encounterWindow: TimeInterval = 30 * 60

    /// Uncertain or retold relays never dose; only an unstated distinctness judgment uses the six-hour window. Distinct relays use the ordinary window; every
    /// caring turn advances it, keeping an uninterrupted exchange to one dose.
    public static let relayEncounterWindow: TimeInterval = 6 * 3_600

    /// Persist the encounter with chemistry so relaunch cannot dose one exchange twice; time, not subject or session, defines its identity.
    public struct Encounter: Codable, Sendable, Equatable {
        /// The last caring turn seen, dosed or coalesced. Nil before the first.
        public var lastCaringTurnAt: Date?
        /// Persist actual dose reasons with chemistry so relay distinctness survives relaunch; missing evidence stays absent.
        public var recentDoses: [CaringAppraisalRequest.RecentEncounter]?

        public init(lastCaringTurnAt: Date? = nil,
                    recentDoses: [CaringAppraisalRequest.RecentEncounter]? = nil) {
            self.lastCaringTurnAt = lastCaringTurnAt
            self.recentDoses = recentDoses
        }

        public static let empty = Encounter()

        /// The caller selects the ordinary or unstated-relay window so the body measures the same encounter the appraisal judged.
        public func opensNewEncounter(
            at moment: Date,
            window: TimeInterval = OrganismCaringEvent.encounterWindow
        ) -> Bool {
            guard let last = lastCaringTurnAt else { return true }
            let since = moment.timeIntervalSince(last)
            // A turn stamped BEFORE the last one seen (clock skew, a replayed out-of-order signal) is not evidence of a new encounter.
            guard since >= 0 else { return false }
            return since >= window
        }

        /// Roll the window forward. Called for every caring turn, whether it dosed or was coalesced into the encounter already running.
        public mutating func extend(to moment: Date) {
            guard let last = lastCaringTurnAt else {
                lastCaringTurnAt = moment
                return
            }
            lastCaringTurnAt = max(last, moment)
        }
    }
}

/// Only a verdict that actually dosed belongs in recent encounter evidence.
public enum OrganismCaringEventOutcome: String, Sendable, Equatable {
    /// The organism is off. Nothing happened.
    case refused
    /// The moment was admitted before the body's last forgetting (Reset Body, Clear). Nothing happened.
    case forgotten
    /// A real, new caring turn inside the encounter already running: it rolled the window and did not dose. One encounter, one dose.
    case coalesced
    /// A new encounter. Tenderness rose by `OrganismCaringEvent.dose`, saturating.
    case dosed
}

public struct OrganismTurnFold: Sendable {
    /// The journal fold seq deduplicates body effects.
    public var seq: UInt64
    /// The admission epoch prevents effects after forgetting.
    public var epoch: UInt64
    public var caring: OrganismCaringEvent.Reading?
    public var caringWindow: TimeInterval
    /// Retain the appraisal reason with actual doses for later relay judgment.
    public var caringWhy: String
    public var reaction: SomaticSignal?
    /// An accepted standing correction supplies confidence evidence.
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

public enum OrganismTurnFoldOutcome: Sendable, Equatable {
    /// Disabled body has no effects.
    case refused
    /// A pre-forgetting admission cannot move the body.
    case forgotten
    /// A refold cannot move an already-lived body share.
    case alreadyLived
    /// Report the actual caring outcome of this fold.
    case lived(caring: OrganismCaringEventOutcome?)
}
