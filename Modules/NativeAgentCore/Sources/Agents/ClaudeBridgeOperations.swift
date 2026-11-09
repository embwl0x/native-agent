import Foundation
import Experiences
import NativeAgentShared
import Darwin
import Network
import ChatTurnRuntime
import ChatTurnContracts
import ChatToolRuntime
import AgentConversations
import ChatToolParsing
import Cognition
import ContextFlow
import PersonaEngine
import CognitiveSubstrate
import NativeAgentCore
import PersistenceCore
import Privacy
import MacControl
// Blueprint: | `ClaudeBridgeOperations.swift` | Message and tool endpoint execution under the existing listener admission and actual-exit worker lifetime |

extension ClaudeBridgeRuntime {
    public func messageRuntime() -> ClaudeBridgeMessageRuntime {
        clientLock.lock(); defer { clientLock.unlock() }
        if let bridgeMessageRuntime { return bridgeMessageRuntime }
        let runtime = ClaudeBridgeMessageRuntime(port: host, tasks: tasks, eventPublisher: { [weak self] kind, payload in
            self?.publishEvent(kind: kind, payload: payload)
        })
        bridgeMessageRuntime = runtime
        return runtime
    }

    func handleMessage(conn: NWConnection, body: Data, defaultSender: String, principal: AgentBridgePrincipal?) {
        guard let principal else {
            writeJSON(conn, status: 403, obj: ["error": "invalid_peer_identity"])
            return
        }
        messageRuntime().handleMessage(response: { [weak self] status, object, settle in
            guard let self else { settle(false); conn.cancel(); return }
            let taskID = object["task_id"] as? String
            let carriesReply = AgentContactRoutes.carriesReply(object)
            self.writeJSON(conn, status: status, obj: object, onSent: { [weak self] in
                settle(true)
                // Failed work can still return produced words/files. The successful write acknowledges those bytes, not execution success.
                guard carriesReply, let taskID, let self else { return }
                Task {
                    do {
                        let task = try await self.tasks.get(taskID, owner: principal.id)
                        await self.tasks.recordReplyFetch(task)
                    } catch { nativeLog("Bridge transmitted reply acknowledgment unavailable for %@: %@", taskID, error.localizedDescription) }
                }
            }, onFailed: { settle(false) })
        }, body: body, defaultSender: defaultSender, principal: principal)
    }

    // MARK: - /claude/tool

    /// Only the door's own authenticated key carries its identity and grant.
    func bridgeCallerPrincipal(headers: [String: String]) -> AgentBridgePrincipal? {
        let principal = AgentBridgePrincipal.resolve(headers: headers, dataRoot: host.dataRoot)
        guard !principal.replyOnly,
              !AgentBridgePrincipal.claimsIdentity(headers: headers) || principal.peerID != nil else { return nil }
        return principal
    }

    func handleTool(conn: NWConnection, body: Data, principal: AgentBridgePrincipal?) {
        guard let json = try? JSONSerialization.jsonObject(with: body) as? [String: Any] else {
            writeJSON(conn, status: 400, obj: ["error": "invalid_json"])
            return
        }
        guard let name = json["name"] as? String, !name.isEmpty else {
            writeJSON(conn, status: 400, obj: ["error": "missing_name"])
            return
        }
        guard let principal else {
            writeJSON(conn, status: 401, obj: ["error": "unauthorized"])
            return
        }
        let surface = principal.surface
        let context = json["session_id"] as? String
        let request = json["request_id"] as? String
        if json["session_id"] != nil || json["request_id"] != nil {
            guard let context, context.utf8.count <= 128,
                  NativeAgentChatSessionID.normalizedPathComponent(context) == context,
                  let request, request.count == 36, UUID(uuidString: request) != nil else {
                writeJSON(conn, status: 400, obj: ["error": "invalid_caller_reply_route",
                    "detail": "Supply a transport session_id and UUID request_id together; no work was queued."])
                return
            }
        }
        let inputRaw: [String: Any]
        if let supplied = json["input"] {
            guard let object = supplied as? [String: Any] else {
                writeJSON(conn, status: 400, obj: ["error": "invalid_input",
                    "detail": "Tool input must be an object; no work was queued."])
                return
            }
            inputRaw = object
        } else { inputRaw = [:] }
        let inputJV = inputRaw.mapValues { JSONValue(fromFoundation: $0) }

        let tasks = self.tasks
        let session = context.map(principal.storedConversation)
        let tools = toolClient(verifiedSessionID: session)
        let requestTurn = principal.turnRequest(context: context, plain: "", messageID: request)
        let turn = requestTurn.turn()
        let taskID = context.flatMap { context in request.map { "na3.\(context).\($0)" } }
        let requestDigest = AgentPeerReplayClaimStore.digest(body)
        let started = Date()
        let workLatch = WorkLatch()
        let workTask = startRequest(conn: conn, latch: workLatch, priority: .userInitiated, accepted: true) { [weak self] id in
            guard let self else { return }
            var admitted = false
            do {
                if let context, let request {
                    let retained = try await tasks.beginTool(context: context, request: request, principal: principal, digest: requestDigest)
                    guard retained.execute else {
                        guard workLatch.claim() else { return }
                        let receipt = AgentContactRoutes.contactReply(retained.task, requestID: request,
                            sessionID: context, offset: 0, maxChars: 8000)
                        self.writeJSON(conn, status: 200, obj: receipt,
                            onSent: AgentContactRoutes.fetched(receipt, task: retained.task, tasks: tasks))
                        return
                    }
                    admitted = true
                }
                let result = try await self.runToolOperation(id) {
                    let result: JSONValue
                    do {
                        result = try await tools.dispatch(tool: name, input: inputJV, surface: requestTurn.surface, turn: turn,
                            invocation: ChatToolInvocation())
                    } catch {
                        // Only dispatch exit settles retained tool work.
                        if let taskID {
                            let status = Task.isCancelled || error is CancellationError
                                ? "outcome_unknown" : "failed"
                            let dispatchCause = String(describing: error)
                            do {
                                try await tasks.finishTool(taskID, owner: principal.id,
                                    result: .object(["status": .string(status), "detail": .string(dispatchCause)]))
                            } catch {
                                RepairOwed.owe(self.host.dataRoot, id: taskID, kind: .message,
                                    operation: "bridge.tool.settle:" + taskID, owner: taskID,
                                    words: "Tool dispatch failed: " + dispatchCause
                                        + "; saving its outcome also failed: " + error.localizedDescription,
                                    lever: "Repair the named retained task's outcome before repeating this tool call.")
                            }
                        }
                        throw error
                    }
                    if let taskID {
                        do { try await tasks.finishTool(taskID, owner: principal.id, result: result) }
                        catch {
                            RepairOwed.owe(self.host.dataRoot, id: taskID, kind: .message,
                                operation: "bridge.tool.settle:" + taskID, owner: taskID,
                                words: "Tool dispatch returned, but saving its result failed: " + error.localizedDescription,
                                lever: "Repair this retained task's result from its original execution evidence; do not repeat the tool call.")
                            throw error
                        }
                    }
                    return result
                }
                let resultAny = result.foundationObject
                let durationMs = Int(Date().timeIntervalSince(started) * 1000)
                self.publishToolResultEvent(name: name, surface: surface, result: result, durationMs: durationMs)
                guard workLatch.claim() else { return }
                self.writeJSON(conn, status: 200, obj: [
                    "name": name,
                    "result": resultAny,
                    "durationMs": durationMs,
                ])
            } catch {
                if admitted, let taskID, self.closeUnstartedTool(id) {
                    do {
                        try await tasks.finishTool(taskID, owner: principal.id,
                            result: .object(["status": .string("failed"), "detail": .string(String(describing: error))]))
                    } catch {
                        RepairOwed.owe(self.host.dataRoot, id: taskID, kind: .message,
                            operation: "bridge.tool.settle:" + taskID, owner: taskID,
                            words: "Tool admission failed and its receipt could not settle: " + error.localizedDescription,
                            lever: "Repair this retained task's receipt before repeating the tool call.")
                    }
                }
                self.publishEvent(kind: "tool_failed", payload: [
                    "name": name,
                    "ok": false,
                    "detail": String(describing: error),
                ])
                guard workLatch.claim() else { return }
                self.writeJSON(conn, status: 500, obj: [
                    "error": "tool_failed",
                    "name": name,
                    "surface": surface,
                    "detail": String(describing: error),
                ])
            }
        }
        guard workTask != nil else { writeJSON(conn, status: 503, obj: ["error": "server_stopping_or_busy"]); return }
    }
}
