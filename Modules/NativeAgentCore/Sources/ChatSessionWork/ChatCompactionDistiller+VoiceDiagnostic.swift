import Foundation
import PersonaEngine
import PersistenceCore
import Experiences
import NativeAgentCore
import ProviderRouting
import Transcripts
import TurnTrace
// Blueprint: | `ChatCompactionDistiller+VoiceDiagnostic.swift` | Quote-aware third-person subject counts, advisory receipt threshold and configured agent name |

extension ChatCompactionDistiller {
    /// Advisory subject predicates at sentence or bullet starts. Names within
    /// another sentence or quoted speech do not count as third-person narration.
    static let thirdPersonPredicates = [
        "said", "agreed", "told", "noted", "decided", "remembered",
        "promised", "felt", "thought", "asked", "wanted", "was", "is",
    ]

    static func thirdPersonSubjectCount(_ text: String, agentName: String) -> Int {
        let name = agentName.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty else { return 0 }
        let unquoted = strippingQuotedSpans(text)
        let pattern = "(?:^[ \\t]*|(?<=[.!?])[ \\t]+)(?:[-*+][ \\t]+|\\d+[.)][ \\t]+)?"
            + NSRegularExpression.escapedPattern(for: name)
            + "\\s+(?:\(thirdPersonPredicates.joined(separator: "|")))\\b"
        guard let regex = try? NSRegularExpression(
            pattern: pattern, options: [.caseInsensitive, .anchorsMatchLines]
        ) else { return 0 }
        return regex.numberOfMatches(
            in: unquoted, options: [], range: NSRange(unquoted.startIndex..., in: unquoted)
        )
    }

    /// Blank quoted spans without changing offsets or line structure.
    private static func strippingQuotedSpans(_ text: String) -> String {
        // Double quotes only; paired apostrophes belong to narration.
        let pattern = "\"[^\"\\n]*\"|“[^”\\n]*”"
        guard let regex = try? NSRegularExpression(pattern: pattern) else { return text }
        var output = text
        let matches = regex.matches(
            in: text, options: [], range: NSRange(text.startIndex..., in: text)
        )
        for match in matches.reversed() {
            guard let range = Range(match.range, in: output) else { continue }
            output.replaceSubrange(
                range, with: String(repeating: " ", count: output[range].count)
            )
        }
        return output
    }

    /// More than this many third-person subject lines flags the receipt.
    static let thirdPersonFlagThreshold = 2

    /// The configured agent name from the shared persona profile.
    package static func configuredAgentName(dataRoot: URL) -> String? {
        do { return try checkedAgentName(dataRoot: dataRoot) }
        catch {
            nativeLog("Conversation voice diagnostic unavailable: %@", error.localizedDescription)
            return nil
        }
    }

    static func checkedAgentName(dataRoot: URL) throws -> String? {
        let profile = try PersonaCompiler.compileProfile(dataRoot: dataRoot)
        let trimmed = profile.name.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }
}
