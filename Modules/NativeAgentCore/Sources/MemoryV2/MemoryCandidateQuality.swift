import Foundation

// Blueprint: | `MemoryCandidateQuality.swift` | `MemoryCandidateQuality`: shared durable-candidate hygiene and explicit incomplete-fragment rejection reasons |

public enum MemoryCandidateQuality {
    /// Rejection reason for incomplete automatic thoughts.
    public static let midThoughtFragmentReason = "mid-thought fragment is not durable memory"

    /// Rejects empty text, transient state and tool noise for every source, in that order.
    /// Only automatic sources then reject semantic fragments, incomplete thoughts, conversational vapor
    /// and context-dependent payloads, in that order, subject to kind and prefix guards.
    public static func rejectionReason(text: String, source: String? = nil, kind: String? = nil) -> String? {
        let normalized = normalize(text)
        guard !normalized.isEmpty else { return "empty memory candidate" }
        if isTransientSessionState(normalized) {
            return "transient session/context state is not durable memory"
        }
        if isToolTranscriptNoise(normalized) {
            return "tool transcript/status output is not durable memory"
        }
        guard isAutomaticExtractionSource(source) else { return nil }
        let normalizedKind = kind?.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        let semanticKind = normalizedKind.map {
            ["preference", "goal", "fact", "attribute", "cognitive_proposal"].contains($0)
        } ?? true
        let prefix = [
            "likes:", "prefers:", "values:", "dislikes:", "goal:",
            "user likes", "user prefers", "user values", "user dislikes",
            "user wants", "user needs", "user would like"
        ].first { normalized.hasPrefix($0) }
        let payload = prefix.map {
            String(normalized.dropFirst($0.count)).trimmingCharacters(in: .whitespacesAndNewlines)
        }
        if semanticKind, let prefix, !["dislikes:", "user dislikes"].contains(prefix),
           isIncompleteSemanticFragment(normalized) {
            return "incomplete semantic fragment is not durable memory"
        }
        if isIncompleteThought(normalized) {
            return midThoughtFragmentReason
        }
        if semanticKind, let payload, isConversationalVapor(payload) {
            return "low-quality conversational fragment is not durable memory"
        }
        if semanticKind || normalizedKind == "relationship", let payload,
           isContextDependentAutomaticSemantic(payload) {
            return "context-dependent automatic extraction is not durable memory"
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

    /// Rejects incomplete automatic captures across kinds; deliberate facts may end in function words.
    private static let hardTailStopwords: Set<String> = [
        "a", "an", "the", "this", "these", "those", "some", "any",
        "my", "your", "their", "our",
        "is", "are", "was", "were", "be", "been", "being", "am",
        "do", "does", "have", "has", "had",
        "can", "could", "will", "would", "shall", "should", "may", "might",
        "must",
        "to", "of", "in", "on", "at", "by", "for", "with", "without",
        "about", "into", "onto", "over", "under", "between", "through",
        "from", "as", "than",
        "and", "or", "but", "nor", "because", "since", "if", "while",
        "when", "where", "how", "which", "whom", "why",
        "whether",
    ]
    /// Automatic extraction alone rejects determiner, quantifier, pronoun and adverb tails.
    private static let automaticTailStopwords: Set<String> = [
        "other", "another", "more", "most", "such", "several", "certain",
        "few", "fewer", "each", "every", "either", "neither",
        "i", "me", "we", "us", "you", "he", "him", "she", "they", "them",
        "it", "its", "mine", "yours", "hers", "theirs", "ours", "that",
        "his", "her", "who",
        "now", "then", "just", "still", "yet", "very", "really", "quite",
        "too", "also", "sometimes", "often", "always", "never", "not",
        "no", "yes", "so", "what",
    ]

    private static func isIncompleteThought(_ text: String) -> Bool {
        let words = text.split { !($0.isLetter || $0.isNumber || $0 == "'") }
            .map(String.init)
        guard let last = words.last?.lowercased() else { return true }
        if hardTailStopwords.contains(last) { return true }
        // A copula followed by a bare adverb/yes/no is a missing complement
        // in automatic captures ("user's design review is now").
        if matches(text, #"\b(?:is|are|was|were|be|been|being)\s+(?:now|then|still|yet|often|sometimes|always|never|really|very|quite|too|also|no|yes)$"#) {
            return true
        }
        if automaticTailStopwords.contains(last) { return true }
        return false
    }

    private static func isIncompleteSemanticFragment(_ text: String) -> Bool {
        let openTailPatterns = [
            #"\b(?:to|for|with|without|about|as|of|in|on|at|by)\s+(?:be|feel|do|have|get|make|use|see|know|work|run|go|look|act|become|stay)\.?$"#,
            #"\b(?:to|for|with|without|about|because|so|that|when|while|where|how|as|of|in|on|at|by)\.?$"#,
        ]
        return openTailPatterns.contains { matches(text, $0) }
    }

    /// Rejects verbose, ephemeral or assistant-directed payloads.
    private static func isConversationalVapor(_ body: String) -> Bool {
        guard !body.isEmpty else { return true }
        let words = body.split { !($0.isLetter || $0.isNumber) }.map(String.init)

        // Bound word count, not commas, so list preferences remain valid.
        if words.count > 12 { return true }

        // Specific activity phrases leave other gerund and adverbial facts eligible.
        let ephemeralOpeners = ["trying to ", "being able to ", "getting to ", "wanting to "]
        if ephemeralOpeners.contains(where: { body.hasPrefix($0) }) { return true }

        // Restrict objects to you/yiu/me so acronyms and third parties remain eligible.
        let paddedBody = " " + body + " "
        if matches(paddedBody, #"\b(?:with|to|about|toward|towards|for)\s+(?:you|yiu|me)\b"#) {
            return true
        }
        if matches(paddedBody, #"\byou\s+are\b"#) || matches(paddedBody, #"\byou're\b"#) {
            return true
        }
        if let last = words.last, ["you", "yiu", "me"].contains(last) { return true }

        return false
    }

    /// Rejects payloads that need the original turn to resolve references or conversational wording.
    private static func isContextDependentAutomaticSemantic(_ body: String) -> Bool {
        let words = body.split { !($0.isLetter || $0.isNumber || $0 == "'") }
            .map { String($0).lowercased() }
        guard let first = words.first else { return true }

        let unresolvedOpeners: Set<String> = [
            "actually", "really", "whatever", "whichever", "something",
            "anything", "nothing", "everything"
        ]
        if unresolvedOpeners.contains(first) { return true }

        let unresolvedTokens: Set<String> = [
            // Bare "it" may be the IT acronym after normalization.
            "this", "that", "these", "those", "here", "there",
            "you", "your", "yours"
        ]
        if words.contains(where: unresolvedTokens.contains) { return true }

        let padded = " " + body.lowercased() + " "
        let conversationalClosers = [
            " don't worry ", " dont worry ", " that's fine ",
            " thats fine ", " is fine ", " no worries "
        ]
        if conversationalClosers.contains(where: padded.contains) { return true }

        let unresolvedTerminalStates: Set<String> = [
            "gone", "done", "fine", "okay", "ok", "ready", "back",
            "built", "fixed", "working"
        ]
        if words.count <= 2,
           let last = words.last,
           unresolvedTerminalStates.contains(last) {
            return true
        }

        return false
    }

    private static func isAutomaticExtractionSource(_ source: String?) -> Bool {
        guard let source = source?
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased(),
              !source.isEmpty else {
            return false
        }
        return source == "semantic-adaptive-extractor"
            || source == "adaptive-promoter"
            || source.hasPrefix("adaptive-promoter:")
    }
}
