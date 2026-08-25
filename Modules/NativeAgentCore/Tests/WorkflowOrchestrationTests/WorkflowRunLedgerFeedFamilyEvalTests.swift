import Foundation
import ApprovalInbox
import NativeAgentCore
import PersistenceCore
import Testing
@testable import WorkflowOrchestration

@Suite("Workflow run-ledger feed family", .serialized)
struct WorkflowRunLedgerFeedFamilyEvalTests {
    private func root(_ suffix: String) throws -> URL {
        let value = FileManager.default.temporaryDirectory
            .appendingPathComponent("workflow-ledger-feed-\(suffix)-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: value, withIntermediateDirectories: true)
        return value
    }

    private func write(_ value: JSONValue, to path: URL) throws {
        try FileManager.default.createDirectory(at: path.deletingLastPathComponent(), withIntermediateDirectories: true)
        try value.serializedData(pretty: false).write(to: path)
    }

    @Test("real writer and reader retain terminal, in-progress, denied, damaged, stale, and reload evidence")
    func realWriterAndReaderExposeHonestFeedFamilyEvidence() async throws {
        let dataRoot = try root("primary")
        let outsideRoot = try root("outside")
        defer {
            try? FileManager.default.removeItem(at: dataRoot)
            try? FileManager.default.removeItem(at: outsideRoot)
        }

        let registry = dataRoot.appendingPathComponent("workflows/registry.json")
        try write(.array([
            .object([
                "id": .string("complete"), "name": .string("Complete"),
                "engineVersion": .string("1"), "status": .string("active"),
                "steps": .array([.object(["id": .string("trace"), "kind": .string("trace")])]),
            ]),
            .object([
                "id": .string("deny"), "name": .string("Deny"),
                "engineVersion": .string("2"), "status": .string("active"),
                "steps": .array([.object([
                    "id": .string("gate"), "kind": .string("approval"), "requiresApproval": .bool(true),
                ])]),
            ]),
            .object([
                "id": .string("not-runnable"), "name": .string("Not runnable"),
                "status": .string("active"),
                "steps": .array([.object(["id": .string("retired"), "kind": .string("retired_kind")])]),
            ]),
        ]), to: registry)

        let writer = SwiftNativeWorkflowOrchestrationClient(root: dataRoot, useFileLock: false)
        let succeeded = try await writer.runWorkflow(
            id: "complete", objective: "record completion", execute: false, engineVersion: nil, variables: nil
        )
        #expect(WorkflowRunLedgerFeedFamilyEvalTests.status(succeeded) == "succeeded")

        let waiting = try await writer.runWorkflow(
            id: "deny", objective: "require consent", execute: true, engineVersion: nil, variables: nil
        )
        #expect(Self.status(waiting) == "waiting_approval")
        let approvalID = try #require(Self.string(waiting, "approvalId"))
        _ = try await SwiftNativeApprovalInbox(root: dataRoot).resolve(
            approvalID, decision: .denied, decidedBy: "feed-eval"
        )
        let denied = try await writer.resumeWorkflowRun(id: Self.string(waiting, "id") ?? "")
        #expect(Self.status(denied) == "failed")

        // A relaunch reader must use this root, preserve append order, and keep
        // the in-progress approval receipt alongside its refused terminal row.
        let reloaded = SwiftNativeWorkflowOrchestrationClient(root: dataRoot, useFileLock: false)
        let beforeDamage = try await reloaded.readWorkflowRunLedgerFeedFamily()
        #expect(beforeDamage.runsSource == .available)
        #expect(Self.status(beforeDamage.recentRuns.first ?? .null) == "failed")
        #expect(beforeDamage.runStatusCounts["succeeded"] == 1)
        #expect(beforeDamage.runStatusCounts["waiting_approval"] == 1)
        #expect(beforeDamage.runStatusCounts["failed"] == 1)
        // runWorkflow's registry access merges the built-in defaults
        // (WorkflowDefaults) back into registry.json (Python-parity
        // _list_workflows_locked behavior), so the reader also counts the
        // template placeholders' deliberately-unrunnable kinds alongside the
        // seeded retired_kind row. The executor vocabulary
        // (WorkflowExecutionPreflight.supportedStepKinds) has never included
        // llm/receipt/analysis/tool_proposal/validation.
        #expect(beforeDamage.unsupportedStepKinds == [
            "retired_kind": 1, "llm": 1, "receipt": 1,
            "analysis": 1, "tool_proposal": 1, "validation": 1,
        ])
        #expect(!FileManager.default.fileExists(atPath: outsideRoot.appendingPathComponent("workflows/runs.jsonl").path))

        let staleState = dataRoot.appendingPathComponent("workflows/run_state/stranded.json")
        try write(.object([
            "id": .string("stranded"), "status": .string("running"),
            "createdAt": .string("2026-01-01T00:00:00Z"),
        ]), to: staleState)
        try FileManager.default.setAttributes(
            [.modificationDate: Date(timeIntervalSince1970: 1_700_000_000)], ofItemAtPath: staleState.path
        )
        let corruptState = dataRoot.appendingPathComponent("workflows/run_state/partial.json")
        try Data("{not-json".utf8).write(to: corruptState)

        let runsPath = dataRoot.appendingPathComponent("workflows/runs.jsonl")
        let append = try FileHandle(forWritingTo: runsPath)
        try append.seekToEnd()
        try append.write(Data("{not-json}\n".utf8))
        try append.close()

        let damaged = try await reloaded.readWorkflowRunLedgerFeedFamily(
            drainWindow: 60, observedAt: Date(timeIntervalSince1970: 1_700_100_000)
        )
        #expect(damaged.runsSource == .partial(malformedRecords: 1))
        #expect(damaged.runStateSource == .partial(malformedRecords: 1))
        #expect(damaged.staleNonTerminalRunStateIDs == ["stranded"])
        #expect(damaged.runStatusCounts["failed"] == 1)

        // The route-compatible reader still presents retained valid rows, but
        // the companion evidence never lets diagnostics call the damaged tail a
        // clean empty source.
        let presented = try await reloaded.listWorkflowRuns()
        #expect(presented.count == 3)
        #expect(Self.status(presented.first ?? .null) == "failed")
    }

    @Test("absent and unavailable run sources remain distinct from an empty ledger")
    func absentAndUnavailableSourcesAreExplicit() async throws {
        let absentRoot = try root("absent")
        let unavailableRoot = try root("unavailable")
        defer {
            try? FileManager.default.removeItem(at: absentRoot)
            try? FileManager.default.removeItem(at: unavailableRoot)
        }

        let absent = try await SwiftNativeWorkflowOrchestrationClient(root: absentRoot, useFileLock: false)
            .readWorkflowRunLedgerFeedFamily()
        #expect(absent.runsSource == .absent)
        #expect(absent.registrySource == .absent)
        #expect(absent.runStateSource == .absent)

        let unavailableRuns = unavailableRoot.appendingPathComponent("workflows/runs.jsonl", isDirectory: true)
        try FileManager.default.createDirectory(at: unavailableRuns, withIntermediateDirectories: true)
        let unavailableStates = unavailableRoot.appendingPathComponent("workflows/run_state")
        try Data("not a directory".utf8).write(to: unavailableStates)
        let unavailable = try await SwiftNativeWorkflowOrchestrationClient(root: unavailableRoot, useFileLock: false)
            .readWorkflowRunLedgerFeedFamily()
        if case .unavailable = unavailable.runsSource {} else {
            Issue.record("a directory at runs.jsonl must not read as an empty ledger")
        }
        if case .unavailable = unavailable.runStateSource {} else {
            Issue.record("a file at run_state must not read as an absent state family")
        }
    }

    private static func string(_ value: JSONValue, _ key: String) -> String? {
        guard case .object(let object) = value, case .string(let string)? = object[key] else { return nil }
        return string
    }

    private static func status(_ value: JSONValue) -> String? {
        string(value, "status")
    }
}
