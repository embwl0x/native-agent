import Foundation
import NativeAgentShared
import NativeAgentCore
import ChatOrchestration
import PersistenceCore

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

extension AppDelegate {
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
    @MainActor
    static func forwardToSwiftRuntime(_ msg: BridgeMessage) async -> Bool {
        let remoteMetadata = msg.metadata ?? [:]
        let sourceKey = remoteMetadata["sourceKey"] ?? "app"
        let routeKey = remoteMetadata["routeKey"] ?? remoteMetadata["deviceSourceKey"] ?? sourceKey
        func writeErrorReply(_ text: String, sessionID: String?) async -> Bool {
            do {
                _ = try await iCloudBridge.shared.sendChatMessage(
                    text: text,
                    sessionID: sessionID,
                    correlationID: msg.id,
                    metadata: [
                        "kind": "error",
                        "errorDetail": String(text.prefix(400)),
                        "transport": "icloud",
                        "source": "mac",
                        "replyTo": remoteMetadata["clientSurface"] ?? "iphone",
                        "targetSourceKey": routeKey
                    ]
                )
                await Self.sendICloudReplyPushNotification(
                    text: text,
                    sessionID: sessionID,
                    correlationID: msg.id,
                    kind: "error"
                )
                NotificationCenter.default.post(name: .chatTurnCompleted, object: sessionID)
                return true
            } catch {
                NSLog("[iCloudBridge] failed to write error reply for msg %@: %@", msg.id, "\(error)")
                return false
            }
        }
        func writeProgress(_ text: String, stage: String, sessionID: String) async {
            let delivered = await iCloudBridge.shared.sendKVSChatProgress(
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

        // Swift-native cutover/fix2-ios-chat (2026-06-02): the daemon's
        // /v1/chat/stream route is dead — every iCloud-forwarded turn used to
        // silently no-reply on iPhone. Route the turn straight through the
        // in-process SwiftNative ChatOrchestration client instead.
        await writeProgress("Mac received it", stage: "received", sessionID: resolvedSessionID)
        // Live profile name (Agent), not the chatPersona style quick-switch —
        // storedChatAgentDisplayName renders the "NativeAgent" fallback there.
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
        let metaFileAccess = remoteMetadata["fileAccess"]?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        let replacementAssistantMessageID = ICloudChatReplacementIntent
            .decode(remoteMetadata)?.assistantMessageID
        let suppressUserAppend = replacementAssistantMessageID != nil
        let chatFileAccess = metaFileAccess.isEmpty ? "auto" : metaFileAccess

        // F7 P0 #3: cancellable stream task. We run the stream consumer in a
        // child Task and register it with MacSyncEngine by sessionID so the
        // iOS "cancelChat" inbox action can `.cancel()` it (in addition to
        // the cancelled.flag the streaming chat path also polls).
        let generatedAttachmentBox = ICloudGeneratedAttachmentBox()
        let replyRoute = ChatToolSessionContext.ReplyRoute(
            surface: "ios",
            sourceKey: routeKey,
            replyTo: remoteMetadata["clientSurface"] ?? "iphone",
            correlationId: msg.id
        )
        let chatClient = Self.residentIOSChatClient
        let streamTask = Task.detached(priority: .userInitiated) { () -> (text: String, deltaSeq: Int, error: String?, toolEvents: Int) in
            var accumulated = ""
            var sawError: String? = nil
            var toolEventCounter = 0
            var deltaCoalescer = ICloudTextDeltaCoalescer()

            // U4 Wave D (gpt-5.5 review-2 BLOCKER): iCloud/iOS streaming is a
            // REMOTE paired-user surface — self-evolution tools must not be
            // reachable from it (consistent with Telegram and Slack). The
            // separately authenticated builder collaboration bridge has its
            // own explicit profile; it is not an iOS policy precedent.
            let stream = ChatToolSessionContext.$replyRoute.withValue(replyRoute) {
                chatClient.chatStream(
                    message: msg.text,
                    sessionId: resolvedSessionID,
                    // Signed metadata is evidence only. The facade
                    // admits the Mac-owned ios tuple before append.
                    model: "",
                    reasoningEffort: "",
                    fileAccess: chatFileAccess,
                    attachments: coAttachments,
                    persona: NativeAgentNotificationDefaults.agentDisplayName(dataRoot: NativeAgentPaths.dataRoot),
                    surface: "ios",
                    suppressUserAppend: suppressUserAppend,
                    replacementAssistantMessageID: replacementAssistantMessageID
                )
            }
            do {
                for try await event in stream {
                    if Task.isCancelled { break }
                    switch event {
                    case .delta(let s):
                        if s.isEmpty { continue }
                        accumulated += s
                        if let flush = deltaCoalescer.push(
                            snapshot: accumulated,
                            nowUptimeNanoseconds: DispatchTime.now().uptimeNanoseconds
                        ) {
                            await Self.sendICloudTextDelta(
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
                        accumulated = r.reply
                        generatedAttachmentBox.set(Self.bridgeAttachments(
                            from: ChatGeneratedImageArtifacts.attachments(
                                from: r.toolDispatches,
                                dataRoot: NativeAgentPaths.dataRoot
                            )
                        ))
                    case .notice(_, let text):
                        // Notify-don't-hang (2026-06-09): in-turn status (invoke
                        // start/heartbeat/timeout). kind "progress" routes to the
                        // iOS streaming-hint line (receiveICloudProgress) — shown
                        // live, never part of the durable reply.
                        _ = await iCloudBridge.shared.sendKVSChatProgress(
                            text: text,
                            sessionID: resolvedSessionID,
                            correlationID: msg.id,
                            metadata: [
                                "kind": "progress",
                                "transport": "icloud",
                                "source": "mac",
                                "replyTo": remoteMetadata["clientSurface"] ?? "iphone",
                                "targetSourceKey": routeKey
                            ]
                        )
                    case .toolUse(let name, _):
                        // F7 P2: forward a lightweight tool_use progress event so
                        // iOS can render that a tool is firing. Payload is the
                        // tool name only — full input/output stays Mac-local.
                        toolEventCounter += 1
                        if let flush = deltaCoalescer.flush(nowUptimeNanoseconds: DispatchTime.now().uptimeNanoseconds) {
                            await Self.sendICloudTextDelta(
                                flush,
                                sessionID: resolvedSessionID,
                                correlationID: msg.id,
                                replyTo: remoteMetadata["clientSurface"] ?? "iphone",
                                targetSourceKey: routeKey
                            )
                        }
                        let delivered = await iCloudBridge.shared.sendKVSChatProgress(
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
                            await Self.sendICloudTextDelta(
                                flush,
                                sessionID: resolvedSessionID,
                                correlationID: msg.id,
                                replyTo: remoteMetadata["clientSurface"] ?? "iphone",
                                targetSourceKey: routeKey
                            )
                        }
                        let delivered = await iCloudBridge.shared.sendKVSChatProgress(
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
                            await Self.sendICloudTextDelta(
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
                    await Self.sendICloudTextDelta(
                        flush,
                        sessionID: resolvedSessionID,
                        correlationID: msg.id,
                        replyTo: remoteMetadata["clientSurface"] ?? "iphone",
                        targetSourceKey: routeKey
                    )
                }
                sawError = "\(error)"
                NSLog("[iCloudBridge] forwardToSwiftRuntime: chatStream() failed for msg %@: %@", msg.id, "\(error)")
            }
            return (accumulated, deltaCoalescer.sequence, sawError, toolEventCounter)
        }
        MacSyncEngine.shared.registerActiveChatTask(streamTask, for: resolvedSessionID)
        let outcome = await streamTask.value
        MacSyncEngine.shared.unregisterActiveChatTask(for: resolvedSessionID, expecting: streamTask)
        let wasCancelled = streamTask.isCancelled
        let outcomeAttachments = generatedAttachmentBox.value()

        if wasCancelled {
            // Cancellation: write a final reply tagged as cancelled so iOS
            // clears its placeholder and stops the typing indicator. Don't
            // ship accumulated text as a "real" reply.
            do {
                _ = try await iCloudBridge.shared.sendChatMessage(
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
                await Self.sendICloudReplyPushNotification(
                    text: outcome.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                        ? "NativeAgent cancelled that reply."
                        : outcome.text,
                    sessionID: resolvedSessionID,
                    correlationID: msg.id,
                    kind: "cancelled"
                )
                NotificationCenter.default.post(name: .chatTurnCompleted, object: resolvedSessionID)
                return true
            } catch {
                NSLog("[iCloudBridge] failed to write cancel reply for msg %@: %@", msg.id, "\(error)")
                return false
            }
        }

        if let errMsg = outcome.error {
            // F7 P1: stream errored. Send a kind=error BridgeMessage with the
            // description so iOS shows a banner instead of folding partial
            // text as a final reply.
            do {
                _ = try await iCloudBridge.shared.sendChatMessage(
                    text: "NativeAgent hit an error answering that message.",
                    sessionID: resolvedSessionID,
                    correlationID: msg.id,
                    metadata: [
                        "kind": "error",
                        "errorDetail": String(errMsg.prefix(400)),
                        "transport": "icloud",
                        "source": "mac",
                        "replyTo": remoteMetadata["clientSurface"] ?? "iphone",
                        "targetSourceKey": routeKey
                    ]
                )
                await Self.sendICloudReplyPushNotification(
                    text: "NativeAgent hit an error answering that message.",
                    sessionID: resolvedSessionID,
                    correlationID: msg.id,
                    kind: "error"
                )
                NotificationCenter.default.post(name: .chatTurnCompleted, object: resolvedSessionID)
                return true
            } catch {
                NSLog("[iCloudBridge] failed to write error reply for msg %@: %@", msg.id, "\(error)")
                return false
            }
        }

        let replyText = outcome.text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !replyText.isEmpty || !outcomeAttachments.isEmpty else {
            NSLog("[iCloudBridge] forwardToSwiftRuntime: empty reply for msg %@", msg.id)
            return await writeErrorReply("NativeAgent returned an empty reply. Check NativeAgent logs for that run.", sessionID: resolvedSessionID)
        }

        do {
            _ = try await iCloudBridge.shared.sendChatMessage(
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
            await Self.sendICloudReplyPushNotification(
                text: replyText,
                sessionID: resolvedSessionID,
                correlationID: msg.id,
                kind: "reply"
            )
            NotificationCenter.default.post(name: .chatTurnCompleted, object: resolvedSessionID)
            NSLog("[iCloudBridge] forwarded iOS msg %@ → Swift chatStream (session=%@) → wrote reply (%d chars, %d deltas, %d attachments)",
                  msg.id, resolvedSessionID, replyText.count, outcome.deltaSeq, outcomeAttachments.count)
            return true
        } catch {
            NSLog("[iCloudBridge] failed to write reply to Drive for msg %@: %@", msg.id, "\(error)")
            return false
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

    @discardableResult
    static func sendICloudReplyPushNotification(
        text: String,
        sessionID: String?,
        correlationID: String,
        kind: String
    ) async -> Bool {
        let cleanText = NativeAppSecretRedactor.redactText(
            String(text.trimmingCharacters(in: .whitespacesAndNewlines).prefix(500))
        )
        guard !cleanText.isEmpty else { return false }
        var userInfo: [String: String] = [
            "screen": "chat",
            "source": "icloud_chat_reply",
            "correlationId": correlationID,
            "kind": kind,
        ]
        let eventID = NativeAgentDeviceEventIdentity.notification(userInfo: userInfo)
        userInfo["eventId"] = eventID
        await MacSyncMobileNotificationRelay.beginDeliveryPrediction(
            eventID: eventID,
            source: "icloud_chat_reply"
        )
        if let sessionID,
           !sessionID.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            userInfo["sessionId"] = sessionID
        }
        let result = await SwiftNativeAPNSSender.shared.sendNotification(
            title: NativeAgentNotificationDefaults.agentDisplayName(),
            body: cleanText,
            userInfo: userInfo,
            urgency: kind == "error" ? "urgent" : nil
        )
        if result.receipts.contains(where: \.isSuccess) {
            NSLog("[iCloudBridge] APNS chat reply notification accepted correlation=%@", correlationID)
            return true
        } else if !result.errors.isEmpty {
            await MacSyncMobileNotificationRelay.failDeliveryPrediction(
                eventID: eventID,
                source: "icloud_chat_reply"
            )
            NSLog("[iCloudBridge] APNS chat reply notification failed correlation=%@: %@",
                  correlationID, result.errors.joined(separator: " | "))
        }
        return false
    }

    private static func sendICloudTextDelta(
        _ flush: ICloudTextDeltaFlush,
        sessionID: String,
        correlationID: String,
        replyTo: String,
        targetSourceKey: String
    ) async {
        do {
            _ = try await iCloudBridge.shared.sendChatMessage(
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
    static func ensureChatSessionIndex(sessionID: String, dataRoot root: URL) async throws {
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
            "archived": .bool(false),
            "messageCount": .int(0),
        ]
        let persistence = SwiftNativePersistenceCore()
        try await persistence.withFileLock(sessionsPath) {
            let parent = sessionsPath.deletingLastPathComponent()
            try? FileManager.default.createDirectory(at: parent, withIntermediateDirectories: true)
            var sessions = try ChatSessionIndexFile.loadObjectRowsForMutation(at: sessionsPath)
            let alreadyPresent = sessions.contains { row in
                guard case .string(let id)? = row["id"] else { return false }
                return id == sessionID
            }
            if alreadyPresent { return }
            sessions.insert(entry, at: 0)
            let out = try ChatSessionIndexFile.serializedData(for: sessions)
            try out.write(to: sessionsPath, options: .atomic)
            _ = try? ChatSessionRetention.enforce(dataRoot: root, now: Date())
        }
    }
}
