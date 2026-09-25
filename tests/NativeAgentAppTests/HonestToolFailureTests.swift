import Testing
import Foundation
@testable import NativeAgentApp
import ChatOrchestration
import NativeAgentCore
import MCPDispatcher

@Test
func honestFailureChromeLeaseEnded() {
    let error = ChromeControlRuntimeError.leaseEnded(
        leaseID: "test-lease", event: "lease_ended", reason: "user_interaction"
    )
    guard case .object(let result) = ChatToolOutcome.failure(error: error) else {
        Issue.record("missing failure envelope"); return
    }
    #expect(result["failure_code"] == .string("dispatch_error"))
    #expect(result["reason"] == .string(error.localizedDescription))
    #expect(result["message"] == .string(error.localizedDescription))
    #expect(error.localizedDescription.contains("Open the page again with browser.chrome_navigate"))
}

@Test
func honestFailureReceiptPreservesRefusalAndConnectionFailure() throws {
    struct Denied: Error, CustomStringConvertible {
        var description: String { "tool denied: fileAccess=read_only blocks write_file" }
    }
    for output in [
        ChatToolOutcome.failure(error: Denied()),
        ChatToolOutcome.normalizedFailure(.object([
            "status": .string("failed"), "reason": .string(Denied().description),
            "error": .string(Denied().description),
        ])),
    ] {
        #expect(ToolPillPresentation.outcome(result: String(decoding: try output.serializedData(pretty: false), as: UTF8.self)) == .refused)
    }
    #expect(ToolPillPresentation.outcome(result: String(decoding: try ChatToolOutcome.failure(error: MCPSubprocessError.streamClosed).serializedData(pretty: false), as: UTF8.self)) == .connectionFailed)
}
