import Foundation
import NativeAgentCore
import PersistenceCore
import StandingBots
// Blueprint: | `AgentConversationRouting.swift` | `AgentConversationRouting` enum; `route`, `wrap` |

/// Argument translation only. Callers must dispatch through the original tool's admission and execution owners; this type grants no authority or tool access.
public enum AgentConversationRouting {
    /// Security reads the same checked contact and recipe owners as dispatch.
    public static func messagesHostByCommand(conversation: AgentConversationContext, _ raw: String, dataRoot: URL) throws -> Bool {
        let input: [String: JSONValue] = ["agent": .string(raw)]
        if HelperContact.matches(conversation: conversation, input) { return false }
        let named = try namingSavedContact(conversation: conversation, "agent_message", input, dataRoot: dataRoot)
        guard let agent = named["agent"]?.stringValue, !agent.isEmpty else { throw invalid("Name the contact to classify its effects.") }
        if agent.hasPrefix("bot:") {
            guard let id = UUID(uuidString: String(agent.dropFirst(4))),
                  try BotDefinitionStore(dataRoot: dataRoot).list().contains(where: { $0.id == id }) else {
                throw invalid("The addressed helper could not be read. Refresh Helpers before sending.")
            }
            return false
        }
        let peers = try AgentPeerStore(dataRoot: dataRoot).list()
        let matches = peers.filter { peer in
            agent == "peer:" + peer.id || agent.lowercased() == peer.id
                || peer.name.caseInsensitiveCompare(agent) == .orderedSame
                || (peer.handles ?? []).contains { $0.caseInsensitiveCompare(agent) == .orderedSame }
        }
        guard matches.count == 1, let peer = matches.first else {
            throw invalid("The addressed contact is missing or ambiguous. Choose its exact contact before sending.")
        }
        guard peer.transport == .acp || peer.transport == .mcpHost else { return false }
        guard let host = peer.endpoint.host, !host.isEmpty else { throw invalid("The contact's host recipe identity is missing.") }
        let launch = try AgentRecipeStore.launch(host, dataRoot: dataRoot)
        if peer.transport == .acp {
            guard launch.acp != nil else { throw invalid(
                "The addressed ACP recipe has no ACP launch declaration. Repair agents/recipes/\(host).json before sending.") }
            return true
        }
        return launch.commandLine != nil
    }

    public struct Route: Sendable {
        public let tool: String
        public let input: [String: JSONValue]
        public let agent: String

        public init(tool: String, input: [String: JSONValue], agent: String) {
            self.tool = tool
            self.input = input
            self.agent = agent
        }
    }

    public struct InvalidRequest: Error, LocalizedError, Sendable {
        public let message: String
        public var errorDescription: String? { message }
    }

    public static func namingSavedContact(conversation: AgentConversationContext, _ tool: String, _ input: [String: JSONValue],
        dataRoot: URL?) throws -> [String: JSONValue] {
        if tool == "agent_message", HelperContact.matches(conversation: conversation, input) { return input }
        guard ["agent_message", "agent_read", "agent_cancel"].contains(tool), let dataRoot,
              case .string(let raw)? = input["agent"], !raw.contains(":") else { return input }
        let name = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        var matches = try AgentPeerStore(dataRoot: dataRoot).references(named: name)
        matches.formUnion(try BotDefinitionStore(dataRoot: dataRoot).list().filter {
            $0.id.uuidString.lowercased() == name.lowercased() || $0.name.caseInsensitiveCompare(name) == .orderedSame
        }.map { "bot:" + $0.id.uuidString })
        guard matches.count <= 1 else { throw InvalidRequest(message: "More than one contact is named \(name). Choose its exact contact from agent_contacts.") }
        var input = input
        if let exact = matches.first { input["agent"] = .string(exact) }
        return input
    }

    public static func route(conversation: AgentConversationContext, tool: String, input: [String: JSONValue]) throws -> Route? {
        if tool == "agent_message", HelperContact.matches(conversation: conversation, input) { return nil }
        guard tool == "agent_message" || tool == "agent_read" else { return nil }
        if let details = input["details"], details != .null {
            guard tool == "agent_read", case .bool = details else { throw invalid("details is a boolean for agent_read only.") }
        }
        let optional: Set<String> = ["conversation_id", "message_id", "task_id", "limit", "offset", "max_chars"]
        let input = input.filter { $0.key != "details" && !(optional.contains($0.key) && ($0.value == .string(""))) }
        let sending = tool == "agent_message"
        let allowed: Set<String> = sending
            ? ["agent", "text", "conversation_id", "message_id", "expects_reply", "session_id", "__session_id"]
            : ["agent", "conversation_id", "message_id", "limit", "offset", "session_id", "__session_id"]
        let agent = try string(input["agent"], field: "agent", maximum: 180)
        if agent.hasPrefix("peer:") {
            guard UUID(uuidString: String(agent.dropFirst(5))) != nil else { throw invalid("peer reference must contain a UUID.") }
            return nil // The selected recipe retains its own owner.
        }
        try keys(input, allowed: allowed)
        guard agent.hasPrefix("bot:") else { throw invalid("No contact is named '\(agent)'. Use a name exactly as agent_contacts shows it.") }
        guard let botID = UUID(uuidString: String(agent.dropFirst(4))) else { throw invalid("bot reference must contain a UUID.") }
        let canonical = "bot:" + botID.uuidString
        let conversation = try optionalString(input["conversation_id"], field: "conversation_id", maximum: 512)
        let message = try optionalString(input["message_id"], field: "message_id", maximum: 160)
        if let conversation {
            guard conversation.hasPrefix("bot:"), UUID(uuidString: String(conversation.dropFirst(4))) == botID else {
                throw invalid("conversation_id must identify this same bot; use its bot:<UUID> handle.")
            }
        }
        // These are turn routing fields, not the remote conversation or bot session. Preserve even malformed values for the existing admission owner to reject.
        var args = input.filter { ["session_id", "__session_id"].contains($0.key) }
        if sending {
            let text = try string(input["text"], field: "text", maximum: 100_000)
            guard message == nil else { throw invalid(
                "Bot messages do not support a caller-supplied message_id; read the returned shelf entry without replaying the ask.") }
            args["id"] = .string(botID.uuidString)
            args["question"] = .string(text)
            return Route(tool: "bot_ask", input: args, agent: canonical)
        }
        guard input["offset"] == nil else { throw invalid("Bot shelf pagination uses an opaque cursor; offset is unsupported.") }
        if let message {
            guard let id = UUID(uuidString: message) else { throw invalid("A bot message_id must be the exact returned shelf entry UUID.") }
            guard input["limit"] == nil else { throw invalid("limit does not apply to an exact bot message.") }
            args["id"] = .string(id.uuidString)
            args["bot_id"] = .string(botID.uuidString)
            return Route(tool: "shelf_entry", input: args, agent: canonical)
        }
        if let limit = input["limit"] {
            args["id"] = .string(botID.uuidString)
            args["limit"] = try integer(limit, field: "limit", range: 1...100)
            return Route(tool: "shelf_read", input: args, agent: canonical)
        }
        // Use the latest actual reply because acknowledging an unread index removes it.
        args["bot_id"] = .string(botID.uuidString)
        return Route(tool: "shelf_entry", input: args, agent: canonical)
    }

    /// Keep the complete owner receipt and its lifecycle. Request identities are not substituted for missing acknowledgement identities.
    public static func wrap(result: JSONValue, route: Route, input: [String: JSONValue] = [:]) -> JSONValue {
        var object: [String: JSONValue]
        if case .object(let receipt) = result { object = receipt }
        else { object = ["result": result] }
        if object["agent"] == nil { object["agent"] = .string(route.agent) }
        if route.tool == "bot_ask", object["reply"] == nil {
            object["reply"] = object["answer"]
        }
        if object["conversation_id"] == nil {
            if route.agent.hasPrefix("bot:") { object["conversation_id"] = .string(route.agent) }
            else if let value = object["conversationId"] { object["conversation_id"] = value }
        }
        if object["message_id"] == nil {
            if let value = object[route.agent.hasPrefix("bot:") ? "entry_id" : "messageId"] { object["message_id"] = value }
            else if route.tool == "shelf_entry", let value = object["id"] { object["message_id"] = value }
        }
        if let locator = readLocator(agent: route.agent, message: object["message_id"],
                                     conversation: object["conversation_id"], task: nil) {
            object["read_with"] = locator
        }
        if ["shelf_read", "shelf_entry"].contains(route.tool) {
            return AgentConversationView.read(.object(object), agent: route.agent, input: input)
        }
        return .object(object)
    }

    /// A scoped recovery reference, never an execution or an authority grant.
    public static func readLocator(agent: String, message: JSONValue?, conversation: JSONValue?, task: JSONValue?) -> JSONValue? {
        func identifier(_ value: JSONValue?) -> JSONValue? {
            guard case .string(let text)? = value, !text.isEmpty else { return nil }
            return .string(text)
        }
        var input: [String: JSONValue] = ["agent": .string(agent)]
        if let task = identifier(task) { input["task_id"] = task }
        else if let message = identifier(message) {
            input["message_id"] = message
            if agent.hasPrefix("peer:") {
                guard let conversation = identifier(conversation) else { return nil }
                input["conversation_id"] = conversation
            }
        } else { return nil }
        return .object(["tool": .string("agent_read"), "input": .object(input)])
    }

    private static func keys(_ input: [String: JSONValue], allowed: Set<String>) throws {
        let unknown = Set(input.keys).subtracting(allowed).sorted()
        guard unknown.isEmpty else { throw invalid("Unsupported fields: " + unknown.joined(separator: ", ")) }
    }
    private static func optionalString(_ value: JSONValue?, field: String, maximum: Int) throws -> String? {
        guard let value, value != .null else { return nil }
        return try string(value, field: field, maximum: maximum)
    }
    private static func string(_ value: JSONValue?, field: String, maximum: Int) throws -> String {
        guard case .string(let text)? = value, !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty, text.count <= maximum else {
            throw invalid("\(field) must be a nonempty string of at most \(maximum) characters.")
        }
        return text
    }
    private static func integer(_ value: JSONValue, field: String, range: ClosedRange<Int64>) throws -> JSONValue {
        guard case .int(let number) = value, range.contains(number) else { throw invalid("\(field) must be an integer in \(range).") }
        return value
    }
    private static func invalid(_ message: String) -> InvalidRequest { InvalidRequest(message: message) }
}
