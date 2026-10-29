import Foundation
import NativeAgentCore

#if canImport(FoundationModels)
import FoundationModels
#endif

// Blueprint: | `MemoryV2+FoundationModels.swift` | `OnDeviceClassification`: shared category prompt and exact reply parser for on-device and remote kind labels |

// MARK: - On-device classification of existing memory rows

public enum FoundationModelsError: Error, Sendable, Equatable {
    case unavailable
    case decodeFailed(String)
    case generationFailed(String)
    /// `classify` got a model reply that matches none of the candidate
    /// categories. Callers must DROP the item (or retry), never substitute a
    /// default — the associated value is the offending reply, for logs.
    case classificationNoMatch(String)
}

public enum OnDeviceClassification {

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

    /// Return exactly one declared category; never repair a nonmember reply.
    public static func classify(content: String, into categories: [String]) async throws -> String {
        guard !categories.isEmpty else {
            throw FoundationModelsError.generationFailed("empty categories")
        }
        #if canImport(FoundationModels)
        if #available(macOS 26, *), SystemLanguageModel.default.isAvailable {
            let prompt = try classifyPrompt(content: content, categories: categories)
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

    /// Accept only a declared category; unparseable replies drop the row.
    public static func matchCategory(reply: String, categories: [String]) throws -> String {
        guard categories.contains(reply) else {
            throw FoundationModelsError.classificationNoMatch(reply)
        }
        return reply
    }

    // MARK: prompts

    public static func classifyPrompt(content: String, categories: [String]) throws -> String {
        try completionPolicy("kind-classification", section: "prompt", arguments: [
            categories.joined(separator: ", "),
            content
        ])
    }

}
