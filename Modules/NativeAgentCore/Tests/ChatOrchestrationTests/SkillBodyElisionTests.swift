import Foundation
import Testing
@testable import ChatOrchestration
import NativeAgentCore
import PersistenceCore

// Skills-recall rework (2026-07-03), Track C pin: a pulled skill body must
// not ride into later prompts at full length. The structural guarantee is
// SessionHistoryPromptRenderer.toolSummary — persisted role="tool" rows re-enter
// rebuilt history ONLY through it, capped at 180 chars. This test fails if
// that cap (or the summary path) ever regresses.
@Suite struct SkillBodyElisionTests {

    @Test func hugeReadSkillResultRendersNameOnly() {
        // User (2026-07-03): even 180-char previews add up across many skill
        // reads. read_skill rows render as NAME ONLY — the body preview was
        // redundant bytes in every subsequent prompt.
        let hugeBody = String(repeating: "skill markdown line. ", count: 500) // ~10.5k chars
        let metadata: [String: JSONValue] = [
            "kind": .string("tool_use"),
            "toolName": .string("read_skill"),
            "inputJSON": .string("{\"name\": \"oauth-auth-hard-check\"}"),
            "resultSummary": .string(hugeBody),
            "ok": .bool(true),
        ]
        let rendered = SessionHistoryPromptRenderer.toolSummary(content: "", metadata: metadata)
        #expect(rendered.contains("oauth-auth-hard-check"))
        #expect(!rendered.contains("skill markdown line"))
        #expect(rendered.count < 90)
    }

    @Test func readSkillWithoutParsableInputStillRendersTight() {
        let metadata: [String: JSONValue] = [
            "kind": .string("tool_use"),
            "toolName": .string("read_skill"),
            "resultSummary": .string(String(repeating: "x", count: 5000)),
            "ok": .bool(true),
        ]
        let rendered = SessionHistoryPromptRenderer.toolSummary(content: "", metadata: metadata)
        #expect(rendered == "read_skill ok")
    }

    @Test func otherToolResultsKeepThe180Cap() {
        let metadata: [String: JSONValue] = [
            "kind": .string("tool_use"),
            "toolName": .string("git_log"),
            "resultSummary": .string(String(repeating: "log line. ", count: 200)),
            "ok": .bool(true),
        ]
        let rendered = SessionHistoryPromptRenderer.toolSummary(content: "", metadata: metadata)
        #expect(rendered.hasPrefix("git_log ok:"))
        #expect(rendered.count < 220)
    }

    @Test func inlineToolContentPassesThroughUnchanged() {
        let rendered = SessionHistoryPromptRenderer.toolSummary(
            content: "read_skill ok: short",
            metadata: nil
        )
        #expect(rendered == "read_skill ok: short")
    }
}
