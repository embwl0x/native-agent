import Foundation
import PersistenceCore
import NativeAgentShared

public enum ChatSessionIndexFileError: Error, LocalizedError, Sendable, Equatable {
    case unreadable(path: String, reason: String)
    case empty(path: String)
    case malformed(path: String, reason: String)
    case expectedArray(path: String)
    case nonObjectRow(path: String, index: Int)

    /// 2026-09-06: the message names the FILE, not its absolute path. These
    /// descriptions are forwarded to remote surfaces (iPhone error banners),
    /// and a Mac filesystem path is not theirs to see. The full path stays in
    /// the associated value for Mac-local logs.
    public var errorDescription: String? {
        switch self {
        case .unreadable(let path, let reason):
            return "Chat session index \(Self.fileName(path)) could not be read: \(reason)"
        case .empty(let path):
            return "Chat session index \(Self.fileName(path)) is empty."
        case .malformed(let path, let reason):
            return "Chat session index \(Self.fileName(path)) is malformed JSON: \(reason)"
        case .expectedArray(let path):
            return "Chat session index \(Self.fileName(path)) must contain a JSON array."
        case .nonObjectRow(let path, let index):
            return "Chat session index \(Self.fileName(path)) contains a non-object row at index \(index)."
        }
    }

    private static func fileName(_ path: String) -> String {
        let name = (path as NSString).lastPathComponent
        return name.isEmpty ? "chat session index" : name
    }
}

/// Strict decoder for mutating `chat/sessions.json`.
///
/// A missing file is the only state treated as a new index. Existing files
/// must be readable, non-empty JSON arrays containing only object rows. This
/// prevents read failures and malformed rows from being collapsed into an
/// empty index and overwritten by the next surface that creates a session.
public enum ChatSessionIndexFile {
    /// The last transcript generation containing conversational speech. Tool
    /// receipts still advance transcriptGeneration, but do not announce a new
    /// exchange to another open workspace.
    public static func recordConversationChange(in row: inout [String: JSONValue], role: String) {
        guard ["user", "assistant"].contains(role), let generation = transcriptGeneration(in: row) else { return }
        row["lastConversationGeneration"] = .int(generation)
    }
    public static func loadObjectRowsForMutation(
        at path: URL,
        fileManager: FileManager = .default
    ) throws -> [[String: JSONValue]] {
        guard fileManager.fileExists(atPath: path.path) else { return [] }

        let data: Data
        do {
            data = try Data(contentsOf: path)
        } catch {
            throw ChatSessionIndexFileError.unreadable(
                path: path.path,
                reason: error.localizedDescription
            )
        }

        guard data.contains(where: { !$0.isJSONWhitespace }) else {
            throw ChatSessionIndexFileError.empty(path: path.path)
        }

        let parsed: JSONValue
        do {
            parsed = try JSONValue.parse(data)
        } catch {
            throw ChatSessionIndexFileError.malformed(
                path: path.path,
                reason: error.localizedDescription
            )
        }

        guard case .array(let values) = parsed else {
            throw ChatSessionIndexFileError.expectedArray(path: path.path)
        }

        var rows: [[String: JSONValue]] = []
        rows.reserveCapacity(values.count)
        for (index, value) in values.enumerated() {
            guard case .object(let row) = value else {
                throw ChatSessionIndexFileError.nonObjectRow(path: path.path, index: index)
            }
            rows.append(row)
        }
        return rows
    }

    public static func serializedData(
        for rows: [[String: JSONValue]],
        pretty: Bool = true
    ) throws -> Data {
        try JSONValue.array(rows.map(JSONValue.object)).serializedData(pretty: pretty)
    }

    /// 2026-09-06: the session row's monotonic transcript version.
    ///
    /// `updatedAt` is a wall-clock stamp and cannot order two transcript
    /// states: a clock that steps back, two writers a millisecond apart, or a
    /// row restamped for a reason that isn't a transcript write all produce
    /// stamps that lie about which transcript is newer. The phone uses this
    /// version to decide whether an EMPTY published transcript is allowed to
    /// wipe its copy of a chat, so it has to be a counter, never a clock:
    /// incremented on every clear and every transcript write, and only ever
    /// upward. A row with no counter yet is `nil`, and the phone never clears
    /// on `nil` — legacy Macs keep the pre-2026-09-06 behaviour.
    public static let transcriptGenerationKey = "transcriptGeneration"

    public static func transcriptGeneration(in row: [String: JSONValue]) -> Int64? {
        switch row[transcriptGenerationKey] {
        case .int(let value): return value
        // A hand-edited or foreign-writer row can carry the counter as a JSON
        // float. Range-checked, never a bare `Int64(value)` — that traps on
        // anything outside Int64, and this reader sits inside the
        // session-index writer.
        case .double(let value):
            let truncated = value.rounded(.towardZero)
            guard truncated >= -9_007_199_254_740_992,
                  truncated <= 9_007_199_254_740_992 else { return nil }
            return Int64(truncated)
        default: return nil
        }
    }

    /// Advance the row's transcript version. Absent or unreadable starts at 1,
    /// which is still strictly greater than "no version at all".
    ///
    /// 2026-09-06: saturating, never wrapping. `&+ 1` on a row already at
    /// `Int64.max` yields `Int64.min`, and this counter's whole job is that it
    /// only ever moves upward — a wrap would make every subsequent transcript
    /// write look older than the clear that preceded it. A row at the ceiling
    /// stops moving instead and reports `false`, so a caller that needs the
    /// bump to mean something (a clear, which publishes an empty transcript a
    /// remote reader may only act on when it is provably newest) can refuse.
    @discardableResult
    public static func bumpTranscriptGeneration(in row: inout [String: JSONValue]) -> Bool {
        let current = transcriptGeneration(in: row) ?? 0
        guard current < Int64.max else { return false }
        row[transcriptGenerationKey] = .int(current + 1)
        return true
    }

    /// Whether this row's transcript version can no longer advance. A clear
    /// checks this BEFORE deleting any transcript bytes: an empty transcript
    /// published without a newer version is one the phone must refuse, which
    /// would leave the two surfaces disagreeing about the chat forever.
    public static func isTranscriptGenerationExhausted(in row: [String: JSONValue]) -> Bool {
        transcriptGeneration(in: row) == Int64.max
    }
}

/// A `sessions.json` row that does not read as a session: a required field is
/// missing, or a field holds the wrong JSON type.
public struct ChatSessionRowError: Error, LocalizedError, Sendable, Equatable {
    public let field: String
    public var errorDescription: String? {
        "A chat session row has an unreadable \"\(field)\" field."
    }
}

public extension ChatSession {
    /// One `sessions.json` row, read straight from its parsed object. The
    /// same contract the row's Codable decode had: `id`, `title` and
    /// `createdAt` are required strings; every other field is absent/null or
    /// its exact type (integers accept an integral JSON float); anything else
    /// fails the row, and so the listing.
    init(row o: [String: JSONValue]) throws {
        func string(_ key: String) throws -> String? {
            switch o[key] {
            case nil, .null?: return nil
            case .string(let s)?: return s
            default: throw ChatSessionRowError(field: key)
            }
        }
        func required(_ key: String) throws -> String {
            guard let s = try string(key) else { throw ChatSessionRowError(field: key) }
            return s
        }
        func int(_ key: String) throws -> Int? {
            switch o[key] {
            case nil, .null?: return nil
            case .int(let n)?: return Int(n)
            case .double(let d)?:
                guard let n = Int(exactly: d) else { throw ChatSessionRowError(field: key) }
                return n
            default: throw ChatSessionRowError(field: key)
            }
        }
        func bool(_ key: String) throws -> Bool? {
            switch o[key] {
            case nil, .null?: return nil
            case .bool(let b)?: return b
            default: throw ChatSessionRowError(field: key)
            }
        }
        self.init(
            id: try required("id"),
            title: try required("title"),
            source: try string("source"),
            sourceKey: try string("sourceKey"),
            createdAt: try required("createdAt"),
            updatedAt: try string("updatedAt"),
            archived: try bool("archived"),
            messageCount: try int("messageCount"),
            lastMessagePreview: try string("lastMessagePreview"),
            summary: try string("summary"),
            parentSessionId: try string("parentSessionId"),
            rootSessionId: try string("rootSessionId"),
            forkedAtMessageId: try string("forkedAtMessageId"),
            projectSpaceId: try string("projectSpaceId"),
            worktreePath: try string("worktreePath"),
            providerId: try string("providerId"),
            modelId: try string("modelId"),
            transcriptGeneration: try int(ChatSessionIndexFile.transcriptGenerationKey)
        )
    }
}

private extension UInt8 {
    var isJSONWhitespace: Bool {
        self == 0x20 || self == 0x09 || self == 0x0A || self == 0x0D
    }
}
