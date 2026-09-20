import Foundation
import NativeAgentCore
import PersistenceCore
import Testing
@testable import NativeAgentApp

@Suite("Mac AppleScript read readiness")
struct MacAppleScriptReadinessTests {
    @Test func recentMailBoundsTheAppleEventBeforeReadingMessages() async throws {
        let inputs: [[String: JSONValue]] = [[:], ["limit": .int(10)], ["limit": .int(50)]]
        for input in inputs {
            let result = try await MacAppleScriptBridge.$scriptExecutorForTests.withValue({ source in
                // Replay the large-inbox failure at the Apple-event boundary.
                if source.contains("set msgList to messages of inbox") {
                    throw NSError(domain: "NativeAgentAppleScript", code: -1741)
                }
                #expect(source.contains("set messageCount to count of messages of inbox"))
                #expect(source.contains("set msg to message i of inbox"))
                #expect(source.contains("repeat with i from 1 to messageCount"))
                return "Subject|||Sender|||Date|||Snippet###"
            }) {
                try await MacAppleScriptBridge.mailListRecent(input: input)
            }
            guard case .object(let object) = result else { Issue.record("Missing result"); return }
            #expect(object["status"] == .string("completed"))
            #expect(object["count"] == .int(1))
        }
    }
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
