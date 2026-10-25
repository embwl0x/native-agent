import Foundation
// Blueprint: | `SelfImprovement+TrainingReads.swift` | `HarnessBenchmarkRun`, `HarnessBenchmarkCheck` models and benchmark execution returning its result without a duplicate receipt store; unused `evals/runs.json` reads/schema and `harness/benchmark/runs.jsonl` writes/retention are retired; retained files stay on disk, outside backup, export and phone sync, and appear in PrivacyMap |

// Retained evals/runs.json and harness/benchmark/runs.jsonl have no live
// reader or writer. Leave them on disk, outside backup, export and phone
// sync, and list them in PrivacyMap. Manual benchmarks return their result.
public struct HarnessBenchmarkRun: Identifiable, Codable, Hashable, Sendable {
    public var id: String
    public var name: String?
    public var status: String?
    public var checks: [HarnessBenchmarkCheck]?
    public var durationSeconds: Double?
    public var schedule: String?
    public var manualRunnable: Bool?
    public var chatPathImpact: String?
    public var createdAt: String?
}

public struct HarnessBenchmarkCheck: Identifiable, Codable, Hashable, Sendable {
    public var id: String
    public var title: String?
    public var passed: Bool?
    public var detail: String?
}

extension HarnessBenchmarkRun {
    /// Validates the local Swift surfaces — tool manifest, embedding runtime,
    /// Doctor — with no model call or persisted duplicate. A failed read is a failed check that
    /// carries its actual error text.
    public static func run(
        authoredToolCount: () async throws -> Int,
        embeddingRuntimeAvailable: () async -> Bool,
        doctorStatuses: () async -> [String]?
    ) async -> HarnessBenchmarkRun {
        let start = Date()
        var checks: [HarnessBenchmarkCheck] = []

        do {
            let tools = try await authoredToolCount()
            checks.append(HarnessBenchmarkCheck(
                id: "tools_manifest",
                title: "Tool manifest loads",
                passed: true,
                detail: "\(tools) tool row(s)"
            ))
        } catch {
            checks.append(HarnessBenchmarkCheck(
                id: "tools_manifest",
                title: "Tool manifest loads",
                passed: false,
                detail: "tools read failed: \(error.localizedDescription)"
            ))
        }

        let memoryAvailable = await embeddingRuntimeAvailable()
        checks.append(HarnessBenchmarkCheck(
            id: "memory_runtime",
            title: "Memory embedding runtime reports",
            passed: memoryAvailable,
            detail: !memoryAvailable ? "no embedding runtime snapshot" : "embedding runtime snapshot available"
        ))

        let doctor = await doctorStatuses()
        let failedDoctor = doctor?.filter { $0 == "fail" }.count ?? 0
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
        return run
    }
}
