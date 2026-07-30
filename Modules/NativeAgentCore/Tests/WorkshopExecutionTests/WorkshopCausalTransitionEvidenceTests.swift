import Foundation
import NativeAgentCore
import PersistenceCore
import Testing
@testable import WorkshopExecution

@Suite("Workshop causal transition evidence")
struct WorkshopCausalTransitionEvidenceTests {
    @Test("shared motor projection keeps Workshop completion explicitly unverified")
    func sharedMotorProjection() async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("workshop-motor-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let runner = SwiftNativeWorkshopRunner(
            executorAvailable: true,
            root: root,
            enableAutonomy: false
        )
        let submitted = try await runner.submit(spec: WorkshopExecutionSpec(
            title: "Private title",
            objective: "Private objective"
        ))

        let ready = try #require(try await runner.motorActionReadModel(actionId: submitted.executionId))
        #expect(ready.phase == .ready)
        #expect(ready.verification == .notStarted)
        #expect(ready.domainState == "queued")
        #expect(ready.expectedNextEvidence == "execution_start")
        #expect(ready.actionIdentity == CausalTransitionEvidence.opaqueIdentity(submitted.executionId))
        #expect(ready.cancellationIdentity == CausalTransitionEvidence.opaqueIdentity(submitted.executionId))
        #expect(ready.deadline == nil)

        _ = try await runner.updateWorkshopExecution(WorkshopExecutionUpdate(
            id: submitted.executionId,
            status: "completed",
            result: "Private result"
        ))
        let completed = try #require(try await runner.motorActionReadModel(actionId: submitted.executionId))
        #expect(completed.phase == .succeeded)
        #expect(completed.verification == .unverified)
        #expect(completed.expectedNextEvidence == "domain_verification")
        #expect(completed.phase.isTerminal)

        let encoded = String(decoding: try JSONEncoder().encode(completed), as: UTF8.self)
        #expect(!encoded.contains("Private"))
        #expect(!encoded.contains(submitted.executionId))
    }

    @Test("shared motor projection exposes exact Workshop verification")
    func sharedMotorProjectionVerified() async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("workshop-motor-verified-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let runner = SwiftNativeWorkshopRunner(
            executorAvailable: true,
            root: root,
            enableAutonomy: false
        )
        let submitted = try await runner.submit(spec: WorkshopExecutionSpec(
            title: "Private title",
            objective: "Private objective"
        ))
        _ = try await runner.updateWorkshopExecution(WorkshopExecutionUpdate(
            id: submitted.executionId,
            status: "completed",
            result: "Private result"
        ))
        let persistence = SwiftNativePersistenceCore()
        let path = runner.executionRecordPath(submitted.executionId)
        var raw = await persistence.readJSON(path, defaultValue: .null)
        guard case .object(var object) = raw else {
            Issue.record("expected Workshop execution object")
            return
        }
        object["verification"] = WorkshopVerificationRecord(
            status: .satisfied,
            checkedAt: "2026-07-12T12:00:00Z",
            methods: ["file_bytes"]
        ).toJSON()
        raw = .object(object)
        try await persistence.writeJSON(raw, to: path)

        let completed = try #require(try await runner.motorActionReadModel(actionId: submitted.executionId))
        #expect(completed.phase == .succeeded)
        #expect(completed.verification == .satisfied)
        #expect(completed.expectedNextEvidence == nil)
        let encoded = String(decoding: try JSONEncoder().encode(completed), as: UTF8.self)
        #expect(!encoded.contains("Private"))
        #expect(!encoded.contains(submitted.executionId))
    }

    @Test("fixture maps into the shared contract without payload leakage")
    func mapsFixture() throws {
        let privateText = "Private step output must not circulate"
        let timeline: [JSONValue] = [
            .object(["event": .string("enqueued"), "ts": .string("2026-07-12T12:00:00Z"), "objective": .string(privateText)]),
            .object(["event": .string("started"), "ts": .string("2026-07-12T12:00:01Z")]),
            .object(["event": .string("step_completed"), "ts": .string("2026-07-12T12:00:02Z"), "output": .string(privateText)]),
            .object(["event": .string("step_blocked_on_approval"), "ts": .string("2026-07-12T12:00:03Z")]),
            .object(["event": .string("approval_decision"), "ts": .string("2026-07-12T12:00:04Z")]),
            .object(["event": .string("completed"), "ts": .string("2026-07-12T12:00:05Z"), "result": .string(privateText)]),
        ]

        let evidence = SwiftNativeWorkshopRunner.causalTransitionEvidence(
            executionId: "private-execution-id",
            timeline: timeline
        )

        #expect(evidence.count == timeline.count)
        #expect(evidence.allSatisfy { $0.domain == "workshop_execution" })
        #expect(evidence.map(\.afterState) == [
            "queued", "running", "running", "blocked_on_approval", "running", "completed",
        ])
        #expect(evidence[0].expectedNextEvidence == "execution_start")
        #expect(evidence[3].expectedNextEvidence == "approval_resolution")
        #expect(evidence.allSatisfy { $0.operationId.count == 64 && $0.itemIdentity.count == 64 })
        #expect(evidence.allSatisfy { $0.trajectoryID == evidence[0].itemIdentity })
        #expect(evidence.map(\.sequenceNumber) == Array(0..<timeline.count))
        #expect(evidence.last?.terminalClass == "unverified_success")
        #expect(SwiftNativeWorkshopRunner.causalTransitionEvidence(
            executionId: "private-execution-id", timeline: timeline, limit: 2
        ).count == 2)

        let text = String(decoding: try JSONEncoder().encode(evidence), as: UTF8.self)
        #expect(!text.contains(privateText))
        #expect(!text.contains("private-execution-id"))
    }

    @Test("authoritative record adds typed schema only and extracts a verified routine")
    func exactProcedureTrajectory() throws {
        let record = WorkshopExecutionRecord(
            id: "private-execution",
            title: "Private title",
            objective: "Private objective",
            createdAt: "2026-07-12T12:00:00Z",
            status: "completed",
            plan: [
                WorkshopExecutionStep(
                    id: "private-step-a",
                    description: "Private description",
                    toolOrAction: "read_file",
                    args: .object(["path": .string("/Users/private/secret")])
                ),
                WorkshopExecutionStep(
                    id: "private-step-b",
                    description: "Private description",
                    toolOrAction: "write_file",
                    args: .object([
                        "path": .string("/Users/private/result"),
                        "content": .string("private-value"),
                    ])
                ),
            ],
            stepsCompleted: [],
            receiptsDir: "/Users/private/receipts",
            triggerSource: "manual",
            trustRequired: "none",
            expectedOutputs: [],
            currentStepId: "",
            updatedAt: "2026-07-12T12:00:04Z",
            result: .string("private-value"),
            rerunCount: 0,
            verification: WorkshopVerificationRecord(
                status: .satisfied,
                checkedAt: "2026-07-12T12:00:04Z",
                methods: ["file_bytes"]
            )
        )
        let timeline: [JSONValue] = [
            .object(["event": .string("enqueued"), "ts": .string("2026-07-12T12:00:00Z")]),
            .object(["event": .string("started"), "ts": .string("2026-07-12T12:00:01Z")]),
            .object([
                "event": .string("step_completed"), "step_id": .string("private-step-a"),
                "status": .string("succeeded"), "ts": .string("2026-07-12T12:00:02Z"),
            ]),
            .object([
                "event": .string("step_completed"), "step_id": .string("private-step-b"),
                "status": .string("succeeded"), "ts": .string("2026-07-12T12:00:03Z"),
            ]),
            .object(["event": .string("completed"), "ts": .string("2026-07-12T12:00:04Z")]),
        ]
        let evidence = SwiftNativeWorkshopRunner.causalTransitionEvidence(
            executionId: record.id,
            timeline: timeline,
            record: record
        )
        let report = ProcedureTrajectoryExtractor.extract(evidence)
        let trajectory = try #require(report.trajectories.first)
        #expect(trajectory.authorityClass == "low_risk")
        #expect(trajectory.inputClass == "manual")
        #expect(trajectory.parameterSchemaIdentity.count == 64)
        #expect(trajectory.steps[2].actionKind == "tool:read_file")
        #expect(trajectory.steps[3].actionKind == "tool:write_file")
        #expect(trajectory.terminalClass == .verifiedSuccess)
        #expect(trajectory.durationMilliseconds == 4_000)
        #expect(trajectory.providerCallCount == nil)
        #expect(trajectory.removableOrchestrationProviderCallCount == nil)

        let encoded = String(decoding: try JSONEncoder().encode(evidence), as: UTF8.self)
        #expect(!encoded.contains("Private"))
        #expect(!encoded.contains("private-value"))
        #expect(!encoded.contains("/Users/"))
        #expect(!encoded.contains("private-step"))
        #expect(!encoded.contains(record.id))
    }

    @Test("terminal transition publishes exact owned provider accounting once")
    func exactProviderAccounting() throws {
        let synthesize = WorkshopStepOutcome(
            stepId: "synthesize",
            status: "succeeded",
            executedAt: "2026-07-12T12:00:02Z",
            providerCallCount: 2,
            removableOrchestrationProviderCallCount: 0
        )
        let write = WorkshopStepOutcome(
            stepId: "write",
            status: "succeeded",
            executedAt: "2026-07-12T12:00:03Z",
            providerCallCount: 0,
            removableOrchestrationProviderCallCount: 0
        )
        let record = WorkshopExecutionRecord(
            id: "accounted-execution",
            title: "Private",
            objective: "Private",
            createdAt: "2026-07-12T12:00:00Z",
            status: "completed",
            plan: [
                WorkshopExecutionStep(id: "synthesize", description: "Private", toolOrAction: "chat.synthesize"),
                WorkshopExecutionStep(id: "write", description: "Private", toolOrAction: "write_file"),
            ],
            stepsCompleted: [synthesize.toJSON(), write.toJSON()],
            receiptsDir: "/private",
            triggerSource: "manual",
            trustRequired: "none",
            expectedOutputs: [],
            currentStepId: "",
            updatedAt: "2026-07-12T12:00:04Z",
            result: .null,
            rerunCount: 0,
            planningProviderCallCount: 1,
            planningRemovableOrchestrationProviderCallCount: 1,
            verification: WorkshopVerificationRecord(
                status: .satisfied,
                checkedAt: "2026-07-12T12:00:04Z",
                methods: ["file_bytes"]
            )
        )
        let timeline: [JSONValue] = [
            .object(["event": .string("enqueued"), "ts": .string("2026-07-12T12:00:00Z")]),
            .object(["event": .string("started"), "ts": .string("2026-07-12T12:00:01Z")]),
            .object(["event": .string("step_completed"), "step_id": .string("synthesize"), "status": .string("succeeded"), "ts": .string("2026-07-12T12:00:02Z")]),
            .object(["event": .string("step_completed"), "step_id": .string("write"), "status": .string("succeeded"), "ts": .string("2026-07-12T12:00:03Z")]),
            .object(["event": .string("completed"), "ts": .string("2026-07-12T12:00:04Z")]),
        ]
        let evidence = SwiftNativeWorkshopRunner.causalTransitionEvidence(
            executionId: record.id,
            timeline: timeline,
            record: record
        )
        #expect(evidence.dropLast().allSatisfy { $0.providerCallCount == nil })
        #expect(evidence.last?.providerCallCount == 3)
        #expect(evidence.last?.removableOrchestrationProviderCallCount == 1)
        let trajectory = try #require(ProcedureTrajectoryExtractor.extract(evidence).trajectories.first)
        #expect(trajectory.providerCallCount == 3)
        #expect(trajectory.removableOrchestrationProviderCallCount == 1)

        var legacyStepRecord = record
        legacyStepRecord.stepsCompleted = [.object([
            "step_id": .string("synthesize"),
            "status": .string("succeeded"),
        ])]
        let incomplete = SwiftNativeWorkshopRunner.causalTransitionEvidence(
            executionId: legacyStepRecord.id,
            timeline: timeline,
            record: legacyStepRecord
        )
        #expect(incomplete.last?.providerCallCount == nil)
        #expect(incomplete.last?.removableOrchestrationProviderCallCount == nil)
    }

    @Test("unknown events remain explicit domain-specific evidence")
    func preservesUnknownEventWithoutInventingState() {
        let evidence = SwiftNativeWorkshopRunner.causalTransitionEvidence(
            executionId: "execution",
            timeline: [.object([
                "event": .string("future_event"),
                "ts": .string("2026-07-12T12:00:00Z"),
            ])]
        )
        #expect(evidence.first?.kind == "domain_specific")
        #expect(evidence.first?.beforeState == nil)
        #expect(evidence.first?.afterState == nil)
    }
}
