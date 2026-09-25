import Foundation
import PersistenceCore

/// A message the person typed into a contact's thread and sent with their own
/// click or Return. That act is the consent for exactly that one send, so the
/// approval gate lets it through without a card (`AutonomyGatedDispatcher`).
///
/// WHY THE MODEL CANNOT FORGE IT: this is a task-local, and only Swift code can
/// bind one. No tool parameter, schema field or tool result reaches it. The app
/// binds it in one place, around one direct dispatch from the thread composer
/// (`ContactThreadSend`), never around a model turn. It names the exact
/// contact and text, and the first matching gate check spends it, so nothing
/// nested under that send (a desktop operator turn, a peer's callback) can
/// ride it. It waives only the send: a call that would also run a program on
/// this Mac, or that Trust refuses, is refused plainly instead of carded.
public final class PersonInitiatedSend: @unchecked Sendable {
    @TaskLocal public static var current: PersonInitiatedSend?

    /// The only capabilities the person's act answers for.
    static let sendOnly: Set<String> = ["tool_call", "external_send", "network_write"]

    public let agent: String
    public let text: String
    private let lock = NSLock()
    private var spent = false

    public init(agent: String, text: String) {
        self.agent = agent
        self.text = text
    }

    func matches(_ input: [String: JSONValue]) -> Bool {
        input["agent"] == .string(agent) && input["text"] == .string(text)
    }

    /// Good for one gate check of this exact send.
    func claim(tool: String, input: [String: JSONValue], surface: String) -> Bool {
        guard tool == "agent_message", surface == "chat", matches(input) else { return false }
        lock.lock(); defer { lock.unlock() }
        guard !spent else { return false }
        spent = true
        return true
    }

    /// The gate took this send as the person's. Read after the gate, so the
    /// contact's answer stays in the thread instead of starting an agent turn.
    public var admitted: Bool {
        lock.lock(); defer { lock.unlock() }
        return spent
    }

    static func refusal(_ detail: String) -> JSONValue {
        .object(["status": .string("blocked"), "sent": .bool(false), "completed": .bool(false),
                 "detail": .string(detail)])
    }
}
