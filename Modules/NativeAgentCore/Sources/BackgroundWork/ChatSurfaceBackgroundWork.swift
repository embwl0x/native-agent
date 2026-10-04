import Foundation
import NativeAgentCore
import ChatOrchestration
import TelegramBot
import ProviderRouting
import MemoryV2
import DeviceSync
import NotificationInbox
import PersistenceCore
import ToolRegistry

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
        // chat-smoothness phase 5: lock-guarded incremental→accumulated text
        // bridge for the Telegram growing draft (the progress closure is
        // @Sendable; deltas arrive on the chat engine's executor).
        final class TelegramDeltaAccumulator: @unchecked Sendable {
            private let lock = NSLock()
            private var text = ""
            func append(_ chunk: String) -> String {
                lock.lock(); defer { lock.unlock() }
                text += chunk
                return text
            }
        }
        // telegram-vision-in: attachment-aware handler. `attachments` carry
        // already-downloaded inbound images (TelegramMediaAttachment.bytes set);
        // convert each to ChatOrchestration's MultimodalAttachment — the SAME
        // {type:"image", base64, mime, byteSize} shape the Mac UI builds in
        // ChatView.swift — so the vision pass works for whichever provider/model
        // the telegram surface resolves to.
        let handler: TelegramProgressChatHandlerWithAttachments = { chatId, text, mediaAttachments, progress, context in
            // chat-smoothness phase 5: chat deltas arrive INCREMENTAL; the
            // bot's growing draft wants accumulated text-so-far. One
            // accumulator per turn (this closure runs once per turn).
            let deltaAccumulator = TelegramDeltaAccumulator()
            // Telegram uses the canonical surface profile. Its evolution
            // backend is present so trusted Full Mac YOLO can read
            // `evolution_status`; propose/install retain their ordinary
            // TrustCenter and approval floors.
            // 2026-09-06: an approval continuation names the session its
            // interrupted turn ran in. Honour it — resolving the chat's active
            // binding here put the replayed tool result into whatever session
            // a /new or /resume had bound in the meantime.
            // 2026-09-06: a Telegram forum topic is its own conversation, so
            // the session is keyed on (chat, topic). `context.threadId` is nil
            // for a DM, an ordinary group, and a forum's General topic — all of
            // which keep the chat-only key they already have on disk.
            let destination = TelegramDestination(chatId: chatId, threadId: context.threadId)
            let sessionId: String
            if let pinnedSessionId = context.sessionId {
                sessionId = pinnedSessionId
            } else {
                sessionId = try await telegramSessions.activeSessionId(destination: destination)
            }
            let persona = (try? await telegramSessions.persona(destination: destination))
                ?? NativeAgentNotificationDefaults.agentDisplayName(dataRoot: dataRoot)
            let effectiveText = TelegramReplyPromptRenderer.messageWithReplyContext(
                text: text,
                replyTo: context.replyTo
            )
            let replyRoute = ChatToolSessionContext.ReplyRoute(
                surface: "telegram",
                destinationId: String(chatId),
                // The topic a tool-driven send or an approval prompt must
                // answer in. Nil keeps the historical whole-chat route.
                threadId: destination.threadId.map(String.init)
            )
            // Convert downloaded Telegram images into the Mac-path attachment
            // shape. Mirrors ChatView.swift's MultimodalAttachment(type:"image",
            // base64:, mime:, byteSize:) exactly so the existing vision path
            // consumes them with no special-casing.
            // Qualify as ChatOrchestration.MultimodalAttachment: an unqualified
            // `MultimodalAttachment` resolves to NativeAgentShared's same-named
            // type, which `client.chat` does NOT accept (mirrors NativeClient's
            // explicit qualification at its chat call site).
            let chatAttachments: [ChatOrchestration.MultimodalAttachment] = mediaAttachments.compactMap { media in
                guard let bytes = media.bytes, !bytes.isEmpty else { return nil }
                return ChatOrchestration.MultimodalAttachment(
                    type: "image",
                    base64: bytes.base64EncodedString(),
                    mime: media.mimeType ?? "image/jpeg",
                    name: media.captureFilename,
                    byteSize: bytes.count
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
                persona: persona,
                surface: "telegram",
                suppressUserAppend: context.suppressUserAppend,
                verifiedSessionID: sessionId,
                verifiedChatID: String(chatId),
                verifiedUserID: context.fromUserId.map(String.init),
                replyRoute: replyRoute
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
                        case .replyTextSettled(let settled):
                            await progress(.replyTextSettled(settled))
                        case .toolUse(let name, let input):
                            let call = shown.use(name, input: input)
                            await progress(.toolUse(name: call.name, input: call.input))
                        case .toolResult(let name, let output):
                            await progress(.toolResult(name: shown.result(name), output: output))
                        case .notice(let kind, let text):
                            // invoke_claude start/heartbeat/timeout — surface on
                            // Telegram so the user sees live progress instead of a silent
                            // multi-minute hang. Carry `kind` so the bot throttles
                            // heartbeats but always delivers the terminal timeout.
                            // (2026-06-09 — completes notify-don't-hang on Telegram.)
                            let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
                            if !trimmed.isEmpty {
                                await progress(.notice(kind: kind, text: trimmed))
                            }
                        case .delta(let chunk):
                            // chat-smoothness phase 5: forward text-so-far to
                            // the bot's growing-draft streamer (it throttles
                            // the actual Telegram edits to ~2s).
                            await progress(.textDelta(accumulated: deltaAccumulator.append(chunk)))
                        case .final, .error:
                            break
                        }
                    }
                )
                }
            }
            // The streamed draft showed her working; the settled message is the answer.
            return ChatOrchestration.ChatResponse.answerOnly(
                response.output,
                workingCommentaryCharacters: response.workingCommentaryCharacters
            )
        }
        return handler
    }

    /// Stable card id for the Speech Recognition permission notice. One id, so
    /// every subsequent denied voice note updates the SAME card instead of
    /// stacking a new row per message.
    public static let systemPermissionsSpeechCardId = "system-permissions-speech"

    /// PATCH-2026-08-18: surface a headless TCC denial to the human at the Mac.
    ///
    /// The Telegram sender already gets a chat notice; this is the other half —
    /// the person who can actually flip the switch is not in the chat. Mirrors
    /// the established `fileDiskHygieneNotice` shape
    /// (BackgroundLoopsAssembly+Maintenance.swift:205): stable id, upsert,
    /// severity "actionable", then push only when the row is newly inserted.
    ///
    /// The card carries the real route rather than a bare Dismiss: the exact
    /// System Settings deep link in `related_paths`, and the in-app row
    /// (Mac Integration → System Permissions → Speech Recognition) named in the
    /// detail. See the report note about the one-click Act button.
    public static func fileSystemPermissionNotice(
        capability: String,
        dataRoot: URL,
        permissionStatus: @escaping @Sendable () -> SpeechPermissionSnapshot,
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
        let summary = liveStatus.warningSummary
        let settingsLink = liveStatus.settingsLink
        let now = ISO8601DateFormatter().string(from: Date())
        let detail = """
        A Telegram voice note could not be transcribed because macOS \
        Speech Recognition is not approved for NativeAgent (current state: \
        \(liveStatus.rawValue)).

        \(summary)

        Two ways to fix it:
        • In NativeAgent: Mac Integration → System Permissions → Speech Recognition → Grant.
        • In macOS: open System Settings → Privacy & Security → Speech Recognition \
        and switch NativeAgent on.\
        \(settingsLink.map { "\n\nDirect link: \($0)" } ?? "")

        Until then, inbound voice notes will keep replying with the permission notice \
        instead of a transcript.
        """
        let card: JSONValue = .object([
            "id": .string(systemPermissionsSpeechCardId),
            "created_at": .string(now),
            "source": .string("system_permissions"),
            "severity": .string("actionable"),
            "title": .string("Speech Recognition is not approved"),
            "summary": .string(String(summary.prefix(500))),
            "detail": .string(detail),
            "related_mission_id": .null,
            "related_approval_id": .null,
            "related_paths": .array(settingsLink.map { [.string($0)] } ?? []),
            "related_groups": .array([]),
            // No "act" entry on purpose: the inbox act-router has no
            // system_permissions case, so an Act button here would fall through
            // to the generic chat-draft path — a button that looks like a fix
            // and is not. The levers above are real; a fake one is worse than
            // none. (See report: wiring a true one-click Act needs a case in
            // NativeClient+ExportWorkshopInbox.resolveInboxPrimaryAction.)
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
        // Sticky-status upsert, mirroring upsertDiskHygieneCard. A plain
        // LiveNotificationInbox.upsert replaces the whole row — including
        // status: "unread" — so a card the user already archived or dismissed
        // would be resurrected by the very next denied voice note. Since the
        // underlying condition persists until someone flips a System Settings
        // switch, that is a guaranteed nag loop. Preserve the user's disposition
        // whenever the detail text is unchanged; a CHANGED detail (the status
        // moved notDetermined -> denied) is genuinely new information and does
        // re-surface the card.
        let inboxPath = dataRoot
            .appendingPathComponent("notifications", isDirectory: true)
            .appendingPathComponent("inbox.jsonl")
        let persistence = SwiftNativePersistenceCore()
        do {
            let inserted = try await persistence.withFileLock(inboxPath) { () async throws -> Bool in
                let lines = try InboxRewriteGuard.readLines(inboxPath)
                guard InboxRewriteGuard.rewriteIsSafe(lines: lines, path: inboxPath) else {
                    InboxRewriteGuard.refuse("SystemPermissionNotice", path: inboxPath)
                    return false
                }
                var mutated: [Data] = []
                mutated.reserveCapacity(lines.count + 1)
                var found = false
                for line in lines {
                    guard case .object(let obj)? = line.row,
                          case .string(let id)? = obj["id"],
                          id == systemPermissionsSpeechCardId else {
                        // Other rows AND undecodable lines: verbatim.
                        mutated.append(line.raw)
                        continue
                    }
                    var replacement = card
                    if case .object(var newObj) = card,
                       case .string(let newDetail)? = newObj["detail"],
                       case .string(let oldDetail)? = obj["detail"],
                       newDetail == oldDetail {
                        newObj["status"] = obj["status"] ?? .string("unread")
                        newObj["read_at"] = obj["read_at"] ?? .null
                        replacement = .object(newObj)
                    }
                    mutated.append(Data(try replacement.serialize(pretty: false).utf8))
                    found = true
                }
                if !found { mutated.append(Data(try card.serialize(pretty: false).utf8)) }
                try InboxRewriteGuard.writeLines(mutated, to: inboxPath)
                return !found
            }
            if inserted {
                await notify(
                    dataRoot,
                    systemPermissionsSpeechCardId,
                    "Speech Recognition is not approved",
                    String(summary.prefix(500)),
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
        let inboxPath = dataRoot
            .appendingPathComponent("notifications", isDirectory: true)
            .appendingPathComponent("inbox.jsonl")
        let persistence = SwiftNativePersistenceCore()
        let now = ISO8601DateFormatter().string(from: Date())
        do {
            try await persistence.withFileLock(inboxPath) { () async throws -> Void in
                let lines = try InboxRewriteGuard.readLines(inboxPath)
                guard !lines.isEmpty else { return }
                guard InboxRewriteGuard.rewriteIsSafe(lines: lines, path: inboxPath) else {
                    InboxRewriteGuard.refuse("SystemPermissionNotice", path: inboxPath)
                    return
                }
                var changed = false
                var mutated: [Data] = []
                mutated.reserveCapacity(lines.count)
                for line in lines {
                    guard case .object(var obj)? = line.row,
                          case .string(let id)? = obj["id"],
                          id == systemPermissionsSpeechCardId else {
                        mutated.append(line.raw)
                        continue
                    }
                    let status: String
                    if case .string(let raw)? = obj["status"] {
                        status = raw.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
                    } else {
                        status = "unread"
                    }
                    if status == "archived" || status == "dismissed" {
                        mutated.append(line.raw)
                        continue
                    }
                    obj["status"] = .string("archived")
                    obj["read_at"] = .string(now)
                    mutated.append(Data(try JSONValue.object(obj).serialize(pretty: false).utf8))
                    changed = true
                }
                if changed { try InboxRewriteGuard.writeLines(mutated, to: inboxPath) }
            }
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
