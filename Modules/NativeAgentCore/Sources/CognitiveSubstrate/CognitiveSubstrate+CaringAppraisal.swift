import Foundation
import TurnTrace

// Blueprint: | `CognitiveSubstrate+CaringAppraisal.swift` | `CaringAppraisalRequest`, verdict and lane contracts: semantic caring judgments, distinctness and admission/refusal interfaces |

// Caring appraisal uses the Memory route; relays require explicit attribution to the human.

// Appraisal judges caring from both sides of the exchange; Encounter owns one dose per encounter.

// MARK: - The request

/// One turn, as the appraisal sees it. Text only, plus the opaque scope the
/// dedupe needs — never an event, never metadata.
public struct CaringAppraisalRequest: Codable, Sendable, Equatable {
    /// Who said one line of the surrounding exchange.
    public enum Speaker: String, Codable, Sendable, Equatable {
        case person
        case agent
    }

    /// One line of the surrounding exchange.
    public struct ContextTurn: Codable, Sendable, Equatable {
        public let speaker: Speaker
        public let text: String

        public init(speaker: Speaker, text: String) {
            self.speaker = speaker
            self.text = text
        }
    }

    /// One encounter that recently DOSED, as the relay judgment is shown it.
    /// Kind, when, and the appraisal's own one-clause reason — never the message.
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

    /// The turn being appraised (the human's words, or the relay carrying them).
    public let userMessage: String
    /// The originating turn's clock anchors dosing and recent-encounter ages.
    public let at: Date
    /// Recent turns from both sides, oldest first, excluding the turn being judged.
    public let context: [ContextTurn]
    /// True when this arrived over the bridge — another agent in the user seat,
    /// which may or may not be relaying the human.
    public let relayed: Bool
    /// Recent dosed encounters establish relay distinctness; locally typed human turns leave this empty.
    public let recentEncounters: [RecentEncounter]
    /// The human's configured name, so the prompt can name who it is looking for.
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

/// What came back. `kind == nil` is the model saying "not a caring moment",
/// which is the answer for the overwhelming majority of turns.
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
    /// One clause saying why. Never persisted into the organism — it exists for
    /// the replay report, for a log line, and for the recent-encounter list the
    /// next relay judgment is shown.
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
    /// A turn longer than this is clipped before it goes in the prompt. A
    /// caring moment is a sentence or two; a pasted log is not one.
    public static let messageCap = 2_000
    /// How many surrounding turns, both sides, go in the prompt with the turn
    /// being judged. Six is roughly three exchanges — enough to tell care from a
    /// diagnostic question, short enough that the prompt stays one small call.
    public static let contextTurns = 6
    public static func clip(_ text: String) -> String {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.count > messageCap else { return trimmed }
        return String(trimmed.prefix(messageCap)) + "…"
    }

    // MARK: parse

    /// The wire words, and the only ones accepted. Anything else — a kind the
    /// model invented, a missing field, a reply that is not JSON — is `nil`,
    /// which the caller treats as a failed call and doses nothing.
    static let wireKinds: [String: OrganismCaringEvent.Kind] = [
        "cared_for": .caredFor,
        "caredfor": .caredFor,
        "room_made": .roomMade,
        "roommade": .roomMade,
        "need_met": .needMet,
        "needmet": .needMet,
        "repair": .repair,
    ]

    /// Parse the decoded reply. `nil` is malformed; a verdict with `kind == nil`
    /// is the successful answer "none".
    public static func parse(_ object: [String: Any]) -> CaringAppraisalVerdict? {
        guard let rawKind = object["kind"] as? String else { return nil }
        let normalized = rawKind
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased()
            .replacingOccurrences(of: "-", with: "_")
            .replacingOccurrences(of: " ", with: "_")
        let why = ((object["why"] as? String) ?? "")
            .replacingOccurrences(of: "\\s+", with: " ", options: .regularExpression)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        let verdict: CaringAppraisalVerdict
        if normalized == "none" || normalized.isEmpty {
            verdict = CaringAppraisalVerdict(kind: nil, why: why)
        } else {
            guard let kind = wireKinds[normalized] else { return nil }
            verdict = CaringAppraisalVerdict(
                kind: kind,
                why: why,
                distinctness: distinctness(in: object)
            )
        }
        if rawKind != normalized || normalized.isEmpty
            || normalized == "caredfor" || normalized == "roommade" || normalized == "needmet"
            || (verdict.kind != nil && (object["distinct"] as? String) != verdict.distinctness.rawValue) {
            TurnTraceBus.fireFromContext(kind: "shim.fired", payload: .object(["id": .string("M20"), "site": .string("CognitiveSubstrate+CaringAppraisal.swift:parse")]))
        }
        return verdict
    }

    /// The relay's distinctness answer. A field the model did not write is
    /// `.unstated` — the only case the six-hour floor still decides — and
    /// anything it wrote that is not one of the three words is `.unsure`, which
    /// never doses.
    static func distinctness(in object: [String: Any]) -> CaringAppraisalVerdict.Distinctness {
        if let number = object["distinct"] as? NSNumber, let flag = number as? Bool {
            return flag ? .distinct : .retelling
        }
        guard let raw = object["distinct"] as? String else { return .unstated }
        switch raw.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() {
        case "": return .unstated
        case "distinct", "yes", "true", "new", "fresh": return .distinct
        case "retelling", "no", "false", "retold", "repeat": return .retelling
        default: return .unsure
        }
    }
}
