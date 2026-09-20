import Foundation

// MARK: - A one-shot system directive bound to ONE chat session
//
// Sol's P1-4, 2026-09-15. The first conversation's instructions lived only in
// the hidden kickoff that produced the opener. That kickoff is a user-role
// message which is deliberately NOT persisted (`hideUserBubble`), so the turn
// carrying the person's ANSWER could be assembled without it — leaving the
// agent looking at "A partner, mostly" with nothing telling it to write a line
// into SOUL.md. The write then simply does not happen, silently, and the one
// visible consequence of the whole flow is missing.
//
// So the instruction that matters on the NEXT turn is left where the next turn
// will actually look: the volatile dynamic segment of its system prompt.
//
// This is `ChatUpdateNote`'s shape with one difference that is the whole point
// — the record is keyed by session id. An update note is a global "say this to
// whoever speaks next"; this is "when THIS conversation continues, it needs to
// know this". A global note would be consumed by whichever session happened to
// take the next turn, which on a Mac with a bot shelf running is routinely not
// the one the person is typing in.
//
// One shot, like the note: stamped delivered as the prompt is built, so a crash
// afterwards cannot repeat it. Retention bounds a directive whose session was
// abandoned; nothing else cleans these up.
public struct ChatSessionDirectiveRecord: Codable, Equatable, Sendable {
    public var createdAt: String
    public var directive: String
    public var deliveredAt: String?
    /// Set when an advisory lane wrote this line, so the turn that actually
    /// delivers it can say so on that lane's own log row — a line that was
    /// queued and one that was read are not the same thing, and the log could
    /// not tell them apart.
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

    /// Long enough that someone who answers the next morning still gets the
    /// behavior, short enough that an abandoned session's directive does not
    /// sit on disk forever.
    public static let retentionSeconds: TimeInterval = 7 * 24 * 60 * 60

    /// Session ids reach this from a stored key, so the path component is
    /// built from an allowlist rather than sanitized by removal: anything that
    /// is not alphanumeric, dash or underscore makes the id unusable here and
    /// the directive is refused rather than written somewhere surprising.
    /// A traversal attempt (`..`, `/`) cannot survive this.
    static func safeComponent(_ sessionID: String) -> String? {
        let trimmed = sessionID.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, trimmed.count <= 128 else { return nil }
        let allowed = Set("abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789-_")
        guard trimmed.allSatisfy({ allowed.contains($0) }) else { return nil }
        return trimmed
    }

    public static func recordURL(dataRoot: URL, sessionID: String) -> URL? {
        guard let component = safeComponent(sessionID) else { return nil }
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
              record.deliveredAt == nil else { return nil }
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
        now: Date = Date()
    ) {
        guard let url = recordURL(dataRoot: dataRoot, sessionID: sessionID),
              var record = load(dataRoot: dataRoot, sessionID: sessionID),
              record.deliveredAt == nil else { return }
        record.deliveredAt = ISO8601DateFormatter().string(from: now)
        guard let data = try? JSONEncoder().encode(record) else { return }
        try? data.write(to: url, options: [.atomic])
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
        try? FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(), withIntermediateDirectories: true
        )
        do {
            try data.write(to: url, options: [.atomic])
            return true
        } catch {
            return false
        }
    }
}
