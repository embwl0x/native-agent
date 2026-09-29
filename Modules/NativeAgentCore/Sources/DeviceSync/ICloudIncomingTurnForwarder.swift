import Foundation
import os
import NativeAgentShared
import NativeAgentCore
import ChatOrchestration
import PersistenceCore
import Transcripts
import ProviderRouting

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

/// The incoming CloudKit record acknowledges a user turn, not successful
/// delivery of the reply back to the phone. Once the runtime has reached a
/// terminal outcome, a transient reply-write failure must consume the input:
/// replaying it would run the same user message again on every drain tick.
enum ICloudIncomingTurnConsumptionPolicy {
    static func shouldConsume(
        turnReachedTerminalState: Bool,
        replyPublished: Bool
    ) -> Bool {
        turnReachedTerminalState || replyPublished
    }
}

private final class ICloudGeneratedAttachmentBox: @unchecked Sendable {
    private let lock = NSLock()
    private var attachments: [NativeAgentShared.MultimodalAttachment] = []

    func set(_ next: [NativeAgentShared.MultimodalAttachment]) {
        lock.lock()
        attachments = next
        lock.unlock()
    }

    func value() -> [NativeAgentShared.MultimodalAttachment] {
        lock.lock()
        defer { lock.unlock() }
        return attachments
    }
}

public struct ICloudIncomingTurnForwarder: Sendable {
    private static let turnAdmission = TurnAdmission()

    public static func runAdmittedTurn<T>(sessionID: String, isolation: isolated (any Actor)? = #isolation,
                                         operation: () async throws -> T) async throws -> T {
        try await turnAdmission.run(sessionID: sessionID, operation: operation)
    }

    private let port: any ICloudIncomingTurnPort

    public init(port: any ICloudIncomingTurnPort) {
        self.port = port
    }

    /// 2026-09-06: a runtime error can carry a Mac filesystem path (storage
    /// errors name the file they failed on). Nothing leaving this Mac for the
    /// phone may disclose one, so every absolute path in an exported detail is
    /// reduced to its last component before it crosses the bridge.
    static func redactedRemoteErrorDetail(_ value: String) -> String {
        // 2026-09-06: match the SHAPE of an absolute path, not a list of roots.
        // The old fixed root list let /data/..., /srv/... and /mnt/... through
        // untouched. Any absolute path of two or more segments is reduced to
        // its leaf; the lookbehind keeps the rule off relative paths ("a/b/c").
        // 2026-09-06: a colon is NOT in that lookbehind. It was, and it let
        // "path:/data/private/file.json" through whole — the leading slash was
        // preceded by a colon, and every later slash by a letter. A URL scheme
        // is still excluded without it: "https://host/x" cannot match at the
        // first slash (a segment needs one non-slash character and the next
        // character is "/"), nor at the second (preceded by "/"), nor at
        // "/x" (preceded by a letter).
        guard let regex = try? NSRegularExpression(
            pattern: "(?<![A-Za-z0-9_.~%/-])(?:/[^\\s\"'<>)\\]},;/]+){2,}",
            options: []
        ) else { return value }
        var text = value
        let matches = regex.matches(
            in: text,
            options: [],
            range: NSRange(location: 0, length: (text as NSString).length)
        )
        for match in matches.reversed() {
            let path = (text as NSString).substring(with: match.range)
            let leaf = (path as NSString).lastPathComponent
            text = (text as NSString).replacingCharacters(
                in: match.range,
                with: leaf.isEmpty ? "[redacted path]" : ".../\(leaf)"
            )
        }
        return text
    }

    /// The only file-access IDs the signed iPhone chat route admits. This is
    /// intentionally shared with the mobile pill rather than treating its
    /// persisted label as authority.
    static func iCloudChatFileAccess(from remoteMetadata: [String: String]) -> String {
        ICloudChatFileAccessPolicy.normalized(remoteMetadata["fileAccess"] ?? "")
    }

    // PATCH-2026-06-02 scheduler-consolidation: registerBackgroundRefreshTasks
    // is gone. It registered status-only NSBackgroundActivityScheduler entries
    // that did no work; the bgTaskIdentifiers entries above are OS-side wake
    // paths for non-dream loops and call runTickOnce when they fire.

    // AUTO-BOOTSTRAP: publish the HMAC pairing secret (and optional server info)
    // to iCloud KVS so iOS can configure itself without any manual pairing step.
    //
    // Key namespace:
    //   NativeAgent.pairing.hmacSecret   — base64-encoded 32-byte HMAC key
    //   NativeAgent.pairing.publishedAt  — ISO8601 timestamp (lets iOS pick newest
    //                                       if multiple Macs ever publish)
    //
    // Idempotency: reads current KVS value first; only writes if the secret changed
    // (or is absent), so repeated calls on every launch are cheap no-ops.
    //
    // Concurrency: nonisolated — called from Task.detached; touches no @MainActor state.
    // PATCH-2026-05-07: icloud-bridge forward iOS→Mac message to daemon and write reply to Drive
    /// The typed needs-input envelope (cards spec, `request_interaction`), as a
    /// compact JSON string. The inline-card work owns the rendering; this side
    /// only has to emit the shape, and a reader without that renderer loses
    /// nothing — the sentence beside it says the same thing.
    static func needsInteractionEnvelope(kind: String, target: String, reason: String) -> String? {
        let needs: [String: String] = ["kind": kind, "target": target, "reason": reason]
        let envelope: [String: Any] = ["status": "needs_input", "needs": needs]
        guard let data = try? JSONSerialization.data(withJSONObject: envelope),
              let json = String(data: data, encoding: .utf8), json.count <= 900 else { return nil }
        return json
    }

    @MainActor
    public func forwardToSwiftRuntime(_ msg: BridgeMessage) async -> Bool {
        let remoteMetadata = msg.metadata ?? [:]
        let sourceKey = remoteMetadata["sourceKey"] ?? "app"
        let routeKey = remoteMetadata["routeKey"] ?? remoteMetadata["deviceSourceKey"] ?? sourceKey
        func writeErrorReply(
            _ text: String,
            sessionID: String?,
            turnReachedTerminalState: Bool = false,
            needs: String? = nil
        ) async -> Bool {
            do {
                var metadata = [
                    "kind": "error",
                    "errorDetail": String(text.prefix(400)),
                    "transport": "icloud",
                    "source": "mac",
                    "replyTo": remoteMetadata["clientSurface"] ?? "iphone",
                    "targetSourceKey": routeKey
                ]
                // 2026-09-13 (first-failure pass): a refusal the person can
                // repair rides as the typed interaction envelope beside the
                // sentence, so the inline card work renders the control without
                // anyone parsing this prose. Absent that renderer the sentence
                // still stands on its own.
                if let needs { metadata["needs"] = needs }
                _ = try await port.sendChatMessage(
                    text: text,
                    sessionID: sessionID,
                    correlationID: msg.id,
                    metadata: metadata
                )
                await port.sendICloudReplyPushNotification(
                    text: text,
                    sessionID: sessionID,
                    correlationID: msg.id,
                    kind: "error"
                )
                port.completed(sessionID: sessionID)
                return true
            } catch {
                NSLog("[iCloudBridge] failed to write error reply for msg %@: %@", msg.id, "\(error)")
                if turnReachedTerminalState {
                    port.completed(sessionID: sessionID)
                }
                return ICloudIncomingTurnConsumptionPolicy.shouldConsume(
                    turnReachedTerminalState: turnReachedTerminalState,
                    replyPublished: false
                )
            }
        }
        func writeProgress(_ text: String, stage: String, sessionID: String) async {
            let delivered = await port.sendKVSChatProgress(
                text: text,
                sessionID: sessionID,
                correlationID: msg.id,
                metadata: [
                    "kind": "progress",
                    "stage": stage,
                    "transport": "icloud",
                    "source": "mac",
                    "replyTo": remoteMetadata["clientSurface"] ?? "iphone",
                    "targetSourceKey": routeKey
                ]
            )
            if !delivered {
                NSLog("[iCloudBridge] failed to write KVS progress for msg %@ stage=%@", msg.id, stage)
            }
        }

        // F7 P0 #1: pre-resolve the sessionID. If iOS sent nil/empty, mint a
        // UUID *here* so the SAME id flows into chatStream(), into the
        // persisted messages, and into every BridgeMessage we send back. iOS
        // latches on the sessionID in the first reply (ChatStore.receiveICloudReply
        // l.454); without pre-minting, runStream() generated a UUID we never
        // saw and iOS never got a session to latch.
        let trimmedSessionID = msg.sessionID?.trimmingCharacters(in: .whitespacesAndNewlines)
        let resolvedSessionID: String
        if let trimmedSessionID, !trimmedSessionID.isEmpty {
            guard let safeSessionID = NativeAgentChatSessionID.normalizedPathComponent(trimmedSessionID) else {
                NSLog("[iCloudBridge] dropping iOS msg %@: invalid sessionID %@", msg.id, trimmedSessionID)
                return await writeErrorReply(
                    "iPhone message rejected: invalid chat session id.",
                    sessionID: nil
                )
            }
            resolvedSessionID = safeSessionID
        } else {
            resolvedSessionID = UUID().uuidString
        }

        // A bot's session opened or pinned on iPhone is still that bot's
        // session: it runs on the bot's own checked tuple, never Chat's. The
        // same contract and the same gate the Mac send applies
        // (AppModel+ChatActions.swift) — a bot whose account was disconnected
        // or whose model left the catalog refuses its turn here exactly as a
        // scheduled run would, instead of quietly spending Chat's route
        // (2026-09-13 comb, item 1). The surface stays "ios", so every remote
        // restriction on this path is unchanged.
        let acceptedBotContract = await BotChatContract.checked(resolvedSessionID)
        if let contract = acceptedBotContract, let problem = contract.modelChoiceProblem {
            return await writeErrorReply(
                "\(contract.name) can't run yet. \(problem) This bot runs on its own account, "
                    + "never Chat's, so choosing it is the one repair - continue on the Mac, in this bot's card. "
                    + "Nothing was started, and its unfinished work is kept.",
                sessionID: resolvedSessionID,
                needs: Self.needsInteractionEnvelope(
                    kind: "model_choice",
                    target: resolvedSessionID,
                    reason: problem
                )
            )
        }

        // Swift-native cutover/fix2-ios-chat (2026-06-02): the daemon's
        // /v1/chat/stream route is dead — every iCloud-forwarded turn used to
        // silently no-reply on iPhone. Route the turn straight through the
        // in-process SwiftNative ChatOrchestration client instead.
        await writeProgress("Mac received it", stage: "received", sessionID: resolvedSessionID)
        // Resolve the live profile name independently of the chatPersona style quick-switch.
        let agentDisplayName = NativeAgentNotificationDefaults.agentDisplayName()
        if !(msg.attachments?.isEmpty ?? true) {
            await writeProgress("Reading attached photos", stage: "attachments", sessionID: resolvedSessionID)
        }
        await writeProgress("\(agentDisplayName) is thinking", stage: "thinking", sessionID: resolvedSessionID)

        // fix2/F3: iOS-created sessions don't get a `chat/sessions.json`
        // entry because the iCloud-bridge entry point skipped the index.
        // Ensure an entry exists BEFORE the chat() call persists messages
        // to `chat/messages/<id>.jsonl`, so SessionListView/getChatSessions
        // sees iOS turns alongside Mac-originated sessions.
        do {
            try await ensureChatSessionIndex(
                sessionID: resolvedSessionID,
                dataRoot: PersistenceCore.defaultDataRoot()
            )
        } catch {
            NSLog("[iCloudBridge] ensureChatSessionIndex failed for %@: %@", resolvedSessionID, "\(error)")
            return await writeErrorReply(
                "Chat history is unavailable because its session index needs repair on the Mac.",
                sessionID: resolvedSessionID
            )
        }

        await MainActor.run { port.received(in: resolvedSessionID) }

        let coAttachments: [ChatOrchestration.MultimodalAttachment] = (msg.attachments ?? []).map { a in
            ChatOrchestration.MultimodalAttachment(
                id: a.id,
                type: a.type,
                base64: a.base64,
                mime: a.mime,
                name: a.name,
                byteSize: a.byteSize,
                path: a.path
            )
        }

        // File access remains a signed per-message request. Provider/model/
        // effort/tier metadata is UI evidence only; the central facade admits
        // those controls from Mac-owned canonical routing.
        let replacementAssistantMessageID = ICloudChatReplacementIntent
            .decode(remoteMetadata)?.assistantMessageID
        let suppressUserAppend = replacementAssistantMessageID != nil
        let chatFileAccess = Self.iCloudChatFileAccess(from: remoteMetadata)

        // F7 P0 #3: cancellable stream task. We run the stream consumer in a
        // child Task and register it with MacSyncEngine by sessionID so the
        // iOS "cancelChat" inbox action can `.cancel()` it (in addition to
        // the cancelled.flag the streaming chat path also polls).
        let generatedAttachmentBox = ICloudGeneratedAttachmentBox()
        let personError = OSAllocatedUnfairLock<String?>(initialState: nil)
        let replyRoute = ChatToolSessionContext.ReplyRoute(
            surface: "ios",
            sourceKey: routeKey,
            replyTo: remoteMetadata["clientSurface"] ?? "iphone",
            correlationId: msg.id
        )
        let chatClient = port.residentChatClient()
        // Bind cryptographic evidence inside the detached consumer; a surface
        // label or phone-supplied metadata can never supply this authority.
        let commandSignatureVerified = port.signatureVerified(msg)
        let streamTask = Task.detached(priority: .userInitiated) { () -> (text: String, deltaSeq: Int, error: String?, toolEvents: Int) in
            do {
            return try await Self.runAdmittedTurn(sessionID: resolvedSessionID) {
            await ChatToolSessionContext.$commandSignatureVerified.withValue(commandSignatureVerified) {
            var accumulated = ""
            var sawError: String? = nil
            var toolEventCounter = 0
            var deltaCoalescer = ICloudTextDeltaCoalescer()

            // U4 Wave D (gpt-5.5 review-2 BLOCKER): iCloud/iOS streaming is a
            // REMOTE paired-user surface — self-evolution tools must not be
            // reachable from it (consistent with Telegram and Slack). The
            // separately authenticated builder collaboration bridge has its
            // own explicit profile; it is not an iOS policy precedent.
            // A bot session carries the tuple its gate accepted above; an
            // ordinary session binds nothing and the facade admits the
            // Mac-owned ios tuple as before.
            // The tuple travels as a PARAMETER: the facade binds it inside its
            // own producer task, for that producer's whole life. A synchronous
            // withValue around this call popped the task-local the moment it
            // returned, while the producer it had just spawned still read it
            // (swift_task_dealloc_specific — see chatStreamExecution).
            let execution = chatClient.chatStreamExecution(
                message: msg.text,
                sessionId: resolvedSessionID,
                // Signed metadata is evidence only. The facade
                // admits the Mac-owned ios tuple before append.
                model: acceptedBotContract?.model ?? "",
                reasoningEffort: acceptedBotContract?.reasoningEffort ?? "",
                fileAccess: chatFileAccess,
                attachments: coAttachments,
                persona: NativeAgentNotificationDefaults.agentDisplayName(dataRoot: PersistenceCore.defaultDataRoot()),
                surface: "ios",
                suppressUserAppend: suppressUserAppend,
                replacementAssistantMessageID: replacementAssistantMessageID,
                choice: acceptedBotContract?.choice,
                replyRoute: replyRoute
            )
            await withTaskCancellationHandler {
            do {
                for try await event in execution.events {
                    if Task.isCancelled { break }
                    switch event {
                    case .delta(let s):
                        if s.isEmpty { continue }
                        accumulated += s
                        if let flush = deltaCoalescer.push(
                            snapshot: accumulated,
                            nowUptimeNanoseconds: DispatchTime.now().uptimeNanoseconds
                        ) {
                            await sendICloudTextDelta(
                                flush,
                                sessionID: resolvedSessionID,
                                correlationID: msg.id,
                                replyTo: remoteMetadata["clientSurface"] ?? "iphone",
                                targetSourceKey: routeKey
                            )
                        }
                    case .final(let r):
                        // The final turn is authoritative. Earlier deltas may
                        // include pre-tool draft text that should not become
                        // the durable reply once tool-loop synthesis finishes.
                        // The phone saw her working as it streamed; the final
                        // reply is the answer without that commentary.
                        accumulated = ChatOrchestration.ChatResponse.answerOnly(
                            r.reply,
                            workingCommentaryCharacters: r.workingCommentaryCharacters
                        )
                        generatedAttachmentBox.set(Self.bridgeAttachments(
                            from: ChatGeneratedImageArtifacts.attachments(
                                from: r.toolDispatches,
                                dataRoot: PersistenceCore.defaultDataRoot()
                            )
                        ))
                    case .replyTextSettled:
                        break
                    case .notice(let noticeKind, let text):
                        // Notify-don't-hang (2026-06-09): in-turn status (invoke
                        // start/heartbeat/timeout). kind "progress" routes to the
                        // iOS streaming-hint line (receiveICloudProgress) — shown
                        // live, never part of the durable reply.
                        // 2026-09-06: a notice keeps its kind and its own KVS
                        // key. Published as an anonymous "progress" into the
                        // single latest-value progress key, a reconnect or
                        // compaction notice was overwritten by the next tool
                        // event before the phone could read it.
                        // It is ALSO mirrored to the old progress key as kind
                        // "progress" (the only kinds an older phone admits), or
                        // a phone that predates the new key would stop seeing
                        // notices at all. Both copies carry one message id, and
                        // an updated phone drops the one it already dispatched.
                        _ = await port.sendKVSChatProgress(
                            text: text,
                            sessionID: resolvedSessionID,
                            correlationID: msg.id,
                            metadata: [
                                "kind": "notice",
                                "noticeKind": noticeKind,
                                "transport": "icloud",
                                "source": "mac",
                                "replyTo": remoteMetadata["clientSurface"] ?? "iphone",
                                "targetSourceKey": routeKey
                            ],
                            key: NativeAgentICloudBridgeConstants.KVSKey.chatNoticeLatest,
                            mirrorKey: NativeAgentICloudBridgeConstants.KVSKey.chatProgressLatest
                        )
                    case .toolUse(let name, _):
                        // F7 P2: forward a lightweight tool_use progress event so
                        // iOS can render that a tool is firing. Payload is the
                        // tool name only — full input/output stays Mac-local.
                        toolEventCounter += 1
                        if let flush = deltaCoalescer.flush(nowUptimeNanoseconds: DispatchTime.now().uptimeNanoseconds) {
                            await sendICloudTextDelta(
                                flush,
                                sessionID: resolvedSessionID,
                                correlationID: msg.id,
                                replyTo: remoteMetadata["clientSurface"] ?? "iphone",
                                targetSourceKey: routeKey
                            )
                        }
                        let delivered = await port.sendKVSChatProgress(
                            text: name,
                            sessionID: resolvedSessionID,
                            correlationID: msg.id,
                            metadata: [
                                "kind": "tool_use",
                                "toolName": name,
                                "toolSeq": String(toolEventCounter),
                                "transport": "icloud",
                                "source": "mac",
                                "replyTo": remoteMetadata["clientSurface"] ?? "iphone",
                                "targetSourceKey": routeKey
                            ]
                        )
                        if !delivered {
                            NSLog("[iCloudBridge] failed tool_use KVS event msg=%@: %@", msg.id, name)
                        }
                    case .toolResult(let name, _):
                        toolEventCounter += 1
                        if let flush = deltaCoalescer.flush(nowUptimeNanoseconds: DispatchTime.now().uptimeNanoseconds) {
                            await sendICloudTextDelta(
                                flush,
                                sessionID: resolvedSessionID,
                                correlationID: msg.id,
                                replyTo: remoteMetadata["clientSurface"] ?? "iphone",
                                targetSourceKey: routeKey
                            )
                        }
                        let delivered = await port.sendKVSChatProgress(
                            text: name,
                            sessionID: resolvedSessionID,
                            correlationID: msg.id,
                            metadata: [
                                "kind": "tool_result",
                                "toolName": name,
                                "toolSeq": String(toolEventCounter),
                                "transport": "icloud",
                                "source": "mac",
                                "replyTo": remoteMetadata["clientSurface"] ?? "iphone",
                                "targetSourceKey": routeKey
                            ]
                        )
                        if !delivered {
                            NSLog("[iCloudBridge] failed tool_result KVS event msg=%@: %@", msg.id, name)
                        }
                    case .error(let m):
                        // F7 P1: surface stream errors explicitly. The previous
                        // path swallowed `.error` and shipped accumulated text
                        // as a normal final reply — iOS saw "success" with a
                        // half-finished bubble. Record the error here; the
                        // post-stream code writes a `kind: "error"` BridgeMessage
                        // instead of a final reply.
                        if let flush = deltaCoalescer.flush(nowUptimeNanoseconds: DispatchTime.now().uptimeNanoseconds) {
                            await sendICloudTextDelta(
                                flush,
                                sessionID: resolvedSessionID,
                                correlationID: msg.id,
                                replyTo: remoteMetadata["clientSurface"] ?? "iphone",
                                targetSourceKey: routeKey
                            )
                        }
                        sawError = m
                        NSLog("[iCloudBridge] chatStream error msg=%@: %@", msg.id, m)
                    }
                }
            } catch {
                if let flush = deltaCoalescer.flush(nowUptimeNanoseconds: DispatchTime.now().uptimeNanoseconds) {
                    await sendICloudTextDelta(
                        flush,
                        sessionID: resolvedSessionID,
                        correlationID: msg.id,
                        replyTo: remoteMetadata["clientSurface"] ?? "iphone",
                        targetSourceKey: routeKey
                    )
                }
                sawError = "\(error)"
                personError.withLock { $0 = ProviderRecoveryPolicy.personMessage(error) }
                NSLog("[iCloudBridge] forwardToSwiftRuntime: chatStream() failed for msg %@: %@", msg.id, "\(error)")
            }
            // Stream close can precede the producer's terminal transcript write.
            // Keep the phone's admission slot until that writer has joined.
            await execution.waitForProducerTermination()
            } onCancel: {
                execution.cancel()
            }
            return (accumulated, deltaCoalescer.sequence, sawError, toolEventCounter)
            }
            }
            } catch {
                personError.withLock { $0 = ProviderRecoveryPolicy.personMessage(error) }
                return ("", 0, error.localizedDescription, 0)
            }
        }
        // The run id is this turn's correlation id — the same one iOS holds
        // for the placeholder it is waiting on, so a Stop can name it.
        port.registerActiveChatTask(streamTask, for: resolvedSessionID, runID: msg.id)
        let outcome = await streamTask.value
        port.unregisterActiveChatTask(for: resolvedSessionID, expecting: streamTask)
        let wasCancelled = streamTask.isCancelled
        let outcomeAttachments = generatedAttachmentBox.value()

        if wasCancelled {
            // Cancellation: write a final reply tagged as cancelled so iOS
            // clears its placeholder and stops the typing indicator. Don't
            // ship accumulated text as a "real" reply.
            do {
                _ = try await port.sendChatMessage(
                    text: outcome.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                        ? "(cancelled)"
                        : outcome.text,
                    sessionID: resolvedSessionID,
                    correlationID: msg.id,
                    metadata: [
                        "kind": "cancelled",
                        "transport": "icloud",
                        "source": "mac",
                        "replyTo": remoteMetadata["clientSurface"] ?? "iphone",
                        "targetSourceKey": routeKey
                    ]
                )
                await port.sendICloudReplyPushNotification(
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
                NSLog("[iCloudBridge] failed to write cancel reply for msg %@: %@", msg.id, "\(error)")
                port.completed(sessionID: resolvedSessionID)
                return ICloudIncomingTurnConsumptionPolicy.shouldConsume(
                    turnReachedTerminalState: true,
                    replyPublished: false
                )
            }
        }

        if let errMsg = outcome.error {
            // F7 P1: stream errored. Send a kind=error BridgeMessage with the
            // description so iOS shows a banner instead of folding partial
            // text as a final reply.
            do {
                _ = try await port.sendChatMessage(
                    text: "NativeAgent hit an error answering that message.",
                    sessionID: resolvedSessionID,
                    correlationID: msg.id,
                    metadata: [
                        "kind": "error",
                        // 2026-09-13 (first-failure pass): the phone used to get
                        // the raw provider string here while the Mac's own
                        // transcript got a cause-and-recovery sentence. One
                        // failure, one explanation — normalized through the same
                        // function, naming the control this device shows.
                        // 2026-09-22: a typed provider failure sends its person sentence.
                        "errorDetail": String((personError.withLock { $0 } ?? ChatStreamErrorText.normalize(
                            Self.redactedRemoteErrorDetail(errMsg),
                            retryAction: "Retry"
                        )).prefix(400)),
                        "transport": "icloud",
                        "source": "mac",
                        "replyTo": remoteMetadata["clientSurface"] ?? "iphone",
                        "targetSourceKey": routeKey
                    ]
                )
                await port.sendICloudReplyPushNotification(
                    text: "NativeAgent hit an error answering that message.",
                    sessionID: resolvedSessionID,
                    correlationID: msg.id,
                    kind: "error"
                )
                port.completed(sessionID: resolvedSessionID)
                return true
            } catch {
                NSLog("[iCloudBridge] failed to write error reply for msg %@: %@", msg.id, "\(error)")
                port.completed(sessionID: resolvedSessionID)
                return ICloudIncomingTurnConsumptionPolicy.shouldConsume(
                    turnReachedTerminalState: true,
                    replyPublished: false
                )
            }
        }

        let replyText = outcome.text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !replyText.isEmpty || !outcomeAttachments.isEmpty else {
            NSLog("[iCloudBridge] forwardToSwiftRuntime: empty reply for msg %@", msg.id)
            return await writeErrorReply(
                "NativeAgent returned an empty reply. Check NativeAgent logs for that run.",
                sessionID: resolvedSessionID,
                turnReachedTerminalState: true
            )
        }

        do {
            _ = try await port.sendChatMessage(
                text: replyText,
                sessionID: resolvedSessionID,
                correlationID: msg.id,
                metadata: [
                    "transport": "icloud",
                    "source": "mac",
                    "replyTo": remoteMetadata["clientSurface"] ?? "iphone",
                    "targetSourceKey": routeKey
                ],
                attachments: outcomeAttachments
            )
            await port.sendICloudReplyPushNotification(
                // An image-only answer has no text to announce, and the request
                // builder rejects an empty body — which used to mean no
                // notification at all for exactly the reply worth walking back
                // for. Announce the artifact instead.
                text: replyText.isEmpty ? "Your image is ready" : replyText,
                sessionID: resolvedSessionID,
                correlationID: msg.id,
                kind: "reply"
            )
            port.completed(sessionID: resolvedSessionID)
            NSLog("[iCloudBridge] forwarded iOS msg %@ → Swift chatStream (session=%@) → wrote reply (%d chars, %d deltas, %d attachments)",
                  msg.id, resolvedSessionID, replyText.count, outcome.deltaSeq, outcomeAttachments.count)
            return true
        } catch {
            NSLog("[iCloudBridge] failed to write reply to Drive for msg %@: %@", msg.id, "\(error)")
            // The assistant turn is already durable in the Mac transcript.
            // Publish the snapshot and consume the one signed input; iOS's
            // transcript backstop can recover the reply without asking Agent
            // to execute the same turn again.
            port.completed(sessionID: resolvedSessionID)
            return ICloudIncomingTurnConsumptionPolicy.shouldConsume(
                turnReachedTerminalState: true,
                replyPublished: false
            )
        }
    }

    nonisolated private static func bridgeAttachments(
        from attachments: [ChatOrchestration.MultimodalAttachment]
    ) -> [NativeAgentShared.MultimodalAttachment] {
        attachments.compactMap { attachment in
            guard let withData = ChatGeneratedImageArtifacts.imageDataAttachment(from: attachment) else {
                return nil
            }
            return NativeAgentShared.MultimodalAttachment(
                id: withData.id,
                type: withData.type,
                base64: withData.base64,
                mime: withData.mime,
                name: withData.name,
                byteSize: withData.byteSize
            )
        }
    }

    private func sendICloudTextDelta(
        _ flush: ICloudTextDeltaFlush,
        sessionID: String,
        correlationID: String,
        replyTo: String,
        targetSourceKey: String
    ) async {
        do {
            _ = try await port.sendChatMessage(
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
        } catch {
            NSLog("[iCloudBridge] failed text_delta seq=%d msg=%@: %@", flush.sequence, correlationID, "\(error)")
        }
    }

    // fix2/F3: ensure `<dataRoot>/chat/sessions.json` has an entry for an
    // iOS-originated sessionId before we persist messages under it. Under
    // flock; idempotent (no-op when the id is already present).
    func ensureChatSessionIndex(sessionID: String, dataRoot root: URL) async throws {
        let sessionsPath = root
            .appendingPathComponent("chat", isDirectory: true)
            .appendingPathComponent("sessions.json")
        let nowISO = ISO8601DateFormatter().string(from: Date())
        let short = String(sessionID.prefix(8))
        let entry: [String: JSONValue] = [
            "id": .string(sessionID),
            "title": .string("iOS chat \(short)"),
            "createdAt": .string(nowISO),
            "updatedAt": .string(nowISO),
            "source": .string("ios"),
            "sourceKey": .string(NativeAgentICloudBridgeConstants.mobileSourceKey),
            "archived": .bool(false),
            "messageCount": .int(0),
        ]
        let persistence = SwiftNativePersistenceCore()
        let changed = try await persistence.withFileLock(sessionsPath) { () async throws -> Bool in
            let parent = sessionsPath.deletingLastPathComponent()
            try? FileManager.default.createDirectory(at: parent, withIntermediateDirectories: true)
            var sessions = try ChatSessionIndexFile.loadObjectRowsForMutation(at: sessionsPath)
            if let index = sessions.firstIndex(where: { row in
                guard case .string(let id)? = row["id"] else { return false }
                return id == sessionID
            }) {
                let existingSourceKey: String? = {
                    guard case .string(let value)? = sessions[index]["sourceKey"] else { return nil }
                    return value
                }()
                guard !NativeAgentICloudBridgeConstants.isMobileSourceKey(existingSourceKey) else {
                    return false
                }
                guard case .string(let existingSource)? = sessions[index]["source"],
                      existingSource.lowercased() == "ios",
                      (existingSourceKey ?? "").isEmpty else { return false }
                // Compatibility migration for sessions authored by older iOS
                // builds, which wrote only `source: ios`.
                sessions[index]["sourceKey"] = .string(NativeAgentICloudBridgeConstants.mobileSourceKey)
                let out = try ChatSessionIndexFile.serializedData(for: sessions)
                try out.write(to: sessionsPath, options: .atomic)
                return true
            }
            sessions.insert(entry, at: 0)
            let out = try ChatSessionIndexFile.serializedData(for: sessions)
            try out.write(to: sessionsPath, options: .atomic)
            ChatSessionRetention.enforceBestEffort(
                dataRoot: root,
                now: Date(),
                context: "AppDelegate.upsertMobileChatSessionRow"
            )
            return true
        }
        if changed {
            await MainActor.run {
                port.requestChatSnapshotPublication(includeTranscripts: false)
            }
        }
    }
}
