import Foundation
import ImageIO
import os
import UniformTypeIdentifiers
import NativeAgentShared
import NativeAgentCore
import ChatTurnRuntime
import ChatTurnContracts
import ChatToolParsing
import MacControl
import PersistenceCore
import ToolRegistry
import Transcripts
import TurnTrace
import ProviderRouting
import StandingBots
import Privacy
import Experiences
// Blueprint: | `ICloudIncomingTurnForwarder.swift` | `ICloudConflatedSender`, `surface.replyDeliveryStarted`; Signed phone turns and retained delivery. |

/// Conflate unsent optional values; join admitted sends at close so late progress cannot reopen a resolved correlation.
final class ICloudConflatedSender: Sendable {
    private typealias Send = @Sendable () async -> Void
    private let mailbox = OSAllocatedUnfairLock(initialState: (closed: false, pending: [String: Send]()))
    private let signal: AsyncStream<Void>.Continuation
    private let worker: Task<Void, Never>

    init() {
        let (signals, signal) = AsyncStream<Void>.makeStream(bufferingPolicy: .bufferingNewest(1))
        self.signal = signal
        let mailbox = mailbox
        worker = Task {
            for await _ in signals {
                let pending = mailbox.withLock { state in
                    let pending = state.pending
                    state.pending.removeAll()
                    return pending
                }
                for key in pending.keys.sorted() {
                    guard !mailbox.withLock({ $0.closed }) else { return }
                    await pending[key]?()
                }
            }
        }
    }

    func submit(key: String, send: @escaping @Sendable () async -> Void) {
        let queued = mailbox.withLock { state in
            guard !state.closed else { return false }
            state.pending[key] = send
            return true
        }
        if queued { signal.yield(()) }
    }

    func close() {
        mailbox.withLock { state in state.closed = true; state.pending.removeAll() }
        signal.finish()
    }

    func finish() async {
        close()
        await worker.value
    }

    deinit { signal.finish() }
}

struct ICloudChatReplacementIntent: Equatable, Sendable {
    let assistantMessageID: String

    static func decode(_ metadata: [String: String]) -> ICloudChatReplacementIntent? {
        guard metadata["suppressUserAppend"] == "true",
              let raw = metadata["replacementAssistantMessageId"]?
                .trimmingCharacters(in: .whitespacesAndNewlines),
              let id = UUID(uuidString: raw) else { return nil }
        return ICloudChatReplacementIntent(assistantMessageID: id.uuidString)
    }
}

/// Terminal turns consume their signed input even if reply publication fails, preventing duplicate execution.
enum ICloudIncomingTurnConsumptionPolicy {
    static func shouldConsume(
        turnReachedTerminalState: Bool,
        replyPublished: Bool
    ) -> Bool {
        turnReachedTerminalState || replyPublished
    }
}

public struct ICloudIncomingTurnForwarder: Sendable {
    private let sync: DeviceSync
    private let port: any ICloudIncomingTurnPort

    public init(sync: DeviceSync, port: any ICloudIncomingTurnPort) {
        self.sync = sync
        self.port = port
    }

    private func signatureVerified(_ message: BridgeMessage) -> Bool {
        (try? PairingSecret.loadOrGenerateSecret())
            .map { message.verifySignature(secret: $0) } ?? false
    }

    /// Share admitted signed file-access IDs with the mobile pill; persisted labels grant no authority.
    static func iCloudChatFileAccess(from remoteMetadata: [String: String]) throws -> String {
        // The phone writes fileAccess on every chat (ChatRuntimeControls.metadata); a chat without it is malformed, never Auto.
        guard let raw = remoteMetadata["fileAccess"] else {
            throw ToolFailureError("The phone's request has no fileAccess; no file access was inferred.",
                argumentPath: "request.fileAccess",
                accepted: ICloudChatFileAccessPolicy.acceptedIDs.sorted().joined(separator: ", "), effects: .none)
        }
        guard let mode = ICloudChatFileAccessPolicy.Mode(raw) else {
            throw ToolFailureError("The phone's fileAccess request is unrecognized; no file access was inferred.",
                argumentPath: "request.fileAccess",
                accepted: ICloudChatFileAccessPolicy.acceptedIDs.sorted().joined(separator: ", "), effects: .none)
        }
        return mode.rawValue
    }

    static func needsInteractionEnvelope(kind: String, target: String, reason: String) -> String? {
        let needs: [String: String] = ["kind": kind, "target": target, "reason": reason]
        let envelope: [String: Any] = ["status": "needs_input", "needs": needs]
        guard let data = try? JSONSerialization.data(withJSONObject: envelope),
              let json = String(data: data, encoding: .utf8), json.count <= 900 else { return nil }
        return json
    }

    /// Admission read `route` from this message (ICloudPhoneRoute.read); every reply goes to that device alone.
    @MainActor
    public func forwardToSwiftRuntime(_ msg: BridgeMessage, route: ICloudPhoneRoute) async -> Bool {
        let receivedAt = Date()
        let remoteMetadata = msg.metadata ?? [:]
        let routeKey = route.routeKey
        func writeErrorReply(
            _ text: String,
            detail: String? = nil,
            partialReply: String? = nil,
            sessionID: String?,
            turnReachedTerminalState: Bool = false,
            needs: String? = nil
        ) async -> Bool {
            do {
                var metadata = [
                    "kind": "error",
                    "errorDetail": String((detail ?? text).prefix(400)),
                    "transport": "icloud",
                    "source": "mac",
                    "replyTo": route.replyTo,
                    "targetSourceKey": routeKey
                ]
                if let needs { metadata["needs"] = needs }
                let body = partialReply.flatMap { $0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? nil : $0 }
                if body != nil { metadata["partialReply"] = "true" }
                _ = try await sync.bridge.sendChatMessage(
                    text: body ?? text,
                    sessionID: sessionID,
                    correlationID: msg.id,
                    metadata: metadata
                )
                await sync.relay.sendICloudReplyPushNotification(
                    text: body ?? text,
                    sessionID: sessionID,
                    correlationID: msg.id,
                    kind: "error"
                )
                port.completed(sessionID: sessionID)
                return true
            } catch {
                nativeLog("[iCloudBridge] failed to write error reply for msg %@: %@", msg.id, "\(error)")
                if turnReachedTerminalState {
                    port.completed(sessionID: sessionID)
                }
                return ICloudIncomingTurnConsumptionPolicy.shouldConsume(
                    turnReachedTerminalState: turnReachedTerminalState,
                    replyPublished: false
                )
            }
        }
        func writeProgress(_ text: String, stage: String, sessionID: String, sender: ICloudConflatedSender) {
            sendICloudProgress(
                text: text,
                sessionID: sessionID,
                correlationID: msg.id,
                sender: sender,
                metadata: [
                    "kind": "progress",
                    "stage": stage,
                    "transport": "icloud",
                    "source": "mac",
                    "replyTo": route.replyTo,
                    "targetSourceKey": routeKey
                ]
            )
        }

        // Resolve one session id before execution so transcripts and every reply identify the same conversation.
        let trimmedSessionID = msg.sessionID?.trimmingCharacters(in: .whitespacesAndNewlines)
        let resolvedSessionID: String
        if let trimmedSessionID, !trimmedSessionID.isEmpty {
            guard let safeSessionID = NativeAgentChatSessionID.normalizedPathComponent(trimmedSessionID) else {
                nativeLog("[iCloudBridge] dropping iOS msg %@: invalid sessionID %@", msg.id, trimmedSessionID)
                return await writeErrorReply(
                    "iPhone message rejected: invalid chat session id.",
                    sessionID: nil
                )
            }
            resolvedSessionID = safeSessionID
        } else {
            resolvedSessionID = UUID().uuidString
        }
        let chatFileAccess: String
        do { chatFileAccess = try Self.iCloudChatFileAccess(from: remoteMetadata) }
        catch { return await writeErrorReply(error.localizedDescription, sessionID: resolvedSessionID) }
        // Register Stop before any await so every later path targets this same admitted run.
        let turnID = TurnTraceContext.mintTurnId()
        let replacementAssistantMessageID = ICloudChatReplacementIntent
            .decode(remoteMetadata)?.assistantMessageID
        let suppressUserAppend = replacementAssistantMessageID != nil
        let replyRoute = ChatToolSessionContext.ReplyRoute(
            surface: "ios", sourceKey: routeKey,
            replyTo: route.replyTo, correlationId: msg.id)
        // Hold the ingress turn before control handoff can persist its early reply.
        let request = TurnRequest(message: msg.text, sessionID: resolvedSessionID, fileAccess: chatFileAccess,
            surface: "ios", suppressUserAppend: suppressUserAppend,
            envelope: TurnEnvelope(surface: "ios", commandSignatureVerified: signatureVerified(msg),
                deliveryRoute: replyRoute),
            verifiedSessionID: resolvedSessionID, replyRoute: replyRoute, pinnedRunID: msg.id,
            replacementAssistantMessageID: .some(replacementAssistantMessageID))
        let admittedTurn = request.turn(id: turnID)
        TurnTraceBus.fire(TurnTraceEvent(turnId: turnID, ts: receivedAt, kind: "phone.pickup",
            sessionId: resolvedSessionID, surface: "ios", payload: .object([
                "messageId": .string(msg.id),
                "sentAt": .string(NativeTimestampFormat.fractionalZulu(msg.timestamp)),
                "pickupMs": .double(receivedAt.timeIntervalSince(msg.timestamp) * 1_000)
            ]), turn: admittedTurn))
        let stopFlag = ChatCancelFlag.accept(dataRoot: PersistenceCore.defaultDataRoot(),
                                             sessionId: resolvedSessionID, runId: msg.id, turnId: turnID)
        defer { ChatCancelFlag.finish(stopFlag) }
        do {
            try await iCloudBridge.bindReplySession(msg, sessionID: resolvedSessionID, dataRoot: PersistenceCore.defaultDataRoot())
            // Cover early returns before control handoff or supersession can work outside the stream task.
            if try iCloudBridge.chatStopRequested(session: resolvedSessionID, runID: msg.id, dataRoot: PersistenceCore.defaultDataRoot()) {
                _ = try await sync.bridge.sendChatMessage(text: "Stopped.", sessionID: resolvedSessionID,
                    correlationID: msg.id, metadata: ["kind": "cancelled", "targetSourceKey": routeKey])
                return true
            }
        } catch {
            nativeLog("[iCloudBridge] reply session could not be retained: %@", error.localizedDescription)
            return false
        }

        // Read before any suspension: a handoff after this point supersedes it.
        let receivedAtHandoffGeneration = port.controlHandoffGeneration(sessionID: resolvedSessionID)
        func supersededByControlHandoff() -> Bool {
            port.holdsMessageAfterControlHandoff(sessionID: resolvedSessionID,
                receivedAtGeneration: receivedAtHandoffGeneration, sentAt: msg.timestamp)
        }

        if UserMessageIntentSignals.isControlHandoff(msg.text) {
            guard let trimmedSessionID, !trimmedSessionID.isEmpty, signatureVerified(msg) else {
                return await writeErrorReply("Control handoff requires a signed message naming its chat session.", sessionID: nil)
            }
            do {
                let reply = try await port.stopChatForControlHandoff(sessionID: resolvedSessionID, messageDate: msg.timestamp)
                try await port.residentChatClient().recordControlHandoff(
                    message: msg.text, reply: reply, sessionId: resolvedSessionID, surface: "ios", runId: msg.id,
                    turn: admittedTurn
                )
                _ = try await sync.bridge.sendChatMessage(text: reply, sessionID: resolvedSessionID,
                    correlationID: msg.id, metadata: [
                        "kind": "final", "transport": "icloud", "source": "mac",
                        "replyTo": route.replyTo, "targetSourceKey": routeKey,
                    ])
                await sync.relay.sendICloudReplyPushNotification(text: reply, sessionID: resolvedSessionID,
                    correlationID: msg.id, kind: "reply")
                sync.engine.requestChatSnapshotPublication(includeTranscripts: true)
                port.completed(sessionID: resolvedSessionID)
                return true
            } catch {
                return await writeErrorReply("""
                    Control handoff could not be confirmed: \(NativeAppSecretRedactor.redactedRemoteErrorDetail(error.localizedDescription))
                    """,
                    sessionID: resolvedSessionID, turnReachedTerminalState: true)
            }
        }

        // Capture the person's surface when takeover arrives, before queueing can change it.
        let takeover = signatureVerified(msg) ? await MacWorkContinuation.admit(msg.text) : nil

        func consumeSupersededMessage() async -> Bool {
            defer { port.completed(sessionID: resolvedSessionID) }
            do {
                _ = try await sync.bridge.sendChatMessage(text: "(cancelled)", sessionID: resolvedSessionID,
                    correlationID: msg.id, metadata: [
                        "kind": "cancelled", "transport": "icloud", "source": "mac",
                        "replyTo": route.replyTo, "targetSourceKey": routeKey,
                    ])
            } catch {
                nativeLog("[iCloudBridge] failed to write superseded reply for msg %@: %@", msg.id, "\(error)")
            }
            // A handoff is terminal for this input, even if reply publication fails.
            return true
        }

        guard !supersededByControlHandoff() else {
            return await consumeSupersededMessage()
        }
        await port.awaitPendingChatStop(sessionID: resolvedSessionID)
        guard !supersededByControlHandoff() else {
            return await consumeSupersededMessage()
        }

        // Resolve the live profile name independently of the chatPersona style quick-switch.
        let agentDisplayName = NativeAgentNotificationDefaults.agentDisplayName()

        // Index the phone session before persisting its messages so conversation lists can discover it.
        do {
            try await ensureChatSessionIndex(
                sessionID: resolvedSessionID,
                dataRoot: PersistenceCore.defaultDataRoot()
            )
        } catch {
            nativeLog("[iCloudBridge] ensureChatSessionIndex failed for %@: %@", resolvedSessionID, "\(error)")
            return await writeErrorReply(
                "Chat history is unavailable because its session index needs repair on the Mac.",
                sessionID: resolvedSessionID
            )
        }

        port.received(in: resolvedSessionID)
        // A person-sent phone message identifies their current conversation.
        let anchorRoot = PersistenceCore.defaultDataRoot()
        let anchorOperation = "conversation.anchor:" + resolvedSessionID
        do {
            _ = try await ConversationAnchor.publish(
                sessionId: resolvedSessionID, source: "ios",
                conversationKind: try SessionConversation.checkedKind(resolvedSessionID, dataRoot: anchorRoot) ?? .unclassified,
                dataRoot: anchorRoot)
            RepairOwed.settle(anchorRoot, operation: anchorOperation,
                             evidence: .init(source: "conversation-anchor", id: resolvedSessionID))
        } catch {
            RepairOwed.owe(anchorRoot, id: anchorOperation, kind: .run,
                operation: anchorOperation, owner: "Conversation anchor",
                words: "The phone conversation was accepted, but its current-conversation anchor could not be published: \(error.localizedDescription)",
                lever: "Repair the conversation anchor store and publish the accepted session \(resolvedSessionID); do not replay its message.")
        }

        // MacSyncEngine retains the turn for explicit Stop; passive sync shutdown lets accepted work settle.
        let replyMetadata = [
            "kind": "final",
            "transport": "icloud",
            "source": "mac",
            "replyTo": route.replyTo,
            "targetSourceKey": routeKey
        ]
        let chatClient = port.residentChatClient()
        var continuedTurn = admittedTurn.with(\.macContinuation, takeover)
        if let takeover { continuedTurn.envelope = continuedTurn.envelope?.withMacContinuation(takeover) }
        let turn = continuedTurn
        // No suspension from this final boundary read through task registration.
        guard !supersededByControlHandoff() else {
            return await consumeSupersededMessage()
        }
        let progress = ICloudConflatedSender()
        writeProgress("Mac received it", stage: "received", sessionID: resolvedSessionID, sender: progress)
        if !(msg.attachments?.isEmpty ?? true) {
            let status = msg.attachments?.contains(where: { $0.type == "audio" }) == true
                ? "Listening to your voice note"
                : msg.attachments?.allSatisfy({ $0.type == "image" }) == true ? "Reading attached photos" : "Reading attachments"
            writeProgress(status, stage: "attachments", sessionID: resolvedSessionID, sender: progress)
        }
        // Let the voice-note line leave before conflation can replace it with progress.
        if msg.attachments?.contains(where: { $0.type == "audio" }) != true {
            writeProgress("\(agentDisplayName) is thinking", stage: "thinking", sessionID: resolvedSessionID, sender: progress)
        }
        typealias Outcome = (text: String, deltaSeq: Int, error: String?, toolEvents: Int,
            attachments: [NativeAgentShared.MultimodalAttachment], cause: Error?)
        let streamTask = Task.detached(priority: .userInitiated) { () -> MacSyncEngine.ICloudChatOutcome in
            do {
            if try iCloudBridge.chatStopRequested(session: resolvedSessionID, runID: msg.id, dataRoot: PersistenceCore.defaultDataRoot()) {
                throw CancellationError()
            }
            let helper = try SessionConversation.checkedIsHelper(resolvedSessionID)
            let operation: (Turn) async throws -> Outcome = { turn in
            return await TurnTraceContext.$turnId.withValue(turn.id) {
            if helper {
                let textProgress = OSAllocatedUnfairLock(initialState: ICloudTextDeltaCoalescer())
                do {
                    let reply = try await port.helperReply(message: msg.text, sessionID: resolvedSessionID,
                            attachments: msg.attachments ?? [], fileAccess: chatFileAccess, progress: { event in
                                guard case .delta(let text) = event else { return }
                                let flush = textProgress.withLock { state in
                                    state.push(delta: text)
                                }
                                if let flush {
                                    sendICloudTextDelta(flush, turn: turn, sender: progress, sessionID: resolvedSessionID, correlationID: msg.id,
                                        replyTo: route.replyTo, targetSourceKey: routeKey)
                                }
                            }, turn: turn)
                    let attachments = try Self.bridgeAttachments(from: reply.attachments ?? [],
                        text: reply.output, sessionID: resolvedSessionID, correlationID: msg.id, metadata: replyMetadata)
                    let cause: Error? = reply.terminalState == .stopped ? CancellationError() : nil
                    return (reply.output, textProgress.withLock { $0.sequence },
                        reply.terminalState == .failed || reply.terminalState == .interrupted ? reply.statusDetail : nil, 0, attachments, cause)
                } catch {
                    return (textProgress.withLock { $0.text }, textProgress.withLock { $0.sequence },
                            error.localizedDescription, 0, [], error)
                }
            }
            var finalAnswer: String?
            var sawError: String? = nil
            var toolEventCounter = 0
            var attachments: [NativeAgentShared.MultimodalAttachment] = []
            var cause: Error?
            let shown = ShownToolNames()
            var deltaCoalescer = ICloudTextDeltaCoalescer()

            // Core admits the session's execution contract inside the producer.
            let execution = chatClient.chatStreamExecution(
                message: msg.text,
                sessionId: resolvedSessionID,
                // Admit the Mac-owned iOS execution tuple before append; signed metadata is only evidence.
                model: "",
                reasoningEffort: "",
                fileAccess: chatFileAccess,
                attachments: msg.attachments ?? [],
                persona: nil,
                surface: "ios",
                suppressUserAppend: suppressUserAppend,
                replacementAssistantMessageID: turn.rows.replacementAssistantMessageID,
                turn: turn
            )
            await withTaskCancellationHandler {
            do {
                for try await event in execution.events {
                    if Task.isCancelled { break }
                    switch event {
                    case .delta(let s):
                        if s.isEmpty { continue }
                        if let flush = deltaCoalescer.push(delta: s) {
                            sendICloudTextDelta(
                                flush,
                                turn: turn,
                                sender: progress,
                                sessionID: resolvedSessionID,
                                correlationID: msg.id,
                                replyTo: route.replyTo,
                                targetSourceKey: routeKey
                            )
                        }
                    case .final(let r):
                        // Settlement preserves all produced words, including text shown before tools ran.
                        let answer = r.reply
                        finalAnswer = answer
                        attachments = try Self.bridgeAttachments(
                            from: ChatGeneratedImageArtifacts.attachments(
                                from: r.toolDispatches,
                                dataRoot: PersistenceCore.defaultDataRoot()
                            ),
                            text: answer.trimmingCharacters(in: .whitespacesAndNewlines),
                            sessionID: resolvedSessionID,
                            correlationID: msg.id,
                            metadata: replyMetadata
                        )
                    case .replyTextSettled:
                        break
                    case .writing(let writing):
                        // A writing call reaches the phone's live line as the existing notice; the conflated key keeps only its latest size.
                        guard let writing else { continue }
                        sendICloudProgress(
                            text: writing.line,
                            sessionID: resolvedSessionID,
                            correlationID: msg.id,
                            sender: progress,
                            metadata: [
                                "kind": "notice",
                                "noticeKind": "writing",
                                "transport": "icloud",
                                "source": "mac",
                                "replyTo": route.replyTo,
                                "targetSourceKey": routeKey
                            ],
                            key: NativeAgentICloudBridgeConstants.KVSKey.chatNoticeLatest
                        )
                    case .notice(let noticeKind, let text):
                        // Transient notices keep their own KVS key so tool progress cannot overwrite them.
                        sendICloudProgress(
                            text: text,
                            sessionID: resolvedSessionID,
                            correlationID: msg.id,
                            sender: progress,
                            metadata: [
                                "kind": "notice",
                                "noticeKind": noticeKind,
                                "transport": "icloud",
                                "source": "mac",
                                "replyTo": route.replyTo,
                                "targetSourceKey": routeKey
                            ],
                            key: NativeAgentICloudBridgeConstants.KVSKey.chatNoticeLatest
                        )
                    case .toolUse(let called, let input):
                        // Phone progress carries the tool's name and card phrase; full input/output stays Mac-local.
                        let call = shown.use(called, input: input)
                        let name = call.name
                        toolEventCounter += 1
                        sendICloudProgress(
                            text: name,
                            sessionID: resolvedSessionID,
                            correlationID: msg.id,
                            sender: progress,
                            metadata: [
                                "kind": "tool_use",
                                "toolName": name,
                                "activity": ToolActivityPresentation.progress(name, args: call.input.stringFields),
                                "toolSeq": String(call.seq),
                                "transport": "icloud",
                                "source": "mac",
                                "replyTo": route.replyTo,
                                "targetSourceKey": routeKey
                            ]
                        )
                    case .toolResult(let called, let output):
                        let reply = ToolResult(output)
                        let call = shown.result(called)
                        let name = call.name
                        let outcome = reply.outcome.rawValue
                        let detail = [ChatToolOutcome.explanation(reply.payload), ChatToolOutcome.remedy(reply.payload)].compactMap { $0 }.joined(
                            separator: " · ")
                        toolEventCounter += 1
                        sendICloudProgress(
                            text: name,
                            sessionID: resolvedSessionID,
                            correlationID: msg.id,
                            sender: progress,
                            metadata: [
                                "kind": "tool_result",
                                "toolName": name,
                                "toolSeq": call.seq.map(String.init) ?? "",
                                "outcome": outcome,
                                "resultDetail": detail,
                                "activity": ToolActivityPresentation.finished(name, outcome: outcome, detail: detail),
                                "transport": "icloud",
                                "source": "mac",
                                "replyTo": route.replyTo,
                                "targetSourceKey": routeKey
                            ]
                        )
                    case .error(let m):
                        // Stream errors produce an error reply rather than a successful partial answer.
                        sawError = m
                        nativeLog("[iCloudBridge] chatStream error msg=%@: %@", msg.id, m)
                    }
                }
            } catch {
                sawError = "\(error)"
                cause = error
                nativeLog("[iCloudBridge] forwardToSwiftRuntime: chatStream() failed for msg %@: %@", msg.id, "\(error)")
            }
            // Retain admission until the terminal transcript writer joins, even if the stream closes first.
            await execution.waitForProducerTermination()
            } onCancel: {
                // Stop is the turn's one cancel link: the run's flag, not the stream.
                Task { try? await MacChatTurnRuntime(dataRoot: PersistenceCore.defaultDataRoot()).stop(sessionId: resolvedSessionID, runId: msg.id) }
            }
            return (finalAnswer ?? deltaCoalescer.text, deltaCoalescer.sequence, sawError, toolEventCounter, attachments, cause)
            }
            }
            let root = PersistenceCore.defaultDataRoot()
            // A regenerate replaces an answer, so it never joins another turn.
            let admitted: TurnAdmission.Admitted<Outcome>
            if suppressUserAppend {
                admitted = .ran(try await TurnAdmission.shared.runAlone(dataRoot: root, sessionID: resolvedSessionID, turn: turn, operation: operation))
            } else {
                admitted = try await TurnAdmission.shared.run(dataRoot: root, sessionID: resolvedSessionID,
                    arrival: TurnArrival(words: msg.text, attachments: msg.attachments ?? [], surface: "ios", row: .shown),
                    turn: turn, operation: operation)
            }
            switch admitted {
            case .ran(let ran): return (ran.text, ran.deltaSeq, ran.error, ran.toolEvents, ran.attachments, ran.cause, nil)
            case .steered(let steered): return ("", 0, nil, 0, [], nil, steered.turnID)
            }
            } catch {
                return ("", 0, error.localizedDescription, 0, [], error, nil)
            }
        }
        // The turn and iOS placeholder share one correlation id so Stop targets the waiting run.
        sync.engine.registerActiveChatTask(streamTask, for: resolvedSessionID, runID: msg.id)
        let outcome = await streamTask.value
        progress.close()
        // Optional sends must settle without delaying durable replies; the phone rejects late progress after terminal resolution.
        return await withTaskGroup(of: Void.self, returning: Bool.self) { group in
        group.addTask { await progress.finish() }
        sync.engine.unregisterActiveChatTask(for: resolvedSessionID, expecting: streamTask)
        func finishWithoutReply(_ evidence: [String: String]) async -> Bool {
            let publicationID = "no-post-" + MacSyncSnapshotIntegrity.digest(Data(msg.id.utf8))
            do {
                var metadata = replyMetadata
                metadata["live"] = "true"
                metadata.merge(evidence, uniquingKeysWith: { _, new in new })
                _ = try await sync.bridge.sendChatMessage(text: "", sessionID: resolvedSessionID, correlationID: msg.id,
                    metadata: metadata, messageID: publicationID)
                await port.completed(sessionID: resolvedSessionID)
                return true
            } catch {
                nativeLog("[iCloudBridge] no-post msg %@ settlement not sent: %@", msg.id, "\(error)")
                do {
                    let state = try await sync.bridge.retainedNoPostState(id: publicationID, correlationID: msg.id)
                    if state == "completed" {
                        await port.completed(sessionID: resolvedSessionID)
                        return true
                    }
                    if state == "publication_owed" { return true }
                    await sync.bridge.noteNoPostDeliveryFailure(messageID: msg.id, cause: error.localizedDescription)
                } catch {
                    await sync.bridge.noteNoPostDeliveryFailure(messageID: msg.id, cause: error.localizedDescription)
                }
                return false
            }
        }
        if let readBy = outcome.readBy { return await finishWithoutReply(["readBy": readBy]) }
        if outcome.error == nil, outcome.cause == nil,
           outcome.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty, outcome.attachments.isEmpty {
            do {
                let silence = try await sync.storage.perform {
                    try SwiftNativeChatOrchestrationClient.silentTurn(
                        dataRoot: PersistenceCore.defaultDataRoot(), sessionId: resolvedSessionID, runId: turn.run, turnId: turn.id)
                }
                if let silence {
                    return await finishWithoutReply(["silence": silence])
                }
            } catch {
                return await writeErrorReply("The turn's silence record could not be read; repair its experience storage.",
                    detail: error.localizedDescription, sessionID: resolvedSessionID, turnReachedTerminalState: true)
            }
        }
        let wasCancelled = streamTask.isCancelled
            || outcome.cause is CancellationError

        if wasCancelled {
            // Tag cancellation so iOS preserves produced words even when terminal delivery overtakes a snapshot.
            do {
                _ = try await sync.bridge.sendChatMessage(
                    text: outcome.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                        ? "(cancelled)"
                        : outcome.text,
                    sessionID: resolvedSessionID,
                    correlationID: msg.id,
                    metadata: [
                        "kind": "cancelled",
                        "partialReply": outcome.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? "false" : "true",
                        "transport": "icloud",
                        "source": "mac",
                        "replyTo": route.replyTo,
                        "targetSourceKey": routeKey
                    ]
                )
                await sync.relay.sendICloudReplyPushNotification(
                    text: outcome.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                        ? "NativeAgent cancelled that reply."
                        : outcome.text,
                    sessionID: resolvedSessionID,
                    correlationID: msg.id,
                    kind: "cancelled"
                )
                port.completed(sessionID: resolvedSessionID)
                return true
            } catch {
                nativeLog("[iCloudBridge] failed to write cancel reply for msg %@: %@", msg.id, "\(error)")
                port.completed(sessionID: resolvedSessionID)
                return ICloudIncomingTurnConsumptionPolicy.shouldConsume(
                    turnReachedTerminalState: true,
                    replyPublished: false
                )
            }
        }

        if let errMsg = outcome.error {
            let error = outcome.cause
            if let chatError = error as? ChatOrchestrationError,
               case .helperModelChoice(let sessionID, let reason, let message) = chatError {
                return await writeErrorReply(
                    message, partialReply: outcome.text, sessionID: sessionID, turnReachedTerminalState: true,
                    needs: Self.needsInteractionEnvelope(kind: "model_choice", target: sessionID, reason: reason)
                )
            }
            return await writeErrorReply(
                "NativeAgent hit an error answering that message.",
                detail: error.flatMap { ProviderRecoveryPolicy.personMessage($0) } ?? ChatStreamErrorText.normalize(
                    NativeAppSecretRedactor.redactedRemoteErrorDetail(errMsg), retryAction: "Retry"),
                partialReply: outcome.text,
                sessionID: resolvedSessionID, turnReachedTerminalState: true
            )
        }

        let replyText = outcome.text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !replyText.isEmpty || !outcome.attachments.isEmpty else {
            nativeLog("[iCloudBridge] forwardToSwiftRuntime: empty reply for msg %@", msg.id)
            return await writeErrorReply(
                "NativeAgent returned an empty reply. Check NativeAgent logs for that run.",
                sessionID: resolvedSessionID,
                turnReachedTerminalState: true
            )
        }

        TurnTraceBus.fire(TurnTraceEvent(
            turnId: turnID, kind: "surface.replyDeliveryStarted", sessionId: resolvedSessionID,
            surface: "ios", payload: .object(["characters": .int(Int64(replyText.count))]), turn: turn))
        do {
            _ = try await sync.bridge.sendChatMessage(
                text: replyText,
                sessionID: resolvedSessionID,
                correlationID: msg.id,
                metadata: replyMetadata,
                attachments: outcome.attachments
            )
            // Only requested results retain a notification intent; retries deliver that event without notifying on ordinary conversation.
            port.completed(sessionID: resolvedSessionID)
            nativeLog("[iCloudBridge] forwarded iOS msg %@ → Swift chatStream (session=%@) → wrote reply (%d chars, %d deltas, %d attachments)",
                  msg.id, resolvedSessionID, replyText.count, outcome.deltaSeq, outcome.attachments.count)
            return true
        } catch {
            nativeLog("[iCloudBridge] failed to write reply to Drive for msg %@: %@", msg.id, "\(error)")
            // Publish the durable Mac transcript so the phone can recover the reply.
            port.completed(sessionID: resolvedSessionID)
            return ICloudIncomingTurnConsumptionPolicy.shouldConsume(
                turnReachedTerminalState: true,
                replyPublished: false
            )
        }
        }
    }

    nonisolated static func bridgeAttachments(
        from attachments: [ChatTurnRuntime.MultimodalAttachment],
        text: String,
        sessionID: String,
        correlationID: String,
        metadata: [String: String]
    ) throws -> [NativeAgentShared.MultimodalAttachment] {
        guard !attachments.isEmpty else { return [] }
        var previews = attachments.map { attachment in
            NativeAgentShared.MultimodalAttachment(
                id: attachment.id, type: "image", base64: "", mime: "image/jpeg",
                name: attachment.name.map { ($0 as NSString).deletingPathExtension + ".jpg" }
            )
        }
        var envelope = BridgeMessage.make(
            sender: "mac", text: text, sessionID: sessionID,
            correlationID: correlationID, metadata: metadata, attachments: previews
        )
        // Budget signed attachment names plus duplicate CloudKit fields and decimal size growth.
        envelope.signature = String(repeating: "0", count: 64)
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.sortedKeys]
        let remaining = NAChatMessageCodec.maxCloudKitRecordValueBytes
            - (try encoder.encode(envelope)).count - text.utf8.count - sessionID.utf8.count - 8192
        // Base64 grows by 4/3 and JSON may escape slashes; share the budget so later images are not silently dropped.
        let imageBudget = max(0, remaining / attachments.count) * 3 / 8
        guard imageBudget > 0 else {
            throw DeviceSyncError.payloadTooLarge(
                actualBytes: NAChatMessageCodec.maxCloudKitRecordValueBytes - remaining,
                maximumBytes: NAChatMessageCodec.maxCloudKitRecordValueBytes
            )
        }
        for (index, attachment) in attachments.enumerated() {
            guard let path = attachment.path,
                  let source = CGImageSourceCreateWithURL(URL(fileURLWithPath: path) as CFURL, nil) else {
                throw CocoaError(.fileReadCorruptFile)
            }
            var dimension = 1400
            while true {
                guard let image = CGImageSourceCreateThumbnailAtIndex(source, 0, [
                    kCGImageSourceCreateThumbnailFromImageAlways: true,
                    kCGImageSourceCreateThumbnailWithTransform: true,
                    kCGImageSourceThumbnailMaxPixelSize: dimension
                ] as CFDictionary) else { throw CocoaError(.fileReadCorruptFile) }
                let data = NSMutableData()
                guard let destination = CGImageDestinationCreateWithData(data, UTType.jpeg.identifier as CFString, 1, nil) else {
                    throw CocoaError(.fileWriteUnknown)
                }
                CGImageDestinationAddImage(destination, image, [kCGImageDestinationLossyCompressionQuality: 0.7] as CFDictionary)
                guard CGImageDestinationFinalize(destination) else { throw CocoaError(.fileWriteUnknown) }
                if data.length <= imageBudget {
                    previews[index].base64 = (data as Data).base64EncodedString()
                    previews[index].byteSize = data.length
                    break
                }
                guard dimension > 1 else {
                    throw DeviceSyncError.payloadTooLarge(actualBytes: data.length, maximumBytes: imageBudget)
                }
                dimension = max(1, dimension * 3 / 4)
            }
        }
        envelope = BridgeMessage.make(
            id: envelope.id, sender: "mac", text: text, sessionID: sessionID,
            correlationID: correlationID, metadata: metadata, attachments: previews,
            timestamp: envelope.timestamp
        )
        envelope.signature = String(repeating: "0", count: 64)
        _ = try NAChatMessageCodec.encode(envelope)
        return previews
    }

    private func sendICloudTextDelta(
        _ flush: ICloudTextDeltaFlush,
        turn: Turn,
        sender: ICloudConflatedSender,
        sessionID: String,
        correlationID: String,
        replyTo: String,
        targetSourceKey: String
    ) {
        sender.submit(key: "delta") {
            do {
                _ = try await sync.bridge.sendChatMessage(
                    text: flush.text,
                    sessionID: sessionID,
                    correlationID: correlationID,
                    metadata: [
                        "kind": "text_delta",
                        "seq": String(flush.sequence),
                        "flushReason": flush.reason.rawValue,
                        "coalesced": "true",
                        "chars": String(flush.text.count),
                        "transport": "icloud",
                        "source": "mac",
                        "replyTo": replyTo,
                        "targetSourceKey": targetSourceKey
                    ]
                )
                TurnTraceBus.fire(TurnTraceEvent(turnId: turn.id, kind: "phone.deltaAccepted",
                    sessionId: sessionID, surface: "ios", payload: .object([
                        "messageId": .string(correlationID), "seq": .int(Int64(flush.sequence))
                    ]), turn: turn))
            } catch {
                nativeLog("[iCloudBridge] failed text_delta seq=%d msg=%@: %@", flush.sequence, correlationID, "\(error)")
            }
        }
    }

    private func sendICloudProgress(
        text: String, sessionID: String, correlationID: String, sender: ICloudConflatedSender,
        metadata: [String: String], key: String = NativeAgentICloudBridgeConstants.KVSKey.chatProgressLatest
    ) {
        sender.submit(key: key) {
            let delivered = await sync.bridge.sendKVSChatProgress(text: text, sessionID: sessionID,
                correlationID: correlationID, metadata: metadata, key: key)
            if !delivered { nativeLog("[iCloudBridge] optional progress not delivered for %@", correlationID) }
        }
    }

    // Reconcile the session index under its file lock so concurrent updates remain idempotent.
    func ensureChatSessionIndex(sessionID: String, dataRoot root: URL) async throws {
        if let bot = try BotDefinitionStore(dataRoot: root).definition(forSession: sessionID) {
            _ = try await StandingBotContinuity.openSession(for: bot, dataRoot: root)
            return
        }
        let sessionsPath = root
            .appendingPathComponent("chat", isDirectory: true)
            .appendingPathComponent("sessions.json")
        let nowISO = ISO8601DateFormatter().string(from: Date())
        let entry: [String: JSONValue] = [
            "id": .string(sessionID),
            "title": .string("New Chat"),
            "createdAt": .string(nowISO),
            "updatedAt": .string(nowISO),
            "source": .string("ios"),
            "threadKind": .string(ChatThreadKind.direct.rawValue),
            "sourceKey": .string(try NativeAgentICloudBridgeConstants.mobileSourceKey),
            "archived": .bool(false),
            "messageCount": .int(0),
            ChatSessionIndexFile.transcriptGenerationKey: .int(0),
        ]
        let changed = try await SwiftNativePersistenceCore.withFileLock(sessionsPath) { () async throws -> Bool in
            var sessions = try ChatSessionIndexFile.loadObjectRowsForMutation(at: sessionsPath)
            if sessions.contains(where: { row in
                guard case .string(let id)? = row["id"] else { return false }
                return id == sessionID
            }) {
                return false
            }
            sessions.insert(entry, at: 0)
            try ChatSessionIndexFile.write(sessions, to: sessionsPath)
            ChatSessionRetention.enforceBestEffort(
                dataRoot: root,
                rows: sessions,
                now: Date(),
                context: "AppDelegate.upsertMobileChatSessionRow"
            )
            return true
        }
        if changed {
            await MainActor.run {
                sync.engine.requestChatSnapshotPublication(includeTranscripts: false)
            }
        }
    }
}
