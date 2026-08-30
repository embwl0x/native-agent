import Testing
import Foundation
@testable import SwarmRuns
import NativeAgentCore
import PersistenceCore

// MARK: - U6 swarm digest-budget seam tests
//
// digestBudgetTokens (default nil = unchanged) truncates the synthesis digest
// relayed to the orchestrator, with an EXPLICIT notice (never silent). Covers
// the parse seam (nil default, non-positive coerced to nil) and the truncation
// helper's notice behavior.

@Suite("DigestBudget")
struct DigestBudgetTests {

    private func policy() -> AgentSwarmPolicy { AgentSwarmPolicy() }

    // MARK: parse seam

    @Test func parseDefaultsDigestBudgetToNil() throws {
        let req = try AgentSwarmRunRequest.parse(
            input: ["objective": .string("analyze X")], policy: policy())
        #expect(req.digestBudgetTokens == nil)  // default = unchanged
    }

    @Test func parseReadsDigestBudgetFromBothKeys() throws {
        let camel = try AgentSwarmRunRequest.parse(
            input: ["objective": .string("X"), "digestBudgetTokens": .int(500)], policy: policy())
        #expect(camel.digestBudgetTokens == 500)
        let snake = try AgentSwarmRunRequest.parse(
            input: ["objective": .string("X"), "digest_budget_tokens": .int(750)], policy: policy())
        #expect(snake.digestBudgetTokens == 750)
    }

    @Test func parseCoercesNonPositiveBudgetToNil() throws {
        // 0 must not silently zero the digest — treated as "no budget".
        let zero = try AgentSwarmRunRequest.parse(
            input: ["objective": .string("X"), "digestBudgetTokens": .int(0)], policy: policy())
        #expect(zero.digestBudgetTokens == nil)
        let neg = try AgentSwarmRunRequest.parse(
            input: ["objective": .string("X"), "digestBudgetTokens": .int(-5)], policy: policy())
        #expect(neg.digestBudgetTokens == nil)
    }

    // MARK: truncation helper

    @Test func nilBudgetReturnsTextUnchanged() {
        let text = String(repeating: "a", count: 10_000)
        let result = SwiftNativeAgentSwarmExecutor.applyDigestBudget(text, budgetTokens: nil)
        #expect(result.truncated == false)
        #expect(result.text == text)
    }

    @Test func underBudgetReturnsUnchanged() {
        let text = "short digest"
        // 100 tokens ≈ 400 chars — well over the text length.
        let result = SwiftNativeAgentSwarmExecutor.applyDigestBudget(text, budgetTokens: 100)
        #expect(result.truncated == false)
        #expect(result.text == text)
    }

    @Test func overBudgetTruncatesWithExplicitNotice() {
        // 5000 chars vs a 100-token (~400 char) budget → truncated + notice.
        let text = String(repeating: "x", count: 5_000)
        let result = SwiftNativeAgentSwarmExecutor.applyDigestBudget(text, budgetTokens: 100)
        #expect(result.truncated == true)
        #expect(result.text.contains("digest truncated"))
        #expect(result.text.contains("~100 tokens"))
        #expect(result.text.contains("discarded text is not retained"))
        #expect(result.text.contains("delegation_status(agent='swarm'"))
        #expect(!result.text.contains("task_ledger/follow-up"))
        // The clipped body is ~400 chars (+ the notice).
        #expect(result.text.hasPrefix(String(repeating: "x", count: 400)))
    }

    @Test(arguments: [Int.max / 4, Int.max / 4 + 1, Int.max])
    func largeValidBudgetCannotOverflow(budget: Int) throws {
        let request = try AgentSwarmRunRequest.parse(
            input: ["objective": .string("preserve finished findings"), "digestBudgetTokens": .int(Int64(budget))],
            policy: policy()
        )
        let text = "already bounded synthesis"
        let result = SwiftNativeAgentSwarmExecutor.applyDigestBudget(text, budgetTokens: request.digestBudgetTokens)
        #expect(result.text == text)
        #expect(result.truncated == false)
    }

    @Test(arguments: [0, -1, Int.min])
    func nonPositiveDirectBudgetRemainsUnchanged(budget: Int) {
        let result = SwiftNativeAgentSwarmExecutor.applyDigestBudget("findings", budgetTokens: budget)
        #expect(result.text == "findings")
        #expect(result.truncated == false)
    }

    @Test(arguments: [1e100, -1e100, Double(Int.max), Double.infinity, -Double.infinity, Double.nan])
    func unrepresentableDoubleUsesExistingInputFallback(value: Double) throws {
        #expect(AgentSwarmRunRequest.intValue(.double(value)) == nil)
        let request = try AgentSwarmRunRequest.parse(
            input: ["objective": .string("preserve input fallback"),
                    "digestBudgetTokens": .double(value), "timeoutSeconds": .double(value)],
            policy: policy()
        )
        #expect(request.digestBudgetTokens == nil)
        #expect(request.timeoutSeconds == 240)
    }

    @Test func representableFractionalAndBoundaryInputKeepsTruncation() {
        #expect(AgentSwarmRunRequest.intValue(.double(4.75)) == 4)
        #expect(AgentSwarmRunRequest.intValue(.double(-4.75)) == -4)
        #expect(AgentSwarmRunRequest.intValue(.double(0.75)) == 0)
        #expect(AgentSwarmRunRequest.intValue(.double(Double(Int.min))) == Int.min)
        #expect(AgentSwarmRunRequest.intValue(.double(Double(Int.max).nextDown)) != nil)
    }
}
