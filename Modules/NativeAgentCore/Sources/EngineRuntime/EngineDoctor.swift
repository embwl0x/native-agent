import Foundation
import NativeAgentCore
import Observation
import BackgroundLoops
import BackgroundWork
import DoctorChecks
import NativeAgentShared
import TrustCenter
import PersistenceCore
import AppToolRuntime
import ToolRegistry
import SystemOps
import Cognition
// Blueprint: | `EngineDoctor.swift` | DoctorFacade owns report evidence, loop verdicts and DoctorPlainCopy summary/issue rows; rooted weekly digest/error, activity, hardening/exports, gauntlet, health card, liveness, watchdog and live report refresh publish through LatestRead; completed reports and committed exports use write. RuntimeHealth is liveness metadata; lifecycle facts remain manager-owned; run history belongs to engine.runs. |

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

        /// Onboarding's offline subset: every `live.*` row is excluded,
        /// including app-owned memory/cognition and optional integrations.
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

    public private(set) var activityEvents: [ActivityEvent] = []
    public private(set) var activityRefresh: PanelRefreshStatus?
    public private(set) var productionHardening: ProductionHardeningSummary?
    public private(set) var productionExports: [ProductionExport] = []
    public private(set) var improvementGauntletStatus: ImprovementGauntletStatus?
    public private(set) var hardeningRefresh: PanelRefreshStatus?
    @ObservationIgnored private let activityRead = LatestRead()
    @ObservationIgnored private let hardeningRead = LatestRead()

    /// The last Doctor report, as of the last run or live-row refresh.
    public var report: DoctorReport?
    @ObservationIgnored public let reportRead = LatestRead()
    /// A run is in flight: the Run button, the pill and Support Snapshot wait.
    public var isRunning = false
    public var runStartedAt: Date?
    /// When the run that produced `report` completed. It stays through the
    /// next run, so a page read mid-run names the report it shows (Support
    /// Snapshot is refused while `isRunning`), and clears if that run fails.
    public var reportCompletedAt: Date?
    /// Runtime liveness metadata, as of the last probe.
    public var health: RuntimeHealth?
    @ObservationIgnored private let healthRead = LatestRead()

    @discardableResult
    public func refreshHealth() async -> RuntimeHealth {
        await healthRead.read({ readHealth() }, publish: { health = $0 })
    }
    /// The background-loop watchdog, as of the last read.
    public var watchdog: WatchdogStatus?
    /// The health pill's card, as of the last read.
    public var healthCard: HealthCard?
    @ObservationIgnored public let healthCardRead = LatestRead()
    @ObservationIgnored private let watchdogRead = LatestRead()

    @discardableResult
    public func refreshWatchdog(manager: BackgroundLoopsManager = .shared) async -> WatchdogStatus {
        await watchdogRead.read({ await readWatchdog(manager: manager) }, publish: { watchdog = $0 })
    }
    /// The verdicts from the same evidence as the report's background-loop row.
    public var loopVerdicts: [LoopHealthVerdict] = []

    public func refreshActivity() async throws {
        let result: Result<[ActivityEvent], Error> = await activityRead.read({
            do { return .success(try await RuntimeReadProjection.getActivity(root: dataRoot)) }
            catch { return .failure(error) }
        }, publish: { result in
            switch result {
            case .success(let events):
                activityEvents = events
                activityRefresh = PanelRefreshStatus(lastAttemptAt: Date(), lastSuccessAt: Date(), failedEndpoints: [])
            case .failure:
                activityRefresh = PanelRefreshStatus(lastAttemptAt: Date(), lastSuccessAt: activityRefresh?.lastSuccessAt, failedEndpoints: ["activity"])
            }
        })
        _ = try result.get()
    }

    public func recordProductionExports(_ verified: [ProductionExport]) {
        hardeningRead.write { productionExports = verified }
    }

    public func refreshHardening() async -> [(endpoint: String, label: String, error: Error)] {
        let read = await hardeningRead.read({
            var hardening: ProductionHardeningSummary?
            var exports: [ProductionExport]?
            var gauntlet: ImprovementGauntletStatus?
            var failures: [(endpoint: String, label: String, error: Error)] = []
            do { hardening = try await DoctorStatusProjection.getProductionHardening(dataRoot: dataRoot) }
            catch { failures.append(("production hardening", "getProductionHardening", error)) }
            do { exports = try await ProductionExport.list(dataRoot: dataRoot) }
            catch { failures.append(("production exports", "getProductionExports", error)) }
            do { gauntlet = try await RuntimeReadProjection.swiftImprovementGauntlet(dataRoot: dataRoot) }
            catch { failures.append(("improvement gauntlet", "getImprovementGauntlet", error)) }
            return (hardening, exports, gauntlet, failures)
        }, publish: { read in
            if let value = read.0 { productionHardening = value }
            if let value = read.1 { productionExports = value }
            if let value = read.2 { improvementGauntletStatus = value }
            hardeningRefresh = PanelRefreshStatus(lastAttemptAt: Date(),
                lastSuccessAt: read.3.isEmpty ? Date() : hardeningRefresh?.lastSuccessAt, failedEndpoints: read.3.map { $0.endpoint })
        })
        return read.3
    }

    public private(set) var weeklyDigest: (text: String, date: String)?
    public private(set) var weeklyDigestError: String?
    @ObservationIgnored private let weeklyDigestRead = LatestRead()

    public func observeWeeklyDigest() async {
        await EventDeadlinePhysiology.refreshOnChanges(paths: [
            dataRoot.appendingPathComponent("self_improvement/digests", isDirectory: true)
        ]) {
            _ = await self.weeklyDigestRead.read { () async -> Result<(text: String, date: String)?, Error> in
            do {
                let dir = self.dataRoot.appendingPathComponent("self_improvement/digests", isDirectory: true)
                let digest = try await Task.detached(priority: .utility) { () throws -> (text: String, date: String)? in
                    let files: [URL]
                    do { files = try FileManager.default.contentsOfDirectory(
                        at: dir, includingPropertiesForKeys: [.contentModificationDateKey]) }
                    catch CocoaError.fileReadNoSuchFile { return nil }
                    let dated = try files.filter { $0.pathExtension == "md" }.map { url in
                        (url: url, modified: try url.resourceValues(forKeys: [.contentModificationDateKey])
                            .contentModificationDate ?? .distantPast)
                    }
                    guard let latest = dated.max(by: { $0.modified < $1.modified })?.url else { return nil }
                    return (try String(contentsOf: latest, encoding: .utf8), latest.deletingPathExtension().lastPathComponent)
                }.value
                return Result<(text: String, date: String)?, Error>.success(digest)
            } catch {
                return .failure(error)
            }
            } publish: { result in
                switch result {
                case .success(let digest): self.weeklyDigest = digest; self.weeklyDigestError = nil
                case .failure(let error): self.weeklyDigestError = UserFacingError.message(error, action: "read latest digest")
                }
            }
        }
    }

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
        reportRead.write {
        if let finished { report = finished }
        reportCompletedAt = finished == nil ? nil : Date()
        }
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

    /// Lazily initialized by the first health read, not stamped at process launch.
    private nonisolated static let firstHealthReadAt = Date()

    /// `ok` means this in-process read answered, not that Doctor passed.
    /// `uptimeSeconds` measures elapsed time since the first health read.
    public nonisolated func readHealth() -> RuntimeHealth {
        RuntimeHealth(
            ok: true,
            app: "NativeAgent",
            version: Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "dev",
            dataDir: dataRoot.path,
            uptimeSeconds: Date().timeIntervalSince(Self.firstHealthReadAt)
        )
    }

    public nonisolated func readWatchdog(manager backgroundLoopsManager: BackgroundLoopsManager = .shared) async -> WatchdogStatus {
        let loopStatuses = await backgroundLoopsManager.status()
        let running = await backgroundLoopsManager.isRunning()
        let uptime = await backgroundLoopsManager.uptimeSeconds()
        let loopHealth = DoctorLoopHealth.doctorCheck(
            observations: loopStatuses,
            recentFailureDates: DoctorLoopHealth.recentFailureDates(
                receiptsFile: dataRoot.appendingPathComponent("logs/background_loop_failures.jsonl")),
            now: Date())
        let adverse = DoctorSafeRepairPolicy.isAdverse(loopHealth.status)
        let lifecycleStatus = running ? (adverse ? "degraded" : loopHealth.status) : "stopped"
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
                ? (loopHealth.status == "ok" ? "Swift background loops are running in NativeAgent.app." : loopHealth.detail)
                : "Swift background loops are not running.",
            runningImprovements: loopStatuses.filter { $0.executing && $0.name == "self_improvement_sweep" }.count,
            runningExecutions: loopStatuses.filter { $0.executing && ["mission_executor", "workshop_pump"].contains($0.name) }.count,
            lastActivity: lastActivity,
            repairAvailable: loopStatuses.contains { $0.lastError != nil },
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
        case "off", "not needed": return runtimeLifecycleStatus
        case "unmeasured": return "info"
        default: return "error"
        }
    }
}

extension DoctorFacade {
    public struct RuntimeStatus: Equatable, Sendable {
        public enum Tone: Sendable { case neutral, success, warning, failure }
        public let text: String
        public let detail: String?
        public let tone: Tone
        public let systemImage: String
    }

    /// Runtime liveness is independent of the most recent operation's feedback.
    public func runtimeStatus(lastRefreshError: String?) -> RuntimeStatus {
        let hasError = !(lastRefreshError?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ?? true)
        let detail = hasError ? "Some sections didn't refresh. The details are in the log." : nil
        switch health?.ok {
        case true:
            return RuntimeStatus(text: hasError ? "App is online; some app data is unavailable" : "App is online",
                detail: detail, tone: hasError ? .warning : .success,
                systemImage: hasError ? "exclamationmark.triangle.fill" : "checkmark.circle.fill")
        case false:
            return RuntimeStatus(text: "App reported a problem", detail: detail,
                tone: .failure, systemImage: "xmark.octagon.fill")
        case nil:
            return RuntimeStatus(text: hasError ? "App status is unavailable" : "App status has not been checked",
                detail: detail, tone: hasError ? .failure : .neutral,
                systemImage: hasError ? "xmark.octagon.fill" : "questionmark.circle")
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
    public var systemHealth: (summary: SystemHealthSummary,
        issues: [(id: String, title: String, detail: String, repairAvailable: Bool)]) {
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
        let rows = report.map { $0.checks.map { ($0.id, $0.title, $0.status, $0.repairFace, $0.repair_available == true) } }
            ?? (healthCard?.subsystems ?? []).map { ($0.id, $0.label, $0.status, $0.detail, false) }
        return (summarize(rows.map(\.2)), rows.filter {
            ["warning", "failing"].contains(DoctorPlainCopy.bucket(for: $0.2))
        }.map { ($0.0, $0.1, $0.3, $0.4) })
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
