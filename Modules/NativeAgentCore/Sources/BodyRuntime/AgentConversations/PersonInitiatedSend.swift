import Synchronization
import Foundation
import PersistenceCore
// Blueprint: | `PersonInitiatedSend.swift` | `PersonInitiatedSend` class; `matches`, `claim` |

/// A composer click or Return grants exactly one matching contact-and-text send, never nested work. Swift carries this grant on `turn.personInitiatedSend`
/// through the direct composer dispatch; model input cannot forge it. It waives only send approval: program execution and Trust refusals still refuse plainly.
public final class PersonInitiatedSend: Sendable {

    public let agent: String
    public let text: String
    private let spent = Atomic(false)

    public init(agent: String, text: String) {
        self.agent = agent
        self.text = text
    }

    package func matches(_ input: [String: JSONValue]) -> Bool {
        input["agent"] == .string(agent) && input["text"] == .string(text)
    }

    /// Good for one gate check of this exact send.
    package func claim(tool: String, input: [String: JSONValue], surface: String) -> Bool {
        guard tool == "agent_message", surface == "chat", matches(input) else { return false }
        return !spent.exchange(true, ordering: .acquiringAndReleasing)
    }

    /// Read the claim after admission so person-initiated replies stay in their thread rather than waking the agent.
    public var admitted: Bool {
        spent.load(ordering: .acquiring)
    }

    package static func refusal(_ detail: String) -> JSONValue {
        .object(["status": .string("blocked"), "sent": .bool(false), "completed": .bool(false),
                 "detail": .string(detail)])
    }
}
