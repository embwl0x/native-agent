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
// Blueprint: | `AgentContactCommand.swift` | Contact command execution through admitted transport |
extension SwiftToolDispatcher {
    func hostCommandRun(
        row: AgentHostRow, contact: AgentPeerContact, message: String, session: String?,
        resuming: Bool = false, store: AgentPeerStore, surface: String, probe: Bool = false
    ) async throws -> JSONValue {
        guard let line = row.commandLine else { throw AgentCommunicationError.invalid("\(row.displayName) has no command line to run") }
        if let failure = row.installation.failure { throw failure }
        // The recipe this send runs on, kept for its proof.
        let recipe = AgentRecipeStore.recipe(row.id)
        if AgentRecipeStore.dryRun {
            var result: [String: JSONValue] = ["status": .string("failed"), "dry_run": .bool(true),
                "agent": .string("peer:" + contact.id), "transport": .string("mcpHost"), "host": .string(row.id),
                "sent": .bool(false), "ran": .bool(false), "completed": .bool(false),
                "command": .string(line.executable),
                "arguments": .array((resuming ? line.continuation : line.arguments).map(JSONValue.string)),
                "checked": .array([.string("commandLine.executable"), .string("commandLine.arguments")])]
            guard let executable = row.resolveExecutable(line.executable) else {
                result["detail"] = .string("\(row.displayName)'s readiness check failed: \(line.executable) could not be resolved to a runnable file; no prompt was sent.")
                return .object(result)
            }
            result["executable"] = .string(executable)
            if line.minimumVersion != nil, let tooOld = line.versionFailure(program: line.executable,
                reported: try? await AgentACPExecutable.capture(path: executable).reported(environment: row.installation.launchEnvironment())) {
                result["detail"] = .string("\(row.displayName)'s readiness check failed: \(tooOld)")
                return .object(result)
            }
            guard let recipe else {
                result["detail"] = .string("\(row.displayName)'s recipe is unavailable; no prompt was sent.")
                return .object(result)
            }
            do {
                let learned = try (recipe.host == row ? recipe : AgentRecipeStore.learn(recipe, host: row))
                result["recipe_version"] = .int(Int64(learned.recipeVersion))
                result["status"] = .string("passed")
                result["detail"] = .string("\(row.displayName) answered its readiness check: \(executable) is runnable; no prompt was sent.")
            } catch {
                result["detail"] = .string("\(row.displayName)'s readiness check could not be recorded in its recipe: \(error). No prompt was sent.")
            }
            return .object(result)
        }
        let access = await fullMacToolAccess(surface: surface)
        guard access.fileOpsAllowed else {
            let refusal = builderFullMacRequired(tool: "agent_message")
            var value: [String: JSONValue] = [:]
            if case .object(let fields) = refusal { value = fields }
            if value["status"] == .string("failed") {
                value["status"] = .string("blocked_by_trust")
            }
            let mode = access.permissionLevel == "balanced" ? "Work mode" : "the current trust mode"
            value["reason"] = .string("trust_center_full_mac_required")
            value["sent"] = .bool(false)
            value["ran"] = .bool(false)
            value["completed"] = .bool(false)
            value["detail"] = .string(probe
                ? "The entry is written, but I couldn't check the link in \(mode) because running that agent here needs Builder or Full Mac; switch in Trust or the composer and say connect again, or use the connection from the other agent's side."
                : "I didn't send the message in \(mode) because running that agent here needs Builder or Full Mac; switch in Trust or the composer and ask me to send it again, or use the connection from the other agent's side.")
            if probe {
                value["connection_check"] = .bool(true)
                value["connection_reply_received"] = .bool(false)
            }
            return .object(value)
        }
        let agent = "peer:" + contact.id
        func honest(_ status: String, _ detail: String) -> JSONValue {
            store.recordUnavailable(peerID: contact.id)
            let state = Self.currentPeerState(contact, peers: (try? store.list()) ?? [])
            return .object(["status": .string(status), "agent": .string(agent), "transport": .string("mcpHost"),
                     "host": .string(row.id), "state": .string(state.rawValue),
                     "state_detail": .string(state.detail),
                     "sent": .bool(false), "completed": .bool(false), "detail": .string(detail)])
        }
        // Every command route reconciles its binding, including those without permission flags.
        let launch = await Self.drivenAgentLaunch(surface: surface, contact: contact,
                                                  name: row.displayName, dataRoot: dataRoot)
        guard let executable = launch.executable else { return launch.deniedResult! }
        let environment = try row.installation.launchEnvironment()
        if line.minimumVersion != nil {
            // The approved program's receipt keeps the version it reported, read
            // once when it was approved; the launch re-verifies those exact bytes.
            var reported = (try? store.list())?.first { $0.id == contact.id }?.acpExecutable.flatMap { $0.path == executable ? $0.version : nil }
            if reported == nil {
                reported = try? await AgentACPExecutable.capture(path: executable).reported(environment: row.installation.launchEnvironment())
                if let reported { _ = try? store.approveExecutable(peerID: contact.id, path: executable, version: reported) }
            }
            if let tooOld = line.versionFailure(program: line.executable, reported: reported) { return honest("unavailable", tooOld) }
        }
        let launchArguments = launch.arguments
        // ONE directory per agent, inside the workspace the command runner
        // already confines writes to. It was a fresh one per message until the
        // Codex drive: Codex records every directory it runs in as a trusted
        // project in its own settings, so each message left a line behind there.
        let workingDirectory = contact.hostWorkspace.map { URL(fileURLWithPath: $0) }
            ?? Self.builderWorkspaceRoot(dataRoot: dataRoot).appendingPathComponent("agent-bridge-runs/" + row.id)
        guard (try? FileManager.default.createDirectory(at: workingDirectory, withIntermediateDirectories: true,
                                                        attributes: [.posixPermissions: 0o700])) != nil else {
            return honest("unavailable", "A working directory for the run could not be created. Nothing ran.")
        }
        // The reply file is this run's alone, so two messages at once never read each other's.
        let replyDirectory = workingDirectory.appendingPathComponent(UUID().uuidString.lowercased())
        try? FileManager.default.createDirectory(at: replyDirectory, withIntermediateDirectories: true,
                                                 attributes: [.posixPermissions: 0o700])
        let replyFile = line.replyFileName.map { replyDirectory.appendingPathComponent($0).path }
        let probeNonce: String?
        do {
            probeNonce = probe ? try store.beginConnectionProbe(peerID: contact.id, timeout: TimeInterval(line.timeoutSeconds)) : nil
        } catch {
            return honest("unavailable", "The connection check could not be recorded. Nothing ran.")
        }
        let outgoing = probeNonce.map { AgentHostDirectory.probeText(appName: Self.appDisplayName, nonce: $0) } ?? message
        let argv = launchArguments + line.argv(message: outgoing, session: session, resuming: resuming,
                                               replyFilePath: replyFile) {
            // Named on its side the way she knows it, so the person recognizes it there.
            let label = AgentConversationLiveContext.target?.recordID.flatMap { id in
                (try? AgentConversationStore(dataRoot: dataRoot).records())?.first { $0.id == id }?.label
            } ?? "Main"
            let her = PersonaCompiler.agentDisplayName(dataRoot: dataRoot)
            return (["NativeAgent"] + (her == "NativeAgent" ? [] : [her]) + [label]).joined(separator: " · ")
        }
        // Retain bounded protocol output before the runner clips stdout for
        // display; streaming events also reach the live view as they arrive.
        let (lines, linesIn) = AsyncStream<String>.makeStream()
        let streamed: Task<String, Never>? = line.stream != nil || line.jsonResultReply ? Task { [line] in
            let live = AgentConversationLiveContext.target
            let hub = AgentConversationLiveHub.shared
            var whole = "", active = false, overflow = false
            var retainedBytes = 0
            for await text in lines {
                let parsed = line.streamEvent(line: text)
                if parsed.retain, !overflow {
                    retainedBytes += text.utf8.count + 1
                    if retainedBytes <= 16 * 1024 * 1024 { whole += text + "\n" }
                    else { overflow = true; whole = "" }
                }
                guard let live, let event = parsed.event else { continue }
                if !active { await hub.activity(live); active = true }
                switch event {
                case .text(let chunk, whole: true): await hub.text(live, replace: chunk)
                case .text(let chunk, whole: false): await hub.text(live, delta: chunk)
                case .note(let note): await hub.note(live, note)
                case .activity: break
                }
            }
            return whole
        } : nil
        // The runner closes stdin. Pass the approved executable and argv directly.
        // The stdout handler's parameter and @Sendable-ness come from this
        // annotation, not inference through the nil ternary branch; the yield
        // result is intentionally discarded.
        let onStdoutLine: (@Sendable (String) -> Void)? = streamed == nil ? nil : { @Sendable in _ = linesIn.yield($0) }
        let outcome = await Self.runShellLikeProcess(
            toolName: "agent_message", executable: executable,
            args: argv,
            cwd: workingDirectory.path, timeoutSeconds: line.timeoutSeconds,
            sourcePayloadForAudit: probe ? AgentHostDirectory.probeToken : nil, dataRoot: dataRoot,
            // This app's own environment holds provider keys and the bridge
            // token; another agent's command gets a scrubbed one instead. And
            // nothing it backgrounds may outlive the run or its directory.
            environmentOverride: environment,
            closeStandardInput: true,
            reapDescendantsOnExit: true,
            onStdoutLine: onStdoutLine)
        return await settle {
            defer {
                try? FileManager.default.removeItem(at: replyDirectory)
                if let probeNonce {
                    _ = store.finishConnectionProbe(peerID: contact.id, nonce: probeNonce, ran: false,
                        workspace: workingDirectory.path)
                }
            }
            linesIn.finish()
            let streamedStdout = await streamed?.value
            guard case .object(var envelope) = outcome else { return outcome }
            if let streamedStdout { envelope["stdout"] = .string(streamedStdout) }
            let stdout = envelope["stdout"]?.stringValue
            let parsed = line.interpretOutput(stdout: stdout ?? "", expected: resuming ? session : nil)
            var reply = ""
            var truncated = false
            if line.jsonResultReply, stdout != nil {
                let response = parsed.reply ?? ""
                truncated = response.utf8.count > 64 * 1024
                reply = String(decoding: response.utf8.prefix(64 * 1024), as: UTF8.self)
            } else if let replyFile, let handle = FileHandle(forReadingAtPath: replyFile) {
                defer { try? handle.close() }
                // Bounded at the READ, not after it: a reply file is written by
                // another program and its size is that program's choice. One byte
                // past the cap is how we know to say so.
                let data = (try? handle.read(upToCount: 64 * 1024 + 1)) ?? Data()
                truncated = data.count > 64 * 1024
                reply = String(decoding: data.prefix(64 * 1024), as: UTF8.self)
            } else if !line.capturesThreadID, let stdout {
                reply = stdout
                truncated = envelope["_truncated"] == .bool(true)
            }
            reply = reply.trimmingCharacters(in: .whitespacesAndNewlines)
            let ran = envelope["ran"] == .bool(true)
            let commandSucceeded = envelope["status"] == .string("completed")
            // THE ROUND TRIP, recorded where it happened: a message left and a
            // reply came back. Nothing short of that promotes the contact — and
            // the CONNECT PROBE is deliberately not counted as a reply arriving.
            // What the probe asks to be proven is the ENTRY, so only the inbound
            // request carrying this connection's key may promote it; the probe's
            // own stdout is the command line talking, which proves nothing about
            // the entry that was just written.
            let replied = commandSucceeded && parsed.failure == nil && !reply.isEmpty
            // A run she stopped says nothing about whether the contact works.
            let arrived = envelope["status"] == .string("stopped") ? false : Self.recordHostConnectionOutcome(store: store, contact: contact, ran: ran,
                replied: replied, probe: probe, probeNonce: probeNonce,
                executable: executable, workspace: workingDirectory.path, recipe: recipe)
            let settled = (try? store.list().first { $0.id == contact.id }) ?? contact
            let state = Self.currentPeerState(settled, peers: (try? store.list()) ?? [])
            var result: [String: JSONValue] = [
                "status": .string(replied ? "replied" : "outcome_unknown"),
                "agent": .string(agent), "transport": .string("mcpHost"), "host": .string(row.id),
                "state": .string(state.rawValue), "state_detail": .string(state.detail),
                "ran": .bool(ran), "command_succeeded": .bool(commandSucceeded),
                "sent": replied || arrived ? .bool(true) : ran ? .null : .bool(false), "completed": .bool(replied),
                "effects": .string(replied || arrived ? "occurred" : ran ? "unknown" : "none"),
                "reply": .string(reply), "reply_truncated": .bool(truncated),
                "untrusted_remote_data": .bool(!reply.isEmpty),
                "exit_code": envelope["exit_code"] ?? .null, "timed_out": envelope["timed_out"] ?? .bool(false),
                // The process has exited (or hit the recipe's timeout): nothing more arrives on this call.
                "terminal": .bool(true),
            ]
            if line.capturesThreadID {
                if let confirmed = parsed.threadID {
                    result["conversation_id"] = .string(confirmed)
                    result["continuation_available"] = .bool(true)
                } else {
                    result["continuation_available"] = .bool(false)
                    result["continuation_detail"] = .string("The command did not confirm the expected conversation identity. Its reply is retained, but continuity is unverified. Do not resend automatically or silently start a replacement conversation.")
                }
            } else if let session { result["conversation_id"] = .string(session) }
            if probe {
                // Omit connection-probe reply content and its taint so a successful check
                // preserves the person's authority for subsequent requests in the same turn.
                result["reply"] = nil
                result["reply_truncated"] = nil
                result["untrusted_remote_data"] = nil
                result["connection_check"] = .bool(true)
                result["connection_reply_received"] = .bool(arrived)
                if !arrived {
                    result["detail"] = .string("No new answer arrived through the connection. The other app may need to restart before it can reply here.")
                }
            }
            if envelope["status"] == .string("stopped") {
                // agent_cancel: interrupted at her request, not a failure of the contact.
                result["status"] = .string("stopped")
                result["detail"] = .string("Stopped at your request: \(row.displayName)'s run was interrupted. Anything it said before stopping is kept above; nothing was resent.")
            } else if !replied {
                if let failure = parsed.failure {
                    // The normalized refusal repeats its cause; keep even JSON-escaped diagnostics within the receipt's 96 KiB limit.
                    let diagnostic = String(decoding: failure.utf8.prefix(3 * 1024), as: UTF8.self)
                        + (failure.utf8.count > 3 * 1024 ? "\n[diagnostic truncated]" : "")
                    let refusal = ToolFailureError("\(row.displayName)'s command failed: \(diagnostic). Do not resend automatically.",
                        effects: .unknown, owner: "\(row.displayName) command line",
                        tap: "Terminal → run `\(line.executable)` once; sign in if requested and resolve its reported error before continuing this conversation")
                    if case .object(let fields) = ChatToolOutcome.failure(error: refusal) {
                        result.merge(fields) { _, failure in failure }
                    }
                    result["detail"] = .string(ChatSecretRedactor.redactText(refusal.message))
                } else {
                    result["detail"] = .string(
                        "\(row.displayName)'s command line did not come back with a reply, so nothing is proven. "
                        + "Its own output is in stderr. Do not resend automatically.")
                    if case .string(let text)? = envelope["stderr"] { result["stderr"] = .string(text) }
                    if case .string(let text)? = envelope["stderr"] {
                        let cause = ProviderFailure.wire(text, fallback: .malformedResponse)
                        if cause != .malformedResponse {
                            Self.peerFailure(.init(cause: cause, work: ran ? .outcomeUnknown : .nothingRan), into: &result)
                        }
                    }
                }
            }
            result["untrusted_remote_data"] = .bool(parsed.failure != nil || PeerDataTaintDispatcher.containsPeerText(.object([
                "reply": result["reply"] ?? .null, "stderr": result["stderr"] ?? .null,
            ])))
            return Self.peerRedact(.object(result), token: nil)
        }
    }
    /// A CLI reply proves that route; the MCP return path has separate evidence.
}
