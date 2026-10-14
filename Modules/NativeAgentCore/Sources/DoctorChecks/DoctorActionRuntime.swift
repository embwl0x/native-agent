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
    case healthy(DoctorProviderProbeReading)
    case unhealthy(String)
    case configurationIssue(CheckResult)
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
    func doctorDataRootCheck() -> CheckResult
    func doctorTelegramSnapshot() async throws -> DoctorTelegramSnapshot
    func doctorSearchURL() async throws -> String?
    func doctorProbeSearch(base: String) async -> Bool
    func doctorSearchSetupReading() -> String?
    /// Codex web search, the route that answers first: is its login live?
    func doctorProbeCodexSearch() async -> Bool
    /// Doctor state: Docker was checked for this search URL and holds no SearXNG.
    func doctorSearchBackendAbsent(base: String) -> Bool
    func doctorLiveRepair(for check: CheckResult, scope: DoctorRepairScope) async -> DoctorExecutableRepair?
    func doctorRecordRepair(checkID: String, receipt: String, status: String) async throws
    func doctorToolSnapshots() async throws -> [DoctorToolSnapshot]
    func doctorAutonomySnapshot() async throws -> DoctorAutonomySnapshot
    func doctorBridgeSnapshots() async -> [DoctorBridgeSnapshot]
    func doctorAgentConnectionsCheck() async -> CheckResult
    func doctorBackgroundLoopsCheck() async -> CheckResult
    func doctorBackgroundLoopChecks() async -> [CheckResult]
    func doctorCognitionChecks() async -> [CheckResult]
    func doctorInspectorCheck() async -> CheckResult
    func doctorEmbeddingDownloadCheck() async -> CheckResult
    func doctorOrganPulsesCheck() async -> CheckResult
    func redactDoctorDetail(_ value: String) -> String
}

/// The health pill polls live checks every 15 s. The live store is queried on
/// every call; the page-by-page quick_check is not.
private let liveMemoryQuickCheck = Mutex<(at: Date, rows: [String])?>(nil)
private let liveMemoryQuickCheckMaxAge: TimeInterval = 600
private let doctorRepairInFlight = Mutex(false)
private let liveSearchReading = Mutex<(base: String, healthy: Bool, codex: Bool, at: Date)?>(nil)

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
        var checks = try await impl.runAll()
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
                        checks[index] = CheckResult(id: row.id, title: row.title, status: "unmeasured",
                                                    detail: row.detail, harm: row.harm, repair: row.repair,
                                                    receipt: row.receipt, human_action: row.human_action,
                                                    repair_available: row.repair_available, ask: row.ask, owner: row.owner)
                    }
                }
                let verified = checks[index]
                var text = safeDoctorDetail(receipt)
                nativeLog("[Doctor repair] %@: %@; recheck=%@", id, text, verified.status)
                do {
                    try await port.doctorRecordRepair(checkID: id, receipt: text, status: verified.status)
                } catch {
                    let failure = "Repair receipt could not be saved: \(safeDoctorDetail(error.localizedDescription))"
                    nativeLog("[Doctor repair] %@", failure)
                    text += " " + failure
                }
                repairReceipts.append(CheckResult(id: id, title: before.title, status: verified.status, detail: text, harm: verified.harm, receipt: text))
                checks[index] = CheckResult(
                    id: id, title: verified.title, status: verified.status,
                    detail: verified.detail, harm: verified.harm,
                    repair: verified.repair, receipt: text, human_action: verified.human_action,
                    repair_available: verified.repair_available, ask: verified.ask, owner: verified.owner
                )
            }
        }
        let rollup = DoctorStatusProjection.doctorRollup(checks.map(\.status))
        let repaired = DoctorSafeRepairPolicy.appliedRepairCount(in: repairReceipts) > 0
        let executable = DoctorSafeRepairPolicy.executableCoreIDs(for: checks)
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
            checks[index] = row.settled(liveAvailable: liveAvailable, coreAvailable: executable.contains(row.id))
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
        case "live.background_loops": return await port.doctorBackgroundLoopsCheck()
        case "live.bridges": return await bridgesDoctorCoverageCheck()
        case "live.agent_connections": return await port.doctorAgentConnectionsCheck()
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
                id: row.id, title: row.title, status: row.status, detail: row.detail, harm: row.harm,
                repair: available ? "Run Repair Safe Issues to retry this live service." : nil,
                receipt: row.receipt, human_action: row.recoveryAction(repairAvailable: available), repair_available: available,
                ask: row.ask, owner: DoctorOwner.of(row, repairAvailable: available)
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
        async let loops = port.doctorBackgroundLoopsCheck()
        async let loopDetails = port.doctorBackgroundLoopChecks()
        async let memory = memoryDoctorCoverageCheck()
        async let bridges = bridgesDoctorCoverageCheck()
        async let agents = port.doctorAgentConnectionsCheck()
        async let inspector = port.doctorInspectorCheck()
        async let embedding = port.doctorEmbeddingDownloadCheck()
        async let pulses = port.doctorOrganPulsesCheck()
        let common = await [providers, telegram, search, tools, autonomy, loops, memory, bridges, agents, inspector, embedding, pulses] + (await loopDetails) + [port.doctorDataRootCheck()]
        return includeCognition ? common + (await port.doctorCognitionChecks()) : common
    }

    /// The store the running app actually holds — not a second reader over the
    /// file (that is `memory_store`). Attachment retries on the same owner.
    private func memoryDoctorCoverageCheck() async -> CheckResult {
        let title = "Live memory store"
        guard let bridge = await SwiftNativeMemoryV2.shared.underlyingBridge() else {
            return CheckResult(
                id: "live.memory", title: title, status: "fail",
                detail: "The canonical memory store is not attached: \(safeDoctorDetail(SwiftNativeMemoryV2.sharedOpenFailure ?? "attachment unavailable"))",
                harm: "Her memories cannot be saved or recalled.",
                repair: "Run Repair Safe Issues to retry canonical memory attachment."
            )
        }
        let storage = await bridge.underlyingStorage()
        let path = await storage.path.path
        do {
            // Every call: the pool the running app writes through answers.
            _ = try await storage.listMemories(persona: nil, status: nil, limit: 1)
            if let failure = SwiftNativeMemoryV2.graphProjectionFailure {
                return CheckResult(
                    id: "live.memory", title: title, status: "fail",
                    detail: "The memory knowledge graph is waiting for canonical reconciliation: \(safeDoctorDetail(failure))",
                    harm: "She cannot recall connections between her saved memories.",
                    repair: "Run Repair Safe Issues to reconcile the canonical memory graph."
                )
            }
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
                    harm: "Her saved memories may be damaged and further writes could lose them.",
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
                detail: "The live memory store did not answer: \(safeDoctorDetail(String(describing: error)))",
                harm: "Her memories cannot be saved or recalled.", repair: nil
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
                status: failures.isEmpty ? "unmeasured" : "fail",
                detail: safeDoctorDetail((failures + warnings + healthy).joined(separator: ". ") + "."),
                harm: failures.isEmpty ? nil : "Other apps and helpers cannot reach her through the affected local bridges.",
                human_action: nextSteps.isEmpty ? nil : nextSteps.joined(separator: " ")
            )
        }
        return CheckResult(
            id: "live.bridges", title: "Local bridges", status: "ok",
            detail: healthy.joined(separator: ", ") + ".", repair: nil
        )
    }

    public func providerDoctorCoverageCheck() async -> CheckResult {
        do {
            let runtime = await port.doctorProviderRuntimeReading()
            // A configuration issue replaces registry coverage in the single live.providers row while present.
            if case .configurationIssue(let check) = runtime { return check }
            let providers = try await port.doctorProviderAuthStates()
            let registryCheck = providerDoctorCoverageCheck(providers)
            switch runtime {
            case .healthy:
                break
            case .unhealthy(let detail):
                return CheckResult(
                    id: "live.providers",
                    title: "Providers and OAuth",
                    status: "warn",
                    detail: "\(registryCheck.detail) \(safeDoctorDetail(detail))",
                    harm: "She cannot reliably answer through the active provider.",
                    human_action: detail.hasPrefix("No usable provider")
                        ? "Open Providers and activate an authenticated provider for Chat."
                        : "Open Providers and run Test Connection for the active provider. If it fails, use its reported authentication or connectivity step.",
                    ask: detail.hasPrefix("No usable provider") ? .signIn : nil
                )
            case .unavailable, .configurationIssue:
                break
            }
            guard case .healthy(let probe) = runtime else { return registryCheck }
            switch probe {
            case .current:
                guard registryCheck.status == "ok" else { return registryCheck }
                return CheckResult(
                    id: registryCheck.id,
                    title: registryCheck.title,
                    status: "ok",
                    detail: "\(registryCheck.detail) Active provider path is ready.",
                    repair: nil
                )
            case .stale(let providerID):
                return CheckResult(
                    id: "live.providers",
                    title: "Providers and OAuth",
                    status: DoctorSafeRepairPolicy.isAdverse(registryCheck.status) ? registryCheck.status : "unmeasured",
                    detail: "\(registryCheck.detail) Last native provider check for \(providerID ?? "an unknown provider") is stale.",
                    harm: registryCheck.harm, repair: registryCheck.repair, receipt: registryCheck.receipt,
                    human_action: registryCheck.human_action ?? "Open Providers and run Test Connection.",
                    repair_available: registryCheck.repair_available, ask: registryCheck.ask, owner: registryCheck.owner
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
                    harm: "She cannot reliably answer through the active provider.",
                    human_action: "Open Providers, repair authentication or connectivity, then run Test Connection."
                )
            }
        } catch {
            return CheckResult(
                id: "live.providers", title: "Providers and OAuth", status: "fail",
                detail: "Provider registry could not be read: \(safeDoctorDetail(error.localizedDescription))",
                harm: "She cannot choose an authenticated provider to answer.", repair: nil,
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
                detail: "Telegram status could not be read: \(safeDoctorDetail(error.localizedDescription))",
                harm: "Telegram messages may not be read or answered.", repair: nil
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
                detail: "Search configuration could not be read: \(safeDoctorDetail(error.localizedDescription))",
                harm: "She cannot use the configured web search.", repair: nil
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
                detail: "Tool registry could not be read: \(safeDoctorDetail(error.localizedDescription))",
                harm: "She cannot use her self-built tools.", repair: nil
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
                detail: "Autonomy state could not be read: \(safeDoctorDetail(error.localizedDescription))",
                harm: "She cannot safely continue work on her own.", repair: nil
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
                harm: "She has no authenticated provider to answer through.",
                human_action: "Open the Providers tab in the sidebar and authenticate one provider.",
                ask: .signIn
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
                harm: "Telegram messages are not being read.",
                human_action: "Open Settings → Telegram and configure the bot token.",
                ask: .signIn
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
                harm: "Telegram messages may not be read or answered.",
                human_action: lastError.contains("401") || lastError.localizedCaseInsensitiveContains("unauthorized")
                    ? "Open Settings → Telegram and replace the bot token with the current token from @BotFather."
                    : nil,
                ask: lastError.contains("401") || lastError.localizedCaseInsensitiveContains("unauthorized")
                    ? .signIn : nil
            )
        }
        guard status.pollerEnabled else {
            return CheckResult(
                id: "live.telegram", title: "Telegram", status: "warn",
                detail: "Telegram is configured, but its poller is not active.",
                harm: "Telegram messages are not being read.", repair: nil
            )
        }
        guard status.hasFreshSuccessfulPoll else {
            if status.isStarting {
                return CheckResult(id: "live.telegram", title: "Telegram", status: "unmeasured",
                                   detail: "Telegram is starting; waiting for its first successful poll this app session.")
            }
            return CheckResult(id: "live.telegram", title: "Telegram", status: "unmeasured",
                               detail: "Telegram's poller is active, but no fresh successful poll has been recorded in this app session.")
        }
        return CheckResult(
            id: "live.telegram", title: "Telegram", status: "ok",
            detail: "Telegram is configured and its poller is active.", repair: nil
        )
    }

    private func searchDoctorCoverageCheck(_ raw: String, probe: Bool) async -> CheckResult {
        if raw.isEmpty, let detail = port.doctorSearchSetupReading() {
            return CheckResult(id: "live.search", title: "Search", status: "unmeasured", detail: detail)
        }
        let validCategoryURL = URL(string: raw).map {
            ["http", "https"].contains($0.scheme?.lowercased() ?? "")
                && $0.host?.isEmpty == false && $0.query == nil && $0.fragment == nil
        } ?? false
        // Only a Doctor run probes (launch, auto run, Run/Repair); the health
        // pill reads this reading and spawns nothing.
        if probe {
            async let healthy = validCategoryURL ? port.doctorProbeSearch(base: raw) : false
            async let codex = port.doctorProbeCodexSearch()
            let reading = (raw, await healthy, await codex, Date())
            liveSearchReading.withLock { $0 = reading }
        }
        guard let reading = liveSearchReading.withLock({ $0 }), reading.base == raw,
              Date().timeIntervalSince(reading.at) < 600 else {
            return CheckResult(id: "live.search", title: "Search", status: "unmeasured",
                               detail: "Web search has no recent probe result. Run Doctor to check it.")
        }
        let codexLine = reading.codex
            ? "Codex web search, which handles general searches, is signed in."
            : "General search is unavailable: the bundled Codex executable or NativeAgent's ChatGPT sign-in needs attention. Check ChatGPT in Providers, then run Doctor."
        if raw.isEmpty {
            return CheckResult(id: "live.search", title: "Search", status: reading.codex ? "ok" : "warn",
                               detail: codexLine + " Optional SearXNG category search is not configured.",
                               harm: reading.codex ? nil : "She cannot search the web for current information.",
                               human_action: reading.codex ? nil : "Check ChatGPT in Providers, then run Doctor.",
                               ask: reading.codex ? nil : .signIn)
        }
        if !validCategoryURL {
            return CheckResult(id: "live.search", title: "Search", status: "fail",
                               detail: codexLine + " The configured SearXNG URL is invalid.",
                               harm: "She cannot search the configured news, IT and science categories.",
                               human_action: "Open Research → Search service, enter a complete HTTP(S) URL in SearXNG URL without a query or fragment, then click Save.")
        }
        if reading.healthy {
            return CheckResult(id: "live.search", title: "Search", status: reading.codex ? "ok" : "warn",
                               detail: codexLine + " SearXNG answered the bounded search probe.",
                               harm: reading.codex ? nil : "She cannot run general web searches.",
                               human_action: reading.codex ? nil : "Check ChatGPT in Providers, then run Doctor.",
                               ask: reading.codex ? nil : .signIn)
        }
        return CheckResult(
            id: "live.search", title: "Search", status: "warn",
            detail: codexLine + " " + (port.doctorSearchBackendAbsent(base: raw)
                ? "No SearXNG backend: nothing answers at \(safeDoctorDetail(raw)) and Docker holds no SearXNG container for it, so category searches (news, it, science) are off."
                : "SearXNG at \(safeDoctorDetail(raw)) did not answer the bounded search probe, so category searches (news, it, science) are down."),
            harm: reading.codex ? "She cannot search the configured news, IT and science categories." : "She cannot search the web for current information."
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
                harm: "She cannot use the quarantined self-built tools.",
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
                id: "live.autonomy", title: "Autonomy", status: "unmeasured",
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
            harm: ["fail", "error", "degraded"].contains(state) ? "Her work on her own is interrupted." : nil,
            repair: nil
        )
    }

}
