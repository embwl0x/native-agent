import AuthoredCapabilities
import Foundation
import NativeAgentCore
import PersistenceCore
import ToolRegistry
import TrustCenter
// Blueprint: | `AppActions+CardVerbs.swift` | `AppActions.cardVerbs` (a card's answers are the declared `inbox.*` and `card.*` verbs) and `AppToolExecutor.personDecided`, the one admission of the person's own act in the inbox and card handlers |

extension AppActions {
    /// A card is its matter's Inbox row: its answers are the declared `inbox.*` and `card.*` verbs, so a card declares none of its own.
    static var cardVerbs: [AppAction] { get throws { [] } }
}

extension AppToolExecutor {
    /// Whether the person decided the `app` call that reached `tool`'s handler with `input`: the person's act names an action this tool runs,
    /// and the door made exactly `input` from that act's arguments (the door's own `__` keys aside). This recognizes taps only;
    /// approval decisions also admit an authenticated person-message through `ApprovalExecution.decisionProvenance`.
    public static func personDecided(tool: String, input: [String: JSONValue], turn: Turn) -> Bool {
        guard let act = turn.personAct, act.tool == "app", let id = act.input["action"]?.stringValue,
              let binding = AppActionBinding.declaredBinding(id), binding.tool == tool,
              case .object(let args) = act.input["args"] ?? .object([:]),
              binding.arguments(args) == input.filter({ !$0.key.hasPrefix("__") }) else { return false }
        return PermissionLaw.personDecided(tool: "app", input: ["action": .string(id), "args": .object(args)], turn: turn)
    }
}
