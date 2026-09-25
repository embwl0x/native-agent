import Foundation
import Network
import UniformTypeIdentifiers
import ChatOrchestration
import NativeAgentCore
import PersistenceCore
import ProviderRouting

struct AgentContactA2AEndpoint: Sendable {
    enum Response: @unchecked Sendable {
        case json([String: Any])
        case stream(id: Any, events: AsyncStream<AgentContactEvent>, version: String)
    }
    let tasks: AgentContactTasks
    var port: UInt16 = 0
    var grpcPort: UInt16? = nil

    func handle(_ body: Data, principal: AgentBridgePrincipal, version: String? = nil) async -> Response {
        let envelope = (try? JSONSerialization.jsonObject(with: body)) as? [String: Any]
        let method = envelope?["method"] as? String ?? ""
        let wireVersion = method.contains("/") ? "0.3" : "1.0"
        if let version, !version.isEmpty {
            let components = version.split(separator: ".", omittingEmptySubsequences: false)
            let pair = components.prefix(2).joined(separator: ".")
            guard (2...3).contains(components.count), components.allSatisfy({ !$0.isEmpty && $0.allSatisfy(\.isNumber) }),
                  ["1.0", "0.3"].contains(pair) else {
                return .json(NativeAgentA2AWire.error(envelope?["id"] ?? NSNull(), -32009, "Supported versions: 1.0, 0.3"))
            }
            if pair != wireVersion {
                return .json(NativeAgentA2AWire.error(envelope?["id"] ?? NSNull(), -32601, "Method does not belong to the requested A2A version"))
            }
        }
        let action = NativeAgentA2AWire.parse(body, defaultContext: principal.conversationID(protocolName: "a2a"))
        let id: Any
        switch action {
        case .response(let response): return .json(response)
        case .send(let send): id = send.rpcID
        case .get(let rpc, _, _, _), .subscribe(let rpc, _), .cancel(let rpc, _), .list(let rpc, _), .push(let rpc, _, _), .extended(let rpc): id = rpc
        }
        do {
            switch action {
            case .response(let value): return .json(value)
            case .extended:
                return .json(NativeAgentA2AWire.result(id, NativeAgentA2AWire.card(port: port, version: wireVersion, extended: true, grpcPort: grpcPort)))
            case .push(_, let operation, let params):
                let parameters = try JSONDecoder().decode(JSONValue.self, from: JSONSerialization.data(withJSONObject: params))
                let value = try await tasks.push(operation: operation, owner: principal.id, parameters: parameters)
                return .json(NativeAgentA2AWire.result(id, AgentContactPart.object(value) as! [String: Any]))
            case .send(let send):
                // Method and params, not the envelope: a client retrying the same
                // messageId mints a new JSON-RPC id.
                let replayObject: [String: Any] = ["method": method, "params": envelope?["params"] ?? NSNull()]
                let replayBytes = JSONSerialization.isValidJSONObject(replayObject)
                    ? (try? JSONSerialization.data(withJSONObject: replayObject, options: .sortedKeys)) ?? body : body
                let task = try await tasks.send(send, principal: principal, digest: AgentPeerReplayClaimStore.digest(replayBytes))
                if send.streaming {
                    return .stream(id: id, events: try await tasks.subscribe(task.id, owner: principal.id), version: wireVersion)
                }
                let returned = send.blocking ? try await tasks.settled(task.id, owner: principal.id) : task
                let projected = try NativeAgentA2AWire.project(returned, version: wireVersion)
                return .json(NativeAgentA2AWire.result(id, wireVersion == "1.0" ? ["task": projected] : projected))
            case .get(_, let task, _, _):
                return .json(NativeAgentA2AWire.result(id, try NativeAgentA2AWire.project(try await tasks.get(task, owner: principal.id), version: wireVersion)))
            case .subscribe(_, let task):
                if wireVersion == "1.0", try await tasks.get(task, owner: principal.id).state.terminal {
                    throw AgentContactFailure(code: -32004, message: "This task has ended; retrieve it with GetTask")
                }
                return .stream(id: id, events: try await tasks.subscribe(task, owner: principal.id), version: wireVersion)
            case .cancel(_, let task):
                return .json(NativeAgentA2AWire.result(id, try NativeAgentA2AWire.project(try await tasks.cancel(task, owner: principal.id), version: wireVersion)))
            case .list(_, let params):
                let parameters = try JSONDecoder().decode(JSONValue.self, from: JSONSerialization.data(withJSONObject: params))
                let listed = try await tasks.list(owner: principal.id, parameters: parameters)
                return .json(NativeAgentA2AWire.result(id, AgentContactPart.object(listed) as! [String: Any]))
            }
        } catch let failure as AgentContactFailure {
            return .json(NativeAgentA2AWire.error(id, failure.code, failure.message))
        } catch {
            return .json(NativeAgentA2AWire.error(id, -32603, "Work could not be accepted. Do not send it again automatically."))
        }
    }
}

enum AgentContactRuntime {
    static let tasks = AgentContactTasks(dataRoot: NativeAgentPaths.dataRoot) { turn, emit in
        try await run(turn, dataRoot: NativeAgentPaths.dataRoot, emit: emit)
    }

    static func run(_ turn: AgentContactTurn, dataRoot: URL,
                    emit: @escaping @Sendable (AgentContactProgress) async -> Void) async throws -> AgentContactOutcome {
        let client = makeNativeAgentAppChatOrchestrationClient(profile: .bridge, dataRoot: dataRoot)
        let principal = turn.principal
        let session = principal.storedConversation(turn.context)
        let envelope = TurnEnvelope(surface: principal.surface, agent: "peer", verifiedUserId: principal.peerID,
                                    commandSignatureVerified: principal.peerID != nil, declaredRemote: !principal.elevated)
        let origin = ChatMessageOrigin(surface: "agent-bridge", agent: "agent", authored: .agent)
        let attachments = turn.parts.compactMap(\.attachment)
        let plain = turn.parts.compactMap { if case .text(let text) = $0 { return text }; return nil }.joined(separator: "\n")
        let text = AgentBridgeSurface.turnHeader(peerName: principal.displayName, elevated: principal.elevated)
            + (plain.isEmpty ? "Please read the attached content." : AgentBridgeSurface.quotingImpersonation(plain))
        return try await ChatToolSessionContext.$envelope.withValue(envelope) {
            try await ChatPersistenceContext.$originProvenance.withValue(origin) {
                try Task.checkCancellation()
                let enqueued = try await client.enqueueUserMessage(message: text, sessionId: session, persona: nil,
                    surface: principal.surface, attachments: attachments, mechanicalRow: nil)
                try await turn.bindRun(session, enqueued.runId)
                if let peerID = principal.peerID { AgentPeerStore(dataRoot: dataRoot).recordProof(peerID: peerID, inbound: true) }
                return try await ChatPersistenceContext.$pinnedTurnRunID.withValue(enqueued.runId) {
                    try Task.checkCancellation()
                    await emit(.working)
                    let execution = client.chatStreamExecution(message: text, sessionId: session, model: "", reasoningEffort: "",
                        fileAccess: "auto", attachments: attachments, persona: nil, surface: principal.surface, suppressUserAppend: true)
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
                                case .notice, .toolUse: break
                                }
                            }
                        } catch {
                            execution.cancel()
                            await execution.waitForProducerTermination()
                            throw ProviderFailure.report(error, work: ranPartly ? .ranPartly : nil) ?? error
                        }
                        await execution.waitForProducerTermination()
                        try Task.checkCancellation()
                        guard let final, failure == nil else {
                            return AgentContactOutcome(state: waiting ? .inputRequired : .failed, parts: [],
                                detail: waiting ? "Waiting for the person" : (failure ?? "The reply ended without a finished result") + ". Work: " + (ranPartly ? "ran partly." : "outcome unknown."))
                        }
                        let parts = try outputParts(final, taskID: turn.taskID, dataRoot: dataRoot)
                        let state: AgentContactTaskState = waiting ? .inputRequired : (final.completionState == .completed ? .completed : .failed)
                        return AgentContactOutcome(state: state, parts: parts,
                            detail: state == .failed ? "The work did not finish" : nil)
                    } onCancel: { execution.cancel() }
                    await MainActor.run {
                        NotificationCenter.default.post(name: .chatTurnCompleted, object: session)
                    }
                    await client.drainDeferredMemoryPromotion()
                    return outcome
                }
            }
        }
    }

    static func outputParts(_ result: TurnEngineResult, taskID: String, dataRoot: URL) throws -> [AgentContactPart] {
        var parts: [AgentContactPart] = result.reply.isEmpty ? [] : [.text(result.reply)]
        if let bytes = result.reply.data(using: .utf8), bytes.count <= 64000,
           let value = try? JSONDecoder().decode(JSONValue.self, from: bytes), case .object = value {
            parts.append(.data(value, metadata: .object(["source": .string("agent"), "taskId": .string(taskID)])))
        }
        // A file too big to send drops out, not the finished reply with it.
        let omitted = "[Files produced by this reply were too large to send and were left out.]"
        var dropped = false
        for attachment in ChatGeneratedImageArtifacts.attachments(from: result.toolDispatches, dataRoot: dataRoot) {
            if let part = try? AgentContactPart.output(attachment, taskID: taskID) { parts.append(part) } else { dropped = true }
        }
        // A successful write receipt proves the produced bytes. Do not scan
        // reply prose for paths or read an arbitrary path from a tool result.
        for dispatch in result.toolDispatches where dispatch.name == "write_file" {
            guard case .object(let receipt) = dispatch.result, receipt["ok"] == .bool(true), receipt["append"] == .bool(false),
                  case .string(let content)? = dispatch.input["content"],
                  receipt["bytes_written"] == .int(Int64(content.utf8.count)),
                  case .string(let path)? = dispatch.input["path"], content.utf8.count <= AgentContactPart.maximumFileBytes else { continue }
            let name = URL(fileURLWithPath: path).lastPathComponent
            guard AgentContactPart.safeName(name) else { continue }
            let mime = UTType(filenameExtension: (name as NSString).pathExtension)?.preferredMIMEType ?? "application/octet-stream"
            parts.append(.file(name: name, mediaType: mime, bytes: Data(content.utf8),
                               metadata: .object(["source": .string("agent"), "taskId": .string(taskID)])))
        }
        let size = try JSONSerialization.data(withJSONObject: parts.map(\.wire03)).count
        guard size <= AgentContactPart.maximumOutputBytes else {
            return parts.filter { if case .file = $0 { return false }; return true } + [.text(omitted)]
        }
        return dropped ? parts + [.text(omitted)] : parts
    }
}

enum AgentContactSSE {
    static func frame(_ event: AgentContactEvent, id: Any, version: String = "0.3", rest: Bool = false) throws -> Data {
        var envelope = NativeAgentA2AWire.event(event, id: id, version: version)
        if version == "0.3", let result = envelope["result"] as? [String: Any] {
            envelope["result"] = try NativeAgentA2AWire.project(result, version: version)
        }
        let json = try JSONSerialization.data(withJSONObject: rest ? (envelope["result"] ?? envelope) : envelope, options: [.sortedKeys])
        var frame = Data("data: ".utf8); frame.append(json); frame.append(Data("\n\n".utf8))
        return frame
    }

    static func write(_ connection: NWConnection, id: Any, events: AsyncStream<AgentContactEvent>, version: String = "0.3", rest: Bool = false) {
        // IDs are immutable strings or integers validated by the wire parser.
        // Carry a value type into the writer task, not Foundation's Any graph.
        let rpcID: JSONValue = (id as? String).map(JSONValue.string) ?? .int((id as? NSNumber)?.int64Value ?? 0)
        let worker = Task {
            defer { connection.cancel() }
            do {
                try await send(Data("HTTP/1.1 200 OK\r\nContent-Type: text/event-stream\r\nCache-Control: no-cache\r\nConnection: close\r\n\r\n".utf8), on: connection)
                for await event in events {
                    try Task.checkCancellation()
                    try await send(frame(event, id: AgentContactPart.object(rpcID), version: version, rest: rest), on: connection)
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
        // Preserve the listener's state handler and connection bookkeeping.
        // There are no more request bytes to read; EOF releases this subscriber.
        connection.receive(minimumIncompleteLength: 1, maximumLength: 1) { _, _, _, _ in worker.cancel() }
    }

    private static func send(_ data: Data, on connection: NWConnection) async throws {
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            connection.send(content: data, completion: .contentProcessed { error in
                if let error { continuation.resume(throwing: error) } else { continuation.resume() }
            })
        }
    }
}
