import Foundation
import ChatOrchestration

/// The chat and tool clients an engine root builds for its agent contacts.
public protocol AgentContactClients: Sendable {
    /// Peer, A2A and Grok turns, and a delegate's notice (the bridge profile).
    func bridgeChatClient() -> SwiftNativeChatOrchestrationClient
    /// A bot's requested check and an explicit human reply (the background profile).
    func backgroundChatClient() -> SwiftNativeChatOrchestrationClient
    /// The desktop operator's short turn over its own fenced tools.
    func chatClient(tools: any ToolDispatchClient, toolLoopMaxIterations: Int?,
                    turnWallClockSeconds: TimeInterval?) -> SwiftNativeChatOrchestrationClient
    /// The app tool chain a queued follow-up is sent through.
    func toolDispatchClient(denyExternalMcp: Bool, enforceAppAutonomy: Bool) -> any ToolDispatchClient
    /// The raw bridge tool chain a contact's reply is read through.
    func bridgeToolDispatchClient(fileAccess: String, verifiedSessionId: String?) -> any ToolDispatchClient
}

/// One engine root's agent contacts: the retained A2A tasks every peer door
/// shares, the desktop send route, explicit human replies, Grok's inbound
/// answers, and the continuation that brings a contact's reply, a bot's
/// result or a delegate's stall back to the chat that asked.
public final class AgentContacts: Sendable {
    public let tasks: AgentContactTasks
    public let desktop: DesktopAgentConversationRoute
    public let humanReplies: HumanConversationReplyService
    public let grok: GrokInboundReply
    public let continuation: AgentConversationContinuation

    public init(dataRoot: URL, clients: any AgentContactClients, completionSender: any AgentBridgeCompletionSending) {
        tasks = AgentContactTasks(dataRoot: dataRoot) { turn, emit in
            try await AgentContactRuntime.run(turn, client: clients.bridgeChatClient(), dataRoot: dataRoot, emit: emit)
        }
        desktop = DesktopAgentConversationRoute(clients: clients)
        humanReplies = HumanConversationReplyService(dataRoot: dataRoot, sender: completionSender) { id, expected, text, run in
            let client = clients.backgroundChatClient()
            try await client.appendHumanConversationReply(sessionID: id, expectedLastMessageID: expected,
                                                          text: text, runID: run)
        }
        grok = GrokInboundReply(clients: clients)
        continuation = AgentConversationContinuation(dataRoot: dataRoot, clients: clients, grok: grok,
                                                     completionSender: completionSender)
    }
}
