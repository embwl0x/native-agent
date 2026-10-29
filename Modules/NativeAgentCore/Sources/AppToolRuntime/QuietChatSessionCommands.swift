import ChatTurnRuntime
import ChatTurnContracts
import ChatToolRuntime
import ChatSessionWork
import ChatToolParsing
import Foundation
import NativeAgentCore
import NativeAgentShared
import PersistenceCore
import Transcripts

// Blueprint: | `QuietChatSessionCommands.swift` | `QuietChatSessionCommands`: effect-free session fences, session operations and queued-turn receipts through canonical turn owners |

@MainActor
public protocol QuietChatTranscriptPort: MacChatSessionStore {
    associatedtype Message: MacChatRetryMessage, ChatTurnFailureMessage, Sendable
    func messages(for sessionId: String) -> [Message]
    func structureVersion(for sessionId: String) -> UInt64
    func setMessages(_ messages: [Message], for sessionId: String)
    func loadMessages(sessionId: String, cached: Bool) async throws -> [Message]
    func listArchived() async throws -> [NativeAgentShared.ChatSession]
}

@MainActor
public protocol QuietChatSessionCommandPort: MacChatTurnPresentationPort {
    associatedtype Transcript: QuietChatTranscriptPort
    var chatCommandTranscripts: Transcript { get }
    var chatSessionTransactions: MacChatSessionTransactions { get }
    var dataRootOverride: URL? { get }
    var chatModel: String { get }
    var chatProvider: String { get }
    var statusForAgent: String { get }
    var otherRunningChatSessionIDs: [String] { get }
    var quietPinnedChatSessionIDs: [String] { get }
    func selectChatSession(_ row: NativeAgentShared.ChatSession) async
    func renameChatSession(id: String, title: String) async
    func pinChatSessionForDetachedWindow(_ sessionId: String)
    func unpinQuietChatSession(_ sessionId: String) -> Bool?
    func clearQuietChatMessages(sessionId: String) async -> (succeeded: Bool, agentMessage: String)
    func archiveQuietChat(sessionId: String) async -> (succeeded: Bool, agentMessage: String)
    func compactQuietChat(sessionId: String, model: String?, providerID: String?, force: Bool) async throws -> ChatSessionCompactionOutcome
    func exportQuietChat(session: NativeAgentShared.ChatSession?, sessionId: String, messages: [Transcript.Message]) async throws -> ChatExportResult
    func publishChatSnapshot()
    func quietChatIsDetached(_ sessionId: String) -> Bool
    func openQuietChatWindow(sessionId: String)
    func closeQuietChatWindow(sessionId: String)
    func isQuietSyntheticNotice(_ message: Transcript.Message) -> Bool
    func regenerateAssistantMessage(_ message: Transcript.Message) async
}

/// Session intake and receipts share the turn runtime, without selecting a
/// conversation or retaining a second lifecycle. The calling conversation
/// cannot interrupt or wait on itself.
public enum QuietChatSessionCommands {

    /// Agent sends keep their provenance and never move the owner conversation anchor.
    public static let agentOrigin = ChatMessageOrigin(surface: "app", agent: "self", authored: .agent)

    @MainActor
    public static func run<Host: QuietChatSessionCommandPort>(
        verb: String, input: [String: JSONValue], reachesUser: Bool, appModel: Host
    ) async -> JSONValue {
        let session: ChatSessionRef
        switch fence(verb: verb, input: input, reachesUser: reachesUser, appModel: appModel) {
        case .failure(let refusal): return refusal.json
        case .success(let found?): session = found
        case .success(nil):
            if verb == "new" { return await newChat(title: text(input["title"]), appModel: appModel) }
            if verb == "list" { return await list(input, appModel: appModel) }
            return stopOthers(calling: text(input["__session_id"]), his: reachesUser, appModel: appModel)
        }
        switch verb {
        case "show":
            let changed = appModel.activeChatSessionId != session.id
            await appModel.selectChatSession(session.row)
            guard appModel.activeChatSessionId == session.id else {
                return failure("show_failed", "The window did not switch: \(appModel.statusForAgent)", session, effects: "unknown")
            }
            return ok(session, changed: changed, "\(session.title) is now the conversation the chat page shows.")
        case "rename":
            let title = text(input["title"])
            guard !title.isEmpty else { return failure("missing_title", "Pass the new name in title.", session) }
            await appModel.renameChatSession(id: session.id, title: title)
            let now = appModel.chatCommandTranscripts.sessions.first { $0.id == session.id }
            guard let now, now.title == title else { return failure("rename_failed", "Renaming \(session.id) was not verified. \(appModel.statusForAgent)", session, effects: "unknown") }
            return ok(ChatSessionRef(row: now), changed: session.title != title, "Renamed from \(session.title) to \(title).")
        case "pin":
            let was = appModel.quietPinnedChatSessionIDs.contains(session.id)
            appModel.pinChatSessionForDetachedWindow(session.id)
            guard appModel.quietPinnedChatSessionIDs.contains(session.id) else {
                return failure("pin_failed", "Saving the pinned tab was not verified.", session, effects: "unknown")
            }
            return ok(session, changed: !was, "\(session.title) is pinned as a tab.")
        case "unpin":
            switch appModel.unpinQuietChatSession(session.id) {
            case true?:
                return ok(session, changed: true, "\(session.title) is no longer a pinned tab.")
            case false?:
                return ok(session, changed: false, "\(session.title) was not pinned.")
            case nil:
                return failure("unpin_failed", "Closing the pinned tab was not verified.", session, effects: "unknown")
            }
        case "clear":
            let result = await appModel.clearQuietChatMessages(sessionId: session.id)
            guard result.succeeded else { return failure("clear_failed", result.agentMessage, session, effects: "unknown") }
            HarnessDecidedRow.post(requester: "Full Mac", tool: "chat.clear \(session.id)",
                                   sessionID: input["__session_id"]?.scalarText,
                                   dataRoot: appModel.dataRootOverride ?? PersistenceCore.defaultDataRoot())
            return ok(session, changed: true, "Every message in \(session.title) is gone for good.")
        case "archive":
            let result = await appModel.archiveQuietChat(sessionId: session.id)
            guard result.succeeded else { return failure("archive_failed", result.agentMessage, session, effects: "unknown") }
            return ok(session, changed: true, "\(session.title) is archived.")
        case "stop":
            guard isRunning(session.id, appModel) else {
                return ok(session, changed: false, "\(session.title) has no reply running.")
            }
            appModel.stopChatStream(sessionId: session.id)
            return ok(session, changed: true, "Stopped the reply in \(session.title). Its send-next queue is paused, as Stop leaves it.")
        case "regenerate":
            return await regenerate(session, appModel: appModel)
        case "queue":
            return queue(session, input: input, appModel: appModel)
        case "compact_now":
            do {
                let outcome = try await appModel.compactQuietChat(
                    sessionId: session.id, model: appModel.chatModel,
                    providerID: appModel.chatProvider, force: true
                )
                if let failure = compactionFailure(outcome) {
                    return self.failure("compact_failed", failure, session, effects: "unknown")
                }
                let runtime = appModel.macChatTurns
                let generation = runtime.taskGenerations[session.id]
                let version = appModel.chatCommandTranscripts.structureVersion(for: session.id)
                let lifecycle = runtime.lifecycle(for: session.id)
                if !runtime.busySessions.contains(session.id),
                   !runtime.streamingSessions.contains(session.id), runtime.tasks[session.id] == nil,
                   let messages = try? await appModel.chatCommandTranscripts.loadMessages(sessionId: session.id, cached: true) {
                    if !runtime.busySessions.contains(session.id),
                       !runtime.streamingSessions.contains(session.id), runtime.tasks[session.id] == nil,
                       runtime.taskGenerations[session.id] == generation,
                       runtime.lifecycle(for: session.id) == lifecycle,
                       appModel.chatCommandTranscripts.structureVersion(for: session.id) == version {
                        appModel.chatCommandTranscripts.setMessages(messages, for: session.id)
                    }
                }
                return ok(session, changed: true, "Older messages in \(session.title) are compacted into a summary.")
            } catch {
                if error is ToolFailureError { return ChatToolOutcome.failure(error: error) }
                return failure("compact_failed", "Compaction failed: \(error.localizedDescription)", session, effects: "unknown")
            }
        case "export":
            do {
                let messages = try await appModel.chatCommandTranscripts.loadMessages(sessionId: session.id, cached: true)
                let result = try await appModel.exportQuietChat(session: session.row, sessionId: session.id, messages: messages)
                let message = result.unavailableImages.isEmpty
                    ? "Exported \(session.title) as Markdown."
                    : "Exported \(session.title) as Markdown; some images were unavailable: \(result.unavailableImages.joined(separator: "; "))."
                var body = ok(session, changed: true, message)
                if case .object(var fields) = body {
                    fields["path"] = .string(result.url.path)
                    fields["unavailable_images"] = .array(result.unavailableImages.map { .string($0) })
                    body = .object(fields)
                }
                return body
            } catch {
                return AppToolExecutor.ownedFailure(error, code: "chat_export_failed", owner: "conversation \(session.id)",
                    instruction: "Read this conversation and resolve the export error before exporting another copy.",
                    next: ["page": .string("chat"), "item": .string(session.id)], effects: .unknown)
            }
        case "detach":
            appModel.openQuietChatWindow(sessionId: session.id)
            guard appModel.quietChatIsDetached(session.id) else {
                return failure("detach_failed", "Its window did not open; the conversation list may still be loading. Try again in a moment.", session, effects: "unknown")
            }
            return ok(session, changed: true, "\(session.title) is open in its own window.")
        case "close_window":
            let was = appModel.quietChatIsDetached(session.id)
            appModel.closeQuietChatWindow(sessionId: session.id)
            return ok(session, changed: was, was ? "Closed the window of \(session.title)." : "\(session.title) had no window of its own.")
        default:
            return AppToolExecutor.failure("unknown_verb", "No chat_session verb is called that.")
        }
    }

    /// Preview and execution use the same effect-free owner/session fences.
    @MainActor
    public static func fence<Host: QuietChatSessionCommandPort>(
        verb: String, input: [String: JSONValue], reachesUser: Bool, appModel: Host
    ) -> Result<ChatSessionRef?, Refusal> {
        if ["new", "list"].contains(verb) || (verb == "stop" && text(input["session_id"]).lowercased() == "others") {
            return .success(nil)
        }
        let session: ChatSessionRef
        switch resolve(text(input["session_id"]), appModel: appModel) {
        case .success(let found): session = found
        case .failure where verb == "compact_now":
            let id = text(input["session_id"])
            guard NativeAgentChatSessionID.normalizedPathComponent(id) == id,
                  FileManager.default.fileExists(atPath: (appModel.dataRootOverride ?? PersistenceCore.defaultDataRoot())
                    .appendingPathComponent("chat/messages/\(id).jsonl").path) else {
                return .failure(Refusal(json: AppToolExecutor.failure("missing_transcript", "Pass the exact session_id of the retained recollection.")))
            }
            session = ChatSessionRef(row: ChatSessionRow(id: id, title: id, createdAt: ""))
        case .failure(let refusal): return .failure(refusal)
        }
        if !reachesUser, ["show", "detach", "close_window"].contains(verb) {
            return .failure(Refusal(json: failure(
                "owners_screen",
                "\(verb) moves the person's screen, and they did not start this turn. Ask them first, "
                + "or tell them where it is (\(session.title), session_id \(session.id)) and let them open it.",
                session
            )))
        }
        let queued = text(input["action"]).lowercased()
        let interruptsReply = verb == "queue" && ["steer", "send_next"].contains(queued)
            && !text(input["turn_id"]).isEmpty && isRunning(session.id, appModel)
        if !reachesUser, (["stop", "archive", "regenerate", "clear"].contains(verb) || interruptsReply), userIsIn(session.id, appModel) {
            return .failure(Refusal(json: failure(
                "owner_is_in_it",
                "The person is in \(session.title) (on screen or in its own window), and they did not start this turn. "
                + "Ask them first, or leave it to them.",
                session
            )))
        }
        guard session.id == text(input["__session_id"]) else { return .success(session) }
        if ["stop", "archive", "regenerate", "clear"].contains(verb) {
            return .failure(Refusal(json: ownTurn(verb, session)))
        }
        if verb == "queue", ["steer", "send_next"].contains(queued), isRunning(session.id, appModel) {
            return .failure(Refusal(json: ownTurn(queued, session)))
        }
        return .success(session)
    }

    /// Archived rows are read only when requested; listing changes nothing.
    @MainActor
    private static func list<Host: QuietChatSessionCommandPort>(_ input: [String: JSONValue], appModel: Host) async -> JSONValue {
        let archived = input["archived"]?.scalarText?.lowercased() == "true"
        let pinned = Set(appModel.quietPinnedChatSessionIDs)
        let pinnedOnly: Bool? = if case .bool(let value)? = input["pinned"] { value } else { nil }
        var rows = appModel.chatCommandTranscripts.sessions
        if archived {
            do { rows = try await appModel.chatCommandTranscripts.listArchived() } catch {
                return AppToolExecutor.failure("list_failed", "The conversation list didn't read (\(error.localizedDescription)). Try again.")
            }
        }
        let query = input["query"]?.scalarText?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        rows = rows.filter { ($0.archived == true) == archived && (pinnedOnly == nil || pinned.contains($0.id) == pinnedOnly)
            && (query.isEmpty || BridgeRoutingPrefix.stripping($0.title).localizedCaseInsensitiveContains(query)) }
            .sorted { ($0.updatedAt ?? $0.createdAt) > ($1.updatedAt ?? $1.createdAt) }
        let offset = min(rows.count, max(0, input["offset"]?.scalarText.flatMap { Int($0) } ?? 0))
        let page = rows.dropFirst(offset).prefix(20)
        let next = offset + page.count
        return .object([
            "status": .string("ok"),
            "conversations": .array(page.map { row in .object([
                "session_id": .string(row.id), "title": .string(BridgeRoutingPrefix.stripping(row.title)),
                "last_active": .string(row.updatedAt ?? row.createdAt),
                "message_count": row.messageCount.map { .int(Int64($0)) } ?? .null,
                "created_at": .string(row.createdAt),
                "first_message_at": row.firstMessageAt.map(JSONValue.string) ?? .null,
                "last_message_at": row.lastMessageAt.map(JSONValue.string) ?? .null,
                "pinned": .bool(pinned.contains(row.id)), "running": .bool(isRunning(row.id, appModel)),
                "archived": .bool(row.archived == true),
            ]) }),
            "offset": .int(Int64(offset)), "total": .int(Int64(rows.count)),
            "next_offset": next < rows.count ? .int(Int64(next)) : .null,
            "note": .string("Message count is the indexed transcript count, which can shrink after compaction. Message times are conversational message stamps; null means not recorded. created_at is session creation and last_active is index activity, not message time."),
        ])
    }

    /// Creating a conversation leaves the selected conversation on screen.
    @MainActor
    private static func newChat<Host: QuietChatSessionCommandPort>(title: String, appModel: Host) async -> JSONValue {
        let row: ChatSessionRow
        do {
            row = try await appModel.chatSessionTransactions.create(store: appModel.chatCommandTranscripts,
                                                                  title: title.isEmpty ? "New Chat" : title)
            appModel.chatCommandTranscripts.setMessages([], for: row.id)
        } catch {
            return AppToolExecutor.failure("new_failed", "New chat failed: \(error.localizedDescription)", extra: ["effects": .string("unknown")])
        }
        appModel.publishChatSnapshot()
        let session = ChatSessionRef(row: row)
        return ok(session, changed: true, "Started \(session.title), not shown: the person's screen stays where it is.")
    }

    @MainActor
    public static func userIsIn<Host: QuietChatSessionCommandPort>(_ sessionId: String, _ appModel: Host) -> Bool {
        sessionId == appModel.activeChatSessionId || appModel.quietChatIsDetached(sessionId)
    }

    @MainActor
    private static func stopOthers<Host: QuietChatSessionCommandPort>(calling: String, his: Bool, appModel: Host) -> JSONValue {
        let others = appModel.otherRunningChatSessionIDs.filter {
            $0 != calling && (his || !appModel.quietChatIsDetached($0))
        }
        for id in others { appModel.stopChatStream(sessionId: id) }
        return .object([
            "status": .string("ok"),
            "changed": .bool(!others.isEmpty),
            "stopped": .array(others.map { .string($0) }),
            "detail": .string(others.isEmpty
                ? "No other conversation had a reply running."
                : "Stopped \(others.count) running repl\(others.count == 1 ? "y" : "ies"), as Stop Others does. "
                    + (his ? "Yours and the one on screen were left alone."
                        : "Yours, the one on screen and any in its own window were left alone.")),
        ])
    }

    @MainActor
    private static func regenerate<Host: QuietChatSessionCommandPort>(_ session: ChatSessionRef, appModel: Host) async -> JSONValue {
        if isRunning(session.id, appModel) {
            return failure("still_running", "\(session.title) is still replying. Stop it first (verb stop), or wait.", session)
        }
        var messages = appModel.chatCommandTranscripts.messages(for: session.id)
        if messages.isEmpty,
           let loaded = try? await appModel.chatCommandTranscripts.loadMessages(sessionId: session.id, cached: true) {
            appModel.chatCommandTranscripts.setMessages(loaded, for: session.id)
            messages = loaded
        }
        guard let last = messages.last(where: { $0.role == "assistant" }) else {
            return failure("nothing_to_regenerate", "\(session.title) has no reply to regenerate yet.", session)
        }
        if last.metadata?.providerRefusal == true {
            return failure("provider_refusal", "That reply was the provider refusing; Try again would not re-run it. "
                + "Pick another model (chat.model) and send the question again.", session)
        }
        guard let snapshot = MacChatRetrySnapshot.capture(
            target: last, messages: messages, sessionId: session.id,
            isSyntheticNotice: appModel.isQuietSyntheticNotice(last)
        ) else {
            return failure("not_retryable", "The last reply in \(session.title) is not one Try again can re-run.", session)
        }
        // Agent regeneration cannot answer the owner's real-action replay confirmation.
        if let gate = ChatTurnFailure.retryNeedsConfirmation(for: last, in: messages) {
            return failure("needs_confirmation", gate.line(model: nil) + " "
                + "Ask the person before starting it over, or send a message that continues from where it stopped.",
                session)
        }
        if snapshot.inputHadAttachments {
            return failure("needs_attachment", "The question behind that reply had a file, and saved rows keep only its summary. "
                + "Send the question again with the file attached (chat.send with attachments).", session)
        }
        // Regeneration must not inherit the asking turn's route or envelope.
        Task.detached { [appModel, last] in await appModel.regenerateAssistantMessage(last) }
        return ok(session, changed: true, "Regenerating the last reply in \(session.title); the new one replaces it there when done.")
    }

    @MainActor
    private static func queue<Host: QuietChatSessionCommandPort>(
        _ session: ChatSessionRef, input: [String: JSONValue], appModel: Host
    ) -> JSONValue {
        let turns = appModel.macChatTurns
        let action = text(input["action"]).lowercased()
        let turnId = text(input["turn_id"])
        let busy = isRunning(session.id, appModel)
        func listing(_ detail: String, changed: Bool) -> JSONValue {
            var body: [String: JSONValue] = [
                "status": .string("ok"), "changed": .bool(changed),
                "session_id": .string(session.id), "title": .string(session.title),
                "busy": .bool(busy), "queue_paused": .bool(turns.pausedQueueSessions.contains(session.id)),
                "queued": .array(queuedRows(session.id, appModel)), "detail": .string(detail),
            ]
            if let reason = queuePauseReason(session.id, appModel) { body["queue_paused_reason"] = .string(reason) }
            return .object(body)
        }
        switch action {
        case "", "list":
            return listing("The send-next queue of \(session.title).", changed: false)
        case "steer", "send_next":
            if turnId.isEmpty {
                guard action == "send_next" else {
                    return failure("missing_turn_id", "Pass turn_id; verb queue lists them.", session)
                }
                appModel.resumeQueuedChatTurns(sessionId: session.id)
                return listing("The queue of \(session.title) is running again.", changed: true)
            }
            guard (turns.queuedBySession[session.id] ?? []).contains(where: { $0.id == turnId }) else {
                return failure("unknown_turn", "No queued turn \(turnId) in \(session.title); verb queue lists them.", session)
            }
            if busy {
                appModel.sendQueuedChatTurnNow(turnId, sessionId: session.id)
                return listing("Stopped the reply in progress; \(turnId) runs next.", changed: true)
            }
            appModel.resumeQueuedChatTurns(sessionId: session.id, startingWith: turnId)
            return listing("\(turnId) is running now.", changed: true)
        case "remove":
            guard (turns.queuedBySession[session.id] ?? []).contains(where: { $0.id == turnId }) else {
                return failure("unknown_turn", "No queued turn \(turnId.isEmpty ? "named" : turnId) in \(session.title); verb queue lists them.", session)
            }
            appModel.removeQueuedChatTurn(turnId, sessionId: session.id)
            return listing("Removed \(turnId) from the queue.", changed: true)
        default:
            return failure("unknown_action", "action is list, steer, send_next or remove.", session)
        }
    }

    @MainActor
    public static func queuedRows<Host: QuietChatSessionCommandPort>(_ sessionId: String, _ appModel: Host) -> [JSONValue] {
        (appModel.macChatTurns.queuedBySession[sessionId] ?? []).filter(\.shouldDisplayInSendNextQueue).map { turn in
            var row: [String: JSONValue] = [
                "turn_id": .string(turn.id),
                "preview": .string(turn.preview),
                "attachments": .int(Int64(turn.attachments.count)),
                "from": .string(turn.origin == nil ? "owner" : "you"),
            ]
            if let reason = turn.stoppedReason { row["status"] = .string("stopped"); row["reason"] = .string(reason) }
            return .object(row)
        }
    }

    @MainActor
    public static func isRunning<Host: QuietChatSessionCommandPort>(_ sessionId: String, _ appModel: Host) -> Bool {
        !sessionId.isEmpty && appModel.macChatTurns.lifecycleBySession[sessionId]?.replyTextSettled != true
            && (appModel.macChatTurns.busySessions.contains(sessionId) || appModel.macChatTurns.streamingSessions.contains(sessionId))
    }

    @MainActor
    public static func queuePauseReason<Host: QuietChatSessionCommandPort>(_ sessionId: String, _ appModel: Host) -> String? {
        guard appModel.macChatTurns.pausedQueueSessions.contains(sessionId),
              let reason = appModel.macChatTurns.queuePauseReasons[sessionId]?.trimmingCharacters(in: .whitespacesAndNewlines),
              !reason.isEmpty else { return nil }
        return reason
    }

    public struct ChatSessionRef {
        public let row: ChatSessionRow
        public var id: String { row.id }
        public var title: String { BridgeRoutingPrefix.stripping(row.title) }
    }
    public typealias ChatSessionRow = NativeAgentShared.ChatSession

    public struct Refusal: Error {
        public let json: JSONValue
    }

    /// An id, an exact title, or nothing: "this chat" is the conversation the
    /// request came from (bridge, phone, Telegram), else the one on screen.
    @MainActor
    public static func resolve<Host: QuietChatSessionCommandPort>(_ raw: String, appModel: Host) -> Result<ChatSessionRef, Refusal> {
        let sessions = appModel.chatCommandTranscripts.sessions
        let asking = ChatToolSessionContext.verifiedSessionId.flatMap { id in sessions.contains { $0.id == id } ? id : nil }
        let wanted = raw.isEmpty ? (asking ?? appModel.activeChatSessionId) : raw
        guard !wanted.isEmpty else {
            return .failure(Refusal(json: AppToolExecutor.failure(
                "no_conversation", "No conversation is on screen. Pass session_id; chat.list lists them."
            )))
        }
        if let row = sessions.first(where: { $0.id == wanted }) { return .success(ChatSessionRef(row: row)) }
        let titled = sessions.filter {
            $0.archived != true && $0.title.compare(wanted, options: .caseInsensitive) == .orderedSame
        }
        if titled.count == 1 { return .success(ChatSessionRef(row: titled[0])) }
        return .failure(Refusal(json: AppToolExecutor.failure(
            titled.isEmpty ? "unknown_session" : "ambiguous_title",
            titled.isEmpty
                ? "No open conversation has that id or title. chat.list lists them with their ids."
                : "\(titled.count) conversations share that title; pass the session_id instead (chat.list lists them).",
            extra: ["requested": .string(raw)]
        )))
    }

    private static func compactionFailure(_ result: ChatSessionCompactionOutcome) -> String? {
        guard !result.compacted, result.summaryRowId == nil else { return nil }
        let detail = result.reason.trimmingCharacters(in: .whitespacesAndNewlines)
        return detail.isEmpty
            ? "Context compaction did not run. Try again after the next context refresh."
            : "Context compaction did not run: \(detail)"
    }

    private static func ok(_ session: ChatSessionRef, changed: Bool, _ detail: String) -> JSONValue {
        .object([
            "status": .string("ok"),
            "changed": .bool(changed),
            "session_id": .string(session.id),
            "title": .string(session.title),
            "detail": .string(detail),
            "note": .string("Done in process through the same action the person's control takes; no click was synthesized."),
        ])
    }

    private static func failure(_ reason: String, _ detail: String, _ session: ChatSessionRef, effects: String = "none") -> JSONValue {
        var extra: [String: JSONValue] = ["session_id": .string(session.id), "title": .string(session.title), "effects": .string(effects)]
        if effects == "unknown" {
            extra["remedy"] = Repair.reconcile(
                instruction: "Read this conversation's current state and resolve the reported cause before another change.",
                nextCall: .object(["tool": .string("app"), "input": .object(["page": .string("chat"), "item": .string(session.id)])]))
        }
        return AppToolExecutor.failure(reason, detail, extra: extra)
    }

    private static func ownTurn(_ verb: String, _ session: ChatSessionRef) -> JSONValue {
        failure(
            "own_conversation",
            "\(session.title) is the conversation you are replying in, and \(verb) there would cut off or wait on "
            + "this very turn. Finish this reply instead; the verb works on your other conversations.",
            session
        )
    }

    private static func text(_ value: JSONValue?) -> String {
        guard case .string(let raw)? = value else { return "" }
        return raw.trimmingCharacters(in: .whitespacesAndNewlines)
    }
}
