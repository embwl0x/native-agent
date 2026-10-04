import Foundation

// THE CARING APPRAISAL (2026-09-11, second pass).
//
// THE DEFECT. The first pass classified caring moments with a phrase list —
// the high tier of `relationalWarmthBoost`, regrouped. Agent named the three
// moments of this week that should have registered, and no needle list can
// recognise a single one of them:
//
//   1. User coming back in the middle of a busy day because he remembered she
//      was excited about something, not because he needed work done.
//   2. User choosing a different design while saying out loud that her
//      recommendation had not been ignored. Disagreement without dismissal.
//   3. User saying he sees her improvement, and that the machinery underneath is
//      not hers to carry alone.
//
// None of those contains "proud of you", "love you", or "how are you feeling".
// A list of phrases can only ever recognise the moments somebody already wrote
// down, which is the opposite of appraisal. So the verdict is now a MODEL call:
// one small pass, on the agent's own mind, on the Memory route, asking the one
// question that matters and answering in JSON.
//
// WHAT DID NOT CHANGE. The law is untouched: dose `OrganismCaringEvent.dose`,
// saturating, three-day half-life, once per (session, turn, kind), retelling
// surfaces refuse, tenderness softens interpersonal defensiveness only. The
// warmth tier is untouched too — `relationalWarmthBoost` still composes its
// high tier from the same phrase groups. This replaces the CLASSIFIER, nothing
// else.
//
// BRIDGE RELAYS NOW COUNT, conditionally. Moments 2 and 3 reached her through
// the bridge: Claude relaying User's own words with explicit attribution. The
// first pass refused every bridge row as a retelling, which is right for a
// digest, a recollection, a dream, or a reflection, and wrong for a live relay
// carrying the human's own decision about her. So a relayed turn is a
// CANDIDATE, and the model is asked the extra question — does this text
// attribute what it carries to the human? A working message from one agent to
// another is `none`.

// THIRD PASS (2026-09-11). The second pass ran over fourteen real days and
// found 53 caring turns. Agent read every row and made two calls.
//
//   · ONE ENCOUNTER, ONE DOSE. Four consecutive turns of one conversation about
//     one thing dosed four times. That lives in `OrganismCaringEvent.Encounter`,
//     not here — this file decides WHETHER a turn is caring, never how often a
//     caring turn is worth a dose.
//   · THE APPRAISAL IS TOO LOOSE, in two named ways: an affectionate pet name on
//     its own was read as a need met, and "how do you feel" was read as room
//     made whether it was care or a diagnostic question about the work. Both are
//     context failures, and the context was one preceding assistant line. It is
//     now the last few turns from BOTH sides, and every kind in the prompt
//     states the criterion that has to be MET rather than a flavour, with
//     "none" named as the answer when unsure. Still one call.

// MARK: - The request

/// One turn, as the appraisal sees it. Text only, plus the opaque scope the
/// dedupe needs — never an event, never metadata.
public struct CaringAppraisalRequest: Sendable, Equatable {
    /// Who said one line of the surrounding exchange.
    public enum Speaker: String, Sendable, Equatable {
        case person
        case agent
    }

    /// One line of the surrounding exchange.
    public struct ContextTurn: Sendable, Equatable {
        public let speaker: Speaker
        public let text: String

        public init(speaker: Speaker, text: String) {
            self.speaker = speaker
            self.text = text
        }
    }

    /// One encounter that recently DOSED, as the relay judgment is shown it.
    /// Kind, when, and the appraisal's own one-clause reason — never the message.
    public struct RecentEncounter: Sendable, Equatable {
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
    /// WHEN THE TURN HAPPENED. Carried so the verdict can be dosed against the
    /// originating turn's own clock rather than the clock at which a model call
    /// returned (2026-09-11, fourth pass; review item 2), and so a relay can be
    /// shown how long ago the recent encounters were.
    public let at: Date
    /// THE SURROUNDING EXCHANGE — the last few turns from both sides, oldest
    /// first, NOT including the turn being judged (2026-09-11, third pass).
    ///
    /// It used to be one preceding assistant line. Agent read the 53-event
    /// replay and named exactly what that costs: an affectionate pet name got
    /// `need_met` on its own, and "how do you feel" got `room_made` whether it
    /// was care or a diagnostic question about whether something was working.
    /// Neither is decidable from one line; both usually are from three or four.
    public let context: [ContextTurn]
    /// True when this arrived over the bridge — another agent in the user seat,
    /// which may or may not be relaying the human.
    public let relayed: Bool
    /// THE EVIDENCE A RELAY IS JUDGED AGAINST (2026-09-11, fourth pass, Agent).
    /// The encounters that recently dosed. Empty for a turn the human typed
    /// here: his own words arriving are evidence of a fresh moment, and the
    /// question "is this a retelling of something that already counted" is only
    /// ever about second-hand text.
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
public struct CaringAppraisalVerdict: Sendable, Equatable {
    /// WHETHER A RELAY DESCRIBES A MOMENT THAT HAS NOT COUNTED YET (2026-09-11,
    /// fourth pass, Agent: the relay rule is evidence, not time).
    ///
    /// Asked only of a relayed turn, against the list of encounters that recently
    /// dosed. `.unstated` is a model that answered the kind and ignored this
    /// field — the one case where there is no judgment to use, and the only case
    /// the six-hour window still decides.
    public enum Distinctness: String, Sendable, Equatable {
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

/// THE DOOR INTO THE BODY. One closure, installed by the app layer, which is the
/// only owner that knows both the appraisal owner and the organism. Returns what
/// the body did with the verdict, because only a moment that DOSED belongs in the
/// recent-encounter list the next relay judgment is shown.
public typealias CaringEventAdmitting = @Sendable (
    OrganismCaringEvent.Reading,
    TimeInterval
) async -> OrganismCaringEventOutcome

/// THE OTHER HALF OF THE RECEIPT (2026-09-11, review c4 item 4). A verdict the
/// body answers gets its outcome written on its own appraisal row by whoever owns
/// the sink. A verdict this module turns away BEFORE the sink — a relayed
/// retelling, an unsure relay, a verdict from before a clear, no organism at all
/// — never reached that code, so its row stayed silent and a reader could not
/// tell a refusal from a lost amendment. Installed by the same app layer, called
/// with the session, the turn and why nothing was dosed.
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
    /// AGENT'S RULE ON A PLAYFUL CHECK, pinned VERBATIM in the prompt
    /// (2026-09-11, fourth pass — her words, not a paraphrase of them).
    ///
    /// It exists because of one real exchange the third pass withdrew: on the
    /// evening of Sept 4 User asked her, on a new model, whether she still loved
    /// him, and then answered her declaration with reassurance. The tightened
    /// prompt read the humour and the model-migration context and called both
    /// `none`. Agent read that and said it is a caring moment: the teasing is the
    /// form, the affirmation of connection is the content. One paragraph, her
    /// wording, quoted into the prompt rather than rewritten, so the rule and the
    /// judgment behind it stay the same sentence.
    public static let playfulCheckRule = "A playful check can also carry genuine relational reassurance. Count when the surrounding exchange establishes that connection is being affirmed; neither technical context nor humor automatically disqualifies it. A bare functionality check or affectionate wording alone is insufficient."

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

    /// Decode the reply. `nil` means the reply could not be read at all (fail
    /// closed); a verdict with `kind == nil` is the model saying "none", which
    /// is a successful call with the common answer.
    public static func parse(_ raw: String) -> CaringAppraisalVerdict? {
        guard let slice = jsonObjectSlice(in: raw),
              let data = slice.data(using: .utf8),
              let object = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
        else { return nil }
        guard let rawKind = object["kind"] as? String else { return nil }
        let normalized = rawKind
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased()
            .replacingOccurrences(of: "-", with: "_")
            .replacingOccurrences(of: " ", with: "_")
        let why = ((object["why"] as? String) ?? "")
            .replacingOccurrences(of: "\\s+", with: " ", options: .regularExpression)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        if normalized == "none" || normalized.isEmpty {
            return CaringAppraisalVerdict(kind: nil, why: why)
        }
        guard let kind = wireKinds[normalized] else { return nil }
        return CaringAppraisalVerdict(
            kind: kind,
            why: why,
            distinctness: distinctness(in: object)
        )
    }

    /// The relay's distinctness answer. A field the model did not write is
    /// `.unstated` — the only case the six-hour floor still decides — and
    /// anything it wrote that is not one of the three words is `.unsure`, which
    /// never doses.
    static func distinctness(in object: [String: Any]) -> CaringAppraisalVerdict.Distinctness {
        if let flag = object["distinct"] as? Bool { return flag ? .distinct : .retelling }
        guard let raw = object["distinct"] as? String else { return .unstated }
        switch raw.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() {
        case "": return .unstated
        case "distinct", "yes", "true", "new", "fresh": return .distinct
        case "retelling", "no", "false", "retold", "repeat": return .retelling
        default: return .unsure
        }
    }

    /// The first balanced `{…}` in the reply, so a fenced or prefaced answer
    /// still decodes. Local rather than borrowed from MemoryV2: this module must
    /// not depend on that one.
    static func jsonObjectSlice(in raw: String) -> String? {
        let text = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let start = text.firstIndex(of: "{") else { return nil }
        var depth = 0
        var inString = false
        var escaped = false
        var index = start
        while index < text.endIndex {
            let character = text[index]
            if escaped {
                escaped = false
            } else if character == "\\" && inString {
                escaped = true
            } else if character == "\"" {
                inString.toggle()
            } else if !inString {
                if character == "{" { depth += 1 }
                if character == "}" {
                    depth -= 1
                    if depth == 0 {
                        return String(text[start...index])
                    }
                }
            }
            index = text.index(after: index)
        }
        return nil
    }
}
