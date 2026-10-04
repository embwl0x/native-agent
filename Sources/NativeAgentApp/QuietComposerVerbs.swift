import ChatOrchestration
import Desk
import AppToolRuntime
import Foundation
import NativeAgentCore
import NativeAgentShared
import PersistenceCore
import TrustCenter

/// The agent working its own composer, in process.
///
/// The app's own window can never be worked over accessibility: an AX round
/// trip into this process re-enters AppKit on the main thread the turn is
/// already running on, and the turn deadlocks waiting for itself. That guard
/// is real and it stays. What was missing was a way IN that never leaves the
/// process — so these verbs call the very same entry points the visible
/// control calls when a person clicks it (`ChatComposerRoutingReading.select`,
/// `saveChatBrainDefaults`, `ChatComposerDraft.edit`, `startChatTurn`), and the live
/// composer updates the way it does for a click.
///
/// Draft and send reach any conversation by `session_id`, not only the one on
/// screen. Her send is not User's: it never publishes the conversation anchor,
/// its row and any queued turn carry `QuietChatSessionVerbs.agentOrigin`, and
/// it starts detached so the new turn inherits nothing of the asking turn's
/// route or envelope.
///
/// No `NSApp.activate`, no `makeKeyAndOrderFront`, no synthesized event, and
/// no `NativeAgentAppCoordinator.request` (which activates): switching the
/// rail page is delivered straight to the mounted scene instead. The one
/// exception is `show_browser`, which is the menu's own Browser item. It and
/// every other verb that changes User's screen or makes a sound runs only as
/// when the turn reaches User (`AppToolExecutor.reachesUser`).
///
/// The person's Trust posture is not here on purpose. The trust card may be
/// opened and its word read; setting the posture is the person's, and there is
/// no verb for it.
enum QuietComposerVerbs {

    /// The verbs, by the plain name the agent calls them.
    static let names = [
        "read", "set_draft", "send", "set_model", "set_think", "set_fast",
        "open_card", "close_card", "set_page", "show_browser", "set_persona",
        "speak", "write_scratch", "check_updates",
    ]

    /// Verbs that change what is on User's screen: they run only when the
    /// turn reaches User (`reachesUser`), as `speak` does.
    static let usersScreenVerbs: Set = ["set_page", "open_card", "close_card", "show_browser", "set_persona"]

    /// The panes the one composer shell can show. Context is the ring's own
    /// pane — the last turn's receipt — so it opens like the other three;
    /// `read` still returns the ring's fraction either way.
    static let cardNames = ["model", "think", "trust", "context"]

    // MARK: - Reading

    /// One concrete reader over the composer's own protocol, so the words and
    /// the picker here are the same code the row on screen runs.
    @MainActor
    private struct Routing: ChatComposerRoutingReading {
        let appModel: AppModel
        var botContract: BotChatContract? { nil }
        var cardState: ComposerShellState? { QuietSelfAdmin.shared.composerCards }
    }

    /// The draft as the composer of `sessionID` holds it: the main window's
    /// live field for the conversation on screen, the saved draft otherwise.
    @MainActor
    private static func draft(_ sessionID: String, appModel: AppModel) -> String {
        (sessionID == appModel.activeChatSessionId ? QuietSelfAdmin.shared.composerDraft?.text : nil)
            ?? appModel.chatDrafts[sessionID]
            ?? ""
    }

    /// Empty `sessionId` reads the conversation on screen.
    @MainActor
    static func state(appModel: AppModel, sessionId: String = "") async -> [String: JSONValue] {
        let routing = Routing(appModel: appModel)
        var sessionID = appModel.activeChatSessionId
        if !sessionId.isEmpty {
            guard case .success(let found) = QuietChatSessionVerbs.resolve(sessionId, appModel: appModel) else {
                return [
                    "status": .string("failed"), "reason": .string("unknown_session"),
                    "detail": .string("No open conversation has that id or title. chat.list lists them with their ids."),
                ]
            }
            sessionID = found.id
        }
        let draft = draft(sessionID, appModel: appModel)
        let turns = appModel.engine.turns
        var body: [String: JSONValue] = [
            "conversation": .string(sessionID),
            "on_screen": .bool(sessionID == appModel.activeChatSessionId),
            "busy": .bool(QuietChatSessionVerbs.isRunning(sessionID, appModel)),
            "queued": .array(QuietChatSessionVerbs.queuedRows(sessionID, appModel)),
            "queue_paused": .bool(turns.isQueuePaused(sessionID)),
            "attachments": .array((appModel.chatPendingAttachments[sessionID] ?? []).map {
                .string($0.name ?? $0.type)
            }),
            "draft": .string(draft),
            "draft_characters": .int(Int64(draft.count)),
            "provider": .string(appModel.chatProvider),
            "model": .string(appModel.chatModel),
            "model_word": .string(routing.modelWord),
            "think": .string(appModel.chatReasoningEffort),
            "think_word": .string(routing.effortWord),
            "think_choices": .array(routing.efforts.map { .string($0.id) }),
            "fast": .bool(routing.fastIsOn),
            "trust_word": .string(routing.trustWord),
            "persona": .string(appModel.chatPersona),
            "open_card": .string(
                cardName(QuietSelfAdmin.shared.composerCards?.activePane.word) ?? "none"
            ),
        ]
        if let reason = turns.queuePauseReason(sessionID) { body["queue_paused_reason"] = .string(reason) }
        if !sessionID.isEmpty,
           let status = try? await appModel.getSessionContext(
               sessionId: sessionID, model: appModel.chatModel
           ) {
            let usage = ContextFillPresentation.usage(status)
            body["ring_fraction"] = .double(usage.fillFraction)
            body["ring_percent"] = .int(Int64(usage.percent.rounded()))
            body["context_used_tokens"] = .int(Int64(status.used_tokens))
            body["context_budget_tokens"] = .int(Int64(status.budget))
        }
        return body
    }

    private static func cardName(_ card: ChatComposerCard?) -> String? {
        switch card {
        case .model: return "model"
        case .effort: return "think"
        case .trust: return "trust"
        case .context: return "context"
        case nil: return nil
        }
    }

    private static func card(named raw: String) -> ChatComposerCard? {
        switch raw {
        case "model": return .model
        case "think", "effort", "thinking": return .effort
        case "trust": return .trust
        case "context", "receipt": return .context
        default: return nil
        }
    }

    // MARK: - Writing

    /// What a verb changed, or why it did not. The caller turns this into the
    /// same receipt shape every other quiet verb returns.
    struct Outcome {
        var changed: Bool
        var element: String
        var detail: String
        /// Non-nil means refused: nothing was changed.
        var refusal: (reason: String, detail: String)?

        static func done(_ element: String, _ detail: String, changed: Bool = true) -> Outcome {
            Outcome(changed: changed, element: element, detail: detail, refusal: nil)
        }

        static func refuse(_ element: String, _ reason: String, _ detail: String) -> Outcome {
            Outcome(changed: false, element: element, detail: detail,
                    refusal: (reason: reason, detail: detail))
        }
    }

    /// Every check that refuses a verb before anything is touched: User's
    /// screen, his ears, and a draft, send or scratch into a conversation he
    /// is in (or one that does not resolve). Reads only, so the door's preview
    /// asks it too and refuses what the real call would; `run` asks it first,
    /// before any window, draft or sound is touched. `session` is the
    /// conversation a draft, send or scratch lands in.
    @MainActor
    static func fence(
        verb: String, value: String, sessionId: String, reachesUser: Bool, turnSessionId: String, appModel: AppModel
    ) -> (session: String, refusal: Outcome?) {
        if !reachesUser, usersScreenVerbs.contains(verb) {
            return ("", .refuse(
                verb, "users_screen",
                "That moves User's screen, and he did not start this turn. Ask him, or tell him "
                + "where it is (app {page} reads any page without showing it)."
            ))
        }
        if !reachesUser, verb == "speak" {
            return ("", .refuse(
                "read aloud", "users_ears",
                "Speaking out loud interrupts User, and he did not start this turn. Ask him, "
                + "or say it in your reply."
            ))
        }
        switch verb {
        case "set_draft", "send":
            let element = verb == "send" ? "send button" : "composer draft"
            var sessionID = appModel.activeChatSessionId
            if !sessionId.isEmpty {
                switch QuietChatSessionVerbs.resolve(sessionId, appModel: appModel) {
                case .success(let found): sessionID = found.id
                case .failure:
                    return ("", .refuse(
                        element, "unknown_session",
                        "No open conversation has that id or title. chat.list lists them with their ids."
                    ))
                }
            }
            // A conversation User is in holds HIS draft and files: unless the
            // turn reaches him, she sends her own words there and leaves his
            // box alone.
            if !reachesUser, QuietChatSessionVerbs.userIsIn(sessionID, appModel),
               verb == "set_draft" || value.isEmpty {
                return (sessionID, .refuse(
                    element, "users_draft",
                    "User is in that conversation, so its draft and attached files are his. "
                    + (verb == "send" ? "Pass your own text in value." : "Ask him first, or send your own text with send and value.")
                ))
            }
            return (sessionID, nil)
        case "write_scratch":
            // The asking turn's own conversation (the one scratchpad_read
            // reads), or the one she named. A conversation User is in is his,
            // as his draft is, unless the turn reaches him.
            var sessionID = turnSessionId
            if !sessionId.isEmpty {
                guard case .success(let found) = QuietChatSessionVerbs.resolve(sessionId, appModel: appModel) else {
                    return ("", .refuse("/scratch", "unknown_session",
                                        "No open conversation has that id or title. chat.list lists them with their ids."))
                }
                sessionID = found.id
            }
            guard !sessionID.isEmpty else {
                return ("", .refuse("/scratch", "no_conversation", "This turn has no conversation of its own: pass session_id."))
            }
            if !reachesUser, QuietChatSessionVerbs.userIsIn(sessionID, appModel) {
                return (sessionID, .refuse(
                    "/scratch", "users_draft",
                    "User is in that conversation, so its scratch is his. Ask him first, or write in a conversation he is not in."
                ))
            }
            return (sessionID, nil)
        default:
            return ("", nil)
        }
    }

    @MainActor
    static func run(
        verb: String, value: String, choice: String,
        sessionId: String = "", attachments: [URL] = [], reachesUser: Bool = false,
        turnSessionId: String = "", appModel: AppModel
    ) async -> Outcome {
        let fenced = fence(verb: verb, value: value, sessionId: sessionId, reachesUser: reachesUser,
                           turnSessionId: turnSessionId, appModel: appModel)
        if let refusal = fenced.refusal { return refusal }
        let sessionID = fenced.session
        switch verb {
        case "set_draft", "send":
            var files: [NativeAgentShared.MultimodalAttachment] = []
            for url in attachments {
                let read: Result<NativeAgentShared.MultimodalAttachment, ChatComposerSupport.AttachmentRefusal>
                switch ChatComposerSupport.attachmentKind(url, resolveType: ChatAttachmentTypeResolver.typeAndMime) {
                case .success(let kind): read = await ChatComposerSupport.readAttachment(url, kind: kind)
                case .failure(let refusal): read = .failure(refusal)
                }
                switch read {
                case .success(let file): files.append(file)
                case .failure(let refusal):
                    return .refuse("attach button", "attachment_refused", refusal.message + " Nothing was changed.")
                }
            }
            return verb == "send"
                ? await send(value, sessionID: sessionID, files: files, appModel: appModel)
                : setDraft(value, sessionID: sessionID, files: files, appModel: appModel)
        case "set_model", "set_think", "set_fast":
            // A bot conversation sends on the BOT's model and thinking level,
            // not Chat's. The glass does not even open these two cards there
            // (it routes to Bots), so writing the global tuple from here would
            // change something the conversation does not use.
            if Routing(appModel: appModel).isBotConversation {
                return .refuse(
                    verb == "set_think" ? "think card" : "model card",
                    "bot_conversation",
                    "This conversation runs on its bot's own model and thinking level. "
                    + "The composer's cards do not open here; change the bot on the bots page."
                )
            }
            switch verb {
            case "set_model": return await setModel(provider: value, model: choice, appModel: appModel)
            case "set_think": return await setThink(value, appModel: appModel)
            default: return await setFast(value, appModel: appModel)
            }
        case "open_card": return openCard(value, appModel: appModel)
        case "close_card": return closeCard()
        case "set_page": return await setPage(value, item: choice, appModel: appModel)
        case "show_browser":
            BrowserWindowController.shared.showWindow()
            return .done("Window > Browser", "The browser window is in front.")
        case "set_persona": return setPersona(value, appModel: appModel)
        case "speak": return await speak(value, appModel: appModel)
        case "write_scratch":
            return await writeScratch(key: choice, value: value, sessionID: sessionID, appModel: appModel)
        case "check_updates":
            let check = await UpdateController.shared.probeForUpdate()
            return check.refusal.map { .refuse("Check for Updates", $0.reason, $0.detail) }
                ?? .done("Check for Updates", check.detail, changed: false)
        default:
            return .refuse(
                "composer", "unknown_verb",
                "No composer verb is called that. The verbs are: "
                + names.joined(separator: ", ") + "."
            )
        }
    }

    /// The draft goes to BOTH copies: the live `ChatComposerDraft` the text
    /// field binds to, and `appModel.chatDrafts`, which is what survives a
    /// session switch and what the chat page's projection reads back.
    ///
    /// Another conversation's draft goes in through `injectChatDraft`, which a
    /// detached window's composer pulls. Files join the conversation's
    /// attached files, as a drop does; passing only files keeps the draft.
    @MainActor
    private static func setDraft(
        _ text: String, sessionID: String, files: [NativeAgentShared.MultimodalAttachment], appModel: AppModel
    ) -> Outcome {
        guard !sessionID.isEmpty else {
            return .refuse("composer draft", "no_conversation", "No conversation is open.")
        }
        let before = draft(sessionID, appModel: appModel)
        let after = text.isEmpty && !files.isEmpty ? before : text
        if sessionID != appModel.activeChatSessionId {
            if after != before { appModel.injectChatDraft(after, sessionId: sessionID) }
        } else {
            if let live = QuietSelfAdmin.shared.composerDraft, live.sessionId == sessionID || live.sessionId.isEmpty {
                live.edit(after)
                live.sessionId = sessionID
            }
            if after.isEmpty {
                appModel.chatDrafts.removeValue(forKey: sessionID)
            } else {
                appModel.chatDrafts[sessionID] = after
            }
            appModel.touchChatDraft(sessionId: sessionID)
        }
        if !files.isEmpty { appModel.chatPendingAttachments[sessionID, default: []].append(contentsOf: files) }
        let attached = appModel.chatPendingAttachments[sessionID]?.count ?? 0
        return .done(
            "composer draft (message box)",
            "Draft is now \(after.count) characters" + (attached == 0 ? "." : ", with \(attached) file(s) attached."),
            changed: before != after || !files.isEmpty
        )
    }

    /// Send takes the composer's own acceptance path, so a run in flight
    /// queues exactly the way the person's Return key queues. `value` is sent
    /// as is; empty sends the conversation's draft. Either way its attached
    /// files ride along, as they do with Return.
    @MainActor
    private static func send(
        _ value: String, sessionID: String,
        files: [NativeAgentShared.MultimodalAttachment], appModel: AppModel
    ) async -> Outcome {
        guard !sessionID.isEmpty else {
            return .refuse("send button", "no_conversation", "No conversation is open.")
        }
        let fromDraft = value.isEmpty
        let message = fromDraft ? draft(sessionID, appModel: appModel) : value
        let staged = fromDraft ? (appModel.chatPendingAttachments[sessionID] ?? []) : []
        guard !message.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || !(staged + files).isEmpty else {
            return .refuse("send button", "empty_draft", "Nothing to send: pass the text in value, or set_draft first.")
        }
        guard !appModel.isSavingChatBrain else {
            return .refuse(
                "send button", "model_saving",
                "The model change has not landed yet — the glass disables Send here too."
            )
        }
        let editedAt = Date()
        let all = staged + files
        let steer = PeerDataTaint.carried(
            peerBridge: PeerTurnEffectPolicy.isPeerBridge(surface: ChatToolSessionContext.envelope?.surface ?? "chat"),
            peerID: ChatToolSessionContext.envelope?.verifiedUserId
        )
        var origin = QuietChatSessionVerbs.agentOrigin
        origin.peerSources = steer.sources
        origin.elevatedPeerSources = steer.elevated
        let acceptance = await Task.detached { [appModel, message, all, sessionID, origin] in
            await startAgentTurn(message, attachments: all, sessionID: sessionID, origin: origin, appModel: appModel)
        }.value
        switch acceptance {
        case .accepted(let accepted), .queued(let accepted, _):
            if fromDraft {
                if let live = QuietSelfAdmin.shared.composerDraft, live.sessionId == accepted, live.text == message {
                    live.edit("")
                }
                appModel.clearChatDraftAfterSend(message, sessionId: accepted, editedAt: editedAt)
                appModel.bumpChatDraftInjectionGeneration()
            }
            let sent = Set(staged.map(\.id))
            appModel.chatPendingAttachments[sessionID]?.removeAll { sent.contains($0.id) }
            if case .queued = acceptance {
                return .done("send button", "Queued in \(accepted): it runs after the reply in progress.")
            }
            return .done("send button", "Sent into \(accepted).")
        case .rejected(let message):
            return .refuse("send button", "send_rejected", message)
        }
    }

    /// Reply routing stays detached; the caller's peer steering rides the send.
    @MainActor
    private static func startAgentTurn(
        _ message: String, attachments: [NativeAgentShared.MultimodalAttachment],
        sessionID: String, origin: ChatMessageOrigin, appModel: AppModel
    ) async -> MacChatTurnAcceptance {
        await appModel.startChatTurn(
            message, attachments: attachments, sessionId: sessionID,
            hideUserBubble: false, requireActiveSession: false,
            origin: origin
        ).acceptance
    }

    /// The model card's Fast toggle: same write, same refusals.
    @MainActor
    private static func setFast(_ raw: String, appModel: AppModel) async -> Outcome {
        guard let on = ["on": true, "true": true, "off": false, "false": false][raw.lowercased()] else {
            return .refuse("model card Fast toggle", "unknown_value", "Pass on or off in value.")
        }
        guard Routing(appModel: appModel).selectedModelSupportsFast else {
            return .refuse(
                "model card Fast toggle", "no_fast",
                "\(appModel.chatModel) has no Fast mode. Pick a model that has it with set_model first."
            )
        }
        guard !appModel.isSavingChatBrain || appModel.chatBrainSaveTask != nil else {
            return .refuse("model card Fast toggle", "model_saving", "A model change is still saving.")
        }
        let changed = appModel.chatFastMode != on
        appModel.chatFastMode = on
        if case .failed(let message, _) = await appModel.saveChatBrainDefaults() {
            return .refuse("model card Fast toggle", "fast_write_failed", message)
        }
        return .done("model card Fast toggle", "Fast is now \(appModel.chatFastMode ? "on" : "off").", changed: changed)
    }

    /// The picker path a person takes: provider AND model in one write,
    /// through `configureSurfaceSelection`, so UI placement stays the
    /// behaviour instruction rather than a second route around it.
    @MainActor
    private static func setModel(provider: String, model: String, appModel: AppModel) async -> Outcome {
        let routing = Routing(appModel: appModel)
        let groups = routing.providerGroups
        guard !provider.isEmpty, !model.isEmpty else {
            return .refuse(
                "model card", "missing_model",
                "Pass the provider in value and the model id in choice. Available: "
                + groups.map { "\($0.id): " + $0.models.map(\.id).joined(separator: ", ") }
                    .joined(separator: " | ")
            )
        }
        guard let group = groups.first(where: { $0.id == provider }) else {
            return .refuse(
                "model card", "unknown_provider",
                "No connected provider is called \(provider). Connected: "
                + groups.map(\.id).joined(separator: ", ")
            )
        }
        guard let item = group.models.first(where: { $0.id == model }) else {
            return .refuse(
                "model card", "unknown_model",
                "\(provider) has no model \(model). It has: "
                + group.models.map(\.id).joined(separator: ", ")
            )
        }
        guard !appModel.isSavingChatBrain else {
            return .refuse("model card", "model_saving", "Another model change is still saving.")
        }
        let before = "\(appModel.chatProvider) · \(appModel.chatModel)"
        // The receipt waits for the transaction. Reporting the pick as done
        // while the write was still open left a permanently false receipt
        // behind a failure that only moved `statusText` (Sol, 2026-09-17).
        guard let write = routing.select(model: item, provider: provider) else {
            return .refuse(
                "model pane", "model_saving",
                "Another model change took the tuple first; nothing was changed."
            )
        }
        if let failure = await write.value {
            return .refuse(
                "model pane row \"\(item.displayName)\" under \(group.provider)",
                "model_write_failed",
                "Chat is still on \(before): \(failure)"
            )
        }
        // The CANONICAL tuple, read back after it landed — not what was asked.
        let after = "\(appModel.chatProvider) · \(appModel.chatModel)"
        return .done(
            "model pane row \"\(item.displayName)\" under \(group.provider)",
            "Chat runs on \(after).",
            changed: before != after
        )
    }

    @MainActor
    private static func setThink(_ effort: String, appModel: AppModel) async -> Outcome {
        let routing = Routing(appModel: appModel)
        let efforts = routing.efforts
        guard let index = efforts.firstIndex(where: { $0.id == effort }) else {
            return .refuse(
                "think card", "unknown_think_level",
                "This model's thinking levels are: " + efforts.map(\.id).joined(separator: ", ")
            )
        }
        guard !appModel.isSavingChatBrain || appModel.chatBrainSaveTask != nil else {
            return .refuse("think card", "model_saving", "A model change is still saving.")
        }
        let before = appModel.chatReasoningEffort
        appModel.chatReasoningEffort = effort
        switch await appModel.saveChatBrainDefaults() {
        case .failed(let message, _):
            return .refuse("think card", "think_write_failed", message)
        case .saved(let selection), .unchanged(let selection):
            return .done(
                "think card step \"\(efforts[index].label)\"",
                "Thinking is now \(selection.reasoningEffort).",
                changed: before != selection.reasoningEffort
            )
        }
    }

    /// One shell, one active pane. The verb writes the pane the word would
    /// have written, so the model word lands on the live provider's models
    /// exactly as a click does.
    @MainActor
    private static func openCard(_ raw: String, appModel: AppModel) -> Outcome {
        guard let shell = QuietSelfAdmin.shared.composerCards else {
            return .refuse("composer pane", "composer_unavailable", "No composer is mounted.")
        }
        guard let card = card(named: raw) else {
            return .refuse(
                "composer pane", "unknown_card",
                "The composer panes are: " + cardNames.joined(separator: ", ") + "."
            )
        }
        let pane = ComposerPane.opening(card, provider: appModel.chatProvider)
        let changed = shell.activePane != pane
        shell.activePane = pane
        shell.flyoutIndex = nil
        return .done(
            "composer \(cardName(card) ?? raw) pane",
            "The pane is open.",
            changed: changed
        )
    }

    @MainActor
    private static func closeCard() -> Outcome {
        guard let shell = QuietSelfAdmin.shared.composerCards else {
            return .refuse("composer pane", "composer_unavailable", "No composer is mounted.")
        }
        let was = cardName(shell.activePane.word)
        shell.dismiss()
        return .done(
            "composer \(was ?? "shell") pane",
            was == nil ? "No pane was open." : "The pane is closed.",
            changed: was != nil
        )
    }

    /// Places inside a rail page: a Today sheet, or a page's tab by the key
    /// the page itself stores.
    static let sheets: [String: ActivitySection] = [
        "approvals": .approvals, "today_inbox": .inbox, "memory_proposals": .memoryProposals,
        "self_improvement": .selfImprovement, "standing_views": .cognitionProposals,
    ]
    static let tabs: [String: (page: SidebarItem, tab: String)] = [
        "knowledge": (.memories, "knowledge"), "minds": (.personality, "minds"),
        "dreams": (.personality, "dreams"), "agents": (.connectors, "agents"),
        "doctor": (.diagnostics, DiagnosticsView.DiagnosticsMode.doctor.rawValue),
        "status": (.diagnostics, DiagnosticsView.DiagnosticsMode.status.rawValue),
        "runs": (.diagnostics, DiagnosticsView.DiagnosticsMode.runs.rawValue),
        "cognition": (.diagnostics, DiagnosticsView.DiagnosticsMode.cognition.rawValue),
        "inspector": (.diagnostics, DiagnosticsView.DiagnosticsMode.inspector.rawValue),
        "skills": (.diagnostics, "skills"), "tools": (.diagnostics, "tools"),
    ]

    /// The rail, delivered straight to the mounted scene. `request` would
    /// activate the app and open the window; this is the same destination
    /// without either. It also reaches a Today sheet, a page's tab, and one
    /// Desk item (`item`, its handle) the way a notification click opens it.
    /// Simple view has no pages, so it leaves for Advanced first, as the
    /// Simple settings menu's "More settings…" does.
    @MainActor
    static func setPage(
        _ raw: String, item: String, appModel: AppModel, coordinator: NativeAgentAppCoordinator = .shared
    ) async -> Outcome {
        let key = raw.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        let destination: NativeAgentNavigationDestination
        let shown: SidebarItem
        var tab: String?
        var title = key
        if let section = sheets[key] {
            destination = .activity(section)
            shown = section == .memoryProposals ? .memories : .activity
        } else if let home = tabs[key] {
            (destination, shown, tab) = (.sidebar(home.page), home.page, home.tab)
        } else if let page = QuietPages.page(named: raw) {
            destination = .sidebar(page.item)
            shown = SidebarItem.shellHome(for: page.item)?.parent ?? page.item
            (tab, title) = (page.tab, page.id)
        } else {
            return .refuse(
                "rail", "unknown_page",
                "No page is called that. The pages are: " + QuietPages.ids.joined(separator: ", ")
                + ". Inside them: " + (Array(sheets.keys) + Array(tabs.keys)).sorted().joined(separator: ", ")
                + ". Value desk with a Desk item's handle in choice opens that item."
            )
        }
        let handle = item.trimmingCharacters(in: .whitespacesAndNewlines)
        if !handle.isEmpty {
            guard shown == .desk else {
                return .refuse("Desk item", "item_needs_desk", "choice opens a Desk item, so pass value desk with it.")
            }
            let root = appModel.dataRootOverride ?? PersistenceCore.defaultDataRoot()
            do {
                guard try await SwiftNativeDeskStore(dataRoot: root).liveState().items.contains(where: { $0.handle == handle }) else {
                    return .refuse("Desk item", "unknown_desk_item", "No Desk item has the handle \(handle). app desk.read lists the handles.")
                }
            } catch {
                return .refuse("Desk item", "desk_unreadable", "The Desk could not be read (\(error.localizedDescription)), so nothing was opened. Try again.")
            }
        }
        guard coordinator.deliverQuietly(destination) else {
            return .refuse(
                "rail", "no_mounted_window",
                "The main window is not mounted in this process, so the rail cannot be moved "
                + "without opening one — and opening one is not quiet."
            )
        }
        // A tab page lands on its rail page with the tab open.
        if let tab { UserDefaults.standard.set(tab, forKey: ShellRailTab.storageKey(shown)) }
        if !handle.isEmpty { appModel.pendingDeskHandle = handle }
        let leftSimple = SimpleViewMode.isShowing
        if leftSimple { UserDefaults.standard.set(SimpleViewMode.advanced, forKey: SimpleViewMode.key) }
        guard coordinator.currentPage?.item == shown else {
            return .refuse("rail", "page_not_shown", "The window has not switched to \(title).")
        }
        return .done(
            "rail row \"\(title)\"",
            "The window is now showing \(title)" + (handle.isEmpty ? "" : ", opening Desk item \(handle)")
                + (leftSimple ? ", in Advanced view (Simple view has no pages)." : ".")
        )
    }

    /// `/persona <name>`: the same write, so the next turn compiles that
    /// persona (an unknown name falls back to the active one).
    @MainActor
    private static func setPersona(_ raw: String, appModel: AppModel) -> Outcome {
        let name = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty else {
            return .refuse("/persona", "missing_persona", "Pass the persona name in value. It is now \(appModel.chatPersona).")
        }
        let changed = appModel.chatPersona != name
        appModel.chatPersona = name
        return .done("/persona", "Chat persona is now \(appModel.chatPersona).", changed: changed)
    }

    /// A bubble's "Read aloud": the shared message player, on the route the
    /// Trust policy picks, so it stops whatever bubble was reading.
    @MainActor
    private static func speak(_ text: String, appModel: AppModel) async -> Outcome {
        guard !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            return .refuse("read aloud", "nothing_to_say", "Pass the words to say in value.")
        }
        guard !VoicePreference.quiet() else {
            return .refuse(
                "read aloud", "quiet_mode",
                "Quiet mode is on (chat.quiet_mode), so nothing plays. Say it in your reply instead."
            )
        }
        let owner = "agent.speak"
        let voice = VoiceOutputController.sharedMessagePlayback
        await voice.speak(text: text, trust: appModel.engine.trust, ownerID: owner)
        if let failure = voice.consumeError(ownerID: owner) {
            return .refuse("read aloud", "speak_failed", failure)
        }
        return .done("read aloud", "Reading \(text.count) characters aloud now.")
    }

    /// `/scratch <key> <value>` into the conversation `fence` picked.
    @MainActor
    private static func writeScratch(key: String, value: String, sessionID: String, appModel: AppModel) async -> Outcome {
        let key = key.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !key.isEmpty, !key.contains(" "), !value.isEmpty else {
            return .refuse("/scratch", "missing_scratch", "Pass the key (one word) in choice and the text in value.")
        }
        let result = await appModel.writeScratch(key: key, value: value, sessionId: sessionID)
        guard result.succeeded else { return .refuse("/scratch", "scratch_write_failed", result.userMessage) }
        return .done("/scratch", "Scratch \(key) is set in \(sessionID); app chat.scratch_read reads it back.")
    }
}
