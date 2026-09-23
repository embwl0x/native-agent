import Foundation
import Testing
import PersistenceCore
@testable import NativeAgentApp

@Suite("Messages and Mail exact conversation identity")
struct MacAppleScriptConversationIdentityTests {
    @Test func chatMetadataTransportCannotInventRowsOrParticipants() {
        func escaped(_ text: String) -> String {
            text.replacingOccurrences(of: "%", with: "%25").replacingOccurrences(of: "|", with: "%7C")
                .replacingOccurrences(of: ":", with: "%3A").replacingOccurrences(of: ",", with: "%2C")
                .replacingOccurrences(of: "\n", with: "%0A").replacingOccurrences(of: "\r", with: "%0D")
        }
        let raw = "\(escaped("chat|42"))|\(escaped("Friends\n|,:"))|\(escaped("one@example.invalid")):\(escaped("A,B|C")),\n"
        let rows = MacAppleScriptBridge.parseMessagesMetadata(raw)
        #expect(rows.count == 1)
        guard case .object(let row) = rows[0] else { Issue.record("No metadata"); return }
        #expect(row["thread_id"] == .string("chat|42"))
        #expect(row["name"] == .string("Friends\n|,:"))
    }

    @Test func conversationEncodingRejectsMalformedAndDecodesOnlyOnce() {
        #expect(MacAppleScriptBridge.decodeConversationTransport("%257C") == "%7C")
        #expect(MacAppleScriptBridge.decodeConversationTransport("100%25 done") == "100% done")
        #expect(MacAppleScriptBridge.decodeConversationTransport("bad%") == nil)
        #expect(MacAppleScriptBridge.decodeConversationTransport("bad%41") == nil)
    }

    @Test func mailListDefersBodiesAndKeepsUsefulRowsAtTimeBudget() {
        let script = MacAppleScriptBridge.mailWorkspaceScript(input: [:])
        #expect(!script.contains("use framework"))
        #expect(!script.contains("current application's"))
        #expect(!script.contains("content of msg"))
        #expect(script.contains("with timeout of 4 seconds"))
        #expect(script.contains("if completedRows > 0 and errorNumber is -1712 then exit repeat"))
        #expect(script.contains("__PAGE__|"))
        let detail = MacAppleScriptBridge.mailWorkspaceScript(input: ["message_id": .int(42), "expected_message_id": .string("rfc@example.invalid")])
        #expect(detail.contains("content of msg"))
        #expect(!detail.contains("if completedRows > 0"))
    }

    @Test func changedParticipantsDoNotReportSend() async throws {
        let result = try await MacAppleScriptBridge.$scriptExecutorForTests.withValue({ script in
            #expect(script.contains("participants_changed"))
            #expect(script.contains("send \"Hello\" to targetChat"))
            #expect(!script.contains("targetBuddy"))
            return "participants_changed"
        }) {
            try await MacAppleScriptBridge.messagesSend(input: ["thread_id": .string("chat42"), "expected_participants": .array([.string("one@example.invalid")]), "body": .string("Hello")])
        }
        guard case .object(let row) = result else { Issue.record("No result"); return }
        #expect(row["status"] == .string("failed"))
        #expect(row["reason"] == .string("participants_changed_read_thread_again"))
    }

    @Test func ambiguousTargetsNeverExecuteSend() async throws {
        let result = try await MacAppleScriptBridge.$scriptExecutorForTests.withValue({ _ in
            Issue.record("Ambiguous send must not reach AppleScript"); return "sent"
        }) {
            try await MacAppleScriptBridge.messagesSend(input: ["thread_id": .string("chat42"), "to": .string("other@example.invalid"), "body": .string("Hello")])
        }
        guard case .object(let row) = result else { Issue.record("No result"); return }
        #expect(row["status"] == .string("failed"))
    }

    @Test func exactMailReplyChecksBothIdentifiersBeforeSending() async throws {
        let result = try await MacAppleScriptBridge.$scriptExecutorForTests.withValue({ script in
            #expect(script.contains("whose id is 42"))
            #expect(script.contains("message id of originalMsg"))
            #expect(script.contains("rfc@example.invalid"))
            #expect(script.contains("if (count of hits) is not 1"))
            return "-2"
        }) {
            try await MacAppleScriptBridge.mailReply(input: ["message_id": .int(42), "expected_message_id": .string("rfc@example.invalid"), "body": .string("Hello")])
        }
        guard case .object(let row) = result else { Issue.record("No result"); return }
        #expect(row["status"] == .string("failed"))
    }
}
