import Foundation
import NativeAgentCore
import PersistenceCore
// Blueprint: | `PersonAct.swift` | `PersonAct`, `Turn.personAct`: the person's own decision of one run of one exact door call (a tap on a row the stem composed, or a card they approved) |

/// The person decided this exact call: a tap on a row the stem composed (a lever, a key lever, a stem page's row, a page owner's packet), or
/// the replay of a card they approved. Only the stem sets it (`PartFaces.act`'s run, the gate's verified replay); model output never can.
/// It answers for one run of that call: the gate spends it once for the call itself and once for the tool the call folds into, so the same
/// call made again inside that run (a part's own call) is judged as the agent's.
public final class PersonAct: @unchecked Sendable {
    public enum By: Sendable, Equatable {
        /// A tap at one of the person's doors (`mac`, `phone`, `telegram`), on a page's row. `device` is the paired phone its router verified,
        /// or Telegram's verified sender, with `chat` the Telegram chat it came from.
        case tap(door: String, device: String?, chat: String?, page: String, row: String)
        /// The person answered this call's card: approved it, or answered the card the call waited on.
        case card(id: String)
    }
    /// The forms of the call one run admits: the call as the door takes it, and the tool it folds into.
    public enum Form: String, Sendable { case call, folded }
    public let by: By
    /// The call as the door takes it: `app` with `{action, args}`, or the tool and input a card replays.
    public let tool: String
    public let input: [String: JSONValue]
    private let lock = NSLock()
    private var spent: Set<Form>

    /// `spent` names forms already admitted (a card's replay is admitted by its verified approval, so its call form starts spent).
    public init(by: By, tool: String, input: [String: JSONValue], spent: Set<Form> = []) {
        self.by = by; self.tool = tool; self.input = input; self.spent = spent
    }

    /// Whether `tool` with `input` is this exact call. An `app` call matches by its action (as the door resolves names) and its arguments.
    public func covers(tool: String, input: [String: JSONValue]) -> Bool {
        guard tool == self.tool else { return false }
        guard tool == "app" else { return input == self.input }
        return Self.action(input) == Self.action(self.input) && (input["args"] ?? .object([:])) == (self.input["args"] ?? .object([:]))
    }

    /// Admit one form of this run once; a second admission of the same form is refused.
    public func spend(_ form: Form) -> Bool {
        lock.lock(); defer { lock.unlock() }
        return spent.insert(form).inserted
    }

    /// The door the person acted at, when it was a tap.
    public var door: String? { if case .tap(let door, _, _, _, _) = by { door } else { nil } }
    /// The verified phone (or Telegram sender) that tapped, when it was one.
    public var device: String? { if case .tap(_, let device, _, _, _) = by { device } else { nil } }
    /// The verified Telegram chat it came from, when it did.
    public var chat: String? { if case .tap(_, _, let chat, _, _) = by { chat } else { nil } }

    private static func action(_ input: [String: JSONValue]) -> String? {
        input["action"]?.stringValue?.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
    }
}

private enum PersonActPart: TurnPart { static let unset: PersonAct? = nil }

extension Turn {
    /// The person's own decision of one exact call this turn makes (see `PersonAct`).
    public var personAct: PersonAct? {
        get { self[PersonActPart.self] }
        set { self[PersonActPart.self] = newValue }
    }
}
