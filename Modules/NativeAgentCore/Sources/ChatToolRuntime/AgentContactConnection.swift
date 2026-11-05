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
// Blueprint: | `AgentContactConnection.swift` | Read one checked peer snapshot; preserve committed setup evidence. |
extension SwiftToolDispatcher {
    /// A current contact and its peer set are one checked address-book read. A failed read or a contact removed meanwhile cannot reuse an earlier binding.
    static func checkedPeerSnapshot(_ id: String, store: AgentPeerStore) throws
        -> (contact: AgentPeerContact, peers: [AgentPeerContact]) {
        let peers = try store.list()
        guard let contact = peers.first(where: { $0.id == id }) else {
            throw ToolFailureError("The saved address book has no row for this contact ID. Read agent.contacts before continuing; nothing was resent.",
                effects: .unknown, owner: store.fileURL.path,
                nextCall: ToolFailureError.call("app", ["action": .string("agent.contacts")]),
                code: "agent_contact_not_saved", recovery: .inspect)
        }
        return (contact, peers)
    }

    /// Post-effect readers keep the effect receipt and label its projection unavailable if the current address-book read failed.
    static func checkedPeerReadout(_ id: String, store: AgentPeerStore) -> (contact: JSONValue, fields: [String: JSONValue]) {
        do {
            let snapshot = try checkedPeerSnapshot(id, store: store)
            let state = try currentPeerState(snapshot.contact, peers: snapshot.peers)
            let contact = peerProjection(snapshot.contact, peers: snapshot.peers)
            let detail = state == .unavailable ? state.detail : AgentContactHealth.checkIn(snapshot.contact)?.detail ?? state.detail
            return (contact, ["state": .string(state.rawValue), "state_detail": .string(detail), "contact": contact])
        } catch {
            let failure = ChatToolOutcome.failure(error: error)
            let detail = "The saved contact state could not be read: \(error.localizedDescription). The operation's effect evidence is retained independently."
            let contact: JSONValue = .object(["agent": .string("peer:" + id), "state": .string("unavailable"),
                "state_detail": .string(detail), "state_failure": failure])
            return (contact, ["state": .string("unavailable"), "state_detail": .string(detail), "state_failure": failure, "contact": contact])
        }
    }

    static func checkedPeerProjection(_ id: String, store: AgentPeerStore) -> JSONValue {
        checkedPeerReadout(id, store: store).contact
    }
    static func peerFailure(_ failure: ProviderFailure.Report, into envelope: inout [String: JSONValue]) {
        AgentPeerPolicy.peerFailure(failure, into: &envelope)
    }
    /// Caller admission or Full Mac must authorize setup before the entry is written; any required approval precedes this boundary.
    func hostConnect(turn: Turn, invocation: ChatToolInvocation, name: String, workspace: String?, executablePath: String?, store: AgentPeerStore,
        surface: String, workingDirectory: String? = nil,
        conversationLabel: String? = nil) async throws -> JSONValue {
        guard conversationLabel == nil || AgentHostDirectory.row(named: name)?.route == .grokBot else {
            throw AgentCommunicationError.invalid("""
                conversation_label by name applies to Grok Bot only; for a desktop app's chat use transport desktop with app_bundle_id
                """)
        }
        // Desktop targets change no external settings and mint no key, so saving one needs no setup card.
        if let row = AgentHostDirectory.row(named: name), row.route == .desktopChat {
            guard row.isInstalled, let bundle = row.bundleIDs.first, let endpoint = URL(string: "app://" + bundle) else {
                return .object(["status": .string("not_supported"), "requested": .string(name), "changed": .bool(false),
                                "detail": .string("Installation/bundle check failed: \(row.installationCheck)")])
            }
            let saved = try store.insertDiscovered(AgentPeerContact(name: row.displayName, endpoint: endpoint, transport: .desktopChat))
            return .object(["status": .string("configured"), "contact": Self.checkedPeerProjection(saved.id, store: store),
                "changed": .bool(true), "completed": .bool(false),
                "detail": .string("Saved. Your first message opens a chat of your own in \(row.displayName) and brings its answer back in the same call.")])
        }
        guard AgentHostDirectory.row(named: name)?.acp != nil || turn.personApprovedHost else {
            throw AgentCommunicationError.invalid("Connecting a named agent requires the person's approval card.")
        }
        guard usesCanonicalBody else {
            throw AgentCommunicationError.invalid("setting another agent up on this Mac is unavailable outside the canonical app")
        }
        var proposal: AgentHostConnection.Proposal
        do { proposal = try AgentHostConnection.propose(name: name, store: store, dataRoot: dataRoot, workspace: workspace,
            workingDirectory: workingDirectory) }
        catch let refusal as AgentHostConnection.Refusal {
            return .object(["status": .string("not_supported"),
                            "requested": .string(name),
                            "known_agents": .array(AgentHostDirectory.knownNames.map(JSONValue.string)),
                            "changed": .bool(false),
                            "detail": .string(refusal.localizedDescription)])
        }
        if proposal.row.route == .grokBot {
            let result = try AgentHostConnection.connect(proposal: proposal, store: store)
            // Select the recipient's exact sidebar name before sending the routine request.
            if let conversationLabel {
                guard result.contact.grokConversation == nil else {
                    throw AgentCommunicationError.invalid("""
                        The routine request already went to a Bot, so the Bot cannot be changed here. Disconnect Grok Bot (disconnect true, name \
                        peer:\(result.contact.id)) and connect again with conversation_label.
                        """)
                }
                do {
                    try store.updateGrok(result.contact.id) { current in
                        guard current.grokConversation == nil else { throw GrokLinkCredential.Failure.invalid }
                        current.conversationLabel = conversationLabel
                    }
                } catch {
                    throw AgentCommunicationError.invalid("""
                        conversation_label was not saved: it must be the Bot's exact sidebar name on one line, and the routine request must not \
                        have gone out yet
                        """)
                }
            }
            return .object(["status": .string("grok_setup"), "peer_id": .string(result.contact.id)])
        }
        if var existing = proposal.existing, proposal.row.acp == nil {
            if proposal.row.format == .shellEnvironment {
                let result = try AgentHostConnection.ensureEnvironment(proposal: proposal, store: store)
                return Self.environmentSetupResult(proposal: proposal, contact: result.contact, store: store,
                    changed: result.repaired, repaired: result.repaired)
            }
            let setup = try AgentHostConnection.connect(proposal: proposal, store: store)
            existing = setup.contact
            let repaired = setup.outcome.backupPath != nil
            let permissionsChanged = setup.permissionsChanged
            // Reconnection approves the currently installed program; an update may leave obsolete version folders on disk.
            var programApproved = false
            if proposal.row.commandLine != nil,
               let path = proposal.executablePath, path == executablePath, existing.verifiedExecutablePath != path {
                programApproved = try store.approveExecutable(peerID: existing.id, path: path)
                guard programApproved else {
                    throw ToolFailureError("The contact changed before its program could be approved. Read agent.contacts before continuing.",
                        effects: .unknown, owner: store.fileURL.path,
                        nextCall: ToolFailureError.call("app", ["action": .string("agent.contacts")]), recovery: .inspect)
                }
            }
            var value: [String: JSONValue] = ["status": .string(repaired ? "configured" : "already_configured"),
                "contact": Self.checkedPeerProjection(existing.id, store: store),
                            "changed": .bool(repaired || permissionsChanged || programApproved),
                            "detail": .string(repaired
                                ? "Repaired \(proposal.row.displayName)'s connector entry and key on the same contact. Restart: \(proposal.row.restartNote)"
                                : programApproved
                ? """
                    Approved the \(proposal.row.displayName) program at \(executablePath ?? ""); a Full Mac launch runs exactly this file. Nothing \
                    else was changed.
                    """
                                : "\(proposal.row.displayName) already has this app's entry and its own key. Nothing was changed.")]
            if existing.state != .connected, proposal.row.commandLine?.automaticMCPProbe == false {
                value["detail"] = .string(Self.directCommandSetupDetail)
            }
            if permissionsChanged { value["detail"] = .string("""
                Enabled only this connection's two messaging tools in \(proposal.row.displayName). Send a message to verify the return path; \
                existing Ask/Deny rules and all other permissions are unchanged. Restart: \(proposal.row.restartNote)
                """) }
            if existing.state != .connected, proposal.row.commandLine?.automaticMCPProbe == true {
                let probe = try await hostCommandRun(turn: turn, invocation: invocation, row: proposal.row, contact: existing,
                    message: AgentHostDirectory.probeText(appName: Self.appDisplayName),
                    session: nil, store: store, surface: surface, probe: true)
                let fields = Self.checkedPeerReadout(existing.id, store: store).fields
                value.merge(fields) { _, current in current }
                let connected = fields["state"] == .string(AgentPeerContactState.connected.rawValue)
                value["status"] = .string(connected ? "connected" : "configured")
                value["detail"] = connected ? fields["state_detail"] : .string(Self.probeReason(probe, row: proposal.row))
                if fields["state_failure"] != nil { value["detail"] = fields["state_detail"] }
                Self.includeConnectionProbe(probe, in: &value)
            }
            Self.sayReplaced(setup.outcome, in: &value)
            return .object(value)
        }
        if proposal.row.acp != nil {
            // Reuse chat approval or Full Mac authority; ask here only if setup has not already been approved.
            if !turn.personApprovedHost {
                guard try await AgentACPApproval.connect(turn: turn, proposal, appName: Self.appDisplayName,
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
            return Self.environmentSetupResult(proposal: proposal, contact: result.contact, store: store, changed: true)
        }
        if row.acp != nil {
            return .object(["status": .string("configured"), "contact": Self.checkedPeerProjection(result.contact.id, store: store),
                "changed": .bool(true), "completed": .bool(false),
                "detail": .string("""
                    Saved this connection with its own key. Its settings were not changed. Send a message to check that it can answer; setup alone \
                    does not prove that.
                    """)])
        }
        // Only an authenticated inbound request proves the written entry works; CLI success or a handshake cannot promote it.
        var probe: JSONValue?
        if row.commandLine?.automaticMCPProbe == true {
            probe = try await hostCommandRun(turn: turn, invocation: invocation,
                row: row, contact: result.contact,
                message: AgentHostDirectory.probeText(appName: Self.appDisplayName),
                session: nil, store: store, surface: surface, probe: true)
        }
        // Read connection state from the saved contact: probe stdout cannot prove the authenticated inbound entry.
        let fields = Self.checkedPeerReadout(result.contact.id, store: store).fields
        let connected = fields["state"] == .string(AgentPeerContactState.connected.rawValue)
        var value: [String: JSONValue] = [
            "status": .string(connected ? "connected" : "configured"),
            "config_path": .string(result.outcome.path),
            "entry": .string(AgentHostDirectory.entryName),
            "restart_required": .bool(row.restartRequired),
            "detail": .string(
                "Wrote one entry into \(row.displayName)'s own settings and kept a timestamped backup beside the file. "
                + "This connection has its own key; it is not elevated and nothing was restarted. "
                + (row.restartRequired
                   ? "\(row.displayName) may need a restart before it picks the entry up — restart it yourself; nothing of its window is opened or read. "
                   : "")
                + (connected
                   ? "The executable answered a request; the contact carries the scope and time of that proof."
                   : row.commandLine != nil
                     ? """
                         The probe did not come back through the entry, so this stays set up: an entry that exists proves only that it was written.\u{20}
                         """ + Self.probeReason(probe, row: row)
                     : """
                         No inbound message authenticated this contact's key yet. Check agents/recipes/\(row.id).json \
                         host.configPath=\(row.expandedConfigPath) with agent.verify. Restart: \(row.restartNote) Then send a message through that \
                         host's connector to prove it.
                         """)),
        ]
        value.merge(fields) { _, current in current }
        if let probe { Self.includeConnectionProbe(probe, in: &value) }
        if row.commandLine?.automaticMCPProbe == false, !connected {
            value["detail"] = .string(Self.directCommandSetupDetail)
        }
        if fields["state_failure"] != nil { value["detail"] = fields["state_detail"] }
        if let backup = result.outcome.backupPath { value["backup_path"] = .string(backup) }
        Self.sayReplaced(result.outcome, in: &value)
        return .object(value)
    }
    private static let directCommandSetupDetail = """
        Contact saved with permission for its two MCP messaging tools only. agent.message returns the command's answer; conversation_id continues \
        it. No callback was attempted. The separate MCP reply path stays unverified until an inbound message arrives.
        """
    private static func environmentSetupResult(proposal: AgentHostConnection.Proposal, contact: AgentPeerContact,
                                               store: AgentPeerStore, changed: Bool, repaired: Bool = false) -> JSONValue {
        let prefix = "set -a && . " + AgentHostDirectory.shellQuoted(proposal.row.expandedConfigPath)
            + " && set +a && " + AgentHostDirectory.shellQuoted(proposal.command)
        let message = prefix + " message \"hello\""
        let reply = prefix + " reply --session '<session_id>' --request '<request_id>'"
        let readout = checkedPeerReadout(contact.id, store: store)
        var value: [String: JSONValue] = ["status": .string(repaired ? "repaired" : changed ? "configured" : "already_configured"),
            "changed": .bool(changed),
            "env_file": .string(proposal.row.expandedConfigPath), "outbound_route": .string("chatgpt-dot-ipc"),
            "message_command": .string(message), "reply_command": .string(reply), "restart_required": .bool(false),
            "detail": .string("""
                \(repaired ? "Repaired" : changed ? "Created" : "Already configured") ChatGPT Dot with its own scoped key and private (0600) \
                environment file. No ChatGPT settings were edited. NativeAgent can message Dot in-house after a read-only route check.\nGive Dot \
                this exact command:\n\(message)\nIf the answer is enqueued, use the session_id and request_id returned by that \
                command:\n\(reply)\nKeep the same --session to continue the conversation. Read enqueued answers with reply; do not resend the \
                message.
                """)]
        value.merge(readout.fields) { _, current in current }
        return .object(value)
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
            value["detail"] = .string("""
                Deleted this contact's environment file, revoked its scoped key and removed ChatGPT Dot. No ChatGPT settings were changed.
                """)
        }
        if let outcome {
            value["config_path"] = .string(outcome.path)
            if let backup = outcome.backupPath { value["backup_path"] = .string(backup) }
        }
        return .object(value)
    }
}
