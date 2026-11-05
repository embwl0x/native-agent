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
// Blueprint: | `AgentContactCommand.swift` | Keep launch, reply and delivery evidence distinct. |
extension SwiftToolDispatcher {
    func hostCommandRun(turn: Turn, invocation: ChatToolInvocation,
        row: AgentHostRow, contact: AgentPeerContact, message: String, session: String?,
        resuming: Bool = false, store: AgentPeerStore, surface: String, probe: Bool = false
    ) async throws -> JSONValue {
        guard let line = row.commandLine else { throw AgentCommunicationError.invalid("\(row.displayName) has no command line to run") }
        if let failure = row.installation.failure { throw failure }
        let recipe = AgentRecipeStore.recipe(row.id)
        if invocation.dryRun {
            var result: [String: JSONValue] = ["status": .string("failed"), "dry_run": .bool(true),
                "agent": .string("peer:" + contact.id), "transport": .string("mcpHost"), "host": .string(row.id),
                "sent": .bool(false), "ran": .bool(false), "completed": .bool(false),
                "command": .string(line.executable),
                "arguments": .array((resuming ? line.continuation : line.arguments).map(JSONValue.string)),
                "checked": .array([.string("commandLine.executable"), .string("commandLine.arguments")])]
            guard let executable = row.resolveExecutable(line.executable) else {
                result["detail"] = .string("""
                    \(row.displayName)'s readiness check failed: \(line.executable) could not be resolved to a runnable file; no prompt was sent.
                    """)
                return .object(result)
            }
            result["executable"] = .string(executable)
            if line.minimumVersion != nil, let tooOld = line.versionFailure(program: line.executable,
                reported: try await AgentACPExecutable.capture(path: executable).reported(environment: row.installation.launchEnvironment())) {
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
        let access = try await fullMacToolAccess(turn: turn, surface: surface)
        guard access.fileOpsAllowed else {
            let refusal = builderFullMacRequired(invocation: invocation, tool: "agent_message")
            let reply = ToolResult(refusal)
            var value: [String: JSONValue] = [:]
            if case .object(let fields) = refusal { value = fields }
            if reply.said("failed"), reply.status == value["status"]?.stringValue {
                value["status"] = .string("blocked_by_trust")
            }
            let mode = access.permissionLevel == "balanced" ? "Work mode" : "the current trust mode"
            value["reason"] = .string("trust_center_full_mac_required")
            value["sent"] = .bool(false)
            value["ran"] = .bool(false)
            value["completed"] = .bool(false)
            value["detail"] = .string(probe
                ? """
                    The entry is written, but I couldn't check the link in \(mode) because running that agent here needs Builder or Full Mac; \
                    switch in Trust or the composer and say connect again, or use the connection from the other agent's side.
                    """
                : """
                    I didn't send the message in \(mode) because running that agent here needs Builder or Full Mac; switch in Trust or the composer \
                    and ask me to send it again, or use the connection from the other agent's side.
                    """)
            if probe {
                value["connection_check"] = .bool(true)
                value["connection_reply_received"] = .bool(false)
            }
            return .object(value)
        }
        let agent = "peer:" + contact.id
        func honest(_ status: String, _ detail: String) -> JSONValue {
            store.recordUnavailable(peerID: contact.id)
            var value: [String: JSONValue] = ["status": .string(status), "agent": .string(agent), "transport": .string("mcpHost"),
                     "host": .string(row.id), "sent": .bool(false), "completed": .bool(false), "detail": .string(detail)]
            value.merge(Self.checkedPeerReadout(contact.id, store: store).fields) { _, current in current }
            return .object(value)
        }
        // Every command route reconciles its binding, including those without permission flags.
        let launch: DrivenAgentLaunch.Program
        switch await Self.drivenAgentLaunch(turn: turn, surface: surface, contact: contact,
                                           name: row.displayName, dataRoot: dataRoot) {
        case .refused(let refusal): return refusal
        case .admitted(let program): launch = program
        }
        let executable = launch.executable
        let environment = try row.installation.launchEnvironment()
        if line.minimumVersion != nil {
            // The approved program's receipt keeps the version it reported, read once when it was approved; the launch re-verifies those exact bytes.
            var reported = try Self.checkedPeerSnapshot(contact.id, store: store).contact.acpExecutable.flatMap { $0.path == executable ? $0.version : nil }
            if reported == nil {
                reported = try await AgentACPExecutable.capture(path: executable).reported(environment: row.installation.launchEnvironment())
                if let reported {
                    guard try store.approveExecutable(peerID: contact.id, path: executable, version: reported) else {
                        return honest("unavailable", """
                            The contact changed before its program's version could be recorded. Read agent.contacts before continuing; nothing ran.
                            """)
                    }
                }
            }
            if let tooOld = line.versionFailure(program: line.executable, reported: reported) { return honest("unavailable", tooOld) }
        }
        let launchArguments = launch.arguments
        let conversationLabel: String
        if let id = invocation.liveTarget?.recordID {
            guard let record = try AgentConversationStore(dataRoot: dataRoot).records().first(where: { $0.id == id }) else {
                throw ToolFailureError("No saved record matches the active conversation identity. Read the contact's conversation before sending; nothing ran.",
                    effects: .none, owner: "Agent conversations",
                        instruction: "Open this contact's saved conversation and continue from its current identity.", recovery: .inspect)
            }
            conversationLabel = record.label
        } else { conversationLabel = "Main" }
        // Reuse one workspace directory per agent because some CLIs persist every working directory as a trusted project.
        let workingDirectory = contact.hostWorkspace.map { URL(fileURLWithPath: $0) }
            ?? Self.builderWorkspaceRoot(dataRoot: dataRoot).appendingPathComponent("agent-bridge-runs/" + row.id)
        do {
            try FileManager.default.createDirectory(at: workingDirectory, withIntermediateDirectories: true,
                                                    attributes: [.posixPermissions: 0o700])
        } catch { return honest("unavailable", "The run's working directory could not be created: \(error.localizedDescription). Nothing ran.") }
        // The reply file is this run's alone, so two messages at once never read each other's.
        let replyDirectory = workingDirectory.appendingPathComponent(UUID().uuidString.lowercased())
        do {
            try FileManager.default.createDirectory(at: replyDirectory, withIntermediateDirectories: true,
                                                    attributes: [.posixPermissions: 0o700])
        } catch { return honest("unavailable", "The run's reply directory could not be created: \(error.localizedDescription). Nothing ran.") }
        let replyFile = line.replyFileName.map { replyDirectory.appendingPathComponent($0).path }
        let probeNonce: String?
        do {
            probeNonce = probe ? try store.beginConnectionProbe(peerID: contact.id, timeout: TimeInterval(line.timeoutSeconds)) : nil
        } catch {
            try? FileManager.default.removeItem(at: replyDirectory)
            return honest("unavailable", "The connection check could not be recorded. Nothing ran.")
        }
        let outgoing = probeNonce.map { AgentHostDirectory.probeText(appName: Self.appDisplayName, nonce: $0) } ?? message
        let argv = launchArguments + line.argv(message: outgoing, session: session, resuming: resuming,
                                               replyFilePath: replyFile) {
            let agentName = PersonaCompiler.agentDisplayName(dataRoot: dataRoot)
            return (["NativeAgent"] + (agentName == "NativeAgent" ? [] : [agentName]) + [conversationLabel]).joined(separator: " · ")
        }
        // Retain bounded protocol output before the runner clips stdout for display; streaming events also reach the live view as they arrive.
        let (lines, linesIn) = AsyncStream<String>.makeStream()
        let streamed: Task<String, Never>? = line.stream != nil || line.jsonResultReply ? Task { [line, invocation] in
            let live = invocation.liveTarget
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
        // Closed stdin prevents interactive waits. Explicit @Sendable annotation types the stdout closure across the nil branch; its yield result is discarded.
        let onStdoutLine: (@Sendable (String) -> Void)? = streamed == nil ? nil : { @Sendable in _ = linesIn.yield($0) }
        let outcome = await Self.runShellLikeProcess(
            turn: turn,
            toolName: "agent_message", executable: executable,
            args: argv,
            cwd: workingDirectory.path, timeoutSeconds: line.timeoutSeconds,
            sourcePayloadForAudit: probe ? AgentHostDirectory.probeToken : nil, dataRoot: dataRoot,
            // Scrub peer environments to protect provider keys and bridge credentials; background work must not outlive its run or directory.
            environmentOverride: environment,
            closeStandardInput: true,
            reapDescendantsOnExit: true,
            onStdoutLine: onStdoutLine)
        return await settle {
            let commandReply = ToolResult(outcome)
            defer {
                try? FileManager.default.removeItem(at: replyDirectory)
                if let probeNonce {
                    do { _ = try store.finishConnectionProbe(peerID: contact.id, nonce: probeNonce, ran: false,
                        workspace: workingDirectory.path) }
                    catch { store.recordEvidenceFailure(peerID: contact.id, operation: "connection-probe", error: error) }
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
            var replyFailure: ToolFailureError?
            if line.jsonResultReply {
                let response = parsed.reply ?? ""
                truncated = response.utf8.count > 64 * 1024
                reply = String(decoding: response.utf8.prefix(64 * 1024), as: UTF8.self)
                if stdout == nil {
                    replyFailure = ToolFailureError("""
                        \(row.displayName)'s declared JSON reply output was not captured. Its process result is retained; do not resend \
                        automatically.
                        """,
                        effects: envelope["ran"] == .bool(true) ? .unknown : .none, owner: row.displayName + " command line",
                        code: "agent_reply_output_unavailable",
                        instruction: "Repair the command's output capture and reconcile this run before another send.", recovery: .reconcile)
                }
            } else if let replyFile {
                do {
                let handle = try FileHandle(forReadingFrom: URL(fileURLWithPath: replyFile))
                defer { try? handle.close() }
                // Bound peer-controlled reply files while reading, retaining one extra scalar so clipping cannot split UTF-8.
                let data = try handle.read(upToCount: 64 * 1024 + 4) ?? Data()
                truncated = data.count > 64 * 1024
                var decoded: String?
                if truncated {
                    // Every candidate contains all bytes inside the retained bound. Invalid body bytes cannot disappear by clipping.
                    for end in (64 * 1024)...min(data.count, 64 * 1024 + 3) where decoded == nil {
                        decoded = String(data: data.prefix(end), encoding: .utf8)
                    }
                } else { decoded = String(data: data, encoding: .utf8) }
                guard var decoded else {
                    throw ToolFailureError("The command's reply file is not valid UTF-8.", effects: .unknown)
                }
                while decoded.utf8.count > 64 * 1024 { decoded.removeLast() }
                reply = decoded
                } catch {
                    replyFailure = ToolFailureError("""
                        \(row.displayName)'s declared reply file could not be read: \(error.localizedDescription). Its process result is retained; \
                        do not resend automatically.
                        """,
                        effects: envelope["ran"] == .bool(true) ? .unknown : .none, owner: replyFile,
                        code: "agent_reply_file_unavailable",
                        instruction: "Repair the command recipe's reply-file output and reconcile this run before another send.", recovery: .reconcile)
                }
            } else if !line.capturesThreadID, let stdout {
                reply = stdout
                truncated = envelope["_truncated"] == .bool(true)
            }
            reply = reply.trimmingCharacters(in: .whitespacesAndNewlines)
            let ran = envelope["ran"] == .bool(true)
            let commandSucceeded = commandReply.said("completed") && commandReply.status == envelope["status"]?.stringValue
            let stopped = commandReply.said("stopped") && commandReply.status == envelope["status"]?.stringValue
            // Only an actual reply proves a command route. A connection probe proves the inbound entry only through a request carrying its key, never stdout.
            let replied = commandSucceeded && parsed.failure == nil && replyFailure == nil && !reply.isEmpty
            // A run the agent stopped says nothing about whether the contact works.
            let arrived: Bool?
            var evidenceFailure: String?
            do {
                arrived = stopped ? false : try Self.recordHostConnectionOutcome(store: store, contact: contact, ran: ran,
                    replied: replied, probe: probe, probeNonce: probeNonce,
                    executable: executable, workspace: workingDirectory.path, recipe: recipe)
            } catch {
                arrived = nil
                evidenceFailure = error.localizedDescription
                store.recordEvidenceFailure(peerID: contact.id, operation: "connection-probe", error: error)
            }
            var result: [String: JSONValue] = [
                "status": .string(replied ? "replied" : "outcome_unknown"),
                "agent": .string(agent), "transport": .string("mcpHost"), "host": .string(row.id),
                "ran": .bool(ran), "command_succeeded": .bool(commandSucceeded),
                "sent": replied || arrived == true ? .bool(true) : ran ? .null : .bool(false), "completed": .bool(replied),
                "effects": .string(replied || arrived == true ? "occurred" : ran ? "unknown" : "none"),
                "reply": .string(reply), "reply_truncated": .bool(truncated),
                "untrusted_remote_data": .bool(!reply.isEmpty),
                "exit_code": envelope["exit_code"] ?? .null, "timed_out": envelope["timed_out"] ?? .bool(false),
                // The process has exited (or hit the recipe's timeout): nothing more arrives on this call.
                "terminal": .bool(true),
            ]
            result.merge(Self.checkedPeerReadout(contact.id, store: store).fields) { _, current in current }
            if line.capturesThreadID {
                if let confirmed = parsed.threadID {
                    result["conversation_id"] = .string(confirmed)
                    result["continuation_available"] = .bool(true)
                } else {
                    result["continuation_available"] = .bool(false)
                    result["continuation_detail"] = .string("""
                        The command did not confirm the expected conversation identity. Its reply is retained, but continuity is unverified. Do not \
                        resend automatically or silently start a replacement conversation.
                        """)
                }
            } else if let session { result["conversation_id"] = .string(session) }
            if probe {
                // Omit probe reply content and taint so connection checks preserve the person's authority for later requests in this turn.
                result["reply"] = nil
                result["reply_truncated"] = nil
                result["untrusted_remote_data"] = nil
                result["connection_check"] = .bool(true)
                result["connection_reply_received"] = arrived.map(JSONValue.bool) ?? .null
                if arrived == false {
                    result["detail"] = .string("No new answer arrived through the connection. The other app may need to restart before it can reply here.")
                }
            }
            if stopped {
                // A requested interruption is not evidence that the contact failed.
                result["status"] = .string("stopped")
                result["detail"] = .string("""
                    Stopped at your request: \(row.displayName)'s run was interrupted. Anything it said before stopping is kept above; nothing was \
                    resent.
                    """)
            } else if let replyFailure {
                if case .object(let fields) = ChatToolOutcome.failure(error: replyFailure) {
                    result.merge(fields) { _, failure in failure }
                }
                if arrived == true { result["effects"] = .string("occurred") }
                result["detail"] = .string(replyFailure.message)
                result["process_stdout"] = envelope["stdout"]
                result["stderr"] = envelope["stderr"]
            } else if !replied {
                if let failure = parsed.failure {
                    // The normalized refusal repeats its cause; keep even JSON-escaped diagnostics within the receipt's 96 KiB limit.
                    let diagnostic = String(decoding: failure.utf8.prefix(3 * 1024), as: UTF8.self)
                        + (failure.utf8.count > 3 * 1024 ? "\n[diagnostic truncated]" : "")
                    let refusal = ToolFailureError("\(row.displayName)'s command failed: \(diagnostic). Do not resend automatically.",
                        effects: .unknown, owner: "\(row.displayName) command line",
                        tap: """
                            Terminal → run `\(line.executable)` once; sign in if requested and resolve its reported error before continuing this \
                            conversation
                            """)
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
            if let evidenceFailure {
                result["durable_evidence_error"] = .string(evidenceFailure)
                result["detail"] = .string("The command outcome above is retained, but connection evidence could not be saved: " + evidenceFailure
                    + ". Repair agents/peers.json and reconcile this operation; do not resend it.")
            }
            result["untrusted_remote_data"] = .bool(parsed.failure != nil || PeerDataTaintDispatcher.containsPeerText(.object([
                "reply": result["reply"] ?? .null, "stderr": result["stderr"] ?? .null, "stdout": result["process_stdout"] ?? .null,
            ])))
            return Self.peerRedact(.object(result), token: nil)
        }
    }
    /// A CLI reply proves that route; the MCP return path has separate evidence.
}
