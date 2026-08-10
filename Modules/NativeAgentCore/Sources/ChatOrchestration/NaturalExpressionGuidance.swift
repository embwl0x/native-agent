import Foundation

/// Small shared prompt tissue that helps the active persona sound less like a
/// repeated response template. It is deliberately not a personality owner:
/// persona documents remain authoritative, and this helper creates no state,
/// model call, output rewrite, or provider-specific behavior.
struct NaturalExpressionGuidance {
    static let baseline = "Let the persona lead. Speak naturally in the moment, with the varied rhythm, looseness, and occasional simplicity of real conversation."

    static let rutCue = "Your recent replies have settled into one rhythm; loosen up and let this one take its own shape."

    /// Detect only a repeated *shape* at the conversational edge. Word-level
    /// register awareness remains CognitiveSubstrate Sound's job. Looking at
    /// the newest six assistant rows bounds CPU work and makes the cue cool as
    /// soon as the latest reply stops matching the shared template.
    static func pendingRutCue(from messages: [ChatMessage]) -> String? {
        let newestAssistantReplies = messages.reversed().lazy
            .filter { $0.role.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() == "assistant" }
            .prefix(6)
            .map(\.content)
            .reversed()

        guard let latestReply = newestAssistantReplies.last,
              let latest = fingerprint(latestReply) else {
            return nil
        }
        let fingerprints = newestAssistantReplies.compactMap(fingerprint)
        guard fingerprints.count >= 3 else { return nil }

        // A single broad feature (for example, using paragraphs) is ordinary
        // writing. Require the latest reply and at least two earlier replies to
        // share the same pair of structural beats.
        let featurePairs: [(Shape, Shape)] = [
            (.briefLeadIn, .multiParagraph),
            (.briefLeadIn, .compactClose),
            (.briefLeadIn, .contrastFrame),
            (.multiParagraph, .compactClose),
            (.multiParagraph, .contrastFrame),
            (.compactClose, .contrastFrame),
        ]
        for (first, second) in featurePairs
        where latest.contains(first) && latest.contains(second) {
            let matches = fingerprints.filter { $0.contains(first) && $0.contains(second) }.count
            if matches >= 3 { return rutCue }
        }
        return nil
    }

    private struct Shape: OptionSet {
        let rawValue: UInt8

        static let briefLeadIn = Shape(rawValue: 1 << 0)
        static let multiParagraph = Shape(rawValue: 1 << 1)
        static let compactClose = Shape(rawValue: 1 << 2)
        static let contrastFrame = Shape(rawValue: 1 << 3)
    }

    private static func fingerprint(_ raw: String) -> Shape? {
        let text = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard text.count >= 80, text.count <= 1_800,
              !text.contains("```"), !text.contains("|---") else {
            return nil
        }

        let lines = text.split(separator: "\n", omittingEmptySubsequences: false)
        let structuredLines = lines.filter { line in
            let value = line.trimmingCharacters(in: .whitespaces)
            guard !value.isEmpty else { return false }
            if value.hasPrefix("#") || value.hasPrefix("- ") || value.hasPrefix("* ")
                || value.hasPrefix("> ") || value.hasPrefix("| ") {
                return true
            }
            let prefix = value.prefix(4)
            return prefix.contains(".") && prefix.first?.isNumber == true
        }.count
        guard structuredLines < 2 else { return nil }

        let paragraphs = text.components(separatedBy: "\n\n")
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
        var shape: Shape = []

        if let firstParagraph = paragraphs.first {
            let firstBoundary = firstParagraph.firstIndex(where: { ".!?—:\n".contains($0) })
            let lead = firstBoundary.map { String(firstParagraph[..<$0]) } ?? firstParagraph
            if lead.split(whereSeparator: \.isWhitespace).count <= 7,
               lead.count <= 52,
               text.count > lead.count + 45 {
                shape.insert(.briefLeadIn)
            }
        }
        if (3...7).contains(paragraphs.count) {
            shape.insert(.multiParagraph)
        }
        if let close = paragraphs.last,
           (18...180).contains(close.count),
           !close.contains("?"),
           sentenceCount(close) <= 2 {
            shape.insert(.compactClose)
        }

        let lower = " " + text.lowercased()
            .replacingOccurrences(of: "\n", with: " ") + " "
        let hasContrast = (lower.contains(" not ") && lower.contains(" but "))
            || (lower.contains(" isn't ") && lower.contains(" it's "))
            || (lower.contains(" wasn't ") && lower.contains(" it was "))
            || (lower.contains(" doesn't ") && lower.contains(" it "))
            || (lower.contains(" don't ") && lower.contains(" just "))
        if hasContrast { shape.insert(.contrastFrame) }

        return shape.isEmpty ? nil : shape
    }

    private static func sentenceCount(_ text: String) -> Int {
        max(1, text.reduce(into: 0) { count, character in
            if ".!?".contains(character) { count += 1 }
        })
    }
}

extension SwiftNativeTurnEngine {
    nonisolated static func contextBySettingNaturalExpressionCue(
        _ context: TurnContext,
        cue: String?
    ) -> TurnContext {
        TurnContext(
            surface: context.surface,
            personaID: context.personaID,
            personaDocs: context.personaDocs,
            recalled: context.recalled,
            modelId: context.modelId,
            reasoningEffort: context.reasoningEffort,
            providerId: context.providerId,
            serviceTier: context.serviceTier,
            toolsAvailable: context.toolsAvailable,
            systemPrompt: context.systemPrompt,
            userMessage: context.userMessage,
            toolSchemas: context.toolSchemas,
            systemSegments: context.systemSegments,
            imageBlocks: context.imageBlocks,
            fluidContextTurn: context.fluidContextTurn,
            naturalExpressionCue: cue
        )
    }
}
