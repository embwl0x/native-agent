import Foundation
import Testing
import ChatOrchestration
import MacIntegration
import NativeAgentCore
import PersistenceCore
import TrustCenter
@testable import NativeAgentApp

@Suite struct AppCatalogSpinReplayTests {
    @Test func appSearchPreservesUnavailableToolsAndTurnContext() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let core = SwiftToolDispatcher(dataRoot: root)
        let dispatcher = AppChatToolDispatcher(inner: core, activeToolsStore: core.activeToolsStore,
            securityCenter: SwiftNativeSecurityCenter(dataRoot: root),
            enforceAutonomySecurity: false,
            macIntegrationPermissionStore: MacIntegrationPermissionStore(dataRoot: root), organismPostureProvider: { nil })
        for index in 1...3 {
            let result = try await dispatcher.dispatch(tool: "tool_catalog", input: [
                "query": .string("open NativeAgent settings page visibly with Mac UI control"),
                "__session_id": .string("app-catalog-replay"), "limit": .int(1)
            ], surface: "chat")
            guard case .object(let fields) = result,
                  case .string(let availability)? = fields["availability"] else {
                Issue.record("App discarded catalog availability"); return
            }
            #expect(fields["searches_this_turn"] == .int(Int64(index)))
            #expect(availability.contains("Mac control is off"))
            #expect(fields["no_tools_loaded_since_previous_search"] == .bool(index > 1))
            if index > 1 { #expect(availability.contains("Results remain capped by limit")) }
            #expect(fields["status"] == .string("ok"))
        }
    }
}
