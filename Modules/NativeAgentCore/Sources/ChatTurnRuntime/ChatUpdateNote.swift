import Foundation

/// U1 (User, 2026-09-10): after the app updates, the agent had no way to know
/// what changed — someone asked theirs and it could not find out.
///
/// The app writes ONE record here when the bundle version changes; the turn
/// engine reads it into the DYNAMIC system segment on the next turn and stamps
/// it delivered, so it is a note left quietly rather than a push, a sound, or a
/// chat row that looks like the person typed. The dynamic segment is turn-scoped
/// volatile (lifted out of the cached prefix), so this costs no prompt-cache
/// prefix and vanishes after the one delivery.
public struct ChatUpdateNoteRecord: Codable, Equatable, Sendable {
    public var from: String
    public var to: String
    public var createdAt: String
    public var note: String
    /// Stamped when the note has been put in front of the agent once.
    public var deliveredAt: String?

    public init(from: String, to: String, createdAt: String, note: String, deliveredAt: String? = nil) {
        self.from = from
        self.to = to
        self.createdAt = createdAt
        self.note = note
        self.deliveredAt = deliveredAt
    }
}

public enum ChatUpdateNote {
    /// A note nobody ever collected stops being news. Without this, an app that
    /// is updated while it is closed for a month would open with a stale note.
    public static let retentionSeconds: TimeInterval = 7 * 24 * 60 * 60

    public static func recordURL(dataRoot: URL) -> URL {
        dataRoot
            .appendingPathComponent("context", isDirectory: true)
            .appendingPathComponent("update_note.json")
    }

    public static func load(dataRoot: URL) -> ChatUpdateNoteRecord? {
        guard let data = try? Data(contentsOf: recordURL(dataRoot: dataRoot)) else { return nil }
        return try? JSONDecoder().decode(ChatUpdateNoteRecord.self, from: data)
    }

    /// The note to put in this turn's context, or nil when there is nothing to
    /// say: no record, already delivered, empty, or past retention.
    public static func pendingNote(dataRoot: URL, now: Date = Date()) -> String? {
        guard let record = load(dataRoot: dataRoot) else { return nil }
        guard record.deliveredAt == nil else { return nil }
        let note = record.note.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !note.isEmpty else { return nil }
        guard let created = ISO8601DateFormatter().date(from: record.createdAt),
              now.timeIntervalSince(created) <= retentionSeconds else { return nil }
        return note
    }

    /// Stamp the record delivered. Best-effort on purpose: failing to stamp must
    /// not fail the turn, and the worst case is the note appearing once more.
    public static func markDelivered(dataRoot: URL, now: Date = Date()) {
        guard var record = load(dataRoot: dataRoot), record.deliveredAt == nil else { return }
        record.deliveredAt = ISO8601DateFormatter().string(from: now)
        write(record, dataRoot: dataRoot)
    }

    public static func write(_ record: ChatUpdateNoteRecord, dataRoot: URL) {
        let url = recordURL(dataRoot: dataRoot)
        do {
            try FileManager.default.createDirectory(
                at: url.deletingLastPathComponent(),
                withIntermediateDirectories: true
            )
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.sortedKeys]
            try encoder.encode(record).write(to: url, options: [.atomic])
        } catch {
            NSLog("[update-note] could not write the update note: %@", error.localizedDescription)
        }
    }
}
