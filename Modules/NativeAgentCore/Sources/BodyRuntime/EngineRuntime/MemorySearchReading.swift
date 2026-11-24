import MindCore
// Blueprint: | `MemorySearchReading.swift` | One memory search's checked reply, independent of later snapshot publication |

public struct MemorySearchReading: Sendable {
    public let query: String
    /// Nil means no search was performed or the search failed; only a completed search returns an array.
    public let records: [MindCore.MemoryRecord]?
    public let issue: String?
}
