import ChatOrchestration
import Foundation
import PersistenceCore
import TelegramBot

/// The token-paste half of a connector's setup, for the inline card.
///
/// The fields are the ones each connector's own setup page asks for
/// (ConnectorWizardView for GitHub, Notion and Slack; TelegramView for
/// Telegram), and the save is that page's own writer and check. The card is a
/// second door into the same room: nothing here stores or validates on its
/// own. What comes back is only "done, and how it was checked" or one fixed
/// reason class — never a service's own error text, which can echo a token
/// back. The agent learns connected or failed, never the secret.
@MainActor
enum InlineConnectorSetup {

    nonisolated static func fields(for connector: String) -> [InlineCardField] {
        // Notion, Slack and Telegram write files under the data root; only
        // GitHub's token goes to the Keychain.
        let stays = "Your key stays on this Mac. It never goes into the chat."
        switch InlineInteractionRegistry.canonicalConnectorID(connector) {
        case "telegram":
            return [
                InlineCardField(label: "Bot token", placeholder: "123456789:ABC… from @BotFather",
                                helper: stays, id: "token"),
                InlineCardField(label: "Allowed chat ID (optional)", placeholder: "Numeric chat ID",
                                helper: "Only allowed chats can message the agent. Leave blank to add one later.",
                                isSecret: false, id: "allowed_chat_id", isOptional: true),
            ]
        case "notion":
            return [
                InlineCardField(label: "Notion integration token", placeholder: "ntn_... or secret_...",
                                helper: "Share the pages it should see with the integration. " + stays,
                                id: "token"),
            ]
        case "github":
            return [
                InlineCardField(label: "Or use a personal access token",
                                placeholder: "ghp_... or github_pat_...",
                                helper: "Saved in your Mac's Keychain, never in this conversation.",
                                id: "token"),
            ]
        case "slack":
            return [
                InlineCardField(label: "Slack bot token", placeholder: "xoxb-...", helper: stays, id: "token"),
                InlineCardField(label: "Socket Mode app token (optional)", placeholder: "xapp-...",
                                helper: "Only needed for inbound Slack chat.",
                                id: "app_token", isOptional: true),
                InlineCardField(label: "Allowed channel IDs", placeholder: "C0123, C0456",
                                isSecret: false, id: "allowed_channels", isOptional: true),
                InlineCardField(label: "Allowed user IDs", placeholder: "U0123",
                                helper: "Add at least one channel or user.",
                                isSecret: false, id: "allowed_users", isOptional: true),
            ]
        default:
            return []
        }
    }

    /// `error` is a fixed reason class once `save` returns; `note` is how it
    /// was verified.
    struct Outcome {
        var error: String?
        var note: String?
    }

    static func save(
        connector rawConnector: String,
        values: [String: String],
        appModel: AppModel,
        dataRoot: URL
    ) async -> Outcome {
        let connector = InlineInteractionRegistry.canonicalConnectorID(rawConnector)
        func value(_ id: String) -> String {
            (values[id] ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        }
        func ids(_ raw: String) -> [String] {
            raw.split { $0 == "," || $0 == ";" || $0.isWhitespace }.map(String.init)
        }
        let token = value("token")
        var outcome: Outcome
        switch connector {
        case "notion":
            let result = await NativeOAuthFlow.saveNotionToken(token, dataRoot: dataRoot)
            outcome = result.ok ? Outcome(note: "token checked with Notion")
                : Outcome(error: result.error ?? "Notion rejected the token.")
        case "github":
            let result = await NativeOAuthFlow.saveGitHubToken(token, dataRoot: dataRoot)
            outcome = result.ok ? Outcome(note: "token checked with GitHub")
                : Outcome(error: result.error ?? "GitHub rejected the token.")
        case "slack":
            let appToken = value("app_token")
            let result = await NativeOAuthFlow.saveSlackToken(
                token,
                appToken: appToken.isEmpty ? nil : appToken,
                allowedChannelIds: Set(ids(value("allowed_channels"))),
                allowedUserIds: Set(ids(value("allowed_users"))),
                requireMention: SlackSocketModeConfig.loadIngressPolicy(dataRoot: dataRoot).requireMention,
                dataRoot: dataRoot
            )
            if result.ok {
                _ = await BackgroundLoopsManager.shared.restartLoop(id: "slack_socket_mode")
                outcome = Outcome(note: "token checked with Slack")
            } else {
                outcome = Outcome(error: result.error ?? "Slack rejected the token.")
            }
        case "telegram":
            outcome = await saveTelegram(token: token, chatID: value("allowed_chat_id"),
                                         appModel: appModel, dataRoot: dataRoot)
        default:
            outcome = Outcome(error: "This card can't set up \(connector). Use Open full setup.")
        }
        await appModel.refreshForSidebarItem(.connectors)
        if let raw = outcome.error {
            outcome.error = failureReason(
                raw,
                service: InlineInteractionRegistry.connectorDisplayName(connector, dataRoot: dataRoot),
                typed: Array(values.values)
            )
        }
        return outcome
    }

    /// A failure as one fixed reason class. The raw text goes to the local log
    /// only, through the chat secret redactor with every typed value removed
    /// too; it never reaches the card, the transcript or the agent.
    nonisolated static func failureReason(
        _ raw: String, service: String, secret: String = "token", typed: [String] = [],
        otherwise: String? = nil
    ) -> String {
        var logged = TurnTraceRedactor.redactText(raw)
        for value in typed where value.count >= 6 {
            logged = logged.replacingOccurrences(of: value, with: "[redacted]")
        }
        NSLog("[inline-setup] \(service) failed: \(logged)")
        let text = raw.lowercased()
        func has(_ words: String...) -> Bool { words.contains { text.contains($0) } }
        // App-side allowlist checks, not service text: the person can fix these.
        if has("at least one allowed", "allowed chat id", "allowed user id", "allowlist") {
            return "\(service) needs a valid allowed chat, channel or user ID."
        }
        if has("could not connect", "couldn't connect", "cannot connect", "network connection",
               "timed out", "offline", "not connected to the internet", "hostname", "could not be found",
               "unreachable") {
            return "Couldn't reach \(service)."
        }
        // Before the scope check: the format hints name "OAuth & Permissions".
        if has("401", "reject", "unauthorized", "such as", "botfather", "isn't a setup token",
               "enter a valid", "not a valid", "invalid_auth", "invalid token", "invalid api key",
               "incorrect api key", "didn't accept", "not_authed", "bad credentials") {
            return "\(service) rejected the \(secret)."
        }
        if has("scope", "permission", "forbidden", "403", "not accessible") {
            return "\(service) is missing a permission or scope this needs."
        }
        return otherwise ?? "\(service): other error (details in the app log)."
    }

    /// A pasted provider key, checked with the provider BEFORE it is saved —
    /// Providers' own probe (`testProvider` with the draft key), so a key the
    /// provider rejects is never written and never reads as connected. A
    /// provider Providers has no probe for (e.g. Codex, xAI) is saved and
    /// says so rather than claiming a check that did not happen.
    static func saveProviderKey(_ key: String, provider: String, appModel: AppModel) async -> Outcome {
        let name = InlineInteractionRegistry.providerDisplayName(provider)
        let probe: ProviderTestResult
        do {
            probe = try await appModel.testProvider(provider, apiKeyOverride: key)
        } catch {
            return Outcome(error: failureReason(
                error.localizedDescription, service: name, secret: "key", typed: [key],
                otherwise: "Couldn't reach \(name)."
            ))
        }
        if probe.tested, probe.status != "ok" {
            return Outcome(error: failureReason(
                probe.error ?? "", service: name, secret: "key", typed: [key],
                otherwise: "\(name) rejected the key."
            ))
        }
        do {
            // Providers' own configure call — the same one its sheet makes.
            // `defaultModel: nil` so saving a key never silently repoints the
            // provider at a different model.
            _ = try await appModel.configureProvider(
                provider, apiKey: key, authMode: "api_key", defaultModel: nil
            )
        } catch {
            return Outcome(error: failureReason(
                error.localizedDescription, service: name, secret: "key", typed: [key]
            ))
        }
        return Outcome(note: probe.tested ? "key checked with \(name)"
                       : "key saved; \(name) has no check to run")
    }

    /// Telegram's page saves a token and an allowlist, then sends a test
    /// reply. The card does the same, with Telegram's `getMe` first so a token
    /// Telegram does not know is never saved.
    private static func saveTelegram(
        token: String, chatID: String, appModel: AppModel, dataRoot: URL
    ) async -> Outcome {
        if let problem = TelegramBotTokenPresentation.validationMessage(for: token) {
            return Outcome(error: problem)
        }
        let username: String
        do {
            username = try await TelegramPollLoop.defaultFetchBotUsername(token)
        } catch {
            return Outcome(error: "Telegram didn't accept that bot token: \(error.localizedDescription)")
        }
        // The saved allowlist is kept; the card only ever adds to it.
        let existing = TelegramBot.TelegramConfig.loadFromDisk(dataRoot: dataRoot)
        var chats = (existing?.allowedChatIds ?? []).map(String.init)
        if !chatID.isEmpty, !chats.contains(chatID) { chats.append(chatID) }
        let users = (existing?.allowedUserIds ?? []).map(String.init)
        do {
            try await appModel.client.configureTelegram(
                token: token,
                allowedChatIds: chats,
                allowedUserIds: users,
                requireMention: existing?.requireMention ?? true,
                model: "",
                reasoningEffort: "",
                enabled: true,
                dataRoot: dataRoot
            )
        } catch {
            return Outcome(error: error.localizedDescription)
        }
        await appModel.refreshTelegram()
        guard let target = chatID.isEmpty ? (chats.first ?? users.first) : chatID else {
            return Outcome(note: "@\(username) verified; add an allowed chat ID before it can take messages")
        }
        do {
            _ = try await appModel.client.testTelegram(chatId: target, dataRoot: dataRoot)
            return Outcome(note: "@\(username) verified, test reply sent")
        } catch {
            return Outcome(error: "@\(username) is saved, but the test reply failed: \(error.localizedDescription)")
        }
    }
}
