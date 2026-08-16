import Foundation
import Observation
import Darwin
import AppKit
import NativeAgentShared
import PersistenceCore
import NativeAgentCore
import MemoryV2
import ToolRegistry
import KnowledgeGraph
import XConnector
import ProviderRouting
import BackgroundLoops
import ApprovalInbox
import MCPDispatcher
import ToolExecution
import PersonaEngine
import ChatOrchestration
import TrustCenter
import DreamREMCycle
import DoctorChecks
import CommandPalette
import SelfImprovement
import Research
import MultimodalTTS
import TriggerScheduler
import WorkshopExecution
import NotificationInbox
import SystemOps
import ScreenVision
import TelegramBot
import Dispatcher
import MacControl
import Onboarding
import MacAssistantStatus
import WorkflowOrchestration
import Skills
import Connectors
import Browser

// W-H Band (U5 decomposition, move-only): improvement lifecycle ops
// (startImprovement, createRecurringImprovement, cleanupImprovementNoise,
// runHarnessBenchmark, getImprovementDiff, promote/discard/revertImprovement)
// relocated verbatim. Two documented lifts in the root (stay there):
// connectorActionIDSet (private->internal), swiftImprovementDiff
// (fileprivate->internal).
extension NativeClient {
    func startImprovement(objective: String) async throws -> ImprovementRun {
        // F6 (eval E06 fix-2): route through Core SelfImprovementOrchestrator
        // actor (Modules/.../SelfImprovement/SelfImprovementOrchestrator.swift).
        // The actor stages a pending run on disk and returns a Core ImprovementRun;
        // we map it to the app-side ImprovementRun (same field set).
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
        let writer = makeSchedulerJobWriter(connectorActionIDs: Self.connectorActionIDSet())
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

    func cleanupImprovementNoise() async throws -> ImprovementCleanupResult {
        // DAEMON-DEAD PORT P4: STUB — return empty result.
        return ImprovementCleanupResult(
            removedJobs: 0,
            removedInterruptedTestRuns: 0,
            repairedReceiptFailures: 0,
            createdAt: ISO8601DateFormatter().string(from: Date())
        )
    }

    func runHarnessBenchmark() async throws -> HarnessBenchmarkRun {
        let start = Date()
        var checks: [HarnessBenchmarkCheck] = []

        // U5 W-A item 1 (:13399/:13407): both reads previously swallowed
        // failures into [] — the tools check failed with a LYING detail
        // ("0 tool row(s)" instead of the read error) and the MCP check
        // passed unconditionally. A failed read is now a failed check
        // carrying the real error text.
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
        try? await Self.persistHarnessBenchmarkRun(run)
        return run
    }

    private static func persistHarnessBenchmarkRun(_ run: HarnessBenchmarkRun) async throws {
        let data = try JSONEncoder().encode(run)
        let row = try JSONValue.parse(data)
        let path = PersistenceCore.defaultDataRoot()
            .appendingPathComponent("harness", isDirectory: true)
            .appendingPathComponent("benchmark", isDirectory: true)
            .appendingPathComponent("runs.jsonl")
        let persistence = SwiftNativePersistenceCore()
        try await persistence.withFileLock(path) {
            try await persistence.appendJSONL(row, to: path)
        }
    }

    // PATCH-2026-05-08: improve-review-loop — diff/promote/discard client methods
    func getImprovementDiff(runId: String) async throws -> ImprovementDiffPayload {
        // wave 33 W09 — PORTED-DORMANT (gate: .selfImprovement, default OFF).
        // Native read of the staged worktree diff (run-record lookup +
        // read-only git probe). No trust gate on this route. Mac-only consumer
        // (ImprovementDiffSheet); no iOS caller. See CUTOVER_PLAN §6.96.
        return try await swiftImprovementDiff(runId: runId)
    }

    func promoteImprovement(runId: String) async throws -> ImprovementPromoteResult {
        // F6 (eval E06 fix-2): route through Core SelfImprovementOrchestrator.
        // The actor runs the swift-build compile gate, stamps the run as
        // promoted, and returns the head commit sha (best-effort).
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
        // residue/R6: daemon discard route retired. Treat discard as a revert
        // through SelfImprovementOrchestrator (idempotent on a never-promoted
        // worktree run). Propagate ok + error so callers can't claim success
        // when revert honestly reports it did nothing.
        let r = try await SelfImprovementOrchestrator.shared.revert(runId: runId)
        return ImprovementRevertResult(
            ok: r.ok,
            revertCommitSha: nil,
            originalCommitSha: nil,
            warning: nil,
            error: r.error
        )
    }

    func revertImprovement(runId: String) async throws -> ImprovementRevertResult {
        // F6 (eval E06 fix-2): route through Core SelfImprovementOrchestrator.
        let r = try await SelfImprovementOrchestrator.shared.revert(runId: runId)
        return ImprovementRevertResult(
            ok: r.ok,
            revertCommitSha: nil,
            originalCommitSha: nil,
            warning: nil,
            error: r.error
        )
    }

    // PATCH-2026-05-08: no-terminal-moments — system rebuild + git push/stash-recover
}
