import DoctorChecks
import Foundation
import Observation
import NativeAgentShared
import PersistenceCore
import SelfImprovement
import AppToolRuntime
import MacControl
import SystemOps

typealias ImprovementGauntletRun = SelfImprovement.ImprovementGauntletRun

typealias GauntletCheck = SelfImprovement.GauntletCheck

typealias ProductionHardeningSummary = DoctorChecks.ProductionHardeningSummary

typealias ProductionExport = SystemOps.ProductionExport

typealias NextGenSummary = EngineRuntime.NextGenSummary
typealias NextGenPhaseRange = EngineRuntime.NextGenPhaseRange
typealias NextGenPhase = EngineRuntime.NextGenPhase
typealias NextGenAction = EngineRuntime.NextGenAction
typealias NextGenReceipt = EngineRuntime.NextGenReceipt
typealias NextGenPhasesResponse = EngineRuntime.NextGenPhasesResponse
typealias NextGenActionResponse = EngineRuntime.NextGenActionResponse
typealias NextGenJSONValue = EngineRuntime.NextGenJSONValue

extension NextGenReceipt {
    // 2026-06-07 ui-taste-sweep #83: receipt rows on Capabilities used to
    // render the raw `detail` string — comma-separated "key: value, key:
    // value, createdAt: <ISO>" dumps with microsecond timestamps. Users
    // can't parse that at a glance. `humanized` runs the parser in
    // UserDisplayFormatters.humanizeReceipt so the row shows
    // "Archived · stale duplicate · 5 days ago" and the raw kv pairs are
    // available for an inspector / disclosure. Falls back gracefully when
    // the detail isn't kv-shaped (free-form text passes through).
    var humanized: UserDisplayFormatters.HumanizedReceipt {
        UserDisplayFormatters.humanizeReceipt(
            name: name,
            detail: detail ?? output,
            fallbackTitle: actionId ?? phaseId ?? "Receipt"
        )
    }
}

extension ImprovementGauntletRun {
    /// The manual Swift-native promotion gauntlet: a validated checkout's
    /// build and smoke sweep plus the installed app's signature, recorded in
    /// the improvements/gauntlet/runs.json contract the gauntlet panel reads.
    /// A check this Mac cannot run is reported unavailable, never passed.
    static func run(dataRoot: URL) async throws -> ImprovementGauntletRun {
        // Swift-only manual gauntlet. This keeps the existing
        // improvements/gauntlet/runs.json contract that getImprovementGauntlet()
        // reads, but executes the "swift" promotion class checks locally instead
        // of routing through the retired daemon endpoint.
        let startedAt = Date()
        let repoRoot = PersistenceCore.resolveSandboxRepoRoot(dataRoot: dataRoot)
        let appPath = Bundle.main.bundleURL
        var checks: [GauntletCheck] = []
        var unavailableIDs: Set<String> = []
        func unavailable(_ id: String, _ title: String, _ detail: String) {
            unavailableIDs.insert(id)
            checks.append(GauntletCheck(
                id: id, title: "\(title) (unavailable)", passed: false, detail: detail
            ))
        }

        if let repoRoot {
            checks.append(try await runGauntletProcessCheck(
                id: "swift_build",
                title: "Swift package builds",
                executable: "/usr/bin/swift",
                arguments: ["build"],
                currentDirectory: repoRoot,
                timeout: 180
            ))
            let smokeScript = repoRoot.appendingPathComponent("script/smoke_all.sh")
            if FileManager.default.fileExists(atPath: smokeScript.path) {
                checks.append(try await runGauntletProcessCheck(
                    id: "isolated_smoke",
                    title: "Native smoke sweep passes",
                    executable: "/bin/zsh",
                    arguments: [smokeScript.path],
                    currentDirectory: repoRoot,
                    timeout: 240
                ))
            } else {
                unavailable("isolated_smoke", "Native smoke sweep passes", "The checkout has no smoke check script.")
            }
        } else {
            unavailable("swift_build", "Swift package builds", "No validated NativeAgent checkout is available.")
            unavailable("isolated_smoke", "Native smoke sweep passes", "No validated NativeAgent checkout is available.")
        }
        if appPath.pathExtension == "app" {
            checks.append(try await runGauntletProcessCheck(
                id: "app_verify",
                title: "Installed app verifies",
                executable: "/usr/bin/codesign",
                arguments: ["--verify", "--deep", "--strict", appPath.path],
                currentDirectory: appPath.deletingLastPathComponent(),
                timeout: 60
            ))
        } else {
            unavailable("app_verify", "Installed app verifies", "This process is not running from an app bundle.")
        }

        let failed = checks.contains { !$0.passed && !unavailableIDs.contains($0.id) }
        let run = ImprovementGauntletRun(
            id: "gauntlet-\(UUID().uuidString.lowercased())",
            objective: "Manual Swift-native promotion gauntlet",
            promotionClass: "swift",
            status: failed ? "failed" : (unavailableIDs.isEmpty ? "passed" : "unavailable"),
            dryRun: false,
            checks: checks,
            createdAt: ISO8601DateFormatter().string(from: startedAt)
        )
        try await persistImprovementGauntletRun(run, dataRoot: dataRoot)
        return run
    }

    private static func runGauntletProcessCheck(
        id: String,
        title: String,
        executable: String,
        arguments: [String],
        currentDirectory: URL,
        timeout: TimeInterval
    ) async throws -> GauntletCheck {
        let result = try await SystemProcessAdapter.runBounded(
            executable: executable,
            arguments: arguments,
            currentDirectory: currentDirectory,
            timeout: timeout
        )
        return GauntletCheck(
            id: id,
            title: title,
            passed: result.status == 0,
            detail: SystemGitActions.processDetail(result)
        )
    }

    private static func persistImprovementGauntletRun(
        _ run: ImprovementGauntletRun,
        dataRoot: URL
    ) async throws {
        let data = try JSONEncoder().encode(run)
        let row = try JSONValue.parse(data)
        let path = dataRoot
            .appendingPathComponent("improvements", isDirectory: true)
            .appendingPathComponent("gauntlet", isDirectory: true)
            .appendingPathComponent("runs.json")
        try await NativeRegistryEvaluation.appendBoundedRun(row, to: path)
    }
}
