import Foundation
import Testing
@testable import NativeAgentApp

struct ChatShellInteractionSummaryTests {
    @Test("Answered cards do not inherit a stale waiting receipt")
    func answeredCardsDecodeWithoutNeedsYou() throws {
        for state in ["settled", "declined", "superseded", "cancelled"] {
            // Older rows lack resultStatus; current rows carry it in camel case.
            // Both must retain the interaction's terminal meaning after decoding.
            for includeStatus in [false, true] {
                var metadata: [String: Any] = [
                    "kind": "inline_interaction",
                    "ok": false,
                    "resultSummary": "{\"status\":\"needs_input\"}",
                    "interaction": ["state": ["name": state]],
                ]
                if includeStatus { metadata["resultStatus"] = state }
                let data = try JSONSerialization.data(withJSONObject: metadata)
                let decoded = try JSONDecoder().decode(ChatMessageMetadata.self, from: data)
                #expect(ChatShellToolSummary.status(
                    kind: decoded.kind, ok: decoded.ok,
                    resultSummary: decoded.resultSummary,
                    resultStatus: decoded.resultStatus,
                    interactionState: decoded.interactionState
                ) == .asked)
            }
        }
    }

    @Test("Pending and failed cards retain their distinct headlines")
    func unfinishedCardsRemainVisible() {
        #expect(ChatShellToolSummary.status(
            kind: "inline_interaction", ok: false,
            resultSummary: "{\"status\":\"needs_input\"}",
            interactionState: "pending"
        ) == .needsYou)
        #expect(ChatShellToolSummary.status(
            kind: "inline_interaction", ok: false,
            resultSummary: "{\"status\":\"needs_input\"}",
            resultStatus: "failed"
        ) == .failed)
    }
}
