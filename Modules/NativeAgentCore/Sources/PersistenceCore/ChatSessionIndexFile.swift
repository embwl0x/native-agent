import Foundation

public enum ChatSessionIndexFileError: Error, LocalizedError, Sendable, Equatable {
    case unreadable(path: String, reason: String)
    case empty(path: String)
    case malformed(path: String, reason: String)
    case expectedArray(path: String)
    case nonObjectRow(path: String, index: Int)

    public var errorDescription: String? {
        switch self {
        case .unreadable(let path, let reason):
            return "Chat session index at \(path) could not be read: \(reason)"
        case .empty(let path):
            return "Chat session index at \(path) is empty."
        case .malformed(let path, let reason):
            return "Chat session index at \(path) is malformed JSON: \(reason)"
        case .expectedArray(let path):
            return "Chat session index at \(path) must contain a JSON array."
        case .nonObjectRow(let path, let index):
            return "Chat session index at \(path) contains a non-object row at index \(index)."
        }
    }
}

/// Strict decoder for mutating `chat/sessions.json`.
///
/// A missing file is the only state treated as a new index. Existing files
/// must be readable, non-empty JSON arrays containing only object rows. This
/// prevents read failures and malformed rows from being collapsed into an
/// empty index and overwritten by the next surface that creates a session.
public enum ChatSessionIndexFile {
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
}

private extension UInt8 {
    var isJSONWhitespace: Bool {
        self == 0x20 || self == 0x09 || self == 0x0A || self == 0x0D
    }
}
