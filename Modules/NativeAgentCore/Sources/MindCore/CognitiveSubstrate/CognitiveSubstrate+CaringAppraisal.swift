import Foundation

// Blueprint: | `CognitiveSubstrate+CaringAppraisal.swift` | `CaringAppraisalRequest`: caring judgment and distinctness contracts |

// Caring appraisal uses the Memory route; relays require explicit attribution to the human.

// Appraisal judges caring from both sides of the exchange; Encounter owns one dose per encounter.

// MARK: - The request

/// Keep appraisal input text-only; opaque scope serves deduplication, not judgment.
public struct CaringAppraisalRequest: Codable, Sendable, Equatable {
    public enum Speaker: String, Codable, Sendable, Equatable {
        case person
        case agent
    }

    public struct ContextTurn: Codable, Sendable, Equatable {
        public let speaker: Speaker
        public let text: String

        public init(speaker: Speaker, text: String) {
            self.speaker = speaker
            self.text = text
        }
    }

    /// Recent dosed encounters show only kind, time and appraisal reason; the original message stays private.
    public struct RecentEncounter: Codable, Sendable, Equatable {
        public let kind: OrganismCaringEvent.Kind
        public let at: Date
        public let why: String

        public init(kind: OrganismCaringEvent.Kind, at: Date, why: String) {
            self.kind = kind
            self.at = at
            self.why = why
        }
    }

    public let userMessage: String
    /// The originating turn's clock anchors dosing and recent-encounter ages.
    public let at: Date
    /// Recent turns from both sides, oldest first, excluding the turn being judged.
    public let context: [ContextTurn]
    /// True when this arrived over the bridge — another agent in the user seat, which may or may not be relaying the human.
    public let relayed: Bool
    /// Recent dosed encounters establish relay distinctness; locally typed human turns leave this empty.
    public let recentEncounters: [RecentEncounter]
    /// The configured person name grounds relay attribution.
    public let personName: String?
    public let session: String
    public let turn: String

    public init(
        userMessage: String,
        at: Date = Date(),
        context: [ContextTurn] = [],
        relayed: Bool,
        recentEncounters: [RecentEncounter] = [],
        personName: String?,
        session: String,
        turn: String
    ) {
        self.userMessage = userMessage
        self.at = at
        self.context = context
        self.relayed = relayed
        self.recentEncounters = recentEncounters
        self.personName = personName?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == false
            ? personName : nil
        self.session = session
        self.turn = turn
    }
}

/// A valid nil kind means no caring moment; it is not a failed call.
public struct CaringAppraisalVerdict: Codable, Sendable, Equatable {
    /// Relays are judged against recent encounters; only `.unstated` uses the six-hour window.
    public enum Distinctness: String, Codable, Sendable, Equatable {
        /// A moment of its own: nothing in the recent encounters is this.
        case distinct
        /// A retelling of one of them. Never doses, whatever the clock says.
        case retelling
        /// The model could not tell. Never doses.
        case unsure
        /// Not asked (a direct turn) or not answered.
        case unstated
    }

    public let kind: OrganismCaringEvent.Kind?
    /// Reasons support relay judgment and observability but never persist into body chemistry.
    public let why: String
    public let distinctness: Distinctness

    public init(
        kind: OrganismCaringEvent.Kind?,
        why: String,
        distinctness: Distinctness = .unstated
    ) {
        self.kind = kind
        self.why = why
        self.distinctness = distinctness
    }

    public static let none = CaringAppraisalVerdict(kind: nil, why: "")
}


/// Records the session, turn and reason for a verdict refused before the body sink.
public typealias CaringRefusalRecording = @Sendable (
    String,
    String,
    String
) async -> Void

// MARK: - The lane

public enum CaringAppraisalLane {
    /// Bound prompt input to a caring exchange; pasted logs must not dominate appraisal.
    public static let messageCap = 2_000
    /// Six turns cover roughly three exchanges, enough to distinguish care from diagnostics in one small call.
    public static let contextTurns = 6
    public static func clip(_ text: String) -> String {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.count > messageCap else { return trimmed }
        return String(trimmed.prefix(messageCap)) + "…"
    }

    // MARK: parse

    /// Only declared wire values are valid; malformed or missing fields fail the call and dose nothing.
    static let wireKinds: [String: OrganismCaringEvent.Kind] = [
        "cared_for": .caredFor,
        "room_made": .roomMade,
        "need_met": .needMet,
        "repair": .repair,
    ]

    /// Parse the decoded reply. `nil` is malformed; a verdict with `kind == nil` is the successful answer "none".
    public static func parse(_ object: [String: Any]) -> CaringAppraisalVerdict? {
        guard let kind = object["kind"] as? String,
              let rawWhy = object["why"] as? String,
              let rawDistinctness = object["distinct"] as? String,
              let distinctness = CaringAppraisalVerdict.Distinctness(rawValue: rawDistinctness) else { return nil }
        let why = rawWhy
            .replacingOccurrences(of: #"\s+"#, with: " ", options: .regularExpression)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        if kind == "none" { return CaringAppraisalVerdict(kind: nil, why: why, distinctness: distinctness) }
        guard let caringKind = wireKinds[kind] else { return nil }
        return CaringAppraisalVerdict(kind: caringKind, why: why, distinctness: distinctness)
    }
}
