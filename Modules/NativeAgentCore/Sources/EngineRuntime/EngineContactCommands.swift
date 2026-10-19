import ChatOrchestration
import Foundation
import Agents
import Cognition
import ContextFlow
import GitHubConnector
import GrokLink
import PersonaEngine
import PersistenceCore

/// The person's own message to a contact, from its thread: the same
/// agent_message machinery the agent uses (peer resolution, transports,
/// receipts, AgentConversationStore), through the same gated chain, marked as
/// the person's by `PersonInitiatedSend`. This is the only place that mark is
/// made, and only a composer click or Return reaches it.
extension NativeAgentEngine {
    /// Nil when the message went; otherwise why not, in plain words.
    public func sendContactMessage(agent: String, text: String, session: String, root: URL, conversation: String? = nil) async -> String? {
        let tools = toolDispatchClient(enforceAppAutonomy: false)
        // No approval filer: nothing here can raise a card the thread can't show.
        let chain = makeGatedToolDispatchClient(tools: tools, fileAccess: "auto", dataRoot: root, verifiedSessionId: session)
        var input: [String: JSONValue] = ["agent": .string(agent), "text": .string(text)]
        if let conversation { input["conversation"] = .string(conversation) }
        let sendInput = input
        do {
            let result = try await PersonInitiatedSend.$current.withValue(PersonInitiatedSend(agent: agent, text: text)) {
                try await ChatToolSessionContext.$verifiedSessionId.withValue(session) {
                    try await chain.dispatch(tool: "agent_message",
                        input: sendInput, surface: "chat")
                }
            }
            guard case .object(let fields) = result else { return "Nothing came back from the send." }
            // Queued behind the reply in progress: accepted, it goes by itself.
            if fields["queued"] == .bool(true) { return nil }
            if fields["sent"] == .bool(true), fields["state"] != .string("attention") { return nil }
            if case .string(let detail)? = fields["detail"], !detail.isEmpty { return detail }
            return "The send wasn't confirmed."
        } catch {
            return error.localizedDescription
        }
    }

    /// The person's Stop on the reply in flight: `agent_cancel` through the
    /// same chain. Nil when the thread recorded the stop (stopping, stopped,
    /// released, cannot_stop or finished; shown from the record); otherwise why not.
    public func stopContactMessage(agent: String, conversation: String, session: String, root: URL) async -> String? {
        let tools = toolDispatchClient(enforceAppAutonomy: false)
        let chain = makeGatedToolDispatchClient(tools: tools, fileAccess: "auto", dataRoot: root, verifiedSessionId: session)
        do {
            let result = try await ChatToolSessionContext.$verifiedSessionId.withValue(session) {
                try await chain.dispatch(tool: "agent_cancel",
                    input: ["agent": .string(agent), "conversation": .string(conversation)], surface: "chat")
            }
            guard case .object(let fields) = result else { return "Nothing came back from the stop." }
            if fields["stop_state"] != nil { return nil }
            if case .string(let detail)? = fields["detail"], !detail.isEmpty { return detail }
            return "The stop didn't go through."
        } catch {
            return error.localizedDescription
        }
    }

    /// Takes a held message off its thread once it has been sent again.
    public func withdrawContactMessage(_ item: String, record: String, root: URL) async {
        await Task.detached(priority: .userInitiated) {
            let store = AgentConversationStore(dataRoot: root)
            guard let row = try? store.records().first(where: { $0.id == record }) else { return }
            _ = try? store.update(id: record, operationID: row.operationID, touch: false) {
                $0.queued?.removeAll { $0.id == item && $0.held != nil }
                if $0.queued?.isEmpty == true { $0.queued = nil }
            }
        }.value
    }
}

extension NativeAgentEngine {
    public static func makeAgentBridge(engine: @escaping @Sendable () -> NativeAgentEngine,
                                        grpcPort: @escaping @Sendable () -> UInt16?,
                                        gitHubCommand: @escaping @Sendable () -> GitHubCommandRuntime) -> ClaudeBridgeRuntime {
        ClaudeBridgeRuntime(port: EngineClaudeBridgePort(engine: engine, readGRPCPort: grpcPort, gitHubCommand: gitHubCommand))
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
    let gitHubCommand: @Sendable () -> GitHubCommandRuntime
    var dataRoot: URL { engine().dataRoot }
    var cognition: NativeCognitionRuntime { engine().cognition! }
    var contextFlow: NativeContextFlowRuntime { engine().contextFlow }
    var tasks: AgentContactTasks { engine().agents.tasks }
    var grpcPort: UInt16? { readGRPCPort() }
    var preferredPersona: String? { PersonaSelection.current() }
    var preferredSessionID: String? { UserDefaults.standard.string(forKey: "activeChatSessionId") }
    func chatClient() -> any ChatOrchestrationClient { engine().chatClient(profile: .bridge) }
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
    func handleCodexCompletion(messageIds: [String], codexStatus: String, summary: String,
                               threadId: String?, turnId: String?, errorMessage: String?, noWorkObserved: Bool?) async {
        await gitHubCommand().handleCodexCompletion(messageIds: messageIds, codexStatus: codexStatus,
            summary: summary, threadId: threadId, turnId: turnId, errorMessage: errorMessage, noWorkObserved: noWorkObserved)
    }
}
