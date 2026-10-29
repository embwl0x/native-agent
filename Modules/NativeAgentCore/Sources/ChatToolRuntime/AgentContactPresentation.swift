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
// Blueprint: | `AgentContactPresentation.swift` | Retained contact and conversation history projection |
extension SwiftToolDispatcher {
    static func recordHostConnectionOutcome(store: AgentPeerStore, contact: AgentPeerContact,
                                             ran: Bool, replied: Bool, probe: Bool,
                                             probeNonce: String? = nil,
                                             executable: String, workspace: String, recipe: AgentRecipeStore.Recipe?) -> Bool {
        let arrived = probe && probeNonce.map {
            store.finishConnectionProbe(peerID: contact.id, nonce: $0, ran: ran, workspace: workspace, recipe: recipe)
        } == true
        store.recordProof(peerID: contact.id, outbound: replied || arrived)
        // Launch alone proves neither delivery nor a broken connection. Only
        // a command that did not launch marks this path unavailable.
        if ran && replied && !probe {
            store.recordRoundTrip(peerID: contact.id, executable: executable, workspace: workspace, recipe: recipe)
        } else if !probe, !ran {
            store.recordUnavailable(peerID: contact.id)
        }
        return arrived
    }
    /// The probe's own reason, so "stays set up" is never a shrug: the command
    /// was missing, the run timed out, or it simply did not answer back.
    static func probeReason(_ probe: JSONValue?, row: AgentHostRow? = nil) -> String {
        let check = row.map { " Checked agents/recipes/\($0.id).json host.commandLine, host.searchPaths and host.configPath=\($0.expandedConfigPath). Run agent.verify, correct the named recipe fields or settings file, then connect. Restart: \($0.restartNote) A message must arrive through this contact's connector to prove it." } ?? ""
        guard case .object(let value)? = probe else { return "No callback probe was recorded." + check }
        if value["reason"] == .string("trust_center_full_mac_required"),
           case .string(let detail)? = value["detail"] { return detail }
        if value["timed_out"] == .bool(true) { return "The probe ran past its time limit." + check }
        if case .string(let detail)? = value["detail"] { return detail + check }
        return "The probe ran and nothing arrived through the entry." + check
    }
    /// Connect owns its entry name: another install's entry there was replaced, and the receipt says so first.
    static func sayReplaced(_ outcome: AgentHostConfigWriter.Outcome, in value: inout [String: JSONValue]) {
        guard let helper = outcome.replacedInstall else { return }
        let note = "Replaced an entry from another install of this app at \(helper); backup at \(outcome.backupPath ?? "none")."
        value["replaced_entry"] = .string(note)
        value["detail"] = .string(note + (value["detail"].flatMap { if case .string(let text) = $0 { " " + text } else { nil } } ?? ""))
    }
    static func includeConnectionProbe(_ probe: JSONValue, in value: inout [String: JSONValue]) {
        value["probe"] = probe
        guard case .object(let fields) = probe,
              fields["reason"] == .string("trust_center_full_mac_required") else { return }
        value["reason"] = fields["reason"]
        value["completed"] = .bool(false)
        value["detail"] = .string(probeReason(probe))
        // A trust refusal says nothing about whether the other app needs a restart.
        value["restart_required"] = nil
    }
    /// A HOST THAT PULLS (no command line). Her message is held in this
    /// conversation and goes out in the result of the host's next call through
    /// its entry (`held_messages`, AgentConversationStore.held); held is not
    /// sent, and the receipt says which. It never reaches for a window.
    static func hostPull(row: AgentHostRow?, contact: AgentPeerContact, text: String?, peers: [AgentPeerContact] = []) -> JSONValue {
        let name = row?.displayName ?? contact.name
        var result: [String: JSONValue] = ["agent": .string("peer:" + contact.id), "transport": .string("mcpHost"),
            "host": .string(row?.id ?? ""), "completed": .bool(false)]
        let presence = AgentContactHealth.checkIn(contact)?.detail ?? ""
        guard let text else {
            result["status"] = .string("nothing_to_read"); result["read"] = .bool(false)
            result["detail"] = .string("\(name)'s answers arrive as its own messages; this conversation's exchanges say which of yours are held and which were delivered, and when. " + presence)
            return .object(result)
        }
        if currentPeerState(contact, peers: peers) == .unavailable {
            result["status"] = .string("unavailable"); result["sent"] = .bool(false)
            result["detail"] = .string(AgentPeerCredentials.unavailableDetail + " Nothing was held: \(name) cannot call in without its key.")
            result["remedy"] = Repair.remedy(owner: "Keychain peer:" + contact.id, nextCall: .object([
                "tool": .string("app"), "input": .object(["action": .string("agent.connect"), "args": .object(["name": .string("peer:" + contact.id)])])]), tap: nil)
            return .object(result)
        }
        // The held copy is the exchange's own prompt; one longer would be clipped.
        guard text.utf8.count <= AgentConversationExchange.textLimit else {
            result["status"] = .string("invalid_arguments"); result["sent"] = .bool(false); result["argument_path"] = .string("text")
            result["detail"] = .string("Nothing was held: a message held for \(name) keeps at most \(AgentConversationExchange.textLimit / 1024) KiB. Send it in parts.")
            return .object(result)
        }
        if AgentRecipeStore.dryRun {
            result["status"] = .string("passed"); result["dry_run"] = .bool(true); result["sent"] = .bool(false)
            result["detail"] = .string("Dry run: a message to \(name) would be held for its next check-in. Nothing was held.")
            return .object(result)
        }
        // Held means kept in a conversation of hers; a send outside one has nowhere to wait.
        guard AgentConversationLiveContext.target != nil else {
            result["status"] = .string("invalid_arguments"); result["sent"] = .bool(false); result["argument_path"] = .string("conversation_id")
            result["detail"] = .string("Nothing was held: a message to \(name) waits in one of your conversations with it. Name the conversation, or omit it for the current one, rather than protocol ids.")
            return .object(result)
        }
        result["status"] = .string("held"); result["delivered"] = .bool(false)
        result["delivery"] = .string("held")
        // The host's own session for this conversation: the session_id it answers in.
        result["conversation_id"] = .string("mcp-" + contact.id)
        result["detail"] = .string("Held, not sent: it waits for \(name)'s next check-in and goes out in the result of that call; nothing is lost. Do not resend. " + presence)
        return .object(result)
    }
    /// One sentence of truth about a closed desktop app: this app can type into
    /// it, and the answer comes back through this app's own inbound door.
    static let desktopSetupNote = "Send-only. For this contact to answer, add this app's MCP server to it (command: nativeagent-link mcp) and have it reply with its agent_message tool; the reply arrives as an ordinary inbound message."
    static let desktopSendOnlyDetail = "Desktop contacts are send-only. Nothing was opened, focused or read. " + desktopSetupNote
    static let hostInboundOnlyDetail =
        "This contact pulls: it has no command line this build knows, and its window is not a transport, so nothing of it is opened or read. "
        + "A message to it is held in the conversation and goes out in the result of its next call through this app's entry "
        + "(any agent_message or agent_reply call); its own messages arrive as ordinary inbound turns."
    static func agentLaneContacts(peers: [AgentPeerContact], selectedPeers: [AgentPeerContact],
                                  readCredential: (String) throws -> String? = { try AgentPeerCredentials.read(peerID: $0) }) -> [JSONValue] {
        let selected = Set(selectedPeers.map { peer in (peers.first { $0.id == peer.who } ?? peer).id })
        return peers.filter { selected.contains($0.id) }.map { who in
            guard case .object(var projection) = peerProjection(who, peers: peers, readCredential: readCredential) else { return .null }
            projection["handles"] = .array((who.handles ?? []).map(JSONValue.string))
            projection["doors"] = .array(peers.filter { $0.id == who.id || $0.who == who.id }.map {
                peerProjection($0, peers: peers, readCredential: readCredential)
            })
            return .object(projection)
        }
    }
    static func currentPeerState(_ peer: AgentPeerContact, peers: [AgentPeerContact]) -> AgentPeerContactState {
        AgentPeerCredentials.isAvailable(peer, peers: peers) ? peer.state : .unavailable
    }
    /// "hermes-agent", "hermes-acp" and "Hermes" name one agent: letters and
    /// digits only, without a trailing agent / acp / cli / bot.
    static func sameAgent(_ a: String, _ b: String) -> Bool {
        func bare(_ name: String) -> String {
            var core = name.lowercased().filter { $0.isLetter || $0.isNumber }
            for suffix in ["agent", "acp", "cli", "bot"] where core.hasSuffix(suffix) && core.count > suffix.count {
                core = String(core.dropLast(suffix.count)); break
            }
            return core
        }
        let x = bare(a), y = bare(b)
        return !x.isEmpty && x == y
    }
    static func compactContact(_ value: JSONValue) -> JSONValue {
        guard case .object(let row) = value else { return value }
        // Workspace Message buttons use these declarations, even on the
        // compact listing; a missing declaration cannot imply permission.
        let keys: Set<String> = ["agent", "name", "state", "last_answered", "capabilities", "can_start_turn"]
        return .object(row.filter { keys.contains($0.key) })
    }
    static func peerProjection(_ peer: AgentPeerContact, peers: [AgentPeerContact] = [],
                                       readCredential: (String) throws -> String? = { try AgentPeerCredentials.read(peerID: $0) }) -> JSONValue {
        guard case .object(var value) = peerHistoryProjection(peer) else { return .null }
        if let ability = peer.ability { value["ability"] = .string(ability) }
        if !AgentPeerCredentials.isAvailable(peer, peers: peers, readCredential: readCredential) {
            value["state"] = .string("unavailable")
            value["state_detail"] = .string(AgentPeerCredentials.unavailableDetail)
            value["readiness"] = .string("unavailable")
            if peer.transport == .mcpHost {
                value["remedy"] = Repair.remedy(owner: "Keychain peer:" + peer.id, nextCall: .object([
                    "tool": .string("app"), "input": .object(["action": .string("agent.connect"), "args": .object(["name": .string("peer:" + peer.id)])])]), tap: nil)
            }
        }
        return .object(value)
    }
    private static func peerHistoryProjection(_ peer: AgentPeerContact) -> JSONValue {
        if peer.transport == .grokBot {
            var value: [String: JSONValue] = ["agent": .string("peer:" + peer.id), "name": .string(peer.name),
                "kind": .string("agent_host"), "transport": .string("grokBot"),
                "state": .string(peer.grokSetup == "set up" && peer.provenInboundAt != nil ? "connected" : peer.grokSetup ?? "set up"),
                "last_message_out": peer.provenOutboundAt.map(JSONValue.string) ?? .null,
                "readiness": .string("not_checked"),
                "can_start_turn": .bool(peer.grokSetup == "set up"), "can_answer_back": .bool(true),
                "capabilities": .array([.string("message"), .string("read")]),
                "read_inputs": .array([.string("message_id")]),
                "state_detail": .string("Webhook acceptance starts a run. Only a correlated local reply is an answer. Grok Bot may ask for local execution approval each time.")]
            if let proof = peer.roundTripProof {
                value["round_trip_proof"] = .object([
                    "route": .string("grokBot"), "at": .string(proof.at),
                    "endpoint": .string(proof.endpoint.absoluteString),
                    "executable": .null, "version": .null, "workspace": .string(proof.workspace)])
            }
            return .object(value)
        }
        // The state, in the same four words everywhere, on every contact.
        var value: [String: JSONValue] = ["agent": .string("peer:" + peer.id), "name": .string(peer.name),
            "can_start_turn": .bool(peer.canStartTurn), "can_answer_back": .bool(peer.canAnswerBack),
            "state": .string(peer.state.rawValue), "state_detail": .string(peer.state.detail)]
        if let workspace = peer.hostWorkspace { value["workspace"] = .string(workspace) }
        // Reply times come from the displayed contact thread at listing time.
        // Route proofs below are historical connection evidence only.
        if let stamp = peer.provenOutboundAt { value["last_message_out"] = .string(stamp) }
        if let proof = peer.roundTripProof {
            value["round_trip_proof"] = .object([
                "route": .string(peer.transport == .acp ? "acp" : peer.transport == .desktop ? "desktop" : proof.executable == nil ? "remote" : "commandLine"),
                "at": .string(proof.at), "endpoint": .string(proof.endpoint.absoluteString),
                "executable": proof.executable.map(JSONValue.string) ?? .null,
                "version": proof.version.map(JSONValue.string) ?? .null,
                "workspace": .string(proof.workspace)])
        }
        if let proof = peer.mcpReturnProof {
            value["mcp_return_proof"] = .object([
                "route": .string(proof.endpoint.absoluteString), "at": .string(proof.at)])
        }
        if let stamp = peer.unavailableAt { value["unavailable_now_checked_at"] = .string(stamp) }
        if peer.transport == .acp {
            value["kind"] = .string("agent_host")
            if peer.state == .setUp {
                value["state_detail"] = .string(!peer.canStartTurn
                    ? "The saved executable cannot currently be verified. Reconnect to review the changed or missing program; earlier replies remain recorded."
                    : peer.unavailableAt != nil
                        ? "The last connection attempt was unavailable. Earlier replies remain recorded; opening a new turn rechecks the route."
                        : "The connection is saved, but it has not answered a message yet.")
            }
            value["transport"] = .string("acp")
            value["route"] = .string("acp")
            value["outbound_route"] = .string("acp")
            value["capabilities"] = .array([.string("message")])
            value["readiness"] = .string("not_checked")
            value["setup"] = .string("Can start a conversation and receive its answer in the same call. The app remembers the conversation within your current chat and continues it when supported; use conversation to select a named discussion. It runs on this Mac as you; this app asks you only when the agent asks it for permission.")
            value["executable"] = peer.approvedExecutablePath.map(JSONValue.string) ?? .null
            value["working_directory"] = peer.acpWorkingDirectory.map(JSONValue.string) ?? .null
            if let id = AgentPeerStore.hostRowID(peer.endpoint), let line = AgentHostDirectory.row(named: id)?.acp {
                value["version_note"] = .string(line.versionNote(peer.acpExecutable?.version))
            }
            return .object(value)
        }
        if peer.transport == .mcpHost {
            let row = AgentPeerStore.hostRowID(peer.endpoint).flatMap { id in
                AgentHostDirectory.rows.first { $0.id == id }
            }
            let line = row?.commandLine
            value["kind"] = .string("agent_host")
            value["transport"] = .string("mcpHost")
            value["host"] = .string(row?.id ?? "")
            value["route"] = .string(row?.route.rawValue ?? "mcp-settings-only")
            value["outbound_route"] = .string(row?.outboundRoute ?? "none")
            if let presence = AgentContactHealth.checkIn(peer) { value["state_detail"] = .string(presence.detail) }
            value["credential_configured"] = .bool(peer.credentialKey != nil)
            value["readiness"] = .string("not_checked")
            value["capabilities"] = .array([.string("message")])
            value["read_inputs"] = .array(line?.continuesConversations == true ? [.string("conversation_id")] : [])
            value["setup"] = .string(line == nil
                ? hostInboundOnlyDetail
                : "A message to this contact runs its command line once and brings its reply back in the same call."
                    + (line?.continuesConversations == true
                       ? " The app remembers the conversation within your current chat; use conversation to select a named discussion."
                       : " This connection starts a separate conversation for each message.")
                    + " It also reaches this app any time through its own entry.")
            if row?.format == .shellEnvironment {
                value["state_detail"] = .string(ChatGPTDotIPCTransport.detail)
                value["outbound_route"] = .string("chatgpt-dot-ipc")
                value["route"] = .string("chatgpt-dot-ipc")
                value["readiness"] = ChatGPTDotIPCTransport.readiness
                value["can_start_turn"] = .bool(ChatGPTDotIPCTransport.available)
                value["capabilities"] = .array(ChatGPTDotIPCTransport.available ? [.string("message"), .string("read")] : [.string("read")])
                value["read_inputs"] = .array([.string("conversation_id"), .string("limit"), .string("offset"), .string("max_chars"), .string("text_offset"), .string("source_version")])
                value["setup"] = .string(ChatGPTDotIPCTransport.available
                    ? "NativeAgent messages Dot in-house after a read-only route check. Unknown delivery is read by its original receipt, never resent. Dot's nativeagent-link inbound commands and per-agent Trust remain unchanged."
                    : "Dot is inbound only: his messages arrive through nativeagent-link on this Mac as ordinary inbound turns, and a read returns the retained conversation. There is no way to send him a message from here; nothing to repair.")
            }
            return .object(value)
        }
        if peer.transport == .desktopChat {
            value["kind"] = .string("desktop_chat_agent")
            value["transport"] = .string("desktopChat")
            value["app_bundle_id"] = .string(AgentPeerStore.desktopBundleID(peer.endpoint) ?? "")
            value["capabilities"] = .array([.string("message")])
            value["read_inputs"] = .array([.string("conversation_id")])
            value["setup"] = .string("A message is typed into your own chat in its app and its answer comes back in the same call. The app remembers that chat within your conversation; start a new conversation for a fresh chat there.")
            return .object(value)
        }
        if peer.transport == .desktop {
            value["kind"] = .string("desktop_agent")
            value["transport"] = .string("desktop")
            value["app_bundle_id"] = .string(AgentPeerStore.desktopBundleID(peer.endpoint) ?? "")
            value["readiness"] = .string("not_checked")
            value["execution"] = .string("app_managed_desktop_route")
            value["capabilities"] = .array([.string("message")])
            value["setup"] = .string(peer.readsReplyInWindow
                ? "A message is pasted into its chat \u{201C}\(peer.conversationLabel ?? "grok")\u{201D} in the Grok Bot app and its answer is read back from that same chat in the same call (up to three minutes)."
                : desktopSetupNote)
            if let label = peer.conversationLabel { value["conversation_label"] = .string(label) }
            return .object(value)
        }
        value["kind"] = .string("external_peer")
        value["transport"] = .string(peer.transport.rawValue)
        value["endpoint"] = .string(peer.endpoint.absoluteString)
        value["credential_configured"] = .bool(peer.credentialKey != nil)
        value["readiness"] = .string("not_checked")
        value["capabilities"] = .array([.string("message"), .string("read")])
        value["read_inputs"] = .array(peer.transport == .a2a
            ? [.string("task_id")] : [.string("message_id"), .string("conversation_id")])
        return .object(value)
    }
}
