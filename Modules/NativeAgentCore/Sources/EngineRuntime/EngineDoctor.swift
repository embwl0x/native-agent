import Foundation
import Observation
import BackgroundLoops
import DoctorChecks
import NativeAgentShared
import TrustCenter
import PersistenceCore

/// `NativeAgentEngine.doctor` (S10): Doctor, this runtime's health and the
/// background-loop watchdog for one data root, in core types. Diagnostics,
/// Status, the health pill, the menu line, Setup and Support Snapshot render
/// this state; the health read is nonisolated so the phone lane uses the same
/// owner. Checks still run through the Doctor executors on `NativeClient`
/// (`runDoctor`, `liveDoctorCoverageChecks`, `getHealthCard`).
@MainActor
@Observable
public final class DoctorFacade {
    public nonisolated let dataRoot: URL

    /// The last Doctor report, as of the last run or live-row refresh.
    public var report: DoctorReport?
    /// A run is in flight: the Run button, the pill and Support Snapshot wait.
    public var isRunning = false
    public var runStartedAt: Date?
    /// When the last full run completed. Cleared for the whole of a run, so
    /// Support Snapshot never reuses a report from before one.
    public var reportCompletedAt: Date?
    /// This runtime's health, as of the last probe.
    public var health: RuntimeHealth?
    /// The LAST health probe's own outcome, not the row it fell back to. A
    /// failed read leaves `health` on its cached row, so anything that says
    /// "online" has to ask this first.
    public var healthProbeFailed = false
    /// The background-loop watchdog, as of the last read.
    public var watchdog: WatchdogStatus?
    /// The health pill's card, as of the last read.
    public var healthCard: HealthCard?

    public nonisolated init(dataRoot: URL) {
        self.dataRoot = dataRoot
    }

    /// When THIS runtime started. `ProcessInfo.systemUptime` measures the
    /// machine, which made Status report days of "uptime" for an app launched
    /// a minute ago.
    public nonisolated static let processStartedAt = Date()

    /// This runtime's health. The Mac process IS the runtime, so this is its
    /// own state: version, data root and how long it has been up.
    public nonisolated func readHealth() -> RuntimeHealth {
        RuntimeHealth(
            ok: true,
            app: "NativeAgent",
            version: Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "dev",
            dataDir: dataRoot.path,
            uptimeSeconds: Date().timeIntervalSince(Self.processStartedAt)
        )
    }

    public nonisolated func readWatchdog(manager backgroundLoopsManager: BackgroundLoopsManager = .shared) async -> WatchdogStatus {
        let loopStatuses = await backgroundLoopsManager.status()
        let running = await backgroundLoopsManager.isRunning()
        let uptime = await backgroundLoopsManager.uptimeSeconds()
        let failedLoops = loopStatuses.filter { $0.lastError != nil }
        let lifecycleStatus = running ? (failedLoops.isEmpty ? "ok" : "degraded") : "stopped"
        let newestRun = loopStatuses.compactMap(\.lastRun).max()
        let lastActivity: JSONValue? = newestRun.map { lastRun in
            .object([
                "id": .string("background-loops-watchdog-\(Int64(lastRun.timeIntervalSince1970))"),
                "kind": .string("background_loops"),
                "title": .string("Swift background loop tick"),
                "detail": .string("Latest registered loop tick."),
                "status": .string(lifecycleStatus),
                "createdAt": .string(SwiftNativeManifestSigner.isoTimestamp(lastRun)),
            ])
        }
        let loops: JSONValue = .array(loopStatuses.sorted { $0.name < $1.name }.map { loop in
            .object([
                "name": .string(loop.name),
                "lastRunAt": loop.lastRun.map { .string(SwiftNativeManifestSigner.isoTimestamp($0)) } ?? .null,
                "nextRunAt": loop.nextRun.map { .string(SwiftNativeManifestSigner.isoTimestamp($0)) } ?? .null,
                "runCount": .int(Int64(loop.runCount)),
                "lastError": loop.lastError.map { .string($0) } ?? .null,
                "running": .bool(loop.running),
                "executing": .bool(loop.executing),
            ])
        })
        return WatchdogStatus(
            daemon: "swift",
            uptimeSeconds: uptime,
            daemonLifecycleStatus: lifecycleStatus,
            daemonLifecycleDetail: running
                ? (failedLoops.isEmpty
                    ? "Swift background loops are running in NativeAgent.app."
                    : "Swift background loops are running with \(failedLoops.count) loop failure(s): \(failedLoops.map(\.name).sorted().joined(separator: ", ")).")
                : "Swift background loops are not running.",
            launchAgentStatus: "not_applicable",
            launchAgentDetail: "NativeAgent.app owns background loops; legacy daemon launch agents are retired.",
            runningImprovements: loopStatuses.filter { $0.executing && $0.name == "self_improvement_sweep" }.count,
            runningExecutions: loopStatuses.filter { $0.executing && ["mission_executor", "workshop_pump"].contains($0.name) }.count,
            lastActivity: lastActivity,
            repairAvailable: !failedLoops.isEmpty,
            extras: .object([
                "backend": .string("swift"),
                "source": .string("app_background_loops_manager"),
                "loopCount": .int(Int64(loopStatuses.count)),
                "running": .bool(running),
                "loops": loops,
            ])
        )
    }
}

/// One Doctor pass: the worst-row rollup, whether a safe repair applied, and
/// every row — core offline checks followed by the app's live-owner rows.
public struct DoctorReport: Equatable, Sendable {
    public var status: String
    public var repaired: Bool
    public var checks: [CheckResult]
    public init(status: String, repaired: Bool, checks: [CheckResult]) {
        self.status = status
        self.repaired = repaired
        self.checks = checks
    }

}

extension WatchdogStatus {
    public var runtimeBadgeText: String {
        let trimmed = (daemon ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? "RUNTIME" : trimmed.uppercased()
    }

    public var runtimeBadgeStatus: String {
        switch runtimeLifecycleStatus.lowercased() {
        case "ok", "running", "active": return "ok"
        case "stopped", "warn", "warning", "degraded": return "warn"
        case "fail", "failed", "error": return "error"
        default:
            let daemon = daemon ?? ""
            return daemon.lowercased() == "swift" ? "ok" : (daemon.isEmpty ? "unknown" : daemon)
        }
    }

    public var runtimeLifecycleStatus: String {
        let lifecycle = (daemonLifecycleStatus ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        if !lifecycle.isEmpty { return lifecycle }
        if daemon?.lowercased() == "swift", launchAgentStatus == "not_applicable" {
            return "ok"
        }
        return launchAgentStatus ?? ""
    }

    public var runtimeLifecycleDetail: String {
        let lifecycle = (daemonLifecycleDetail ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        if !lifecycle.isEmpty { return lifecycle }
        if daemon?.lowercased() == "swift", launchAgentStatus == "not_applicable" {
            return "Swift runtime is owned by NativeAgent.app."
        }
        return launchAgentDetail ?? ""
    }
}
