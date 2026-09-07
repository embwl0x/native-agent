import Foundation
import PersistenceCore
import MemoryV2
import DoctorChecks
import SelfImprovement
import TriggerScheduler

extension NativeClient {
    func startImprovement(objective: String) async throws -> ImprovementRun {
        // Map the canonical orchestrator result to the app presentation model.
        let core = try await SelfImprovementOrchestrator.shared.startImprovement(objective: objective)
        return ImprovementRun(
            id: core.id,
            objective: core.objective ?? objective,
            status: core.status ?? "pending",
            phase: core.phase ?? "pending",
            createdAt: core.createdAt ?? ISO8601DateFormatter().string(from: Date()),
            summary: core.summary,
            completedAt: core.completedAt,
            model: core.model,
            worktree: core.worktree,
            exitReason: core.exitReason,
            promotedCommitSha: core.promotedCommitSha,
            revertCommitSha: core.revertCommitSha
        )
    }

    func createRecurringImprovement(objective: String, intervalSeconds: Int) async throws -> SchedulerJob {
        let writer = makeSchedulerJobWriter(
            connectorActionIDs: Self.connectorActionIDSet(),
            dataRoot: dataRootOverride ?? PersistenceCore.defaultDataRoot()
        )
        let trimmed = objective.trimmingCharacters(in: .whitespacesAndNewlines)
        let body: JSONValue = .object([
            "name": .string("Continuous Self-Improvement"),
            "kind": .string("improve"),
            "interval_seconds": .int(Int64(max(60, intervalSeconds))),
            "payload": .object([
                "objective": .string(trimmed.isEmpty ? "Make NativeAgent meaningfully better." : trimmed),
            ]),
        ])
        let jobJSON = try await writer.createJob(body: body)
        let data = try jobJSON.serializedData(pretty: false)
        return try JSONDecoder().decode(SchedulerJob.self, from: data)
    }

    func runHarnessBenchmark() async throws -> HarnessBenchmarkRun {
        let start = Date()
        var checks: [HarnessBenchmarkCheck] = []

        // Failed reads produce failed checks with their actual error text.
        do {
            let tools = try await getTools()
            checks.append(HarnessBenchmarkCheck(
                id: "tools_manifest",
                title: "Tool manifest loads",
                passed: !tools.isEmpty,
                detail: "\(tools.count) tool row(s)"
            ))
        } catch {
            checks.append(HarnessBenchmarkCheck(
                id: "tools_manifest",
                title: "Tool manifest loads",
                passed: false,
                detail: "tools read failed: \(error.localizedDescription)"
            ))
        }

        do {
            let mcpServers = try await getMCPServers()
            checks.append(HarnessBenchmarkCheck(
                id: "mcp_registry",
                title: "MCP registry loads",
                passed: true,
                detail: "\(mcpServers.count) configured server(s)"
            ))
        } catch {
            checks.append(HarnessBenchmarkCheck(
                id: "mcp_registry",
                title: "MCP registry loads",
                passed: false,
                detail: "MCP registry read failed: \(error.localizedDescription)"
            ))
        }

        let memorySnapshot = await SwiftNativeMemoryV2.shared.embeddingRuntimeSnapshot()
        checks.append(HarnessBenchmarkCheck(
            id: "memory_runtime",
            title: "Memory embedding runtime reports",
            passed: memorySnapshot != nil,
            detail: memorySnapshot == nil ? "no embedding runtime snapshot" : "embedding runtime snapshot available"
        ))

        let doctor = try? await makeDoctorChecks().runAll(repair: false, checkLLM: false)
        let failedDoctor = doctor?.filter { $0.status == "fail" }.count ?? 0
        checks.append(HarnessBenchmarkCheck(
            id: "doctor_snapshot",
            title: "Doctor checks run",
            passed: doctor != nil && failedDoctor == 0,
            detail: doctor == nil ? "doctor unavailable" : "\(doctor?.count ?? 0) check(s), \(failedDoctor) fail"
        ))

        let passed = checks.allSatisfy { $0.passed == true }
        let run = HarnessBenchmarkRun(
            id: "hb-\(UUID().uuidString.lowercased())",
            name: "Swift Native Harness Benchmark",
            status: passed ? "passed" : "warn",
            checks: checks,
            durationSeconds: Date().timeIntervalSince(start),
            schedule: "manual",
            manualRunnable: true,
            chatPathImpact: "No model call; validates local Swift surfaces only.",
            createdAt: ISO8601DateFormatter().string(from: Date())
        )
        try? await Self.persistHarnessBenchmarkRun(
            run,
            dataRoot: dataRootOverride ?? PersistenceCore.defaultDataRoot()
        )
        return run
    }

    static func persistHarnessBenchmarkRun(
        _ run: HarnessBenchmarkRun,
        dataRoot: URL = PersistenceCore.defaultDataRoot()
    ) async throws {
        let data = try JSONEncoder().encode(run)
        let row = try JSONValue.parse(data)
        let path = dataRoot
            .appendingPathComponent("harness", isDirectory: true)
            .appendingPathComponent("benchmark", isDirectory: true)
            .appendingPathComponent("runs.jsonl")
        let persistence = SwiftNativePersistenceCore()
        try await appendPathOwnedJSONL(
            row,
            to: path,
            using: persistence,
            logLabel: "NativeClient.harnessBenchmark"
        )
    }

    func promoteImprovement(runId: String) async throws -> ImprovementPromoteResult {
        let r = try await SelfImprovementOrchestrator.shared.promote(runId: runId)
        return ImprovementPromoteResult(
            ok: r.ok,
            commitSha: r.commitSha,
            filesChanged: nil,
            error: r.error,
            warning: nil,
            swiftChanged: r.swiftChanged
        )
    }

    func discardImprovement(runId: String) async throws -> ImprovementRevertResult {
        // Discard uses the same revert operation, including its explicit
        // no-op/error result for a never-promoted worktree.
        try await revertImprovement(runId: runId)
    }

    func revertImprovement(runId: String) async throws -> ImprovementRevertResult {
        let r = try await SelfImprovementOrchestrator.shared.revert(runId: runId)
        return ImprovementRevertResult(
            ok: r.ok,
            revertCommitSha: nil,
            originalCommitSha: nil,
            warning: nil,
            error: r.error
        )
    }

}
