import Foundation
import Darwin
// Blueprint: | `ConnectorInputValue.swift` | Connector input scalars and secret-free TransportAllowlist: canonical Slack auth.json policy only, strict alias unions within that object and Telegram integer IDs shared by ingress and SecurityCenter; unreadable or malformed saved policy throws |

/// Scalar conversion shared by action and request inputs.
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

/// Secret-free authority read shared by transport ingress and SecurityCenter.
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
        try slack(fields: slackPolicy(dataRoot: dataRoot))
    }

    /// One checked metadata read for both ingress options and allowlist admission.
    public static func slackPolicy(dataRoot: URL) throws -> [String: JSONValue] {
        try read(slackMetadataPath(dataRoot: dataRoot), transport: "Slack")
    }

    public static func slack(fields: [String: JSONValue]) throws -> Self {
        func ids(_ keys: [String]) throws -> Set<String> {
            var result: Set<String> = []
            for key in keys {
                guard let value = fields[key] else { continue }
                guard case .array(let values) = value else { throw failure("Slack") }
                for value in values {
                    guard case .string(let id) = value else { throw failure("Slack") }
                    let trimmed = id.trimmingCharacters(in: .whitespacesAndNewlines)
                    if !trimmed.isEmpty { result.insert(trimmed) }
                }
            }
            return result
        }
        return try Self(chatIds: ids(["allowed_channel_ids", "allowedChannelIds", "allowed_chat_ids", "allowedChatIds"]),
            userIds: ids(["allowed_user_ids", "allowedUserIds"]))
    }

    public static func slackMetadataPath(dataRoot: URL) -> URL {
        dataRoot.appendingPathComponent("connectors/slack/auth.json")
    }

    private static func read(_ path: URL, transport: String) throws -> [String: JSONValue] {
        // Only a missing entry is empty. A dangling link or other unreadable
        // saved policy must not admit a message.
        var metadata = stat()
        if lstat(path.path, &metadata) != 0 {
            guard errno == ENOENT else { throw failure(transport) }
            return [:]
        }
        guard metadata.st_mode & S_IFMT == S_IFREG else { throw failure(transport) }
        do {
            // Authority keeps Slack's checked JSON semantics; the general
            // persistence parser's non-finite-token repair is not admission.
            let decoded = try JSONSerialization.jsonObject(with: Data(contentsOf: path))
            guard case .object(let fields) = JSONValue(fromFoundation: decoded) else { throw failure(transport) }
            return fields
        } catch { throw failure(transport) }
    }

    private static func failure(_ transport: String) -> PersistenceCoreError {
        .ioFailure("Saved \(transport) allowlist is unavailable")
    }
}
