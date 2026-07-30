import Foundation
import NativeAgentCore

#if canImport(FoundationModels)
import FoundationModels
#endif

// MARK: - Apple Foundation Models adapter (on-device fact extraction)
//
// Primary fact-extraction path for sister workers m5 (AdaptiveMemoryPromoter)
// and m6 (MemoryConsolidator). Uses Apple Intelligence's on-device
// `SystemLanguageModel` when available (macOS 26+ Apple-Intelligence Macs);
// callers should fall back to `RuleBasedFactExtractor` (below) when
// `isAvailable == false` or `extractFacts(_:)` throws `.unavailable`.

public struct ExtractedFact: Sendable, Codable, Equatable {
    public var content: String
    public var confidence: Double
    public var category: String

    public init(content: String, confidence: Double, category: String) {
        self.content = content
        self.confidence = confidence
        self.category = category
    }
}

public enum FoundationModelsError: Error, Sendable, Equatable {
    case unavailable
    case decodeFailed(String)
    case generationFailed(String)
    /// `classify` got a model reply that matches none of the candidate
    /// categories. Callers must DROP the item (or retry), never substitute a
    /// default — the associated value is the offending reply, for logs.
    case classificationNoMatch(String)
}

public enum AppleFoundationModelsAdapter {

    /// True only on macOS 26+ with Apple Intelligence enabled and the
    /// `FoundationModels` framework present at compile time.
    public static var isAvailable: Bool {
        #if canImport(FoundationModels)
        if #available(macOS 26, *) {
            return SystemLanguageModel.default.isAvailable
        }
        return false
        #else
        return false
        #endif
    }

    /// Ask the on-device model to surface durable user facts from `text` as
    /// JSON `[{content, confidence, category}]`.
    public static func extractFacts(from text: String) async throws -> [ExtractedFact] {
        #if canImport(FoundationModels)
        if #available(macOS 26, *), SystemLanguageModel.default.isAvailable {
            let prompt = factExtractionPrompt(for: text)
            do {
                let session = LanguageModelSession()
                let response = try await session.respond(to: prompt)
                return try parseFacts(response.content).compactMap(MemoryFactQuality.cleanedExtractedFact)
            } catch let error as FoundationModelsError {
                throw error
            } catch {
                throw FoundationModelsError.generationFailed(String(describing: error))
            }
        }
        throw FoundationModelsError.unavailable
        #else
        throw FoundationModelsError.unavailable
        #endif
    }

    /// Single-label classification helper. Returns the chosen category
    /// verbatim from `categories`. Throws `.classificationNoMatch` when the
    /// model's reply matches none of them — a reply that can't be trusted
    /// must be dropped by the caller, never coerced. (The old behavior
    /// fell back to `categories.first`, which for the kind-backfill taxonomy
    /// was "identity" — malformed FM output became an approved-looking card
    /// row; gpt-5.5 U3w2 fix-round finding 1.)
    public static func classify(content: String, into categories: [String]) async throws -> String {
        guard !categories.isEmpty else {
            throw FoundationModelsError.generationFailed("empty categories")
        }
        #if canImport(FoundationModels)
        if #available(macOS 26, *), SystemLanguageModel.default.isAvailable {
            let prompt = classifyPrompt(content: content, categories: categories)
            do {
                let session = LanguageModelSession()
                let response = try await session.respond(to: prompt)
                return try matchCategory(reply: response.content, categories: categories)
            } catch let error as FoundationModelsError {
                throw error
            } catch {
                throw FoundationModelsError.generationFailed(String(describing: error))
            }
        }
        throw FoundationModelsError.unavailable
        #else
        throw FoundationModelsError.unavailable
        #endif
    }

    /// Match a raw model reply against the candidate categories: EXACT
    /// (case-insensitive, whitespace/punctuation-trimmed) or throw
    /// `.classificationNoMatch`. The earlier category-as-substring branch
    /// was removed (gpt-5.5 delta re-review, 2026-06-10): a chatty or
    /// NEGATED reply ("not a preference") substring-matched "preference" —
    /// fabricating exactly the kind the no-fabrication contract forbids.
    /// An unparseable reply drops the row from the proposal card instead.
    /// Split out so the malformed-reply path is unit-testable on non-AI
    /// Macs (the model call itself requires Apple Intelligence).
    static func matchCategory(reply: String, categories: [String]) throws -> String {
        let trimmed = reply
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .trimmingCharacters(in: CharacterSet(charactersIn: ".\"'`"))
        if let match = categories.first(where: { $0.caseInsensitiveCompare(trimmed) == .orderedSame }) {
            return match
        }
        throw FoundationModelsError.classificationNoMatch(trimmed)
    }

    // MARK: prompts

    static func factExtractionPrompt(for text: String) -> String {
        """
        Extract durable, long-lived facts about the user from the conversation \
        snippet below. Skip ephemeral chatter, opinions, and questions. \
        Return ONLY valid JSON: an array of objects, each with keys \
        "content" (string, the fact), "confidence" (0.0–1.0), and "category" \
        (one of: identity, preference, relationship, goal, skill, schedule, other).
        If no durable facts are present, return [].

        Conversation snippet:
        \"\"\"
        \(text)
        \"\"\"

        JSON:
        """
    }

    static func classifyPrompt(content: String, categories: [String]) -> String {
        """
        Choose exactly one category for the content. Respond with only the \
        category label, nothing else.

        Categories: \(categories.joined(separator: ", "))

        Content: \(content)

        Category:
        """
    }

    // MARK: parsing

    static func parseFacts(_ raw: String) throws -> [ExtractedFact] {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        let json = extractJSONArray(from: trimmed) ?? trimmed
        guard let data = json.data(using: .utf8) else {
            throw FoundationModelsError.decodeFailed("non-utf8 reply")
        }
        do {
            return try JSONDecoder().decode([ExtractedFact].self, from: data)
        } catch {
            throw FoundationModelsError.decodeFailed(String(describing: error))
        }
    }

    private static func extractJSONArray(from text: String) -> String? {
        guard let start = text.firstIndex(of: "["),
              let end = text.lastIndex(of: "]"),
              start < end else { return nil }
        return String(text[start...end])
    }
}

// MARK: - Fact quality gate

enum MemoryFactQuality {
    /// Keep the automatic write path precision-biased. Phrases like
    /// "I want it to be live..." depend on nearby chat context; once detached
    /// as a memory, "it" is meaningless and actively harms recall.
    static func cleanedExtractedFact(_ fact: ExtractedFact) -> ExtractedFact? {
        guard let content = cleanedContent(fact.content, category: fact.category) else {
            return nil
        }
        return ExtractedFact(
            content: content,
            confidence: fact.confidence,
            category: fact.category
        )
    }

    static func cleanedCanonicalCandidate(_ candidate: AdaptiveCandidate) -> AdaptiveCandidate? {
        guard let content = cleanedContent(candidate.content, category: candidate.kind) else {
            return nil
        }
        return AdaptiveCandidate(
            content: content,
            score: candidate.score,
            kind: candidate.kind
        )
    }

    private static func cleanedContent(_ content: String, category: String) -> String? {
        let normalizedCategory = category
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased()
        let scopedCategories = Set([
            "identity", "preference", "relationship", "goal",
            "skill", "schedule", "attribute", "location", "employment",
            "fact", "other"
        ])
        let normalized = content
            .replacingOccurrences(of: "\\s+", with: " ", options: .regularExpression)
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .trimmingCharacters(in: CharacterSet(charactersIn: ".!?,;:"))

        guard scopedCategories.contains(normalizedCategory) else {
            return normalized.isEmpty ? nil : normalized
        }

        let displayNormalized = MemoryTextClip.memoryDisplayText(
            normalized,
            kind: normalizedCategory
        )
        let (prefix, payload) = splitPrefix(from: displayNormalized)
        guard let cleaned = cleanPayload(payload, prefix: prefix) else { return nil }
        let result = prefix + cleaned
        guard MemoryCandidateQuality.isDurableCandidate(
            text: result,
            source: "semantic-adaptive-extractor",
            kind: normalizedCategory
        ) else {
            return nil
        }
        return result.isEmpty ? nil : result
    }

    private static func splitPrefix(from content: String) -> (prefix: String, payload: String) {
        let lower = content.lowercased()
        let prefixes: [(match: String, emit: String)] = [
            ("goal: ", "Goal: "), ("goal:", "Goal: "),
            ("likes: ", "Likes: "), ("likes:", "Likes: "),
            ("prefers: ", "Prefers: "), ("prefers:", "Prefers: "),
            ("dislikes: ", "Dislikes: "), ("dislikes:", "Dislikes: "),
            ("values: ", "Values: "), ("values:", "Values: "),
            ("name: ", "Name: "), ("name:", "Name: "),
            ("role: ", "Role: "), ("role:", "Role: "),
            ("context: ", "Context: "), ("context:", "Context: "),
            ("user wants ", "user wants "),
            ("user's name is ", "user's name is "),
            ("user is ", "user is "),
            ("user context: ", "user context: "),
            ("user likes ", "user likes "),
            ("user prefers ", "user prefers "),
            ("user dislikes ", "user dislikes "),
            ("user values ", "user values "),
            ("user needs ", "user needs "),
            ("user would like ", "user would like ")
        ]
        for prefix in prefixes where lower.hasPrefix(prefix.match) {
            let payload = String(content.dropFirst(prefix.match.count))
                .trimmingCharacters(in: .whitespacesAndNewlines)
                .trimmingCharacters(in: CharacterSet(charactersIn: ".!?,;:"))
            return (prefix.emit, payload)
        }
        return ("", content)
    }

    private static func cleanPayload(_ payload: String, prefix: String) -> String? {
        var cleaned = payload
            .replacingOccurrences(
                of: #"(?i)\s+(?:so|because|since)\s+(?:he|hes|he's|she|shes|she's|they|theyre|they're)\b.*$"#,
                with: "",
                options: .regularExpression
            )
            .replacingOccurrences(
                of: #"(?i)\blike\s+we\s+are\s+in\s+telegram\b"#,
                with: "like Telegram",
                options: .regularExpression
            )
            .replacingOccurrences(
                of: #"(?i)\blike\s+it\s+is\s+in\s+telegram\b"#,
                with: "like Telegram",
                options: .regularExpression
            )
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .trimmingCharacters(in: CharacterSet(charactersIn: ".!?,;:"))
        cleaned = cleaned
            .replacingOccurrences(of: "\\s+", with: " ", options: .regularExpression)
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .replacingOccurrences(
                of: #"(?i)\bwhich\s+got\s+us\s+into\b.*$"#,
                with: "",
                options: .regularExpression
            )
            .replacingOccurrences(
                of: #"(?i)(?:\s+(?:anyways?|lol|lmao|haha|geez))+$"#,
                with: "",
                options: .regularExpression
            )
            .trimmingCharacters(in: .whitespacesAndNewlines)

        let normalizedPrefix = prefix.lowercased()
        let preferencePrefixes = ["likes: ", "prefers: ", "user likes ", "user prefers "]

        var words = cleaned.lowercased()
            .split { character in
                !(character.isLetter || character.isNumber)
            }
            .map(String.init)
        guard let first = words.first else { return nil }

        let goalPrefixes = ["goal: ", "user wants ", "user needs ", "user would like "]
        if goalPrefixes.contains(normalizedPrefix) {
            let firstPersonGoalPrefixes = [
                "i would like to ", "i would like ", "i'd like to ", "i'd like ",
                "i want to ", "i want ", "i need to ", "i need "
            ]
            if let match = firstPersonGoalPrefixes.first(where: {
                cleaned.lowercased().hasPrefix($0)
            }) {
                cleaned = String(cleaned.dropFirst(match.count))
                    .trimmingCharacters(in: .whitespacesAndNewlines)
                    .trimmingCharacters(in: CharacterSet(charactersIn: ".!?,;:"))
                words = cleaned.lowercased()
                    .split { character in
                        !(character.isLetter || character.isNumber)
                    }
                    .map(String.init)
                guard !words.isEmpty else { return nil }
            }
        }

        if preferencePrefixes.contains(normalizedPrefix), first == "your" {
            let rest = cleaned
                .dropFirst("your".count)
                .trimmingCharacters(in: .whitespacesAndNewlines)
            guard !rest.isEmpty else { return nil }
            cleaned = "assistant's \(rest)"
            words = cleaned.lowercased()
                .split { character in
                    !(character.isLetter || character.isNumber)
                }
                .map(String.init)
        }

        let unresolvedStarts: Set<String> = [
            "it", "this", "that", "these", "those", "they", "them",
            "he", "she", "him", "her", "we", "you", "your", "yours", "us", "me"
        ]
        guard let cleanedFirst = words.first else { return nil }
        if unresolvedStarts.contains(cleanedFirst) { return nil }
        if cleanedFirst == "to" { return nil }

        let chattyMarkers = [
            " really good now", " so good now"
        ]
        if chattyMarkers.contains(where: { cleaned.lowercased().contains($0) }) { return nil }

        if preferencePrefixes.contains(normalizedPrefix), words.count <= 1 {
            return nil
        }

        let speculativeMarkers = [
            " who may be ", " may be a ", " may be an ", " might be ",
            " possibly ", " based on ", " appears to ", " seems to "
        ]
        let paddedLower = " " + cleaned.lowercased() + " "
        if speculativeMarkers.contains(where: { paddedLower.contains($0) }) { return nil }

        let narrativeSubjects: Set<String> = ["he", "hes", "she", "shes", "they", "theyre"]
        let narrativeLinks: Set<String> = ["so", "because", "since"]
        if words.indices.dropLast().contains(where: { index in
            narrativeLinks.contains(words[index]) && narrativeSubjects.contains(words[index + 1])
        }) {
            return nil
        }

        let operationalPairs: Set<String> = [
            "do it", "doing it", "fix it", "check it", "look at it",
            "open it", "run it", "make it", "change it", "update it"
        ]
        let lower = words.joined(separator: " ")
        if operationalPairs.contains(where: { lower.contains($0) }) { return nil }

        return cleaned
    }
}

// MARK: - Rule-based fallback extractor
//
// Used when AppleFoundationModelsAdapter is unavailable. Conservative
// regex sweep — favors precision over recall so the promoter/consolidator
// don't get flooded on non-AI Macs.

public enum FoundationModelsRuleFallback {

    /// U3 wave-1 item 2: value-capture cap (shared constant in
    /// MemoryV2+TextClip.swift). The old {1,60}/{1,80} caps chopped values
    /// mid-phrase; the generous cap lets a value run to its natural
    /// boundary and `MemoryTextClip.wordSafeCapture` in `match` guarantees
    /// no extracted fact ever ends mid-word.
    static let valueCap = memoryExtractionCaptureCap

    public static func extractFacts(from text: String) -> [ExtractedFact] {
        var out: [ExtractedFact] = []
        func append(_ fact: ExtractedFact) {
            guard let cleaned = MemoryFactQuality.cleanedExtractedFact(fact) else { return }
            out.append(cleaned)
        }
        let lines = text
            .components(separatedBy: .newlines)
            .flatMap { line in
                line.split { character in
                    character == "." || character == "!" || character == "?"
                }.map(String.init)
            }
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }

        for line in lines {
            if let m = match(line, pattern: #"(?i)\bmy name is\s+([A-Z][\w'\-]{1,40}(?:\s+[A-Z][\w'\-]{1,40}){0,2})"#) {
                append(ExtractedFact(content: "Name: \(m)", confidence: 0.9, category: "identity"))
                continue
            }
            if let m = match(line, pattern: #"(?i)\bi(?:'m| am)\s+(?:a|an)\s+([\w][\w\s\-]{1,\#(valueCap)})"#) {
                append(ExtractedFact(content: "Role: \(m)", confidence: 0.7, category: "identity"))
                continue
            }
            if let m = match(line, pattern: #"(?i)\bi (?:prefer|would rather)\s+([\w][\w\s\-,]{1,\#(valueCap)})"#) {
                append(ExtractedFact(content: "Prefers: \(m)", confidence: 0.82, category: "preference"))
                continue
            }
            if let m = match(line, pattern: #"(?i)\bi (?:like|love|enjoy)\s+([\w][\w\s\-,]{1,\#(valueCap)})"#) {
                append(ExtractedFact(content: "Likes: \(m)", confidence: 0.80, category: "preference"))
                continue
            }
            if let m = match(line, pattern: #"(?i)\bi (?:hate|dislike|can't stand)\s+([\w][\w\s\-,]{1,\#(valueCap)})"#) {
                append(ExtractedFact(content: "Dislikes: \(m)", confidence: 0.80, category: "preference"))
                continue
            }
            if let m = match(line, pattern: #"(?i)\bi (?:value|care about)\s+([\w][\w\s\-,]{1,\#(valueCap)})"#) {
                append(ExtractedFact(content: "Values: \(m)", confidence: 0.82, category: "preference"))
                continue
            }
            if let m = match(line, pattern: #"(?i)\bi (?:want|need|would like)\s+([\w][\w\s\-,]{1,\#(valueCap)})"#) {
                append(ExtractedFact(content: "Goal: \(m)", confidence: 0.70, category: "goal"))
                continue
            }
            if let m = match(line, pattern: #"(?i)\bi (?:work|live|reside)\s+(?:at|in|for)\s+([\w][\w\s\-,\.]{1,\#(valueCap)})"#) {
                append(ExtractedFact(content: "Context: \(m)", confidence: 0.7, category: "identity"))
                continue
            }
        }
        return out
    }

    private static func match(_ text: String, pattern: String) -> String? {
        guard let regex = try? NSRegularExpression(pattern: pattern) else { return nil }
        let range = NSRange(text.startIndex..<text.endIndex, in: text)
        guard let m = regex.firstMatch(in: text, range: range), m.numberOfRanges >= 2 else { return nil }
        // wordSafeCapture trims a quantifier-capped match back to its last
        // whole word (or rejects it) so no extracted fact ends mid-word.
        guard let captured = MemoryTextClip.wordSafeCapture(text as NSString, range: m.range(at: 1)) else {
            return nil
        }
        let cleaned = captured
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .trimmingCharacters(in: CharacterSet(charactersIn: ".,;:!?"))
        return cleaned.isEmpty ? nil : cleaned
    }
}

// MARK: - Unified facade
//
// Sister workers m5/m6 should call this rather than branching themselves.
// Returns Apple-Intelligence output when available; falls back to the
// rule-based extractor on unavailable / decode failure / generation error.

public enum MemoryFactExtractor {

    public static func extract(from text: String) async -> [ExtractedFact] {
        if AppleFoundationModelsAdapter.isAvailable {
            do {
                return try await AppleFoundationModelsAdapter.extractFacts(from: text)
            } catch {
                return FoundationModelsRuleFallback.extractFacts(from: text)
            }
        }
        return FoundationModelsRuleFallback.extractFacts(from: text)
    }
}

/// Live chat-turn adapter for AdaptiveMemoryPromoter. It keeps the old
/// high-precision regex extractor, adds the broader Swift fact fallback
/// ("I like/prefer/value/want..."), and opportunistically merges Apple
/// Foundation Models facts only when they return inside a short budget.
public struct SemanticAdaptiveFactExtractor: AdaptiveFactExtractor {
    private let foundationTimeoutNanoseconds: UInt64
    private let ruleExtractor: RuleBasedFactExtractor

    public init(foundationTimeoutMilliseconds: UInt64 = 250) {
        self.foundationTimeoutNanoseconds = foundationTimeoutMilliseconds * 1_000_000
        self.ruleExtractor = RuleBasedFactExtractor()
    }

    public func extract(userMessage: String, assistantMessage: String) async -> [AdaptiveCandidate] {
        let raw = Self.userAuthoredExtractionText(from: userMessage)
        guard !raw.isEmpty else { return [] }

        var out: [AdaptiveCandidate] = []
        var seen: [String: Int] = [:]

        func emit(_ candidate: AdaptiveCandidate) {
            guard let cleanedCandidate = MemoryFactQuality.cleanedCanonicalCandidate(candidate) else { return }
            let content = cleanedCandidate.content
                .replacingOccurrences(of: "\\s+", with: " ", options: .regularExpression)
                .trimmingCharacters(in: .whitespacesAndNewlines)
                .trimmingCharacters(in: CharacterSet(charactersIn: ".!?,;:"))
            guard content.count >= 3 else { return }
            let key = content.lowercased()
            if let idx = seen[key] {
                if cleanedCandidate.score > out[idx].score {
                    out[idx] = AdaptiveCandidate(
                        content: content,
                        score: cleanedCandidate.score,
                        kind: cleanedCandidate.kind
                    )
                }
                return
            }
            seen[key] = out.count
            out.append(AdaptiveCandidate(
                content: content,
                score: min(1.0, max(0.0, cleanedCandidate.score)),
                kind: cleanedCandidate.kind
            ))
        }

        for fact in FoundationModelsRuleFallback.extractFacts(from: raw) {
            emit(Self.candidate(from: fact))
        }

        let modelFacts = await Self.foundationFacts(
            from: raw,
            timeoutNanoseconds: foundationTimeoutNanoseconds
        )
        for fact in modelFacts {
            emit(Self.candidate(from: fact))
        }

        for candidate in await ruleExtractor.extract(userMessage: userMessage, assistantMessage: assistantMessage) {
            emit(candidate)
        }

        return out.sorted { lhs, rhs in
            if lhs.score != rhs.score { return lhs.score > rhs.score }
            return lhs.content < rhs.content
        }
    }

    /// Surface adapters may prepend quoted reply context to the actual user
    /// text. That context is useful to the chat model but is not user-authored
    /// evidence: feeding it to the memory extractor lets quoted assistant prose
    /// become a fabricated user fact. Reduce the envelope to the final authored
    /// message before either the rule or Foundation Models extractor sees it.
    static func userAuthoredExtractionText(from message: String) -> String {
        var cleaned = message.trimmingCharacters(in: .whitespacesAndNewlines)

        if let marker = cleaned.range(
            of: "User message:",
            options: [.caseInsensitive, .backwards]
        ) {
            cleaned = String(cleaned[marker.upperBound...])
        } else if let start = cleaned.range(
            of: "[Telegram reply context]",
            options: [.caseInsensitive]
        ) {
            guard let end = cleaned.range(
                of: "[/Telegram reply context]",
                options: [.caseInsensitive]
            ), start.lowerBound < end.upperBound else {
                return ""
            }
            cleaned.removeSubrange(start.lowerBound..<end.upperBound)
        }

        cleaned = cleaned.replacingOccurrences(
            of: "[Telegram voice message]\nTranscript:",
            with: "",
            options: [.caseInsensitive]
        )
        cleaned = cleaned.replacingOccurrences(
            of: "[Telegram voice message] Transcript:",
            with: "",
            options: [.caseInsensitive]
        )
        return cleaned
            .replacingOccurrences(of: "\\s+", with: " ", options: .regularExpression)
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private static func foundationFacts(from text: String, timeoutNanoseconds: UInt64) async -> [ExtractedFact] {
        guard AppleFoundationModelsAdapter.isAvailable, timeoutNanoseconds > 0 else { return [] }
        return await withTaskGroup(of: [ExtractedFact].self, returning: [ExtractedFact].self) { group in
            group.addTask {
                do {
                    return try await AppleFoundationModelsAdapter.extractFacts(from: text)
                } catch {
                    return []
                }
            }
            group.addTask {
                try? await Task.sleep(nanoseconds: timeoutNanoseconds)
                return []
            }
            let first = await group.next() ?? []
            group.cancelAll()
            return first
        }
    }

    private static func candidate(from fact: ExtractedFact) -> AdaptiveCandidate {
        AdaptiveCandidate(
            content: canonicalContent(fact.content),
            score: fact.confidence,
            kind: canonicalKind(fact.category)
        )
    }

    private static func canonicalKind(_ category: String) -> String {
        switch category.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() {
        case "identity": return "identity"
        case "preference": return "preference"
        case "relationship": return "relationship"
        case "goal": return "goal"
        case "skill": return "skill"
        case "schedule": return "schedule"
        default: return "fact"
        }
    }

    private static func canonicalContent(_ raw: String) -> String {
        let trimmed = raw
            .replacingOccurrences(of: "\\s+", with: " ", options: .regularExpression)
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .trimmingCharacters(in: CharacterSet(charactersIn: ".!?,;:"))
        let lower = trimmed.lowercased()
        func suffix(after prefix: String) -> String {
            String(trimmed.dropFirst(prefix.count))
                .trimmingCharacters(in: .whitespacesAndNewlines)
                .trimmingCharacters(in: CharacterSet(charactersIn: ".!?,;:"))
        }
        if lower.hasPrefix("name:") { return "user's name is \(suffix(after: "Name:"))" }
        if lower.hasPrefix("role:") { return "user is \(suffix(after: "Role:"))" }
        if lower.hasPrefix("likes:") { return "user likes \(suffix(after: "Likes:"))" }
        if lower.hasPrefix("prefers:") { return "user prefers \(suffix(after: "Prefers:"))" }
        if lower.hasPrefix("dislikes:") { return "user dislikes \(suffix(after: "Dislikes:"))" }
        if lower.hasPrefix("values:") { return "user values \(suffix(after: "Values:"))" }
        if lower.hasPrefix("goal:") { return "user wants \(suffix(after: "Goal:"))" }
        if lower.hasPrefix("context:") { return "user context: \(suffix(after: "Context:"))" }
        return trimmed
    }
}
