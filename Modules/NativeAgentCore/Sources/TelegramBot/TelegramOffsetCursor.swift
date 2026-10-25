import Foundation
import PersistenceCore

// Blueprint: | `TelegramOffsetCursor.swift` | `TelegramOffsetCursor`: monotonic durable getUpdates cursor; only missing state bootstraps and corrupt state cannot replay commands |

/// The durable Telegram `getUpdates` cursor.
///
/// This is a security-sensitive boundary: treating corrupt bytes as offset zero
/// replays old updates, which can repeat a command or external tool action.
/// Missing is the sole bootstrap value; every existing file must be valid.
public struct TelegramOffsetCursor: Sendable {
    public static let maximumPayloadBytes = 4 * 1024

    public let fileURL: URL
    private let persistence: any PersistenceCoreProtocol

    public init(
        fileURL: URL,
        persistence: any PersistenceCoreProtocol = SwiftNativePersistenceCore()
    ) {
        self.fileURL = fileURL
        self.persistence = persistence
    }

    /// Loads the stored cursor. An absent file is the fresh-install cursor 0;
    /// malformed, unreadable, or out-of-range state deliberately throws.
    public func load() throws -> Int {
        let fileManager = FileManager.default
        guard fileManager.fileExists(atPath: fileURL.path) else { return 0 }

        let values: URLResourceValues
        do {
            values = try fileURL.resourceValues(forKeys: [.fileSizeKey])
        } catch {
            throw TelegramOffsetCursorError.unreadable(error.localizedDescription)
        }
        if let size = values.fileSize, size > Self.maximumPayloadBytes {
            throw TelegramOffsetCursorError.oversized(actualBytes: size, maximumBytes: Self.maximumPayloadBytes)
        }

        let payload: Data
        do {
            payload = try Data(contentsOf: fileURL)
        } catch {
            throw TelegramOffsetCursorError.unreadable(error.localizedDescription)
        }
        let decoded: JSONValue
        do {
            decoded = try JSONValue.parse(payload)
        } catch {
            throw TelegramOffsetCursorError.malformed
        }
        return try Self.offset(from: decoded)
    }

    /// Advances the cursor without ever moving it backwards. The read, compare,
    /// and durable write share the canonical sidecar lock so a second process
    /// cannot overwrite a newer cursor with an older poll result.
    @discardableResult
    public func advance(to requestedOffset: Int) async throws -> Int {
        guard requestedOffset >= 0 else {
            throw TelegramOffsetCursorError.invalidOffset
        }
        let cursor = self
        return try await persistence.withFileLock(fileURL) {
            let current = try cursor.load()
            let next = max(current, requestedOffset)
            if next != current || !FileManager.default.fileExists(atPath: cursor.fileURL.path) {
                try await cursor.persistence.writeJSON(
                    .object(["offset": .int(Int64(next))]),
                    to: cursor.fileURL
                )
            }
            return next
        }
    }

    private static func offset(from value: JSONValue) throws -> Int {
        guard case .object(let object) = value,
              let rawOffset = object["offset"] else {
            throw TelegramOffsetCursorError.malformed
        }

        switch rawOffset {
        case .int(let value):
            guard value >= 0, value <= Int64(Int.max) else {
                throw TelegramOffsetCursorError.invalidOffset
            }
            return Int(value)
        case .double(let value):
            guard value.isFinite,
                  value >= 0,
                  value.rounded(.towardZero) == value,
                  let offset = Int(exactly: value) else {
                throw TelegramOffsetCursorError.invalidOffset
            }
            return offset
        default:
            throw TelegramOffsetCursorError.invalidOffset
        }
    }
}

public enum TelegramOffsetCursorError: Error, Sendable, Equatable, LocalizedError {
    case unreadable(String)
    case oversized(actualBytes: Int, maximumBytes: Int)
    case malformed
    case invalidOffset

    public var errorDescription: String? {
        switch self {
        case .unreadable(let detail):
            return "telegram_cursor_unreadable: \(detail). Restore read access to this bot's last_offset.json; do not reset it to zero, which can replay actions."
        case .oversized(let actualBytes, let maximumBytes):
            return "telegram_cursor_oversized: Cursor is \(actualBytes) bytes; limit \(maximumBytes). Repair this bot's last_offset.json with its confirmed offset; resetting to zero can replay actions."
        case .malformed:
            return "telegram_cursor_malformed: Cursor is malformed. Repair this bot's last_offset.json as {\"offset\":N} using its confirmed offset; resetting to zero can replay actions."
        case .invalidOffset:
            return "telegram_cursor_invalid: Offset must be a nonnegative whole number. Repair this bot's last_offset.json using its confirmed offset; resetting to zero can replay actions."
        }
    }
}
