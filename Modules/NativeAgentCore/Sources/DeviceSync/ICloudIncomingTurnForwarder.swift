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

/// One signed phone message: the message, its admitted route, and the reply target every answer to it names.
final class ICloudPhoneCall: Sendable {
    let msg: BridgeMessage
    let route: ICloudPhoneRoute
    let routeKey: String

    init(msg: BridgeMessage, route: ICloudPhoneRoute, routeKey: String) {
        self.msg = msg
        self.route = route
        self.routeKey = routeKey
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
        let phone = ICloudPhoneCall(msg: msg, route: route, routeKey: routeKey)
        // Resolve one session id before execution so transcripts and every reply identify the same conversation.
        let trimmedSessionID = msg.sessionID?.trimmingCharacters(in: .whitespacesAndNewlines)
        let resolvedSessionID: String
        if let trimmedSessionID, !trimmedSessionID.isEmpty {
            guard let safeSessionID = NativeAgentChatSessionID.normalizedPathComponent(trimmedSessionID) else {
                nativeLog("[iCloudBridge] dropping iOS msg %@: invalid sessionID %@", msg.id, trimmedSessionID)
                return await writeErrorReply(
                    "iPhone message rejected: invalid chat session id.",
                    sessionID: nil, to: phone
                )
            }
            resolvedSessionID = safeSessionID
        } else {
            do {
                let root = sync.dataRoot
                resolvedSessionID = try await sync.storage.perform {
                    try iCloudBridge.readChat(msg.id, dataRoot: root).assistantSessionId ?? UUID().uuidString
                }
            } catch {
                nativeLog("[iCloudBridge] reply session could not be read: %@", error.localizedDescription)
                return false
            }
        }
        let incomingAttachments = (msg.attachments ?? []).map { attachment in
            var attachment = attachment
            attachment.path = nil
            return attachment
        }
        guard incomingAttachments.allSatisfy({ !$0.base64.isEmpty }) else {
            return await writeErrorReply("iPhone attachment rejected: no file bytes were sent. Attach the file again.", sessionID: resolvedSessionID, to: phone)
        }
        let chatFileAccess: String
        do { chatFileAccess = try Self.iCloudChatFileAccess(from: remoteMetadata) }
        catch { return await writeErrorReply(error.localizedDescription, sessionID: resolvedSessionID, to: phone) }
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
        let stopFlag = ChatCancelFlag.accept(dataRoot: sync.dataRoot,
                                             sessionId: resolvedSessionID, runId: msg.id, turnId: turnID)
        defer { ChatCancelFlag.finish(stopFlag) }
        do {
            try await iCloudBridge.bindReplySession(msg, sessionID: resolvedSessionID, dataRoot: sync.dataRoot)
            // Cover early returns before control handoff or supersession can work outside the stream task.
            if try iCloudBridge.chatStopRequested(session: resolvedSessionID, runID: msg.id, dataRoot: sync.dataRoot) {
                return await sync.bridge.sendTerminalWithoutSavedReply("Stopped.", kind: "cancelled", to: msg,
                    sessionID: resolvedSessionID, route: route)
            }
        } catch {
            nativeLog("[iCloudBridge] reply session could not be retained: %@", error.localizedDescription)
            return false
        }

        // Read before any suspension: a handoff after this point supersedes it.
        let receivedAtHandoffGeneration = port.controlHandoffGeneration(sessionID: resolvedSessionID)

        if UserMessageIntentSignals.isControlHandoff(msg.text) {
            return await answerControlHandoff(phone, trimmedSessionID: trimmedSessionID,
                resolvedSessionID: resolvedSessionID, admittedTurn: admittedTurn)
        }

        // Capture the person's surface when takeover arrives, before queueing can change it.
        let takeover = signatureVerified(msg) ? await MacWorkContinuation.admit(msg.text) : nil

        if let answered = await preparePhoneSession(phone, resolvedSessionID: resolvedSessionID,
            receivedAtHandoffGeneration: receivedAtHandoffGeneration) {
            return answered
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
        // Read handoff and Stop without suspending before task registration.
        guard !supersededByControlHandoff(phone, resolvedSessionID, receivedAtHandoffGeneration) else {
            return await consumeSupersededMessage(phone, resolvedSessionID)
        }
        do {
            if try iCloudBridge.chatStopRequested(session: resolvedSessionID, runID: msg.id, dataRoot: sync.dataRoot) {
                return await sync.bridge.sendTerminalWithoutSavedReply("Stopped.", kind: "cancelled", to: msg,
                    sessionID: resolvedSessionID, route: route)
            }
        } catch {
            nativeLog("[iCloudBridge] phone Stop record could not be read: %@", error.localizedDescription)
            return false
        }
        let progress = ICloudConflatedSender()
        let streamTask = Task.detached(priority: .userInitiated) { () -> MacSyncEngine.ICloudChatOutcome in
            await runPhoneTurn(phone, resolvedSessionID: resolvedSessionID, incomingAttachments: incomingAttachments,
                chatFileAccess: chatFileAccess, suppressUserAppend: suppressUserAppend,
                chatClient: chatClient, turn: turn, progress: progress)
        }
        // The turn and iOS placeholder share one correlation id so Stop targets the waiting run.
        sync.engine.registerActiveChatTask(streamTask, for: resolvedSessionID, runID: msg.id)
        let outcome = await streamTask.value
        progress.close()
        // Optional sends must settle without delaying durable replies; the phone rejects late progress after terminal resolution.
        return await withTaskGroup(of: Void.self, returning: Bool.self) { group in
        group.addTask { await progress.finish() }
        sync.engine.unregisterActiveChatTask(for: resolvedSessionID, expecting: streamTask)
        return await deliverPhoneOutcome(outcome, phone, resolvedSessionID: resolvedSessionID, turnID: turnID,
            turn: turn, replyMetadata: replyMetadata)
        }
    }

    /// The phone's error answer for this message; a failed publication still consumes a turn that reached its end.
    @MainActor
    private func writeErrorReply(
        _ text: String,
        detail: String? = nil,
        partialReply: String? = nil,
        sessionID: String?,
        turnReachedTerminalState: Bool = false,
        needs: String? = nil,
        to phone: ICloudPhoneCall
    ) async -> Bool {
        let (msg, route, routeKey) = (phone.msg, phone.route, phone.routeKey)
        do {
            var metadata = [
                "kind": "error",
                "errorDetail": iCloudBridge.phoneErrorDetail(detail ?? text),
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

    /// A signed control handoff stops the session's turn here and answers with its confirmation.
    @MainActor
    private func answerControlHandoff(_ phone: ICloudPhoneCall, trimmedSessionID: String?, resolvedSessionID: String,
                                      admittedTurn: Turn) async -> Bool {
        let (msg, route, routeKey) = (phone.msg, phone.route, phone.routeKey)
        guard let trimmedSessionID, !trimmedSessionID.isEmpty, signatureVerified(msg) else {
            return await writeErrorReply("Control handoff requires a signed message naming its chat session.", sessionID: nil, to: phone)
        }
        do {
            try await iCloudBridge.beginChat(msg, sessionID: resolvedSessionID, dataRoot: sync.dataRoot)
        } catch {
            nativeLog("[iCloudBridge] handoff dispatch was not claimed: %@", error.localizedDescription)
            return false
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
                sessionID: resolvedSessionID, turnReachedTerminalState: true, to: phone)
        }
    }

    /// A control handoff after this message's arrival supersedes it.
    @MainActor
    private func supersededByControlHandoff(_ phone: ICloudPhoneCall, _ resolvedSessionID: String,
                                            _ receivedAtHandoffGeneration: Int) -> Bool {
        let msg = phone.msg
        return port.holdsMessageAfterControlHandoff(sessionID: resolvedSessionID,
            receivedAtGeneration: receivedAtHandoffGeneration, sentAt: msg.timestamp)
    }

    /// A superseded message is consumed with a cancelled answer.
    @MainActor
    private func consumeSupersededMessage(_ phone: ICloudPhoneCall, _ resolvedSessionID: String) async -> Bool {
        guard await sync.bridge.sendTerminalWithoutSavedReply("(cancelled)", kind: "cancelled", to: phone.msg,
            sessionID: resolvedSessionID, route: phone.route) else { return false }
        port.completed(sessionID: resolvedSessionID)
        return true
    }

    /// Before the turn runs: a superseding handoff consumes it, a pending Stop settles, the session is indexed and anchored.
    @MainActor
    private func preparePhoneSession(_ phone: ICloudPhoneCall, resolvedSessionID: String,
                                     receivedAtHandoffGeneration: Int) async -> Bool? {
        guard !supersededByControlHandoff(phone, resolvedSessionID, receivedAtHandoffGeneration) else {
            return await consumeSupersededMessage(phone, resolvedSessionID)
        }
        await port.awaitPendingChatStop(sessionID: resolvedSessionID)
        guard !supersededByControlHandoff(phone, resolvedSessionID, receivedAtHandoffGeneration) else {
            return await consumeSupersededMessage(phone, resolvedSessionID)
        }

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
                sessionID: resolvedSessionID, to: phone
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
        return nil
    }

    /// The admitted phone turn, off the main actor: a helper's reply or the resident chat stream, under turn admission.
    private func runPhoneTurn(
        _ phone: ICloudPhoneCall, resolvedSessionID: String, incomingAttachments: [NativeAgentShared.MultimodalAttachment],
        chatFileAccess: String, suppressUserAppend: Bool,
        chatClient: SwiftNativeChatOrchestrationClient, turn: Turn, progress: ICloudConflatedSender
    ) async -> MacSyncEngine.ICloudChatOutcome {
        let (msg, route, routeKey) = (phone.msg, phone.route, phone.routeKey)
        let root = sync.dataRoot
        do {
            let helper = try SessionConversation.checkedIsHelper(resolvedSessionID)
            let operation: (Turn) async throws -> MacSyncEngine.ICloudChatOutcome = { turn in
                do {
                    try await iCloudBridge.beginChat(msg, sessionID: resolvedSessionID, dataRoot: root)
                } catch let error as CancellationError {
                    throw error
                } catch {
                    nativeLog("[iCloudBridge] phone dispatch was not claimed: %@", error.localizedDescription)
                    return .undispatched
                }
                return await TurnTraceContext.$turnId.withValue(turn.id) { () -> MacSyncEngine.ICloudChatOutcome in
                    if helper {
                        let textProgress = OSAllocatedUnfairLock(initialState: ICloudTextDeltaCoalescer())
                        do {
                            let reply = try await port.helperReply(message: msg.text, sessionID: resolvedSessionID,
                                attachments: incomingAttachments, fileAccess: chatFileAccess, progress: { event in
                                    guard case .delta(let text) = event,
                                          let flush = textProgress.withLock({ $0.push(delta: text) }) else { return }
                                    sendICloudTextDelta(flush, turn: turn, sender: progress, sessionID: resolvedSessionID,
                                        correlationID: msg.id, replyTo: route.replyTo, targetSourceKey: routeKey)
                                }, turn: turn)
                            return .ran(.success(reply), partial: "")
                        } catch {
                            return .ran(.failure(error), partial: textProgress.withLock { $0.text })
                        }
                    }

                    // Core admits the Mac-owned execution contract. Signed phone metadata is evidence only.
                    let execution = chatClient.chatStreamExecution(
                        message: msg.text, sessionId: resolvedSessionID, model: "", reasoningEffort: "",
                        fileAccess: chatFileAccess, attachments: incomingAttachments, persona: nil, surface: "ios",
                        suppressUserAppend: suppressUserAppend,
                        replacementAssistantMessageID: turn.rows.replacementAssistantMessageID, turn: turn)
                    return await withTaskCancellationHandler {
                        var movement = ICloudTextDeltaCoalescer()
                        do {
                            for try await event in execution.events {
                                if Task.isCancelled { break }
                                guard case .delta(let text) = event, !text.isEmpty,
                                      let flush = movement.push(delta: text) else { continue }
                                sendICloudTextDelta(flush, turn: turn, sender: progress, sessionID: resolvedSessionID,
                                    correlationID: msg.id, replyTo: route.replyTo, targetSourceKey: routeKey)
                            }
                        } catch {
                            nativeLog("[iCloudBridge] phone stream ended with error for %@: %@", msg.id, error.localizedDescription)
                        }
                        // The producer joins transcript settlement and carries the authoritative ending.
                        return .ran(await execution.waitForProducerTermination(), partial: movement.text)
                    } onCancel: { execution.cancel() }
                }
            }
            // A regenerate replaces an answer, so it never joins another turn.
            if suppressUserAppend {
                return try await TurnAdmission.shared.runAlone(dataRoot: root, sessionID: resolvedSessionID, turn: turn, operation: operation)
            }
            let admitted = try await TurnAdmission.shared.run(dataRoot: root, sessionID: resolvedSessionID,
                arrival: TurnArrival(words: msg.text, attachments: incomingAttachments, surface: "ios", row: .shown),
                runID: msg.id, turn: turn, operation: operation)
            switch admitted {
            case .ran(let outcome): return outcome
            case .steered(let steered): return .steered(readBy: steered.turnID)
            }
        } catch {
            return .ran(.failure(error), partial: "")
        }
    }

    /// A turn that ends without a reply settles the phone's placeholder with its evidence.
    @MainActor
    private func finishWithoutReply(_ evidence: [String: String], _ phone: ICloudPhoneCall, _ resolvedSessionID: String,
                                    _ replyMetadata: [String: String]) async -> Bool {
        let msg = phone.msg
        let publicationID = iCloudBridge.noPostPublicationID(msg.id)
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

    /// The phone receives the same terminal state during live delivery and recovery.
    @MainActor
    private func deliverPhoneOutcome(
        _ outcome: MacSyncEngine.ICloudChatOutcome, _ phone: ICloudPhoneCall, resolvedSessionID: String, turnID: String,
        turn: Turn, replyMetadata: [String: String]
    ) async -> Bool {
        let (msg, route, routeKey) = (phone.msg, phone.route, phone.routeKey)
        let response: ChatResponse
        switch outcome {
        case .undispatched:
            return false
        case .steered(let readBy):
            return await finishWithoutReply(["readBy": readBy], phone, resolvedSessionID, replyMetadata)
        case .ran(.success(let settled), _):
            response = settled
        case .ran(.failure(let error), let partial):
            if error is CancellationError {
                let text = partial.isEmpty ? "(cancelled)" : partial
                let retained = await sync.bridge.sendTerminalWithoutSavedReply(text, kind: "cancelled", to: msg,
                    sessionID: resolvedSessionID, route: route, partial: !partial.isEmpty, notifyCancellation: true)
                if retained { port.completed(sessionID: resolvedSessionID) }
                return retained
            }
            if let chatError = error as? ChatOrchestrationError,
               case .helperModelChoice(let sessionID, let reason, let message) = chatError {
                return await writeErrorReply(
                    message, partialReply: partial, sessionID: sessionID, turnReachedTerminalState: true,
                    needs: Self.needsInteractionEnvelope(kind: "model_choice", target: sessionID, reason: reason), to: phone
                )
            }
            return await writeErrorReply(
                "NativeAgent hit an error answering that message.",
                detail: ProviderRecoveryPolicy.personMessage(error) ?? ChatStreamErrorText.normalize(
                    NativeAppSecretRedactor.redactedRemoteErrorDetail(error.localizedDescription), retryAction: "Retry"),
                partialReply: partial, sessionID: resolvedSessionID, turnReachedTerminalState: true, to: phone
            )
        }

        if response.isSilentCompletion {
            do {
                let root = sync.dataRoot
                let silence = try await sync.storage.perform {
                    try SwiftNativeChatOrchestrationClient.silentTurn(
                        dataRoot: root, sessionId: resolvedSessionID, runId: turn.run, turnId: turn.id)
                }
                if let silence {
                    return await finishWithoutReply(["silence": silence], phone, resolvedSessionID, replyMetadata)
                }
                return await writeErrorReply("NativeAgent returned an empty reply. Check NativeAgent logs for that run.",
                    sessionID: resolvedSessionID, turnReachedTerminalState: true, to: phone)
            } catch {
                return await writeErrorReply("The turn's silence record could not be read; repair its experience storage.",
                    detail: error.localizedDescription, sessionID: resolvedSessionID, turnReachedTerminalState: true, to: phone)
            }
        }

        TurnTraceBus.fire(TurnTraceEvent(
            turnId: turnID, kind: "surface.replyDeliveryStarted", sessionId: resolvedSessionID,
            surface: "ios", payload: .object(["characters": .int(Int64(response.output.count))]), turn: turn))
        do {
            let verdict = try await sync.bridge.recoverReply(response, route: AgentBridgeCompletionRoute(
                surface: "ios", sessionId: resolvedSessionID, sourceKey: routeKey, replyTo: route.replyTo, correlationId: msg.id),
                firstPublication: true)
            if verdict == "completed", response.terminalState == .failed || response.terminalState == .stopped {
                let stopped = response.terminalState == .stopped
                let text = response.output.isEmpty
                    ? iCloudBridge.phoneErrorDetail(response.statusDetail
                        ?? (stopped ? "NativeAgent cancelled that reply." : "The reply could not be completed."))
                    : response.output
                await sync.relay.sendICloudReplyPushNotification(text: text, sessionID: resolvedSessionID,
                    correlationID: msg.id, kind: stopped ? "cancelled" : "error")
            }
        } catch {
            nativeLog("[iCloudBridge] failed to publish CloudKit reply for msg %@: %@", msg.id, error.localizedDescription)
        }
        // The producer already settled. Its answer and delivery obligation survive an unconfirmed upload.
        port.completed(sessionID: resolvedSessionID)
        return true
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
