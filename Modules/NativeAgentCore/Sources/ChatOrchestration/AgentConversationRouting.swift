import Foundation
import PersistenceCore

/// Argument translation only. Callers must dispatch through the original tool's
/// admission and execution owners; this type grants no authority or tool access.
public enum AgentConversationRouting {
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

    public static func route(tool: String, input: [String: JSONValue]) throws -> Route? {
        guard tool == "agent_message" || tool == "agent_read" else { return nil }
        if let details = input["details"], details != .null {
            guard tool == "agent_read", case .bool = details else { throw invalid("details is a boolean for agent_read only.") }
        }
        // Nullable optional fields let strict providers express "not applicable"
        // without manufacturing arguments for a different adapter.
        let optional: Set<String> = ["conversation_id", "message_id", "task_id", "options", "limit", "offset", "max_chars"]
        let input = input.filter { $0.key != "details" && !(optional.contains($0.key) && $0.value == .null) }
        let sending = tool == "agent_message"
        let allowed: Set<String> = sending
            ? ["agent", "text", "conversation_id", "message_id", "options", "session_id", "__session_id"]
            : ["agent", "conversation_id", "message_id", "limit", "offset", "session_id", "__session_id"]
        let raw = try string(input["agent"], field: "agent", maximum: 180)
        let agent = raw == "claude" ? "claude" : raw
        if agent.hasPrefix("peer:") {
            guard UUID(uuidString: String(agent.dropFirst(5))) != nil else { throw invalid("peer reference must contain a UUID.") }
            return nil // External adapters retain their own validation and owner.
        }
        try keys(input, allowed: allowed)
        let botID: UUID?
        if agent.hasPrefix("bot:") {
            guard let id = UUID(uuidString: String(agent.dropFirst(4))) else { throw invalid("bot reference must contain a UUID.") }
            botID = id
        } else {
            guard ["codex", "claude", "omp"].contains(agent) else { throw invalid("Use codex, claude, omp, bot:<UUID>, or peer:<UUID> from agent discovery.") }
            botID = nil
        }
        let canonical = botID.map { "bot:" + $0.uuidString } ?? agent
        let conversation = try optionalString(input["conversation_id"], field: "conversation_id", maximum: 512)
        let message = try optionalString(input["message_id"], field: "message_id", maximum: 160)
        if let botID, let conversation {
            guard conversation.hasPrefix("bot:"), UUID(uuidString: String(conversation.dropFirst(4))) == botID else {
                throw invalid("conversation_id must identify this same bot; use its bot:<UUID> handle.")
            }
        }
        // These are harness context, not the remote conversation or bot session.
        // Preserve even malformed values for the existing admission owner to reject.
        var args = input.filter { ["session_id", "__session_id"].contains($0.key) }
        if sending {
            let text = try string(input["text"], field: "text", maximum: 100_000)
            let options: [String: JSONValue]
            if let supplied = input["options"] {
                guard case .object(let object) = supplied else { throw invalid("options must be an object.") }
                let optionalOptions: Set<String> = ["working_directory", "topic", "model", "reasoning_effort", "fast", "pair_reviewer", "timeout_seconds"]
                options = object.filter { !(optionalOptions.contains($0.key) && $0.value == .null) }
            } else { options = [:] }
            if let botID {
                guard options.isEmpty, message == nil else { throw invalid("Bot messages do not support options or caller-supplied message_id; read the returned shelf entry without replaying the ask.") }
                args["id"] = .string(botID.uuidString)
                args["question"] = .string(text)
                return Route(tool: "bot_ask", input: args, agent: canonical)
            }
            try validate(options: options, agent: agent, continuing: conversation != nil)
            args.merge(options) { _, new in new }
            args["text"] = .string(text)
            args["conversation_mode"] = .string(conversation == nil ? "new" : "resume")
            if let conversation { args["conversation_id"] = .string(conversation) }
            if let message { args["message_id"] = .string(message) }
            return Route(tool: agent + "_message", input: args, agent: canonical)
        }
        if let botID {
            guard input["offset"] == nil else { throw invalid("Bot shelf pagination uses an opaque cursor; offset is unsupported.") }
            if let message {
                guard let id = UUID(uuidString: message) else { throw invalid("A bot message_id must be the exact returned shelf entry UUID.") }
                guard input["limit"] == nil else { throw invalid("limit does not apply to an exact bot message.") }
                args["id"] = .string(id.uuidString)
                args["bot_id"] = .string(botID.uuidString)
                return Route(tool: "shelf_entry", input: args, agent: canonical)
            }
            args["bot_id"] = .string(botID.uuidString)
            if let limit = input["limit"] { args["limit"] = try integer(limit, field: "limit", range: 1...100) }
            return Route(tool: "shelf_read", input: args, agent: canonical)
        }
        guard conversation == nil else { throw invalid("Coding-agent reads currently require message_id without conversation_id; conversation filtering is not supported by delegation_status.") }
        args["agent"] = .string(agent)
        args["detail"] = .string("full")
        if let message { args["message_id"] = .string(message) }
        if let limit = input["limit"] { args["limit"] = try integer(limit, field: "limit", range: 1...12) }
        if let offset = input["offset"] { args["offset"] = try integer(offset, field: "offset", range: 0...Int64.max) }
        return Route(tool: "delegation_status", input: args, agent: canonical)
    }

    /// Keep the complete owner receipt and its lifecycle. Request identities are
    /// not substituted for missing acknowledgement identities.
    public static func wrap(result: JSONValue, route: Route, input: [String: JSONValue] = [:]) -> JSONValue {
        var object: [String: JSONValue]
        if case .object(let receipt) = result { object = receipt }
        else { object = ["result": result] }
        if object["agent"] == nil { object["agent"] = .string(route.agent) }
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
        if ["delegation_status", "shelf_read", "shelf_entry"].contains(route.tool) {
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

    private static func validate(options: [String: JSONValue], agent: String, continuing: Bool) throws {
        var allowed: Set<String> = ["working_directory", "topic"]
        if agent != "codex" { allowed.insert("timeout_seconds") }
        if agent == "codex" { allowed.formUnion(["model", "reasoning_effort", "fast", "pair_reviewer"]) }
        if agent == "claude" { allowed.insert("pair_reviewer") }
        try keys(options, allowed: allowed)
        if continuing, options["working_directory"] != nil || options["topic"] != nil {
            throw invalid("A continuation reuses its existing workspace and topic; omit those options.")
        }
        for (key, value) in options {
            switch key {
            case "fast", "pair_reviewer":
                guard case .bool = value else { throw invalid("\(key) must be boolean.") }
            case "timeout_seconds": _ = try integer(value, field: key, range: 60...3600)
            default: _ = try string(value, field: key, maximum: key == "working_directory" ? 4096 : 200)
            }
        }
    }

    private static func keys(_ input: [String: JSONValue], allowed: Set<String>) throws {
        let unknown = Set(input.keys).subtracting(allowed).sorted()
        guard unknown.isEmpty else { throw invalid("Unsupported fields: " + unknown.joined(separator: ", ")) }
    }
    private static func optionalString(_ value: JSONValue?, field: String, maximum: Int) throws -> String? {
        guard let value else { return nil }
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
