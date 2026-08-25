import Testing
import Foundation
@testable import WorkshopExecution
import NativeAgentCore
import PersistenceCore

// Coverage ledger, three rows, all pure functions on `WorkshopExecutorLoop`:
//
//   workshop.executor.extractWorkshopExecutionResult  (ui-summary, wrong value)
//   workshop.executor.stepOutputCarryForward          (turn-ingredient, wrong value)
//   workshop.executor.promptArgAliasing               (turn-ingredient, silent degradation)
//
// These three decide (1) the single string the user reads as "what the task
// produced", (2) the whole memory a multi-step plan has of its own work, and
// (3) which instruction a synthesis step actually answers. All three degrade
// SILENTLY: the step still succeeds, the receipt is clean, the answer is just
// built on the wrong text. Before this file, `grep -rn
// extractWorkshopExecutionResult|summarizeStepOutput|lastStepRecord` over the
// test targets returned zero direct hits.

private func stepRecord(_ stepId: String, output: JSONValue, status: String = "completed") -> JSONValue {
    .object([
        "step_id": .string(stepId),
        "status": .string(status),
        "output": output,
    ])
}

private func evalRecord(
    stepsCompleted: [JSONValue],
    plan: [WorkshopExecutionStep] = [],
    objective: String = "the objective"
) -> WorkshopExecutionRecord {
    let stamp = SwiftNativeWorkshopRunner.isoTimestamp(Date(timeIntervalSince1970: 1_700_000_000))
    return WorkshopExecutionRecord(
        id: "eval", title: "eval", objective: objective, createdAt: stamp,
        status: "running", plan: plan, stepsCompleted: stepsCompleted,
        receiptsDir: "/tmp/eval-receipts", triggerSource: "manual", trustRequired: "none",
        expectedOutputs: [], currentStepId: "", updatedAt: stamp, result: .null, rerunCount: 0
    )
}

private func text(_ value: JSONValue) -> String? {
    if case .string(let s) = value { return s }
    return nil
}

// MARK: - workshop.executor.extractWorkshopExecutionResult

@Suite("EVAL workshop.executor.extractWorkshopExecutionResult")
struct WorkshopExtractResultEvalSuite {

    /// Shape 1: `{model, text}` — the tooled/measured step shape.
    @Test func objectWithTextUnwrapsToThatText() {
        let record = evalRecord(stepsCompleted: [
            stepRecord("step-1", output: .object([
                "model": .string("m"), "text": .string("the answer"),
            ])),
        ])
        #expect(WorkshopExecutorLoop.extractWorkshopExecutionResult(record) == .string("the answer"))
    }

    /// Shape 2: `{output: {text}}` — the tool-dispatch envelope.
    @Test func nestedOutputTextUnwrapsToThatText() {
        let record = evalRecord(stepsCompleted: [
            stepRecord("step-1", output: .object([
                "output": .object(["text": .string("nested answer")]),
            ])),
        ])
        #expect(WorkshopExecutorLoop.extractWorkshopExecutionResult(record) == .string("nested answer"))
    }

    /// Shape 3: a bare string output passes through unchanged.
    @Test func bareStringPassesThrough() {
        let record = evalRecord(stepsCompleted: [stepRecord("step-1", output: .string("plain"))])
        #expect(WorkshopExecutorLoop.extractWorkshopExecutionResult(record) == .string("plain"))
    }

    /// Shape 4: an object with no `text` anywhere is SERIALIZED, never dropped.
    /// Envelope assertion — the exact key order of the serialization is not a
    /// contract, but "the payload survives into the card" is.
    @Test func objectWithoutTextSerializesRatherThanVanishing() throws {
        let record = evalRecord(stepsCompleted: [
            stepRecord("step-1", output: .object([
                "output": .object(["rows": .int(3), "path": .string("/tmp/x")]),
            ])),
        ])
        let result = WorkshopExecutorLoop.extractWorkshopExecutionResult(record)
        let rendered = try #require(text(result))
        #expect(rendered.contains("rows"))
        #expect(rendered.contains("/tmp/x"))
        #expect(rendered.isEmpty == false)
    }

    /// The two EMPTY-CARD branches. Both are `.null`, which is what the UI
    /// renders as a completed execution with nothing in it. Pinning them keeps
    /// the branch honest: if someone widens the unwrap they must decide what
    /// these become, rather than silently changing what the user sees.
    @Test func nonObjectNonStringOutputYieldsNull() {
        let arrayOutput = evalRecord(stepsCompleted: [
            stepRecord("step-1", output: .array([.string("a"), .string("b")])),
        ])
        #expect(WorkshopExecutorLoop.extractWorkshopExecutionResult(arrayOutput) == .null)

        let numberOutput = evalRecord(stepsCompleted: [stepRecord("step-1", output: .int(7))])
        #expect(WorkshopExecutorLoop.extractWorkshopExecutionResult(numberOutput) == .null)
    }

    @Test func absentOutputAndEmptyStepsYieldNull() {
        let noOutputKey = evalRecord(stepsCompleted: [
            .object(["step_id": .string("step-1"), "status": .string("completed")]),
        ])
        #expect(WorkshopExecutorLoop.extractWorkshopExecutionResult(noOutputKey) == .null)
        #expect(WorkshopExecutorLoop.extractWorkshopExecutionResult(evalRecord(stepsCompleted: [])) == .null)
    }

    /// SELECTION IS BY POSITION, NOT BY STATUS. The last completed-step entry
    /// wins even when it FAILED — which means a run whose final step failed
    /// reports that failure text as "the result". This is the shipped
    /// behaviour; pinning it here makes the tradeoff visible instead of
    /// letting a future "pick the last SUCCESSFUL step" change slip in
    /// unnoticed (that change would silently promote a stale mid-run output to
    /// the user-facing card).
    @Test func lastEntryWinsRegardlessOfItsStatus() {
        let record = evalRecord(stepsCompleted: [
            stepRecord("step-1", output: .string("good earlier output")),
            stepRecord("step-2", output: .string("step failed: timeout"), status: "failed"),
        ])
        #expect(WorkshopExecutorLoop.extractWorkshopExecutionResult(record)
                == .string("step failed: timeout"))
    }
}

// MARK: - workshop.executor.stepOutputCarryForward

@Suite("EVAL workshop.executor.stepOutputCarryForward")
struct WorkshopStepCarryForwardEvalSuite {

    /// The 500-char cap is the whole memory a later step has of an earlier one.
    /// Pin the BOUNDARY (at the cap: verbatim; one past: truncated) and pin
    /// that truncation is MARKED, so a downstream model can tell it is reading
    /// a fragment rather than a complete prior result.
    @Test func truncationBoundaryAndMarker() {
        let atCap = String(repeating: "a", count: 500)
        #expect(WorkshopExecutorLoop.summarizeStepOutput(.string(atCap)) == atCap)

        let underCap = String(repeating: "b", count: 499)
        #expect(WorkshopExecutorLoop.summarizeStepOutput(.string(underCap)) == underCap)

        for length in [501, 5_000] {
            let long = String(repeating: "c", count: length)
            let summary = WorkshopExecutorLoop.summarizeStepOutput(.string(long))
            #expect(summary.count == 501, "cap 500 + one marker character")
            #expect(summary.hasSuffix("…"), "truncation must be MARKED, length \(length)")
            #expect(summary.dropLast() == long.prefix(500))
        }
    }

    /// The cap is a parameter, and the caller-visible default is 500. A change
    /// to either the default or the marker changes every multi-step plan's
    /// working memory at once.
    @Test func capIsHonoredWhenOverridden() {
        let long = String(repeating: "d", count: 100)
        let summary = WorkshopExecutorLoop.summarizeStepOutput(.string(long), maxChars: 10)
        #expect(summary == String(repeating: "d", count: 10) + "…")
    }

    /// Nested shapes reach the same extraction as the result card, and an
    /// EMPTY payload becomes an explicit sentinel, never the empty string —
    /// "returned no results" is what stops the next step confabulating.
    @Test func nestedShapesAndEmptySentinel() {
        #expect(WorkshopExecutorLoop.summarizeStepOutput(
            .object(["text": .string("direct")])) == "direct")
        #expect(WorkshopExecutorLoop.summarizeStepOutput(
            .object(["output": .object(["text": .string("nested")])])) == "nested")
        #expect(WorkshopExecutorLoop.summarizeStepOutput(.null) == "returned no results")
        #expect(WorkshopExecutorLoop.summarizeStepOutput(.object([:])) == "returned no results")
        #expect(WorkshopExecutorLoop.summarizeStepOutput(
            .object(["output": .object([:])])) == "returned no results")
        #expect(WorkshopExecutorLoop.summarizeStepOutput(.string("   \n ")) == "returned no results")
    }

    /// A re-run step appends a SECOND entry under the same id. `lastStepRecord`
    /// must resolve the MOST RECENT one — resolving the first hands step N a
    /// stale prior result that still looks plausible.
    @Test func lastStepRecordResolvesTheMostRecentDuplicate() throws {
        let record = evalRecord(stepsCompleted: [
            stepRecord("step-1", output: .string("first attempt")),
            stepRecord("step-2", output: .string("other step")),
            stepRecord("step-1", output: .string("second attempt")),
        ])
        let resolved = try #require(WorkshopExecutorLoop.lastStepRecord(record, stepId: "step-1"))
        guard case .object(let object) = resolved else {
            Issue.record("expected an object step record"); return
        }
        #expect(object["output"] == .string("second attempt"))
        #expect(WorkshopExecutorLoop.lastStepRecord(record, stepId: "no-such-step") == nil)
    }

    /// End to end through the consumer: a later step's prompt must carry the
    /// prior step's output, TRUNCATED and MARKED, keyed by the plan's tool
    /// name — and must NOT carry the step's own record.
    @Test func priorStepContextEntersTheNextPromptTruncatedAndMarked() {
        let long = String(repeating: "e", count: 900)
        let plan = [
            WorkshopExecutionStep(id: "step-1", description: "read", toolOrAction: "local_files.read"),
            WorkshopExecutionStep(id: "step-2", description: "write it up",
                                  toolOrAction: "chat.synthesize",
                                  args: .object(["prompt": .string("Summarize the file")])),
        ]
        let record = evalRecord(
            stepsCompleted: [
                stepRecord("step-1", output: .object(["text": .string(long)])),
                stepRecord("step-2", output: .string("should not appear in its own prompt")),
            ],
            plan: plan
        )
        let prompt = WorkshopExecutorLoop.buildLLMPrompt(execution: record, step: plan[1])
        #expect(prompt.contains("[step step-1 via local_files.read]:"))
        #expect(prompt.contains(String(repeating: "e", count: 500) + "…"))
        #expect(prompt.contains(long) == false, "untruncated prior output must not reach the prompt")
        #expect(prompt.contains("should not appear in its own prompt") == false)
        #expect(prompt.contains("Summarize the file"))
    }
}

// MARK: - workshop.executor.promptArgAliasing

@Suite("EVAL workshop.executor.promptArgAliasing")
struct WorkshopPromptArgAliasingEvalSuite {

    private func firstStepPrompt(args: JSONValue, description: String = "the short label") -> String {
        let step = WorkshopExecutionStep(
            id: "step-1", description: description, toolOrAction: "chat.synthesize", args: args)
        // No prior steps → buildLLMPrompt returns the resolved base prompt
        // VERBATIM, which is what makes the alias precedence observable.
        return WorkshopExecutorLoop.buildLLMPrompt(
            execution: evalRecord(stepsCompleted: [], plan: [step]), step: step)
    }

    /// Precedence is exactly prompt → text → description.
    @Test func aliasPrecedenceIsPromptThenTextThenDescription() {
        #expect(firstStepPrompt(args: .object(["prompt": .string("P")])) == "P")
        #expect(firstStepPrompt(args: .object(["text": .string("T")])) == "T")
        #expect(firstStepPrompt(args: .object([
            "prompt": .string("P"), "text": .string("T"),
        ])) == "P", "prompt must win over text")
        #expect(firstStepPrompt(args: .object(["instruction": .string("I")]))
                == "the short label", "an unknown key must NOT be treated as an alias")
        #expect(firstStepPrompt(args: .object([:])) == "the short label")
        #expect(firstStepPrompt(args: .null) == "the short label")
    }

    /// A whitespace-only `prompt` is not an instruction: it must fall THROUGH
    /// to `text`, not collapse straight to the description. This is the branch
    /// that turns "the planner emitted a blank prompt" into "the step answered
    /// the other alias" instead of "the step answered its own one-line label".
    @Test func blankPromptFallsThroughToTextNotToDescription() {
        #expect(firstStepPrompt(args: .object([
            "prompt": .string("   \n\t "), "text": .string("T"),
        ])) == "T")
        #expect(firstStepPrompt(args: .object(["prompt": .string("")])) == "the short label")
        #expect(firstStepPrompt(args: .object([
            "prompt": .string(" "), "text": .string("  "),
        ])) == "the short label")
    }

    /// A non-string alias value must not be coerced into the prompt.
    @Test func nonStringAliasValuesAreIgnored() {
        #expect(firstStepPrompt(args: .object(["prompt": .int(42)])) == "the short label")
        #expect(firstStepPrompt(args: .object([
            "prompt": .array([.string("P")]), "text": .string("T"),
        ])) == "T")
    }

    /// THE DEGRADATION IS UNCOUNTED — this is the ledger's actual finding, and
    /// this assertion is the honest form of it: the description-fallback path
    /// is INDISTINGUISHABLE, at the prompt boundary, from a planner that
    /// deliberately emitted the description as the instruction. Nothing in the
    /// returned string marks it. A planner arg rename would degrade every
    /// synthesis step at once with a green suite.
    ///
    /// The assertion is deliberately the current (unmarked) behaviour, so that
    /// when the production seam lands — a `prompt_arg_missing` timeline event,
    /// see productionSeamNeeded — this test FAILS and must be updated by
    /// whoever adds it, rather than the seam shipping unnoticed.
    @Test func descriptionFallbackIsCurrentlyUnmarkedAtThePromptBoundary() {
        let fallback = firstStepPrompt(args: .object(["instruction": .string("ignored")]),
                                       description: "Draft the weekly note")
        #expect(fallback == "Draft the weekly note")
        // No marker, no sentinel, no distinguishing prefix: identical to a step
        // whose planner arg genuinely carried that same string.
        #expect(fallback == firstStepPrompt(args: .object([
            "prompt": .string("Draft the weekly note"),
        ]), description: "something else entirely"))
    }
}
