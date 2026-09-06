import Foundation
import Testing
import NativeAgentCore
import PersistenceCore
import MacControl
@testable import ChatOrchestration

@Suite("Builder wakeup receipt truth")
struct BuilderWakeupReceiptTests {
    private let helper = URL(fileURLWithPath: "/fixture/wakeup.js")

    private func receipt(
        _ stdout: String,
        exitCode: Int32 = 0,
        timedOut: Bool = false,
        truncated: Bool = false
    ) throws -> [String: JSONValue] {
        let value = SwiftToolDispatcher.builderWakeupHelperReceipt(
            result: ProcessRunResult(
                exitCode: exitCode, stdout: stdout, stderr: "",
                timedOut: timedOut, stdoutTruncated: truncated
            ),
            helper: helper
        )
        return try #require(value.receiptObject)
    }

    @Test("exit zero without a structured receipt is unknown admission, never completed work")
    func emptyAndMalformedOutput() throws {
        for output in ["", "ordinary log line", "[]", "null", "42", "\"ready\"", "{}", "{\"status\":\" \"}"] {
            let result = try receipt(output)
            #expect(result["status"] == .string("failed"))
            #expect(result["admissionOutcome"] == .string("unknown"))
            #expect(result["note"]?.receiptString?.contains("before any resend") == true)
        }
    }

    @Test("accepted and queued helper evidence keep their distinct states")
    func structuredAdmission() throws {
        for status in ["sent", "queued", "completed", "skipped", "failed"] {
            let result = try receipt("diagnostic preamble\n{\"status\":\"\(status)\",\"messageId\":\"same-message\"}")
            #expect(result["status"] == .string(status))
            #expect(result["messageId"] == .string("same-message"))
            #expect(result["exitCode"] == .int(0))
        }
    }

    @Test("timeout and truncated output cannot certify admission even with a success-shaped prefix")
    func interruptedHelper() throws {
        let timeout = try receipt("{\"status\":\"sent\"}", timedOut: true)
        #expect(timeout["reason"] == .string("helper_timeout"))
        #expect(timeout["admissionOutcome"] == .string("unknown"))
        let truncated = try receipt("{\"status\":\"completed\"}", truncated: true)
        #expect(truncated["reason"] == .string("helper_output_truncated"))
        #expect(truncated["admissionOutcome"] == .string("unknown"))
    }

    @Test("nonzero helper exit cannot present a conflicting successful receipt as success")
    func conflictingExit() throws {
        let result = try receipt("{\"status\":\"sent\",\"threadId\":\"thread-1\"}", exitCode: 7)
        #expect(result["status"] == .string("failed"))
        #expect(result["reason"] == .string("helper_exit_conflict"))
        #expect(result["admissionOutcome"] == .string("unknown"))
        #expect(result["helperReportedReceipt"]?.receiptObject?["threadId"] == .string("thread-1"))
        let failed = try receipt("{\"status\":\"failed\",\"reason\":\"known_failure\"}", exitCode: 7)
        #expect(failed["reason"] == .string("known_failure"))
    }

    @Test("Claude caller-facing note follows actual wake evidence")
    func claudeNotes() {
        let accepted = SwiftToolDispatcher.claudeWakeupReceiptNote(.object(["status": .string("sent")]))
        #expect(accepted.contains("wake was accepted"))
        #expect(accepted.contains("does not prove the work completed"))
        let pending = SwiftToolDispatcher.claudeWakeupReceiptNote(.object(["status": .string("queued")]))
        #expect(pending.contains("not yet confirmed running"))
        for status in ["failed", "skipped"] {
            let note = SwiftToolDispatcher.claudeWakeupReceiptNote(.object(["status": .string(status)]))
            #expect(note.contains("did not confirm a new Claude wake"))
            #expect(!note.contains("session is waking"))
        }
    }

    @Test("Claude tool preserves durable queue status while explaining an unconfirmed wake")
    func claudeToolReceiptUsesActualHelperEvidence() async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("claude-receipt-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        // The top-level receipt status now REPORTS the wake evidence instead of
        // hardcoding "queued" for all four. A flat "queued" classified every
        // send `.unknown`, which the transcript rendered "completion
        // unconfirmed" even for a wake the helper had accepted.
        for (status, receiptStatus, expected) in [
            ("sent", "accepted", "wake was accepted"),
            ("queued", "queued", "not yet confirmed running"),
            // Nothing heard: the durable row is still a real enqueue.
            ("skipped", "queued", "did not confirm a new Claude wake"),
            ("failed", "failed", "did not confirm a new Claude wake"),
        ] {
            let dispatcher = SwiftToolDispatcher(
                dataRoot: root,
                agentBridgeConfigRoot: root,
                claudeMessageWakeupOverride: { _ in .object(["status": .string(status)]) }
            )
            let result = try await dispatcher.dispatch(
                tool: "claude_message",
                input: ["message_id": .string("receipt-\(status)"), "text": .string("bounded fixture")],
                surface: "chat"
            )
            let object = try #require(result.receiptObject)
            #expect(object["status"] == .string(receiptStatus))
            #expect(object["note"]?.receiptString?.contains(expected) == true)
        }
    }
}

private extension JSONValue {
    var receiptObject: [String: JSONValue]? {
        if case .object(let object) = self { return object }
        return nil
    }

    var receiptString: String? {
        if case .string(let string) = self { return string }
        return nil
    }
}
