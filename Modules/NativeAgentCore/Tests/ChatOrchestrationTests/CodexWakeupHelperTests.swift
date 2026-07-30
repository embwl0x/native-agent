import Testing
@testable import ChatOrchestration

@Suite("Codex wakeup helper deadline")
struct CodexWakeupHelperTests {
    @Test("outer helper deadline leaves cleanup margin beyond the default RPC timeout")
    func defaultDeadlineHasMargin() {
        #expect(SwiftToolDispatcher.codexWakeupHelperTimeoutSeconds(environment: [:]) == 20)
    }

    @Test("configured RPC timeout keeps an eight-second outer margin")
    func configuredDeadlineHasMargin() {
        let environment = ["NATIVE_AGENT_CODEX_WAKEUP_REQUEST_TIMEOUT_MS": "30000"]
        #expect(SwiftToolDispatcher.codexWakeupHelperTimeoutSeconds(environment: environment) == 38)
    }

    @Test("invalid and extreme values remain bounded")
    func deadlineIsBounded() {
        #expect(SwiftToolDispatcher.codexWakeupHelperTimeoutSeconds(environment: [
            "NATIVE_AGENT_CODEX_WAKEUP_REQUEST_TIMEOUT_MS": "invalid",
        ]) == 20)
        #expect(SwiftToolDispatcher.codexWakeupHelperTimeoutSeconds(environment: [
            "NATIVE_AGENT_CODEX_WAKEUP_REQUEST_TIMEOUT_MS": "1",
        ]) == 13)
        #expect(SwiftToolDispatcher.codexWakeupHelperTimeoutSeconds(environment: [
            "NATIVE_AGENT_CODEX_WAKEUP_REQUEST_TIMEOUT_MS": "999999",
        ]) == 128)
    }
}
