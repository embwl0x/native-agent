import Foundation
import CognitiveSubstrate
import NativeAgentCore
import PersistenceCore

// Blueprint: | `MemoryV2+DueDateStamp.swift` | `MemoryDueDateStamp`: writer-named plan instants, shared horizon clock-relative labels and a date reader that excludes retired prose-extractor stamps |

/// The writer names a plan's instant; this boundary only labels and reads it.
/// Memory prose is never evidence that something is planned for a moment.
public enum MemoryDueDateStamp {
    public static let dueAtKey = "due_at"
    /// Write-time display retained for older readers; never current words or identity.
    public static let dueLabelKey = "due_label"
    public static let dueSourceKey = "due_source"

    /// Derived from the resolved instant against the reader's clock, never prose.
    public static func label(for dueAt: Date, at now: Date, timeZone: TimeZone = .current) -> String {
        OrganismHorizonRegister.statedPlanLabel(for: dueAt, at: now, timeZone: timeZone)
    }

    static func iso8601(_ date: Date) -> String {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime]
        return formatter.string(from: date)
    }

    /// Retired prose-extractor stamps are not plans; leave stored rows intact.
    public static func dueAt(in metadata: JSONValue?) -> Date? {
        guard case .object(let object)? = metadata,
              object[dueSourceKey] != .string("write_extractor_v1"),
              case .string(let raw)? = object[dueAtKey] else { return nil }
        return MemoryRecallScoring.parseTimestamp(raw)
    }
}
