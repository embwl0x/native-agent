import ChatTurnRuntime
import ApprovalTransactions
import ChatTurnContracts
import ChatToolRuntime
import AgentConversations
import AgentWorkspace
import Foundation
import NativeAgentCore
import Agents
import Cognition
import ContextFlow
import PersonaEngine
import PersistenceCore
// Blueprint: | `EngineContactCommands.swift` | Person-initiated sends, original-scope Stop and held-message withdrawal |

/// Only composer click or Return marks `PersonInitiatedSend`; person-authored sends still traverse the shared gated contact machinery.
extension NativeAgentEngine {
    public func sendContactMessage(agent: String, text: String, session: String, root: URL, conversation: String? = nil,
                                   turn: Turn) async -> String? {
        let tools = toolDispatchClient(enforceAppAutonomy: false)
        // No approval filer: this thread cannot show a raised card.
        let chain = makeGatedToolDispatchClient(tools: tools, fileAccess: "auto", dataRoot: root, verifiedSessionId: session)
        var input: [String: JSONValue] = ["agent": .string(agent), "text": .string(text)]
        if let conversation { input["conversation"] = .string(conversation) }
        let sendInput = input
        // The composer or verified phone ingress owns the origin; a shared send never makes it local.
        var turn = turn
        turn.verifiedSessionID = session
        turn.personInitiatedSend = PersonInitiatedSend(agent: agent, text: text)
        do {
            let result = try await chain.dispatch(tool: "agent_message", input: sendInput, surface: "chat", turn: turn, invocation: .init())
            guard case .object(let fields) = result else { return "Nothing came back from the send." }
            // Accepted follow-ups remain queued behind the in-flight reply.
            if fields["queued"] == .bool(true) { return nil }
            if fields["sent"] == .bool(true), fields["state"] != .string("attention") { return nil }
            if case .string(let detail)? = fields["detail"], !detail.isEmpty { return detail }
            return "The send wasn't confirmed."
        } catch {
            return error.localizedDescription
        }
    }

    /// Use the shared cancellation chain; return nil only when the thread records its stop outcome.
    public func stopContactMessage(agent: String, record: String, session: String, root: URL) async -> String? {
        let tools = toolDispatchClient(enforceAppAutonomy: false)
        let chain = makeGatedToolDispatchClient(tools: tools, fileAccess: "auto", dataRoot: root, verifiedSessionId: session)
        var turn = Turn(session: session)
        turn.envelope = .personOnMac("mac_ui:contact.stop")
        turn.verifiedSessionID = session
        do {
            let result = try await chain.dispatch(tool: "agent_cancel",
                input: ["agent": .string(agent), "conversation": .string(record)], surface: "chat", turn: turn, invocation: .init())
            guard case .object(let fields) = result else { return "Nothing came back from the stop." }
            if fields["stop_state"] != nil { return nil }
            if case .string(let detail)? = fields["detail"], !detail.isEmpty { return detail }
            return "The stop didn't go through."
        } catch {
            return error.localizedDescription
        }
    }

    @discardableResult
    public func withdrawContactMessage(_ item: String, record: String, root: URL) async throws -> AgentConversationRecord {
        try await Task.detached(priority: .userInitiated) {
            let store = AgentConversationStore(dataRoot: root)
            guard let row = try store.records().first(where: { $0.id == record }) else {
                throw ToolFailureError("The held message's conversation is unavailable. Preserve its saved record and repair the conversation store.",
                    effects: .none)
            }
            return try store.update(id: record, operationID: row.operationID, touch: false) {
                if let queued = $0.queued?.first(where: { $0.id == item }), queued.held == nil {
                    throw ToolFailureError("The old message is no longer held; its current state was preserved. Read the conversation before changing it.",
                        effects: .none)
                }
                $0.queued?.removeAll { $0.id == item && $0.held != nil }
                if $0.queued?.isEmpty == true { $0.queued = nil }
            }
        }.value
    }
}

extension NativeAgentEngine {
    public static func makeAgentBridge(engine: @escaping @Sendable () -> NativeAgentEngine,
                                        grpcPort: @escaping @Sendable () -> UInt16?) -> ClaudeBridgeRuntime {
        ClaudeBridgeRuntime(port: EngineClaudeBridgePort(engine: engine, readGRPCPort: grpcPort))
    }
    public static func makeA2AListener(engine: @escaping @Sendable () -> NativeAgentEngine,
                                       bridge: @escaping @Sendable () -> ClaudeBridgeRuntime) -> NativeAgentA2AGRPCListener {
        NativeAgentA2AGRPCListener(dataRoot: { engine().dataRoot }, endpoint: { grpcPort in
            AgentContactA2AEndpoint(tasks: engine().agents.tasks, port: bridge().activePort, grpcPort: grpcPort)
        }, liveToken: { bridge().token })
    }
}

private struct EngineClaudeBridgePort: ClaudeBridgeRuntimePort {
    let engine: @Sendable () -> NativeAgentEngine
    let readGRPCPort: @Sendable () -> UInt16?
    var dataRoot: URL { engine().dataRoot }
    var cognition: NativeCognitionRuntime { engine().cognition! }
    var contextFlow: NativeContextFlowRuntime { engine().contextFlow }
    var tasks: AgentContactTasks { engine().agents.tasks }
    var grpcPort: UInt16? { readGRPCPort() }
    var preferredPersona: String? { PersonaSelection.current() }
    var preferredSessionID: String? { UserDefaults.standard.string(forKey: "activeChatSessionId") }
    func chatClient() -> SwiftNativeChatOrchestrationClient { engine().chatClient(profile: .bridge) }
    func toolClient(verifiedSessionID: String?) -> any ToolDispatchClient {
        let engine = engine()
        return engine.bridgeToolDispatchClient(approvalFiler: NativeAgentChatApprovalFiler(dataRoot: engine.dataRoot),
                                               verifiedSessionId: verifiedSessionID)
    }
    func completionSender(dataRoot: URL) -> any AgentBridgeCompletionSending { engine().ports.completionSender(dataRoot) }
    func receiveGrok(_ reply: GrokReplyInput, principal: AgentBridgePrincipal, dataRoot: URL) async throws {
        try await engine().agents.grok.receive(reply, principal: principal, dataRoot: dataRoot,
                                              continuation: engine().agents.continuation)
    }
    func publishChatTurnCompleted(sessionID: String?) async {
        await MainActor.run { NotificationCenter.default.post(name: .chatTurnCompleted, object: sessionID) }
    }
}
