import SenseCore
import ProviderRouting
import MindCore
import Foundation
import NativeAgentCore
import NativeAgentShared
import PersistenceCore
import DeskCore

// Blueprint: | `QuietComposerCommands.swift` | `QuietComposerCommands`; Composer commands share preview and execution fences |

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
    var chatPersona: String { get set }
    var chatReasoningEffort: String { get set }
    var chatFastMode: Bool { get set }
    var isSavingChatBrain: Bool { get }
    var quietComposerProviderGroups: [(id: String, provider: String, models: [ComposerModel])] { get }
    var quietComposerEfforts: [ComposerEffort] { get }
    var quietComposerSupportsFast: Bool { get }
    func quietComposerPresentation(verb: String) async -> QuietComposerOutcome
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

    /// The same effect-free fences admit both preview and execution.
    @MainActor
    public static func fence<Host: QuietComposerCommandPort>(
        verb: String, value: String, sessionId: String, reachesUser: Bool, turnSessionId: String, appModel: Host, turn: Turn,
        scope: QuietChatSessionScope? = nil
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
            guard scope != nil else {
                return ("", .refuse("Work pane", "window_scope_unavailable", "Read the window's pane controls before opening it."))
            }
            return ("", nil)
        case "set_draft", "send":
            let element = verb == "send" ? "send button" : "composer draft"
            var sessionID = scope.map(\.selectedSessionID) ?? appModel.activeChatSessionId
            if !sessionId.isEmpty {
                switch QuietChatSessionCommands.resolve(sessionId, appModel: appModel, turn: turn, scope: scope) {
                case .success(let found): sessionID = found.id
                case .failure:
                    return ("", .refuse(
                        element, "unknown_session",
                        "No open conversation has that id or title. chat.list lists them with their ids."
                    ))
                }
            }
            // User conversations own their drafts/files; turns without user reach send agent text without changing the user's composer.
            if !reachesUser, verb == "set_draft" || value.isEmpty {
                guard let scope else {
                    return (sessionID, .refuse(element, "window_scope_unavailable",
                        "The person's visible conversations have not been read. Their draft was not changed."))
                }
                if QuietChatSessionCommands.userIsIn(sessionID, scope: scope) {
                return (sessionID, .refuse(
                    element, "owners_draft",
                    "The person is in that conversation, so its draft and attached files are theirs. "
                    + (verb == "send" ? "Pass your own text in value." : "Ask them first, or send your own text with send and value.")
                ))
                }
            }
            return (sessionID, nil)
        case "write_scratch":
            // Scratchpad and explicit session resolution must retain user draft ownership unless the turn reaches the user.
            var sessionID = turnSessionId
            if !sessionId.isEmpty {
                guard case .success(let found) = QuietChatSessionCommands.resolve(sessionId, appModel: appModel, turn: turn, scope: scope) else {
                    return ("", .refuse("/scratch", "unknown_session",
                                        "No open conversation has that id or title. chat.list lists them with their ids."))
                }
                sessionID = found.id
            }
            guard !sessionID.isEmpty else {
                return ("", .refuse("/scratch", "no_conversation", "This turn has no conversation of its own: pass session_id."))
            }
            if !reachesUser {
                guard let scope else {
                    return (sessionID, .refuse("/scratch", "window_scope_unavailable",
                        "The person's visible conversations have not been read. Their scratch was not changed."))
                }
                if QuietChatSessionCommands.userIsIn(sessionID, scope: scope) {
                return (sessionID, .refuse(
                    "/scratch", "owners_draft",
                    "The person is in that conversation, so its scratch is theirs. Ask them first, or write in a conversation they are not in."
                ))
                }
            }
            return (sessionID, nil)
        default:
            return ("", nil)
        }
    }

    @MainActor
    public static func run<Host: QuietComposerCommandPort>(
        verb: String, value: String, choice: String,
        sessionId: String = "", reachesUser: Bool = false,
        turnSessionId: String = "", appModel: Host, turn: Turn, scope: QuietChatSessionScope? = nil
    ) async -> Outcome {
        let fenced = fence(verb: verb, value: value, sessionId: sessionId, reachesUser: reachesUser,
                           turnSessionId: turnSessionId, appModel: appModel, turn: turn, scope: scope)
        if let refusal = fenced.refusal { return refusal }
        let sessionID = fenced.session
        switch verb {
        case "set_model", "set_think", "set_fast":
            // Bot conversations use their own route, so the global tuple cannot change it.
            let helper: Bool
            do { helper = try SessionConversation.checkedIsHelper(appModel.activeChatSessionId) }
            catch { return .refuse("model card", "conversation_unavailable", """
                The conversation's owner could not be read: \(error.localizedDescription). Repair the saved session index before changing its model.
                """) }
            if helper {
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
        case "show_browser", "check_updates":
            return await appModel.quietComposerPresentation(verb: verb)
        case "set_persona": return setPersona(value, appModel: appModel)
        case "speak": return await speak(value, appModel: appModel)
        case "write_scratch":
            return await writeScratch(key: choice, value: value, sessionID: sessionID, appModel: appModel)
        default:
            return .refuse(
                "composer", "unknown_verb",
                "No composer verb is called that. The verbs are: "
                + names.joined(separator: ", ") + "."
            )
        }
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
        // Receipt the canonical landed tuple, not merely the requested selection.
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
                instruction: """
                    Check playback and the reported speech error before speaking again; completion is unverified.
                    """, next: ["page": .string("settings")])
        }
        return .done("read aloud", "Started reading \(text.count) characters aloud. Playback completion is not confirmed.", status: "started")
    }

    private static func reconcileFailure(_ element: String, _ code: String, _ detail: String,
                                         instruction: String, next: [String: JSONValue]) -> Outcome {
        var outcome = Outcome.refuse(element, code, detail, effects: .unknown)
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
