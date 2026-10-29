import Foundation
import NativeAgentCore
import PersistenceCore
// Blueprint: | `ChatSessionDirective.swift` | `ChatSessionDirective.recordURL` uses canonical session path validation; seven-day delivery eligibility leaves expired/delivered records on disk |

// One-shot instructions belong to their session's next accepted user turn.
// One shot, like the note: stamped delivered after provider acceptance.
// Expiry bounds delivery eligibility; existing records remain on disk.
// Storage: local backup, data export and phone sync exclude these records;
// off-disk backup includes them. PrivacyMap: context. No automatic deletion.
public struct ChatSessionDirectiveRecord: Codable, Equatable, Sendable {
    public var createdAt: String
    public var directive: String
    public var deliveredAt: String?
    /// Legacy advisory provenance retained to recognize retired helper records
    /// on disk. These records must never be delivered as session directives.
    public var helperLane: String?
    /// The turn whose content produced the line.
    public var helperSourceTurn: String?
    /// The claim the line is about, when it is about one. Kept after delivery:
    /// it is what stops the same claim being raised a second time.
    public var claimKey: String?

    public init(
        createdAt: String,
        directive: String,
        deliveredAt: String? = nil,
        helperLane: String? = nil,
        helperSourceTurn: String? = nil,
        claimKey: String? = nil
    ) {
        self.createdAt = createdAt
        self.directive = directive
        self.deliveredAt = deliveredAt
        self.helperLane = helperLane
        self.helperSourceTurn = helperSourceTurn
        self.claimKey = claimKey
    }
}

public enum ChatSessionDirective {

    /// Seven-day delivery window; expiry returns nil without changing the file.
    public static let retentionSeconds: TimeInterval = 7 * 24 * 60 * 60

    public static func recordURL(dataRoot: URL, sessionID: String) -> URL? {
        guard let component = NativeAgentChatSessionID.normalizedPathComponent(sessionID) else { return nil }
        return dataRoot
            .appendingPathComponent("context", isDirectory: true)
            .appendingPathComponent("session_directives", isDirectory: true)
            .appendingPathComponent("\(component).json", isDirectory: false)
    }

    public static func load(dataRoot: URL, sessionID: String) -> ChatSessionDirectiveRecord? {
        guard let url = recordURL(dataRoot: dataRoot, sessionID: sessionID),
              let data = try? Data(contentsOf: url) else { return nil }
        return try? JSONDecoder().decode(ChatSessionDirectiveRecord.self, from: data)
    }

    /// The directive this session still owes its next turn, or nil.
    public static func pendingDirective(
        dataRoot: URL,
        sessionID: String,
        now: Date = Date()
    ) -> String? {
        guard let record = load(dataRoot: dataRoot, sessionID: sessionID),
              record.deliveredAt == nil,
              record.helperLane == nil else { return nil }
        let directive = record.directive.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !directive.isEmpty else { return nil }
        let formatter = ISO8601DateFormatter()
        if let created = formatter.date(from: record.createdAt),
           now.timeIntervalSince(created) > retentionSeconds {
            return nil
        }
        return directive
    }

    /// Best effort, and idempotent: a directive already stamped stays stamped.
    public static func markDelivered(
        dataRoot: URL,
        sessionID: String,
        now: Date = Date(),
        expectedDirective: String? = nil
    ) {
        guard let url = recordURL(dataRoot: dataRoot, sessionID: sessionID),
              var record = load(dataRoot: dataRoot, sessionID: sessionID),
              record.deliveredAt == nil else { return }
        if let expectedDirective, record.directive.trimmingCharacters(in: .whitespacesAndNewlines) != expectedDirective { return }
        record.deliveredAt = ISO8601DateFormatter().string(from: now)
        guard let data = try? JSONEncoder().encode(record) else { return }
        try? SwiftNativePersistenceCore.writeDataAtomicDurable(data, to: url)
    }

    @discardableResult
    public static func write(
        _ record: ChatSessionDirectiveRecord,
        dataRoot: URL,
        sessionID: String
    ) -> Bool {
        guard let url = recordURL(dataRoot: dataRoot, sessionID: sessionID) else { return false }
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        guard let data = try? encoder.encode(record) else { return false }
        return NativePrivateFile.write(data, to: url)
    }
}
