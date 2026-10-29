import Foundation
import NativeAgentCore
import PersistenceCore
// Blueprint: | `ImprovementGauntletReadModels.swift` | `ImprovementGauntletRun` is the stored run schema, typed history reader and manual check runner; `GauntletCheck` |

public struct ImprovementGauntletRun: Identifiable, Codable, Hashable, Sendable {
    public var id: String
    public var objective: String?
    public var promotionClass: String?
    public var status: String
    public var dryRun: Bool?
    public var checks: [GauntletCheck]?
    public var createdAt: String?
    public init(id: String, objective: String? = nil, promotionClass: String? = nil, status: String, dryRun: Bool? = nil, checks: [GauntletCheck]? = nil, createdAt: String? = nil) {
        self.id = id
        self.objective = objective
        self.promotionClass = promotionClass
        self.status = status
        self.dryRun = dryRun
        self.checks = checks
        self.createdAt = createdAt
    }
}

public struct GauntletCheck: Identifiable, Codable, Hashable, Sendable {
    public var id: String
    public var title: String
    public var passed: Bool
    public var detail: String?
    public init(id: String, title: String, passed: Bool, detail: String? = nil) {
        self.id = id
        self.title = title
        self.passed = passed
        self.detail = detail
    }
}

extension ImprovementGauntletRun {
    static func readHistory(dataRoot: URL) async throws -> [ImprovementGauntletRun] {
        try await Task.detached(priority: .utility) {
            let path = dataRoot.appendingPathComponent("improvements/gauntlet/runs.json")
            let data: Data
            do { data = try Data(contentsOf: path) }
            catch CocoaError.fileReadNoSuchFile { return [] }
            return try JSONDecoder().decode([ImprovementGauntletRun].self, from: data)
        }.value
    }

    /// The manual Swift-native promotion gauntlet: a validated checkout's
    /// static checks and installed runtime proof plus its signature, recorded in
    /// the improvements/gauntlet/runs.json contract the gauntlet panel reads.
    /// A check this Mac cannot run is reported unavailable, never passed.
    public static func run(
        dataRoot: URL,
        runProcess: (String, [String], URL, TimeInterval) async throws -> (status: Int32, detail: String),
        appendBoundedRun: (JSONValue, URL) async throws -> Void
    ) async throws -> ImprovementGauntletRun {
        func runGauntletProcessCheck(
            id: String,
            title: String,
            executable: String,
            arguments: [String],
            currentDirectory: URL,
            timeout: TimeInterval
        ) async throws -> GauntletCheck {
            let result = try await runProcess(executable, arguments, currentDirectory, timeout)
            return GauntletCheck(
                id: id,
                title: title,
                passed: result.status == 0,
                detail: result.detail
            )
        }
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
            let smokeScript = repoRoot.appendingPathComponent("script/smoke_all.sh")
            if FileManager.default.fileExists(atPath: smokeScript.path) {
                checks.append(try await runGauntletProcessCheck(
                    id: "isolated_smoke",
                    title: "Static checks and installed runtime pass",
                    executable: "/usr/bin/env",
                    arguments: ["NATIVE_AGENT_INSTALLED_APP=\(appPath.path)", "/bin/bash", smokeScript.path, "--live"],
                    currentDirectory: repoRoot,
                    timeout: 240
                ))
            } else {
                unavailable("isolated_smoke", "Static checks and installed runtime pass", "The checkout has no smoke check script.")
            }
        } else {
            unavailable("isolated_smoke", "Static checks and installed runtime pass", "No validated NativeAgent checkout is available.")
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
        let row = try JSONValue.parse(JSONEncoder().encode(run))
        let path = dataRoot
            .appendingPathComponent("improvements", isDirectory: true)
            .appendingPathComponent("gauntlet", isDirectory: true)
            .appendingPathComponent("runs.json")
        try await appendBoundedRun(row, path)
        return run
    }

}
