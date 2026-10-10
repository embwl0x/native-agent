import Foundation
import Observation
import NativeAgentShared
import PersistenceCore
import TriggerScheduler
import SelfImprovement
import MCPDispatcher
import MemoryV2
import DoctorChecks

struct TrainingArtifact: Identifiable, Codable, Hashable {
    var id: String
    var kind: String
    var title: String?
    var sourceId: String?
    var sensitivity: String?
    var status: String?
    var createdAt: String?
    var summary: String?
}

struct HarnessBenchmarkRun: Identifiable, Codable, Hashable {
    var id: String
    var name: String?
    var status: String?
    var checks: [HarnessBenchmarkCheck]?
    var durationSeconds: Double?
    var schedule: String?
    var manualRunnable: Bool?
    var chatPathImpact: String?
    var createdAt: String?
}

struct HarnessBenchmarkCheck: Identifiable, Codable, Hashable {
    var id: String
    var title: String?
    var passed: Bool?
    var detail: String?
}

extension HarnessBenchmarkRun {
    /// Validates the local Swift surfaces — tool manifest, MCP registry,
    /// embedding runtime, Doctor — with no model call, and appends the run to
    /// `harness/benchmark/runs.jsonl`. A failed read is a failed check that
    /// carries its actual error text.
    static func run(dataRoot: URL) async -> HarnessBenchmarkRun {
        let start = Date()
        var checks: [HarnessBenchmarkCheck] = []

        do {
            let tools = try await ToolsFacade(dataRoot: dataRoot).listAuthored()
            checks.append(HarnessBenchmarkCheck(
                id: "tools_manifest",
                title: "Tool manifest loads",
                passed: true,
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
            let mcpServers = try await makeMCPDispatcher().listServers()
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

        let doctor = try? await makeDoctorChecks().runAll(repair: false)
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
        if let row = try? JSONValue.parse(JSONEncoder().encode(run)) {
            let path = dataRoot
                .appendingPathComponent("harness", isDirectory: true)
                .appendingPathComponent("benchmark", isDirectory: true)
                .appendingPathComponent("runs.jsonl")
            try? await appendPathOwnedJSONL(
                row, to: path, using: SwiftNativePersistenceCore(), logLabel: "NativeClient.harnessBenchmark"
            )
        }
        return run
    }
}

// PATCH-2026-05-08: no-terminal-moments — rebuild result
struct SystemRebuildResult: Codable, Hashable {
    var ok: Bool
    var message: String?
    var error: String?
}
