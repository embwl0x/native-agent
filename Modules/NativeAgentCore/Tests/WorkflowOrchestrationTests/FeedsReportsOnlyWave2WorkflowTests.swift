import Foundation
import NativeAgentCore
import Testing
@testable import PersistenceCore
@testable import WorkflowOrchestration

@Suite("Feeds reports-only wave 2 workflows", .serialized)
struct FeedsReportsOnlyWave2WorkflowTests {
    @Test("feeds.workflows.uncovered joins an old run state to its existing terminal ledger row")
    func workflowFeedJoinsOldStateToExistingTerminalRunWithoutDuplicateAppend() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("feeds-wave2-workflow-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: root) }
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let client = SwiftNativeWorkflowOrchestrationClient(root: root, now: { "2026-08-24T12:00:00+00:00" }, uuid: { "wave2" })
        let created = try await client.createWorkflow(.object([
            "name": .string("Feed proof"),
            "steps": .array([.object(["kind": .string("trace"), "title": .string("record")])]),
        ]))
        guard case .object(let object) = created, case .string(let id)? = object["id"] else {
            Issue.record("production createWorkflow did not return an id")
            return
        }
        #expect((try await client.listWorkflows()).contains { row in
            guard case .object(let object) = row else { return false }
            return object["id"] == .string(id)
        })

        func statePath(_ runID: String) -> URL {
            root.appendingPathComponent("workflows/run_state/\(WorkflowRunState.slugify(runID)).json")
        }
        func orphanState(_ runID: String) -> JSONValue {
            .object([
                "id": .string(runID),
                "workflowId": .string(id),
                "workflowName": .string("Feed proof"),
                "objective": .string("finish the orphan"),
                "status": .string("running"),
                "engineVersion": .string("2"),
                "createdAt": .string("2026-08-16T12:00:00+00:00"),
                "updatedAt": .string("2026-08-16T12:00:00+00:00"),
                "currentStepIndex": .int(0),
                "activeStepAttempt": .object([
                    "stepId": .string("record"),
                    "ownerIdentity": .string("retired-process"),
                    "ownerPID": .int(0),
                    "startedAt": .string("2026-08-16T12:00:00+00:00"),
                ]),
            ])
        }
        let runID = "orphan-after-dispatch"
        let oldStatePath = statePath(runID)
        try FileManager.default.createDirectory(at: oldStatePath.deletingLastPathComponent(), withIntermediateDirectories: true)
        try orphanState(runID).serializedData(pretty: true).write(to: oldStatePath)
        try FileManager.default.setAttributes([.modificationDate: Date().addingTimeInterval(-2 * 60 * 60)], ofItemAtPath: oldStatePath.path)
        let oldMetadata = try oldStatePath.resourceValues(forKeys: [.contentModificationDateKey])
        #expect((oldMetadata.contentModificationDate ?? .distantFuture) <= Date().addingTimeInterval(-60 * 60))
        let runsPath = root.appendingPathComponent("workflows/runs.jsonl")
        let terminal: JSONValue = .object([
            "id": .string(runID),
            "workflowId": .string(id),
            "status": .string("succeeded"),
            "completedAt": .string("2026-08-17T12:00:00+00:00"),
        ])
        var terminalLine = try terminal.serializedData(pretty: false)
        terminalLine.append(0x0A)
        try terminalLine.write(to: runsPath)

        let repaired = try await client.listWorkflowRuns()
        #expect(repaired.count == 1)
        guard case .object(let run)? = repaired.first else {
            Issue.record("the old orphan was not joined into the workflow run feed")
            return
        }
        #expect(run["id"] == .string(runID))
        #expect(run["status"] == .string("succeeded"))

        let persisted = try JSONValue.parse(Data(contentsOf: oldStatePath))
        guard case .object(let object) = persisted,
              object["status"] == .string("succeeded"),
              object["completedAt"] == .string("2026-08-17T12:00:00+00:00"),
              object["activeStepAttempt"] == .null else {
            Issue.record("reconciliation did not join the old run state to its durable terminal row")
            return
        }
        // Re-enter recovery after the age gate, not just immediately (which
        // skips the state and would conceal repeated terminal rewrites).
        let repairedBytes = try Data(contentsOf: oldStatePath)
        let oldModifiedAt = Date(timeIntervalSince1970: 1_700_000_000)
        try FileManager.default.setAttributes([.modificationDate: oldModifiedAt], ofItemAtPath: oldStatePath.path)
        let laterClient = SwiftNativeWorkflowOrchestrationClient(root: root, now: { "2026-08-25T12:00:00+00:00" }, uuid: { "wave2" })
        let repeated = try await laterClient.listWorkflowRuns()
        #expect(repeated.count == 1)
        #expect(try Data(contentsOf: oldStatePath) == repairedBytes)
        // URL resource values were cached by the initial age assertion above.
        let repeatedAttributes = try FileManager.default.attributesOfItem(atPath: oldStatePath.path)
        #expect(repeatedAttributes[.modificationDate] as? Date == oldModifiedAt)
    }
}
