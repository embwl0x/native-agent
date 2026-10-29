import Foundation
import NativeAgentCore
import ChatTurnRuntime
import ChatTurnContracts
import TelegramBot
import ProviderRouting
import MemoryV2
import DeviceSync
import NotificationInbox
import PersistenceCore
import ToolRegistry
// Blueprint: | `ChatSurfaceBackgroundWork.swift` | `ChatSurfaceBackgroundWork` enum; `makeTelegramChatHandler`; `fileSystemPermissionNotice` passes native Speech Recognition facts to maintenance-assistance, retaining permission checks, retirement, sticky-status publication and delivery |

public enum ChatSurfaceBackgroundWork {
    private static func withChatTranscriptCompletionSignal<T>(
        sessionID: String,
        turnCompleted: @escaping @Sendable (String) -> Void,
        operation: () async throws -> T
    ) async rethrows -> T {
        defer { turnCompleted(sessionID) }
        return try await operation()
    }

    public static func makeTelegramChatHandler(
        dataRoot: URL,
        telegramSessions: TelegramSessionStore,
        client: SwiftNativeChatOrchestrationClient,
        turnCompleted: @escaping @Sendable (String) -> Void
    ) -> TelegramProgressChatHandlerWithAttachments {
        // Telegram images use the same MultimodalAttachment shape as Mac chat.
        let handler: TelegramProgressChatHandlerWithAttachments = { chatId, text, mediaAttachments, progress, context in
            // Approval continuations stay in the interrupted turn's session.
            // Forum topics key sessions by (chat, topic); nil topics retain chat-only keys.
            let destination = TelegramDestination(chatId: chatId, threadId: context.threadId)
            let sessionId: String
            if let pinnedSessionId = context.sessionId {
                sessionId = pinnedSessionId
            } else {
                sessionId = try await telegramSessions.activeSessionId(destination: destination)
            }
            var correctedTranscript = false
            if mediaAttachments.isEmpty, let reply = context.replyTo, let sender = context.fromUserId,
               let prefix = text.range(of: "Correction:", options: [.anchored, .caseInsensitive]) {
                let replacement = text[prefix.upperBound...].trimmingCharacters(in: .whitespacesAndNewlines)
                if !replacement.isEmpty {
                    correctedTranscript = try await client.correctSpeechTranscript(
                        sessionId: sessionId, reference: "telegram:\(chatId):\(sender):\(reply.messageId)", text: replacement)
                }
            }
            let effectiveText = correctedTranscript ? text : TelegramReplyPromptRenderer.messageWithReplyContext(
                text: text,
                replyTo: context.replyTo
            )
            let replyRoute = ChatToolSessionContext.ReplyRoute(
                surface: "telegram",
                destinationId: String(chatId),
                // The topic a tool-driven send or an approval prompt must
                // answer in. Nil keeps the historical whole-chat route.
                threadId: destination.threadId.map(String.init),
                requesterUserId: context.fromUserId.map(String.init)
            )
            // Downloaded Telegram files use the same attachment type as Mac
            // chat, so document ingestion and its Trust policy stay in Core.
            let chatAttachments: [MultimodalAttachment] = mediaAttachments.compactMap { media in
                guard let bytes = media.bytes, !bytes.isEmpty else { return nil }
                guard let resolved = media.chatTypeAndMime else { return nil }
                return ChatTurnRuntime.MultimodalAttachment(
                    type: resolved.type,
                    base64: bytes.base64EncodedString(),
                    mime: resolved.mime,
                    name: media.captureFilename,
                    byteSize: bytes.count,
                    utterance: media.utterance
                )
            }
            // Bind the verified Telegram chatId so the security gates resolve
            // allowlist trust even when the active session is a bare UUID
            // (post-/new), not the legacy `telegram:<chatId>` form. See
            // ChatToolSessionContext.
            let request = TurnRequest(
                message: effectiveText,
                sessionID: sessionId,
                // The facade freezes provider/model/effort/tier before branch
                // selection and context assembly.
                attachments: chatAttachments,
                persona: nil,
                surface: "telegram",
                suppressUserAppend: context.suppressUserAppend,
                verifiedSessionID: sessionId,
                verifiedChatID: String(chatId),
                verifiedUserID: context.fromUserId.map(String.init),
                replyRoute: replyRoute,
                pinnedRunID: context.runId
            )
            // Telegram's activity line reads an app call as the action it ran.
            let shown = ShownToolNames()
            // One turn at a time in this session across every door. Only the
            // model turn holds it; Telegram delivery runs after it is released.
            let response = try await withChatTranscriptCompletionSignal(sessionID: sessionId, turnCompleted: turnCompleted) {
                try await TurnAdmission.shared.run(sessionID: sessionId) {
                try await request.chat(
                    on: client,
                    progress: { event in
                        switch event {
                        case .toolUse(let name, let input):
                            let call = shown.use(name, input: input)
                            await progress(.toolUse(name: call.name, input: call.input))
                        case .toolResult(let name, let output):
                            await progress(.toolResult(name: shown.result(name).name, output: output))
                        case .notice(let kind, let text):
                            // invoke_claude start/heartbeat/timeout — surface on
                            // Telegram so the user sees live progress instead of a silent
                            // multi-minute hang. Carry `kind` so the bot throttles
                            // heartbeats but always delivers the terminal timeout.
                            let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
                            if !trimmed.isEmpty {
                                await progress(.notice(kind: kind, text: trimmed))
                            }
                        case .final, .error:
                            break
                        default:
                            await progress(event)
                        }
                    }
                )
                }
            }
            // The streamed draft showed her working; the settled message is the
            // answer, with the images she chose.
            return (ChatTurnRuntime.ChatResponse.answerOnly(
                response.output,
                workingCommentaryCharacters: response.workingCommentaryCharacters
            ), TelegramPollLoop.replyImagePaths(response))
        }
        return handler
    }

    /// Stable card id for the Speech Recognition permission notice. One id, so
    /// every subsequent denied voice note updates the SAME card instead of
    /// stacking a new row per message.
    public static let systemPermissionsSpeechCardId = "system-permissions-speech"

    /// Surface a headless TCC denial to the person who can grant it at the Mac.
    /// Upsert one actionable card and push only on insertion.
    /// Include the System Settings deep link and the in-app Speech Recognition route.
    public static func fileSystemPermissionNotice(
        capability: String,
        dataRoot: URL,
        permissionStatus: @escaping @Sendable () -> SpeechPermissionSnapshot,
        assistanceCard: @escaping @Sendable (JSONValue) async throws -> AssistanceCardContent,
        notify: @escaping @Sendable (URL, String, String, String, String, String) async -> Void
    ) async {
        guard capability == "speechRecognition" else {
            // Only the speech capability has a card today. An unrecognised
            // capability is dropped LOUDLY rather than filed under the speech
            // card id, which would put the wrong pane in front of the user.
            FileHandle.standardError.write(Data(
                "SystemPermissionNotice: no card mapped for capability \(capability)\n".utf8))
            return
        }
        // Read the LIVE status (non-prompting) so the card states what is
        // actually true now, not what the failing turn assumed.
        let liveStatus = permissionStatus()
        guard !liveStatus.isGranted else {
            // The grant landed between the failed turn and this write (e.g. the
            // launch preflight resolved it). Do not file a card that is already
            // false — and clear any card a previous denial left behind.
            await retireSystemPermissionCardIfGranted(
                dataRoot: dataRoot,
                permissionStatus: permissionStatus
            )
            return
        }
        let settingsLink = liveStatus.settingsLink
        let now = ISO8601DateFormatter().string(from: Date())
        let content: AssistanceCardContent
        do {
            content = try await assistanceCard(.object([
                "kind": .string("speech"), "permission": .string(liveStatus.rawValue),
                "warningSummary": .string(liveStatus.warningSummary),
                "settingsLink": settingsLink.map(JSONValue.string) ?? .null
            ]))
        } catch {
            FileHandle.standardError.write(Data("SystemPermissionNotice: assistance part unavailable: \(error)\n".utf8))
            return
        }
        let card: JSONValue = .object([
            "id": .string(systemPermissionsSpeechCardId),
            "created_at": .string(now),
            "source": .string("system_permissions"),
            "severity": .string("actionable"),
            "title": .string(content.title),
            "summary": .string(String(content.summary.prefix(500))),
            "detail": .string(content.detail),
            "related_mission_id": .null,
            "related_approval_id": .null,
            "related_paths": .array(settingsLink.map { [.string($0)] } ?? []),
            "related_groups": .array([]),
            // No "act" entry on purpose: the inbox act-router has no
            // system_permissions case, so an Act button here would fall through
            // to the generic chat-draft path — a button that looks like a fix
            // and is not. The levers above are real; a fake one is worse than
            // none. (See report: wiring a true one-click Act needs a case in
            // InboxCardActions.resolvePrimaryAction.)
            "actions": .array([
                .object(["id": .string("view"), "label": .string("View"),
                         "description": .string("See how to grant Speech Recognition")]),
                .object(["id": .string("archive"), "label": .string("Archive"),
                         "description": .string("Archive this card")]),
                .object(["id": .string("dismiss"), "label": .string("Dismiss"),
                         "description": .string("Dismiss this card")]),
            ]),
            "status": .string("unread"),
            "read_at": .null,
        ])
        // Preserve disposition while the permission detail is unchanged.
        do {
            let inserted = try await LiveNotificationInbox.live(dataRoot: dataRoot)
                .upsert(id: systemPermissionsSpeechCardId) { existing in
                    var replacement = card
                    if case .object(let obj)? = existing,
                       case .object(var newObj) = card,
                       case .string(let newDetail)? = newObj["detail"],
                       case .string(let oldDetail)? = obj["detail"],
                       newDetail == oldDetail {
                        newObj["status"] = obj["status"] ?? .string("unread")
                        newObj["read_at"] = obj["read_at"] ?? .null
                        replacement = .object(newObj)
                    }
                    return (replacement, existing == nil)
                }
            if inserted {
                await notify(
                    dataRoot,
                    systemPermissionsSpeechCardId,
                    content.title,
                    String(content.summary.prefix(500)),
                    "system_permissions",
                    "actionable"
                )
            }
        } catch {
            FileHandle.standardError.write(Data(
                "SystemPermissionNotice: card upsert failed: \(error)\n".utf8))
        }
    }

    /// Archives the Speech Recognition card once the grant actually lands.
    ///
    /// Without this the card is immortal: filing skips when granted, but a card
    /// filed while denied has nothing that ever clears it, so a user who fixes
    /// the permission keeps an actionable "not approved" row forever — an alert
    /// that outlives its own condition. Safe to call on every launch; it is a
    /// no-op when the grant is missing, when there is no card, or when the user
    /// already archived/dismissed it.
    public static func retireSystemPermissionCardIfGranted(
        dataRoot: URL,
        permissionStatus: @escaping @Sendable () -> SpeechPermissionSnapshot
    ) async {
        guard permissionStatus().isGranted else { return }
        let now = ISO8601DateFormatter().string(from: Date())
        do {
            try await LiveNotificationInbox.live(dataRoot: dataRoot)
                .archiveActive(ids: [systemPermissionsSpeechCardId], readAt: now)
        } catch {
            FileHandle.standardError.write(Data(
                "SystemPermissionNotice: card retire failed: \(error)\n".utf8))
        }
    }

}

/// Non-prompting platform observation used by the canonical permission-card writer.
public struct SpeechPermissionSnapshot: Sendable {
    public let rawValue: String
    public let isGranted: Bool
    public let warningSummary: String
    public let settingsLink: String?

    public init(rawValue: String, isGranted: Bool, warningSummary: String, settingsLink: String?) {
        self.rawValue = rawValue
        self.isGranted = isGranted
        self.warningSummary = warningSummary
        self.settingsLink = settingsLink
    }
}
