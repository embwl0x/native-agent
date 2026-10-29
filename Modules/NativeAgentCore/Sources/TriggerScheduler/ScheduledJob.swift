import Foundation
import NativeAgentCore
import PersistenceCore

// Blueprint: | `ScheduledJob.swift` | `ScheduledJob`: strict scheduler row decoding and projected civil next-run decoration while preserving claimed/retry instants |

/// Scheduler list projection: unclaimed wall-clock nextRunAt follows the current
/// zone; active occurrences and retry floors retain their saved instant.
public struct ScheduledJob: Identifiable, Codable, Hashable, Sendable {
    public var id: String
    public var name: String
    public var kind: String
    public var intervalSeconds: Int?
    public var oneShot: Bool?
    public var enabled: Bool
    public var nextRunAt: String?
    public var lastRunAt: String?

    public init(
        id: String, name: String, kind: String, intervalSeconds: Int? = nil,
        enabled: Bool, nextRunAt: String? = nil, lastRunAt: String? = nil,
        oneShot: Bool? = nil
    ) {
        self.id = id
        self.name = name
        self.kind = kind
        self.intervalSeconds = oneShot == true ? nil : intervalSeconds
        self.oneShot = oneShot
        self.enabled = enabled
        self.nextRunAt = nextRunAt
        self.lastRunAt = lastRunAt
    }

    public var onceScheduleDescription: String? {
        guard oneShot == true else { return nil }
        guard let nextRunAt else { return "Once." }
        guard let date = SwiftNativeTriggerScheduler.parseISOTimestamp(nextRunAt) else {
            return "Once — scheduled time unavailable."
        }
        let formatter = DateFormatter()
        formatter.timeZone = TimeZone.autoupdatingCurrent
        formatter.dateStyle = .medium
        formatter.timeStyle = .short
        return "Once at \(formatter.string(from: date))."
    }

    public enum RowError: Error, LocalizedError {
        case notAnObject
        case field(String)

        public var errorDescription: String? {
            switch self {
            case .notAnObject: return "scheduler job row is not an object"
            case .field(let key): return "scheduler job row has no valid \(key)"
            }
        }
    }

    /// A listed writer row. `id`, `name`, `kind` and `enabled` are required;
    /// a present field of the wrong type makes the row malformed, never
    /// silently absent.
    public init(row: JSONValue) throws {
        do {
            let row = try JSONRow(SchedulerJobNormalizer.decorateNextRunAt(row))
            self.id = try row.string("id")
            self.name = try row.string("name")
            self.kind = try row.string("kind")
            self.oneShot = try row.optionalBool("oneShot")
            self.intervalSeconds = try row.optionalInt("intervalSeconds")
            guard let enabled = try row.optionalBool("enabled") else { throw RowError.field("enabled") }
            self.enabled = enabled
            self.nextRunAt = try row.optionalString("nextRunAt")
            self.lastRunAt = try row.optionalString("lastRunAt")
        } catch let error as JSONRow.Malformed {
            switch error {
            case .notAnObject: throw RowError.notAnObject
            case .field(let key): throw RowError.field(key)
            }
        }
    }
}
