import AgentWorkspace
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
    func agentCancel(_ args: [String: JSONValue], store: AgentPeerStore) async throws -> JSONValue {
        try Self.peerKeys(args, allowed: ["agent", "conversation_id", "message_id", "task_id"])
        let agent = try Self.peerString(args, "agent", max: 64)!
        func answer(_ status: String, _ detail: String = "") -> JSONValue {
            .object(["status": .string(status), "agent": .string(agent), "detail": .string(detail)])
        }
        if let door = AgentConversationDelivery.door(for: agent, dataRoot: dataRoot, bridgeConfigRoot: agentBridgeConfigRoot), !door.liveReader {
            guard let message = try Self.peerString(args, "message_id", max: 160, required: false) else {
                return answer("cannot_stop", "No accepted message is recorded for this reply, so there is nothing exact to stop.")
            }
            return await builtInStop(agent: door.handle, messageID: message)
        }
        guard agent.hasPrefix("peer:"), let peer = try store.list().first(where: { "peer:" + $0.id == agent }) else {
            return answer("not_here")
        }
        // Only this app's own run of her ability can be stopped.
        if peer.ability != nil { return answer("not_here") }
        switch peer.transport {
        case .acp:
            let conversation = try Self.peerString(args, "conversation_id", max: 1024, required: false)
            guard await AgentACPConnections.shared.cancelTurn(peer: peer.id, conversation: conversation) else { return answer("not_here") }
            return answer("stopping", "Asked \(peer.name) to stop (ACP session/cancel). Its turn ends as cancelled and the session stays open for your next message.")
        case .a2a:
            guard let task = try Self.peerString(args, "task_id", max: 512, required: false) else { return answer("not_here") }
            return await a2aCancel(peer: peer, task: task, agent: agent)
        case .desktop, .desktopChat, .grokBot:
            return answer("cannot_stop", "\(peer.name) has no stop from here; its answer still arrives.")
        default:
            // A command-line host or another NativeAgent: only the send this app is running.
            return answer("not_here")
        }
    }
    /// A2A CancelTask on the exact task the conversation is waiting on.
    private func a2aCancel(peer: AgentPeerContact, task: String, agent: String) async -> JSONValue {
        var token: String?
        func answer(_ status: String, _ detail: String, task result: JSONValue? = nil, peerAuthored: Bool = false) -> JSONValue {
            var fields: [String: JSONValue] = ["status": .string(status), "agent": .string(agent), "detail": .string(detail), "task_id": .string(task)]
            if let result { fields["task"] = result }
            if peerAuthored { fields["untrusted_remote_data"] = .bool(true) }
            return Self.peerRedact(.object(fields), token: token)
        }
        do {
            guard peer.credentialKey == nil || usesCanonicalBody else { return answer("cannot_stop", "This contact's credential is unavailable here, so no stop was sent.") }
            token = peer.credentialKey == nil ? nil : try AgentPeerCredentials.read(peerID: peer.id)
            let card = try await AgentPeerHTTP.get(peer.endpoint, bearerToken: token)
            guard (200..<300).contains(card.statusCode), let json = card.json else {
                return answer("cannot_stop", "\(peer.name)'s agent card did not load (HTTP \(card.statusCode)), so no stop was sent; its reply may still arrive.")
            }
            let selected = try await AgentPeerDiscovery.authenticatedInterface(card: json, cardURL: peer.endpoint, bearerToken: token).0
            let request = try AgentA2AWire.cancelRequest(taskID: task, interface: selected)
            let response = try await AgentPeerHTTP.send(request, bearerToken: token)
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
    /// Codex: app-server `turn/interrupt` on the exact turn. OMP: its wake run
    /// is stopped, so the runner itself records how
    /// it ended and the answer path settles as usual.
    private func builtInStop(agent: String, messageID: String) async -> JSONValue {
        @Sendable func answer(_ status: String, _ detail: String) -> JSONValue {
            .object(["status": .string(status), "agent": .string(agent), "message_id": .string(messageID), "detail": .string(detail)])
        }
        let name = agent == "omp" ? "OMP" : "Codex"
        if agent == "codex" {
            let job = DelegationStatusProjector(configRoot: agentBridgeConfigRoot, dataRoot: dataRoot)
                .readSnapshot(now: Date(), limit: 1, offset: 0, agent: "codex", messageID: messageID).jobs.first
            if job?.stallBasis == .terminal { return answer("cannot_stop", "Codex already finished that turn; its answer is on the way.") }
            guard let thread = job?.recordedThreadID, let turn = job?.recordedTurnID,
                  let helper = AgentBridgeRuntime.codexHelperURL(dataRoot: dataRoot),
                  let input = try? JSONValue.object(["interrupt": .bool(true), "threadId": .string(thread), "turnId": .string(turn)]).serializedData(pretty: false) else {
                return answer("cannot_stop", "Codex has not started a turn for it yet (it is queued behind other Codex work), so there is no turn to interrupt.")
            }
            let cwd = Self.builderSourceRepoRoot(dataRoot: dataRoot) ?? NativeAgentWorkspaceRoot.resolve(dataRoot: dataRoot)
            let receipt = await runAgentWakeupHelper(helper: helper, inputData: input, cwd: cwd, cli: "codex", variable: "CODEX_BIN",
                                                     timeout: Self.codexWakeupHelperTimeoutSeconds())
            guard case .object(let fields) = receipt, fields["status"] == .string("interrupted") else {
                let why: String = if case .object(let fields) = receipt, case .string(let text)? = fields["error"] ?? fields["reason"] { text } else { "no receipt" }
                return answer("cannot_stop", "Codex did not take the interrupt (\(why)); its reply may still arrive.")
            }
            return answer("stopping", "Asked Codex to interrupt its turn (turn/interrupt); the conversation settles when the turn ends.")
        }
        let directory = Self.bridgeConfigDirectory(named: "omp-bridge", configRootOverride: agentBridgeConfigRoot)
        let safe = String(messageID.map { $0.isLetter && $0.isASCII || $0.isNumber && $0.isASCII || "._-".contains($0) ? $0 : "_" }.prefix(160))
        guard let data = try? Data(contentsOf: directory.appendingPathComponent("wake-jobs/" + safe + ".json")),
              case .object(let job)? = try? JSONValue.parse(data) else {
            return answer("cannot_stop", "No wake run is recorded for that message, so there is nothing to interrupt.")
        }
        let state: String = if case .string(let value)? = job["state"] { value } else { "" }
        guard state == "running" else {
            return answer("cannot_stop", ["settled", "delivering"].contains(state)
                ? "\(name) already finished that run; its answer is on the way."
                : "\(name) has not started that run yet (\(state.isEmpty ? "unknown" : state)), so there is nothing to interrupt.")
        }
        // The runner recorded its own start identity (wake_worker_common's
        // processStartIdentity: ps lstart+command, hashed). A reused pid, even
        // another run of the same helper, never matches it.
        guard case .int(let number)? = job["runnerPid"], let pid = Int32(exactly: number), pid > 1,
              case .string(let recorded)? = job["runnerIdentity"], !recorded.isEmpty else {
            return answer("cannot_stop", "\(name)'s run did not record its process identity, so it is not safe to interrupt from here.")
        }
        guard AgentBridgeRuntime.processStartIdentity(pid) == recorded else {
            return answer("cannot_stop", "\(name)'s run is no longer live on this Mac, so there is nothing to interrupt.")
        }
        // Only the run's own children (the agent CLI), never the runner: it
        // records the interrupted exit and settles the job like any other end.
        let tree = ProcessTreeReaper.snapshot(rootPID: pid)
        let children = ProcessTreeSnapshot(rootPID: pid, rootIdentity: nil, descendants: tree.descendants)
        guard !children.descendants.isEmpty else {
            return answer("cannot_stop", "\(name)'s run has no agent process to interrupt right now.")
        }
        return await settle {
            ProcessTreeReaper.quiesceAndKill(children)
            return answer("stopped", "Stopped \(name)'s agent process. Its runner retains any output and records the run's end.")
        }
    }
    /// A MESSAGE GOES OUT AND A MESSAGE COMES BACK, IN THE SAME CALL.
    ///
    /// The only command-line adapter there is. It reads the row — executable
    /// name, argument template, whether the CLI documents a resume flag — and
    /// nothing here branches on which agent that row describes. The run is an
    /// ordinary command on this Mac and takes the ordinary path for one: the
    /// same Full Mac file_ops gate as `shell`, the same sandbox-profiled
    /// runner, the same audit receipt. No new authority, and the person's
    /// trust posture decides exactly as it does for any shell command.
    ///
    /// Its working directory is a fresh empty directory of its own, stdin is
    /// closed so nothing can block waiting for a person, and the reply is the
    /// CLI's own output — untrusted remote data, marked so, like every other
    /// transport here.
}
