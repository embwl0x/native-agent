import Foundation
import PersistenceCore
// Blueprint: | `PersonInitiatedSend.swift` | `PersonInitiatedSend` class; `matches`, `claim` |

/// A composer click or Return grants exactly one matching contact-and-text send, never nested work. Swift carries this grant on `turn.personInitiatedSend`
/// through the direct composer dispatch; model input cannot forge it. It waives only send approval: program execution and Trust refusals still refuse plainly.
public final class PersonInitiatedSend: @unchecked Sendable {

    /// The person’s act answers only these send capabilities.
    package static let sendOnly: Set<String> = ["tool_call", "external_send", "network_write"]

    public let agent: String
    public let text: String
    private let lock = NSLock()
    private var spent = false

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
        lock.lock(); defer { lock.unlock() }
        guard !spent else { return false }
        spent = true
        return true
    }

    /// Read the claim after admission so person-initiated replies stay in their thread rather than waking the agent.
    public var admitted: Bool {
        lock.lock(); defer { lock.unlock() }
        return spent
    }

    package static func refusal(_ detail: String) -> JSONValue {
        .object(["status": .string("blocked"), "sent": .bool(false), "completed": .bool(false),
                 "detail": .string(detail)])
    }
}
