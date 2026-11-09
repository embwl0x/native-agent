import AgentWorkspace
import Foundation
import ApprovalInbox
import CryptoKit
import NativeAgentCore
import NativeAgentShared
import PersistenceCore
import TurnTrace
import PersonaEngine
import MemoryV2
import ProviderRouting
import ToolRegistry
import TrustCenter
import Dispatcher
import MacControl
import SwarmRuns
import MacIntegration
import StandingBots
import ChatToolParsing

import ChatTurnContracts
import ChatSessionWork
import AgentConversations
// Blueprint: | `CanonicalToolNameDispatcher.swift` | Canonical dispatch; records non-Inbox calls before execution for message decisions |

/// Every app call re-enters the complete gated chain with the consumer's current
/// turn and operation, including the enclosing receipt and door dependencies.
public struct AppDoorReentry: Sendable {
    public typealias Perform = @Sendable (String, [String: JSONValue], Turn, ChatToolInvocation) async throws -> JSONValue
    public var perform: Perform
    public typealias Validate = @Sendable (String, [String: JSONValue], Turn, ChatToolInvocation) async -> JSONValue?
    public var validate: Validate
    public var waitForInteraction: (@Sendable (InlineInteraction, String, [String: JSONValue]) async -> JSONValue)?
    public init(perform: @escaping Perform, validate: @escaping Validate,
                waitForInteraction: (@Sendable (InlineInteraction, String, [String: JSONValue]) async -> JSONValue)? = nil) {
        self.perform = perform
        self.validate = validate
        self.waitForInteraction = waitForInteraction
    }
}

/// Trims current executor names before every gate so policy judges the name that executes.
public final class CanonicalToolNameDispatcher: ToolDispatchClient {
    private let inner: any ToolDispatchClient
    private let peerDataRoot: URL?
    private let conversationScope: String?

    public init(inner: any ToolDispatchClient, peerDataRoot: URL? = nil,
                conversationScope: String? = nil) {
        self.inner = inner
        self.peerDataRoot = peerDataRoot
        self.conversationScope = conversationScope
    }

    /// Saved contacts and their explicit handles own their names.
    private func namingSavedContact(invocation: ChatToolInvocation, _ tool: String, _ input: [String: JSONValue]) throws -> [String: JSONValue] {
        try AgentConversationRouting.namingSavedContact(conversation: invocation.conversation, tool, input, dataRoot: peerDataRoot)
    }

    /// Match the native dispatcher's whitespace-only admission; unknown names must not resolve through aliases.
    public static func canonical(_ name: String) -> String {
        ToolNameAliases.canonical(name)
    }

    /// The action's own result inside the door's reply; a reply the door answered itself (a refusal, a card) is returned whole.
    public static func actionResult(_ reply: JSONValue, action: String) -> JSONValue {
        guard case .object(let envelope) = reply, envelope["action"] == .string(action), let result = envelope["result"] else { return reply }
        return result
    }

    /// Map dotted ingress to its action identity and bare part IDs to authored.<id> so admission judges the executed door.
    static func doorAction(_ tool: String, turn: Turn) throws -> String? {
        let trimmed = tool.trimmingCharacters(in: .whitespacesAndNewlines)
        let action = trimmed.lowercased()
        if action.contains(".") {
            return try AppActionBinding.action(input: ["action": .string(action)], turn: turn) != nil ? action : nil
        }
        guard !action.isEmpty, !SwiftToolDispatcher.nativeCanonicalToolNames.contains(action) else { return nil }
        let authored = ToolNameAliases.authoredAction(trimmed)
        return try AppActionBinding.action(input: ["action": .string(authored)], turn: turn) != nil ? authored : nil
    }

    public func dispatch(tool: String, input: [String: JSONValue], surface: String, turn: Turn, invocation: ChatToolInvocation) async throws -> JSONValue {
        let input = input.filter { $0.key != "__authored_primitive" }
        let action = tool.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        // Translate only ingress; folded native calls already crossed the app door. Bare-part replay must re-enter under its exact approved action and retain
        // the dispatcher for nested script calls.
        if invocation.appDoor?.perform == nil, invocation.authoredCall?.tool != tool, let door = try Self.doorAction(tool, turn: turn) {
            var call = input.filter { $0.key.hasPrefix("__") }
            call["action"] = .string(door)
            call["args"] = .object(input.filter { !$0.key.hasPrefix("__") })
            return try await dispatch(tool: "app", input: call, surface: surface, turn: turn, invocation: invocation)
        }
        if try !Self.readsInboxOrAnswersApproval(tool: tool, input: input, turn: turn) {
            turn.messageDecisionCalls?.noteOtherCallStarted()
        }
        return try await dispatchWithWorkspacePorts(turn: turn, invocation: invocation, tool: tool, input: input, surface: surface)
    }

    /// Only Inbox reads and decision routes are exempt; every other call closes message authority without inspecting content.
    private static func readsInboxOrAnswersApproval(tool: String, input: [String: JSONValue], turn: Turn) throws -> Bool {
        let name = canonical(tool)
        let arguments: [String: JSONValue]
        if name == "inbox" {
            arguments = input
        } else {
            guard name == "app" else { return false }
            if let script = input["script"], script != .null, script != .string("") { return false }
            if let actions = input["actions"], actions != .null { return false }
            if let binding = try AppActionBinding.action(input: input, turn: turn) {
                guard binding.tool == "inbox" else { return false }
                switch input["args"] {
                case .object(let args)?: arguments = binding.arguments(args)
                case nil, .null?: arguments = binding.arguments([:])
                default: return false
                }
            } else {
                func text(_ key: String) -> String { input[key]?.scalarText?.trimmingCharacters(in: .whitespacesAndNewlines) ?? "" }
                return text("page").lowercased() == "inbox" && text("action").isEmpty && text("find").isEmpty
            }
        }
        switch arguments["verb"]?.stringValue {
        case "list", "read", "archive", "dismiss", "not_now": return true
        case "act":
            guard let action = arguments["action"]?.stringValue else { return false }
            return ["approve", "reject"].contains(InboxActionVocabulary.normalizedAction(action))
        default: return false
        }
    }

    private func dispatchWithWorkspacePorts(turn: Turn, invocation: ChatToolInvocation, tool: String, input: [String: JSONValue],
        surface: String) async throws -> JSONValue {
        let result = try await inner.withToolArguments(turn: turn, invocation: invocation, tool: Self.canonical(tool), input: input,
            surface: surface) { input, invocation in
            let invocation = invocation.with(\.dryRun, Self.canonical(tool) == "agent_message" && input["dry_run"] == .bool(true))
            return try await dispatchNormalized(turn: turn, invocation: invocation, tool: tool, input: input, surface: surface)
        }
        // Only an explicit close removes a Chrome tab from the workspace.
        if case .object(let fields) = result,
           fields["tool"] == .string("browser.chrome_close_tab"), fields["tabClosed"] == .bool(true),
           case .int(let tab)? = fields["tabId"], let root = peerDataRoot,
           let scope = turn.verifiedSessionID ?? conversationScope, !scope.isEmpty {
            await AgentWorkspaceNavigation.shared.forgetTab(tab: tab,
                key: root.standardizedFileURL.path + "\u{0}" + scope)
        }
        // Attach replayable receipts only to structured results, preserving scalar/file bytes and the cached prefix. The person's own sends must not consume
        // notices intended for the agent.
        guard !invocation.internalRead,
              !invocation.insideWorkspace, turn.personInitiatedSend == nil,
              case .object(var fields) = result,
              fields["workspace_arrivals"] == nil,
              let notice = await AgentWorkspaceArrivals.pending(workspace: ChatWorkspaceBinding.operation(turn: turn, invocation: invocation),
                dataRoot: peerDataRoot, scope: turn.verifiedSessionID ?? conversationScope) else { return result }
        fields["workspace_arrivals"] = notice
        return .object(fields)
    }

    private func dispatchNormalized(turn: Turn, invocation: ChatToolInvocation, tool: String, input: [String: JSONValue],
        surface: String) async throws -> JSONValue {
        // Re-entry must refuse before contact queues or other facade coordination can mutate state.
        if let refusal = try PermissionLaw.requestFileAccessRefusal(tool: tool, input: input, turn: turn) { throw refusal }
        // Admit `app` by its action profile, then re-enter the complete chain for each folded tool or script call. The reached name is active for that call
        // only; the app door confers no authority on it.
        if Self.canonical(tool) == "app" {
            let door = AppDoorReentry(perform: { name, arguments, turn, invocation in
                try await self.dispatch(tool: name, input: arguments, surface: surface,
                    turn: turn.with(\.offeredTools, (turn.offeredTools ?? []).union([name])), invocation: invocation)
            }, validate: { name, arguments, turn, invocation in
                if let validating = self.inner as? any PreApprovalToolValidating {
                    return await validating.preApprovalRefusal(turn: turn, invocation: invocation, tool: name, input: arguments, surface: surface)
                }
                return await (self.inner as? any PureToolArgumentValidating)?.argumentRefusal(tool: name, input: arguments, turn: turn)
            }, waitForInteraction: invocation.appDoor?.waitForInteraction)
            return try await dispatchExact(turn: turn, invocation: invocation.with(\.appDoor, door), tool: tool, input: input, surface: surface)
        }
        if Self.canonical(tool) == "workspace" {
            guard let root = peerDataRoot,
                  let scope = turn.verifiedSessionID ?? conversationScope, !scope.isEmpty else {
                throw ToolFailureError("""
                    Workspace needs a runtime-bound originating door. No action was performed. Call app {} through a verified turn or native \
                    owner's door; creating a transcript or supplying __session_id cannot bind this caller.
                    """,
                    argumentPath: "context", accepted: "a verified turn or native owner's tool chain", effects: .none,
                    nextCall: ToolFailureError.call("app"))
            }
            // Admission to the facade is checked first. Each selected read or send then re-enters the SAME complete chain under its real name and complete
            // arguments; workspace cannot confer its authority.
            let admission = try await dispatchExact(turn: turn, invocation: invocation, tool: tool, input: input, surface: surface)
            let reply = ToolResult(admission)
            guard case .object(let prepared) = admission,
                  reply.said("prepared"), reply.status == prepared["status"]?.stringValue,
                  prepared["execution"] == .string("requires_workspace_runtime") else { return admission }
            // Workspace looks retain their own Mac frame slot.
            let invocation = invocation.with(\.frameSource, "workspace").with(\.insideWorkspace, true)
            // A room's form may name a door verb a part answers; it runs through the door like the agent's own call. An unreadable registry offers none.
            let answered = SwiftToolDispatcher.authoredTools(dataRoot: root).compactMap { tool -> LLMToolSchema? in
                guard tool.answer != nil, let verb = tool.action else { return nil }
                return LLMToolSchema(name: verb, toolClass: tool.schema.toolClass, reach: tool.schema.reach, capabilities: tool.schema.capabilities,
                                     macIntegration: tool.schema.macIntegration, description: tool.schema.description,
                                     parametersJSON: tool.schema.parametersJSON)
            }
            let verbs = Set(answered.map(\.name))
            let result = try await AgentWorkspaceReadiness.withSnapshot(workspace: ChatWorkspaceBinding.operation(turn: turn, invocation: invocation),
                dataRoot: root) { workspace in
              try await AgentWorkspace.dispatch(workspace: workspace, input: input, scope: scope, dataRoot: root,
                catalog: { try await self.inner.listAvailableToolSchemas(turn: turn, surface: surface) + answered }) { name, arguments in
                // The agent's own app is never read through the workspace's Mac verbs.
                if let refusal = await AgentScreen.ownAppRefusal(tool: name, input: arguments) { return refusal }
                let scoped = ChatToolSessionInjection.apply(toolName: name, input: arguments, sessionId: scope)
                guard verbs.contains(name) else {
                    return try await self.dispatch(tool: name, input: scoped, surface: surface, turn: turn, invocation: invocation)
                }
                // A verb a part answers runs through the door; the room reads the verb's own result.
                var call = scoped.filter { $0.key.hasPrefix("__") }
                call["action"] = .string(name)
                call["args"] = .object(scoped.filter { !$0.key.hasPrefix("__") })
                return Self.actionResult(try await self.dispatch(tool: "app", input: call, surface: surface, turn: turn, invocation: invocation),
                    action: name)
              }
            }
            return result
        }
        // Keep both facade and executor policy identities visible to admission; dotted aliases would introduce an unwanted third identity.
        var input = try namingSavedContact(invocation: invocation, tool, input)
        if tool == "agent_message" {
            try AgentMessageFiles.requireSupported(conversation: invocation.conversation, input, dataRoot: peerDataRoot)
            if try AgentMessageFiles.paths(input["files"]).isEmpty { input.removeValue(forKey: "files") }
        }
        if ["read_page", "browser.chrome_navigate", "browser_chrome_navigate"].contains(Self.canonical(tool)),
           case .string(let url)? = input["url"] { input["url"] = .string(SwiftToolDispatcher.withWebScheme(url)) }
        // Known hosts connect through agent_connect's gates and card before messaging.
        if tool == "agent_message", !HelperContact.matches(conversation: invocation.conversation, input), turn.personInitiatedSend == nil, !invocation.dryRun,
           case .string(let name)? = input["agent"], !name.contains(":"),
           let row = AgentHostDirectory.row(named: name), let root = peerDataRoot,
           // Resolve shortened saved-contact names to that contact so a suffix cannot create a second route.
           !(try AgentPeerStore(dataRoot: root).list()).contains(where: { $0.name.localizedCaseInsensitiveContains(name) }) {
            return try await connectThenMessage(turn: turn, invocation: invocation, row: row, input: input, surface: surface)
        }
        if Self.canonical(tool) == "bot_run_once", let root = peerDataRoot,
           let scope = turn.verifiedSessionID ?? conversationScope, !scope.isEmpty {
            return try await BotRunConversation.dispatch(turn: turn, invocation: invocation, input: input, surface: surface, scope: scope,
                dataRoot: root) { _, input in
                try await self.dispatchExact(turn: turn, invocation: invocation, tool: tool, input: input, surface: surface)
            }
        }
        // Contact waits return conversation reads through agent_read's gates; wait_seconds adds no Full Mac gate. Screen waits retain wait's admission. Blank
        // optional contact selectors are absent.
        func blank(_ value: JSONValue) -> Bool {
            if case .string(let text) = value { return text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
            return value == .null
        }
        if Self.canonical(tool) == "wait" {
            for key in ["agent", "conversation"] where input[key].map(blank) == true { input.removeValue(forKey: key) }
        }
        let readWait = tool == "agent_read" ? input.removeValue(forKey: "wait_seconds") : nil
        let waitsOnRead: Bool = switch readWait { case .int(let n)?: (1...300).contains(n); default: false }
        if let readWait, readWait != .null, !waitsOnRead {
            throw ToolFailureError("wait_seconds must be an integer from 1 to 300.", argumentPath: "wait_seconds",
                                   accepted: "app {action:\"agent.read\",args:{agent:\"<contact>\",wait_seconds:60}}", effects: .none)
        }
        if waitsOnRead, input.contains(where: { !blank($0.value) && !["agent", "conversation", "conversation_id", "message_id", "task_id", "details",
            "session_id", "__session_id"].contains($0.key) }) {
            throw ToolFailureError("""
                wait_seconds accepts only agent, conversation, conversation_id, message_id, task_id and details. Use max_chars or history/listing \
                filters in a separate read without wait_seconds.
                """,
                                   argumentPath: "wait_seconds",
                                   accepted: "app {action:\"agent.read\",args:{agent:\"<contact>\",wait_seconds:60}}", effects: .none)
        }
        if (Self.canonical(tool) == "wait" && input["agent"] != nil) || waitsOnRead {
            guard let root = peerDataRoot,
                  let scope = try turn.verifiedSessionID ?? conversationScope
                    ?? (waitsOnRead ? Self.contactSession(input, dataRoot: root) : nil), !scope.isEmpty else {
                if waitsOnRead { throw AgentConversationStore.Failure(message: """
                    wait_seconds needs this chat's conversation, which this call does not have. Nothing was read.
                    """) }
                return try await dispatchExact(turn: turn, invocation: invocation, tool: tool, input: input, surface: surface)
            }
            var named = try namingSavedContact(invocation: invocation, "agent_read", input)
            if waitsOnRead { named["seconds"] = readWait }
            return try await AgentConversationSession.waitForReply(turn: turn, mac: invocation.macContext(dataRoot: root),
                conversation: invocation.conversation, input: named, scope: scope, dataRoot: root, admit: waitsOnRead) { tool, input, turn, conversation, mac in
                try await self.dispatchNormalized(turn: turn, invocation: invocation.serving(conversation: conversation).serving(mac: mac),
                    tool: tool, input: input, surface: surface)
            }
        }
        // Dry runs create no exchange or transcript; work without a chat uses the contact's own session.
        if !invocation.internalRead, !invocation.dryRun,
           ["agent_message", "agent_read", "agent_cancel"].contains(tool), let root = peerDataRoot,
           let scope = try turn.verifiedSessionID ?? conversationScope ?? Self.contactSession(input, dataRoot: root),
           !scope.isEmpty {
            return try await AgentConversationSession.dispatch(turn: turn, mac: invocation.macContext(dataRoot: root),
                conversation: invocation.conversation, workspace: ChatWorkspaceBinding.operation(turn: turn, invocation: invocation),
                tool: tool, input: input, surface: surface, scope: scope, dataRoot: root) { tool, input, turn, conversation, mac in
                    // Everything the conversation dispatches is its own internal read or send: marked here, once, it reaches the contact's
                    // transport and never re-enters this conversation (unmarked, a Grok details read recursed until the app pinned a core).
                    try await self.dispatch(tool: tool, input: input, surface: surface, turn: turn,
                        invocation: invocation.serving(conversation: conversation.internalRead).serving(mac: mac))
                }
        }
        return try await dispatchExact(turn: turn, invocation: invocation, tool: tool, input: input, surface: surface)
    }

    /// Only saved contacts may supply ContactThread.session; other routes have no contact-owned session.
    private static func contactSession(_ input: [String: JSONValue], dataRoot: URL) throws -> String? {
        guard case .string(let agent)? = input["agent"] else { return nil }
        return agent.hasPrefix("peer:") ? ContactThread.session(owner: String(agent.dropFirst(5))) : nil
    }

    /// Send only after connection succeeds; otherwise preserve the connection result without sending.
    private func connectThenMessage(turn: Turn, invocation: ChatToolInvocation, row: AgentHostRow, input: [String: JSONValue],
        surface: String) async throws -> JSONValue {
        var request: [String: JSONValue] = ["name": .string(row.displayName)]
        for key in ["session_id", "__session_id"] { request[key] = input[key] }
        var connect: [String: JSONValue]
        do {
            let result = try await dispatch(tool: "agent_connect", input: request, surface: surface, turn: turn, invocation: invocation)
            if case .object(let fields) = result { connect = fields } else { connect = ["result": result] }
        } catch {
            connect = ["status": .string("failed"), "detail": .string(ChatToolOutcome.errorMessage(error))]
        }
        // Send only to the contact this connect made or confirmed, never to another saved peer that happens to share a name.
        let reply = ToolResult(.object(connect))
        var handle: String?
        if reply.status == connect["status"]?.stringValue,
           ["configured", "connected", "already_configured", "set up"].contains(where: { reply.said($0) }) {
            if case .object(let contact)? = connect["contact"], case .string(let agent)? = contact["agent"] { handle = agent }
            else if reply.said("set up"), let root = peerDataRoot,
                    let peer = (try AgentPeerStore(dataRoot: root).list()).first(where: {
                        $0.transport == .grokBot && $0.name.caseInsensitiveCompare(row.displayName) == .orderedSame }) {
                handle = "peer:" + peer.id
            }
        }
        var named = input
        guard let handle, handle.hasPrefix("peer:") else {
            connect["sent"] = .bool(false)
            connect["message"] = .string("\(row.displayName) is not connected, so the message was not sent. Once it is, send it again with agent_message.")
            return .object(connect)
        }
        named["agent"] = .string(handle)
        var result = try await dispatchNormalized(turn: turn, invocation: invocation, tool: "agent_message", input: named, surface: surface)
        if case .object(var fields) = result {
            fields["connected_first"] = .object(["status": connect["status"] ?? .string("unknown"),
                                                 "detail": connect["detail"] ?? connect["state_detail"] ?? .null])
            result = .object(fields)
        }
        return result
    }

    private func dispatchExact(turn: Turn, invocation: ChatToolInvocation, tool: String, input: [String: JSONValue],
        surface: String) async throws -> JSONValue {
        let route: AgentConversationRouting.Route?
        do { route = try AgentConversationRouting.route(conversation: invocation.conversation, tool: tool, input: input) }
        catch let error as AgentConversationRouting.InvalidRequest {
            throw ToolFailureError(error.message, argumentPath: "args",
                accepted: tool == "agent_read"
                    ? "app {action:\"agent.read\",args:{agent:\"<contact>\",message_id:\"<receipt message_id>\"}}"
                    : "app {action:\"agent.message\",args:{agent:\"<contact>\",text:\"<message>\"}}", effects: .none)
        }
        if let route {
            let result = try await inner.dispatch(tool: route.tool, input: route.input, surface: surface, turn: turn, invocation: invocation)
            return AgentConversationRouting.wrap(result: result, route: route, input: input)
        }
        return try await inner.dispatch(tool: Self.canonical(tool), input: input, surface: surface, turn: turn, invocation: invocation)
    }

    public func listAvailableTools(turn: Turn?, surface: String) async throws -> [String] {
        try await inner.listAvailableTools(turn: turn, surface: surface)
    }

    public func listAvailableToolSchemas(named names: Set<String>, turn: Turn?, surface: String) async throws -> [LLMToolSchema] {
        try await inner.listAvailableToolSchemas(named: names, turn: turn, surface: surface)
    }

    public func listAvailableToolSchemas(turn: Turn?, surface: String) async throws -> [LLMToolSchema] {
        try await inner.listAvailableToolSchemas(turn: turn, surface: surface)
    }
}

extension ApprovedChatToolReplay {
    package func matches(turn: Turn,
        tool: String,
        surface: String,
        input: [String: JSONValue],
        verifiedSessionID: String?
    ) -> Bool {
        // Compare canonical names for both persisted approvals and dispatched calls.
        !approvalID.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            && CanonicalToolNameDispatcher.canonical(self.tool)
                == CanonicalToolNameDispatcher.canonical(tool)
            && self.surface == surface
            && self.input == input
            && self.verifiedSessionID == verifiedSessionID
            && verifiedChatID == turn.envelope?.verifiedChatId
            && verifiedUserID == turn.envelope?.verifiedUserId
    }
}
