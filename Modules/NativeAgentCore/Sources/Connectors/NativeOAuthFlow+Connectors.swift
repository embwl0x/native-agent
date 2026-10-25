import ProviderRouting
import Foundation
import PersistenceCore
import TelegramBot
// Blueprint: | `NativeOAuthFlow+Connectors.swift` | `NativeOAuthFlow`: `saveInlineConnector`, a connector card's token save (Slack, Telegram) |

extension NativeOAuthFlow {
    @MainActor
    public static func saveInlineConnector(
        connector: String, service: @MainActor () -> String, values: [String: String], dataRoot: URL,
        slackRequireMention: @MainActor () throws -> Bool,
        restartSlack: @MainActor () async -> Void,
        validateTelegramToken: @MainActor (String) -> String?,
        configureTelegram: @MainActor (String, [String], [String], Bool) async throws -> Void,
        refreshTelegram: @MainActor () async -> Void,
        sendTelegramTestReply: @MainActor (String) async throws -> Void,
        refresh: @MainActor () async -> Void
    ) async -> InlineSetupOutcome {
        func value(_ id: String) -> String {
            (values[id] ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        }
        func ids(_ raw: String) -> [String] {
            raw.split { $0 == "," || $0 == ";" || $0.isWhitespace }.map(String.init)
        }
        /// Telegram's page saves a token and an allowlist, then sends a test
        /// reply. The card does the same, with Telegram's `getMe` first so a token
        /// Telegram does not know is never saved.
        func saveTelegram(token: String, chatID: String) async -> InlineSetupOutcome {
            if let problem = validateTelegramToken(token) {
                return InlineSetupOutcome(error: problem)
            }
            let username: String
            do {
                username = try await TelegramPollLoop.defaultFetchBotUsername(token)
            } catch {
                return InlineSetupOutcome(error: "Telegram didn't accept that bot token: \(error.localizedDescription)")
            }
            // The saved allowlist is kept; the card only ever adds to it.
            let existing = TelegramBot.TelegramConfig.loadFromDisk(dataRoot: dataRoot)
            var chats = (existing?.allowedChatIds ?? []).map(String.init)
            if !chatID.isEmpty, !chats.contains(chatID) { chats.append(chatID) }
            let users = (existing?.allowedUserIds ?? []).map(String.init)
            do {
                try await configureTelegram(token, chats, users, existing?.requireMention ?? true)
            } catch {
                return InlineSetupOutcome(error: error.localizedDescription)
            }
            await refreshTelegram()
            guard let target = chatID.isEmpty ? (chats.first ?? users.first) : chatID else {
                return InlineSetupOutcome(note: "@\(username) verified; add an allowed chat ID before it can take messages")
            }
            do {
                try await sendTelegramTestReply(target)
                return InlineSetupOutcome(note: "@\(username) verified, test reply sent")
            } catch {
                return InlineSetupOutcome(error: "@\(username) is saved, but the test reply failed: \(error.localizedDescription)")
            }
        }

        let token = value("token")
        var outcome: InlineSetupOutcome
        switch connector {
        case "slack":
            let requireMention: Bool
            do { requireMention = try slackRequireMention() } catch {
                outcome = InlineSetupOutcome(error: "Slack's saved policy could not be read (\(error.localizedDescription)). Nothing was changed.")
                break
            }
            let appToken = value("app_token")
            let result = await NativeOAuthFlow.saveSlackToken(
                token,
                appToken: appToken.isEmpty ? nil : appToken,
                allowedChannelIds: Set(ids(value("allowed_channels"))),
                allowedUserIds: Set(ids(value("allowed_users"))),
                requireMention: requireMention,
                dataRoot: dataRoot
            )
            if result.ok {
                await restartSlack()
                outcome = InlineSetupOutcome(note: "token checked with Slack")
            } else {
                outcome = InlineSetupOutcome(error: result.error ?? "Slack rejected the token.")
            }
        case "telegram":
            outcome = await saveTelegram(token: token, chatID: value("allowed_chat_id"))
        default:
            outcome = InlineSetupOutcome(error: "This card can't set up \(connector). Use Open full setup.")
        }
        await refresh()
        if let raw = outcome.error {
            outcome.error = inlineSetupFailureReason(
                raw,
                service: service(),
                typed: Array(values.values)
            )
        }
        return outcome
    }
}
