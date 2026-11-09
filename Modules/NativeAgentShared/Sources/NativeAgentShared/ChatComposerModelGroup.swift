import Foundation
// Blueprint: | `ChatComposerModelGroup.swift` | Finished provider/model menu groups and their vendor sections |

public struct ChatComposerModelGroup: Sendable, Codable, Equatable, Identifiable {
    public let id: String
    public let provider: String
    public let models: [ModelCatalogItem]
    public let vendorGroups: [ChatComposerModelGroup]?

    public init(id: String, provider: String, models: [ModelCatalogItem], vendorGroups: [ChatComposerModelGroup]? = nil) {
        self.id = id
        self.provider = provider
        self.models = models
        self.vendorGroups = vendorGroups
    }

    private static let knownVendorNames = [
        "openai": "OpenAI", "anthropic": "Anthropic", "google": "Google", "x-ai": "xAI",
        "meta-llama": "Meta", "mistralai": "Mistral", "qwen": "Qwen", "deepseek": "DeepSeek",
        "z-ai": "Z.ai", "nvidia": "NVIDIA", "moonshotai": "Moonshot", "microsoft": "Microsoft",
        "amazon": "Amazon", "cohere": "Cohere", "perplexity": "Perplexity", "minimax": "MiniMax",
    ]

    public static func vendorName(_ id: String) -> String {
        if let known = knownVendorNames[id] { return known }
        return id.split(separator: "-").map { $0.prefix(1).uppercased() + $0.dropFirst() }.joined(separator: " ")
    }
}
