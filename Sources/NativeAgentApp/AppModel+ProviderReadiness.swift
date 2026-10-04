import Foundation
import PersistenceCore
import ProviderRouting

@MainActor
extension AppModel {
    /// Guidance text to show in chat when no AI provider is usable at all;
    /// `nil` when at least one provider looks connected.
    func missingProviderChatGuidance() -> String? {
        guard !hasAnyUsableProvider() else { return nil }
        return """
        No AI provider is connected yet, so I can't reply.

        Use Open Providers below to connect one.
        """
    }

    func hasAnyUsableProvider() -> Bool {
        AppModel.hasAnyUsableProvider(dataRoot: PersistenceCore.defaultDataRoot())
    }

    /// Use the same credential admission as provider routing, without catalog discovery.
    nonisolated static func hasAnyUsableProvider(dataRoot: URL) -> Bool {
        SwiftNativeProviderRouting(dataRoot: dataRoot).hasUsableCredentials()
    }
}
