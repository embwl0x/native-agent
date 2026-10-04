import Foundation
import MemoryV2
import PersistenceCore
import Synchronization

public typealias DoctorTelegramSnapshot = (enabled: Bool, tokenConfigured: Bool, isTransientPollInterruption: Bool, actionableError: String?, pollerEnabled: Bool, hasFreshSuccessfulPoll: Bool, isStarting: Bool)
public typealias DoctorAutonomySnapshot = (enabled: Bool?, disabledReason: String?, status: String, mode: String?, runningImprovements: Int?)
public typealias DoctorToolSnapshot = (status: String, name: String)
public typealias DoctorBridgeSnapshot = (name: String, health: (failure: String?, boundPort: UInt16?, isActive: Bool, port: UInt16), expected: Bool)

/// A currently applicable action supplied by the owner; instructions alone
/// never make a live finding executable.
public struct DoctorExecutableRepair: Sendable {
    public let checkID: String
    public let run: @Sendable () async throws -> DoctorRepairAttempt

    public init(checkID: String, run: @escaping @Sendable () async throws -> DoctorRepairAttempt) {
        self.checkID = checkID
        self.run = run
    }
}

public enum DoctorRepairAttempt: Sendable {
    case completed(String)
    case unverified(String)

    public var detail: String {
        switch self {
        case .completed(let detail), .unverified(let detail): return detail
        }
    }

    public var completed: Bool {
        if case .completed = self { return true }
        return false
    }
}

public enum DoctorProviderRuntimeReading: Sendable {
    case healthy
    case unhealthy(String)
    case unavailable
}
public enum DoctorProviderProbeReading: Sendable {
    case current
    case stale(String?)
    case unavailable(String)
    case failed(String)
}

/// Reads from the mounted runtime and platform listeners. Verdicts belong to Doctor.
public protocol DoctorActionPort: Sendable {
    func doctorProviderAuthStates() async throws -> [String]
    func doctorProviderRuntimeReading() async -> DoctorProviderRuntimeReading
    func doctorProviderProbeReading() -> DoctorProviderProbeReading
    func doctorTelegramSnapshot() async throws -> DoctorTelegramSnapshot
    func doctorSearchURL() async throws -> String?
    func doctorProbeSearch(base: String) async -> Bool
    func doctorLiveRepair(for check: CheckResult, scope: DoctorRepairScope) async -> DoctorExecutableRepair?
    func doctorRecordRepair(checkID: String, receipt: String, status: String) async throws
    func doctorToolSnapshots() async throws -> [DoctorToolSnapshot]
    func doctorAutonomySnapshot() async throws -> DoctorAutonomySnapshot
    func doctorBridgeSnapshots() async -> [DoctorBridgeSnapshot]
    func doctorBackgroundLoopsCheck() async -> CheckResult
    func doctorBackgroundLoopChecks() async -> [CheckResult]
    func doctorCognitionChecks() async -> [CheckResult]
    func doctorInspectorCheck() async -> CheckResult
    func doctorEmbeddingDownloadCheck() async -> CheckResult
    func redactDoctorDetail(_ value: String) -> String
}

/// The health pill polls live checks every 15 s. The live store is queried on
/// every call; the page-by-page quick_check is not.
private let liveMemoryQuickCheck = Mutex<(at: Date, rows: [String])?>(nil)
private let liveMemoryQuickCheckMaxAge: TimeInterval = 600
private let doctorRepairInFlight = Mutex(false)
private let liveSearchReading = Mutex<(base: String, healthy: Bool, at: Date)?>(nil)

public struct DoctorActionRuntime<Port: DoctorActionPort>: Sendable {
    private let port: Port
    public init(port: Port) { self.port = port }

    public static func safeDetail(_ value: String, redact: (String) -> String) -> String {
        boundedDoctorDetail(redact(value))
    }

    public static func mergeReport(currentChecks: [CheckResult], liveChecks: [CheckResult]) -> (status: String, checks: [CheckResult]) {
        let liveIDs = Set(liveChecks.map(\.id))
        let checks = currentChecks.filter { !liveIDs.contains($0.id) } + liveChecks
        return (DoctorStatusProjection.doctorRollup(checks.map(\.status)), checks)
    }
    public func runDoctor(repair: Bool = false, repairScope: DoctorRepairScope = .automatic, checks impl: any DoctorChecksProtocol) async throws -> (status: String, repaired: Bool, checks: [CheckResult]) {
        // Concurrent status readers do not queue another repair pass.
        let ownsRepair = repair && doctorRepairInFlight.withLock { running in
            guard !running else { return false }
            running = true
            return true
        }
        defer { if ownsRepair { doctorRepairInFlight.withLock { $0 = false } } }
        var checks = try await impl.runAll(repair: false)
        checks += await liveDoctorCoverageReadings(probeSearch: true, includeCognition: true)
        var liveRepairs: [String: DoctorExecutableRepair] = [:]
        for check in checks where check.id.hasPrefix("live.") && DoctorSafeRepairPolicy.isAdverse(check.status)
            && (ownsRepair || !check.id.hasPrefix("live.cognition.")) {
            if let action = await port.doctorLiveRepair(for: check, scope: ownsRepair ? repairScope : .button),
               action.checkID == check.id {
                liveRepairs[check.id] = action
            }
        }
        var repairReceipts: [CheckResult] = []
        if ownsRepair {
            // Freeze admission before executing; each check gets one attempt.
            for id in DoctorSafeRepairPolicy.checkIDs(for: checks, executableLiveIDs: Set(liveRepairs.keys), scope: repairScope) {
                try Task.checkCancellation()
                guard let index = checks.firstIndex(where: { $0.id == id }) else { continue }
                let before = checks[index]
                var receipt: String
                var actionCompleted = true
                do {
                    if let action = liveRepairs[id] {
                        let attempt = try await action.run()
                        receipt = attempt.detail
                        actionCompleted = attempt.completed
                    } else if let result = try await impl.runCheck(id: id, repair: true, scope: repairScope) {
                        receipt = result.receipt ?? (id == "oauth_token_expiry"
                            ? result.detail : result.repair ?? "Repair attempted; no completion receipt returned.")
                        // The OAuth result carries the exchange verdict. A
                        // disk-only reread cannot distinguish rejected from untried.
                        if id == "oauth_token_expiry" {
                            checks[index] = result
                        } else {
                            checks[index] = try await impl.runCheck(id: id, repair: false, scope: repairScope) ?? result
                        }
                    } else {
                        continue
                    }
                } catch is CancellationError {
                    throw CancellationError()
                } catch {
                    receipt = "Repair failed: \(safeDoctorDetail(error.localizedDescription))"
                    actionCompleted = false
                }
                if liveRepairs[id] != nil {
                    if let verified = await liveDoctorCheck(id: id) { checks[index] = verified }
                    if id == "live.telegram", !actionCompleted, checks[index].status == "ok" {
                        let row = checks[index]
                        checks[index] = CheckResult(id: row.id, title: row.title, status: "warn",
                                                    detail: row.detail, repair: row.repair,
                                                    human_action: row.human_action)
                    }
                }
                let verified = checks[index]
                var text = safeDoctorDetail(receipt)
                NSLog("[Doctor repair] %@: %@; recheck=%@", id, text, verified.status)
                do {
                    try await port.doctorRecordRepair(checkID: id, receipt: text, status: verified.status)
                } catch {
                    let failure = "Repair receipt could not be saved: \(safeDoctorDetail(error.localizedDescription))"
                    NSLog("[Doctor repair] %@", failure)
                    text += " " + failure
                }
                repairReceipts.append(CheckResult(id: id, title: before.title, status: verified.status, detail: text, receipt: text))
                checks[index] = CheckResult(
                    id: id, title: verified.title, status: verified.status,
                    detail: verified.detail,
                    repair: verified.repair, receipt: text, human_action: verified.human_action
                )
            }
        }
        let rollup = DoctorStatusProjection.doctorRollup(checks.map(\.status))
        let repaired = DoctorSafeRepairPolicy.appliedRepairCount(in: repairReceipts) > 0
        // Core checks still return legacy repair copy. Only an advertised,
        // registered handler may survive in the report's executable field.
        let handlers = Set(SwiftNativeDoctorChecks.defaultChecks.compactMap {
            $0 is any RepairingDoctorCheck ? $0.id : nil
        })
        let executable = Set(DoctorSafeRepairPolicy.checkIDs(for: checks)).intersection(handlers)
        for index in checks.indices {
            let row = checks[index]
            var liveAvailable = false
            if row.id.hasPrefix("live."), DoctorSafeRepairPolicy.isAdverse(row.status) {
                if ownsRepair {
                    liveAvailable = await port.doctorLiveRepair(for: row, scope: .button)?.checkID == row.id
                } else {
                    liveAvailable = liveRepairs[row.id] != nil || row.repair_available == true
                }
            }
            let coreAvailable = executable.contains(row.id)
            let buttonOnly = coreAvailable && !DoctorSafeRepairPolicy.automaticCoreIDs.contains(row.id)
            let humanAction = row.recoveryAction(repairAvailable: liveAvailable || coreAvailable) ?? (liveAvailable
                ? "Open Diagnostics → Doctor and press Repair to retry this live service."
                : coreAvailable && row.id == "persona_engine"
                ? "Persona and identity documents require your decision. Open Diagnostics → Doctor and press Repair to create missing persona documents; automatic checks never write them."
                : buttonOnly
                ? "Open Diagnostics → Doctor and press Repair to run this file repair. Existing files are backed up before replacement; automatic checks leave them unchanged."
                : nil)
            checks[index] = CheckResult(id: row.id, title: row.title, status: row.status, detail: row.detail,
                        repair: liveAvailable ? "Run Repair Safe Issues to retry this live service." : (coreAvailable ? row.repair : nil),
                        receipt: row.receipt,
                        human_action: humanAction, repair_available: liveAvailable || coreAvailable)
        }
        return (status: rollup, repaired: repaired, checks: checks)
    }

    private func liveDoctorCheck(id: String) async -> CheckResult? {
        if id.hasPrefix("live.cognition.") {
            return await port.doctorCognitionChecks().first { $0.id == id }
        }
        switch id {
        case "live.providers": return await providerDoctorCoverageCheck()
        case "live.search": return await searchDoctorCoverageCheck(probe: true)
        case "live.telegram": return await telegramDoctorCoverageCheck()
        case "live.background_loops": return await backgroundLoopsDoctorCoverageCheck()
        case "live.bridges": return await bridgesDoctorCoverageCheck()
        case "live.memory": return await memoryDoctorCoverageCheck()
        case "live.inspector_feed": return await port.doctorInspectorCheck()
        case "live.embedding_download": return await port.doctorEmbeddingDownloadCheck()
        default:
            if id.hasPrefix("live.background_loop.") {
                return await port.doctorBackgroundLoopChecks().first { $0.id == id }
            }
            return nil
        }
    }

    public func liveDoctorCoverageChecks(probeSearch: Bool = false) async -> [CheckResult] {
        var checks = await liveDoctorCoverageReadings(probeSearch: probeSearch, includeCognition: false)
        for index in checks.indices where DoctorSafeRepairPolicy.isAdverse(checks[index].status) {
            let row = checks[index]
            let available = await port.doctorLiveRepair(for: row, scope: .button)?.checkID == row.id
            checks[index] = CheckResult(
                id: row.id, title: row.title, status: row.status, detail: row.detail,
                repair: available ? "Run Repair Safe Issues to retry this live service." : nil,
                receipt: row.receipt, human_action: row.recoveryAction(repairAvailable: available), repair_available: available
            )
        }
        return checks
    }

    private func liveDoctorCoverageReadings(probeSearch: Bool, includeCognition: Bool) async -> [CheckResult] {
        async let providers = providerDoctorCoverageCheck()
        async let telegram = telegramDoctorCoverageCheck()
        async let search = searchDoctorCoverageCheck(probe: probeSearch)
        async let tools = toolsDoctorCoverageCheck()
        async let autonomy = autonomyDoctorCoverageCheck()
        // FIX-4 (2026-09-01): DoctorLoopHealth's verdicts had no route into
        // `doctorReport.checks`, so the toolbar pill could not see them. This
        // is the same read-only evaluation the Doctor loops section renders,
        // rolled into one row — and it rides the live-coverage lane, so
        // `refreshLiveDoctorCoverage()` keeps it current too.
        async let loops = backgroundLoopsDoctorCoverageCheck()
        async let loopDetails = port.doctorBackgroundLoopChecks()
        async let memory = memoryDoctorCoverageCheck()
        async let bridges = bridgesDoctorCoverageCheck()
        async let inspector = port.doctorInspectorCheck()
        async let embedding = port.doctorEmbeddingDownloadCheck()
        let common = await [providers, telegram, search, tools, autonomy, loops, memory, bridges, inspector, embedding] + (await loopDetails)
        return includeCognition ? common + (await port.doctorCognitionChecks()) : common
    }

    /// The store the running app actually holds — not a second reader over the
    /// file (that is `memory_store`). An open failure at launch leaves memory
    /// unwired until restart runs the complete migration/projection startup.
    private func memoryDoctorCoverageCheck() async -> CheckResult {
        let title = "Live memory store"
        if let failure = SwiftNativeMemoryV2.sharedOpenFailure {
            return CheckResult(
                id: "live.memory", title: title, status: "fail",
                detail: "The canonical memory store is not attached: \(safeDoctorDetail(failure))",
                human_action: "Restart NativeAgent — memory didn't open at launch"
            )
        }
        guard let bridge = await SwiftNativeMemoryV2.shared.underlyingBridge() else {
            return CheckResult(
                id: "live.memory", title: title, status: "fail",
                detail: "The running app has no memory store attached.",
                human_action: "Restart NativeAgent — memory didn't open at launch"
            )
        }
        let storage = await bridge.underlyingStorage()
        let path = await storage.path.path
        do {
            // Every call: the pool the running app writes through answers.
            _ = try await storage.listMemories(persona: nil, status: nil, limit: 1)
            let cached = liveMemoryQuickCheck.withLock { $0 }
            let rows: [String]
            if let cached, Date().timeIntervalSince(cached.at) < liveMemoryQuickCheckMaxAge {
                rows = cached.rows
            } else {
                do {
                    rows = try await storage.quickCheck()
                } catch {
                    rows = ["quick_check could not run: \(error)"]
                }
                liveMemoryQuickCheck.withLock { $0 = (Date(), rows) }
            }
            guard rows == ["ok"] else {
                return CheckResult(
                    id: "live.memory", title: title, status: "fail",
                    detail: "quick_check on \(path) reported: \(safeDoctorDetail(rows.joined(separator: "; ")))",
                    human_action: "Restore memory.sqlite from a backup (Trust Center) before it is written further."
                )
            }
            return CheckResult(
                id: "live.memory", title: title, status: "ok",
                detail: "\(path) is open in the running app and quick_check is clean.", repair: nil
            )
        } catch {
            return CheckResult(
                id: "live.memory", title: title, status: "fail",
                detail: "The live memory store did not answer: \(safeDoctorDetail(String(describing: error)))", repair: nil
            )
        }
    }

    /// Each install listens on its own fixed ports; one another process
    /// holds fails here with the holder's name (clients read the descriptor,
    /// so nothing else would say why they can't connect).
    private func bridgesDoctorCoverageCheck() async -> CheckResult {
        // `expected`: ClaudeBridge and the browser IPC are always resident;
        // MacControlBridge only when Mac control is enabled. Expected but
        // down = its startup failed.
        let bridges = await port.doctorBridgeSnapshots()
        var failures: [String] = []
        var warnings: [String] = []
        var healthy: [String] = []
        var nextSteps: [String] = []
        for (name, health, expected) in bridges {
            if let failure = health.failure {
                failures.append("\(name) is not listening: \(failure)")
                if let range = failure.range(of: " is held by ") {
                    let holder = String(failure[range.upperBound...])
                    nextSteps.append("Quit \(holder) to free port \(health.port) for \(name), then run Doctor again.")
                } else {
                    nextSteps.append("\(name) could not bind port \(health.port): \(failure).")
                }
            } else if let bound = health.boundPort {
                healthy.append("\(name) on \(bound)")
            } else if health.isActive {
                warnings.append("\(name) is still starting on \(health.port)")
            } else if expected {
                failures.append("\(name) is not listening: its startup stopped before binding port \(health.port) (see Console for [\(name)])")
            } else {
                healthy.append("\(name) off")
            }
        }
        if !failures.isEmpty || !warnings.isEmpty {
            return CheckResult(
                id: "live.bridges", title: "Local bridges",
                status: failures.isEmpty ? "warn" : "fail",
                detail: safeDoctorDetail((failures + warnings + healthy).joined(separator: ". ") + "."),
                human_action: nextSteps.isEmpty ? nil : nextSteps.joined(separator: " ")
            )
        }
        return CheckResult(
            id: "live.bridges", title: "Local bridges", status: "ok",
            detail: healthy.joined(separator: ", ") + ".", repair: nil
        )
    }

    private func backgroundLoopsDoctorCoverageCheck() async -> CheckResult {
        await port.doctorBackgroundLoopsCheck()
    }

    public func providerDoctorCoverageCheck() async -> CheckResult {
        do {
            let providers = try await port.doctorProviderAuthStates()
            let registryCheck = providerDoctorCoverageCheck(providers)
            let runtime = await port.doctorProviderRuntimeReading()
            switch runtime {
            case .healthy:
                break
            case .unhealthy(let detail):
                return CheckResult(
                    id: "live.providers",
                    title: "Providers and OAuth",
                    status: "warn",
                    detail: "\(registryCheck.detail) \(safeDoctorDetail(detail))",
                    human_action: detail.hasPrefix("No usable provider")
                        ? "Open Providers and activate an authenticated provider for Chat."
                        : "Open Providers and run Test Connection for the active provider. If it fails, use its reported authentication or connectivity step."
                )
            case .unavailable:
                break
            }
            switch port.doctorProviderProbeReading() {
            case .current:
                guard registryCheck.status == "ok" else { return registryCheck }
                if case .healthy = runtime {
                    return CheckResult(
                        id: registryCheck.id,
                        title: registryCheck.title,
                        status: "ok",
                        detail: "\(registryCheck.detail) Active provider path is ready.",
                        repair: nil
                    )
                }
                return registryCheck
            case .stale(let providerID):
                return CheckResult(
                    id: "live.providers",
                    title: "Providers and OAuth",
                    status: "warn",
                    detail: "\(registryCheck.detail) Last native provider check for \(providerID ?? "an unknown provider") is stale.",
                    human_action: "Open Providers and run Test Connection."
                )
            case .unavailable:
                // No native connection test exists for this route; ready
                // authentication is the whole verdict, not a fault.
                return registryCheck
            case .failed(let detail):
                return CheckResult(
                    id: "live.providers",
                    title: "Providers and OAuth",
                    status: "fail",
                    detail: "The last native provider check failed: \(safeDoctorDetail(detail))",
                    human_action: "Open Providers, repair authentication or connectivity, then run Test Connection."
                )
            }
        } catch {
            return CheckResult(
                id: "live.providers", title: "Providers and OAuth", status: "fail",
                detail: "Provider registry could not be read: \(safeDoctorDetail(error.localizedDescription))", repair: nil,
                human_action: "Open Providers and check its saved provider configuration; restore the provider registry from a valid backup if it cannot be read."
            )
        }
    }

    private func telegramDoctorCoverageCheck() async -> CheckResult {
        do {
            let status = try await port.doctorTelegramSnapshot()
            return telegramDoctorCoverageCheck(status)
        } catch {
            return CheckResult(
                id: "live.telegram", title: "Telegram", status: "fail",
                detail: "Telegram status could not be read: \(safeDoctorDetail(error.localizedDescription))", repair: nil
            )
        }
    }

    private func searchDoctorCoverageCheck(probe: Bool) async -> CheckResult {
        do {
            let raw = (try await port.doctorSearchURL())?
                .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            return await searchDoctorCoverageCheck(raw, probe: probe)
        } catch {
            return CheckResult(
                id: "live.search", title: "Search", status: "fail",
                detail: "Search configuration could not be read: \(safeDoctorDetail(error.localizedDescription))", repair: nil
            )
        }
    }

    private func toolsDoctorCoverageCheck() async -> CheckResult {
        do {
            let tools = try await port.doctorToolSnapshots()
            return toolsDoctorCoverageCheck(tools)
        } catch {
            return CheckResult(
                id: "live.tools", title: "Tool Registry", status: "fail",
                detail: "Tool registry could not be read: \(safeDoctorDetail(error.localizedDescription))", repair: nil
            )
        }
    }

    private func autonomyDoctorCoverageCheck() async -> CheckResult {
        do {
            let autonomy = try await port.doctorAutonomySnapshot()
            return autonomyDoctorCoverageCheck(autonomy)
        } catch {
            return CheckResult(
                id: "live.autonomy", title: "Autonomy", status: "fail",
                detail: "Autonomy state could not be read: \(safeDoctorDetail(error.localizedDescription))", repair: nil
            )
        }
    }

    private static func boundedDoctorDetail(_ value: String, limit: Int = 240) -> String {
        guard value.count > limit else { return value }
        return String(value.prefix(limit - 1)) + "…"
    }

    public func safeDoctorDetail(_ value: String) -> String {
        Self.safeDetail(value, redact: port.redactDoctorDetail)
    }

    private func providerDoctorCoverageCheck(_ providers: [String]) -> CheckResult {
        let ready = providers.filter { $0.lowercased() == "ready" }
        if ready.isEmpty {
            return CheckResult(
                id: "live.providers", title: "Providers and OAuth", status: "warn",
                detail: "Provider registry is readable, but no provider currently reports ready authentication.",
                human_action: "Open the Providers tab in the sidebar and authenticate one provider."
            )
        }
        return CheckResult(
            id: "live.providers", title: "Providers and OAuth", status: "ok",
            detail: "\(ready.count) of \(providers.count) provider paths report ready authentication.", repair: nil
        )
    }

    private func telegramDoctorCoverageCheck(_ status: DoctorTelegramSnapshot) -> CheckResult {
        guard status.enabled else {
            return CheckResult(
                id: "live.telegram", title: "Telegram", status: "ok",
                detail: "Telegram is disabled by configuration.", repair: nil
            )
        }
        guard status.tokenConfigured else {
            return CheckResult(
                id: "live.telegram", title: "Telegram", status: "fail",
                detail: "Telegram is enabled but no bot token is configured.",
                human_action: "Open Settings → Telegram and configure the bot token."
            )
        }
        if status.isTransientPollInterruption && status.hasFreshSuccessfulPoll {
            return CheckResult(
                id: "live.telegram", title: "Telegram", status: "ok",
                detail: "Telegram's poller is active and retrying after a transient poll interruption.",
                repair: nil
            )
        }
        if let lastError = status.actionableError {
            return CheckResult(
                id: "live.telegram", title: "Telegram", status: "warn",
                detail: "Telegram's last recorded error is: \(safeDoctorDetail(lastError))",
                human_action: lastError.contains("401") || lastError.localizedCaseInsensitiveContains("unauthorized")
                    ? "Open Settings → Telegram and replace the bot token with the current token from @BotFather."
                    : nil
            )
        }
        guard status.pollerEnabled else {
            return CheckResult(
                id: "live.telegram", title: "Telegram", status: "warn",
                detail: "Telegram is configured, but its poller is not active.", repair: nil
            )
        }
        guard status.hasFreshSuccessfulPoll else {
            if status.isStarting {
                return CheckResult(id: "live.telegram", title: "Telegram", status: "ok",
                                   detail: "Telegram is starting; waiting for its first successful poll this app session.")
            }
            return CheckResult(id: "live.telegram", title: "Telegram", status: "warn",
                               detail: "Telegram's poller is active, but no fresh successful poll has been recorded in this app session.")
        }
        return CheckResult(
            id: "live.telegram", title: "Telegram", status: "ok",
            detail: "Telegram is configured and its poller is active.", repair: nil
        )
    }

    private func searchDoctorCoverageCheck(_ raw: String, probe: Bool) async -> CheckResult {
        guard !raw.isEmpty else {
            return CheckResult(
                id: "live.search", title: "Search", status: "ok",
                detail: "External SearXNG search is not configured.", repair: nil
            )
        }
        guard let url = URL(string: raw),
              ["http", "https"].contains(url.scheme?.lowercased() ?? ""),
              url.host?.isEmpty == false, url.query == nil, url.fragment == nil else {
            return CheckResult(
                id: "live.search", title: "Search", status: "fail",
                detail: "The configured SearXNG URL is invalid.",
                human_action: "Open Research → Search service, enter a complete HTTP(S) URL in SearXNG URL without a query or fragment, then click Save."
            )
        }
        if probe {
            let healthy = await port.doctorProbeSearch(base: raw)
            liveSearchReading.withLock { $0 = (raw, healthy, Date()) }
        }
        guard let reading = liveSearchReading.withLock({ $0 }), reading.base == raw,
              Date().timeIntervalSince(reading.at) < 600 else {
            return CheckResult(id: "live.search", title: "Search", status: "unmeasured",
                               detail: "SearXNG has no recent probe result. Run Doctor to check it.")
        }
        if reading.healthy {
            return CheckResult(id: "live.search", title: "Search", status: "ok",
                               detail: "The configured SearXNG endpoint answered the bounded search probe successfully.")
        }
        return CheckResult(
            id: "live.search", title: "Search", status: "warn",
            detail: "The configured SearXNG endpoint failed the bounded search probe.",
            human_action: "Open Research → Search service and verify the SearXNG URL and that server's availability. If its container is stopped and ownership is not configured, confirm which container to start."
        )
    }

    /// FIX-5c (2026-09-01): every non-throwing path returned "ok", so a
    /// registry holding QUARANTINED tools reported the same green as a clean
    /// one. Two changes, both honesty: the detail now states the row's actual
    /// scope on every path (the registry file was read; no tool was invoked),
    /// and a quarantined tool is a finding. `proposed` is deliberately NOT a
    /// finding — an unapproved proposal is the self-building lane working.
    private func toolsDoctorCoverageCheck(_ tools: [DoctorToolSnapshot]) -> CheckResult {
        let quarantined = tools.filter { $0.status.lowercased() == "quarantined" }
        let active = tools.filter { $0.status.lowercased() == "active" }.count
        let scope = " Registry read only: Doctor invoked no tool, so this says nothing about whether one runs."
        // Taste pass 2026-07-24: this registry holds SELF-BUILT (promoted)
        // tools only — built-in chat tools never appear here, so an empty
        // registry is the normal state and "0 active, 0 total" read like the
        // agent had no tools at all.
        if tools.isEmpty {
            return CheckResult(
                id: "live.tools", title: "Tool Registry", status: "ok",
                detail: "Self-built tool registry is readable; no promoted tools yet."
                    + " Built-in tools don't live here." + scope,
                repair: nil
            )
        }
        let census = "Self-built tool registry is readable (\(active) active, \(tools.count) total)."
        if !quarantined.isEmpty {
            let named = quarantined.prefix(3).map(\.name).joined(separator: ", ")
            let more = quarantined.count > 3 ? ", …" : ""
            return CheckResult(
                id: "live.tools", title: "Tool Registry", status: "warn",
                detail: census + " \(quarantined.count) quarantined: \(named)\(more)." + scope,
                human_action: "Open Tools and restore or remove the quarantined tools."
            )
        }
        return CheckResult(
            id: "live.tools", title: "Tool Registry", status: "ok",
            detail: census + scope,
            repair: nil
        )
    }

    private func autonomyDoctorCoverageCheck(_ autonomy: DoctorAutonomySnapshot) -> CheckResult {
        if autonomy.enabled == nil {
            return CheckResult(
                id: "live.autonomy", title: "Autonomy", status: "warn",
                detail: "Autonomy state is readable, but its enabled posture is unknown.", repair: nil
            )
        }
        guard autonomy.enabled == true else {
            return CheckResult(
                id: "live.autonomy", title: "Autonomy", status: "ok",
                detail: autonomy.disabledReason ?? "Autonomy is disabled by policy.", repair: nil
            )
        }
        let state = autonomy.status.lowercased()
        return CheckResult(
            id: "live.autonomy", title: "Autonomy",
            status: ["fail", "error", "degraded"].contains(state) ? "warn" : "ok",
            detail: "Autonomy is enabled in \(autonomy.mode ?? "supervised") mode; \(autonomy.runningImprovements ?? 0) improvements are active.",
            repair: nil
        )
    }

}
