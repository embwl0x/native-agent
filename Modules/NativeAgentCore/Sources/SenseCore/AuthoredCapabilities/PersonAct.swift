import Synchronization
import Foundation
import NativeAgentCore
import PersistenceCore
// Blueprint: | `PersonAct.swift` | `PersonAct`, `Turn.personAct`: the person's own decision of one run of one exact door call (a tap on a row the stem composed, a card they approved, which can carry a list of calls, or their own ask in a turn they started) |

/// The person decided this exact call: a tap on a row the stem composed (a lever, a key lever, a stem page's row, a page owner's packet),
/// the replay of a card they approved, or their own ask in a turn they started. Only the stem sets it (`PartFaces.act`'s run, the gate's
/// verified replay, the gate's reading of the person's turn); model output never can. It answers for one run of that call: the gate
/// spends it once for the call itself and once for the tool the call folds into, so the same call made again inside that run (a part's own
/// call) is judged as the agent's.
public final class PersonAct: Sendable {
    public enum By: Sendable, Equatable {
        /// A tap at one of the person's doors (`mac`, `phone`, `telegram`), on a page's row. `device` is the paired phone its router verified,
        /// or Telegram's verified sender, with `chat` the Telegram chat it came from.
        case tap(door: String, device: String?, chat: String?, page: String, row: String)
        /// The person answered this call's card: approved it, or answered the card the call waited on.
        case card(id: String)
        /// The call was made in a turn the person started at a door that is theirs; `quote` is their own message, the ask it runs on
        /// (`Turn.personsAsk`).
        case word(quote: String)
    }
    /// The forms of the call one run admits: the call as the door takes it, the tool it folds into, and each call of a list the person
    /// approved together (`app {actions:[…]}`), by its place in the list.
    public enum Form: Hashable, Sendable { case call, folded, step(Int) }
    public let by: By
    /// The call as the door takes it: `app` with `{action, args}`, or the tool and input a card replays.
    public let tool: String
    public let input: [String: JSONValue]
    private let spent: Mutex<Set<Form>>

    /// `spent` names forms already admitted (a card's replay is admitted by its verified approval, so its call form starts spent).
    public init(by: By, tool: String, input: [String: JSONValue], spent: Set<Form> = []) {
        self.by = by; self.tool = tool; self.input = input; self.spent = Mutex(spent)
    }

    /// Whether `tool` with `input` is this exact call. An `app` call matches by its action (as the door resolves names) and its arguments,
    /// and a list of calls by the list itself.
    public func covers(tool: String, input: [String: JSONValue]) -> Bool {
        guard tool == self.tool else { return false }
        guard tool == "app" else { return input == self.input }
        return Self.sameAppCall(input, self.input)
    }

    /// Two `app` calls are one call: the same action with the same arguments, or the same list of calls.
    public static func sameAppCall(_ one: [String: JSONValue], _ other: [String: JSONValue]) -> Bool {
        action(one) == action(other) && (one["args"] ?? .object([:])) == (other["args"] ?? .object([:])) && one["actions"] == other["actions"]
    }

    /// Whether this form of the run was already admitted.
    public func isSpent(_ form: Form) -> Bool {
        return spent.withLock { $0.contains(form) }
    }

    /// Admit one form of this run once; a second admission of the same form is refused.
    public func spend(_ form: Form) -> Bool {
        return spent.withLock { $0.insert(form).inserted }
    }

    /// The door the person acted at, when it was a tap.
    public var door: String? { if case .tap(let door, _, _, _, _) = by { door } else { nil } }
    /// The verified phone (or Telegram sender) that tapped, when it was one.
    public var device: String? { if case .tap(_, let device, _, _, _) = by { device } else { nil } }
    /// The verified Telegram chat it came from, when it did.
    public var chat: String? { if case .tap(_, _, let chat, _, _) = by { chat } else { nil } }
    /// The person's words that decided it, when it was their word.
    public var words: String? { if case .word(let quote) = by { quote } else { nil } }

    private static func action(_ input: [String: JSONValue]) -> String? {
        input["action"]?.stringValue?.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
    }
}

private enum PersonActPart: TurnPart { static let unset: PersonAct? = nil }

/// The card (or approval) whose answer a call runs on: its receipt names it as the cause. The replay of an answered card carries it in; the
/// gate fills it when the person approves a call while it waits, and the dispatch tracer writes it on that call's receipt.
public final class CardCause: Sendable {
    private let id: Mutex<String?>
    public init(_ id: String? = nil) { self.id = Mutex(id) }
    public var card: String? { id.withLock { $0 } }
    public func approved(by card: String) { id.withLock { $0 = card } }
}

private enum CardCausePart: TurnPart { static let unset: CardCause? = nil }

extension Turn {
    /// The person's own decision of one exact call this turn makes (see `PersonAct`).
    public var personAct: PersonAct? {
        get { self[PersonActPart.self] }
        set { self[PersonActPart.self] = newValue }
    }
    /// The card this turn's call runs on (see `CardCause`).
    public var cardCause: CardCause? {
        get { self[CardCausePart.self] }
        set { self[CardCausePart.self] = newValue }
    }
}
