import Foundation
import NativeAgentCore
import PersistenceCore

// Blueprint: | `MemoryV2+DueDateStamp.swift` | `MemoryDueDateStamp`: writer-named instants |

public enum MemoryDueDateStamp {
    public static let dueAtKey = "due_at"
    public static let dueSourceKey = "due_source"

    /// Only writer-supplied instants establish a plan; unsupported stamps leave stored rows intact.
    public static func dueAt(in metadata: JSONValue?) -> Date? {
        guard case .object(let object)? = metadata,
              object[dueSourceKey] != .string("write_extractor_v1"),
              case .string(let raw)? = object[dueAtKey] else { return nil }
        return MemoryRecallScoring.parseTimestamp(raw)
    }
}
