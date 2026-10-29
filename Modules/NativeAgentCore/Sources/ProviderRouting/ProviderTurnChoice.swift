import Foundation
import NativeAgentCore
// Blueprint: | `ProviderTurnChoice.swift` | `ProviderTurnChoice` struct |

/// A selection value; only binding `current` makes it turn-local. Never writes saved preferences.
public struct ProviderTurnChoice: Sendable, Hashable {
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
