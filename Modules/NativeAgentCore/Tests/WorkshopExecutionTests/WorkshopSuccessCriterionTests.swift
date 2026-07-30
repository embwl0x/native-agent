import Foundation
import Testing
import NativeAgentCore
import PersistenceCore
@testable import WorkshopExecution

// W3 honesty gate (docs/build_plans/workshop-github-command.md): an execution
// may not record `completed` when its own success criterion is unmet. Pins the
// exact 251da950 shape Agent caught — objective demanded "Workshop live proof
// passed." while the model returned "I don't have the required phrase." and
// the executor recorded completed anyway.
@Suite("Workshop execution success criterion")
struct WorkshopSuccessCriterionTests {

    private func record(
        objective: String,
        expectedOutputs: [JSONValue] = [],
        outputs: [String]
    ) -> WorkshopExecutionRecord {
        let now = SwiftNativeWorkshopRunner.isoTimestamp(Date())
        return WorkshopExecutionRecord(
            id: "exec-test",
            title: "t",
            objective: objective,
            createdAt: now,
            status: "running",
            plan: [],
            stepsCompleted: outputs.map { text -> JSONValue in
                .object([
                    "step_id": .string("step-1"),
                    "status": .string("succeeded"),
                    "output": .object(["text": .string(text), "model": .string("m")]),
                ])
            },
            receiptsDir: "/tmp/receipts",
            triggerSource: "manual",
            trustRequired: "low",
            expectedOutputs: expectedOutputs,
            currentStepId: "",
            updatedAt: now,
            result: .null,
            rerunCount: 0
        )
    }

    @Test func the251da950ShapeIsUnmet() {
        let rec = record(
            objective: "Return exactly: Workshop live proof passed. Use no tools and make no external changes.",
            outputs: ["I don\u{2019}t have the required phrase."]
        )
        let unmet = WorkshopExecutorLoop.unmetSuccessCriterion(rec)
        #expect(unmet != nil)
        #expect(unmet?.contains("Workshop live proof passed.") == true)
    }

    @Test func exactPhrasePresentIsMet() {
        let rec = record(
            objective: "Return exactly: Workshop live proof passed. Use no tools and make no external changes.",
            outputs: ["Workshop live proof passed."]
        )
        #expect(WorkshopExecutorLoop.unmetSuccessCriterion(rec) == nil)
    }

    @Test func expectedOutputsEntriesEnforced() {
        let missing = record(
            objective: "Summarize the findings.",
            expectedOutputs: [.string("findings.md written")],
            outputs: ["Here is a summary of things."]
        )
        #expect(WorkshopExecutorLoop.unmetSuccessCriterion(missing) != nil)

        let present = record(
            objective: "Summarize the findings.",
            expectedOutputs: [.string("findings.md written")],
            outputs: ["Done — findings.md written to the workspace."]
        )
        #expect(WorkshopExecutorLoop.unmetSuccessCriterion(present) == nil)
    }

    @Test func noCriterionMeansNoGate() {
        let rec = record(
            objective: "Investigate the flaky test and report.",
            outputs: ["It was a timezone assumption; details attached."]
        )
        #expect(WorkshopExecutorLoop.unmetSuccessCriterion(rec) == nil)
    }

    @Test func multiStepOutputsAreJoinedBeforeMatching() {
        let rec = record(
            objective: "Return exactly: Workshop live proof passed.",
            outputs: ["working on it", "Workshop live proof passed."]
        )
        #expect(WorkshopExecutorLoop.unmetSuccessCriterion(rec) == nil)
    }

    @Test func newlineAfterPhraseDoesNotPolluteExtraction() {
        let rec = record(
            objective: "Return exactly: Workshop live proof passed.\nUse no tools and make no external changes.",
            outputs: ["Workshop live proof passed."]
        )
        #expect(WorkshopExecutorLoop.unmetSuccessCriterion(rec) == nil)
    }

    @Test func exactTextCriterionProducesSatisfiedVerification() {
        let rec = record(
            objective: "Return exactly: Workshop live proof passed.",
            outputs: ["Workshop live proof passed."]
        )
        let verification = WorkshopExecutorLoop.verifyCompletedOutcome(
            rec,
            checkedAt: "2026-07-12T12:00:00Z"
        )
        #expect(verification.status == .satisfied)
        #expect(verification.methods == ["exact_output"])
    }

    @Test func ordinaryNarrativeCompletionStaysUnverified() {
        let rec = record(
            objective: "Investigate the flaky test and report.",
            outputs: ["It was a timezone assumption."]
        )
        let verification = WorkshopExecutorLoop.verifyCompletedOutcome(
            rec,
            checkedAt: "2026-07-12T12:00:00Z"
        )
        #expect(verification.status == .unverified)
        #expect(verification.methods.isEmpty)
    }

    @Test func writeFileBytesAreReadBackExactly() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("workshop-verify-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let path = root.appendingPathComponent("result.txt")
        let content = "verified bytes\n"
        try Data(content.utf8).write(to: path)
        var rec = record(objective: "Write the result.", outputs: [])
        rec.plan = [WorkshopExecutionStep(
            id: "write",
            description: "write",
            toolOrAction: "write_file",
            args: .object([
                "path": .string(path.path),
                "content": .string(content),
                "append": .bool(false),
            ])
        )]
        rec.stepsCompleted = [.object([
            "step_id": .string("write"),
            "status": .string("succeeded"),
            "output": .object([
                "ok": .bool(true),
                "path": .string(path.path),
                "bytes_written": .int(Int64(Data(content.utf8).count)),
            ]),
        ])]

        let verification = WorkshopExecutorLoop.verifyCompletedOutcome(
            rec,
            checkedAt: "2026-07-12T12:00:00Z"
        )
        #expect(verification.status == .satisfied)
        #expect(verification.methods == ["file_bytes"])

        try Data("different\n".utf8).write(to: path)
        let mismatch = WorkshopExecutorLoop.verifyCompletedOutcome(
            rec,
            checkedAt: "2026-07-12T12:00:01Z"
        )
        #expect(mismatch.status == .failed)
        #expect(!mismatch.detail.contains(path.path))
        #expect(!mismatch.detail.contains(content))
    }

    @Test func unsupportedExternalActionCannotBorrowFileVerification() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("workshop-partial-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let path = root.appendingPathComponent("result.txt")
        try Data("ok".utf8).write(to: path)
        var rec = record(objective: "Write and send.", outputs: [])
        rec.plan = [
            WorkshopExecutionStep(
                id: "write", description: "write", toolOrAction: "write_file",
                args: .object(["path": .string(path.path), "content": .string("ok")])
            ),
            WorkshopExecutionStep(
                id: "send", description: "send", toolOrAction: "slack.post_message"
            ),
        ]
        rec.stepsCompleted = [
            .object([
                "step_id": .string("write"), "status": .string("succeeded"),
                "output": .object(["ok": .bool(true), "path": .string(path.path)]),
            ]),
            .object([
                "step_id": .string("send"), "status": .string("succeeded"),
                "output": .object(["ok": .bool(true)]),
            ]),
        ]
        let verification = WorkshopExecutorLoop.verifyCompletedOutcome(
            rec,
            checkedAt: "2026-07-12T12:00:00Z"
        )
        #expect(verification.status == .unverified)
        #expect(verification.methods == ["file_bytes"])
    }
}
