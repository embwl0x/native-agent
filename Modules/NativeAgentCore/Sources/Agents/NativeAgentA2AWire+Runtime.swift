import Foundation
import AgentLinkTransport
import ToolRegistry
import Network
import ChatTurnRuntime
import AgentConversations
import ChatToolParsing
import NativeAgentCore
import PersistenceCore
import ProviderRouting
import StandingBots
import Experiences
import AgentWorkspace
import Privacy

// Blueprint: | `NativeAgentA2AWire+Runtime.swift` | Shared admission and canonical reply framing. |

public struct AgentContactA2AEndpoint: Sendable {
    public enum Response: @unchecked Sendable {
        case json([String: Any], onSent: (@Sendable () async -> Void)? = nil, onFailed: (@Sendable () -> Void)? = nil)
        case stream(id: Any, events: AsyncStream<AgentContactEvent>, version: String,
                    metadata: JSONValue, onSent: @Sendable (AgentContactEvent) async -> Void, settle: @Sendable (Bool) -> Void)

        func failed() {
            switch self {
            case .json(_, _, let onFailed): onFailed?()
            case .stream(_, _, _, _, _, let settle): settle(false)
            }
        }
    }
    let tasks: AgentContactTasks
    var port: UInt16 = 0
    var grpcPort: UInt16? = nil

    public init(tasks: AgentContactTasks, port: UInt16 = 0, grpcPort: UInt16? = nil) {
        self.tasks = tasks; self.port = port; self.grpcPort = grpcPort
    }

    public func handle(_ decoded: Any?, byteCount: Int, principal: AgentBridgePrincipal, version: String? = nil) async -> Response {
        let envelope = decoded as? [String: Any]
        let method = envelope?["method"] as? String ?? ""
        let wireVersion = method.contains("/") ? "0.3" : "1.0"
        if let version, !version.isEmpty {
            guard let pair = AgentA2AWire.canonicalVersion(version) else {
                return .json(NativeAgentA2AWire.error(envelope?["id"] ?? NSNull(), -32009, "Supported versions: 1.0, 0.3"))
            }
            if pair != wireVersion {
                return .json(NativeAgentA2AWire.error(envelope?["id"] ?? NSNull(), -32601, "Method does not belong to the requested A2A version"))
            }
        }
        let action = NativeAgentA2AWire.parse(decoded, byteCount: byteCount, defaultContext: principal.conversationID(protocolName: "a2a"))
        let id: Any
        switch action {
        case .response(let response): return .json(response)
        case .send(let send): id = send.rpcID
        case .get(let rpc, _), .subscribe(let rpc, _), .cancel(let rpc, _), .list(let rpc, _), .push(let rpc, _, _), .extended(let rpc): id = rpc
        }
        do {
            switch action {
            case .response(let value): return .json(value)
            case .extended:
                return .json(NativeAgentA2AWire.result(id, NativeAgentA2AWire.card(port: port, version: wireVersion, extended: true, grpcPort: grpcPort)))
            case .push(_, let operation, let params):
                let value = try await tasks.push(operation: operation, owner: principal.id, parameters: JSONValue(fromFoundation: params))
                return .json(NativeAgentA2AWire.result(id, value.foundationObject as! [String: Any]))
            case .send(let send):
                // Method and params, not the envelope: a client retrying the same messageId mints a new JSON-RPC id.
                let replayBytes = try JSONSerialization.data(withJSONObject: ["method": method, "params": envelope?["params"] ?? NSNull()],
                    options: .sortedKeys)
                let task = try await tasks.send(send, principal: principal, digest: AgentPeerReplayClaimStore.digest(replayBytes))
                if send.streaming {
                    return try await streamResponse(id: id, task: task.id, principal: principal, version: wireVersion)
                }
                let returned = send.blocking ? try await tasks.settled(task.id, owner: principal.id) : task
                return try await replyResponse(id: id, task: returned, principal: principal, version: wireVersion, sending: true)
            case .get(_, let task):
                let returned = try await tasks.get(task, owner: principal.id)
                return try await replyResponse(id: id, task: returned, principal: principal, version: wireVersion)
            case .subscribe(_, let task):
                if wireVersion == "1.0", try await tasks.get(task, owner: principal.id).state.terminal {
                    throw AgentContactFailure(code: -32004, message: "This task has ended; retrieve it with GetTask")
                }
                return try await streamResponse(id: id, task: task, principal: principal, version: wireVersion)
            case .cancel(_, let task):
                return .json(NativeAgentA2AWire.result(id, try NativeAgentA2AWire.project(try await tasks.cancel(task, owner: principal.id),
                    version: wireVersion)))
            case .list(_, let params):
                let listed = try await tasks.list(owner: principal.id, parameters: JSONValue(fromFoundation: params))
                return .json(NativeAgentA2AWire.result(id, listed.foundationObject as! [String: Any]))
            }
        } catch let failure as AgentContactFailure {
            return .json(NativeAgentA2AWire.error(id, failure.code, failure.message))
        } catch {
            return .json(NativeAgentA2AWire.error(id, -32603, "Work could not be accepted. Do not send it again automatically."))
        }
    }

    private func heldResponse(principal: AgentBridgePrincipal) async throws -> AgentContactHeldResponse {
        do { return try AgentContactHeldResponse(principal: principal, dataRoot: tasks.dataRoot, via: "a2a") }
        catch {
            throw AgentContactFailure(code: -32603, message: "Held-message drain failed: "
                + NativeAgentSecretRedactor.redactText(error.localizedDescription) + ". No held message was taken.")
        }
    }

    private func replyResponse(id: Any, task: AgentContactTask, principal: AgentBridgePrincipal,
                               version: String, sending: Bool = false) async throws -> Response {
        var projected = try NativeAgentA2AWire.project(task, version: version)
        let held = try await heldResponse(principal: principal)
        if case .object(let fields) = held.metadata, !fields.isEmpty { projected["metadata"] = held.metadata.foundationObject }
        let fetched = replyAcknowledgement(task)
        return .json(NativeAgentA2AWire.result(id, sending && version == "1.0" ? ["task": projected] : projected),
            onSent: { held.settle(true); await fetched?() }, onFailed: { held.settle(false) })
    }

    private func streamResponse(id: Any, task: String, principal: AgentBridgePrincipal, version: String) async throws -> Response {
        let events = try await tasks.subscribe(task, owner: principal.id)
        let held = try await heldResponse(principal: principal)
        return .stream(id: id, events: events, version: version, metadata: held.metadata,
            onSent: eventAcknowledgement, settle: held.settle)
    }

    /// Settle transport delivery only after the selected reply is written.
    private func replyAcknowledgement(_ task: AgentContactTask) -> (@Sendable () async -> Void)? {
        guard !task.text.isEmpty || !task.parts.isEmpty || task.delegatedCompletions?.isEmpty == false else { return nil }
        return { await tasks.recordReplyFetch(task) }
    }

    private func eventAcknowledgement(_ event: AgentContactEvent) async {
        let task: AgentContactTask
        switch event {
        case .snapshot(let value), .status(let value, _), .artifact(let value, _, _, _, _): task = value
        }
        await replyAcknowledgement(task)?()
    }
}

enum AgentContactRuntime {
    private static func revalidated(_ principal: AgentBridgePrincipal, dataRoot: URL) throws -> AgentBridgePrincipal {
        if let id = principal.localHelperID {
            let bot = try BotDefinitionStore(dataRoot: dataRoot).get(id)
            guard bot.deleted != true else { throw AgentContactFailure.missing }
            return AgentBridgePrincipal(id: principal.id, peerID: principal.peerID, elevated: false,
                displayName: bot.name, localHelperID: id)
        }
        guard let peerID = principal.peerID else { return principal }
        guard let peer = try AgentPeerStore(dataRoot: dataRoot).list().first(where: { $0.id == peerID }),
              peer.grokSetup != "disconnected" else {
            throw AgentContactFailure(code: -32001, message: "The contact is no longer connected. Work: nothing ran.")
        }
        return AgentBridgePrincipal(id: principal.id, peerID: peerID,
            elevated: principal.elevated && peer.elevationAllowed, displayName: peer.name,
            replyOnly: principal.replyOnly)
    }

    static func run(_ turn: AgentContactTurn, client: SwiftNativeChatOrchestrationClient, dataRoot: URL,
                    enqueued acceptedMessage: EnqueuedUserMessage? = nil,
                    completionSender: (any AgentBridgeCompletionSending)? = nil,
                    emit: @escaping @Sendable (AgentContactProgress) async -> Void) async throws -> AgentContactOutcome {
        let principal = turn.principal
        let attachments = turn.parts.compactMap(\.attachment)
        let plain = turn.parts.compactMap { if case .text(let text) = $0 { return text }; return nil }.joined(separator: "\n")
        let acceptedMessage = acceptedMessage ?? turn.accepted
        let session = acceptedMessage?.sessionId ?? principal.storedConversation(turn.context)
        // A job's turn is told what it is and where its files are; saving them again after a restart writes the same bytes.
        let jobLines: String
        if let job = turn.job {
            // A contact that is gone gets no folder.
            _ = try revalidated(principal, dataRoot: dataRoot)
            let inputs = try AgentContactJob.stage(turn.parts, taskID: turn.taskID, dataRoot: dataRoot)
            jobLines = AgentBridgeSurface.jobLines(folder: AgentContactJob.folder(taskID: turn.taskID, dataRoot: dataRoot), inputs: inputs, done: job.done)
        } else { jobLines = "" }
        // A job is new work, never the answer to a send of the agent's that is waiting on this contact.
        if acceptedMessage == nil, turn.job == nil, turn.parts.allSatisfy({ if case .text = $0 { true } else { false } }),
           let peerID = try revalidated(principal, dataRoot: dataRoot).peerID {
            let from = "peer:" + peerID
            let offered = await settle {
                Result {
                    try AgentConversationStore(dataRoot: dataRoot).offerBridgeReplyToInlineWait(
                        agent: from, conversationID: turn.context, text: plain, from: from, steeredBy: [from])
                }
            }
            if try offered.get() {
                return AgentContactOutcome(state: .completed,
                    parts: [.text("Your reply was returned to the waiting conversation.")])
            }
        }
        // Pin the minted run before enqueue so the canonical row keeps the same identity.
        let runID = acceptedMessage?.runId ?? UUID().uuidString
        let enqueued: EnqueuedUserMessage
        if let acceptedMessage { enqueued = acceptedMessage } else {
            // Persist the task binding before session admission waits so restart can resume queued input from its row.
            var request = try revalidated(principal, dataRoot: dataRoot).turnRequest(context: turn.context, plain: plain,
                attachments: attachments, messageID: turn.requestID, jobLines: jobLines)
            request.pinnedRunID = .some(runID)
            enqueued = try await request.enqueue(on: client)
            try await turn.bindRun(session, enqueued.runId)
        }
        // One turn at a time in this conversation: a second message waits for the first reply to finish instead of interleaving with it. Admission registers
        // the run for Stop before it waits.
        let arriving = principal.turnRequest(context: turn.context, plain: plain, attachments: attachments,
            messageID: turn.requestID, jobLines: jobLines).consuming(enqueued)
        let admitted = try await TurnAdmission.admittedRun(turn: arriving.turn(), arrival: arriving.arrival(.saved), dataRoot: dataRoot,
            waitForCapacity: true) { held in
            try Task.checkCancellation()
            // Bind externally accepted messages only at admission.
            if acceptedMessage != nil { try await turn.bindRun(session, enqueued.runId) }
            // The wait suspends too; bind only current authority.
            let current = try revalidated(principal, dataRoot: dataRoot)
            var request = current.turnRequest(context: turn.context, plain: plain,
                attachments: attachments, messageID: turn.requestID, originID: turn.bridgeInput?.originID, jobLines: jobLines)
            if let peerID = principal.peerID { AgentPeerStore(dataRoot: dataRoot).recordProof(peerID: peerID, inbound: true) }
            if let binding = turn.bridgeInput {
                // The canonical queued row already carries its complete framed input. Preserve its selected session/persona without framing twice.
                request.message = plain
                request.sessionID = session
                request.verifiedSessionID = .some(session)
                request.ownedSessionID = binding.ownedSessionID
                request.persona = binding.persona
                guard let completionSender else {
                    throw AgentContactFailure(code: -32603, message: "Builder reply settlement is unavailable; no turn ran.")
                }
                let owner = try AgentContactIdentity(dataRoot: dataRoot).canonical("peer:" + current.id)
                // Both authenticated contact framing and anonymous header-only input remain live shapes.
                let replyText: String
                if current.peerID != nil {
                    guard let words = AgentBridgeSurface.message(inTurn: plain) else {
                        throw AgentContactFailure(code: -32603, message: "The saved builder contact framing is unreadable; no turn ran.")
                    }
                    replyText = words
                } else {
                    let header = AgentBridgeSurface.turnHeader(peerName: principal.displayName, elevated: principal.elevated)
                    guard plain.hasPrefix(header) else {
                        throw AgentContactFailure(code: -32603, message: "The saved builder header is unreadable; no turn ran.")
                    }
                    replyText = String(plain.dropFirst(header.count))
                }
                request.queryUserMessage = .some(replyText)
                await emit(.working)
                let acceptedRequest = request.consuming(enqueued)
                let heldTurn = acceptedRequest.turn(id: held.id, parent: held)
                let reply = try await acceptedRequest.chat(on: client, holding: heldTurn)
                await MainActor.run {
                    NotificationCenter.default.post(name: .chatTurnCompleted, object: session)
                }
                do {
                    try await ClaudeBridgeMessageRuntime.settleContactReply(turn: heldTurn, reply, request: request,
                        principal: current, owner: owner, replyID: binding.originID, replyText: replyText,
                        session: session, client: client, sender: completionSender)
                    return ClaudeBridgeMessageRuntime.bridgeOutcome(reply, taskID: turn.taskID, result: [:])
                } catch {
                    // Settlement debt must not discard the produced answer or files.
                    let detail = "The recovered builder reply needs settlement repair: " + error.localizedDescription
                    RepairOwed.owe(dataRoot, id: turn.requestID, kind: .message,
                        operation: "bridge.reply.settle:" + turn.requestID, owner: turn.taskID,
                        words: detail, lever: "Repair this exact retained task and run; do not repeat the turn.")
                    return ClaudeBridgeMessageRuntime.bridgeOutcome(reply, taskID: turn.taskID,
                        result: ["detail": detail])
                }
            }
            let text = request.message
            let acceptedRequest = request.consuming(enqueued)
            let heldTurn = acceptedRequest.turn(id: held.id, parent: held)
            do {
                try Task.checkCancellation()
                await emit(.working)
                let execution = client.chatStreamExecution(message: text, sessionId: session, model: "", reasoningEffort: "",
                    fileAccess: request.fileAccess, attachments: attachments, persona: request.persona, surface: current.surface,
                    suppressUserAppend: true, turn: heldTurn)
                let outcome = try await withTaskCancellationHandler {
                    var final: TurnEngineResult?
                    var waiting = false
                    var failure: String?
                    var ranPartly = false
                    do {
                        for try await event in execution.events {
                            try Task.checkCancellation()
                            switch event {
                            case .delta(let delta):
                                ranPartly = ranPartly || !delta.isEmpty
                                await emit(.text(delta))
                            case .toolResult(_, let output):
                                ranPartly = ranPartly || !ChatToolOutcome.wasCancelled(output) || ChatToolOutcome.effectsUnknown(output)
                                if ChatToolOutcome.isWaitingOnPerson(output) {
                                    if case .object(let fields) = output,
                                       case .string(let id) = fields["approvalId"] ?? fields["approval_id"] {
                                        await emit(.approval(id))
                                    }
                                    waiting = true
                                    await emit(.waiting)
                                }
                            case .final(let result): final = result
                            case .error(let message): failure = message
                            case .notice, .toolUse, .replyTextSettled, .writing: break
                            }
                        }
                    } catch {
                        // Stop is the turn's one cancel link: the run's flag.
                        if Task.isCancelled { try? await MacChatTurnRuntime(dataRoot: dataRoot).stop(sessionId: session, runId: runID) }
                        await execution.waitForProducerTermination()
                        throw ProviderFailure.report(error, work: ranPartly ? .ranPartly : nil) ?? error
                    }
                    await execution.waitForProducerTermination()
                    if let final, failure == nil, final.reply.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
                       try SwiftNativeChatOrchestrationClient.silentTurn(
                        dataRoot: dataRoot, sessionId: session, runId: runID, turnId: heldTurn.id) != nil {
                        return AgentContactOutcome(state: .completed, parts: [],
                            toolResult: .object(["status": .string("completed"), "silence": .string(heldTurn.id)]))
                    }
                    try Task.checkCancellation()
                    guard let final, failure == nil else {
                        return AgentContactOutcome(state: waiting ? .inputRequired : .failed,
                            parts: try final.map { try outputParts($0, taskID: turn.taskID, dataRoot: dataRoot, job: turn.job) } ?? [],
                            detail: waiting ? "Waiting for the person" : (failure ?? "The reply ended without a finished result") + ". Work: " + (
                                ranPartly ? "ran partly." : "outcome unknown."))
                    }
                    let parts = try outputParts(final, taskID: turn.taskID, dataRoot: dataRoot, job: turn.job)
                    // Only an explicit incomplete outcome retains unfinished-turn state, matching the chat owner.
                    let state: AgentContactTaskState = waiting ? .inputRequired : (final.completionState == .incomplete ? .failed : .completed)
                    return AgentContactOutcome(state: state, parts: parts,
                        detail: state == .failed ? "The work did not finish" : nil)
                } onCancel: { Task { try? await MacChatTurnRuntime(dataRoot: dataRoot).stop(sessionId: session, runId: runID) } }
                await MainActor.run {
                    NotificationCenter.default.post(name: .chatTurnCompleted, object: session)
                }
                // A started memory promotion finishes on its own; the reply and the session's next turn never wait for it.
                return outcome
            }
        }
        switch admitted {
        case .ran(let outcome): return outcome
        case .steered(let steered): return ClaudeBridgeMessageRuntime.steeredOutcome(steered)
        }
    }

    static func outputParts(_ result: TurnEngineResult, taskID: String, dataRoot: URL, job: AgentContactJob? = nil) throws -> [AgentContactPart] {
        var parts: [AgentContactPart] = result.reply.isEmpty ? [] : [.text(result.reply)]
        if let bytes = result.reply.data(using: .utf8), bytes.count <= 64000,
           let value = try? JSONDecoder().decode(JSONValue.self, from: bytes), case .object = value {
            parts.append(.data(value, metadata: .object(["source": .string("agent"), "taskId": .string(taskID)])))
        }
        // A file too big to send drops out, not the finished reply with it.
        let omitted = "[Files produced by this reply that were too large or unreadable were left out.]"
        var dropped = false
        if job != nil {
            // A job's artifacts are the files in its folder, whichever tool made them.
            let made = try AgentContactJob.fileParts(taskID: taskID, dataRoot: dataRoot)
            parts += made.parts
            dropped = made.unsent > 0
        } else {
            for attachment in ChatGeneratedImageArtifacts.attachments(from: result.toolDispatches, dataRoot: dataRoot) {
                if let part = try? AgentContactPart.output(attachment, taskID: taskID) { parts.append(part) } else { dropped = true }
            }
            // Use successful write receipts as produced-file evidence; never infer paths from prose or arbitrary tool results.
            for file in ChatWrittenFileArtifacts.files(from: result.toolDispatches, maximumBytes: AgentContactPart.maximumFileBytes) {
                parts.append(.file(name: file.name, mediaType: file.mime, bytes: file.bytes,
                                   metadata: .object(["source": .string("agent"), "taskId": .string(taskID)])))
            }
        }
        let size = try JSONSerialization.data(withJSONObject: parts.map(\.wire03)).count
        guard size <= AgentContactPart.maximumOutputBytes else {
            return parts.filter { if case .file = $0 { return false }; return true } + [.text(omitted)]
        }
        return dropped ? parts + [.text(omitted)] : parts
    }
}

public enum AgentContactSSE {
    static func envelope(_ event: AgentContactEvent, id: Any, version: String, metadata: JSONValue) throws -> [String: Any] {
        var envelope = NativeAgentA2AWire.event(event, id: id, version: version)
        guard envelope["error"] == nil else {
            throw AgentContactFailure(code: -32603, message: "The task update could not be encoded; no reply was acknowledged")
        }
        guard var result = envelope["result"] as? [String: Any] else {
            throw AgentContactFailure(code: -32603, message: "The task update has no result; held messages remain undelivered")
        }
        if case .object(let fields) = metadata, !fields.isEmpty {
            if version == "1.0" {
                let key: String
                switch event {
                case .snapshot: key = "task"
                case .status: key = "statusUpdate"
                case .artifact: key = "artifactUpdate"
                }
                guard var payload = result[key] as? [String: Any] else {
                    throw AgentContactFailure(code: -32603, message: "The task update has no payload; held messages remain undelivered")
                }
                payload["metadata"] = metadata.foundationObject
                result[key] = payload
            } else { result["metadata"] = metadata.foundationObject }
        }
        envelope["result"] = result
        return envelope
    }

    static func frame(_ event: AgentContactEvent, id: Any, version: String = "0.3", rest: Bool = false,
                      metadata: JSONValue = .object([:])) throws -> Data {
        var envelope = try Self.envelope(event, id: id, version: version, metadata: metadata)
        if version == "0.3", let result = envelope["result"] as? [String: Any] {
            envelope["result"] = try NativeAgentA2AWire.project(result, version: version)
        }
        guard let result = envelope["result"] as? [String: Any] else {
            throw AgentContactFailure(code: -32603, message: "The stream frame has no result; no reply was acknowledged")
        }
        let json = try JSONSerialization.data(withJSONObject: rest ? result : envelope, options: [.sortedKeys])
        var frame = Data("data: ".utf8); frame.append(json); frame.append(Data("\n\n".utf8))
        return frame
    }

    public static func write(_ connection: NWConnection, id: Any, events: AsyncStream<AgentContactEvent>, version: String = "0.3", rest: Bool = false,
                             metadata: JSONValue, onSent: @escaping @Sendable (AgentContactEvent) async -> Void,
                             settle: @escaping @Sendable (Bool) -> Void) {
        // IDs are immutable strings or integers validated by the wire parser. Carry a value type into the writer task, not Foundation's Any graph.
        let rpcID: JSONValue = (id as? String).map(JSONValue.string) ?? .int((id as? NSNumber)?.int64Value ?? 0)
        let worker = Task {
            var written = false
            defer { if !written { settle(false) }; connection.cancel() }
            do {
                try await send(Data("HTTP/1.1 200 OK\r\nContent-Type: text/event-stream\r\nCache-Control: no-cache\r\nConnection: close\r\n\r\n".utf8),
                    on: connection)
                for await event in events {
                    try Task.checkCancellation()
                    try await send(frame(event, id: rpcID.foundationObject, version: version, rest: rest,
                        metadata: written ? .object([:]) : metadata), on: connection)
                    if !written { written = true; settle(true) }
                    await onSent(event)
                    if version == "1.0" {
                        switch event {
                        case .snapshot(let task), .status(let task, _):
                            if task.state.terminal || task.state == .inputRequired { return }
                        case .artifact: break
                        }
                    }
                }
            } catch { /* Only this subscriber ended. Task truth is unchanged. */ }
        }
        // Preserve the listener's state handler and connection bookkeeping. Receive EOF is a half-close, so only a failed or closed connection cancels this
        // subscriber before its final event has been sent.
        let previous = connection.stateUpdateHandler
        connection.stateUpdateHandler = { state in
            previous?(state)
            switch state {
            case .failed, .cancelled: worker.cancel()
            default: break
            }
        }
        switch connection.state {
        case .failed, .cancelled: worker.cancel()
        default: break
        }
    }

    static func send(_ data: Data, on connection: NWConnection) async throws {
        // finish is idempotent: cancellation and Network completion claim the same send, including cancellation before the operation starts.
        let completion = AsyncThrowingStream<Void, Error>.makeStream()
        try await withTaskCancellationHandler {
            try Task.checkCancellation()
            connection.send(content: data, completion: .contentProcessed { error in
                completion.continuation.finish(throwing: error)
            })
            var iterator = completion.stream.makeAsyncIterator()
            _ = try await iterator.next()
        } onCancel: {
            completion.continuation.finish(throwing: CancellationError())
            connection.cancel()
        }
    }
}
