import Foundation
import NativeAgentCore

#if canImport(FoundationModels)
import FoundationModels
#endif

// MARK: - Apple Foundation Models adapter (on-device classification)
//
// What is LEFT of this adapter, 2026-09-11: `classify`, which the memory kind
// backfill and the kind-repair approval executor use to label an EXISTING row.
//
// The on-device FACT EXTRACTION that used to live here is gone, with
// `ExtractedFact`, the regex fallback extractor, the `MemoryFactQuality` prefix
// cleaning, and `SemanticAdaptiveFactExtractor`. Those minted the junk User saw
// on the Memories page, and every fix to them was one more regex. The memory
// manager (MemoryV2+MemoryManager.swift) asks the agent's real model once, with
// the memories already kept in view.

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

    static func classifyPrompt(content: String, categories: [String]) -> String {
        """
        Choose exactly one category for the content. Respond with only the \
        category label, nothing else.

        Categories: \(categories.joined(separator: ", "))

        Content: \(content)

        Category:
        """
    }

}
