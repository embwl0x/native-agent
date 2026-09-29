import AgentWorkspace
import Foundation
import ApprovalInbox
import CryptoKit
import NativeAgentCore
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

    /// Usable builder lanes retain their bare names; otherwise a saved contact owns its name.
    private func namingSavedContact(_ tool: String, _ input: [String: JSONValue]) throws -> [String: JSONValue] {
        guard ["agent_message", "agent_read", "agent_cancel"].contains(tool), let root = peerDataRoot,
              case .string(let agent)? = input["agent"], !agent.contains(":")
        else { return input }
        var input = input
        let name = agent.trimmingCharacters(in: .whitespacesAndNewlines)
        let lane = name.lowercased() == "claude" ? "claude" : name.lowercased()
        if builtInLanes?.builtInAgentLaneUsable(lane) == true {
            input["agent"] = .string(lane)
            return input
        }
        var matches = try AgentPeerStore(dataRoot: root).list().filter {
            $0.name.caseInsensitiveCompare(name) == .orderedSame
        }.map { "peer:" + $0.id }
        matches += try BotDefinitionStore(dataRoot: root).list().filter {
            $0.name.caseInsensitiveCompare(name) == .orderedSame
        }.map { "bot:" + $0.id.uuidString }
        guard matches.count <= 1 else {
            throw AgentConversationStore.Failure(message: "More than one contact is named \(name). Choose its exact contact from agent_contacts.")
        }
        if let exact = matches.first { input["agent"] = .string(exact) }
        else if ["codex", "claude", "omp"].contains(lane) { input["agent"] = .string(lane) }
        return input
    }

    /// The one alias table (`ToolNameAliases`) over the built-in catalog —
    /// the same resolution `SwiftToolDispatcher.dispatch` applies downstream.
    /// Unknown names stay unknown.
    public static func canonical(_ name: String) -> String {
        ToolNameAliases.canonical(name) { SwiftToolDispatcher.nativeCanonicalToolNames.contains($0) }
    }

    public func dispatch(tool: String, input: [String: JSONValue], surface: String) async throws -> JSONValue {
        try await AgentWorkspacePorts.$binding.withValue(ChatWorkspaceBinding.ports) {
            try await dispatchWithWorkspacePorts(tool: tool, input: input, surface: surface)
        }
    }

    private func dispatchWithWorkspacePorts(tool: String, input: [String: JSONValue], surface: String) async throws -> JSONValue {
        let result = try await inner.withToolArguments(tool: Self.canonical(tool), input: input) { input in
            try await CraftToolContext.$dispatch.withValue({ name, arguments in
                try await self.dispatch(tool: name, input: arguments, surface: surface)
            }) {
                try await dispatchNormalized(tool: tool, input: input, surface: surface)
            }
        }
        // A released Chrome tab leaves her screen's windows and home too.
        if case .object(let fields) = result, fields["tool"] == .string("browser.chrome_release"),
           fields["released"] == .bool(true), case .string(let lease)? = fields["leaseId"], let root = peerDataRoot,
           let scope = ChatToolSessionContext.verifiedSessionId ?? conversationScope, !scope.isEmpty {
            let tab: Int64? = if case .int(let id)? = fields["tabId"] { id } else { nil }
            await AgentWorkspaceNavigation.shared.forgetTab(lease: lease, tabID: tab,
                                                            key: root.standardizedFileURL.path + "\u{0}" + scope)
        }
        // Attach to structured owner results so every provider lane receives
        // the same replayable receipt, without altering scalar/file contents,
        // adding synthetic chat turns, or changing the cached prompt prefix.
        // The person's own thread send has no agent reading its result, so it
        // must not use up her arrival notices.
        guard !AgentWorkspaceArrivals.insideWorkspaceDispatch, PersonInitiatedSend.current == nil,
              case .object(var fields) = result,
              fields["workspace_arrivals"] == nil,
              let notice = await AgentWorkspaceArrivals.pending(dataRoot: peerDataRoot,
                scope: ChatToolSessionContext.verifiedSessionId ?? conversationScope) else { return result }
        fields["workspace_arrivals"] = notice
        return .object(fields)
    }

    private func dispatchNormalized(tool: String, input: [String: JSONValue], surface: String) async throws -> JSONValue {
        if Self.canonical(tool) == "workspace" {
            guard let root = peerDataRoot,
                  let scope = ChatToolSessionContext.verifiedSessionId ?? conversationScope, !scope.isEmpty else {
                return .object(["status": .string("unavailable"), "message": .string("Workspace needs a verified chat session. No action was performed.")])
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
            // Phase 3: opening a place loads its whole tool group, so her next
            // call needs no tool_load round trip. Loading grants nothing; every
            // call still clears its own gates.
            let key = root.standardizedFileURL.path + "\u{0}" + scope
            if let group = await AgentWorkspaceNavigation.shared.currentToolGroup(key: key) {
                _ = try? await dispatchExact(tool: "tool_load", input: ChatToolSessionInjection.apply(
                    toolName: "tool_load", input: ["category": .string(group)], sessionId: scope), surface: surface)
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
        if tool == "agent_message", PersonInitiatedSend.current == nil,
           case .string(let name)? = input["agent"], !name.contains(":"),
           !["codex", "claude", "omp", "claude"].contains(name.lowercased()),
           let row = AgentHostDirectory.row(named: name), let root = peerDataRoot,
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
        let waitsOnRead: Bool = switch readWait { case .int(let n)?: n > 0; case .double(let n)?: n > 0; default: false }
        if waitsOnRead, input.contains(where: { !blank($0.value) && !["agent", "conversation", "details", "session_id", "__session_id"].contains($0.key) }) {
            throw AgentConversationStore.Failure(message: "wait_seconds waits on a conversation by name; it cannot be combined with exact ids, history or listing filters. Nothing was read.")
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
        if !AgentConversationContext.isInternalRead,
           ["agent_message", "agent_read", "agent_cancel"].contains(tool), let root = peerDataRoot,
           let scope = ChatToolSessionContext.verifiedSessionId ?? conversationScope, !scope.isEmpty {
            return try await AgentConversationSession.dispatch(tool: tool, input: input, surface: surface,
                scope: scope, dataRoot: root) { tool, input in
                    try await self.dispatchExact(tool: tool, input: input, surface: surface)
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
        if let route = try AgentConversationRouting.route(tool: tool, input: input) {
            let alias = GatedToolNameAlias(raw: tool, canonical: route.tool)
            return try await GatedToolNameContext.$alias.withValue(alias) {
                let result = try await inner.dispatch(tool: route.tool, input: route.input, surface: surface)
                return AgentConversationRouting.wrap(result: result, route: route, input: input)
            }
        }
        let canonical = Self.canonical(tool)
        // 2026-09-06: canonicalizing before the gates threw away the spelling
        // the caller used, and the Trust Center matches override/block keys
        // against the name it is given — so a user's `"save.skill": "blocked"`
        // stopped applying. Carry the raw spelling down the chain so the policy
        // gates can judge both and keep the stricter answer. Bound even when
        // nothing was rewritten (as nil) so a nested dispatch cannot inherit a
        // stale alias.
        //
        // 2026-09-06: except when the alias already describes THIS dispatch.
        // The bridge wraps a gated client that begins with a canonicalizer of
        // its own, so the inner one is handed the canonical name, rewrites
        // nothing, and used to bind nil — erasing the raw spelling the outer
        // wrapper captured before the gates in between could read it. An
        // inherited alias whose canonical name is exactly the name we were
        // handed is this call's own alias; carry it through. Anything else is
        // a stale alias from an enclosing dispatch and still clears.
        let alias: GatedToolNameAlias?
        if canonical != tool {
            alias = GatedToolNameAlias(raw: tool, canonical: canonical)
        } else if let inherited = GatedToolNameContext.alias,
                  inherited.canonical.trimmingCharacters(in: .whitespaces)
                      == canonical.trimmingCharacters(in: .whitespaces) {
            alias = inherited
        } else {
            alias = nil
        }
        return try await GatedToolNameContext.$alias.withValue(alias) {
            try await inner.dispatch(tool: canonical, input: input, surface: surface)
        }
    }

    public func listAvailableTools() async throws -> [String] {
        try await inner.listAvailableTools()
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
