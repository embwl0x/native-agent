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
import MCPDispatcher
import ProviderRouting
import ToolRegistry
import TrustCenter
import KnowledgeGraph
import XConnector
import Dispatcher
import MacControl
import SwarmRuns
import MacIntegration
import StandingBots

import ChatTurnContracts
import ChatSessionWork
import AgentConversations

/// The `app` door's way back in: the canonical dispatcher binds it around an
/// `app` call, and each call of a script re-enters the whole chain through it
/// as its own `app` call.
public enum AppDoorReentry {
    public typealias Perform = @Sendable (String, [String: JSONValue]) async throws -> JSONValue
    @TaskLocal public static var perform: Perform?
    public typealias Validate = @Sendable (String, [String: JSONValue]) async -> JSONValue?
    @TaskLocal public static var validate: Validate?
    @TaskLocal public static var waitForInteraction: (@Sendable (InlineInteraction, String, [String: JSONValue]) async -> JSONValue)?
    /// What a send listed in an `app {actions}` call returns instead of
    /// running when the step also called something else: the step's held
    /// receipt (`heldOutboundResult`), nil when the step holds no send.
    @TaskLocal public static var heldSend: JSONValue?
}

// MARK: - Dotted-alias canonicalization (outermost)

/// 2026-09-06: the dispatcher's dotted-alias canonicalizer (`save.skill` →
/// `save_skill`) ran INSIDE `SwiftToolDispatcher.dispatch`, i.e. after every
/// gate had already judged the spelling the caller supplied. So `save.skill`
/// matched neither `FileAccessGatedDispatcher`'s blocklist nor a Trust Center
/// override keyed on `save_skill`, and `tool.catalog` slipped past the bridge
/// guard's meta-result scrub — while Core still executed `save_skill` /
/// `tool_catalog`. Canonicalize ONCE, outside every gate, so each gate judges
/// the name that will actually execute. Idempotent: the inner dispatcher's own
/// canonicalization then finds nothing left to rewrite. 2026-09-26: the name
/// comes from the one alias table (`ToolNameAliases`), which also holds the
/// app's browser/notify/self-admin spellings the Trust Center used to resolve
/// differently.
public final class CanonicalToolNameDispatcher: ToolDispatchClient, @unchecked Sendable {
    private let inner: any ToolDispatchClient
    private let peerDataRoot: URL?
    private let builtInLanes: (any BuiltInAgentLaneProviding)?
    private let conversationScope: String?

    public init(inner: any ToolDispatchClient, peerDataRoot: URL? = nil,
                builtInLanes: (any BuiltInAgentLaneProviding)? = nil, conversationScope: String? = nil) {
        self.inner = inner
        self.peerDataRoot = peerDataRoot
        self.builtInLanes = builtInLanes ?? (inner as? any BuiltInAgentLaneProviding)
        self.conversationScope = conversationScope
    }

    /// Saved contacts and their explicit handles own their names.
    private func namingSavedContact(_ tool: String, _ input: [String: JSONValue]) throws -> [String: JSONValue] {
        try AgentConversationRouting.namingSavedContact(tool, input, dataRoot: peerDataRoot)
    }

    /// The one alias table (`ToolNameAliases`) over the built-in catalog —
    /// the same resolution `SwiftToolDispatcher.dispatch` applies downstream.
    /// Unknown names stay unknown.
    public static func canonical(_ name: String) -> String {
        ToolNameAliases.canonical(name) { SwiftToolDispatcher.nativeCanonicalToolNames.contains($0) }
    }

    /// The door action an ingress call is: a dotted action name as itself, a
    /// part's bare id as `authored.<id>`; nil for a native tool or an unknown name.
    static func doorAction(_ tool: String) -> String? {
        let trimmed = tool.trimmingCharacters(in: .whitespacesAndNewlines)
        let action = trimmed.lowercased()
        if action.contains(".") {
            return AppActionBinding.action(input: ["action": .string(action)]) != nil ? action : nil
        }
        guard !action.isEmpty, !SwiftToolDispatcher.nativeCanonicalToolNames.contains(action) else { return nil }
        let authored = ToolNameAliases.authoredAction(trimmed)
        return AppActionBinding.action(input: ["action": .string(authored)]) != nil ? authored : nil
    }

    public func dispatch(tool: String, input: [String: JSONValue], surface: String) async throws -> JSONValue {
        let input = input.filter { $0.key != "__authored_primitive" }
        let action = tool.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        // Folded native calls already came through the door; translate only ingress.
        // A part reached by its bare name from outside the door — an approved
        // card's replay, a bridge's direct call — is the door call that runs it
        // (`authored.<id>`), so its script has the chain to come back through
        // and the card's exact call is what re-enters under the part's name.
        if AppDoorReentry.perform == nil, AuthoredToolEffects.call?.tool != tool, let door = Self.doorAction(tool) {
            var call = input.filter { $0.key.hasPrefix("__") }
            call["action"] = .string(door)
            call["args"] = .object(input.filter { !$0.key.hasPrefix("__") })
            return try await dispatch(tool: "app", input: call, surface: surface)
        }
        return try await AgentWorkspacePorts.$binding.withValue(ChatWorkspaceBinding.ports) {
            try await dispatchWithWorkspacePorts(tool: tool, input: input, surface: surface)
        }
    }

    private func dispatchWithWorkspacePorts(tool: String, input: [String: JSONValue], surface: String) async throws -> JSONValue {
        let result = try await inner.withToolArguments(tool: Self.canonical(tool), input: input) { input in
            let result = try await AgentRecipeStore.$dryRun.withValue(Self.canonical(tool) == "agent_message" && input["dry_run"] == .bool(true)) {
                try await dispatchNormalized(tool: tool, input: input, surface: surface)
            }
            if !AgentConversationContext.isInternalRead, Self.canonical(tool) == "agent_read",
               case .object(var fields) = result,
               case .string(let agent)? = fields["agent_id"] ?? fields["agent"], let root = peerDataRoot, AgentConversationDelivery.door(for: agent, dataRoot: root)?.liveReader == true {
                fields["worklog"] = AgentConversationView.claudeWorklog()
                return .object(fields)
            }
            return result
        }
        // Only an explicit close removes a Chrome tab from the workspace.
        if case .object(let fields) = result,
           fields["tool"] == .string("browser.chrome_close_tab"), fields["tabClosed"] == .bool(true),
           case .int(let tab)? = fields["tabId"], let root = peerDataRoot,
           let scope = ChatToolSessionContext.verifiedSessionId ?? conversationScope, !scope.isEmpty {
            await AgentWorkspaceNavigation.shared.forgetTab(tab: tab,
                key: root.standardizedFileURL.path + "\u{0}" + scope)
        }
        // Attach to structured owner results so every provider lane receives
        // the same replayable receipt, without altering scalar/file contents,
        // adding synthetic chat turns, or changing the cached prompt prefix.
        // The person's own thread send has no agent reading its result, so it
        // must not use up her arrival notices.
        guard !AgentConversationContext.isInternalRead,
              !AgentWorkspaceArrivals.insideWorkspaceDispatch, PersonInitiatedSend.current == nil,
              case .object(var fields) = result,
              fields["workspace_arrivals"] == nil,
              let notice = await AgentWorkspaceArrivals.pending(dataRoot: peerDataRoot,
                scope: ChatToolSessionContext.verifiedSessionId ?? conversationScope) else { return result }
        fields["workspace_arrivals"] = notice
        return .object(fields)
    }

    private func dispatchNormalized(tool: String, input: [String: JSONValue], surface: String) async throws -> JSONValue {
        // The app door: `app` is admitted first under its
        // own profile, classified by action, and an action runs in process, so
        // this was its one pass. Each call of a script re-enters the SAME
        // complete chain as its own `app` call; a script cannot confer its
        // authority. The name it reaches is active for that call only.
        if Self.canonical(tool) == "app" {
            return try await AppDoorReentry.$validate.withValue({ name, arguments in
                if let validating = self.inner as? any PreApprovalToolValidating {
                    return await validating.preApprovalRefusal(tool: name, input: arguments, surface: surface)
                }
                return await (self.inner as? any PureToolArgumentValidating)?.argumentRefusal(tool: name, input: arguments)
            }) {
                try await AppDoorReentry.$perform.withValue({ name, arguments in
                    try await LLMCallContext.$turnActiveTools.withValue((LLMCallContext.turnActiveTools ?? []).union([name])) {
                        try await self.dispatch(tool: name, input: arguments, surface: surface)
                    }
                }) {
                    try await dispatchExact(tool: tool, input: input, surface: surface)
                }
            }
        }
        if Self.canonical(tool) == "workspace" {
            guard let root = peerDataRoot,
                  let scope = ChatToolSessionContext.verifiedSessionId ?? conversationScope, !scope.isEmpty else {
                throw ToolFailureError("Workspace needs a transport-bound chat session. No action was performed. Call app {} from a chat turn's tool chain; creating a transcript or supplying __session_id cannot bind this caller.",
                    argumentPath: "context", accepted: "a chat turn's verified tool chain", effects: .none,
                    nextCall: ToolFailureError.call("app"))
            }
            // Admission to the facade is checked first. Each selected read or
            // send then re-enters the SAME complete chain under its real name
            // and complete arguments; workspace cannot confer its authority.
            let admission = try await dispatchExact(tool: tool, input: input, surface: surface)
            guard case .object(let prepared) = admission,
                  prepared["status"] == .string("prepared"),
                  prepared["execution"] == .string("requires_workspace_runtime") else { return admission }
            // Phase 3: workspace looks keep their own Mac frame slot.
            let result = try await MacLookFrameStore.$source.withValue("workspace") {
              try await AgentWorkspaceArrivals.$insideWorkspaceDispatch.withValue(true) {
              try await AgentWorkspaceReadiness.withSnapshot(dataRoot: root) {
              try await AgentWorkspace.dispatch(input: input, scope: scope, dataRoot: root,
                catalog: { try await self.inner.listAvailableToolSchemas() }) { name, arguments in
                // Her own app is never read through the workspace's Mac verbs.
                if let refusal = await HerScreen.ownAppRefusal(tool: name, input: arguments) { return refusal }
                let scoped = ChatToolSessionInjection.apply(toolName: name, input: arguments, sessionId: scope)
                return try await self.dispatch(tool: name, input: scoped, surface: surface)
              }
              }
              }
            }
            return result
        }
        // Translate the conversational facade before every admission owner.
        // Both the facade policy and the actual executor policy remain visible.
        // Dotted facade aliases are deliberately unsupported: this context has
        // two policy identities, not three.
        var input = try namingSavedContact(tool, input)
        if ["read_page", "browser.chrome_navigate", "browser_chrome_navigate"].contains(Self.canonical(tool)),
           case .string(let url)? = input["url"] { input["url"] = .string(SwiftToolDispatcher.withWebScheme(url)) }
        // Agent 09-24: "agent_message connects if needed and hands back the
        // thread, so it's one call." A known agent that is not a contact yet
        // is connected first, through agent_connect's own gates and card.
        if tool == "agent_message", PersonInitiatedSend.current == nil, !AgentRecipeStore.dryRun,
           case .string(let name)? = input["agent"], !name.contains(":"),
           let row = AgentHostDirectory.row(named: name), let root = peerDataRoot,
           AgentConversationDelivery.door(for: name, dataRoot: root) == nil,
           // "Grok" while "Grok Bot" is saved means that contact, not a second route.
           !((try? AgentPeerStore(dataRoot: root).list()) ?? []).contains(where: { $0.name.localizedCaseInsensitiveContains(name) }) {
            return try await connectThenMessage(row: row, input: input, surface: surface)
        }
        if Self.canonical(tool) == "bot_run_once", let root = peerDataRoot,
           let scope = ChatToolSessionContext.verifiedSessionId ?? conversationScope, !scope.isEmpty {
            return try await BotRunConversation.dispatch(input: input, surface: surface, scope: scope, dataRoot: root) { _, input in
                try await self.dispatchExact(tool: tool, input: input, surface: surface)
            }
        }
        // `wait` on a contact watches its conversation, not the screen (walk
        // 09-25: waiting on OMP was refused as "my own app"). It reads nothing
        // itself; what it returns is agent_read's, through agent_read's gates.
        // agent_read's own wait_seconds is the same wait, with no Full Mac
        // gate in front of it (09-26: `wait` is a Full Mac read tool).
        // Models fill optional fields with "" (Maps walk 09-26: a screen wait
        // with agent "" was refused as "Name the contact"): blank is absent.
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
        if waitsOnRead, input.contains(where: { !blank($0.value) && !["agent", "conversation", "conversation_id", "message_id", "task_id", "details", "session_id", "__session_id"].contains($0.key) }) {
            throw ToolFailureError("wait_seconds accepts only agent, conversation, conversation_id, message_id, task_id and details. Use max_chars or history/listing filters in a separate read without wait_seconds.",
                                   argumentPath: "wait_seconds",
                                   accepted: "app {action:\"agent.read\",args:{agent:\"<contact>\",wait_seconds:60}}", effects: .none)
        }
        if (Self.canonical(tool) == "wait" && input["agent"] != nil) || waitsOnRead {
            guard let root = peerDataRoot, let scope = ChatToolSessionContext.verifiedSessionId ?? conversationScope, !scope.isEmpty else {
                if waitsOnRead { throw AgentConversationStore.Failure(message: "wait_seconds needs this chat's conversation, which this call does not have. Nothing was read.") }
                return try await dispatchExact(tool: tool, input: input, surface: surface)
            }
            var named = try namingSavedContact("agent_read", input)
            if waitsOnRead { named["seconds"] = readWait }
            return try await AgentConversationSession.waitForReply(input: named, scope: scope, dataRoot: root, admit: waitsOnRead) { tool, input in
                try await self.dispatchNormalized(tool: tool, input: input, surface: surface)
            }
        }
        // A repair's dry run is no exchange of hers: no thread, no record.
        if !AgentConversationContext.isInternalRead, !AgentRecipeStore.dryRun,
           ["agent_message", "agent_read", "agent_cancel"].contains(tool), let root = peerDataRoot,
           let scope = ChatToolSessionContext.verifiedSessionId ?? conversationScope, !scope.isEmpty {
            return try await AgentConversationSession.dispatch(tool: tool, input: input, surface: surface,
                scope: scope, dataRoot: root) { tool, input in
                    try await AgentConversationContext.$isInternalRead.withValue(true) {
                        try await self.dispatch(tool: tool, input: input, surface: surface)
                    }
                }
        }
        return try await dispatchExact(tool: tool, input: input, surface: surface)
    }

    /// Connect by name, then send the message to the saved contact in the same
    /// call. Not connected afterwards: the connect's own answer, and nothing sent.
    private func connectThenMessage(row: AgentHostRow, input: [String: JSONValue], surface: String) async throws -> JSONValue {
        var request: [String: JSONValue] = ["name": .string(row.displayName)]
        for key in ["session_id", "__session_id"] { request[key] = input[key] }
        var connect: [String: JSONValue]
        do {
            let result = try await dispatch(tool: "agent_connect", input: request, surface: surface)
            if case .object(let fields) = result { connect = fields } else { connect = ["result": result] }
        } catch {
            connect = ["status": .string("failed"), "detail": .string(ChatToolOutcome.errorMessage(error))]
        }
        // Send only to the contact this connect made or confirmed, never to
        // another saved peer that happens to share a name.
        var handle: String?
        if case .string(let status)? = connect["status"], ["configured", "connected", "already_configured", "set up"].contains(status) {
            if case .object(let contact)? = connect["contact"], case .string(let agent)? = contact["agent"] { handle = agent }
            else if status == "set up", let root = peerDataRoot,
                    let peer = ((try? AgentPeerStore(dataRoot: root).list()) ?? []).first(where: {
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
        var result = try await dispatchNormalized(tool: "agent_message", input: named, surface: surface)
        if case .object(var fields) = result {
            fields["connected_first"] = .object(["status": connect["status"] ?? .string("unknown"),
                                                 "detail": connect["detail"] ?? connect["state_detail"] ?? .null])
            result = .object(fields)
        }
        return result
    }

    private func dispatchExact(tool: String, input: [String: JSONValue], surface: String) async throws -> JSONValue {
        let route: AgentConversationRouting.Route?
        do { route = try AgentConversationRouting.route(tool: tool, input: input, dataRoot: peerDataRoot) }
        catch let error as AgentConversationRouting.InvalidRequest {
            throw ToolFailureError(error.message, argumentPath: "args",
                accepted: tool == "agent_read"
                    ? "app {action:\"agent.read\",args:{agent:\"<contact>\",message_id:\"<receipt message_id>\"}}"
                    : "app {action:\"agent.message\",args:{agent:\"<contact>\",text:\"<message>\"}}; options.timeout_seconds is OMP only", effects: .none)
        }
        if let route {
            let result = try await inner.dispatch(tool: route.tool, input: route.input, surface: surface)
            return AgentConversationRouting.wrap(result: result, route: route, input: input)
        }
        return try await inner.dispatch(tool: Self.canonical(tool), input: input, surface: surface)
    }

    public func listAvailableTools() async throws -> [String] {
        try await inner.listAvailableTools()
    }

    public func listAvailableToolSchemas(named names: Set<String>) async throws -> [LLMToolSchema] {
        try await inner.listAvailableToolSchemas(named: names)
    }

    public func listAvailableToolSchemas() async throws -> [LLMToolSchema] {
        try await inner.listAvailableToolSchemas()
    }
}

extension ApprovedChatToolReplay {
    package func matches(
        tool: String,
        surface: String,
        input: [String: JSONValue],
        verifiedSessionID: String?
    ) -> Bool {
        // 2026-09-06: the executor builds this from the PERSISTED tool name
        // (`save.skill`), and the outer canonicalizer rewrites the dispatched
        // name (`save_skill`) before this comparison — a pre-upgrade dotted
        // approval was consumed and then rejected. Compare canonical names.
        !approvalID.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            && CanonicalToolNameDispatcher.canonical(self.tool)
                == CanonicalToolNameDispatcher.canonical(tool)
            && self.surface == surface
            && self.input == input
            && self.verifiedSessionID == verifiedSessionID
            && verifiedChatID == ChatToolSessionContext.verifiedChatId
            && verifiedUserID == ChatToolSessionContext.verifiedUserId
    }
}
