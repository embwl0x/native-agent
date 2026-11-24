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

    /// One rule for every model menu: an account offering more than 40 vendor-named models (`vendor/model`) is split by vendor.
    public static func splitsByVendor(_ modelIDs: [String]) -> Bool {
        modelIDs.count > 40 && modelIDs.allSatisfy { $0.contains("/") }
    }

    /// Where a model sits in a menu, as Chat's shows it: its account, then its vendor when the account is split, then the model.
    public static func menuPath(account: String, modelID: String, name: String, splitByVendor: Bool) -> [String] {
        splitByVendor ? [account, vendorName(String(modelID.prefix { $0 != "/" })), name] : [account, name]
    }
}
