import Foundation

// Blueprint: | `MemoryCandidateQuality.swift` | `MemoryCandidateQuality`: source-independent shape gates |

public enum MemoryCandidateQuality {
    /// Apply empty, transient-state and tool-noise rejection in that order for every source.
    public static func rejectionReason(text: String, source: String? = nil, kind: String? = nil) -> String? {
        let normalized = normalize(text)
        guard !normalized.isEmpty else { return "empty memory candidate" }
        if isTransientSessionState(normalized) {
            return "transient session/context state is not durable memory"
        }
        if isToolTranscriptNoise(normalized) {
            return "call transcript/status output is not durable memory"
        }
        return nil
    }

    public static func isDurableCandidate(text: String, source: String? = nil, kind: String? = nil) -> Bool {
        rejectionReason(text: text, source: source, kind: kind) == nil
    }

    private static func normalize(_ text: String) -> String {
        text
            .replacingOccurrences(of: "’", with: "'")
            .replacingOccurrences(of: "‘", with: "'")
            .replacingOccurrences(of: "\\s+", with: " ", options: .regularExpression)
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .trimmingCharacters(in: CharacterSet(charactersIn: "\"'` "))
            .lowercased()
    }

    private static func matches(_ text: String, _ pattern: String) -> Bool {
        text.range(of: pattern, options: .regularExpression) != nil
    }

    private static func isTransientSessionState(_ text: String) -> Bool {
        let lifecyclePatterns = [
            #"^(?:the\s+)?(?:user'?s|agent'?s|assistant'?s|nativeagent'?s)?\s*(?:current\s+)?(?:session|conversation|chat)\s+context\s+(?:is|was|has\s+been|got|gets)?\s*(?:reset|cleared|compacted|truncated)\.?$"#,
            #"^(?:the\s+)?(?:current\s+)?(?:session|conversation|chat)\s+(?:is|was|has\s+been|got|gets)?\s*(?:reset|cleared|compacted|truncated)\.?$"#,
            #"^(?:the\s+)?(?:context|context\s+window)\s+(?:is|was|has\s+been|got|gets)?\s*(?:reset|cleared|compacted|truncated)\.?$"#,
        ]
        return lifecyclePatterns.contains { matches(text, $0) }
    }

    private static func isToolTranscriptNoise(_ text: String) -> Bool {
        let prefixes = [
            "[cognitivesubstrate]",
            "cognitive capsule:",
            "private working state",
            "app lifecycle:",
            "applifecycle:",
            "focus:",
            "correction:",
            "thread:",
            "inner:",
            "body:",
            "open:",
            "expect:",
            "feeling:",
            "voice:",
            "- body:",
            "settling:",
            "- settling:",
            "conversation focus:",
            "conversationfocus:",
            "current focus:",
            "currentfocus:",
            "recent correction:",
            "recentcorrection:",
            "inner thread:",
            "innerthread:",
            "open commitment:",
            "opencommitment:",
            "expectation:",
            "affect:",
            "reflection takeaway:",
            "reflectiontakeaway:",
            "tool observation:",
            "toolobservation:",
            "bash ok:",
            "read_file ok:",
            "write_file ok:",
            "list_dir ok:",
            "run_id:",
            "session_id:",
        ]
        return prefixes.contains { text.hasPrefix($0) }
    }

}
