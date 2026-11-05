import Foundation
import Darwin
// Blueprint: | `ConnectorInputValue.swift` | Checked transport scalars and allowlists; damaged authority throws. |

public enum ConnectorInputValue {
    public static func bool(_ raw: JSONValue?, default defaultValue: Bool) -> Bool {
        switch raw {
        case .bool(let b): return b
        case .int(let i): return i != 0
        case .double(let d): return d != 0
        case .string(let s):
            let lower = s.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
            if ["1", "true", "yes", "on"].contains(lower) { return true }
            if ["0", "false", "no", "off"].contains(lower) { return false }
            return defaultValue
        default:
            return defaultValue
        }
    }
}

public struct TransportAllowlist: Sendable {
    public let chatIds: Set<String>
    public let userIds: Set<String>

    public static func telegram(dataRoot: URL) throws -> Self {
        try telegram(fields: read(dataRoot.appendingPathComponent("telegram/config.json"), transport: "Telegram"))
    }

    public static func telegram(fields: [String: JSONValue]) throws -> Self {
        func ids(_ key: String) throws -> Set<String> {
            guard let value = fields[key] else { return [] }
            guard case .array(let values) = value else { throw failure("Telegram") }
            return Set(try values.map { value in
                switch value {
                case .int(let id): return String(id)
                case .string(let raw):
                    if let id = Int64(raw) { return String(id) }
                    fallthrough
                default: throw failure("Telegram")
                }
            })
        }
        return try Self(chatIds: ids("allowed_chat_ids"), userIds: ids("allowed_user_ids"))
    }

    public static func slack(dataRoot: URL) throws -> Self {
        try slackPolicy(dataRoot: dataRoot).allowlist
    }

    public static func slackPolicy(dataRoot: URL) throws -> SlackPolicy {
        try slackPolicy(fields: read(slackMetadataPath(dataRoot: dataRoot), transport: "Slack"))
    }

    public struct SlackPolicy: Sendable {
        public let allowlist: TransportAllowlist
        public let requireMention: Bool
        public let socketModeEnabled: Bool
        public let botUserId: String?
        public let teamId: String?
    }

    /// Only missing options use setup defaults; malformed saved values make authority unavailable.
    public static func slackPolicy(fields: [String: JSONValue]) throws -> SlackPolicy {
        func ids(_ key: String) throws -> Set<String> {
            guard let value = fields[key] else { return [] }
            guard case .array(let values) = value else { throw failure("Slack") }
            return Set(try values.map { value in
                guard case .string(let id) = value else { throw failure("Slack") }
                let trimmed = id.trimmingCharacters(in: .whitespacesAndNewlines)
                guard !trimmed.isEmpty else { throw failure("Slack") }
                return trimmed
            })
        }
        func flag(_ key: String) throws -> Bool {
            guard let value = fields[key] else { return true }
            guard case .bool(let flag) = value else { throw failure("Slack") }
            return flag
        }
        func identity(_ key: String) throws -> String? {
            guard let value = fields[key] else { return nil }
            guard case .string(let raw) = value else { throw failure("Slack") }
            let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty else { throw failure("Slack") }
            return trimmed
        }
        return try SlackPolicy(
            allowlist: Self(chatIds: ids("allowed_channel_ids"), userIds: ids("allowed_user_ids")),
            requireMention: flag("require_mention"), socketModeEnabled: flag("socket_mode_enabled"),
            botUserId: identity("user_id"), teamId: identity("team_id"))
    }

    public static func slackMetadataPath(dataRoot: URL) -> URL {
        dataRoot.appendingPathComponent("connectors/slack/auth.json")
    }

    private static func read(_ path: URL, transport: String) throws -> [String: JSONValue] {
        // Only absence means empty policy; unreadable saved authority cannot admit messages.
        var metadata = stat()
        if lstat(path.path, &metadata) != 0 {
            guard errno == ENOENT else { throw failure(transport) }
            return [:]
        }
        guard metadata.st_mode & S_IFMT == S_IFREG else { throw failure(transport) }
        do {
            // Authority keeps Slack's checked JSON semantics; the general persistence parser's non-finite-token repair is not admission.
            let decoded = try JSONSerialization.jsonObject(with: Data(contentsOf: path))
            guard case .object(let fields) = JSONValue(fromFoundation: decoded) else { throw failure(transport) }
            return fields
        } catch { throw failure(transport) }
    }

    private static func failure(_ transport: String) -> PersistenceCoreError {
        .ioFailure("Saved \(transport) allowlist is unavailable")
    }
}
