import Foundation
import Observation
import BackgroundLoops
import DoctorChecks
import NativeAgentShared
import TrustCenter
import PersistenceCore
import AppToolRuntime
import ToolRegistry

/// `NativeAgentEngine.doctor` (S10): Doctor, this runtime's health and the
/// background-loop watchdog for one data root, in core types. Diagnostics,
/// Status, the health pill, the menu line, Setup and Support Snapshot render
/// this state; the health read is nonisolated so the phone lane uses the same
/// owner. `EngineDoctorRuntime` interprets live owners and selects repairs;
/// the app's Doctor port supplies platform observations and callbacks.
@MainActor
@Observable
public final class DoctorFacade {
    /// What a Doctor run actually produced.
    ///
    /// gpt-5.5 review BLOCKING 2 (2026-08-02): `runDoctor` used to return a Bool
    /// that meant "a report came back", and onboarding read it as "the repair
    /// worked". A repair that ran to completion over a store it could NOT fix
    /// returned `true`, so the wizard showed "<Agent> is ready" over a broken
    /// scaffold. The two questions are now distinct on the type.
    public enum RunOutcome: Equatable {
        /// No report: another run held the lock, or the run threw.
        case unavailable(String)
        /// A report came back. `failingChecks` are its `status == fail|error`
        /// rows — the run completing says nothing about them.
        case completed(status: String, failingChecks: [CheckResult])

        /// True when the run produced a report at all. This is the old Bool's
        /// meaning; callers that only wanted "did it run" keep using it.
        public var didRun: Bool {
            if case .completed = self { return true }
            return false
        }

        /// Failing rows outside the `live.*` namespace, which covers optional
        /// user-configured subsystems (Telegram token, SearXNG URL). Those are
        /// real Doctor findings but they are NOT the app-owned scaffold, and
        /// blocking onboarding on them would strand a user who skipped setup.
        public var failingScaffoldChecks: [CheckResult] {
            guard case .completed(_, let failing) = self else { return [] }
            return failing.filter { !$0.checkID.hasPrefix("live.") }
        }

        /// One line naming what to fix, for a user-facing surface.
        public var failureDetail: String {
            switch self {
            case .unavailable(let reason):
                return reason
            case .completed:
                let failing = failingScaffoldChecks
                guard !failing.isEmpty else { return "Health checks reported a failure with no failing check." }
                return failing.map { "\($0.title): \($0.detail)" }.joined(separator: " ")
            }
        }
    }

    public nonisolated let dataRoot: URL

    /// The last Doctor report, as of the last run or live-row refresh.
    public var report: DoctorReport?
    /// A run is in flight: the Run button, the pill and Support Snapshot wait.
    public var isRunning = false
    public var runStartedAt: Date?
    /// When the run that produced `report` completed. It stays through the
    /// next run, so a page read mid-run names the report it shows (Support
    /// Snapshot is refused while `isRunning`), and clears if that run fails.
    public var reportCompletedAt: Date?
    /// This runtime's health, as of the last probe.
    public var health: RuntimeHealth?
    /// The background-loop watchdog, as of the last read.
    public var watchdog: WatchdogStatus?
    /// The health pill's card, as of the last read.
    public var healthCard: HealthCard?

    public nonisolated init(dataRoot: URL) {
        self.dataRoot = dataRoot
    }

    /// Admission for every Doctor run on this root — Run, Repair, onboarding
    /// and the automatic passes — so two never overlap and a click during a
    /// pass is told so.
    public func admitRun() -> Bool {
        guard !isRunning else { return false }
        isRunning = true
        runStartedAt = Date()
        return true
    }

    /// Completion: the report a finished run produced lands with its stamp;
    /// a run that threw or was cancelled leaves the last report standing but
    /// clears its stamp, so nothing (Support Snapshot's reuse) takes that
    /// rollup as current after a newer run failed to confirm it.
    public func finishRun(_ finished: DoctorReport?) {
        if let finished { report = finished }
        reportCompletedAt = finished == nil ? nil : Date()
        isRunning = false
        runStartedAt = nil
    }

    public func toolStatusEnvelope() async throws -> JSONValue {
        guard let report else {
            return AppToolExecutor.failure(isRunning ? "doctor_running" : "doctor_not_run", isRunning
                ? "A Doctor run is in progress and this launch has no report yet; read this page again when it finishes."
                : "No Doctor report yet. Run doctor.run, then read this page.")
        }
        return try await AppToolExecutor.doctorStatus(report: report, completedAt: reportCompletedAt,
                                                      runningSince: runStartedAt) { dataRoot in
            try await ProvidersFacade(dataRoot: dataRoot).list().map {
                AppToolProviderHealth(providerID: $0.provider_id, authState: $0.auth_status.state,
                                      eligible: $0.auth_status.eligible)
            }
        }
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
            uptimeSeconds: uptime,
            runtimeLifecycleStatus: lifecycleStatus,
            runtimeLifecycleDetail: running
                ? (failedLoops.isEmpty
                    ? "Swift background loops are running in NativeAgent.app."
                    : "Swift background loops are running with \(failedLoops.count) loop failure(s): \(failedLoops.map(\.name).sorted().joined(separator: ", ")).")
                : "Swift background loops are not running.",
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
    public var runtimeBadgeStatus: String {
        switch runtimeLifecycleStatus {
        case "ok": return "ok"
        case "stopped", "degraded": return "warn"
        default: return "error"
        }
    }
}

public enum SystemHealthSummary: Sendable, Equatable {
    case unknown
    case ok
    case warn(count: Int)
    case error(count: Int)
}

extension DoctorFacade {
    public var systemHealthSummary: SystemHealthSummary {
        // Prefer an explicit Doctor run. Otherwise reuse the health card that
        // Chat already keeps current instead of launching a second full Doctor
        // pass from this always-mounted toolbar control.
        func summarize(_ statuses: [String]) -> SystemHealthSummary {
            let buckets = statuses.map { DoctorPlainCopy.bucket(for: $0) }
            let failCount = buckets.filter { $0 == "failing" }.count
            let warnCount = buckets.filter { $0 == "warning" }.count
            if failCount > 0 { return .error(count: failCount) }
            if warnCount > 0 { return .warn(count: warnCount) }
            if buckets.isEmpty || buckets.contains("unclear") { return .unknown }
            return .ok
        }
        if let checks = report?.checks {
            return summarize(checks.map(\.status))
        }
        guard let subsystems = healthCard?.subsystems else { return .unknown }
        return summarize(subsystems.map(\.status))
    }
}

extension DoctorFacade {
    public nonisolated static func repairCompletionMessage(report: DoctorReport) -> String {
        let remaining = report.checks.filter { DoctorSafeRepairPolicy.isAdverse($0.status) }.count
        if report.repaired {
            return remaining == 0
                ? "Repair applied safe fixes."
                : "Repair applied safe fixes, but \(remaining) issue\(remaining == 1 ? " remains" : "s remain")."
        }
        return remaining == 0
            ? "Repair finished; no changes were needed."
            : "Repair finished, but no safe fixes were applied."
    }
}
