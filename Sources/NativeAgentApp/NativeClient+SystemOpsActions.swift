import Privacy
import Foundation
import PersistenceCore
import DoctorChecks
import ProviderRouting
import SystemOps
import MacControl
import Research

extension NativeClient {
    private var doctorActions: DoctorActionRuntime<NativeClient> {
        DoctorActionRuntime(port: self)
    }

    func runDoctor(repair: Bool = false, repairScope: DoctorRepairScope = .automatic) async throws -> DoctorReport {
        let result = try await doctorActions.runDoctor(repair: repair, repairScope: repairScope, checks: makeDoctorChecks())
        return DoctorReport(status: result.status, repaired: result.repaired, checks: result.checks)
    }

    func liveDoctorCoverageChecks() async -> [CheckResult] {
        await doctorActions.liveDoctorCoverageChecks()
    }

    static func safeDoctorDetail(_ value: String) -> String {
        DoctorActionRuntime<NativeClient>.safeDetail(value, redact: NativeAppSecretRedactor.redactText)
    }

    static func doctorRollup(_ statuses: [String]) -> String {
        DoctorStatusProjection.doctorRollup(statuses)
    }

    static func mergeDoctorReport(_ current: DoctorReport, liveChecks: [CheckResult]) -> DoctorReport {
        let result = DoctorActionRuntime<NativeClient>.mergeReport(
            currentChecks: current.checks, liveChecks: liveChecks
        )
        return DoctorReport(status: result.status, repaired: current.repaired, checks: result.checks)
    }

    func systemRebuild() async throws -> SystemRebuildResult {
        // WAVE 15 (2026-06-01): Swift-only — daemon route retired.
        let impl = makeSystemRebuildClient()
        let r = try await impl.systemRebuild()
        return SystemRebuildResult(ok: r.ok, message: r.message, error: r.error)
    }

    func gitPush() async throws -> GitPushResult {
        let result = try await SystemGitActions.gitPush { arguments, repoRoot, timeout in
            try await Self.runGit(arguments, repoRoot: repoRoot, timeout: timeout)
        }
        return GitPushResult(ok: result.ok, branch: result.branch, output: result.output, error: result.error)
    }

    static func runGit(
        _ arguments: [String],
        repoRoot: URL,
        timeout: TimeInterval
    ) async throws -> (status: Int32, stdout: String, stderr: String) {
        try await runProcess(
            executable: "/usr/bin/git",
            arguments: arguments,
            currentDirectory: repoRoot,
            timeout: timeout
        )
    }

    static func runProcess(
        executable: String,
        arguments: [String],
        currentDirectory: URL,
        timeout: TimeInterval
    ) async throws -> (status: Int32, stdout: String, stderr: String) {
        let result = try await SystemProcessAdapter().run(
            executable: executable,
            arguments: arguments,
            currentDirectory: currentDirectory,
            environment: nil,
            standardInput: nil,
            timeoutSeconds: timeout
        )
        if result.timedOut {
            let stderr = result.stderr.isEmpty
                ? "\(URL(fileURLWithPath: executable).lastPathComponent) command timed out"
                : result.stderr
            return (124, result.stdout, stderr)
        }
        return (result.exitCode, result.stdout, result.stderr)
    }

    static func processDetail(_ result: (status: Int32, stdout: String, stderr: String)) -> String {
        SystemGitActions.processDetail(result)
    }

    func gitStashRecover(label: String) async throws -> GitStashRecoverResult {
        // WAVE 15 (2026-06-01): Swift-only — daemon route retired.
        let impl = makeGitStashRecoverClient()
        let r = try await impl.gitStashRecover(label: label)
        return GitStashRecoverResult(ok: r.ok, stashRef: r.stashRef, output: r.output, error: r.error)
    }
}

extension NativeClient: DoctorActionPort {
    func doctorEmbeddingDownloadCheck() async -> CheckResult {
        await DoctorEmbeddingDownloadCheck.read(dataRoot: dataRootOverride ?? PersistenceCore.defaultDataRoot())
    }

    func doctorProviderAuthStates() async throws -> [String] {
        try await ProvidersFacade(dataRoot: dataRootOverride ?? PersistenceCore.defaultDataRoot())
            .list().map { $0.auth_status.state }
    }

    func doctorProviderRuntimeReading() async -> DoctorProviderRuntimeReading {
        await DoctorProviderPathReading.read(dataRoot: dataRootOverride ?? PersistenceCore.defaultDataRoot())
    }

    func doctorProviderProbeReading() -> DoctorProviderProbeReading {
        switch LLMProviderStatusFeed.read(dataRoot: dataRootOverride ?? PersistenceCore.defaultDataRoot()) {
        case .current: return .current
        case .stale(let record): return .stale(record.providerID)
        case .unavailable(let detail): return .unavailable(detail)
        case .failed(let detail): return .failed(detail)
        }
    }

    func doctorTelegramSnapshot() async throws -> DoctorTelegramSnapshot {
        let manager = backgroundLoopsManager.coreManager
        let status = try await TelegramFacade(
            dataRoot: dataRootOverride ?? PersistenceCore.defaultDataRoot()
        ).load(manager: manager)
        let now = Date()
        let uptime = await manager.uptimeSeconds(now: now)
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        let pollDate = status.lastPollAt.flatMap {
            formatter.date(from: $0) ?? ISO8601DateFormatter().date(from: $0)
        }
        // A normal poll holds up to 25 seconds, then waits for the next tick.
        // Require both current-manager-lifecycle evidence and a bounded age.
        let fresh = pollDate.map {
            let age = now.timeIntervalSince($0)
            return age >= 0 && age <= 35 && age < uptime
        } ?? false
        let starting = status.pollerEnabled && uptime > 0 && uptime <= 35 && !fresh
        return (status.enabled, status.tokenConfigured, status.isTransientPollInterruption, status.actionableError, status.pollerEnabled, fresh, starting)
    }

    func doctorSearchURL() async throws -> String? {
        try await getConfig().searxngBaseURL
    }

    func doctorProbeSearch(base: String) async -> Bool {
        await SwiftNativeResearchClient(dataRoot: dataRootOverride ?? PersistenceCore.defaultDataRoot())
            .checkSearXNG(base: base)
    }

    private func doctorSearchContainerName() async throws -> String? {
        // Discovery/configuration records only an endpoint, not ownership.
        // No app provisioning path currently records a container name; keep
        // the human action unless ownership was explicitly configured.
        let path = (dataRootOverride ?? PersistenceCore.defaultDataRoot())
            .appendingPathComponent("research/config.json")
        let config = try await SwiftNativePersistenceCore().readJSON(path, ifMissing: .object([:]))
        guard case .object(let fields) = config,
              case .string(let name) = fields["searxng_container_name"],
              !name.isEmpty else { return nil }
        return name
    }

    func doctorRecordRepair(checkID: String, receipt: String, status: String) async throws {
        let path = (dataRootOverride ?? PersistenceCore.defaultDataRoot())
            .appendingPathComponent("doctor/repair_receipts.jsonl")
        try await SwiftNativePersistenceCore().appendJSONL(.object([
            "at": .string(ISO8601DateFormatter().string(from: Date())),
            "check_id": .string(checkID), "receipt": .string(receipt), "status": .string(status),
        ]), to: path)
    }

    func doctorLiveRepair(for check: CheckResult, scope: DoctorRepairScope) async -> DoctorExecutableRepair? {
        let requestedRoot = dataRootOverride ?? PersistenceCore.defaultDataRoot()
        guard requestedRoot.resolvingSymlinksInPath().standardizedFileURL
            == PersistenceCore.defaultDataRoot().resolvingSymlinksInPath().standardizedFileURL else { return nil }
        switch check.id {
        case "live.providers":
            guard scope == .button else { return nil }
            let pendingPath = requestedRoot.appendingPathComponent("providers/pending-surface-configuration.json")
            let pendingSelection = FileManager.default.fileExists(atPath: pendingPath.path)
            let needsProbe: Bool
            switch doctorProviderProbeReading() {
            case .current: needsProbe = false
            case .unavailable: needsProbe = false
            case .stale, .failed: needsProbe = true
            }
            guard pendingSelection || needsProbe else { return nil }
            if !pendingSelection {
                guard let snapshot = try? await SwiftNativeProviderRouting(dataRoot: requestedRoot)
                    .checkedRoutingSnapshotReadOnly(),
                    ProviderRoutingSurfaceLookup.value(snapshot.activeProviders, "chat") != nil else { return nil }
            }
            return DoctorExecutableRepair(checkID: check.id) {
                do {
                    let routing = SwiftNativeProviderRouting(dataRoot: requestedRoot)
                    let snapshot = try await (FileManager.default.fileExists(atPath: pendingPath.path)
                        ? routing.checkedRoutingSnapshot()
                        : routing.checkedRoutingSnapshotReadOnly())
                    guard let providerID = ProviderRoutingSurfaceLookup.value(snapshot.activeProviders, "chat") else {
                        let row = await doctorActions.providerDoctorCoverageCheck()
                        return .unverified("Repair could not test the active provider: \(row.detail)")
                    }
                    let test = try await testProvider(providerID)
                    // Same verdict the Providers page uses for Test Connection.
                    guard test.tested && test.status == "ok" else {
                        return .unverified("Repair attempted: the \(providerID) connection test did not pass: \(Self.safeDoctorDetail(test.detail ?? test.error ?? test.status))")
                    }
                    let row = await doctorActions.providerDoctorCoverageCheck()
                    return row.status == "ok"
                        ? .completed("Completed: recovered provider selection if needed and checked the active provider connection.")
                        : .unverified("Repair attempted: \(row.detail)")
                } catch {
                    let row = await doctorActions.providerDoctorCoverageCheck()
                    return .unverified("Repair could not finish: \(Self.safeDoctorDetail(error.localizedDescription)) \(row.detail)")
                }
            }
        case "live.inspector_feed":
            return await doctorInspectorRepair(for: check)
        case DoctorEmbeddingDownloadCheck.id:
            return await DoctorEmbeddingDownloadCheck.repair(dataRoot: requestedRoot, scope: scope)
        case "live.search":
            guard let base = try? await doctorSearchURL(),
                  let name = try? await doctorSearchContainerName(),
                  let container = await SystemDockerPSExecutor().stoppedLocalSearXNG(base: base, containerName: name) else { return nil }
            return DoctorExecutableRepair(checkID: check.id) {
                guard try await doctorSearchURL() == base,
                      try await doctorSearchContainerName() == name else {
                    return .unverified("Repair skipped: the configured SearXNG URL or container name changed.")
                }
                try await SystemDockerPSExecutor().restartLocalSearXNG(base: base, containerName: name, containerID: container)
                try await Task.sleep(for: .seconds(2))
                return .completed("Completed: restarted the identified local SearXNG container \(container.prefix(12)); checking the configured endpoint again.")
            }
        case "live.background_loops":
            return nil
        case "live.telegram":
            guard let state = try? await doctorTelegramSnapshot(), state.enabled,
                  state.tokenConfigured, !state.pollerEnabled else { return nil }
            return DoctorExecutableRepair(checkID: check.id) {
                let facade = TelegramFacade(dataRoot: dataRootOverride ?? PersistenceCore.defaultDataRoot())
                let manager = backgroundLoopsManager.coreManager
                let before = try await facade.load(manager: manager)
                guard before.enabled, before.tokenConfigured else {
                    return .unverified("Repair skipped: Telegram configuration changed.")
                }
                if !(await manager.registered().contains("telegram_poll")) {
                    let outcome = await backgroundLoopsManager.restartLoop(id: "telegram_poll")
                    guard outcome.didRestart else {
                        return .unverified("Repair failed: \(outcome.surfaceMessage ?? "Telegram poller could not restart.")")
                    }
                }
                _ = await manager.start()
                // Observe the owner's ordinary bounded long poll, never send
                // a second getUpdates request or force a duplicate tick.
                let deadline = ContinuousClock.now.advanced(by: .seconds(35))
                repeat {
                    let after = try await facade.load(manager: manager)
                    if after.lastPollAt != nil, after.lastPollAt != before.lastPollAt,
                       after.pollerEnabled, after.actionableError == nil {
                        return .completed("Completed: restarted Telegram's poller and confirmed a successful poll.")
                    }
                    try await Task.sleep(for: .seconds(1))
                } while ContinuousClock.now < deadline
                return .unverified("Repair attempted: Telegram's poller was started, but no successful poll was confirmed within 35 seconds.")
            }
        case "live.bridges":
            let names = await doctorBridgeSnapshots().filter {
                $0.expected && $0.health.boundPort == nil && !$0.health.isActive
            }.map(\.name)
            guard !names.isEmpty else { return nil }
            return DoctorExecutableRepair(checkID: check.id) {
                // Start methods retain their own gates, callbacks and tokens.
                for name in names {
                    switch name {
                    case "ClaudeBridge": await ClaudeBridge.shared.startServer()
                    case "MacControlBridge": MacControlBridge.shared.start()
                    case "BrowserIPC": await BrowserWindowController.shared.startIPCServer()
                    default: break
                    }
                }
                let deadline = ContinuousClock.now.advanced(by: .seconds(3))
                repeat {
                    let rows = await doctorBridgeSnapshots().filter { names.contains($0.name) }
                    if rows.allSatisfy({ $0.health.boundPort != nil }) {
                        return .completed("Completed: rebound \(names.joined(separator: ", ")) and verified the listening ports.")
                    }
                    try await Task.sleep(for: .milliseconds(100))
                } while ContinuousClock.now < deadline
                return .unverified("Repair attempted: \(names.joined(separator: ", ")) did not confirm a bound port within 3 seconds.")
            }
        case DoctorLoopHealth.doctorCheckID:
            return await DoctorLoopHealth.safeRepair(manager: backgroundLoopsManager.coreManager)
        case let id where id.hasPrefix(DoctorLoopRecovery.checkPrefix):
            return await DoctorLoopRecovery.repair(
                checkID: check.id,
                manager: backgroundLoopsManager,
                dataRoot: requestedRoot
            )
        default: return await doctorCognitionRepair(for: check)
        }
    }

    func doctorToolSnapshots() async throws -> [DoctorToolSnapshot] {
        try await ToolsFacade(dataRoot: dataRootOverride ?? PersistenceCore.defaultDataRoot())
            .listAuthored().map { ($0.status, $0.name) }
    }

    func doctorAutonomySnapshot() async throws -> DoctorAutonomySnapshot {
        let status = try await getAutonomyKernel()
        return (status.enabled, status.disabledReason, status.status, status.mode, status.runningImprovements)
    }

    func doctorBridgeSnapshots() async -> [DoctorBridgeSnapshot] {
        let browserIPC = await BrowserWindowController.shared.ipcListenerHealth
        let bridges: [(name: String, health: NativeLoopbackListener.Health, expected: Bool)] = [
            ("ClaudeBridge", ClaudeBridge.shared.listenerHealth, true),
            ("MacControlBridge", MacControlBridge.shared.listenerHealth, MacControlBridge.startGateAllows()),
            ("BrowserIPC", browserIPC, true),
        ]
        return bridges.map { ($0.name, ($0.health.failure, $0.health.boundPort, $0.health.isActive, $0.health.port), $0.expected) }
    }

    func doctorBackgroundLoopsCheck() async -> CheckResult {
        await DoctorLoopHealth.doctorCheck(
            dataRoot: dataRootOverride ?? PersistenceCore.defaultDataRoot()
        )
    }

    func doctorBackgroundLoopChecks() async -> [CheckResult] {
        await DoctorLoopRecovery.checks(
            manager: backgroundLoopsManager,
            dataRoot: dataRootOverride ?? PersistenceCore.defaultDataRoot()
        )
    }

    func redactDoctorDetail(_ value: String) -> String {
        NativeAppSecretRedactor.redactText(value)
    }
}
