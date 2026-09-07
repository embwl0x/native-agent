import Foundation
import BackgroundLoops
import ChatOrchestration
import PersistenceCore
import SlackConnector

struct SlackSocketModeConfig: Sendable, Equatable {
    let botToken: String
    let appToken: String
    let botUserId: String?
    let teamId: String?
    let enabled: Bool
    let historyPollEnabled: Bool
    let historyPollInterval: TimeInterval
    let historyConversationRefreshInterval: TimeInterval
    // Transport policy mirrors SecurityCenter's union of the two Slack token
    // stores. An empty allowlist is deliberately unavailable, never open.
    let allowedChannelIds: Set<String>
    let allowedUserIds: Set<String>
    let requireMention: Bool

    var ingressPolicy: SlackIngressPolicy {
        SlackIngressPolicy(
            allowedChannelIds: allowedChannelIds,
            allowedUserIds: allowedUserIds,
            requireMention: requireMention,
            botUserId: botUserId
        )
    }

    static func loadIngressPolicy(
        dataRoot: URL = PersistenceCore.defaultDataRoot()
    ) -> SlackIngressPolicy {
        let objects = tokenObjects(dataRoot: dataRoot)
        return SlackIngressPolicy(
            allowedChannelIds: firstStringSet(
                keys: ["allowed_channel_ids", "allowedChannelIds", "allowed_chat_ids", "allowedChatIds"],
                in: objects
            ),
            allowedUserIds: firstStringSet(
                keys: ["allowed_user_ids", "allowedUserIds"],
                in: objects
            ),
            requireMention: firstBool(keys: ["require_mention", "requireMention"], in: objects) ?? true,
            botUserId: firstString(keys: ["user_id", "bot_user_id", "bot_id"], in: objects)
        )
    }

    static func load(dataRoot: URL = PersistenceCore.defaultDataRoot()) -> SlackSocketModeConfig? {
        let objects = tokenObjects(dataRoot: dataRoot)
        // Match the connector readiness and outbound-delivery vocabulary.
        // Imported/legacy Slack credentials may use `oauth_token` or `token`;
        // rejecting those only here leaves an admitted connector unable to
        // start its inbound transport.
        let botToken = firstString(
            keys: ["access_token", "oauth_token", "token", "bot_token"],
            in: objects
        )
        let appToken = firstString(keys: ["socket_mode_app_token", "app_token", "slack_app_token"], in: objects)
        guard let botToken, !botToken.isEmpty,
              let appToken, !appToken.isEmpty else {
            return nil
        }
        let enabled = firstBool(keys: ["socket_mode_enabled", "inbound_enabled"], in: objects) ?? true
        let historyPollEnabled = firstBool(
            keys: ["history_poll_enabled", "socket_mode_history_poll_enabled"],
            in: objects
        ) ?? true
        let historyPollInterval = max(
            30,
            firstDouble(keys: ["history_poll_interval", "socket_mode_history_poll_interval"], in: objects) ?? 60
        )
        let historyConversationRefreshInterval = max(
            historyPollInterval,
            firstDouble(
                keys: ["history_conversation_refresh_interval", "socket_mode_history_conversation_refresh_interval"],
                in: objects
            ) ?? 600
        )
        return SlackSocketModeConfig(
            botToken: botToken,
            appToken: appToken,
            botUserId: firstString(keys: ["user_id", "bot_user_id", "bot_id"], in: objects),
            teamId: firstString(keys: ["team_id"], in: objects),
            enabled: enabled,
            historyPollEnabled: historyPollEnabled,
            historyPollInterval: historyPollInterval,
            historyConversationRefreshInterval: historyConversationRefreshInterval,
            allowedChannelIds: firstStringSet(
                keys: ["allowed_channel_ids", "allowedChannelIds", "allowed_chat_ids", "allowedChatIds"],
                in: objects
            ),
            allowedUserIds: firstStringSet(
                keys: ["allowed_user_ids", "allowedUserIds"],
                in: objects
            ),
            requireMention: firstBool(keys: ["require_mention", "requireMention"], in: objects) ?? true
        )
    }

    private static func tokenObjects(dataRoot: URL) -> [[String: Any]] {
        let paths = [
            dataRoot
                .appendingPathComponent("connectors", isDirectory: true)
                .appendingPathComponent("slack", isDirectory: true)
                .appendingPathComponent("auth.json"),
            dataRoot
                .appendingPathComponent("oauth_tokens", isDirectory: true)
                .appendingPathComponent("slack.json"),
        ]
        return paths.compactMap { path in
            guard let data = try? Data(contentsOf: path),
                  let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
                return nil
            }
            return obj
        }
    }

    private static func firstStringSet(keys: [String], in objects: [[String: Any]]) -> Set<String> {
        // UNION across all files and aliases (2026-07-21 gpt-5.5 review):
        // SecurityCenter's slack allowlist unions the same sources — the
        // transport gate must not be stricter than the trust root (first-
        // non-empty previously let one file shadow another's channels).
        var result: Set<String> = []
        for object in objects {
            for key in keys {
                if let array = object[key] as? [String] {
                    result.formUnion(array.map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }.filter { !$0.isEmpty })
                } else if let array = object[key] as? [Any] {
                    result.formUnion(array.compactMap { $0 as? String }.map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }.filter { !$0.isEmpty })
                }
            }
        }
        return result
    }

    private static func firstString(keys: [String], in objects: [[String: Any]]) -> String? {
        for object in objects {
            for key in keys {
                guard let value = object[key] as? String else { continue }
                let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
                if !trimmed.isEmpty { return trimmed }
            }
        }
        return nil
    }

    private static func firstBool(keys: [String], in objects: [[String: Any]]) -> Bool? {
        for object in objects {
            for key in keys {
                if let value = object[key] as? Bool { return value }
                if let value = object[key] as? String {
                    switch value.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() {
                    case "1", "true", "yes", "on": return true
                    case "0", "false", "no", "off": return false
                    default: continue
                    }
                }
            }
        }
        return nil
    }

    private static func firstDouble(keys: [String], in objects: [[String: Any]]) -> Double? {
        for object in objects {
            for key in keys {
                if let value = object[key] as? Double { return value }
                if let value = object[key] as? Int { return Double(value) }
                if let value = object[key] as? String,
                   let parsed = Double(value.trimmingCharacters(in: .whitespacesAndNewlines)) {
                    return parsed
                }
            }
        }
        return nil
    }
}

enum SlackIngressDenial: String, Sendable, Equatable {
    case allowlistEmpty = "allowlist_empty_fail_closed"
    case notAllowlisted = "not_allowlisted"
    case mentionRequired = "mention_required"
}

/// One pure ingress decision shared by Socket Mode and history gap-fill.
/// SecurityCenter separately rechecks the same channel/user union at effect
/// time; this transport policy prevents unauthorized messages from becoming a
/// turn in the first place. It owns no tool or provider authority.
struct SlackIngressPolicy: Sendable, Equatable {
    let allowedChannelIds: Set<String>
    let allowedUserIds: Set<String>
    let requireMention: Bool
    let botUserId: String?

    var isConfigured: Bool {
        !allowedChannelIds.isEmpty || !allowedUserIds.isEmpty
    }

    func denial(
        channelId: String,
        userId: String,
        eventType: String,
        channelType: String?,
        rawText: String
    ) -> SlackIngressDenial? {
        guard isConfigured else { return .allowlistEmpty }
        guard allowedChannelIds.contains(channelId) || allowedUserIds.contains(userId) else {
            return .notAllowlisted
        }
        let normalizedType = channelType?
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased()
        let direct = normalizedType == "im" || normalizedType == "app_home" || channelId.hasPrefix("D")
        guard requireMention, !direct else { return nil }
        if eventType == "app_mention" { return nil }
        guard let botUserId = botUserId?.trimmingCharacters(in: .whitespacesAndNewlines),
              !botUserId.isEmpty,
              rawText.contains("<@\(botUserId)>") else {
            return .mentionRequired
        }
        return nil
    }
}
