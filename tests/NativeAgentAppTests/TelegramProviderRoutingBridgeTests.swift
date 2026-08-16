import Foundation
import Testing
import ProviderRouting
@testable import NativeAgentApp

@Suite("Telegram provider routing bridge exact transport identity")
struct TelegramProviderRoutingBridgeTests {
    @Test func apiAndOAuthSiblingsAreNotTheSameTransport() {
        #expect(!TelegramProviderRoutingBridge.providerIdsMatch("openai", "openai_oauth_direct"))
        #expect(!TelegramProviderRoutingBridge.providerIdsMatch("anthropic", "anthropic_oauth_direct"))
        #expect(!TelegramProviderRoutingBridge.providerIdsMatch("anthropic_mcp", "anthropic_oauth_direct"))
    }

    @Test func genuineLegacyAliasesStillMatch() {
        #expect(TelegramProviderRoutingBridge.providerIdsMatch("xai", "xai_oauth_direct"))
        #expect(TelegramProviderRoutingBridge.providerIdsMatch("grok-oauth", "xai_oauth_direct"))
        #expect(TelegramProviderRoutingBridge.providerIdsMatch("kimi", "moonshot"))
    }

    @Test func modelSelectionCommitsExactTupleThroughCanonicalTransaction() async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("telegram-routing-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let routing = SwiftNativeProviderRouting(dataRoot: root)
        let bridge = TelegramProviderRoutingBridge(routing: routing, dataRoot: root)

        try await bridge.saveModelSelection(
            surface: "telegram",
            provider: "openai_oauth_direct",
            model: "gpt-5.6-sol"
        )
        let snapshot = try await routing.checkedRoutingSnapshot()
        #expect(snapshot.preferences["telegram"]?.model == "gpt-5.6-sol")
        #expect(snapshot.activeProviders["telegram"] == "openai_oauth_direct")
    }
}
