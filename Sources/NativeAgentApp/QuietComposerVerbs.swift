import Foundation
import NativeAgentCore
import PersistenceCore

/// The agent working its own composer, in process.
///
/// The app's own window can never be worked over accessibility: an AX round
/// trip into this process re-enters AppKit on the main thread the turn is
/// already running on, and the turn deadlocks waiting for itself. That guard
/// is real and it stays. What was missing was a way IN that never leaves the
/// process — so these verbs call the very same entry points the visible
/// control calls when a person clicks it (`ChatComposerRoutingReading.select`,
/// `setEffort`, `ChatComposerDraft.edit`, `startActiveChatTurn`), and the live
/// composer updates the way it does for a click.
///
/// No `NSApp.activate`, no `makeKeyAndOrderFront`, no synthesized event, and
/// no `NativeAgentAppCoordinator.request` (which activates): switching the
/// rail page is delivered straight to the mounted scene instead.
///
/// The person's Trust posture is not here on purpose. The trust card may be
/// opened and its word read; setting the posture is the person's, and there is
/// no verb for it.
enum QuietComposerVerbs {

    /// The verbs, by the plain name the agent calls them.
    static let names = [
        "read", "set_draft", "send", "set_model", "set_think",
        "open_card", "close_card", "set_page",
    ]

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

    @MainActor
    static func state(appModel: AppModel) async -> [String: JSONValue] {
        let routing = Routing(appModel: appModel)
        let sessionID = appModel.activeChatSessionId
        let draft = QuietSelfAdmin.shared.composerDraft?.text
            ?? appModel.chatDrafts[sessionID]
            ?? ""
        var body: [String: JSONValue] = [
            "conversation": .string(sessionID),
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
            "open_card": .string(
                cardName(QuietSelfAdmin.shared.composerCards?.activePane.word) ?? "none"
            ),
        ]
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

    @MainActor
    static func run(
        verb: String, value: String, choice: String, appModel: AppModel
    ) async -> Outcome {
        switch verb {
        case "set_draft": return setDraft(value, appModel: appModel)
        case "send": return await send(appModel: appModel)
        case "set_model", "set_think":
            // A bot conversation sends on the BOT's model and thinking level,
            // not Chat's. The glass does not even open these two cards there
            // (it routes to Bots), so writing the global tuple from here would
            // change something the conversation does not use.
            if Routing(appModel: appModel).isBotConversation {
                return .refuse(
                    verb == "set_model" ? "model card" : "think card",
                    "bot_conversation",
                    "This conversation runs on its bot's own model and thinking level. "
                    + "The composer's cards do not open here; change the bot on the bots page."
                )
            }
            return verb == "set_model"
                ? await setModel(provider: value, model: choice, appModel: appModel)
                : setThink(value, appModel: appModel)
        case "open_card": return openCard(value, appModel: appModel)
        case "close_card": return closeCard()
        case "set_page": return setPage(value)
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
    @MainActor
    private static func setDraft(_ text: String, appModel: AppModel) -> Outcome {
        let sessionID = appModel.activeChatSessionId
        guard !sessionID.isEmpty else {
            return .refuse("composer draft", "no_conversation", "No conversation is open.")
        }
        let before = QuietSelfAdmin.shared.composerDraft?.text ?? appModel.chatDrafts[sessionID] ?? ""
        if let live = QuietSelfAdmin.shared.composerDraft, live.sessionId == sessionID || live.sessionId.isEmpty {
            live.edit(text)
            live.sessionId = sessionID
        }
        if text.isEmpty {
            appModel.chatDrafts.removeValue(forKey: sessionID)
        } else {
            appModel.chatDrafts[sessionID] = text
        }
        appModel.touchChatDraft(sessionId: sessionID)
        return .done(
            "composer draft (message box)",
            "Draft is now \(text.count) characters.",
            changed: before != text
        )
    }

    /// Send takes the composer's own acceptance path, so a run in flight
    /// queues exactly the way the person's Return key queues.
    @MainActor
    private static func send(appModel: AppModel) async -> Outcome {
        let sessionID = appModel.activeChatSessionId
        guard !sessionID.isEmpty else {
            return .refuse("send button", "no_conversation", "No conversation is open.")
        }
        let message = QuietSelfAdmin.shared.composerDraft?.text
            ?? appModel.chatDrafts[sessionID]
            ?? ""
        guard !message.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            return .refuse("send button", "empty_draft", "The message box is empty; set_draft first.")
        }
        guard !appModel.isSavingChatBrain else {
            return .refuse(
                "send button", "model_saving",
                "The model change has not landed yet — the glass disables Send here too."
            )
        }
        let editedAt = QuietSelfAdmin.shared.composerDraft?.editedAt ?? Date()
        switch await appModel.startActiveChatTurn(message, expectedSessionId: sessionID) {
        case .accepted(let accepted), .queued(let accepted, _):
            if let live = QuietSelfAdmin.shared.composerDraft, live.text == message {
                live.edit("")
            }
            appModel.clearChatDraftAfterSend(message, sessionId: accepted, editedAt: editedAt)
            return .done("send button", "Sent into \(accepted).")
        case .rejected(let message):
            return .refuse("send button", "send_rejected", message)
        }
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
    private static func setThink(_ effort: String, appModel: AppModel) -> Outcome {
        let routing = Routing(appModel: appModel)
        let efforts = routing.efforts
        guard let index = efforts.firstIndex(where: { $0.id == effort }) else {
            return .refuse(
                "think card", "unknown_think_level",
                "This model's thinking levels are: " + efforts.map(\.id).joined(separator: ", ")
            )
        }
        let changed = appModel.chatReasoningEffort != effort
        routing.setEffort(index: index)
        return .done(
            "think card step \"\(efforts[index].label)\"",
            "Thinking is now \(effort).",
            changed: changed
        )
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

    /// The rail, delivered straight to the mounted scene. `request` would
    /// activate the app and open the window; this is the same destination
    /// without either.
    @MainActor
    static func setPage(_ raw: String, coordinator: NativeAgentAppCoordinator = .shared) -> Outcome {
        guard let page = QuietPages.page(named: raw) else {
            return .refuse(
                "rail", "unknown_page",
                "No page is called that. The pages are: " + QuietPages.ids.joined(separator: ", ")
            )
        }
        guard !SimpleViewMode.isShowing else {
            return .refuse("rail", "no_pages_in_simple_view", SimpleViewMode.noPagesNote)
        }
        guard coordinator.deliverQuietly(.sidebar(page.item)) else {
            return .refuse(
                "rail", "no_mounted_window",
                "The main window is not mounted in this process, so the rail cannot be moved "
                + "without opening one — and opening one is not quiet."
            )
        }
        guard coordinator.currentPage?.id == page.id else {
            return .refuse("rail", "page_not_shown", "The window has not switched to \(page.id).")
        }
        return .done("rail row \"\(page.title)\"", "The window is now showing \(page.id).")
    }
}
