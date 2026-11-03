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
// Blueprint: | `ICloudIncomingTurnForwarder.swift` | Signed phone turns route helpers/resident chat; payload-free pickup and text-delta acceptance timings; attachment-kind progress; checked session commits, Privacy-redacted errors and retained conflated optional publication; full replies keep streamed pre-tool words; Error/Stop envelopes mark accumulated reply text for phone settlement; every delta enters retained conflated optional publication through `ICloudConflatedSender` immediately; terminal delivery runs alongside admitted optional sends and traces `surface.replyDeliveryStarted`; iCloudChatFileAccess, checked session commits and Privacy-redacted errors |

/// One retained worker; each presentation channel holds only its latest value.
/// Closing discards unsent optional values. The owner joins the admitted send
/// alongside terminal delivery; a late optional value cannot reopen the phone's
/// resolved correlation.
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

    /// The only file-access IDs the signed iPhone chat route admits. This is
    /// intentionally shared with the mobile pill rather than treating its
    /// persisted label as authority.
    static func iCloudChatFileAccess(from remoteMetadata: [String: String]) throws -> String {
        guard let raw = remoteMetadata["fileAccess"] else { return "auto" }
        guard let mode = ICloudChatFileAccessPolicy.Mode(raw) else {
            throw ToolFailureError("The phone's fileAccess request is unrecognized; no file access was inferred.",
                argumentPath: "request.fileAccess",
                accepted: ICloudChatFileAccessPolicy.acceptedIDs.sorted().joined(separator: ", "), effects: .none)
        }
        return mode.rawValue
    }

    /// Emit the typed needs-input envelope for inline cards; the accompanying sentence remains self-contained.
    static func needsInteractionEnvelope(kind: String, target: String, reason: String) -> String? {
        let needs: [String: String] = ["kind": kind, "target": target, "reason": reason]
        let envelope: [String: Any] = ["status": "needs_input", "needs": needs]
        guard let data = try? JSONSerialization.data(withJSONObject: envelope),
              let json = String(data: data, encoding: .utf8), json.count <= 900 else { return nil }
        return json
    }

    @MainActor
    public func forwardToSwiftRuntime(_ msg: BridgeMessage) async -> Bool {
        let receivedAt = Date()
        let remoteMetadata = msg.metadata ?? [:]
        let sourceKey = remoteMetadata["sourceKey"] ?? "app"
        let routeKey = remoteMetadata["routeKey"] ?? remoteMetadata["deviceSourceKey"] ?? sourceKey
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
                    "replyTo": remoteMetadata["clientSurface"] ?? "iphone",
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
                    "replyTo": remoteMetadata["clientSurface"] ?? "iphone",
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
        // The run is registered for Stop at admission, before any await: a Stop
        // from here on names this message's run wherever it has got to, and the
        // turn's own acceptance of the same run is the same registration.
        let turnID = TurnTraceContext.mintTurnId()
        TurnTraceBus.fire(TurnTraceEvent(turnId: turnID, ts: receivedAt, kind: "phone.pickup",
            sessionId: resolvedSessionID, surface: "ios", payload: .object([
                "messageId": .string(msg.id),
                "sentAt": .string(NativeTimestampFormat.fractionalZulu(msg.timestamp)),
                "pickupMs": .double(receivedAt.timeIntervalSince(msg.timestamp) * 1_000)
            ])))
        let stopFlag = ChatCancelFlag.accept(dataRoot: PersistenceCore.defaultDataRoot(),
                                             sessionId: resolvedSessionID, runId: msg.id, turnId: turnID)
        defer { ChatCancelFlag.finish(stopFlag) }
        do {
            try await iCloudBridge.bindReplySession(msg, sessionID: resolvedSessionID, dataRoot: PersistenceCore.defaultDataRoot())
            // Also cover early-return handlers (control handoff and supersession),
            // before they can perform work outside the stream task.
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
                    message: msg.text, reply: reply, sessionId: resolvedSessionID, surface: "ios", runId: msg.id
                )
                _ = try await sync.bridge.sendChatMessage(text: reply, sessionID: resolvedSessionID,
                    correlationID: msg.id, metadata: [
                        "kind": "final", "transport": "icloud", "source": "mac",
                        "replyTo": remoteMetadata["clientSurface"] ?? "iphone", "targetSourceKey": routeKey,
                    ])
                await sync.relay.sendICloudReplyPushNotification(text: reply, sessionID: resolvedSessionID,
                    correlationID: msg.id, kind: "reply")
                sync.engine.requestChatSnapshotPublication(includeTranscripts: true)
                port.completed(sessionID: resolvedSessionID)
                return true
            } catch {
                return await writeErrorReply("Control handoff could not be confirmed: \(NativeAppSecretRedactor.redactedRemoteErrorDetail(error.localizedDescription))",
                    sessionID: resolvedSessionID, turnReachedTerminalState: true)
            }
        }

        // Where User was when his "take over" arrived, before any queue.
        let takeover = signatureVerified(msg) ? await MacWorkContinuation.admit(msg.text) : nil

        func consumeSupersededMessage() async -> Bool {
            defer { port.completed(sessionID: resolvedSessionID) }
            do {
                _ = try await sync.bridge.sendChatMessage(text: "(cancelled)", sessionID: resolvedSessionID,
                    correlationID: msg.id, metadata: [
                        "kind": "cancelled", "transport": "icloud", "source": "mac",
                        "replyTo": remoteMetadata["clientSurface"] ?? "iphone", "targetSourceKey": routeKey,
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
        // User sent this from his phone, so it is the conversation he is in.
        let anchorRoot = PersistenceCore.defaultDataRoot()
        let anchorOperation = "conversation.anchor:" + resolvedSessionID
        do {
            _ = try await ConversationAnchor.publish(
                sessionId: resolvedSessionID, source: "ios",
                conversationKind: SessionConversation.kind(resolvedSessionID) ?? .legacy,
                dataRoot: anchorRoot)
            RepairOwed.settle(anchorRoot, operation: anchorOperation,
                             evidence: .init(source: "conversation-anchor", id: resolvedSessionID))
        } catch {
            RepairOwed.owe(anchorRoot, id: anchorOperation, kind: .run,
                operation: anchorOperation, owner: "Conversation anchor",
                words: "The phone conversation was accepted, but its current-conversation anchor could not be published: \(error.localizedDescription)",
                lever: "Repair the conversation anchor store and publish the accepted session \(resolvedSessionID); do not replay its message.")
        }

        // File access remains a signed per-message request. Provider/model/
        // effort/tier metadata is UI evidence only; the central facade admits
        // those controls from Mac-owned canonical routing.
        let replacementAssistantMessageID = ICloudChatReplacementIntent
            .decode(remoteMetadata)?.assistantMessageID
        let suppressUserAppend = replacementAssistantMessageID != nil

        // MacSyncEngine retains the turn for explicit Stop; passive sync shutdown lets accepted work settle.
        let replyMetadata = [
            "kind": "final",
            "transport": "icloud",
            "source": "mac",
            "replyTo": remoteMetadata["clientSurface"] ?? "iphone",
            "targetSourceKey": routeKey
        ]
        let replyRoute = ChatToolSessionContext.ReplyRoute(
            surface: "ios",
            sourceKey: routeKey,
            replyTo: remoteMetadata["clientSurface"] ?? "iphone",
            correlationId: msg.id
        )
        let chatClient = port.residentChatClient()
        // Bind cryptographic evidence inside the detached consumer; a surface
        // label or phone-supplied metadata can never supply this authority.
        let commandSignatureVerified = signatureVerified(msg)
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
        // The conflated sender must not replace the voice-note line before
        // it can leave the Mac. Deltas/tool progress take over naturally.
        if msg.attachments?.contains(where: { $0.type == "audio" }) != true {
            writeProgress("\(agentDisplayName) is thinking", stage: "thinking", sessionID: resolvedSessionID, sender: progress)
        }
        let streamTask = Task.detached(priority: .userInitiated) { () -> (text: String, deltaSeq: Int, error: String?, toolEvents: Int, attachments: [NativeAgentShared.MultimodalAttachment], cause: Error?) in
            do {
            if try iCloudBridge.chatStopRequested(session: resolvedSessionID, runID: msg.id, dataRoot: PersistenceCore.defaultDataRoot()) {
                throw CancellationError()
            }
            let helper = try SessionConversation.checkedIsHelper(resolvedSessionID)
            return try await TurnAdmission.shared.run(dataRoot: PersistenceCore.defaultDataRoot(), sessionID: resolvedSessionID) {
            return await TurnTraceContext.$turnId.withValue(turnID) {
            await ChatPersistenceContext.$pinnedTurnRunID.withValue(msg.id) {
            await ChatToolSessionContext.$envelope.withValue(TurnEnvelope(
                surface: "ios", commandSignatureVerified: commandSignatureVerified, deliveryRoute: replyRoute
            )) {
            if helper {
                let textProgress = OSAllocatedUnfairLock(initialState: ICloudTextDeltaCoalescer())
                do {
                    let request = TurnRequest(message: msg.text, sessionID: resolvedSessionID, fileAccess: chatFileAccess,
                        surface: "ios", replyRoute: replyRoute,
                        replacementAssistantMessageID: .some(replacementAssistantMessageID))
                    let reply = try await request.bind {
                        try await port.helperReply(message: msg.text, sessionID: resolvedSessionID,
                            attachments: msg.attachments ?? [], fileAccess: chatFileAccess, progress: { event in
                                guard case .delta(let text) = event else { return }
                                let flush = textProgress.withLock { state in
                                    state.push(delta: text)
                                }
                                if let flush {
                                    sendICloudTextDelta(flush, sender: progress, sessionID: resolvedSessionID, correlationID: msg.id,
                                        replyTo: remoteMetadata["clientSurface"] ?? "iphone", targetSourceKey: routeKey)
                                }
                            })
                    }
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
            // The phone reads an app call as the action it ran.
            let shown = ShownToolNames()
            var deltaCoalescer = ICloudTextDeltaCoalescer()

            // Core admits the session's execution contract inside the producer.
            let execution = chatClient.chatStreamExecution(
                message: msg.text,
                sessionId: resolvedSessionID,
                // Signed metadata is evidence only. The facade
                // admits the Mac-owned ios tuple before append.
                model: "",
                reasoningEffort: "",
                fileAccess: chatFileAccess,
                attachments: msg.attachments ?? [],
                persona: nil,
                surface: "ios",
                suppressUserAppend: suppressUserAppend,
                replacementAssistantMessageID: replacementAssistantMessageID,
                replyRoute: replyRoute,
                macContinuation: takeover
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
                                sender: progress,
                                sessionID: resolvedSessionID,
                                correlationID: msg.id,
                                replyTo: remoteMetadata["clientSurface"] ?? "iphone",
                                targetSourceKey: routeKey
                            )
                        }
                    case .final(let r):
                        // Settlement keeps all her words, including those
                        // already shown before tools ran.
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
                                "replyTo": remoteMetadata["clientSurface"] ?? "iphone",
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
                                "replyTo": remoteMetadata["clientSurface"] ?? "iphone",
                                "targetSourceKey": routeKey
                            ]
                        )
                    case .toolResult(let called, let output):
                        let call = shown.result(called)
                        let name = call.name
                        let outcome = ChatToolOutcome.exactResultClass(output).rawValue
                        let detail = [ChatToolOutcome.explanation(output), ChatToolOutcome.remedy(output)].compactMap { $0 }.joined(separator: " · ")
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
                                "replyTo": remoteMetadata["clientSurface"] ?? "iphone",
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
            // Stream close can precede the producer's terminal transcript write.
            // Keep the phone's admission slot until that writer has joined.
            await execution.waitForProducerTermination()
            } onCancel: {
                // Stop is the turn's one cancel link: the run's flag, not the stream.
                Task { try? await MacChatTurnRuntime(dataRoot: PersistenceCore.defaultDataRoot()).stop(sessionId: resolvedSessionID, runId: msg.id) }
            }
            return (finalAnswer ?? deltaCoalescer.text, deltaCoalescer.sequence, sawError, toolEventCounter, attachments, cause)
            }
            }
            }
            }
            } catch {
                return ("", 0, error.localizedDescription, 0, [], error)
            }
        }
        // The run id is this turn's correlation id — the same one iOS holds
        // for the placeholder it is waiting on, so a Stop can name it.
        sync.engine.registerActiveChatTask(streamTask, for: resolvedSessionID, runID: msg.id)
        let outcome = await streamTask.value
        progress.close()
        // An optional in-flight snapshot must settle, but it cannot hold her
        // durable reply behind its network round trip. The phone rejects late
        // progress for a resolved correlation. The group joins on every exit.
        return await withTaskGroup(of: Void.self, returning: Bool.self) { group in
        group.addTask { await progress.finish() }
        sync.engine.unregisterActiveChatTask(for: resolvedSessionID, expecting: streamTask)
        let wasCancelled = streamTask.isCancelled
            || outcome.cause is CancellationError

        if wasCancelled {
            // Cancellation: write a final reply tagged as cancelled so iOS
            // keeps all produced words even if the terminal overtakes a
            // snapshot, then ends the bubble as incomplete.
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
                        "replyTo": remoteMetadata["clientSurface"] ?? "iphone",
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
            surface: "ios", payload: .object(["characters": .int(Int64(replyText.count))])))
        do {
            _ = try await sync.bridge.sendChatMessage(
                text: replyText,
                sessionID: resolvedSessionID,
                correlationID: msg.id,
                metadata: replyMetadata,
                attachments: outcome.attachments
            )
            // Requested results carry their durable intent on the assistant
            // row. Publication retries that one phone event independently;
            // ordinary conversation does not create a notification.
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
        // Measure the signed envelope, including all attachment names. Reserve
        // duplicated CloudKit fields and growth in byteSize's decimal digits.
        envelope.signature = String(repeating: "0", count: 64)
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.sortedKeys]
        let remaining = NAChatMessageCodec.maxCloudKitRecordValueBytes
            - (try encoder.encode(envelope)).count - text.utf8.count - sessionID.utf8.count - 8192
        // Base64 expands 4/3; JSON may also escape every slash. Share the
        // remaining budget across every image rather than dropping later ones.
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
        sender: ICloudConflatedSender,
        sessionID: String,
        correlationID: String,
        replyTo: String,
        targetSourceKey: String
    ) {
        let turnID = TurnTraceContext.turnId
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
                if let turnID {
                    TurnTraceBus.fire(TurnTraceEvent(turnId: turnID, kind: "phone.deltaAccepted",
                        sessionId: sessionID, surface: "ios", payload: .object([
                            "messageId": .string(correlationID), "seq": .int(Int64(flush.sequence))
                        ])))
                }
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

    // Reconcile the phone session's sessions.json entry idempotently under the file lock.
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
