import Foundation
// Blueprint: | `TranscriptSearch.swift` | `TranscriptSearchDocument`, `TranscriptSearch` |

/// JSONL remains authoritative; this rebuildable projection owns no sidecar index or session lifecycle.
public struct TranscriptSearchDocument: Sendable, Equatable {
    public let messageID: String
    public let ordinal: Int
    public let content: String

    public init(messageID: String, ordinal: Int, content: String) {
        self.messageID = messageID
        self.ordinal = ordinal
        self.content = content
    }
}

public enum TranscriptSearch {}
