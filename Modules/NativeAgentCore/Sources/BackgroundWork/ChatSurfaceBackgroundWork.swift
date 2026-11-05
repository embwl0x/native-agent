import Foundation
import NativeAgentCore
import ChatTurnRuntime
import ChatTurnContracts
import TelegramBot
import ProviderRouting
import MemoryV2
import DeviceSync
import Experiences
import PersistenceCore
import ToolRegistry
// Blueprint: | `ChatSurfaceBackgroundWork.swift` | `ChatSurfaceBackgroundWork`, `makeTelegramChatHandler`, `fileSystemPermissionNotice`; chat delivery |

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
        let handler: TelegramProgressChatHandlerWithAttachments = { chatId, text, mediaAttachments, context in
            // Approval continuations stay in the interrupted turn's session.
            // Forum topics isolate sessions; absent topics address the whole chat.
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
                // Sends and approval prompts must return to the originating topic.
                threadId: destination.threadId.map(String.init),
                requesterUserId: context.fromUserId.map(String.init)
            )
            // Shared attachments keep document ingestion and Trust policy in Core.
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
            // Verified chat identity preserves allowlist checks when /new gives the session a bare UUID.
            let request = TurnRequest(
                message: effectiveText,
                sessionID: sessionId,
                // Freeze routing before branch selection and context assembly.
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
            let turn = request.turn(id: context.turn.id, parent: context.turn)
            // Serialize model turns across doors; release the session before Telegram delivery. A row saved before admission is consumed.
            let admitted = try await withChatTranscriptCompletionSignal(sessionID: sessionId, turnCompleted: turnCompleted) {
                try await TurnAdmission.shared.run(dataRoot: dataRoot, sessionID: sessionId,
                    arrival: request.arrival(context.suppressUserAppend ? .saved : .shown), turn: turn) { turn in
                    try await client.chat(message: request.message, sessionId: request.sessionID,
                        model: request.model, reasoningEffort: request.reasoningEffort,
                        fileAccess: request.fileAccess, attachments: request.attachments,
                        persona: request.persona, surface: request.surface,
                        suppressUserAppend: request.suppressUserAppend, turn: turn,
                        serviceTier: request.serviceTier ?? nil)
                }
            }
            // Final delivery must retain every word shown in the draft; a read arrival brings no words, the agent's turn's reply answers it.
            switch admitted {
            case .ran(let response): return (response.output, TelegramPollLoop.replyImagePaths(response), nil)
            case .steered(let steered): return ("", [], steered.turnID)
            }
        }
        return handler
    }

    public static let systemPermissionsSpeechCardId = "system-permissions-speech"

    /// The live grant owns clearance; each denied episode is told once through the same attention port as the other body notices.
    public static func fileSystemPermissionNotice(
        capability: String,
        dataRoot: URL,
        permissionStatus: @escaping @Sendable () -> SpeechPermissionSnapshot,
        assistanceCard: @escaping @Sendable (JSONValue) async throws -> AssistanceCardContent,
        notifications: any BackgroundWorkNotificationPort
    ) async {
        guard capability == "speechRecognition" else {
            nativeLog("SystemPermissionNotice: no remedy mapped for capability %@", capability)
            return
        }
        let liveStatus = permissionStatus()
        guard !liveStatus.isGranted else {
            await retireSystemPermissionCardIfGranted(dataRoot: dataRoot, permissionStatus: permissionStatus)
            return
        }
        do {
            let content = try await assistanceCard(.object([
                "kind": .string("speech"), "permission": .string(liveStatus.rawValue),
                "warningSummary": .string(liveStatus.warningSummary),
                "settingsLink": liveStatus.settingsLink.map(JSONValue.string) ?? .null
            ]))
            try await BodyNotice.tell(key: systemPermissionsSpeechCardId, from: "system_permissions",
                finding: liveStatus.rawValue, dataRoot: dataRoot) { id in
                guard !permissionStatus().isGranted else {
                    for matter in try await ForPerson.at(dataRoot).matters() where matter.face?.from == "system_permissions" {
                        try await BodyNotice.resolve(matter, dataRoot: dataRoot)
                    }
                    return
                }
                try await notifications.tell(Matter(id: id, form: .ask, from: "system_permissions",
                    title: content.title, summary: String(content.summary.prefix(500)), words: content.detail,
                    // The person's Trust page holds the Mac permissions; the System Settings deep link stays in the words.
                    open: "page:trust",
                    choices: [.init(id: "view", label: "View"), .init(id: "archive", label: "Archive"),
                              .init(id: "dismiss", label: "Dismiss")]),
                    dataRoot: dataRoot, reach: .person(from: nil), turn: nil)
            }
        } catch {
            nativeLog("SystemPermissionNotice: permission matter could not be told: %@", error.localizedDescription)
        }
    }

    /// Missing or refused grants leave the episode open; only a measured grant resolves it.
    public static func retireSystemPermissionCardIfGranted(
        dataRoot: URL,
        permissionStatus: @escaping @Sendable () -> SpeechPermissionSnapshot
    ) async {
        guard permissionStatus().isGranted else { return }
        do {
            try await BodyNotice.resolve(key: systemPermissionsSpeechCardId, from: "system_permissions", dataRoot: dataRoot)
        } catch {
            nativeLog("SystemPermissionNotice: permission matter could not be resolved: %@", error.localizedDescription)
        }
    }

}

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
