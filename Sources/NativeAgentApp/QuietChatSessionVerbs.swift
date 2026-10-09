import AppToolRuntime
import ChatOrchestration
import Foundation
import NativeAgentCore
import NativeAgentShared
import PersistenceCore

/// `chat_session`: the agent working her chat conversations the way User does
/// from the sidebar, the composer and the queue strip, in process. Each verb
/// calls the AppModel / store action the visible control calls; nothing here
/// keeps state of its own. Core has already admitted the call (posture gate);
/// wiping a conversation (clear) is User's below Full Mac, and the door refuses
/// it there.
///
/// The conversation the asking turn runs in is fenced from the verbs that
/// would end or rewrite that same turn (stop, archive, regenerate, clear, steer):
/// those would cut her off mid-reply, or wait on the turn that is waiting on
/// them.
///
/// She never takes User's screen or disturbs a conversation he is in unless
/// the turn reaches him (`AppToolExecutor.reachesUser`): `new` creates without
/// switching; show, detach and close_window, and stop/archive/regenerate on
/// the chat on screen or in its own window, need it.
enum QuietChatSessionVerbs {

    /// What the agent's own sends are stamped with, on the user row and on any
    /// queued turn: not User at this Mac. The badge reads "Automated", the
    /// conversation anchor is never moved by it, and `AnchorReplyMirror` skips
    /// a reply whose ask carries an origin.
    static let agentOrigin = ChatMessageOrigin(surface: "app", agent: "self", authored: .agent)

    @MainActor
    static func run(
        verb: String, input: [String: JSONValue], reachesUser: Bool, appModel: AppModel
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
                return failure("show_failed", "The window did not switch: \(appModel.statusForAgent)", session)
            }
            return ok(session, changed: changed, "\(session.title) is now the conversation the chat page shows.")
        case "rename":
            let title = text(input["title"])
            guard !title.isEmpty else { return failure("missing_title", "Pass the new name in title.", session) }
            await appModel.renameChatSession(id: session.id, title: title)
            let now = appModel.engine.transcripts.sessions.first { $0.id == session.id }
            guard let now, now.title == title else { return failure("rename_failed", appModel.statusForAgent, session) }
            return ok(ChatSessionRef(row: now), changed: session.title != title, "Renamed from \(session.title) to \(title).")
        case "pin":
            let was = MacPinnedChatSessionStore.load().contains(session.id)
            appModel.pinChatSessionForDetachedWindow(session.id)
            guard MacPinnedChatSessionStore.load().contains(session.id) else {
                return failure("pin_failed", "Pinned tabs could not be saved; nothing changed.", session)
            }
            return ok(session, changed: !was, "\(session.title) is pinned as a tab.")
        case "unpin":
            switch ChatSidebarRowUnpinTransaction.execute(sessionID: session.id) {
            case .unpinned(let encoded):
                ChatPinnedSnapshotPublication.request(encodedPinnedIDs: encoded) { _ in
                    NativeAgentEngine.liveDeviceSync.engine.requestChatSnapshotPublication(includeTranscripts: false)
                }
                return ok(session, changed: true, "\(session.title) is no longer a pinned tab.")
            case .refusedAlreadyUnpinned:
                return ok(session, changed: false, "\(session.title) was not pinned.")
            case .refusedInvalidSessionID, .failed:
                return failure("unpin_failed", "The pinned tab could not be closed; it stays pinned.", session)
            }
        case "clear":
            // /clear's own call, on the conversation named.
            let result = await appModel.clearActiveChatMessages(sessionId: session.id)
            guard result.succeeded else { return failure("clear_failed", result.agentMessage, session) }
            HarnessDecidedRow.post(requester: "Full Mac", tool: "chat.clear \(session.id)",
                                   sessionID: AppToolExecutor.inputString(input["__session_id"]),
                                   dataRoot: appModel.dataRootOverride ?? PersistenceCore.defaultDataRoot())
            return ok(session, changed: true, "Every message in \(session.title) is gone for good.")
        case "archive":
            let result = await appModel.archiveActiveChat(sessionId: session.id)
            guard result.succeeded else { return failure("archive_failed", result.agentMessage, session) }
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
                let outcome = try await appModel.compactSession(
                    sessionId: session.id, model: appModel.chatModel,
                    providerID: appModel.chatProvider, force: true
                )
                if let failure = ContextFillCompactionPresentation.failureMessage(for: outcome) {
                    return self.failure("compact_failed", failure, session)
                }
                if !appModel.engine.turns.streamingSessions.contains(session.id),
                   let messages = try? await appModel.engine.transcripts.loadMessages(sessionId: session.id, cached: true) {
                    appModel.engine.transcripts.setMessages(messages, for: session.id)
                }
                return ok(session, changed: true, "Older messages in \(session.title) are compacted into a summary.")
            } catch {
                return failure("compact_failed", "Compaction failed: \(error.localizedDescription)", session)
            }
        case "export":
            do {
                let messages = try await appModel.engine.transcripts.loadMessages(sessionId: session.id, cached: true)
                let file = try ChatExportService.export(session: session.row, sessionId: session.id, messages: messages)
                var body = ok(session, changed: true, "Exported \(session.title) as Markdown.")
                if case .object(var fields) = body { fields["path"] = .string(file.path); body = .object(fields) }
                return body
            } catch {
                return failure("export_failed", "Export failed: \(error.localizedDescription)", session)
            }
        case "detach":
            DetachedChatWindowController.shared.open(sessionId: session.id)
            guard DetachedChatWindowController.shared.isDetached(session.id) else {
                return failure("detach_failed", "Its window did not open; the conversation list may still be loading. Try again in a moment.", session)
            }
            return ok(session, changed: true, "\(session.title) is open in its own window.")
        case "close_window":
            let was = DetachedChatWindowController.shared.isDetached(session.id)
            DetachedChatWindowController.shared.close(sessionId: session.id)
            return ok(session, changed: was, was ? "Closed the window of \(session.title)." : "\(session.title) had no window of its own.")
        default:
            return AppToolExecutor.failure("unknown_verb", "No chat_session verb is called that.")
        }
    }

    /// Every check that refuses a verb before anything is touched: a
    /// conversation that does not resolve, User's screen, a conversation he is
    /// in, and the one she is replying in. Reads only, so the door's preview
    /// asks it too and refuses what the real call would; `run` asks it first.
    /// Nil for the verbs with no conversation of their own (new, list, stop
    /// others).
    @MainActor
    static func fence(
        verb: String, input: [String: JSONValue], reachesUser: Bool, appModel: AppModel
    ) -> Result<ChatSessionRef?, Refusal> {
        if ["new", "list"].contains(verb) || (verb == "stop" && text(input["session_id"]).lowercased() == "others") {
            return .success(nil)
        }
        let session: ChatSessionRef
        switch resolve(text(input["session_id"]), appModel: appModel) {
        case .success(let found): session = found
        case .failure(let refusal): return .failure(refusal)
        }
        if !reachesUser, ["show", "detach", "close_window"].contains(verb) {
            return .failure(Refusal(json: failure(
                "users_screen",
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
                "user_is_in_it",
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

    // MARK: - Verbs with more to them

    /// The sidebar's conversations, newest first, twenty at a time: what
    /// chat.list and the chat page read show (it folds chat_conversations'
    /// list). Archived ones, from the archive tier, only when asked. Changes nothing.
    @MainActor
    private static func list(_ input: [String: JSONValue], appModel: AppModel) async -> JSONValue {
        let archived = AppToolExecutor.inputString(input["archived"])?.lowercased() == "true"
        let pinned = Set(MacPinnedChatSessionStore.load())
        let pinnedOnly: Bool? = if case .bool(let value)? = input["pinned"] { value } else { nil }
        var rows = appModel.engine.transcripts.sessions
        if archived {
            do { rows = try await appModel.engine.transcripts.listArchived() } catch {
                return AppToolExecutor.failure("list_failed", "The conversation list didn't read (\(error.localizedDescription)). Try again.")
            }
        }
        let query = AppToolExecutor.inputString(input["query"])?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        rows = rows.filter { ($0.archived == true) == archived && (pinnedOnly == nil || pinned.contains($0.id) == pinnedOnly)
            && (query.isEmpty || BridgeRoutingPrefix.stripping($0.title).localizedCaseInsensitiveContains(query)) }
            .sorted { ($0.updatedAt ?? $0.createdAt) > ($1.updatedAt ?? $1.createdAt) }
        let offset = min(rows.count, max(0, AppToolExecutor.inputString(input["offset"]).flatMap { Int($0) } ?? 0))
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

    /// The create half of `newChatSession`, without selecting it: the chat
    /// User is looking at stays on screen.
    @MainActor
    private static func newChat(title: String, appModel: AppModel) async -> JSONValue {
        let row: ChatSessionRow
        do {
            row = try await appModel.chatSessionTransactions.create(store: appModel.engine.transcripts,
                                                                  title: title.isEmpty ? "New Chat" : title)
            appModel.engine.transcripts.setMessages([], for: row.id)
            appModel.engine.transcripts.sessions = try await appModel.engine.transcripts.list()
        } catch {
            return AppToolExecutor.failure("new_failed", "New chat failed: \(error.localizedDescription)")
        }
        appModel.publishChatSnapshot()
        let session = ChatSessionRef(row: row)
        return ok(session, changed: true, "Started \(session.title), not shown: the person's screen stays where it is.")
    }

    /// The chat on screen, or one open in its own window.
    @MainActor
    static func userIsIn(_ sessionId: String, _ appModel: AppModel) -> Bool {
        sessionId == appModel.activeChatSessionId || DetachedChatWindowController.shared.isDetached(sessionId)
    }

    @MainActor
    private static func stopOthers(calling: String, his: Bool, appModel: AppModel) -> JSONValue {
        let others = appModel.otherRunningChatSessionIDs.filter {
            $0 != calling && (his || !DetachedChatWindowController.shared.isDetached($0))
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
    private static func regenerate(_ session: ChatSessionRef, appModel: AppModel) async -> JSONValue {
        if isRunning(session.id, appModel) {
            return failure("still_running", "\(session.title) is still replying. Stop it first (verb stop), or wait.", session)
        }
        var messages = appModel.engine.transcripts.messages(for: session.id)
        if messages.isEmpty,
           let loaded = try? await appModel.engine.transcripts.loadMessages(sessionId: session.id, cached: true) {
            appModel.engine.transcripts.setMessages(loaded, for: session.id)
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
            isSyntheticNotice: last.id.hasPrefix(AppModel.syntheticErrorIDPrefix)
        ) else {
            return failure("not_retryable", "The last reply in \(session.title) is not one Try again can re-run.", session)
        }
        // The same gate the person's Retry asks. She cannot answer the
        // confirmation for them, so a re-run that could repeat a real action
        // is refused here and named.
        if let gate = ChatTurnFailure.retryNeedsConfirmation(for: last, in: messages) {
            return failure("needs_confirmation", gate.line(model: nil) + " "
                + "Ask the person before starting it over, or send a message that continues from where it stopped.",
                session)
        }
        if snapshot.inputHadAttachments {
            return failure("needs_attachment", "The question behind that reply had a file, and saved rows keep only its summary. "
                + "Send the question again with the file attached (chat.send with attachments).", session)
        }
        // Detached: the regenerated turn must not inherit the asking turn's
        // route or envelope. It runs as Try again runs; the reply lands there.
        Task.detached { [appModel, last] in await appModel.regenerateAssistantMessage(last) }
        return ok(session, changed: true, "Regenerating the last reply in \(session.title); the new one replaces it there when done.")
    }

    @MainActor
    private static func queue(
        _ session: ChatSessionRef, input: [String: JSONValue], appModel: AppModel
    ) -> JSONValue {
        let turns = appModel.engine.turns
        let action = text(input["action"]).lowercased()
        let turnId = text(input["turn_id"])
        let busy = isRunning(session.id, appModel)
        func listing(_ detail: String, changed: Bool) -> JSONValue {
            var body: [String: JSONValue] = [
                "status": .string("ok"), "changed": .bool(changed),
                "session_id": .string(session.id), "title": .string(session.title),
                "busy": .bool(busy), "queue_paused": .bool(turns.isQueuePaused(session.id)),
                "queued": .array(queuedRows(session.id, appModel)), "detail": .string(detail),
            ]
            if let reason = turns.queuePauseReason(session.id) { body["queue_paused_reason"] = .string(reason) }
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
            guard turns.queued(for: session.id).contains(where: { $0.id == turnId }) else {
                return failure("unknown_turn", "No queued turn \(turnId) in \(session.title); verb queue lists them.", session)
            }
            if busy {
                appModel.sendQueuedChatTurnNow(turnId, sessionId: session.id)
                return listing("Stopped the reply in progress; \(turnId) runs next.", changed: true)
            }
            appModel.resumeQueuedChatTurns(sessionId: session.id, startingWith: turnId)
            return listing("\(turnId) is running now.", changed: true)
        case "remove":
            guard turns.queued(for: session.id).contains(where: { $0.id == turnId }) else {
                return failure("unknown_turn", "No queued turn \(turnId.isEmpty ? "named" : turnId) in \(session.title); verb queue lists them.", session)
            }
            appModel.removeQueuedChatTurn(turnId, sessionId: session.id)
            return listing("Removed \(turnId) from the queue.", changed: true)
        default:
            return failure("unknown_action", "action is list, steer, send_next or remove.", session)
        }
    }

    // MARK: - Shared with the composer verbs

    /// The send-next queue as the strip shows it (hidden system turns left out).
    @MainActor
    static func queuedRows(_ sessionId: String, _ appModel: AppModel) -> [JSONValue] {
        ChatQueuePresentation.visibleTurns(appModel.engine.turns.queued(for: sessionId)).map { turn in
            .object([
                "turn_id": .string(turn.id),
                "preview": .string(turn.preview),
                "attachments": .int(Int64(turn.attachments.count)),
                "from": .string(turn.origin == nil ? "owner" : "you"),
            ])
        }
    }

    @MainActor
    static func isRunning(_ sessionId: String, _ appModel: AppModel) -> Bool {
        appModel.engine.turns.isBusy(sessionId) || appModel.engine.turns.isStreaming(sessionId)
    }

    struct ChatSessionRef {
        let row: ChatSessionRow
        var id: String { row.id }
        var title: String { BridgeRoutingPrefix.stripping(row.title) }
    }
    typealias ChatSessionRow = NativeAgentShared.ChatSession

    struct Refusal: Error {
        let json: JSONValue
    }

    /// An id, an exact title, or nothing: "this chat" is the conversation the
    /// request came from (bridge, phone, Telegram), else the one on screen.
    @MainActor
    static func resolve(_ raw: String, appModel: AppModel) -> Result<ChatSessionRef, Refusal> {
        let sessions = appModel.engine.transcripts.sessions
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

    // MARK: - Receipts

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

    private static func failure(_ reason: String, _ detail: String, _ session: ChatSessionRef) -> JSONValue {
        AppToolExecutor.failure(reason, detail, extra: [
            "session_id": .string(session.id), "title": .string(session.title),
        ])
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
