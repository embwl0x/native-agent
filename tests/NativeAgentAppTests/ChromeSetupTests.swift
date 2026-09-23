import Testing
import PersistenceCore
import TrustCenter
@testable import NativeAgentApp

@Test func chromeSetupDoesNotConflatePreparedOrHistoricalConnectionWithLoaded() {
    let never = AppChatToolDispatcher.chromeSetupStatusJSON(state: .extensionNotLoaded, enabled: true)
    #expect(never["connected"] == .bool(false))
    #expect(never["connection"] == .string("not_yet_connected"))
    let historical = AppChatToolDispatcher.chromeSetupStatusJSON(state: .disconnected, enabled: true)
    #expect(historical["connected"] == .bool(false))
    #expect(historical["connection"] == .string("previously_connected"))
    let disabled = AppChatToolDispatcher.chromeSetupStatusJSON(state: .connected, enabled: false)
    #expect(disabled["connected"] == .bool(true))
    #expect(disabled["chrome_control_enabled"] == .bool(false))
    #expect(disabled["permissions_changed"] == .bool(false))
}
