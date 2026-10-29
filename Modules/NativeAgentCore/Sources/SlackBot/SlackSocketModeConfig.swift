import Foundation
import BackgroundLoops
import PersistenceCore
import TrustCenter
// Blueprint: | `SlackSocketModeConfig.swift` | Socket configuration and throwing ingress/toggle readers consume TransportAllowlist's checked Slack metadata and strict string-only union; UI callers retain unavailable authority as a failure |

public struct SlackSocketModeConfig: Sendable, Equatable {
    public static func parseIDs(_ raw: String) -> Set<String> {
        Set(raw.split { $0 == "," || $0 == ";" || $0.isWhitespace }
            .map(String.init)
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty })
    }

    let botToken: String
    let appToken: String
    let botUserId: String?
    let teamId: String?
    let enabled: Bool
    let historyPollEnabled: Bool
    let historyPollInterval: TimeInterval
    let historyConversationRefreshInterval: TimeInterval
    // TransportAllowlist owns the checked policy union. Empty is never open.
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

    public static func loadIngressPolicy(
        dataRoot: URL = PersistenceCore.defaultDataRoot()
    ) throws -> SlackIngressPolicy {
        try parseIngressPolicy(TransportAllowlist.slackPolicy(dataRoot: dataRoot))
    }

    private static func parseIngressPolicy(_ object: [String: JSONValue]) throws -> SlackIngressPolicy {
        let allowed = try TransportAllowlist.slack(fields: object)
        return SlackIngressPolicy(
            allowedChannelIds: allowed.chatIds,
            allowedUserIds: allowed.userIds,
            requireMention: firstBool(keys: ["require_mention", "requireMention"], in: object) ?? true,
            botUserId: firstString(keys: ["user_id", "bot_user_id", "bot_id"], in: object)
        )
    }

    /// Nil when Slack is not connected; throws when its tokens could not be
    /// read, which is a fault, never "not connected".
    static func load(dataRoot: URL = PersistenceCore.defaultDataRoot()) throws -> SlackSocketModeConfig? {
        try SlackCredentials.withSnapshot(dataRoot: dataRoot) {
            try loadSnapshot(dataRoot: dataRoot)
        }
    }

    private static func loadSnapshot(dataRoot: URL) throws -> SlackSocketModeConfig? {
        let object = try TransportAllowlist.slackPolicy(dataRoot: dataRoot)
        let ingress = try parseIngressPolicy(object)
        // The tokens are Keychain's (SlackCredentials); the files say the rest.
        let botToken = try SlackCredentials.read(.bot, dataRoot: dataRoot)
        let appToken = try SlackCredentials.read(.app, dataRoot: dataRoot)
        guard let botToken, !botToken.isEmpty,
              let appToken, !appToken.isEmpty else {
            return nil
        }
        let enabled = firstBool(keys: socketModeKeys, in: object) ?? true
        let historyPollEnabled = firstBool(
            keys: ["history_poll_enabled", "socket_mode_history_poll_enabled"],
            in: object
        ) ?? true
        let historyPollInterval = max(
            30,
            try firstDuration(keys: ["history_poll_interval", "socket_mode_history_poll_interval"], in: object, projection: 10) ?? 60
        )
        let historyConversationRefreshInterval = max(
            historyPollInterval,
            try firstDuration(
                keys: ["history_conversation_refresh_interval", "socket_mode_history_conversation_refresh_interval"],
                in: object
            ) ?? 600
        )
        return SlackSocketModeConfig(
            botToken: botToken,
            appToken: appToken,
            botUserId: ingress.botUserId,
            teamId: firstString(keys: ["team_id"], in: object),
            enabled: enabled,
            historyPollEnabled: historyPollEnabled,
            historyPollInterval: historyPollInterval,
            historyConversationRefreshInterval: historyConversationRefreshInterval,
            allowedChannelIds: ingress.allowedChannelIds,
            allowedUserIds: ingress.allowedUserIds,
            requireMention: ingress.requireMention
        )
    }

    private static let socketModeKeys = ["socket_mode_enabled", "inbound_enabled"]

    /// Switched off in the saved Slack config, whatever the tokens say.
    public static func socketModeSwitchedOff(dataRoot: URL) throws -> Bool {
        firstBool(keys: socketModeKeys, in: try TransportAllowlist.slackPolicy(dataRoot: dataRoot)) == false
    }

    private static func firstString(keys: [String], in object: [String: JSONValue]) -> String? {
        for key in keys {
            guard case .string(let value)? = object[key] else { continue }
            let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
            if !trimmed.isEmpty { return trimmed }
        }
        return nil
    }

    private static func firstBool(keys: [String], in object: [String: JSONValue]) -> Bool? {
        for key in keys {
            if case .bool(let value)? = object[key] { return value }
            // Preserve the saved Foundation scalar semantics of this reader.
            if case .int(let value)? = object[key], let flag = NSNumber(value: value) as? Bool { return flag }
            if case .double(let value)? = object[key], let flag = NSNumber(value: value) as? Bool { return flag }
            if case .string(let value)? = object[key] {
                switch value.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() {
                case "1", "true", "yes", "on": return true
                case "0", "false", "no", "off": return false
                default: continue
                }
            }
        }
        return nil
    }

    /// Every saved duration, including its largest timer projection, must fit
    /// the nanosecond sleep owner. Invalid bytes remain on disk for repair.
    private static func firstDuration(keys: [String], in object: [String: JSONValue], projection: Double = 1) throws -> Double? {
        for key in keys {
            guard let raw = object[key] else { continue }
            let value: Double?
            switch raw {
            case .double(let number): value = number
            case .int(let number): value = Double(number)
            case .string(let text): value = Double(text.trimmingCharacters(in: .whitespacesAndNewlines))
            default: value = nil
            }
            guard let value, value.isFinite, value > 0,
                  UInt64(exactly: (value * projection * 1_000_000_000).rounded(.up)) != nil else {
                throw NSError(domain: "SlackConfiguration", code: 1,
                    userInfo: [NSLocalizedDescriptionKey: "Slack \(key) must be a positive finite duration representable by its timers."])
            }
            return value
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
public struct SlackIngressPolicy: Sendable, Equatable {
    public let allowedChannelIds: Set<String>
    public let allowedUserIds: Set<String>
    public let requireMention: Bool
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
