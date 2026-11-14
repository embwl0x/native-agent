import Privacy
import Foundation
import MemoryV2
import NativeAgentCore
import NativeAgentShared
import BackgroundLoops
import PersistenceCore
import DoctorChecks
import BackgroundWork
import Cognition
import ProviderRouting
import Research
import AgentConversations
import AgentWorkspace
import Synchronization
import Experiences
import TelegramBot
// Blueprint: | `EngineDoctorMeasurements.swift` | Mounted provider, memory, tool, transport and organ health |

/// Read mounted health live while integrity checks retain their own cache.
private let liveMemoryQuickCheck = Mutex<(at: Date, rows: [String])?>(nil)
private let liveMemoryQuickCheckMaxAge: TimeInterval = 600
private let liveSearchReading = Mutex<(base: String, result: Result<Bool, Error>, at: Date)?>(nil)

extension EngineDoctorRuntime {
    /// Attachment retries must query the same mounted memory owner.
    func memoryDoctorCoverageCheck() async -> CheckResult {
        let title = "Live memory store"
        guard let storage = await SwiftNativeMemoryV2.shared.underlyingStorage() else {
            return CheckResult(source: "memory/memory.sqlite",
                id: "live.memory", title: title, status: "fail",
                detail: "The canonical memory store is not attached: \(safeDoctorDetail(SwiftNativeMemoryV2.sharedOpenFailure ?? "attachment unavailable"))",
                harm: "The agent's memories cannot be saved or recalled.",
                repair: "Press Repair in Diagnostics → Health checks to retry canonical memory attachment."
            )
        }
        let path = await storage.path.path
        do {
            // Query the pool the running app writes through.
            _ = try await storage.listMemories(persona: nil, status: nil, limit: 1)
            if let failure = SwiftNativeMemoryV2.graphProjectionFailure {
                return CheckResult(source: "memory/memory.sqlite",
                    id: "live.memory", title: title, status: "fail",
                    detail: "The memory knowledge graph is waiting for canonical reconciliation: \(safeDoctorDetail(failure))",
                    harm: "The agent cannot recall connections between its saved memories.",
                    repair: "Press Repair in Diagnostics → Health checks to reconcile the canonical memory graph."
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
                return CheckResult(source: "memory/memory.sqlite",
                    id: "live.memory", title: title, status: "fail",
                    detail: "quick_check on \(path) reported: \(safeDoctorDetail(rows.joined(separator: "; ")))",
                    harm: "The agent's saved memories may be damaged and further writes could lose them.",
                    human_action: """
                        Open Trust → Advanced → Backups, select a verified backup containing memory/memory.sqlite, then choose Restore → Restore backup \
                        before further writes.
                        """,
                    ask: .permission
                )
            }
            return CheckResult(source: "memory/memory.sqlite",
                id: "live.memory", title: title, status: "ok",
                detail: "\(path) is open in the running app and quick_check is clean.", repair: nil
            )
        } catch {
            return CheckResult(source: "memory/memory.sqlite",
                id: "live.memory", title: title, status: "fail",
                detail: "The live memory store did not answer: \(safeDoctorDetail(String(describing: error)))",
                harm: "The agent's memories cannot be saved or recalled.", repair: nil
            )
        }
    }
    /// Name the process holding a required fixed port when listener admission fails.
    func bridgesDoctorCoverageCheck() async -> CheckResult {
        // An expected bridge being down means its startup failed.
        let bridges = await self.doctorBridgeSnapshots()
        var failures: [String] = []
        var warnings: [String] = []
        var healthy: [String] = []
        var nextSteps: [String] = []
        for (name, health, expected) in bridges {
            if let failure = health.failure {
                failures.append("\(name) is not listening: \(failure)")
                if let range = failure.range(of: " is held by ") {
                    let holder = String(failure[range.upperBound...])
                    nextSteps.append("""
                        quit \(holder.trimmingCharacters(in: CharacterSet(charactersIn: ".").union(.whitespacesAndNewlines))) to free port \(health.port) for \
                        \(name), then run Health checks again
                        """)
                } else {
                    nextSteps.append("press Repair in Diagnostics → Health checks to retry \(name) on port \(health.port)")
                }
            } else if let bound = health.boundPort {
                healthy.append("\(name) on \(bound)")
            } else if health.isActive {
                warnings.append("\(name) is still starting on \(health.port)")
            } else if expected {
                failures.append("\(name) is not listening: its startup stopped before binding port \(health.port) (see Console for [\(name)])")
                nextSteps.append("press Repair in Diagnostics → Health checks to restart \(name)")
            } else {
                healthy.append("\(name) off")
            }
        }
        if !failures.isEmpty || !warnings.isEmpty {
            return CheckResult(source: "Local bridge listeners",
                id: "live.bridges", title: "Local bridges",
                status: failures.isEmpty ? "unmeasured" : "fail",
                detail: safeDoctorDetail((failures + warnings + healthy).joined(separator: "; ") + "."),
                harm: failures.isEmpty ? nil : "Other apps and helpers cannot reach the agent through the affected local bridges.",
                human_action: nextSteps.isEmpty ? nil : "For the affected bridges, " + nextSteps.joined(separator: "; ") + "."
            )
        }
        return CheckResult(source: "Local bridge listeners",
            id: "live.bridges", title: "Local bridges", status: "ok",
            detail: healthy.joined(separator: ", ") + ".", repair: nil
        )
    }
    public func providerDoctorCoverageCheck() async -> CheckResult {
        do {
            let (runtime, providers) = try await DoctorProviderPathReading.read(dataRoot: dataRoot, turn: turn)
            // Configuration faults replace registry coverage within the single provider-health row.
            if case .configurationIssue(let check) = runtime { return check }
            let registryCheck = providerDoctorCoverageCheck(providers.map { ($0.auth_status.state, $0.auth_status.eligible) })
            switch runtime {
            case .healthy:
                break
            case .unhealthy(let detail):
                var check = CheckResult(source: "Providers > Chat",
                    id: "live.providers",
                    title: "Providers and OAuth",
                    status: "warn",
                    detail: registryCheck.detail.trimmingCharacters(in: CharacterSet(charactersIn: ".").union(.whitespacesAndNewlines)) + "; active path: "
                        + safeDoctorDetail(detail),
                    harm: "The agent cannot reliably answer through the active provider.",
                    human_action: detail.hasPrefix("No usable provider")
                        ? "Open Providers → Chat → Model and choose an account and model."
                        : detail.contains("isn't offered") || detail.contains("is no longer offered")
                            ? "Open Providers → Chat → Model and choose a model offered by the selected Provider."
                            : "Open Providers → Accounts → active account → Test the connection and follow its reported recovery step.",
                    ask: detail.hasPrefix("No usable provider") ? .signIn : nil
                )
                // Only paths without pending-transaction repair need the user’s provider control.
                guard check.ask == nil, await self.doctorLiveRepair(for: check, scope: .button) == nil else { return check }
                check.ask = .permission
                return check
            case .unavailable, .configurationIssue:
                break
            }
            guard case .healthy(let probe) = runtime else { return registryCheck }
            switch probe {
            case .current:
                guard registryCheck.status == "ok" else { return registryCheck }
                var reading = registryCheck
                reading.detail = registryCheck.detail.trimmingCharacters(in: CharacterSet(charactersIn: ".").union(.whitespacesAndNewlines))
                    + "; active provider path is ready."
                reading.repair = nil
                return reading
            case .stale(let providerID):
                var reading = registryCheck
                reading.source = "Providers > Chat"
                reading.status = DoctorSafeRepairPolicy.isAdverse(registryCheck.status) ? registryCheck.status : "unmeasured"
                reading.detail = registryCheck.detail.trimmingCharacters(in: CharacterSet(charactersIn: ".").union(.whitespacesAndNewlines))
                    + "; last native provider check for \(providerID ?? "an unknown provider") is stale."
                reading.human_action = registryCheck.human_action ?? "Open Providers → Accounts → active account → Test the connection."
                return reading
            case .unavailable(let detail):
                // This route has no native probe; authentication readiness is its full verdict, never an invented fault.
                var reading = registryCheck
                reading.detail = registryCheck.detail.trimmingCharacters(in: CharacterSet(charactersIn: ".").union(.whitespacesAndNewlines)) + "; "
                    + safeDoctorDetail(detail)
                return reading
            case .failed(let detail):
                return CheckResult(source: "Providers > Chat",
                    id: "live.providers",
                    title: "Providers and OAuth",
                    status: "fail",
                    detail: "The last native provider check failed: \(safeDoctorDetail(detail))",
                    human_action: "Open Providers → Accounts → active account → Test the connection and follow its reported recovery step."
                )
            }
        } catch {
            let owner = (error as? ToolFailureError)?.owner
            let file = owner?.components(separatedBy: " generation ").first.flatMap { path -> URL? in
                let url = URL(fileURLWithPath: path).standardizedFileURL
                return url.deletingLastPathComponent().path == self.dataRoot.appendingPathComponent("providers").standardizedFileURL.path
                    && ["active.json", "surfaces.json", "pending-surface-configuration.json"].contains(url.lastPathComponent) ? url : nil
            }
            return CheckResult(source: file?.path ?? "Providers > saved configuration",
                id: "live.providers", title: "Providers and OAuth", status: "fail",
                detail: "Provider registry could not be read: \(safeDoctorDetail(error.localizedDescription))",
                harm: "The agent cannot choose an authenticated provider to answer.", repair: nil,
                human_action: [file.map { ToolFailureError.fileRepairInstruction($0,
                    shape: """
                        This JSON object holds the saved provider routing selection or its pending transaction. Preserve all surface, provider, model, effort \
                        and transaction fields; never choose a replacement provider or alter credentials.
                        """) },
                            """
                                Open Providers and check its saved provider configuration; restore the provider registry from a valid backup if it cannot be \
                                read.
                                """].compactMap { $0 }.joined(separator: " "))
        }
    }
    func telegramDoctorCoverageCheck() async -> CheckResult {
        do {
            let status = try await self.doctorTelegramSnapshot()
            return telegramDoctorCoverageCheck(status)
        } catch {
            if error is DeviceSecretKeychain.Failure {
                return CheckResult(source: "Telegram > Bot token", id: "live.telegram", title: "Telegram", status: "fail",
                    detail: "Telegram's saved Keychain credential is unavailable.",
                    human_action: "Telegram → Bot token → Bot token: enter the current token from @BotFather, then Save.", ask: .signIn)
            }
            return CheckResult(source: "telegram/config.json",
                id: "live.telegram", title: "Telegram", status: "fail",
                detail: "Telegram status could not be read: \(safeDoctorDetail(error.localizedDescription))",
                harm: "Telegram messages may not be read or answered.", repair: nil,
                human_action: ToolFailureError.fileRepairInstruction(self.dataRoot.appendingPathComponent("telegram/config.json"),
                    shape: """
                        This JSON object holds Telegram's saved enabled flag, sender allowlists and configuration. Preserve all credential references and \
                        admission choices exactly.
                        """))
        }
    }
    func searchDoctorCoverageCheck(probe: Bool) async -> CheckResult {
        do {
            let raw = (try await self.doctorSearchURL())?
                .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            return await searchDoctorCoverageCheck(raw, probe: probe)
        } catch {
            let source = (error as? ToolFailureError)?.owner ?? self.dataRoot.appendingPathComponent("research/config.json").path
            return CheckResult(source: source,
                id: "live.search", title: "Search", status: "fail",
                detail: "Search configuration is unreadable or malformed at \(safeDoctorDetail(source))."
            )
        }
    }
    func toolsDoctorCoverageCheck() async -> CheckResult {
        do {
            let tools = try await self.doctorToolSnapshots()
            return toolsDoctorCoverageCheck(tools)
        } catch {
            return CheckResult(source: "abilities/",
                id: "live.tools", title: "Tool Registry", status: "fail",
                detail: "Tool registry could not be read: \(safeDoctorDetail(error.localizedDescription))",
                harm: "The agent cannot use its self-built tools.",
                human_action: "Open Trust → Advanced → Backups, select a verified backup, then choose Restore → Restore backup.", ask: .permission
            )
        }
    }
    func autonomyDoctorCoverageCheck() async -> CheckResult {
        do {
            let autonomy = try await self.doctorAutonomySnapshot()
            return autonomyDoctorCoverageCheck(autonomy)
        } catch {
            return CheckResult(source: "trust/policy.json > enableAutonomy and autonomyDefault",
                id: "live.autonomy", title: "Autonomy", status: "fail",
                detail: "Autonomy state could not be read: \(safeDoctorDetail(error.localizedDescription))",
                harm: "The agent cannot safely continue work on its own.",
                human_action: "Open Trust → Advanced → Backups, select a verified backup, then choose Restore → Restore backup.", ask: .permission
            )
        }
    }
    private static func boundedDoctorDetail(_ value: String, limit: Int = 240) -> String {
        guard value.count > limit else { return value }
        return String(value.prefix(limit - 1)) + "…"
    }
    public func safeDoctorDetail(_ value: String) -> String {
        Self.safeDetail(value)
    }
    /// Read readiness from routing eligibility and each path’s receipt.
    private func providerDoctorCoverageCheck(_ providers: [(state: String, eligible: Bool)]) -> CheckResult {
        let usable = providers.filter(\.eligible)
        if usable.isEmpty {
            return CheckResult(source: "Providers > Chat",
                id: "live.providers", title: "Providers and OAuth", status: "warn",
                detail: "Provider registry is readable, but no provider currently has usable authentication.",
                harm: "The agent has no authenticated provider to answer through.",
                human_action: "Providers → Accounts → choose your provider → Add key or Sign in → protected connection card.",
                ask: .signIn
            )
        }
        return CheckResult(source: "Providers > Chat",
            id: "live.providers", title: "Providers and OAuth", status: "ok",
            detail: "\(usable.count) of \(providers.count) provider paths can answer ("
                + Dictionary(grouping: usable, by: \.state).sorted { $0.key < $1.key }
                    .map { "\($0.value.count) \($0.key)" }.joined(separator: ", ") + ").", repair: nil
        )
    }
    private func telegramDoctorCoverageCheck(_ status: DoctorTelegramSnapshot) -> CheckResult {
        guard status.enabled else {
            return CheckResult(source: "telegram/config.json",
                id: "live.telegram", title: "Telegram", status: "off",
                detail: "Telegram is disabled by configuration.", repair: nil
            )
        }
        guard status.tokenConfigured else {
            return CheckResult(source: "telegram/config.json",
                id: "live.telegram", title: "Telegram", status: "fail",
                detail: "Telegram is enabled but no bot token is configured.",
                harm: "Telegram messages are not being read.",
                human_action: "Telegram → Bot token → Bot token, then Save.",
                ask: .signIn
            )
        }
        if status.isTransientPollInterruption && status.hasFreshSuccessfulPoll {
            return CheckResult(source: "telegram/state.json > lastError",
                id: "live.telegram", title: "Telegram", status: "ok",
                detail: "Telegram's poller is active and retrying after a transient poll interruption.",
                repair: nil
            )
        }
        if let lastError = status.actionableError {
            let rejected = lastError.contains("401") || lastError.localizedCaseInsensitiveContains("unauthorized")
            return CheckResult(source: rejected ? "Telegram > Bot token" : "telegram/state.json > lastError",
                id: "live.telegram", title: "Telegram", status: rejected ? "warn" : "fail",
                detail: "Telegram's last recorded error is: \(safeDoctorDetail(lastError))",
                harm: "Telegram messages may not be read or answered.",
                human_action: rejected
                    ? "Telegram → Bot token → Bot token: enter the current token from @BotFather, then Save."
                    : nil,
                ask: rejected ? .signIn : nil
            )
        }
        guard status.pollerEnabled else {
            return CheckResult(source: "Background loop registration: telegram_poll",
                id: "live.telegram", title: "Telegram", status: "warn",
                detail: "Telegram is configured, but its poller is not active.",
                harm: "Telegram messages are not being read.", repair: nil
            )
        }
        guard status.hasFreshSuccessfulPoll else {
            if status.isStarting {
                return CheckResult(source: "telegram/config.json", id: "live.telegram", title: "Telegram", status: "unmeasured",
                                   detail: "Telegram is starting; waiting for its first successful poll this app session.")
            }
            return CheckResult(source: "telegram/config.json", id: "live.telegram", title: "Telegram", status: "unmeasured",
                               detail: "Telegram's poller is active, but no fresh successful poll has been recorded in this app session.")
        }
        return CheckResult(source: "telegram/config.json",
            id: "live.telegram", title: "Telegram", status: "ok",
            detail: "Telegram is configured and its poller is active.", repair: nil
        )
    }
    private func searchDoctorCoverageCheck(_ raw: String, probe: Bool) async -> CheckResult {
        let source = "research/config.json > searxng_base_url"
        // Never set up is off, not failed: only a configured address that is malformed or does not answer is a fault.
        if raw.isEmpty {
            return CheckResult(source: source, id: "live.search", title: "Search", status: "off",
                               detail: "Web search is off: no search service is set.",
                               human_action: "Open Research → Search service, enter the SearXNG URL, then click Save.")
        }
        let validURL = URL(string: raw).map {
            ["http", "https"].contains($0.scheme?.lowercased() ?? "")
                && $0.host?.isEmpty == false && $0.query == nil && $0.fragment == nil
        } ?? false
        guard validURL else {
            return CheckResult(source: source, id: "live.search", title: "Search", status: "fail",
                               detail: "The configured SearXNG URL is invalid, so the agent's web searches fail.",
                               harm: "The agent cannot search the web.",
                               human_action: """
                                   Open Research → Search service, enter a complete HTTP(S) URL in SearXNG URL without a query or fragment, then click Save.
                                   """)
        }
        // Doctor may probe; the health pill must read the cached result.
        if probe {
            let result: Result<Bool, Error>
            do { result = .success(try await self.doctorProbeSearch(base: raw)) }
            catch { result = .failure(error) }
            let reading = (raw, result, Date())
            liveSearchReading.withLock { $0 = reading }
        }
        guard let reading = liveSearchReading.withLock({ $0 }), reading.base == raw,
              Date().timeIntervalSince(reading.at) < 600 else {
            return CheckResult(source: source, id: "live.search", title: "Search", status: "unmeasured",
                               detail: "Web search has no recent probe result; run Diagnostics → Health checks to check it.")
        }
        switch reading.result {
        case .success(true):
            return CheckResult(source: source, id: "live.search", title: "Search", status: "ok",
                               detail: "SearXNG answered the bounded search probe.")
        case .failure(let error):
            let harm: String
            if let failure = error as? ResearchClientError, case .malformedResponse = failure {
                harm = "Search readiness is unverified because the probe response could not establish it."
            } else {
                harm = "The agent cannot search the web until the configured service answers."
            }
            return CheckResult(source: source, id: "live.search", title: "Search", status: "warn",
                detail: "The configured SearXNG probe is unavailable: \(safeDoctorDetail(error.localizedDescription))",
                harm: harm)
        case .success(false):
            return CheckResult(source: source, id: "live.search", title: "Search", status: "warn",
                detail: "Connection refused at the configured SearXNG address \(safeDoctorDetail(raw)); no search response was received.",
                harm: "The agent cannot search the web until the configured service answers.")
        }
    }
    /// Quarantine is an admission fact, not damage to undo.
    private func toolsDoctorCoverageCheck(_ tools: [DoctorToolSnapshot]) -> CheckResult {
        let quarantined = tools.filter { $0.status.lowercased() == "quarantined" }
        let active = tools.filter { $0.status.lowercased() == "active" }.count
        let scope = "; registry read only, with no tool invoked, so execution is unmeasured."
        // An empty promoted-tool registry is healthy.
        if tools.isEmpty {
            return CheckResult(source: "abilities/",
                id: "live.tools", title: "Tool Registry", status: "ok",
                detail: "Self-built tool registry is readable with no promoted tools yet; built-in tools are outside this registry" + scope,
                repair: nil
            )
        }
        let census = "Self-built tool registry is readable (\(active) active, \(tools.count) total)"
        if !quarantined.isEmpty {
            let named = quarantined.prefix(3).map(\.name).joined(separator: ", ")
            let more = quarantined.count > 3 ? ", …" : ""
            return CheckResult(source: "abilities/",
                id: "live.tools", title: "Tool Registry", status: "ok",
                detail: census + "; \(quarantined.count) quarantined: \(named)\(more)" + scope
            )
        }
        return CheckResult(source: "abilities/",
            id: "live.tools", title: "Tool Registry", status: "ok",
            detail: census + scope,
            repair: nil
        )
    }
    private func autonomyDoctorCoverageCheck(_ autonomy: DoctorAutonomySnapshot) -> CheckResult {
        if autonomy.enabled == nil {
            return CheckResult(source: "Trust > Autonomy",
                id: "live.autonomy", title: "Autonomy", status: "unmeasured",
                detail: "Autonomy state is readable, but its enabled posture is unknown.", repair: nil
            )
        }
        guard autonomy.enabled == true else {
            return CheckResult(source: "Trust > Autonomy",
                id: "live.autonomy", title: "Autonomy", status: "off",
                detail: autonomy.disabledReason ?? "Autonomy is disabled by policy.", repair: nil
            )
        }
        let state = autonomy.status.lowercased()
        return CheckResult(source: "Trust > Autonomy",
            id: "live.autonomy", title: "Autonomy",
            status: ["fail", "error"].contains(state) ? "fail" : state == "degraded" ? "warn" : "ok",
            detail: "Autonomy is enabled in \(autonomy.mode ?? "supervised") mode; reported state: \(autonomy.status).",
            repair: nil
        )
    }

    public static func safeDetail(_ value: String) -> String {
        boundedDoctorDetail(NativeAppSecretRedactor.redactText(value))
    }
    public func doctorEmbeddingDownloadCheck() async -> CheckResult {
        await DoctorEmbeddingDownloadCheck.read(dataRoot: dataRoot).check
    }
    public func doctorDataRootCheck() -> CheckResult {
        let marker = dataRoot.appendingPathComponent("install").appendingPathComponent(InstallPaths.publicReleaseDataMarker)
        do {
            let data = try Data(contentsOf: marker)
            guard let saved = try JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let reason = saved["reason"] as? String,
                  ["public_release_blank_slate_first_run", "public_release_marker_written_in_place"].contains(reason),
                  reason != "public_release_blank_slate_first_run" || (saved["backupPath"] as? String)?.isEmpty == false else {
                throw CocoaError(.propertyListReadCorrupt)
            }
            if reason == "public_release_blank_slate_first_run", let backup = saved["backupPath"] as? String,
               FileManager.default.fileExists(atPath: backup) {
                return CheckResult(source: marker.path,
                    id: "install.data_root", title: "Data root", status: "ok",
                    detail: "An earlier launch moved saved data to the recorded backup location: \(backup).")
            }
        } catch CocoaError.fileReadNoSuchFile {
            return CheckResult(source: marker.path, id: "install.data_root", title: "Data root", status: "ok",
                detail: "No earlier data-root move marker exists at \(marker.path).")
        } catch {
            return CheckResult(source: marker.path,
                id: "install.data_root", title: "Data root", status: "fail",
                detail: "The data-root move marker is unreadable or malformed: \(marker.path).",
                human_action: ToolFailureError.fileRepairInstruction(marker,
                    shape: """
                        This JSON object records installation history, including its reason and any earlier data-root move's backupPath. Preserve the \
                        original history and backup location; never invent a move or backup.
                        """))
        }
        return CheckResult(source: marker.path,id: "install.data_root", title: "Data root", status: "ok",
                           detail: "No existing backup from an earlier data-root move was found.")
    }

    public func doctorTelegramSnapshot() async throws -> DoctorTelegramSnapshot {
        let manager = port.doctorManager
        let status = try await TelegramFacade(dataRoot: dataRoot).loadStatus(manager: manager)
        let now = Date()
        let uptime = await manager.uptimeSeconds(now: now)
        let pollDate = status.lastPollAt.flatMap(NativeTimestampFormat.parseISO8601FractionalFirst)
        // Long polls may hold for 25 seconds; require bounded-age evidence from the current manager lifecycle.
        let fresh = pollDate.map {
            let age = now.timeIntervalSince($0)
            return age >= 0 && age <= 35 && age < uptime
        } ?? false
        let starting = status.pollerEnabled && uptime > 0 && uptime <= 35 && !fresh
        return (status.enabled, status.tokenConfigured, status.isTransientPollInterruption, status.actionableError, status.pollerEnabled, fresh, starting)
    }

    public func doctorSearchURL() async throws -> String? {
        try SwiftNativeResearchClient.checkedSearxngBaseURL(root: dataRoot)
    }

    public func doctorProbeSearch(base: String) async throws -> Bool {
        try await SwiftNativeResearchClient(dataRoot: dataRoot)
            .checkSearXNG(base: base, answering: true)
    }

    public func doctorToolSnapshots() async throws -> [DoctorToolSnapshot] {
        try await ToolsFacade(dataRoot: dataRoot).listAuthored().map { ($0.status, $0.name) }
    }

    public func doctorAutonomySnapshot() async throws -> DoctorAutonomySnapshot {
        let root = dataRoot
        let status = try await RuntimeReadouts.getAutonomyKernel(
            dataRoot: root)
        return (status.enabled, status.disabledReason, status.status, status.mode)
    }

    public func doctorBridgeSnapshots() async -> [DoctorBridgeSnapshot] {
        await port.doctorBridgeSnapshots()
    }

    public func doctorAgentConnectionsCheck() async -> CheckResult {
        let root = dataRoot
        await AgentContactHealth.shared.refresh(dataRoot: root)
        var source = "agents/peers.json"
        do {
            let peers = try AgentPeerStore(dataRoot: root).list()
            source = "agents/conversations.json"
            _ = try AgentConversationStore(dataRoot: root).recordsUnlocked()
            source = "agents/local-health.json"
            _ = try AgentLocalHealth.checkedRead(root)
            var problems: [String] = try AgentContactHealth.read(dataRoot: root).sorted { $0.key < $1.key }.compactMap { agent, health in
                guard health.isBroken else { return nil }
                return health.problem.map { (peers.first { "peer:" + $0.id == agent }?.name ?? agent) + ": " + $0 }
            }
            // Only repair obligations are problems; project each owner’s remedy.
            source = "experiences/experiences.sqlite"
            for owed in try await ExperienceStore.at(root).projection() where owed.owes["repair"]?.phase.isSettled == false
                && RepairDebt(owed).operation.map({ $0.hasPrefix("peer.") || $0.hasPrefix("agent.") }) == true {
                let operation = RepairDebt(owed).operation.map { "operation: " + $0 } ?? "agent connection"
                problems.append("\(operation) still owes repair (\(owed.id))")
            }
            return CheckResult(source: "agents/peers.json, agents/local-health.json and experiences/experiences.sqlite",
                id: "live.agent_connections", title: "Agent connections", status: problems.isEmpty ? "ok" : "fail",
                detail: problems.isEmpty ? "No broken reply path is recorded; setup alone does not prove a reply."
                    : "Agent connection evidence: " + problems.map { $0.trimmingCharacters(in: CharacterSet(charactersIn: ".").union(.whitespacesAndNewlines)) }
                        .joined(separator: "; ") + ".")
        } catch {
            return CheckResult(source: source,
                id: "live.agent_connections", title: "Agent connections", status: "fail",
                detail: "Agent connection evidence is unavailable: \(Self.safeDetail(error.localizedDescription))",
                harm: "The agent's saved helper contacts and conversations cannot be read.", repair: nil,
                human_action: ToolFailureError.fileRepairInstruction(root.appendingPathComponent(source),
                    shape: source == "experiences/experiences.sqlite"
                        ? """
                            This SQLite experience store retains original experiences, claims, evidence and obligation phases. Preserve their identities and \
                            settlement history.
                            """
                        : """
                            Retain the saved peer contacts, conversations or local-health observations in this file, with their original identities and \
                            recorded states. Preserve credentials, admission and elevation choices exactly; never grant authority or invent a reply.
                            """))
        }
    }

    public func doctorBackgroundLoopsCheck() async -> CheckResult {
        let observations = await port.doctorManager.status()
        let receipts: [String: [DoctorLoopHealth.FailureIncident]]
        do {
            receipts = try await DoctorLoopHealth.recentFailureDates(dataRoot: dataRoot)
        } catch {
            return CheckResult(source: "Loop failure details",
                id: "background_loops", title: "Background loops", status: "fail",
                detail: "Loop failure history is unavailable: \(error.localizedDescription)")
        }
        let now = Date()
        await MainActor.run {
            port.doctorEngine.doctor.loopVerdicts = DoctorLoopHealth.evaluate(
                observations: observations, recentFailureDates: receipts, now: now)
        }
        return DoctorLoopHealth.doctorCheck(
            observations: observations, recentFailureDates: receipts, now: now)
    }

    public func doctorBackgroundLoopChecks() async -> [CheckResult] {
        await DoctorLoopRecovery.checks(
            manager: port.doctorManager,
            dataRoot: dataRoot,
            friendlyLoopName: DoctorPlainCopy.friendlyLoopName
        )
    }

    /// The Body view: the same projection the agent reads in `mind.body`, line for line, deviations first.
    public func doctorOrganPulsesCheck() async -> CheckResult {
        let now = Date()
        let body: OrganBody
        do { body = try await port.doctorManager.organBody(now: now) }
        catch {
            return CheckResult(source: "Organ beats", id: "live.pulses", title: "Body", status: "fail",
                               detail: "The organ beats in experiences/experiences.sqlite could not be read: \(error.localizedDescription).")
        }
        let gaps = body.unreadable.isEmpty ? "" : " Unreadable beats, so unknown: "
            + body.unreadable.sorted { $0.key < $1.key }.map { OrganBody.name($0.key) + " (" + $0.value + ")" }.joined(separator: "; ") + "."
        return CheckResult(source: "Organ beats", id: "live.pulses", title: "Body",
                           status: body.lines.isEmpty && body.unreadable.isEmpty ? "unmeasured"
                               : body.felt.isEmpty && body.unreadable.isEmpty ? "ok" : "warn",
                           detail: (body.lines.isEmpty ? "No organ has a readable beat yet, so nothing else is known about the body."
                               : body.lines.map { $0.words(now: now) }.joined(separator: "; ") + ".") + gaps)
    }

    public func doctorInspectorCheck() async -> CheckResult {
        await port.doctorInspectorCheck()
    }
}
