import Foundation
import NativeAgentCore
import PersistenceCore
import Testing
import WorkflowOrchestration
@testable import NativeAgentApp

@Suite("Workflow resident outcome projector")
struct WorkflowResidentOutcomeProjectorTests {
    @Test("real canonical run reaches resident observer without gaining authority")
    func realRunProjects() async throws {
        let root = try makeRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        try await writeState(root: root, runID: "run-real", status: "succeeded", mode: "real")
        let recorder = WorkflowOutcomeRecorder()
        let client = SwiftNativeWorkflowOrchestrationClient(root: root, useFileLock: false)

        await WorkflowResidentOutcomeProjector.observe(
            client: client,
            actionId: "run-real",
            dataRoot: root,
            canonicalRoot: root,
            observer: { await recorder.record($0) }
        )

        let model = try #require(await recorder.models().first)
        #expect(model.domain == "workflow_orchestration")
        #expect(model.phase == .succeeded)
        #expect(model.verification == .unverified)
        #expect(model.expectedNextEvidence == "domain_verification")
    }

    @Test("dry runs and noncanonical roots cannot become lived consequences")
    func confinementAndDryRun() async throws {
        let root = try makeRoot()
        let other = try makeRoot()
        defer {
            try? FileManager.default.removeItem(at: root)
            try? FileManager.default.removeItem(at: other)
        }
        try await writeState(root: root, runID: "dry", status: "succeeded", mode: "dry_run")
        try await writeState(root: root, runID: "real", status: "succeeded", mode: "real")
        let recorder = WorkflowOutcomeRecorder()
        let client = SwiftNativeWorkflowOrchestrationClient(root: root, useFileLock: false)

        await WorkflowResidentOutcomeProjector.observe(
            client: client,
            actionId: "dry",
            dataRoot: root,
            canonicalRoot: root,
            observer: { await recorder.record($0) }
        )
        await WorkflowResidentOutcomeProjector.observe(
            client: client,
            actionId: "real",
            dataRoot: root,
            canonicalRoot: other,
            observer: { await recorder.record($0) }
        )
        await WorkflowResidentOutcomeProjector.observe(
            client: client,
            actionId: "real",
            dataRoot: root,
            canonicalRoot: root,
            executionWasRequested: false,
            observer: { await recorder.record($0) }
        )

        #expect(await recorder.models().isEmpty)
    }

    @Test("catch projection requires an authoritative owner-state change")
    func catchProjectionRequiresChange() async throws {
        let root = try makeRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        try await writeState(
            root: root,
            runID: "run-existing",
            status: "succeeded",
            mode: "real",
            updatedAt: "2026-07-14T00:00:00Z"
        )
        let recorder = WorkflowOutcomeRecorder()
        let client = SwiftNativeWorkflowOrchestrationClient(root: root, useFileLock: false)
        let baseline = await WorkflowResidentOutcomeProjector.snapshot(
            client: client,
            actionId: "run-existing",
            dataRoot: root,
            canonicalRoot: root
        )

        await WorkflowResidentOutcomeProjector.observeChanged(
            client: client,
            actionId: "run-existing",
            dataRoot: root,
            canonicalRoot: root,
            baseline: baseline,
            observer: { await recorder.record($0) }
        )
        #expect(await recorder.models().isEmpty)

        try await writeState(
            root: root,
            runID: "run-existing",
            status: "failed",
            mode: "real",
            updatedAt: "2026-07-14T00:00:01Z"
        )
        await WorkflowResidentOutcomeProjector.observeChanged(
            client: client,
            actionId: "run-existing",
            dataRoot: root,
            canonicalRoot: root,
            baseline: baseline,
            observer: { await recorder.record($0) }
        )

        let projected = try #require(await recorder.models().first)
        #expect(projected.phase == .failed)
        #expect(projected.updatedAt == "2026-07-14T00:00:01Z")
    }

    private func makeRoot() throws -> URL {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("workflow-resident-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        return root
    }

    private func writeState(
        root: URL,
        runID: String,
        status: String,
        mode: String,
        updatedAt: String = "2026-07-14T00:00:00Z"
    ) async throws {
        let path = root
            .appendingPathComponent("workflows/run_state", isDirectory: true)
            .appendingPathComponent("\(runID).json")
        try await SwiftNativePersistenceCore().writeJSON(.object([
            "id": .string(runID),
            "status": .string(status),
            "mode": .string(mode),
            "updatedAt": .string(updatedAt),
            "steps": .array([]),
        ]), to: path)
    }
}

private actor WorkflowOutcomeRecorder {
    private var values: [MotorActionReadModel] = []

    func record(_ model: MotorActionReadModel) { values.append(model) }
    func models() -> [MotorActionReadModel] { values }
}
