import Foundation

/// Read-only health boundary for the daemon-owned adaptive context-hints feed.
/// The Swift Context Flow runtime deliberately does not inject these hints: the
/// daemon's adaptive route remains the only authority for that behavior. It
/// does, however, name a missing, malformed, or dormant feed so degraded turn
/// context is not mistaken for a healthy zero-hint state.
public enum ContextHintsFeed {
    public enum Health: Equatable, Sendable {
        case missing
        case empty
        case malformed(rowCount: Int, malformedRows: Int)
        case stale(hintCount: Int, newestUpdatedAt: Date)
        case fresh(hintCount: Int, newestUpdatedAt: Date)

        public var warning: String? {
            switch self {
            case .fresh, .empty:
                return nil
            case .missing:
                return "Context hints feed is missing; adaptive turn guidance is unavailable."
            case .malformed(let rowCount, let malformedRows):
                return "Context hints feed is malformed: \(malformedRows) of \(rowCount) rows could not be read."
            case .stale(let hintCount, let newestUpdatedAt):
                return "Context hints feed is stale: \(hintCount) hints, newest update \(Self.timestamp(newestUpdatedAt))."
            }
        }

        private static func timestamp(_ date: Date) -> String {
            ISO8601DateFormatter().string(from: date)
        }
    }

    public static let relativePath = "context/hints/hints.json"
    public static let maximumAge: TimeInterval = 30 * 24 * 60 * 60

    public static func inspect(
        dataRoot: URL,
        now: Date = Date(),
        maximumAge: TimeInterval = ContextHintsFeed.maximumAge
    ) -> Health {
        let url = dataRoot.appendingPathComponent(relativePath)
        let fileManager = FileManager.default
        guard fileManager.fileExists(atPath: url.path) else { return .missing }
        guard let values = try? url.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey]),
              values.isRegularFile == true,
              values.isSymbolicLink != true,
              let data = try? Data(contentsOf: url),
              let rows = try? JSONSerialization.jsonObject(with: data) as? [[String: Any]] else {
            return .malformed(rowCount: 0, malformedRows: 1)
        }
        guard !rows.isEmpty else { return .empty }

        var newestUpdatedAt: Date?
        var malformedRows = 0
        for row in rows {
            guard nonEmptyString(row["id"]) != nil,
                  nonEmptyString(row["mode"]) != nil,
                  let updatedAt = date(row["updatedAt"])
            else {
                malformedRows += 1
                continue
            }
            newestUpdatedAt = max(newestUpdatedAt ?? updatedAt, updatedAt)
        }
        guard malformedRows == 0, let newestUpdatedAt else {
            return .malformed(rowCount: rows.count, malformedRows: max(1, malformedRows))
        }
        return now.timeIntervalSince(newestUpdatedAt) > maximumAge
            ? .stale(hintCount: rows.count, newestUpdatedAt: newestUpdatedAt)
            : .fresh(hintCount: rows.count, newestUpdatedAt: newestUpdatedAt)
    }

    private static func nonEmptyString(_ value: Any?) -> String? {
        guard let value = value as? String else { return nil }
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }

    private static func date(_ value: Any?) -> Date? {
        guard let raw = nonEmptyString(value) else { return nil }
        let fractional = ISO8601DateFormatter()
        fractional.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return fractional.date(from: raw) ?? ISO8601DateFormatter().date(from: raw)
    }
}
