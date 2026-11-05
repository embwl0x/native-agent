import ChatTurnContracts
import ChatToolRuntime
import Privacy
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
import ProviderRouting
// Blueprint: | `EngineDoctor.swift` | Shared report availability, route health, liveness and checked publication |

/// Share one root’s health state across surfaces, including nonisolated phone reads; native ports observe while `EngineDoctorRuntime` interprets and
/// admits repairs.
@MainActor
@Observable
public final class DoctorFacade {
    /// A completed Doctor run produces a report, not proof that repairs succeeded.
    public enum RunOutcome: Equatable {
        /// No report may mean held admission or a thrown run; it does not prove health.
        case unavailable(String)
        /// Run completion does not mean its `fail` or `error` rows passed.
        case completed(status: String, failingChecks: [CheckResult])

        public var didRun: Bool {
            if case .completed = self { return true }
            return false
        }

        /// Exclude every `live.*` row from offline onboarding, including app-owned state and optional integrations.
        public var failingScaffoldChecks: [CheckResult] {
            guard case .completed(_, let failing) = self else { return [] }
            return failing.filter { !$0.checkID.hasPrefix("live.") }
        }

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

    @ObservationIgnored var diagnosticsDidChange: (@MainActor () -> Void)?
    @ObservationIgnored var faceAction: (@MainActor (String, String?) async throws -> String?)?

    public private(set) var activityEvents: [ActivityEvent] = []
    public private(set) var activityRefresh: PanelRefreshStatus?
    public private(set) var productionHardening: ProductionHardeningSummary?
    public private(set) var productionExports: [ProductionExport] = []
    public private(set) var latestImprovementGauntletRun: ImprovementGauntletRun?
    public private(set) var improvementGauntletRunCount = 0
    public private(set) var hardeningRefresh: PanelRefreshStatus?
    public internal(set) var improvementRunStartedAt: Date?
    public internal(set) var improvementRunError: String?
    public internal(set) var productionExportWork: (support: Bool, startedAt: Date)?
    public internal(set) var productionExportFailure: (support: Bool, detail: String)?
    @ObservationIgnored var capabilitiesDidChange: (@MainActor @Sendable () async -> Void)?
    @ObservationIgnored private let activityRead = LatestRead()
    @ObservationIgnored private let hardeningRead = LatestRead()

    public var report: DoctorReport? { didSet { diagnosticsDidChange?() } }
    @ObservationIgnored public let reportRead = LatestRead()
    /// Surfaces must wait while a run is in flight.
    public var isRunning = false
    public var runStartedAt: Date?
    /// Retain the displayed report’s completion stamp during a new run; clear it on failure so stale evidence cannot appear current.
    public var reportCompletedAt: Date?
    /// A failed full run remains unavailable through partial live-row refreshes.
    public private(set) var latestRunFailure: String?
    public var reportAvailabilityIssue: String? {
        if isRunning { return "A Doctor run is in progress; retained checks are not current until it finishes." }
        return latestRunFailure
    }
    public var health: RuntimeHealth?
    @ObservationIgnored private let healthRead = LatestRead()

    @discardableResult
    public func refreshHealth() async -> RuntimeHealth {
        await healthRead.read({ readHealth() }, publish: { health = $0; diagnosticsDidChange?() })
    }
    public var watchdog: WatchdogStatus?
    public var healthCard: HealthCard?
    @ObservationIgnored public let healthCardRead = LatestRead()
    @ObservationIgnored private let watchdogRead = LatestRead()

    @discardableResult
    public func refreshWatchdog(manager: BackgroundLoopLifetimes = .shared) async -> WatchdogStatus {
        await watchdogRead.read({ await readWatchdog(manager: manager) }, publish: { watchdog = $0; diagnosticsDidChange?() })
    }
    /// Derive verdicts from the report’s same background-loop evidence.
    public var loopVerdicts: [LoopHealthVerdict] = [] { didSet { diagnosticsDidChange?() } }

    public func refreshActivity() async throws {
        let result: Result<[ActivityEvent], Error> = await activityRead.read({
            do { return .success(try await RuntimeReadouts.getActivity(root: dataRoot)) }
            catch { return .failure(error) }
        }, publish: { result in
            switch result {
            case .success(let events):
                activityEvents = events
                activityRefresh = PanelRefreshStatus(lastAttemptAt: Date(), lastSuccessAt: Date(), failedEndpoints: [])
            case .failure:
                activityRefresh = PanelRefreshStatus(lastAttemptAt: Date(), lastSuccessAt: activityRefresh?.lastSuccessAt, failedEndpoints: ["activity"])
            }
            diagnosticsDidChange?()
        })
        _ = try result.get()
    }

    public func recordProductionExports(_ verified: [ProductionExport]) async {
        hardeningRead.write { productionExports = verified }
        await capabilitiesDidChange?()
    }

    public func refreshHardening() async -> [(endpoint: String, label: String, error: Error)] {
        let read = await hardeningRead.read({
            var hardening: ProductionHardeningSummary?
            var exports: [ProductionExport]?
            var gauntlet: [ImprovementGauntletRun]?
            var failures: [(endpoint: String, label: String, error: Error)] = []
            do { hardening = try await DoctorReadout.getProductionHardening(dataRoot: dataRoot) }
            catch { failures.append(("production hardening", "getProductionHardening", error)) }
            do { exports = try await ProductionExport.list(dataRoot: dataRoot) }
            catch { failures.append(("production exports", "getProductionExports", error)) }
            do { gauntlet = try await ImprovementGauntletRun.readHistory(dataRoot: dataRoot) }
            catch { failures.append(("improvement gauntlet", "getImprovementGauntlet", error)) }
            return (hardening, exports, gauntlet, failures)
        }, publish: { read in
            if let value = read.0 { productionHardening = value }
            if let value = read.1 { productionExports = value }
            if let runs = read.2 {
                latestImprovementGauntletRun = runs.last
                improvementGauntletRunCount = runs.count
            }
            hardeningRefresh = PanelRefreshStatus(lastAttemptAt: Date(),
                lastSuccessAt: read.3.isEmpty ? Date() : hardeningRefresh?.lastSuccessAt, failedEndpoints: read.3.map { $0.endpoint })
        })
        await capabilitiesDidChange?()
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

    /// All run sources share admission so overlapping runs cannot occur.
    public func admitRun() -> Bool {
        guard !isRunning else { return false }
        isRunning = true
        runStartedAt = Date()
        diagnosticsDidChange?()
        return true
    }

    /// A failed or cancelled run retains prior report rows but clears their stamp so Support Snapshot cannot reuse them as current.
    public func finishRun(_ finished: DoctorReport?, failure: String? = nil) {
        reportRead.write {
        if let finished { report = finished }
        reportCompletedAt = finished == nil ? nil : Date()
        latestRunFailure = finished == nil
            ? "The latest Doctor run did not complete. \(failure ?? "Run health checks again to obtain a current report.")"
            : nil
        }
        isRunning = false
        runStartedAt = nil
        diagnosticsDidChange?()
    }

    public func toolStatusEnvelope(turn: Turn) async throws -> JSONValue {
        guard let report else {
            if let latestRunFailure, !isRunning {
                return AppToolExecutor.failure("doctor_unavailable", latestRunFailure)
            }
            return AppToolExecutor.failure(isRunning ? "doctor_running" : "doctor_not_run", isRunning
                ? "A Doctor run is in progress and this launch has no report yet; read this page again when it finishes."
                : "No Doctor report yet. Run doctor.run, then read this page.")
        }
        let completedAt = reportCompletedAt
        let runningSince = runStartedAt
        let reportIssue = reportAvailabilityIssue
        let surface = turn.runtime?.surface ?? turn.envelope?.surface ?? "chat"
        let router = SwiftNativeProviderRouting(dataRoot: dataRoot)
        let activeProviderID: String?
        let activeProvider: ProviderInfo?
        let routeIssue: JSONValue?
        do {
            let snapshot = try await router.checkedProviderSnapshot()
            let providers = try ProvidersFacade.connections(from: snapshot)
            activeProviderID = turn.runtime?.providerID ?? turn.admission?.provider
                ?? ProviderRoutingSurfaceLookup.value(snapshot.routing.activeProviders, surface)
            activeProvider = activeProviderID.flatMap { providerID in
                providers.first(where: { $0.provider_id == providerID })
            }
            routeIssue = nil
        } catch {
            activeProviderID = nil
            activeProvider = nil
            routeIssue = .object([
                "status": .string("unavailable"),
                "source": .string(dataRoot.appendingPathComponent("providers").path),
                "surface": .string(surface),
                "detail": .string(NativeAppSecretRedactor.redactText(boundedDoctorDetail(error.localizedDescription))),
            ])
        }
        let executableRepairs = DoctorSafeRepairPolicy.executableCoreIDs(for: report.checks)
        let checks = report.checks.map { check in
            let repairAvailable = executableRepairs.contains(check.id)
                || (check.repair_available == true
                    && DoctorSafeRepairPolicy.isAdverse(check.status))
            var row: [String: JSONValue] = [
                "id": .string(check.id),
                "check_id": .string(check.checkID),
                "title": .string(check.title),
                "status": .string(check.status),
                "detail": .string(NativeAppSecretRedactor.redactText(boundedDoctorDetail(check.detail))),
                "repair_available": .bool(repairAvailable),
                "remedy": check.remedy ?? .null,
                "repair_face": .string(NativeAppSecretRedactor.redactText(check.repairFace)),
            ]
            if let harm = check.harm {
                row["harm"] = .string(NativeAppSecretRedactor.redactText(boundedDoctorDetail(harm)))
            }
            if check.remedy != nil {
                row["owner"] = check.repairOwner.map(JSONValue.string) ?? .null
            }
            if let action = check.recoveryAction() {
                row["human_action"] = .string(NativeAppSecretRedactor.redactText(boundedDoctorDetail(action)))
            }
            if let receipt = check.receipt?.trimmingCharacters(in: .whitespacesAndNewlines),
               !receipt.isEmpty {
                row["receipt"] = .string(NativeAppSecretRedactor.redactText(boundedDoctorDetail(receipt)))
            }
            return JSONValue.object(row)
        }
        // Only provider, memory, prompt and ingress-bridge faults block the chat path. Credential eligibility alone cannot prove a provider warning concerns
        // another account or working model.
        let pathIDs: Set<String> = ["live.providers", "live.memory", "prompt_prefix_health", "live.bridges"]
        let pathChecks = report.checks.filter { check in
            guard pathIDs.contains(check.checkID) else { return false }
            // Only credential-owner warnings name affected accounts; model and probe warnings remain on the path despite eligible credentials.
            if check.checkID == "live.providers", check.status.lowercased() == "warn",
               activeProvider?.auth_status.eligible == true, let activeProviderID,
               let source = check.source, source.hasPrefix("Providers accounts: ") {
                let accounts = source.dropFirst("Providers accounts: ".count)
                    .components(separatedBy: ", ").filter { !$0.isEmpty }
                if !accounts.isEmpty, !accounts.contains(activeProviderID) { return false }
            }
            return true
        }
        var envelope: [String: JSONValue] = [
            "status": .string(reportIssue == nil && routeIssue == nil ? report.status : "unavailable"),
            "report_status": .string(report.status),
            "report_availability": .string(reportIssue == nil ? "current" : runningSince != nil ? "running" : "unavailable"),
            "report_issue": reportIssue.map(JSONValue.string) ?? .null,
            "report_completed_at": completedAt.map { .string(NativeTimestampFormat.plainZulu($0)) } ?? .null,
            "active_path_status": .string(reportIssue == nil && routeIssue == nil
                ? DoctorReadout.doctorRollup(pathChecks.map(\.status)) : "unavailable"),
            "active_path_check_ids": .array(pathChecks.map { .string($0.id) }),
            "active_provider_id": activeProviderID.map(JSONValue.string) ?? .null,
            "active_provider_status": .string(routeIssue == nil ? activeProvider?.auth_status.state ?? "unknown" : "unavailable"),
            "current_route_issue": routeIssue ?? .null,
            "status_scope_note": .string("""
                status requires a completed latest run and readable current routing, then rolls up every check; report_status describes the retained \
                checks; active_path_status covers the checks a chat turn here depends on (active_path_check_ids). Off and not needed are non-fault \
                states; unmeasured and unknown checks cannot establish health.
                """),
            "repaired": .bool(report.repaired),
            "check_count": .int(Int64(checks.count)),
            "checks": .array(checks),
        ]
        if let runningSince {
            envelope["run_in_progress"] = .string("""
                A Doctor run started at \(NativeTimestampFormat.plainZulu(runningSince)) is in progress; this report is from before it and is not \
                current until it finishes.
                """)
        }
        if activeProvider?.auth_status.eligible == false, let activeProviderID {
            let target = InlineInteractionRegistry.canonicalProviderID(activeProviderID)
            envelope["next"] = .string("raise request_interaction kind=api_key target=\(target)")
        }
        return .object(envelope)
    }

    /// Prefer word boundaries and mark truncation within the detail budget.
    private func boundedDoctorDetail(_ detail: String, limit: Int = 600) -> String {
        guard detail.count > limit else { return detail }
        let ellipsis = "…"
        let head = detail.prefix(limit - ellipsis.count)
        // Use only a late word boundary so a long token cannot collapse the detail to a few words.
        if let boundary = head.lastIndex(where: { $0 == " " || $0.isNewline }),
           head.distance(from: head.startIndex, to: boundary) > head.count / 2 {
            let trimmed = head[..<boundary]
                .trimmingCharacters(in: .whitespacesAndNewlines)
            if !trimmed.isEmpty { return trimmed + ellipsis }
        }
        return String(head) + ellipsis
    }

    /// Begin liveness timing at the first health read, never process launch.
    private nonisolated static let firstHealthReadAt = Date()

    /// `ok` proves this read answered, not Doctor health; uptime starts at the first health read.
    public nonisolated func readHealth() -> RuntimeHealth {
        RuntimeHealth(
            ok: true,
            app: "NativeAgent",
            version: Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "dev",
            dataDir: dataRoot.path,
            uptimeSeconds: Date().timeIntervalSince(Self.firstHealthReadAt)
        )
    }

    public nonisolated func readWatchdog(manager backgroundLoopsManager: BackgroundLoopLifetimes = .shared) async -> WatchdogStatus {
        let loopStatuses = await backgroundLoopsManager.status()
        let running = await backgroundLoopsManager.isRunning()
        let uptime = await backgroundLoopsManager.uptimeSeconds()
        let loopHealth: CheckResult
        do {
            loopHealth = DoctorLoopHealth.doctorCheck(
                observations: loopStatuses,
                recentFailureDates: try await DoctorLoopHealth.recentFailureDates(dataRoot: dataRoot),
                now: Date())
        } catch {
            loopHealth = CheckResult(source: "Loop failure details",
                id: "background_loops", title: "Background loops", status: "fail",
                detail: "Loop failure history is unavailable: \(error.localizedDescription)")
        }
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
        if let issue = reportAvailabilityIssue {
            return (.unknown, [("doctor.latest_run", "Health checks unavailable", issue, false)])
        }
        // Reuse the mounted health card until an explicit Doctor run; this toolbar must not launch a second full pass.
        func summarize(_ statuses: [String]) -> SystemHealthSummary {
            let buckets = statuses.map { DoctorPlainCopy.bucket(for: $0) }
            let failCount = buckets.filter { $0 == "failing" }.count
            let warnCount = buckets.filter { $0 == "warning" }.count
            if failCount > 0 { return .error(count: failCount) }
            if warnCount > 0 { return .warn(count: warnCount) }
            if buckets.isEmpty || buckets.contains("unclear") || buckets.contains("reading") { return .unknown }
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
