import NativeAgentCore
import Testing
@testable import NativeAgentApp

@Suite("Mac AppleScript read readiness")
struct MacAppleScriptReadinessTests {
    @Test func explicitMailSetupSentinelIsNotReportedAsAnEmptyInbox() throws {
        let result = try #require(MacAppleScriptBridge.readSetupEnvelope(
            raw: "  \(MacAppleScriptBridge.mailNotConfiguredSentinel)\n",
            integration: "mail"
        ))

        guard case .object(let object) = result,
              case .string(let fix)? = object["fix"] else {
            Issue.record("expected mail setup envelope")
            return
        }
        #expect(object["status"] == .string("failed"))
        #expect(object["reason"] == .string("not_configured"))
        #expect(fix.contains("Internet Accounts"))
    }

    @Test func explicitNotesSetupSentinelIsNotReportedAsAnEmptyStore() throws {
        let result = try #require(MacAppleScriptBridge.readSetupEnvelope(
            raw: MacAppleScriptBridge.notesNotConfiguredSentinel,
            integration: "notes"
        ))

        guard case .object(let object) = result else {
            Issue.record("expected notes setup envelope")
            return
        }
        #expect(object["status"] == .string("failed"))
        #expect(object["reason"] == .string("not_configured"))
    }

    @Test func genuineEmptyReadRemainsAValidZeroResult() {
        #expect(MacAppleScriptBridge.readSetupEnvelope(raw: "", integration: "mail") == nil)
        #expect(MacAppleScriptBridge.readSetupEnvelope(raw: " \n", integration: "notes") == nil)
    }
}
