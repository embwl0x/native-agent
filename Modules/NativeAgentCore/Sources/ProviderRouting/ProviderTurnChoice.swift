import Foundation
import NativeAgentCore

/// A turn-local picker tuple. Never writes active.json or another surface's preferences.
public struct ProviderTurnChoice: Sendable, Equatable {
    public let provider: String
    public let model: String
    public let reasoningEffort: String
    public let fast: Bool
    public init(provider: String, model: String, reasoningEffort: String, fast: Bool) {
        self.provider = provider; self.model = model
        self.reasoningEffort = reasoningEffort; self.fast = fast
    }
    @TaskLocal public static var current: ProviderTurnChoice?
}
