import AppKit
import AuthoredCapabilities
import BackgroundLoops
import BackgroundWork
import Foundation
import MacIntegration
import NativeAgentCore
import NativeAgentShared
import ProviderRouting
import TelegramBot
// Blueprint: | `ConnectorFace+Telegram.swift` | Connectors' Telegram rows: transport health, the person's levers (on, token card, who may reach, mention, model), receipts, blocked and errors; each row is a door call, and the Telegram verbs no other verb runs run here |

/// One summary for a cleared diagnostics receipt, for the face and the Mac's own Telegram receipts.
public enum TelegramClearLogsPresentation {
    public enum Outcome: Equatable {
        case completed(TelegramDiagnosticsClearReceipt)
        case failed(detail: String)
    }

    public static func summary(for receipt: TelegramDiagnosticsClearReceipt) -> String {
        let files = "\(receipt.removedFileCount) diagnostic \(receipt.removedFileCount == 1 ? "file" : "files")"
        let rows = "\(receipt.removedRowCount) \(receipt.removedRowCount == 1 ? "row" : "rows")"
        return "Cleared \(files) containing \(rows)."
    }
}

/// Outbound validation cannot prove inbound poller health; report them independently.
public enum TelegramTestReplyPresentation {
    public static func summary(for response: TelegramTestResponse) -> String {
        let delivery = "Telegram test sent to \(response.chatId). Bot token verified."
        guard response.pollerRegistered == true else {
            return "\(delivery) Telegram polling is not registered."
        }
        guard response.pollerTicking == true else {
            return "\(delivery) Telegram polling is registered but has not ticked yet."
        }
        return "\(delivery) Telegram polling is registered and ticking."
    }
}

extension NativeAgentEngine {
    /// The Telegram owner's files whose change re-reads the Connectors page.
    var telegramFacePaths: [URL] {
        ["config.json", "state.json", "receipts.jsonl", "blocked.jsonl", "errors.jsonl"]
            .map { dataRoot.appendingPathComponent("telegram/" + $0) }
    }

    /// A failed Telegram read stays in its section; the other connectors still draw.
    @concurrent func telegramFaceSections() async -> [PartFace.Section] {
        let status: TelegramPresentationSnapshot
        do {
            status = try await telegram.refresh()
        } catch {
            return [.init(id: "telegram", title: "Telegram", style: .list, rows: [.init(id: "telegram.unavailable",
                title: "Telegram's records could not be read.", detail: TurnSecretRedactor.redactText(error.localizedDescription), tone: .failed,
                actions: [.init(id: "refresh", label: "Read again", call: .init("telegram.refresh"))])])]
        }
        let state = await MainActor.run { (choice: providers.selection(for: "telegram"),
                                           connections: providers.connections, catalog: providers.catalog) }
        return [telegramSettingsSection(status,
            modelRows: telegramModelRows(status, choice: state.choice, connections: state.connections, catalog: state.catalog))]
            + telegramRecordSections(status)
    }

    private func telegramSettingsSection(_ status: TelegramPresentationSnapshot, modelRows: [PartFace.Row]) -> PartFace.Section {
        // A face carries source times, never words recalculated from the moment it was read.
        func moment(_ iso: String?) -> String {
            guard let iso else { return "None" }
            guard let date = UserDisplayFormatters.parseISOTimestamp(iso) else { return iso }
            return date.formatted(date: .abbreviated, time: .shortened)
        }
        let allowed = status.allowedChatIds.count + status.allowedUserIds.count
        var health = [
            "Bot token " + (status.tokenConfigured ? "configured" : "missing"),
            allowed == 0 ? "No allowed chat or user yet" : "\(allowed) allowed \(allowed == 1 ? "recipient" : "recipients")",
            "Poller: " + (status.pollerEnabled ? "Running" : "Disabled"),
            "Last update: " + (status.lastSeenUpdateId.map(String.init) ?? "None"),
            "Last reply: " + moment(status.lastReplyAt),
        ]
        if let cleared = status.lastDiagnosticsClearedAt { health.append("Diagnostics cleared: " + moment(cleared)) }
        var actions: [PartFace.Action] = [.init(id: "refresh", label: "Refresh", call: .init("telegram.refresh"))]
        if status.tokenConfigured && status.enabled && allowed > 0 {
            actions.append(.init(id: "test", label: "Send a test reply", call: .init("telegram.test")))
        }
        // Telegram's switches are its settings: the same setting.set the agent's door makes, with the new position as the value.
        func setting(_ id: String) -> PartFace.Call { .init("setting.set", ["setting": .string(id)]) }
        var rows: [PartFace.Row] = [.init(id: "telegram.on", title: "Telegram is on", detail: health.joined(separator: "\n"),
            value: status.enabled ? "On" : "Off", symbol: "paperplane",
            tone: status.isOperational ? .live : status.enabled ? .attention : .quiet, actions: actions,
            control: .toggle(status.enabled, confirm: status.enabled ? nil : """
                Telegram can reply to allowed chats and users when on, and to everyone in an allowed group.
                """, call: setting("telegram.enabled")))]
        if let issue = status.credentialIssue {
            rows.append(.init(id: "telegram.credential", title: "The saved bot token could not be read", detail: issue, tone: .failed))
        }
        if let message = status.pollStatusMessage {
            rows.append(.init(id: "telegram.poll", title: status.isTransientPollInterruption ? "Polling is retrying" : "Polling reported an error",
                detail: message, tone: status.isTransientPollInterruption ? .attention : .failed))
        }
        var token: [PartFace.Action] = [.init(id: "token", label: status.tokenConfigured ? "Replace bot token" : "Enter bot token",
                                              role: status.tokenConfigured ? .plain : .primary, call: .init("telegram.token"))]
        if status.tokenConfigured {
            token.append(.init(id: "disconnect", label: "Disconnect Telegram", role: .destructive, call: .init("telegram.disconnect")))
        }
        rows.append(.init(id: "telegram.token", title: "Bot token", detail: status.tokenConfigured
            ? "Saved in the keychain. A new token goes on its key-entry card in chat, never on this page. Disconnect removes it and turns Telegram off."
            : "Paste a BotFather token on its key-entry card in chat; it never enters this page.",
            value: status.tokenConfigured ? "Saved" : "Missing", symbol: "key", tone: status.tokenConfigured ? .done : .attention, actions: token))
        rows.append(.init(id: "telegram.chats", title: "Allowed chat IDs",
            detail: "Only these chats and the users below can message me; everyone in an allowed group can. Separate IDs with commas.",
            tone: allowed == 0 ? .attention : nil,
            control: .field(status.allowedChatIds.joined(separator: ", "), placeholder: "Numeric chat IDs",
                            call: .init("telegram.allowlist", ["list": .string("chats")]))))
        rows.append(.init(id: "telegram.users", title: "Allowed user IDs",
            control: .field(status.allowedUserIds.joined(separator: ", "), placeholder: "Numeric user IDs",
                            call: .init("telegram.allowlist", ["list": .string("users")]))))
        if !status.enabled {
            rows.append(.init(id: "telegram.sender", title: "Find your chat ID", detail: """
                With Telegram off and the bot token saved, send the bot a message in Telegram, then check sender: its numeric chat ID appears \
                under Blocked and ignored. Admit only a sender you recognize, then turn Telegram on.
                """, symbol: "person.crop.circle.badge.questionmark",
                actions: [.init(id: "check", label: "Check sender", call: .init("telegram.check_sender"))]))
        }
        rows.append(.init(id: "telegram.mention", title: "Only answer when mentioned in a group",
            value: status.requireMention ? "On" : "Off",
            control: .toggle(status.requireMention, confirm: status.requireMention
                ? "Without a required mention, Telegram can reply in allowed groups without being mentioned." : nil,
                call: setting("telegram.require_mention"))))
        rows += modelRows
        if let voice = status.voiceTranscription {
            rows.append(.init(id: "telegram.voice", title: "Voice", detail: voice.enabled
                ? "Allow speech recognition on this Mac to transcribe Telegram voice messages. Microphone access is not needed." : nil,
                value: voice.enabled ? "\(voice.model) via \(voice.backend)" : "Disabled", symbol: "waveform",
                actions: voice.enabled ? [.init(id: "voice", label: "Set up Telegram voice", doors: ["mac"], call: .init("telegram.voice_setup"))]
                    : nil))
        }
        rows.append(.init(id: "telegram.logs", title: "Telegram diagnostics",
            detail: "Clearing permanently removes recent replies, blocked-message records, errors and diagnostic logs from this Mac.",
            symbol: "trash", actions: [.init(id: "clear", label: "Clear logs", role: .destructive, call: .init("telegram.clear_logs"))]))
        return .init(id: "telegram", title: "Telegram", style: .list, rows: rows)
    }

    private func telegramModelRows(_ status: TelegramPresentationSnapshot, choice: ProviderTurnChoice,
                                  connections: [ProviderInfo], catalog: ModelCatalogResponse?) -> [PartFace.Row] {
        let models = ProvidersFacade.modelOptions(providers: connections, providerID: choice.provider, current: choice.model, limit: 40)
        let efforts = ProvidersFacade.reasoningOptions(from: catalog, providers: connections,
                                                      providerID: choice.provider, model: choice.model)
        let normalized = ProvidersFacade.normalizedReasoningEffort(from: catalog, providers: connections,
            providerID: choice.provider, model: choice.model, selected: choice.reasoningEffort)
        // The model's choice and field, and the thinking level, call telegram.choose with their setting and the new value.
        let model = PartFace.Call("telegram.choose", ["setting": .string("model")])
        var rows: [PartFace.Row] = [.init(id: "telegram.model", title: "Model",
            detail: status.routingIssue.map { "Routing unavailable: " + $0 }, tone: status.routingIssue == nil ? nil : .failed,
            control: .choice(models.map { .init(id: $0.id, label: $0.displayName) }, selected: choice.model, call: model))]
        rows.append(.init(id: "telegram.model-id", title: "Or paste a model ID",
            detail: "The list stays short so it opens fast. Paste any provider's model ID here if it is not listed.",
            control: .field(choice.model, placeholder: "Model ID", call: model)))
        if !efforts.isEmpty {
            rows.append(.init(id: "telegram.think", title: "How hard it thinks",
                detail: normalized == choice.reasoningEffort ? nil
                    : "Saved think level '\(choice.reasoningEffort)' is unsupported for \(choice.model). Choose a level to use \(normalized).",
                tone: normalized == choice.reasoningEffort ? nil : .attention,
                control: .choice(efforts.map { .init(id: $0.id, label: $0.label) }, selected: choice.reasoningEffort,
                                 call: .init("telegram.choose", ["setting": .string("think")]))))
        }
        rows.append(.init(id: "telegram.commands", title: "Commands in the chat", value: "/model, /think, /fast, /brain", tone: .quiet))
        return rows
    }

    private func telegramRecordSections(_ status: TelegramPresentationSnapshot) -> [PartFace.Section] {
        func hidden(_ total: Int, _ shown: Int, _ noun: String) -> String? {
            total > shown ? "\(total - shown) older \(noun) are not shown." : nil
        }
        var replies: [PartFace.Row] = status.receiptsIssue.map { [PartFace.Row(id: "telegram.replies-issue", title: $0, tone: .failed)] } ?? []
        if status.receipts.isEmpty {
            replies.append(.init(id: "telegram.replies-empty", title: status.receiptsIssue == nil
                ? "Replies I send over Telegram will be listed here." : "No readable reply records are available.", tone: .quiet))
        }
        replies += status.receipts.prefix(6).map { receipt -> PartFace.Row in
            PartFace.Row(id: "telegram.reply:" + receipt.id, title: "\(receipt.kind ?? "reply") · chat \(receipt.chatId ?? "unknown")",
                  detail: [receipt.replyPreview ?? receipt.textPreview ?? "",
                           receipt.model.map { "\($0) / \(receipt.reasoningEffort ?? "default")" } ?? ""]
                      .filter { !$0.isEmpty }.joined(separator: "\n"), at: receipt.at)
        }
        let allowedChats = Set(status.allowedChatIds)
        var blocked: [PartFace.Row] = status.blockedIssue.map { [PartFace.Row(id: "telegram.blocked-issue", title: $0, tone: .failed)] } ?? []
        if status.blocked.isEmpty {
            blocked.append(.init(id: "telegram.blocked-empty", title: status.blockedIssue == nil
                ? "Messages turned away by the allowlist will be listed here." : "No readable blocked-message records are available.", tone: .quiet))
        }
        blocked += status.blocked.prefix(6).map { event -> PartFace.Row in
            let admit = event.chatId.flatMap { Int64($0) != nil && !allowedChats.contains($0) ? $0 : nil }
            return PartFace.Row(id: "telegram.blocked:" + event.id, title: "\(event.reason ?? "blocked") · chat \(event.chatId ?? "unknown")",
                         detail: event.textPreview, at: event.at,
                         actions: admit.map { [.init(id: "allow", label: "Allow chat ID " + $0, role: .primary,
                                                     call: .init("telegram.allow_chat", ["chat": .string($0)]))] })
        }
        var sections: [PartFace.Section] = [
            .init(id: "telegram-replies", title: "Recent Telegram replies", style: .timeline,
                  footer: hidden(status.receipts.count, 6, "replies"), rows: replies, folded: true),
            .init(id: "telegram-blocked", title: "Blocked and ignored on Telegram", style: .timeline,
                  footer: hidden(status.blocked.count, 6, "blocked messages"), rows: blocked, folded: true),
        ]
        if status.errorsIssue != nil || !status.errors.isEmpty {
            var errors: [PartFace.Row] = status.errorsIssue.map { [PartFace.Row(id: "telegram.errors-issue", title: $0, tone: .failed)] } ?? []
            if status.errors.isEmpty {
                errors.append(.init(id: "telegram.errors-empty", title: "No readable Telegram errors are available.", tone: .quiet))
            }
            errors += status.errors.prefix(4).map { event -> PartFace.Row in
                PartFace.Row(id: "telegram.error:" + event.id, title: event.context ?? "telegram", detail: event.error, at: event.at, tone: .failed)
            }
            sections.append(.init(id: "telegram-errors", title: "Recent Telegram errors", style: .timeline,
                                  footer: hidden(status.errors.count, 4, "errors"), rows: errors, folded: true))
        }
        return sections
    }

    /// `telegram.refresh`: reads the Telegram owner again.
    @MainActor func telegramRefresh() async throws -> String? {
        try await telegramVerb {
            _ = try await telegram.refresh()
            return nil
        }
    }

    /// `telegram.token`: the bot token goes onto its key-entry card in the open conversation, never through a page.
    @MainActor func telegramToken(turn: Turn) async throws -> String? {
        try await telegramVerb {
            try await connectors.raiseSetupCard("telegram", name: "Telegram",
                why: "You asked to enter the Telegram bot token.", origin: "face:connectors:telegram.token", turn: turn)
        }
    }

    /// `telegram.allowlist`: the allowed chat (`list` chats) or user (`list` users) IDs become exactly the numeric IDs given.
    @MainActor func telegramAllowlist(list: String, value: String) async throws -> String? {
        try await telegramVerb {
            guard ["chats", "users"].contains(list) else {
                throw ToolFailureError("list is chats or users. Nothing was saved.", argumentPath: "list", effects: .none, code: "bad_value")
            }
            let saved = try await telegram.refresh()
            let parsed = parseTelegramNumericIDs(value)
            guard parsed.invalidTokens.isEmpty else {
                throw ToolFailureError("""
                    These are not usable IDs: \(parsed.invalidTokens.joined(separator: ", ")). Use the numeric chat or user ID. Nothing was saved.
                    """, argumentPath: "value", effects: .none, code: "bad_ids")
            }
            if list == "chats" { try await saveTelegramLever(saved, chats: parsed.canonicalIDs) }
            else { try await saveTelegramLever(saved, users: parsed.canonicalIDs) }
            return nil
        }
    }

    /// `telegram.allow_chat`: a chat Telegram turned away (it is under Blocked and ignored) may message the agent.
    @MainActor func telegramAllowChat(_ chat: String) async throws -> String? {
        try await telegramVerb {
            let saved = try await telegram.refresh()
            guard saved.blocked.contains(where: { $0.chatId == chat }), Int64(chat) != nil else {
                throw PartCallError(code: "stale_row", message: "That blocked message is no longer readable. Refresh Connectors before allowing it.")
            }
            try await saveTelegramLever(saved, chats: saved.allowedChatIds + [chat])
            return "Chat \(chat) may now message me" + (saved.enabled ? "." : " once Telegram is on.")
        }
    }

    /// `telegram.check_sender`: who messaged the bot appears under Blocked and ignored, to admit there.
    @MainActor func telegramCheckSender() async throws -> String? {
        try await telegramVerb {
            let found = try await telegram.discoverTelegramSenders(token: "")
            return found == 0 ? "No messages found. Send your bot a message, then check again."
                : "Sender IDs are under Blocked and ignored. Allow your chat ID there."
        }
    }

    /// `telegram.choose`: Telegram's model (`setting` model: any provider's model ID, keeping a thinking level it supports) or its
    /// thinking level (`setting` think).
    @MainActor func telegramChoose(setting: String, value: String) async throws -> String? {
        try await telegramVerb {
            let saved = try await telegram.refresh()
            switch setting {
            case "model":
                guard !value.isEmpty else { throw PartCallError(code: "bad_value", message: "Choose or paste a model ID. Nothing was saved.") }
                let choice = providers.selection(for: "telegram")
                let effort = ProvidersFacade.normalizedReasoningEffort(from: providers.catalog, providers: providers.connections,
                    providerID: choice.provider, model: value, selected: choice.reasoningEffort)
                try await saveTelegramLever(saved, model: value, effort: effort)
            case "think":
                guard !value.isEmpty else { throw PartCallError(code: "bad_value", message: "Choose a think level. Nothing was saved.") }
                try await saveTelegramLever(saved, model: providers.selection(for: "telegram").model, effort: value)
            default: throw PartCallError(code: "bad_value", message: "setting is model or think. Nothing was saved.")
            }
            return nil
        }
    }

    /// `telegram.voice_setup`: macOS asks for speech recognition in the foreground, so Telegram voice messages can be transcribed.
    @MainActor func telegramVoiceSetup() async throws -> String? {
        try await telegramVerb {
            NSApp.activate()
            switch await SystemPermissionPreflight.requestSpeechRecognitionIfNotDetermined() {
            case .granted:
                await NativeAgentEngine.retireSystemPermissionCardIfGranted(dataRoot: dataRoot)
                return "Speech recognition is ready for Telegram voice messages."
            case .denied: return "Enable NativeAgent in System Settings → Privacy & Security → Speech Recognition."
            case .restricted: return "Speech recognition is restricted on this Mac."
            case .notDetermined, .unknown: return "Speech recognition permission was not resolved. Try setup again."
            }
        }
    }

    /// A Telegram verb's failure is the owner's words; any other error is redacted.
    @MainActor private func telegramVerb(_ body: () async throws -> String?) async throws -> String? {
        do { return try await body() }
        catch let error as ToolFailureError { throw error }
        catch let error as PartCallError { throw error }
        catch { throw PartCallError(code: "telegram_action_failed", message: TurnSecretRedactor.redactText(error.localizedDescription)) }
    }

    /// Saves one changed lever over the saved settings; the saved token is kept and the poller restarts on the new authority.
    private func saveTelegramLever(_ saved: TelegramPresentationSnapshot, chats: [String]? = nil, users: [String]? = nil,
                                   model: String = "", effort: String = "") async throws {
        try await telegram.configureTelegram(token: "", allowedChatIds: chats ?? saved.allowedChatIds,
            allowedUserIds: users ?? saved.allowedUserIds, requireMention: saved.requireMention,
            model: model, reasoningEffort: effort, enabled: saved.enabled,
            restartPollLoop: { _ = await NativeAgentEngine.restartBackgroundLoop(id: "telegram_poll") })
    }
}
