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
// Blueprint: | `AgentContactACP.swift` | ACP launch, execution and live updates |
extension SwiftToolDispatcher {
    /// The installed program, approved in place of the one pinned at connect
    /// when it moved (Cursor's version folders) or changed (Hermes in place).
    private static func followACPUpdate(_ contact: AgentPeerContact, installed: String?, environment: [String: String], store: AgentPeerStore) async -> AgentPeerContact {
        guard let installed else { return contact }
        let path = URL(fileURLWithPath: installed).standardizedFileURL.resolvingSymlinksInPath().path
        if let approved = contact.approvedACPExecutable, approved.path == path, approved.isCurrent { return contact }
        // Its version, for the startup check (startupBlocker) and the contact's version note.
        let version = try? await AgentACPExecutable.capture(path: path).reported(environment: environment)
        guard (try? store.approveExecutable(peerID: contact.id, path: path, version: version)) == true else { return contact }
        return (try? store.list())?.first { $0.id == contact.id } ?? contact
    }
    /// What a dry run changed in an ACP recipe, said plainly: the two downgrades, or what it recorded.
    static func learned(_ old: AgentHostACP, _ new: AgentHostACP) -> String {
        var said: [String] = []
        if new.modes != old.modes {
            said.append(new.modes == [] ? "dropped set_mode — no modes advertised" : "its modes are " + (new.modes ?? []).joined(separator: ", "))
        }
        if new.supportsLoad == false, new.supportsResume == false, old.supportsLoad != false || old.supportsResume != false {
            said.append("no session/load or session/resume — continuing the conversation opens a new ACP session")
        }
        return said.isEmpty ? "recorded its protocol version and session support" : said.joined(separator: "; ")
    }
    /// THE RULE FOR RUNNING ANOTHER AGENT'S PROGRAM, a send's and an explicit
    /// discover's handshake alike: Full Mac runs it as is; otherwise it runs
    /// inside the builder sandbox and never reads the bridge directory. Denied
    /// or locked down, nothing runs and `refused` is the receipt that says why.
    func agentProgramLaunch(_ permission: DrivenAgentLaunchPermission) async
        -> (launch: AgentPeerDiscovery.Launch, refused: [String: JSONValue]) {
        func refused(_ status: String, _ detail: String, reason: String? = nil) -> (launch: AgentPeerDiscovery.Launch, refused: [String: JSONValue]) {
            var receipt: [String: JSONValue] = ["status": .string(status), "sent": .bool(false), "completed": .bool(false), "detail": .string(detail)]
            if let reason { receipt["reason"] = .string(reason) }
            return (.refused(detail), receipt)
        }
        if case .denied(let reason) = permission { return refused("failed", "Nothing was launched: \(reason).", reason: "launch_blocked") }
        guard permission != .fullMac else { return (.run { executable, arguments in [executable] + arguments }, [:]) }
        let sandbox = await Self.builderShellSandboxMode(dataRoot: dataRoot)
        guard sandbox != .lockedDown else { return refused("unavailable", "Running another agent is turned off in the current permission settings.") }
        // Peers use the URL-only descriptor and cannot read the main bridge bearer.
        let bridgeDir = Self.sbplEscapeLiteral(AgentHostDirectory.bridgeDiscoveryDirectory(dataRoot: dataRoot)
            .standardizedFileURL.resolvingSymlinksInPath().path)
        let profile = (sandbox == .developerFullMac ? Self.builderDeveloperSandboxProfile(dataRoot: dataRoot)
            : Self.builderSandboxProfile(dataRoot: dataRoot)) + "\n(deny file-read* (subpath \"\(bridgeDir)\"))"
        return (.run { executable, arguments in ["/usr/bin/sandbox-exec", "-p", profile, executable] + arguments }, [:])
    }
    func hostACPRun(contact: AgentPeerContact, message: String, conversationID: String?, store: AgentPeerStore,
                            surface: String) async throws -> JSONValue {
        guard usesCanonicalBody, await fullMacToolAccess(surface: surface).fileOpsAllowed else {
            return builderFullMacRequired(tool: "agent_message")
        }
        // The recipe this send runs on, kept for its proof.
        func missing(_ reason: String, _ detail: String, instruction: String, call: String? = nil, tap: String? = nil) -> JSONValue {
            .object(["status": .string("unavailable"), "reason": .string(reason), "effects": .string("none"),
                "sent": .bool(false), "completed": .bool(false), "detail": .string(detail),
                "remedy": Repair.remedy(owner: contact.name, nextCall: call.flatMap { try? JSONValue.parse(Data($0.utf8)) },
                    tap: tap, instruction: instruction)])
        }
        let recipeCall = ToolFailureError.call("app", ["action": .string("agent.recipe"),
            "args": .object(contact.recipeID.map { ["host": .string($0)] } ?? [:])])
        guard let recipe = AgentPeerStore.hostRowID(contact.endpoint).flatMap(AgentRecipeStore.recipe) else {
            return missing("agent_recipe_missing", "No recipe is available for \(contact.name).",
                instruction: "Read the recipe problem, then repair the named recipe with agent.recipe_write.", call: recipeCall)
        }
        guard let line = recipe.host.acp else {
            return missing("acp_configuration_missing", "agents/recipes/\(recipe.host.id).json has no host.acp.",
                instruction: "Read the recipe, then set host.acp to the installed agent's ACP contract with agent.recipe_write.", call: recipeCall)
        }
        guard let link = AgentHostDirectory.linkCommandPath() else {
            return missing("agent_link_helper_missing", "This app's nativeagent-link helper is missing.",
                instruction: "Report the missing contact helper to the person.", tap: "Tell the person: this copy of NativeAgent is missing nativeagent-link.")
        }
        guard let secret = try AgentPeerCredentials.read(peerID: contact.id) else {
            return missing("agent_credential_missing", "Keychain has no credential for contact peer:\(contact.id).",
                instruction: "Reconnect this contact to create its missing credential.",
                call: ToolFailureError.call("app", ["action": .string("agent.connect"), "args": .object(["name": .string("peer:" + contact.id)])]))
        }
        let row = recipe.host
        if let failure = row.installation.failure { throw failure }
        let handshakeCheck = " Recipe agents/recipes/\(row.id).json host.acp: executable=\(line.executable), arguments=\(line.arguments), protocolVersion=\(line.protocolVersion.map(String.init) ?? "unset"), modes=\(line.modes ?? []); host.searchPaths=\(row.searchPaths). Match fields to the installed agent with agent.recipe_write; agent.verify. Keep permissionMode and sandbox restrictions."
        let origin = SecurityOriginContext.currentTurn(
            verifiedSessionId: ChatToolSessionContext.verifiedSessionId, surface: surface)
        let launchPermission = await SwiftNativeSecurityCenter(dataRoot: dataRoot)
            .drivenAgentLaunchPermission(origin: origin)
        // Full Mac follows updates, as drivenAgentLaunch does for command
        // contacts: the version installed now is approved here, so an update
        // never needs a reconnect and never runs the old build.
        let current = launchPermission == .fullMac
            ? try await Self.followACPUpdate(contact, installed: row.resolveExecutable(line.executable), environment: row.installation.launchEnvironment(), store: store) : contact
        guard let approved = current.approvedACPExecutable, approved.isCurrent else {
            await AgentACPConnections.shared.revoke(peer: contact.id)
            // Reconnecting raises the renewal card without holding this turn.
            return .object(["status": .string("reconnect_required"), "sent": .bool(false), "completed": .bool(false),
                "detail": .string("The approved program is missing, changed, or was never bound to this contact. Reconnect this agent to approve it. Nothing ran; the message was not resent.")])
        }
        if let blocker = line.startupBlocker(installedVersion: approved.version) {
            await AgentACPConnections.shared.revoke(peer: contact.id)
            store.recordUnavailable(peerID: contact.id)
            return .object(["status": .string("unavailable"), "sent": .bool(false), "completed": .bool(false),
                "reason": .string("incompatible_sandboxed_acp"), "detail": .string(blocker)])
        }
        let executable = approved.path
        // A repair's dry run (`AgentRecipeStore.dryRun`): a fresh session, its handshake, no prompt.
        let dryRun = AgentRecipeStore.dryRun
        let shown = contact.name + (approved.version.map { " " + AgentContactHealth.shortVersion($0) } ?? "")
        guard let folder = contact.acpWorkingDirectory else {
            return .object(["status": .string("reconnect_required"), "completed": .bool(false),
                "detail": .string("Reconnect this agent to approve its starting folder.")])
        }
        let directory = URL(fileURLWithPath: folder)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true,
                                                attributes: [.posixPermissions: 0o700])
        let environment: [String: String] = [
            AgentHostDirectory.peerIDVariable: contact.id,
            AgentHostDirectory.peerSecretVariable: secret,
            AgentHostDirectory.bridgeDescriptorVariable: AgentHostDirectory.bridgeDescriptorPath(dataRoot: dataRoot)]
        let server: JSONValue = .object(["name": .string(AgentHostDirectory.entryName), "command": .string(link),
            "args": .array([.string("mcp")]),
            "env": .array(environment.sorted { $0.key < $1.key }.map {
                .object(["name": .string($0.key), "value": .string($0.value)])
            })])
        let inbox = SwiftNativeApprovalInbox(root: dataRoot)
        let rule = await agentProgramLaunch(launchPermission)
        guard case .run(let wrap) = rule.launch else {
            await AgentACPConnections.shared.revoke(peer: contact.id)
            return .object(rule.refused)
        }
        let command = wrap(executable, line.arguments)
        let program = command[0], arguments = Array(command.dropFirst())
        let approvalContext = AgentACPApproval.Context.current
        let decidedSessionID = ChatToolSessionContext.verifiedSessionId
        let childEnvironment = try row.installation.launchEnvironment()
        // The program's identity, not just its path: an in-place update starts a new process.
        let configuration = try JSONValue.object([
            "program": .string(program), "executable": .string("\(approved.path)\n\(approved.inode)\n\(approved.digest)"),
            "arguments": .array(arguments.map(JSONValue.string)),
            "folder": .string(folder), "server": server,
            "environment": .object(childEnvironment.mapValues(JSONValue.string))
        ]).serialize(pretty: false)
        var lease: AgentACPConnections.Lease?
        do {
            let acquired = try await AgentACPConnections.shared.acquire(peer: contact.id, conversation: dryRun ? nil : conversationID, configuration: configuration)
            lease = acquired
            let reply = try await acquired.client.turn(
                executable: program, arguments: arguments,
                directory: directory, environment: childEnvironment,
                message: dryRun ? nil : message, peerCredential: secret, mcpServers: [server], line: line,
                conversationID: dryRun ? nil : conversationID,
                approvedExecutable: approved, requireVerifiedRestore: row.id == "hermes", permission: { request in
                    // Revocation wins even if an already-open card was approved.
                    guard try store.list().contains(where: { $0.id == contact.id }) else { return false }
                    // Under Full Mac she decides a driven agent's requests;
                    // irreversible deletion stays the person's.
                    var kind = "other"
                    if case .object(let params) = request, case .object(let call)? = params["toolCall"],
                       case .string(let value)? = call["kind"], !value.isEmpty { kind = value }
                    let allowed: Bool
                    let currentPermission = await SwiftNativeSecurityCenter(dataRoot: self.dataRoot)
                        .drivenAgentLaunchPermission(origin: origin)
                    if case .denied = currentPermission { return false }
                    let automaticallyAllowed = kind != "delete" && launchPermission == .fullMac && currentPermission == .fullMac
                    if automaticallyAllowed {
                        HarnessDecidedRow.post(requester: contact.name, tool: kind,
                                                     sessionID: decidedSessionID, dataRoot: self.dataRoot)
                        allowed = true
                    } else {
                        allowed = try await AgentACPApproval.request(request, peer: contact, context: approvalContext,
                                                                     dataRoot: self.dataRoot, inbox: inbox)
                    }
                    let stillConnected = try store.list().contains(where: { $0.id == contact.id })
                    let permissionAfterResponse = await SwiftNativeSecurityCenter(dataRoot: self.dataRoot)
                        .drivenAgentLaunchPermission(origin: origin)
                    if case .denied = permissionAfterResponse { return false }
                    return allowed && stillConnected && (!automaticallyAllowed || permissionAfterResponse == .fullMac)
                }, update: Self.acpLiveUpdate(AgentConversationLiveContext.target))
            // A cancelled turn (agent_cancel's session/cancel) keeps its session:
            // ACP ends the prompt and the conversation continues from there.
            guard await AgentACPConnections.shared.finish(acquired, peer: contact.id, conversation: dryRun ? nil : reply.sessionID) else { throw AgentACPClient.Failure.interrupted }
            lease = nil
            if dryRun {
                // What the agent advertised now goes into its recipe.
                let found = await acquired.client.learned(line)
                var host = row
                host.acp = found
                // A finding that cannot be written proves nothing, and no retry runs on it.
                var written: AgentRecipeStore.Recipe?
                if found != line {
                    do { written = try AgentRecipeStore.learn(recipe, host: host) }
                    catch {
                        return Self.peerRedact(.object(["status": .string("failed"), "dry_run": .bool(true), "sent": .bool(false),
                            "agent": .string("peer:" + contact.id), "transport": .string("acp"),
                            "detail": .string("Handshake verified for \(shown); recipe save unconfirmed (\(Self.learned(line, found))): \(error).")]), token: secret)
                    }
                }
                let now = written ?? recipe
                var result: [String: JSONValue] = ["status": .string(written == nil ? "passed" : "repaired"), "dry_run": .bool(true), "sent": .bool(false),
                    "agent": .string("peer:" + contact.id), "transport": .string("acp"), "recipe_version": .int(Int64(now.recipeVersion)),
                    "detail": .string("\(shown) answered its handshake with no prompt sent.")]
                if let written { result["healed"] = .string("\(shown): \(Self.learned(line, found)) — recipe updated to v\(written.recipeVersion)") }
                return .object(result)
            }
            store.recordProof(peerID: contact.id, inbound: reply.completed && !reply.text.isEmpty, outbound: true)
            // A prompt that went and ended without an answer is the agent's turn,
            // not a failed send path: only a send that never went marks it unavailable.
            if reply.completed && !reply.text.isEmpty {
                store.recordRoundTrip(peerID: contact.id, executable: approved.path,
                    version: approved.version, workspace: directory.path, recipe: recipe)
            }
            let result: [String: JSONValue] = ["status": .string(reply.completed ? "replied" : reply.stopReason),
                "agent": .string("peer:" + contact.id), "transport": .string("acp"),
                "conversation_id": .string(reply.sessionID), "continued": .bool(reply.continued),
                "sent": .bool(true), "completed": .bool(reply.completed), "reply": .string(reply.text),
                "untrusted_remote_data": .bool(!reply.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)]
            return Self.peerRedact(.object(result), token: secret)
        } catch AgentACPClient.Failure.executableChanged {
            if let lease { await AgentACPConnections.shared.finish(lease, peer: contact.id, conversation: nil) }
            store.recordUnavailable(peerID: contact.id)
            return .object(["status": .string("reconnect_required"), "sent": .bool(false), "completed": .bool(false),
                "detail": .string("The program changed before launch. Reconnect this agent to approve it. Nothing ran; the message was not resent.")])
        } catch {
            // The session it already has, so an uncertain turn can be resumed, not orphaned.
            let opened = await lease?.client.currentSessionID
            let delivered = await lease?.client.delivered == true
            let reported = await lease?.client.learned(line).protocolVersion
            let session = conversationID ?? opened
            if let lease { await AgentACPConnections.shared.finish(lease, peer: contact.id, conversation: nil) }
            if let failure = error as? AgentACPClient.Failure, failure == .sessionUnavailable || failure == .busy {
                return .object(["status": .string(failure == .busy ? "busy" : "session_unavailable"), "sent": .bool(false), "completed": .bool(false), "detail": .string(failure.localizedDescription)])
            }
            // Nothing was sent: the agent and its recipe disagree (a repair acts on it), or a dry run failed.
            if let refused = error as? AgentACPClient.Mismatch {
                store.recordUnavailable(peerID: contact.id)
                var result: [String: JSONValue] = ["status": .string(dryRun ? "failed" : "unavailable"), "agent": .string("peer:" + contact.id),
                    "transport": .string("acp"), "sent": .bool(false), "completed": .bool(false), "reason": .string("protocol_mismatch"),
                    "method": .string(refused.method), "detail": .string("\(shown): \(refused.method) — \(refused.detail). Nothing was sent." + handshakeCheck)]
                if let code = refused.code { result["code"] = .int(code) }
                if let reported { result["protocol_version"] = .int(Int64(reported)) }
                if let version = approved.version { result["program_version"] = .string(version) }
                if dryRun { result["dry_run"] = .bool(true) }
                // The agent's own error text never carries this connection's key.
                return Self.peerRedact(.object(result), token: secret)
            }
            // Cut off mid-reply (her app quitting, a cancel) says nothing about
            // whether the agent can start; marking it unavailable hid a working
            // Cursor after a restart (User 09-27).
            // Our own quit (closeAll) cut it off when the error says so; a peer's own EOF stays unknown.
            let quit = (error as? AgentACPClient.Failure) == .appQuit && !Task.isCancelled
            let cutOff = (error as? AgentACPClient.Failure) == .interrupted || quit || error is CancellationError || Task.isCancelled
            // After the prompt went (a post-delivery timeout, an unreadable answer)
            // the send path did not fail: the reply stalled, and health says so.
            if !cutOff, !delivered { store.recordUnavailable(peerID: contact.id) }
            if var result = AgentACPClient.startupTimeoutReceipt(error) {
                result["agent"] = .string("peer:" + contact.id)
                result["transport"] = .string("acp")
                let detail: String = if case .string(let text)? = result["detail"] { text } else { error.localizedDescription }
                result["detail"] = .string(detail + handshakeCheck)
                if dryRun { result["status"] = .string("failed"); result["dry_run"] = .bool(true) }
                return .object(result)
            }
            if dryRun {
                return Self.peerRedact(.object(["status": .string("failed"), "dry_run": .bool(true), "sent": .bool(false), "agent": .string("peer:" + contact.id),
                    "transport": .string("acp"), "detail": .string("\(shown) did not finish its handshake: "
                        + ((error as? AgentACPClient.Failure)?.localizedDescription ?? error.localizedDescription) + handshakeCheck)]), token: secret)
            }
            if let failure = ProviderFailure.report(error, work: .outcomeUnknown) {
                var result: [String: JSONValue] = ["agent": .string("peer:" + contact.id), "transport": .string("acp")]
                Self.peerFailure(failure, into: &result)
                if let session { result["conversation_id"] = .string(session) }
                return Self.peerRedact(.object(result), token: secret)
            }
            // Terminal: the call is over, bounded by the client's own timeout, and
            // nothing more arrives on it, so the thread does not wait on it.
            var result: [String: JSONValue] = ["status": .string(Task.isCancelled ? "cancelled" : quit ? "interrupted" : "outcome_unknown"),
                "agent": .string("peer:" + contact.id), "transport": .string("acp"), "completed": .bool(false), "terminal": .bool(true),
                "detail": .string(Task.isCancelled ? "The conversation was stopped." : quit ? AgentConversationSession.restartDetail(contact.name) :
                    (error as? AgentACPClient.Failure)?.localizedDescription ?? "The conversation did not finish. Do not resend automatically.")]
            if let session { result["conversation_id"] = .string(session) }
            return .object(result)
        }
    }
    /// ACP `session/update` carries scrubbed reply snapshots, tool calls and
    /// plans as progress notes, and the rest as activity.
    static func acpLiveUpdate(_ target: AgentConversationLiveTarget?) -> @Sendable (JSONValue) async -> Void {
        guard let target else { return { _ in } }
        return { event in
            let hub = AgentConversationLiveHub.shared
            guard case .object(let update) = event, case .string(let kind)? = update["sessionUpdate"] else { return }
            switch kind {
            case "agent_message_chunk":
                if case .object(let content)? = update["content"], content["type"] == .string("text"),
                   case .string(let text)? = content["text"] { await hub.text(target, replace: text) }
            case "tool_call":
                if case .string(let title)? = update["title"] { await hub.note(target, title) } else { await hub.activity(target) }
            case "plan":
                var steps: [[String: JSONValue]] = []
                if case .array(let entries)? = update["entries"] {
                    steps = entries.compactMap { if case .object(let step) = $0 { step } else { nil } }
                }
                let current = steps.first { $0["status"] == .string("in_progress") } ?? steps.first { $0["status"] == .string("pending") }
                if case .string(let step)? = current?["content"] { await hub.note(target, "Plan: " + step) } else { await hub.activity(target) }
            default: await hub.activity(target)
            }
        }
    }
    /// agent_cancel's lane owner: the other side's own stop for a reply in
    /// flight. "stopping"/"stopped" when asked; "cannot_stop" when the route has
    /// none; "not_here" when only this app's own in-flight send could be
    /// stopped, which the conversation layer does by cancelling that send.
}
