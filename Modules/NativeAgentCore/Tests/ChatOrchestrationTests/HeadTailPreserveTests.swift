import Testing
import Foundation
@testable import ChatOrchestration

// Regression cover: the builder-tool envelope truncation was head-only
// (`.prefix(32_768)`), which kept leading progress noise and DROPPED the
// trailing compiler/test errors on any build whose output outran the cap —
// blinding the agent to WHY a build failed. `headTailPreserve` keeps head+tail
// at the same budget so trailing errors survive.
struct HeadTailPreserveTests {
    @Test func underBudgetPassesThroughUnchanged() {
        let text = "short build output\nAll tests passed."
        let (out, truncated) = SwiftToolDispatcher.headTailPreserve(
            text, headBudget: 8_192, tailBudget: 24_576)
        #expect(out == text)
        #expect(truncated == false)
    }

    @Test func trailingBuildErrorsSurviveTruncation() {
        // Verbose build: lots of progress noise, then the REAL error at the very
        // end — exactly the shape head-only truncation used to drop.
        let noise = String(repeating: "Compiling module Foo ok\n", count: 5_000)
        let errorTail = "error: value of type 'X' has no member 'bar'\n** BUILD FAILED **\nEXIT: 65"
        let log = noise + errorTail
        let (out, truncated) = SwiftToolDispatcher.headTailPreserve(
            log, headBudget: 8_192, tailBudget: 24_576)

        #expect(truncated == true)
        // The whole point of the fix: the trailing errors survive.
        #expect(out.contains("** BUILD FAILED **"))
        #expect(out.contains("error: value of type 'X' has no member 'bar'"))
        #expect(out.contains("EXIT: 65"))
        // Middle elided with an honest marker, total stays near budget.
        #expect(out.contains("elided from middle"))
        #expect(out.count < log.count)
        // Proof the OLD head-only `.prefix(32_768)` would have dropped the error.
        #expect(!String(log.prefix(32_768)).contains("** BUILD FAILED **"))
    }

    @Test func leadingContextAndTrailingErrorBothSurvive() {
        let header = "$ swift build\nBuilding for debugging...\n"
        let log = header + String(repeating: "note: informational line\n", count: 6_000) + "error: the final failure\n"
        let (out, _) = SwiftToolDispatcher.headTailPreserve(
            log, headBudget: 8_192, tailBudget: 24_576)
        #expect(out.contains("$ swift build"))        // command echo survives in the head
        #expect(out.contains("error: the final failure")) // trailing error survives in the tail
    }
}
