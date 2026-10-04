import Foundation
import NativeAgentCore
import PersistenceCore

/// One row of `scheduler/jobs.json` as the Schedule and the Desk show it
/// (S10): the fields every job carries, read from the writer's listed row.
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
        formatter.timeZone = DisplayTimeZone.current
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
        guard case .object(let obj) = SchedulerJobNormalizer.decorateNextRunAt(row) else {
            throw RowError.notAnObject
        }
        func string(_ key: String) throws -> String {
            guard case .string(let value)? = obj[key] else { throw RowError.field(key) }
            return value
        }
        func optionalString(_ key: String) throws -> String? {
            switch obj[key] {
            case nil, .null?: return nil
            case .string(let value)?: return value
            default: throw RowError.field(key)
            }
        }
        self.id = try string("id")
        self.name = try string("name")
        self.kind = try string("kind")
        switch obj["oneShot"] {
        case nil, .null?: self.oneShot = nil
        case .bool(let value)?: self.oneShot = value
        default: throw RowError.field("oneShot")
        }
        switch obj["intervalSeconds"] {
        case nil, .null?:
            self.intervalSeconds = nil
        case .int(let value)?:
            guard let seconds = Int(exactly: value) else { throw RowError.field("intervalSeconds") }
            self.intervalSeconds = seconds
        case .double(let value)?:
            guard let seconds = Int(exactly: value) else { throw RowError.field("intervalSeconds") }
            self.intervalSeconds = seconds
        default:
            throw RowError.field("intervalSeconds")
        }
        guard case .bool(let enabled)? = obj["enabled"] else { throw RowError.field("enabled") }
        self.enabled = enabled
        self.nextRunAt = try optionalString("nextRunAt")
        self.lastRunAt = try optionalString("lastRunAt")
    }
}
