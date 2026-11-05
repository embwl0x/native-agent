import AgentWorkspace
import ChatToolParsing
import AuthoredCapabilities
#if canImport(AppKit)
import AppKit
#endif
import Foundation
import NativeAgentShared
import TrustCenter
import ApprovalInbox
import NativeAgentCore
import PersistenceCore
import PersonaEngine
import StandingBots
import ProviderRouting
import Darwin
import CryptoKit
import MemoryV2
import Dispatcher
import MacControl
import SwarmRuns
import MacIntegration
import TurnTrace
// Blueprint: | `AgentContactCancellation.swift` | Contact transport cancellation and unknown outcomes |
extension SwiftToolDispatcher {
    func agentCancel(invocation: ChatToolInvocation, _ args: [String: JSONValue], store: AgentPeerStore) async throws -> JSONValue {
        try Self.peerKeys(args, allowed: ["agent", "conversation_id", "message_id", "task_id"])
        let agent = try Self.peerString(args, "agent", max: 64)!
        func answer(_ status: String, _ detail: String = "") -> JSONValue {
            .object(["status": .string(status), "agent": .string(agent), "detail": .string(detail)])
        }
        guard agent.hasPrefix("peer:"), let peer = try store.list().first(where: { "peer:" + $0.id == agent }) else {
            return answer("not_here")
        }
        // Only this app's own run of the agent's ability can be stopped.
        if peer.ability != nil { return answer("not_here") }
        switch peer.transport {
        case .acp:
            let conversation = try Self.peerString(args, "conversation_id", max: 1024, required: false)
            guard await AgentACPConnections.shared.cancelTurn(peer: peer.id, conversation: conversation) else { return answer("not_here") }
            return answer("stopping", """
                Asked \(peer.name) to stop (ACP session/cancel). Its turn ends as cancelled and the session stays open for your next message.
                """)
        case .a2a:
            guard let task = try Self.peerString(args, "task_id", max: 512, required: false) else { return answer("not_here") }
            return await a2aCancel(invocation: invocation, peer: peer, task: task, agent: agent)
        case .desktop, .desktopChat, .grokBot:
            return answer("cannot_stop", "\(peer.name) has no stop from here; its answer still arrives.")
        default:
            // A command-line host or another NativeAgent: only the send this app is running.
            return answer("not_here")
        }
    }
    private func a2aCancel(invocation: ChatToolInvocation, peer: AgentPeerContact, task: String, agent: String) async -> JSONValue {
        var token: String?
        func answer(_ status: String, _ detail: String, task result: JSONValue? = nil, peerAuthored: Bool = false) -> JSONValue {
            var fields: [String: JSONValue] = ["status": .string(status), "agent": .string(agent), "detail": .string(detail), "task_id": .string(task)]
            if let result { fields["task"] = result }
            if peerAuthored { fields["untrusted_remote_data"] = .bool(true) }
            return Self.peerRedact(.object(fields), token: token)
        }
        do {
            guard peer.credentialKey == nil || usesCanonicalBody else { return answer("cannot_stop",
                "This contact's credential is unavailable here, so no stop was sent.") }
            token = peer.credentialKey == nil ? nil : try AgentPeerCredentials.read(peerID: peer.id)
            let card = try await AgentPeerHTTP.get(peer.endpoint, bearerToken: token)
            guard (200..<300).contains(card.statusCode), let json = card.json else {
                return answer("cannot_stop", """
                    \(peer.name)'s agent card did not load (HTTP \(card.statusCode)), so no stop was sent; its reply may still arrive.
                    """)
            }
            let selected = try await AgentPeerDiscovery.authenticatedInterface(conversation: invocation.conversation, card: json, cardURL: peer.endpoint,
                bearerToken: token).0
            let request = try AgentA2AWire.cancelRequest(taskID: task, interface: selected)
            let response = try await AgentPeerHTTP.send(conversation: invocation.conversation, request, bearerToken: token)
            guard (200..<300).contains(response.statusCode), let payload = response.json else {
                return answer("cannot_stop", "\(peer.name) did not accept the stop (HTTP \(response.statusCode)); its reply may still arrive.")
            }
            let result = try AgentA2AWire.normalizeResponse(payload, interface: selected,
                                                            expectedRequestID: request.requestID, expectedTaskID: task)
            let summary: JSONValue = .object(["state": .string(result.state), "terminal": .bool(result.terminal)])
            if result.state == "canceled" { return answer("stopped", "\(peer.name) cancelled the task.", task: summary) }
            if result.terminal { return answer("cannot_stop", "The task had already ended (\(result.state)) before the stop.", task: summary) }
            return answer("stopping", "\(peer.name) accepted the stop; the task is \(result.state) and settles when it ends.", task: summary)
        } catch let failure as ToolFailureError {
            var receipt = ChatToolOutcome.failure(error: failure, tool: "agent_cancel")
            if case .object(var fields) = receipt {
                fields["status"] = .string("cannot_stop")
                fields["agent"] = .string(agent); fields["task_id"] = .string(task)
                fields["stop_sent"] = .bool(false); fields["reply_may_arrive"] = .bool(true)
                receipt = .object(fields)
            }
            return Self.peerRedact(receipt, token: token)
        } catch AgentA2AWire.WireError.remote(let code, let message) {
            return answer("cannot_stop", "\(peer.name) refused the stop (\(code): \(message)); its reply may still arrive.", peerAuthored: true)
        } catch {
            return answer("cannot_stop", "The stop could not be sent: \(error.localizedDescription). The reply may still arrive.", peerAuthored: true)
        }
    }
    /// All command contacts use the shell's Trust gate, sandbox and audit; the adapter reads the declared contract without agent-specific branches. Closed
    /// stdin prevents waiting for user input; isolated cwd and tainted CLI output keep peer work confined and untrusted.
}
