import Transcripts
import MultimodalTTS
import ChatTurnRuntime
import ChatTurnContracts
import Foundation
import NativeAgentCore
import NativeAgentShared
import PersistenceCore
import ProviderRouting
import TrustCenter

// Blueprint: | `QuietComposerCommands.swift` | `QuietComposerCommands`: draft/model/effort/persona/speech commands through composer ports; preview and execution share admission fences |

public protocol QuietComposerModel: Identifiable where ID == String {
    var displayName: String { get }
}

public protocol QuietComposerEffort: Identifiable where ID == String {
    var label: String { get }
}

@MainActor
public protocol QuietComposerCommandPort: QuietChatSessionCommandPort {
    associatedtype ComposerModel: QuietComposerModel
    associatedtype ComposerEffort: QuietComposerEffort
    var chatPendingAttachments: [String: [NativeAgentShared.MultimodalAttachment]] { get set }
    var chatPersona: String { get set }
    var chatReasoningEffort: String { get set }
    var chatFastMode: Bool { get set }
    var isSavingChatBrain: Bool { get }
    var quietComposerProviderGroups: [(id: String, provider: String, models: [ComposerModel])] { get }
    var quietComposerEfforts: [ComposerEffort] { get }
    var quietComposerSupportsFast: Bool { get }
    func quietComposerDraft(_ sessionID: String) -> String
    func quietComposerDraftRevision(_ sessionID: String) -> (Date, Int)
    func setQuietComposerDraft(_ text: String, sessionID: String)
    func clearQuietAcceptedDraft(_ message: String, sessionID: String, editedAt: Date)
    func quietComposerPaneClosed(turnID: String?) -> Bool
    func quietComposerPresentationState(sessionID: String) async -> [String: JSONValue]
    func quietComposerPresentation(verb: String, value: String, choice: String) async -> QuietComposerOutcome
    func selectQuietComposerModel(_ model: ComposerModel, provider: String) -> Task<String?, Never>?
    func saveQuietChatBrain() async -> (succeeded: Bool, agentMessage: String, reasoningEffort: String)
    func startQuietSpeech(_ text: String) async -> String?
    func writeQuietScratch(key: String, value: String, sessionId: String) async -> (succeeded: Bool, agentMessage: String)
}

public enum QuietComposerCommands {
    public typealias Outcome = QuietComposerOutcome

    public static let names = [
        "read", "set_draft", "send", "set_model", "set_think", "set_fast",
        "open_card", "close_card", "set_page", "show_browser", "show_pane", "hide_pane", "set_persona",
        "speak", "write_scratch", "check_updates",
    ]

    public static let usersScreenVerbs: Set = [
        "set_page", "open_card", "close_card", "show_browser", "show_pane", "hide_pane", "set_persona",
    ]

    @MainActor
    public static func state<Host: QuietComposerCommandPort>(appModel: Host, sessionId: String = "") async -> [String: JSONValue] {
        var sessionID = appModel.activeChatSessionId
        if !sessionId.isEmpty {
            switch QuietChatSessionCommands.resolve(sessionId, appModel: appModel) {
            case .success(let found): sessionID = found.id
            case .failure(let refusal):
                // The resolver's own why; a name no conversation has is not_found.
                var fields: [String: JSONValue] = if case .object(let fields) = refusal.json { fields } else { [:] }
                if fields["reason"] == .string("unknown_session") { fields["status"] = .string("not_found") }
                fields["effects"] = .string("none")
                return fields
            }
        }
        let draft = appModel.quietComposerDraft(sessionID)
        var body: [String: JSONValue] = [
            "conversation": .string(sessionID),
            "on_screen": .bool(sessionID == appModel.activeChatSessionId),
            "busy": .bool(QuietChatSessionCommands.isRunning(sessionID, appModel)),
            "queued": .array(QuietChatSessionCommands.queuedRows(sessionID, appModel)),
            "queue_paused": .bool(appModel.macChatTurns.pausedQueueSessions.contains(sessionID)),
            "attachments": .array((appModel.chatPendingAttachments[sessionID] ?? []).map { .string($0.name ?? $0.type) }),
            "draft": .string(draft),
            "draft_characters": .int(Int64(draft.count)),
        ]
        if let reason = QuietChatSessionCommands.queuePauseReason(sessionID, appModel) { body["queue_paused_reason"] = .string(reason) }
        let presentation = await appModel.quietComposerPresentationState(sessionID: sessionID)
        body.merge(presentation) { _, field in field }
        return body
    }

    /// The same effect-free fences admit both preview and execution.
    @MainActor
    public static func fence<Host: QuietComposerCommandPort>(
        verb: String, value: String, sessionId: String, reachesUser: Bool, turnSessionId: String, appModel: Host
    ) -> (session: String, refusal: Outcome?) {
        if !reachesUser, usersScreenVerbs.contains(verb) {
            return ("", .refuse(
                verb, "owners_screen",
                "That moves the person's screen, and they did not start this turn. Ask them, or tell them "
                + "where it is (app {page} reads any page without showing it)."
            ))
        }
        if !reachesUser, verb == "speak" {
            return ("", .refuse(
                "read aloud", "owners_ears",
                "Speaking out loud interrupts the person, and they did not start this turn. Ask them, "
                + "or say it in your reply."
            ))
        }
        switch verb {
        case "show_pane":
            // User closing the pane wins for the rest of that turn.
            let turnID = appModel.macChatTurns.activeTurnIDsBySession[turnSessionId]
            if appModel.quietComposerPaneClosed(turnID: turnID) {
                return ("", .refuse("Work pane", "owner_closed_pane", "The person closed the Work pane this turn, so it stays closed."))
            }
            return ("", nil)
        case "set_draft", "send":
            let element = verb == "send" ? "send button" : "composer draft"
            var sessionID = appModel.activeChatSessionId
            if !sessionId.isEmpty {
                switch QuietChatSessionCommands.resolve(sessionId, appModel: appModel) {
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
            if !reachesUser, QuietChatSessionCommands.userIsIn(sessionID, appModel),
               verb == "set_draft" || value.isEmpty {
                return (sessionID, .refuse(
                    element, "owners_draft",
                    "The person is in that conversation, so its draft and attached files are theirs. "
                    + (verb == "send" ? "Pass your own text in value." : "Ask them first, or send your own text with send and value.")
                ))
            }
            return (sessionID, nil)
        case "write_scratch":
            // The asking turn's own conversation (the one scratchpad_read
            // reads), or the one she named. A conversation User is in is his,
            // as his draft is, unless the turn reaches him.
            var sessionID = turnSessionId
            if !sessionId.isEmpty {
                guard case .success(let found) = QuietChatSessionCommands.resolve(sessionId, appModel: appModel) else {
                    return ("", .refuse("/scratch", "unknown_session",
                                        "No open conversation has that id or title. chat.list lists them with their ids."))
                }
                sessionID = found.id
            }
            guard !sessionID.isEmpty else {
                return ("", .refuse("/scratch", "no_conversation", "This turn has no conversation of its own: pass session_id."))
            }
            if !reachesUser, QuietChatSessionCommands.userIsIn(sessionID, appModel) {
                return (sessionID, .refuse(
                    "/scratch", "owners_draft",
                    "The person is in that conversation, so its scratch is theirs. Ask them first, or write in a conversation they are not in."
                ))
            }
            return (sessionID, nil)
        default:
            return ("", nil)
        }
    }

    @MainActor
    public static func run<Host: QuietComposerCommandPort>(
        verb: String, value: String, choice: String,
        sessionId: String = "", attachments: [URL] = [], reachesUser: Bool = false,
        turnSessionId: String = "", appModel: Host
    ) async -> Outcome {
        let fenced = fence(verb: verb, value: value, sessionId: sessionId, reachesUser: reachesUser,
                           turnSessionId: turnSessionId, appModel: appModel)
        if let refusal = fenced.refusal { return refusal }
        let sessionID = fenced.session
        switch verb {
        case "set_draft", "send":
            let revision = appModel.quietComposerDraftRevision(sessionID)
            let draft = appModel.quietComposerDraft(sessionID)
            let attachmentIDs = (appModel.chatPendingAttachments[sessionID] ?? []).map(\.id)
            var files: [NativeAgentShared.MultimodalAttachment] = []
            for url in attachments {
                let read: Result<NativeAgentShared.MultimodalAttachment, ChatAttachmentTypeResolver.AttachmentRefusal>
                switch ChatAttachmentTypeResolver.attachmentKind(url, resolveType: ChatAttachmentTypeResolver.typeAndMime) {
                case .success(let kind): read = await ChatAttachmentTypeResolver.readAttachment(url, kind: kind)
                case .failure(let refusal): read = .failure(refusal)
                }
                switch read {
                case .success(let file): files.append(file)
                case .failure(let refusal):
                    return .refuse("attach button", "attachment_refused", refusal.message + " Nothing was changed.")
                }
            }
            // File intake suspends. Ownership and the exact draft being
            // changed must still hold in this synchronous mutation step.
            let current = fence(verb: verb, value: value, sessionId: sessionID, reachesUser: reachesUser,
                                turnSessionId: turnSessionId, appModel: appModel)
            if let refusal = current.refusal { return refusal }
            if current.session != sessionID || ((verb == "set_draft" || value.isEmpty)
                && (appModel.quietComposerDraftRevision(sessionID) != revision
                    || appModel.quietComposerDraft(sessionID) != draft
                    || (appModel.chatPendingAttachments[sessionID] ?? []).map(\.id) != attachmentIDs)) {
                return .refuse("composer draft", "draft_changed",
                               "The conversation or draft changed while attachments were being read. Nothing was changed.")
            }
            return verb == "send"
                ? await send(value, sessionID: sessionID, files: files, appModel: appModel)
                : setDraft(value, sessionID: sessionID, files: files, appModel: appModel)
        case "set_model", "set_think", "set_fast":
            // Bot conversations use their own route, so the global tuple cannot change it.
            if SessionConversation.isHelper(appModel.activeChatSessionId) {
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
        case "open_card", "close_card", "set_page", "show_browser", "show_pane", "hide_pane":
            return await appModel.quietComposerPresentation(verb: verb, value: value, choice: choice)
        case "set_persona": return setPersona(value, appModel: appModel)
        case "speak": return await speak(value, appModel: appModel)
        case "write_scratch":
            return await writeScratch(key: choice, value: value, sessionID: sessionID, appModel: appModel)
        case "check_updates":
            return await appModel.quietComposerPresentation(verb: verb, value: value, choice: choice)
        default:
            return .refuse(
                "composer", "unknown_verb",
                "No composer verb is called that. The verbs are: "
                + names.joined(separator: ", ") + "."
            )
        }
    }

    /// Files preserve an existing draft when no text is supplied.
    @MainActor
    private static func setDraft<Host: QuietComposerCommandPort>(
        _ text: String, sessionID: String, files: [NativeAgentShared.MultimodalAttachment], appModel: Host
    ) -> Outcome {
        guard !sessionID.isEmpty else {
            return .refuse("composer draft", "no_conversation", "No conversation is open.")
        }
        let before = appModel.quietComposerDraft(sessionID)
        let after = text.isEmpty && !files.isEmpty ? before : text
        appModel.setQuietComposerDraft(after, sessionID: sessionID)
        if !files.isEmpty { appModel.chatPendingAttachments[sessionID, default: []].append(contentsOf: files) }
        let attached = appModel.chatPendingAttachments[sessionID]?.count ?? 0
        return .done(
            "composer draft (message box)",
            "Draft is now \(after.count) characters" + (attached == 0 ? "." : ", with \(attached) file(s) attached."),
            changed: before != after || !files.isEmpty
        )
    }

    /// Shared admission owns queueing; only accepted snapshots are cleared.
    @MainActor
    private static func send<Host: QuietComposerCommandPort>(
        _ value: String, sessionID: String,
        files: [NativeAgentShared.MultimodalAttachment], appModel: Host
    ) async -> Outcome {
        guard !sessionID.isEmpty else {
            return .refuse("send button", "no_conversation", "No conversation is open.")
        }
        let fromDraft = value.isEmpty
        let message = fromDraft ? appModel.quietComposerDraft(sessionID) : value
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
        var origin = QuietChatSessionCommands.agentOrigin
        origin.peerSources = steer.sources
        origin.elevatedPeerSources = steer.elevated
        let acceptance = await Task.detached { [appModel, message, all, sessionID, origin] in
            await startAgentTurn(message, attachments: all, sessionID: sessionID, origin: origin, appModel: appModel)
        }.value
        switch acceptance {
        case .accepted(let accepted), .queued(let accepted, _):
            if fromDraft {
                appModel.clearQuietAcceptedDraft(message, sessionID: accepted, editedAt: editedAt)
            }
            let sent = Set(staged.map(\.id))
            appModel.chatPendingAttachments[sessionID]?.removeAll { sent.contains($0.id) }
            if case .queued = acceptance {
                return .done("send button", "Queued in \(accepted): it runs after the reply in progress.")
            }
            return .done("send button", "Sent into \(accepted).")
        case .rejected(let message):
            return reconcileFailure("send button", "send_rejected", message,
                instruction: "Read the conversation and its queue to resolve this rejection before sending again.",
                next: ["page": .string("chat"), "item": .string(sessionID)], effects: .none)
        }
    }

    /// Reply routing stays detached; the caller's peer steering rides the send.
    @MainActor
    private static func startAgentTurn<Host: QuietComposerCommandPort>(
        _ message: String, attachments: [NativeAgentShared.MultimodalAttachment],
        sessionID: String, origin: ChatMessageOrigin, appModel: Host
    ) async -> MacChatTurnAcceptance {
        await appModel.startChatTurn(
            message, attachments: attachments, sessionId: sessionID,
            hideUserBubble: false, requireActiveSession: false,
            origin: origin
        ).acceptance
    }

    @MainActor
    private static func setFast<Host: QuietComposerCommandPort>(_ raw: String, appModel: Host) async -> Outcome {
        guard let on = ["on": true, "true": true, "off": false, "false": false][raw.lowercased()] else {
            return .refuse("model card Fast toggle", "unknown_value", "Pass on or off in value.")
        }
        guard appModel.quietComposerSupportsFast else {
            return .refuse(
                "model card Fast toggle", "no_fast",
                "\(appModel.chatModel) has no Fast mode. Pick a model that has it with set_model first."
            )
        }
        let changed = appModel.chatFastMode != on
        appModel.chatFastMode = on
        let result = await appModel.saveQuietChatBrain()
        if !result.succeeded {
            return reconcileFailure("model card Fast toggle", "fast_write_failed", result.agentMessage,
                instruction: "Read the saved Chat model settings and resolve the save error before changing Fast again.", next: ["page": .string("providers")])
        }
        return .done("model card Fast toggle", "Fast is now \(appModel.chatFastMode ? "on" : "off") for every chat (app-wide default).", changed: changed)
    }

    /// The visible picker owns the provider/model transaction.
    @MainActor
    private static func setModel<Host: QuietComposerCommandPort>(provider: String, model: String, appModel: Host) async -> Outcome {
        let groups = appModel.quietComposerProviderGroups
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
        // Receipts wait for the canonical selection to land.
        guard let write = appModel.selectQuietComposerModel(item, provider: provider) else {
            return .refuse(
                "model pane", "model_saving",
                "Another model change took the tuple first; nothing was changed."
            )
        }
        if let failure = await write.value {
            return reconcileFailure(
                "model pane row \"\(item.displayName)\" under \(group.provider)", "model_write_failed", failure,
                instruction: "Read the saved Chat model selection and resolve the save error before changing it again.", next: ["page": .string("providers")])
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
    private static func setThink<Host: QuietComposerCommandPort>(_ effort: String, appModel: Host) async -> Outcome {
        let efforts = appModel.quietComposerEfforts
        guard let index = efforts.firstIndex(where: { $0.id == effort }) else {
            return .refuse(
                "think card", "unknown_think_level",
                "This model's thinking levels are: " + efforts.map(\.id).joined(separator: ", ")
            )
        }
        let before = appModel.chatReasoningEffort
        appModel.chatReasoningEffort = effort
        let result = await appModel.saveQuietChatBrain()
        guard result.succeeded else {
            return reconcileFailure("think card", "think_write_failed", result.agentMessage,
                instruction: "Read the saved Chat model settings and resolve the save error before changing Think again.", next: ["page": .string("providers")])
        }
        return .done(
            "think card step \"\(efforts[index].label)\"",
            "Thinking is now \(result.reasoningEffort) for every chat (app-wide default).",
            changed: before != result.reasoningEffort
        )
    }

    @MainActor
    private static func setPersona<Host: QuietComposerCommandPort>(_ raw: String, appModel: Host) -> Outcome {
        let name = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty else {
            return .refuse("/persona", "missing_persona", "Pass the persona name in value. It is now \(appModel.chatPersona).")
        }
        let changed = appModel.chatPersona != name
        appModel.chatPersona = name
        return .done("/persona", "Chat persona is now \(appModel.chatPersona).", changed: changed)
    }

    @MainActor
    private static func speak<Host: QuietComposerCommandPort>(_ text: String, appModel: Host) async -> Outcome {
        guard !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            return .refuse("read aloud", "nothing_to_say", "Pass the words to say in value.")
        }
        guard !VoicePreference.quiet() else {
            return .refuse(
                "read aloud", "quiet_mode",
                "Quiet mode is on (chat.quiet_mode), so nothing plays. Say it in your reply instead."
            )
        }
        if let failure = await appModel.startQuietSpeech(text) {
            return reconcileFailure("read aloud", "speak_failed", failure,
                instruction: "Check playback and the reported speech error before speaking again; completion is unverified.", next: ["page": .string("settings")])
        }
        return .done("read aloud", "Started reading \(text.count) characters aloud. Playback completion is not confirmed.", status: "started")
    }

    private static func reconcileFailure(_ element: String, _ code: String, _ detail: String,
                                         instruction: String, next: [String: JSONValue], effects: ToolFailureError.Effects = .unknown) -> Outcome {
        var outcome = Outcome.refuse(element, code, detail, effects: effects)
        outcome.remedy = Repair.reconcile(instruction: instruction,
            nextCall: .object(["tool": .string("app"), "input": .object(next)]))
        return outcome
    }

    @MainActor
    private static func writeScratch<Host: QuietComposerCommandPort>(key: String, value: String, sessionID: String, appModel: Host) async -> Outcome {
        let key = key.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !key.isEmpty, !key.contains(" "), !value.isEmpty else {
            return .refuse("/scratch", "missing_scratch", "Pass the key (one word) in choice and the text in value.")
        }
        let result = await appModel.writeQuietScratch(key: key, value: value, sessionId: sessionID)
        guard result.succeeded else { return reconcileFailure("/scratch", "scratch_write_failed", result.agentMessage,
            instruction: "Read this scratch key and resolve the save error before writing again.",
            next: ["action": .string("chat.scratch_read"), "args": .object(["key": .string(key), "session_id": .string(sessionID)])]) }
        return .done("/scratch", "Scratch \(key) is set in \(sessionID); app chat.scratch_read reads it back.")
    }
}
