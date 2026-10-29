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
// Blueprint: | `AgentContactConnection.swift` | Named contact connection and disconnection |
extension SwiftToolDispatcher {
    static func peerFailure(_ failure: ProviderFailure.Report, into envelope: inout [String: JSONValue]) {
        AgentPeerPolicy.peerFailure(failure, into: &envelope)
    }
    /// Connect-by-name. By the time this runs the person has already pressed
    /// the button on the card `AgentHostConnection.cardText` wrote — a
    /// confirm-tier tool body only executes on the approved replay — so this is
    /// where the entry is actually written and not one step earlier.
    func hostConnect(name: String, workspace: String?, executablePath: String?, store: AgentPeerStore, surface: String, workingDirectory: String? = nil, conversationLabel: String? = nil) async throws -> JSONValue {
        guard conversationLabel == nil || AgentHostDirectory.row(named: name)?.route == .grokBot else {
            throw AgentCommunicationError.invalid("conversation_label by name applies to Grok Bot only; for a desktop app's chat use transport desktop with app_bundle_id")
        }
        // A chat app driven through its own window: nothing is written to its
        // settings and no key is minted, so saving it needs no card.
        if let row = AgentHostDirectory.row(named: name), row.route == .desktopChat {
            guard row.isInstalled, let bundle = row.bundleIDs.first, let endpoint = URL(string: "app://" + bundle) else {
                return .object(["status": .string("not_supported"), "requested": .string(name), "changed": .bool(false),
                                "detail": .string("Installation/bundle check failed: \(row.installationCheck)")])
            }
            let saved = try store.insertDiscovered(AgentPeerContact(name: row.displayName, endpoint: endpoint, transport: .desktopChat))
            return .object(["status": .string("configured"), "contact": Self.peerProjection(saved, peers: (try? store.list()) ?? []),
                "changed": .bool(true), "completed": .bool(false),
                "detail": .string("Saved. Your first message opens a chat of your own in \(row.displayName) and brings its answer back in the same call.")])
        }
        guard AgentHostDirectory.row(named: name)?.acp != nil || AgentHostConnection.personApproved else {
            throw AgentCommunicationError.invalid("Connecting a named agent requires the person's approval card.")
        }
        guard usesCanonicalBody else {
            throw AgentCommunicationError.invalid("setting another agent up on this Mac is unavailable outside the canonical app")
        }
        var proposal: AgentHostConnection.Proposal
        do { proposal = try AgentHostConnection.propose(name: name, store: store, dataRoot: dataRoot, workspace: workspace, workingDirectory: workingDirectory) }
        catch let refusal as AgentHostConnection.Refusal {
            // Unknown or uninstalled: an honest result, nothing changed.
            return .object(["status": .string("not_supported"),
                            "requested": .string(name),
                            "known_agents": .array(AgentHostDirectory.knownNames.map(JSONValue.string)),
                            "changed": .bool(false),
                            "detail": .string(refusal.localizedDescription)])
        }
        if proposal.row.route == .grokBot {
            let result = try AgentHostConnection.connect(proposal: proposal, store: store)
            // The Connect card's "Use this Bot": the exact sidebar name of the
            // Bot that receives the routine request, chosen before it is sent.
            if let conversationLabel {
                guard result.contact.grokConversation == nil else {
                    throw AgentCommunicationError.invalid("The routine request already went to a Bot, so the Bot cannot be changed here. Disconnect Grok Bot (disconnect true, name peer:\(result.contact.id)) and connect again with conversation_label.")
                }
                do {
                    try store.updateGrok(result.contact.id) { current in
                        guard current.grokConversation == nil else { throw GrokLinkCredential.Failure.invalid }
                        current.conversationLabel = conversationLabel
                    }
                } catch {
                    throw AgentCommunicationError.invalid("conversation_label was not saved: it must be the Bot's exact sidebar name on one line, and the routine request must not have gone out yet")
                }
            }
            return .object(["status": .string("grok_setup"), "peer_id": .string(result.contact.id)])
        }
        if var existing = proposal.existing, proposal.row.acp == nil {
            if proposal.row.format == .shellEnvironment {
                let result = try AgentHostConnection.ensureEnvironment(proposal: proposal, store: store)
                return Self.environmentSetupResult(proposal: proposal, contact: result.contact, peers: try store.list(),
                    changed: result.repaired, repaired: result.repaired)
            }
            let setup = try AgentHostConnection.connect(proposal: proposal, store: store)
            existing = setup.contact
            let repaired = setup.outcome.backupPath != nil
            let permissionsChanged = setup.permissionsChanged
            // Connecting again approves the program installed now (the path the
            // card showed) when the approved one is gone, changed, or no longer
            // the installed version — updates leave old version folders behind.
            var programApproved = false
            if proposal.row.commandLine != nil,
               let path = proposal.executablePath, path == executablePath, existing.verifiedExecutablePath != path {
                programApproved = (try? store.approveExecutable(peerID: existing.id, path: path)) == true
                if programApproved, let saved = try? store.list().first(where: { $0.id == existing.id }) { existing = saved }
            }
            var value: [String: JSONValue] = ["status": .string(repaired ? "configured" : "already_configured"), "contact": Self.peerProjection(existing, peers: (try? store.list()) ?? []),
                            "changed": .bool(repaired || permissionsChanged || programApproved),
                            "detail": .string(repaired
                                ? "Repaired \(proposal.row.displayName)'s connector entry and key on the same contact. Restart: \(proposal.row.restartNote)"
                                : programApproved
                                ? "Approved the \(proposal.row.displayName) program at \(existing.approvedExecutablePath ?? ""); a Full Mac launch runs exactly this file. Nothing else was changed."
                                : "\(proposal.row.displayName) already has this app's entry and its own key. Nothing was changed.")]
            if existing.state != .connected, proposal.row.commandLine?.automaticMCPProbe == false {
                value["detail"] = .string(Self.directCommandSetupDetail)
            }
            if permissionsChanged { value["detail"] = .string("Enabled only this connection's two messaging tools in Antigravity. Send a message to verify the return path; existing Ask/Deny rules and all other permissions are unchanged.") }
            if existing.state != .connected, proposal.row.commandLine?.automaticMCPProbe == true {
                let probe = try await hostCommandRun(row: proposal.row, contact: existing,
                    message: AgentHostDirectory.probeText(appName: Self.appDisplayName),
                    session: nil, store: store, surface: surface, probe: true)
                let settled = (try? store.list().first { $0.id == existing.id }) ?? existing
                let peers = (try? store.list()) ?? []
                let state = Self.currentPeerState(settled, peers: peers)
                value["contact"] = Self.peerProjection(settled, peers: peers)
                value["state"] = .string(state.rawValue)
                value["status"] = .string(state == .connected ? "connected" : "configured")
                value["detail"] = .string(state == .connected ? state.detail : Self.probeReason(probe, row: proposal.row))
                Self.includeConnectionProbe(probe, in: &value)
            }
            Self.sayReplaced(setup.outcome, in: &value)
            return .object(value)
        }
        if proposal.row.acp != nil {
            // The person already answered this named connect in chat (or Full Mac
            // allows it): a second card here is filed where the chat never shows
            // it, and the first live drive waited on it unseen for fifteen
            // minutes. Ask here only when no one has been asked yet.
            if !AgentHostConnection.personApproved {
                guard try await AgentACPApproval.connect(proposal, appName: Self.appDisplayName,
                    inbox: SwiftNativeApprovalInbox(root: dataRoot)) else {
                    return .object(["status": .string("denied"), "changed": .bool(false), "completed": .bool(false),
                                    "detail": .string("The person declined this connection; nothing was sent.")])
                }
            }
            // Its --version runs the program, so only once the connect is approved.
            let version = try await proposal.executable?.reported(environment: proposal.row.installation.launchEnvironment())
            proposal.executable?.version = version
        } else if proposal.executablePath != executablePath {
            throw AgentCommunicationError.invalid("The agent executable changed since the approval card. Ask to connect again; nothing ran or changed.")
        }
        let result = try AgentHostConnection.connect(proposal: proposal, store: store)
        let row = proposal.row
        if row.format == .shellEnvironment {
            return Self.environmentSetupResult(proposal: proposal, contact: result.contact, peers: try store.list(), changed: true)
        }
        if row.acp != nil {
            return .object(["status": .string("configured"), "contact": Self.peerProjection(result.contact, peers: (try? store.list()) ?? []),
                "changed": .bool(true), "completed": .bool(false),
                "detail": .string("Saved this connection with its own key. Its settings were not changed. Send a message to check that it can answer; setup alone does not prove that.")])
        }
        // PROVE THE ROUND TRIP WHERE THAT IS POSSIBLE. The entry is written and
        // approved; a host with a command line now gets one fixed probe asking
        // it to answer through that entry. The contact turns connected only
        // when the inbound request carrying this connection's key actually
        // arrives — not because the probe returned, and never on a handshake.
        var probe: JSONValue?
        if row.commandLine?.automaticMCPProbe == true {
            probe = try await hostCommandRun(
                row: row, contact: result.contact,
                message: AgentHostDirectory.probeText(appName: Self.appDisplayName),
                session: nil, store: store, surface: surface, probe: true)
        }
        let settled = (try? store.list().first { $0.id == result.contact.id }) ?? result.contact
        // The probe's own reply is the CLI talking back on its command line.
        // Only an inbound request through the entry proves the entry works, so
        // the connect state is read back from the contact, never from the run.
        let state = Self.currentPeerState(settled, peers: (try? store.list()) ?? [])
        var value: [String: JSONValue] = [
            "status": .string(state == .connected ? "connected" : "configured"),
            "contact": Self.peerProjection(settled, peers: (try? store.list()) ?? []),
            "state": .string(state.rawValue), "state_detail": .string(state == .unavailable ? state.detail : AgentContactHealth.checkIn(settled)?.detail ?? state.detail),
            "config_path": .string(result.outcome.path),
            "entry": .string(AgentHostDirectory.entryName),
            "restart_required": .bool(row.restartRequired),
            "detail": .string(
                "Wrote one entry into \(row.displayName)'s own settings and kept a timestamped backup beside the file. "
                + "This connection has its own key; it is not elevated and nothing was restarted. "
                + (row.restartRequired
                   ? "\(row.displayName) may need a restart before it picks the entry up — restart it yourself; nothing of its window is opened or read. "
                   : "")
                + (state == .connected
                   ? "The executable answered a request; the contact carries the scope and time of that proof."
                   : row.commandLine != nil
                     ? "The probe did not come back through the entry, so this stays set up: an entry that exists proves only that it was written. " + Self.probeReason(probe, row: row)
                     : "No inbound message authenticated this contact's key yet. Check agents/recipes/\(row.id).json host.configPath=\(row.expandedConfigPath) with agent.verify. Restart: \(row.restartNote) Then send a message through that host's connector to prove it.")),
        ]
        if let probe { Self.includeConnectionProbe(probe, in: &value) }
        if row.commandLine?.automaticMCPProbe == false, state != .connected {
            value["detail"] = .string(Self.directCommandSetupDetail)
        }
        if let backup = result.outcome.backupPath { value["backup_path"] = .string(backup) }
        Self.sayReplaced(result.outcome, in: &value)
        return .object(value)
    }
    private static let directCommandSetupDetail = "Contact saved with permission for its two MCP messaging tools only. agent.message returns the command's answer; conversation_id continues it. No callback was attempted. The separate MCP reply path stays unverified until an inbound message arrives."
    private static func environmentSetupResult(proposal: AgentHostConnection.Proposal, contact: AgentPeerContact,
                                               peers: [AgentPeerContact], changed: Bool, repaired: Bool = false) -> JSONValue {
        let prefix = "set -a && . " + AgentHostDirectory.shellQuoted(proposal.row.expandedConfigPath)
            + " && set +a && " + AgentHostDirectory.shellQuoted(proposal.command)
        let message = prefix + " message \"hello\""
        let reply = prefix + " reply --session '<session_id>' --request '<request_id>'"
        let state = currentPeerState(contact, peers: peers)
        return .object(["status": .string(repaired ? "repaired" : changed ? "configured" : "already_configured"),
            "contact": peerProjection(contact, peers: peers), "changed": .bool(changed),
            "state": .string(state.rawValue), "state_detail": .string(proposal.row.description),
            "env_file": .string(proposal.row.expandedConfigPath), "outbound_route": .string("chatgpt-dot-ipc"),
            "message_command": .string(message), "reply_command": .string(reply), "restart_required": .bool(false),
            "detail": .string("\(repaired ? "Repaired" : changed ? "Created" : "Already configured") ChatGPT Dot with its own scoped key and private (0600) environment file. No ChatGPT settings were edited. NativeAgent can message Dot in-house after a read-only route check.\nGive Dot this exact command:\n\(message)\nIf the answer is enqueued, use the session_id and request_id returned by that command:\n\(reply)\nKeep the same --session to continue the conversation. Read enqueued answers with reply; do not resend the message.")])
    }
    func hostDisconnect(name: String, store: AgentPeerStore) async throws -> JSONValue {
        guard usesCanonicalBody else {
            throw AgentCommunicationError.invalid("changing another agent's settings is unavailable outside the canonical app")
        }
        // Disconnect requires the exact peer id from agent_contacts.
        guard let contact = try store.list().first(where: { "peer:" + $0.id == name }) else {
            return .object(["status": .string("not_configured"), "requested": .string(name),
                            "changed": .bool(false),
                            "detail": .string("Disconnect needs the exact peer:<id> from agent_contacts. Nothing was changed.")])
        }
        let outcome: AgentHostConfigWriter.Outcome?
        if contact.transport == .grokBot {
            try store.updateGrok(contact.id, allowDisconnected: true) { revoked in
                if revoked.grokBootstrapConfirmed == nil {
                    revoked.grokBootstrapConfirmed = ["secure-paste", "set up"].contains(revoked.grokSetup ?? "")
                }
                try GrokLinkCredential.delete(peer: contact.id)
                try AgentPeerCredentials.delete(peerID: contact.id)
                revoked.grokSetup = "disconnected"
            }
            return .object(["status": .string("grok_disconnect"), "peer_id": .string(contact.id)])
        }
        if contact.transport == .mcpHost {
            outcome = try AgentHostConnection.disconnect(contact: contact, store: store)
        } else {
            try AgentPeerCredentials.delete(peerID: contact.id)
            _ = try store.remove(contact.id)
            await AgentACPConnections.shared.revoke(peer: contact.id)
            outcome = nil
        }
        var value: [String: JSONValue] = ["status": .string("disconnected"), "changed": .bool(true),
            "detail": .string(contact.transport == .mcpHost && outcome != nil
                ? "Removed exactly this app's entry, revoked that connection's key, and forgot the contact. Everything else in that file is unchanged."
                : "Removed the contact and its saved key. No other app's settings were changed.")]
        if AgentPeerStore.hostRowID(contact.endpoint).flatMap({ AgentHostDirectory.row(named: $0)?.format }) == .shellEnvironment {
            value["detail"] = .string("Deleted this contact's environment file, revoked its scoped key and removed ChatGPT Dot. No ChatGPT settings were changed.")
        }
        if let outcome {
            value["config_path"] = .string(outcome.path)
            if let backup = outcome.backupPath { value["backup_path"] = .string(backup) }
        }
        return .object(value)
    }
}
