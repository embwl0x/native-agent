import Foundation
import BackgroundLoops
import PersistenceCore
import TrustCenter
// Blueprint: | `SlackSocketModeConfig.swift` | Socket configuration and throwing ingress/toggle readers consume TransportAllowlist's typed canonical Slack policy; UI callers retain unavailable authority as a failure |

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
    // TransportAllowlist owns the checked channel/user policy. Empty is never open.
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
        ingressPolicy(try TransportAllowlist.slackPolicy(dataRoot: dataRoot))
    }

    private static func ingressPolicy(_ policy: TransportAllowlist.SlackPolicy) -> SlackIngressPolicy {
        return SlackIngressPolicy(
            allowedChannelIds: policy.allowlist.chatIds,
            allowedUserIds: policy.allowlist.userIds,
            requireMention: policy.requireMention,
            botUserId: policy.botUserId
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
        let policy = try TransportAllowlist.slackPolicy(dataRoot: dataRoot)
        let ingress = ingressPolicy(policy)
        // The tokens are Keychain's (SlackCredentials); the files say the rest.
        let botToken = try SlackCredentials.read(.bot, dataRoot: dataRoot)
        let appToken = try SlackCredentials.read(.app, dataRoot: dataRoot)
        guard let botToken, !botToken.isEmpty,
              let appToken, !appToken.isEmpty else {
            return nil
        }
        return SlackSocketModeConfig(
            botToken: botToken,
            appToken: appToken,
            botUserId: ingress.botUserId,
            teamId: policy.teamId,
            enabled: policy.socketModeEnabled,
            allowedChannelIds: ingress.allowedChannelIds,
            allowedUserIds: ingress.allowedUserIds,
            requireMention: ingress.requireMention
        )
    }

    /// Switched off in the saved Slack config, whatever the tokens say.
    public static func socketModeSwitchedOff(dataRoot: URL) throws -> Bool {
        try !TransportAllowlist.slackPolicy(dataRoot: dataRoot).socketModeEnabled
    }

}

enum SlackIngressDenial: String, Sendable, Equatable {
    case allowlistEmpty = "allowlist_empty_fail_closed"
    case notAllowlisted = "not_allowlisted"
    case mentionRequired = "mention_required"
}

/// The Socket Mode ingress decision.
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
