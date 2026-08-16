import Foundation
import Observation
import Darwin
import AppKit
@preconcurrency import EventKit
import SwiftUI
import NativeAgentShared
import PersistenceCore
import NativeAgentCore
import MemoryV2
import ToolRegistry
import KnowledgeGraph
import XConnector
import SlackConnector
import ProviderRouting
import BackgroundLoops
import ApprovalInbox
import MCPDispatcher
import ToolExecution
import PersonaEngine
import ChatOrchestration
import TrustCenter
import DreamREMCycle
import DoctorChecks
import CommandPalette
import SelfImprovement
import Research
import MultimodalTTS
import TriggerScheduler
import WorkshopExecution
import NotificationInbox
import SystemOps
import ScreenVision
import TelegramBot
import Dispatcher
import MacControl
import Onboarding
import MacAssistantStatus
import WorkflowOrchestration
import Skills
import Connectors
import Browser

@MainActor
extension AppModel {
    @MainActor
    func searchGraph(_ query: String) async {
        let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        do {
            graphSearchResults = try await client.searchGraph(query: trimmed).results
            statusText = "Graph search found \(graphSearchResults.count)"
        } catch {
            statusText = "Graph search failed: \(error.localizedDescription)"
        }
    }

    @MainActor
    func refreshGraph() async {
        do {
            agentGraph = try await client.getAgentGraph()
            graphEntities = try await client.getGraphEntities()
            graphStatus = try await client.getGraphStatus()
            statusText = "Knowledge graph refreshed"
        } catch {
            statusText = "Knowledge graph refresh failed: \(error.localizedDescription)"
        }
    }

    @MainActor
    func runResearchLab(objective: String) async {
        let trimmed = objective.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        do {
            _ = try await client.runResearchLab(objective: trimmed)
            statusText = "Research lab run recorded"
            await refreshAll()
        } catch {
            statusText = "Research lab failed: \(error.localizedDescription)"
        }
    }

    @MainActor
    func addCatalogSource(name: String, url: String) async {
        let trimmedName = name.trimmingCharacters(in: .whitespacesAndNewlines)
        let trimmedURL = url.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedName.isEmpty || !trimmedURL.isEmpty else { return }
        do {
            _ = try await client.upsertCatalogSource(name: trimmedName.isEmpty ? "Capability Source" : trimmedName, url: trimmedURL, kind: "local")
            capabilityCatalogSources = (try? await client.getCapabilityCatalogSources()) ?? capabilityCatalogSources
            statusText = "Capability source saved"
        } catch {
            statusText = "Source save failed: \(error.localizedDescription)"
        }
    }

    @MainActor
    func checkCapabilityUpdates() async {
        do {
            latestCapabilityUpdateCheck = try await client.checkCapabilityUpdates()
            capabilityCatalogSources = (try? await client.getCapabilityCatalogSources()) ?? capabilityCatalogSources
            statusText = "Capability updates checked"
        } catch {
            statusText = "Update check failed: \(error.localizedDescription)"
        }
    }

    @MainActor
    func evaluateCapabilityTrust(_ capability: CapabilityRecord) async {
        do {
            latestCapabilityTrustEvaluation = try await client.evaluateCapabilityTrust(id: capability.id)
            capabilityTrust = try? await client.getCapabilityTrust()
            statusText = "Capability trust evaluated"
        } catch {
            statusText = "Trust evaluate failed: \(error.localizedDescription)"
        }
    }

    @MainActor
    func runNativeAction(_ action: NativeActionRecord, dryRun: Bool = true) async {
        do {
            _ = try await client.runNativeAction(id: action.id, dryRun: dryRun)
            nativeActionReceipts = (try? await client.getNativeActionReceipts()) ?? nativeActionReceipts
            approvals = (try? await client.getApprovals()) ?? approvals
            statusText = "Native action recorded"
        } catch {
            statusText = "Native action failed: \(error.localizedDescription)"
        }
    }

    @MainActor
    @discardableResult
    func runNextGenAction(id: String, dryRun: Bool = true) async -> Bool {
        guard !id.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return false }
        guard !isRunningNextGenAction else { return false }

        isRunningNextGenAction = true
        defer { isRunningNextGenAction = false }

        do {
            let result = try await client.runNextGenAction(id: id, dryRun: dryRun)
            latestNextGenReceipt = result.displayReceipt
            // U5 W-A item 1 (:2944): the post-action refresh fell back
            // stale-then-empty via bare `try?` — a failed refresh rendered
            // as healthy receipts with no signal. decodeLogged keeps the
            // stale fallback but records the real error.
            nextGenSummary = await decodeLogged("getNextGenSummary") {
                try await client.getNextGenSummary()
            } ?? nextGenSummary
            nextGenPhases = await decodeLogged(
                "getNextGenPhases", default: nextGenSummary?.phases ?? nextGenPhases
            ) {
                try await client.getNextGenPhases()
            }
            let refreshedReceipts = await decodeLogged(
                "getNextGenReceipts", default: nextGenSummary?.displayReceipts ?? []
            ) {
                try await client.getNextGenReceipts()
            }
            mergeNextGenReceipts([result.displayReceipt] + refreshedReceipts)
            let label = dryRun ? "Next-gen dry run" : "Next-gen action"
            statusText = "\(label): \(latestNextGenReceipt?.displayStatus ?? "recorded")"
            return true
        } catch {
            statusText = "Next-gen probe failed: \(error.localizedDescription)"
            return false
        }
    }

    @MainActor
    @discardableResult
    func runNextGenAction(_ action: NextGenAction, dryRun: Bool = true) async -> Bool {
        await runNextGenAction(id: action.id, dryRun: dryRun)
    }

    private func mergeNextGenReceipts(_ receipts: [NextGenReceipt]) {
        var seen = Set<String>()
        nextGenReceipts = (receipts + nextGenReceipts).filter { seen.insert($0.id).inserted }
    }

    @MainActor
    func runBrowserDryRun(url: String = "https://example.com") async {
        do {
            latestBrowserRun = try await client.runBrowser(url: url, dryRun: true)
            browserRuntimeStatus = try? await client.getBrowserStatus()
            statusText = "Browser dry run: \(latestBrowserRun?.status ?? "recorded")"
        } catch {
            statusText = "Browser run failed: \(error.localizedDescription)"
        }
    }

    @MainActor
    func cancelBrowserRun() async {
        do {
            latestBrowserRun = try await client.cancelBrowserRun(id: latestBrowserRun?.id)
            browserRuntimeStatus = try? await client.getBrowserStatus()
            statusText = "Browser run \(latestBrowserRun?.status ?? "canceled")"
        } catch {
            statusText = "Browser cancel failed: \(error.localizedDescription)"
        }
    }

    @MainActor
    func showVisibleBrowser() async {
        BrowserWindowController.shared.showWindow()
        browserRuntimeStatus = try? await client.getBrowserStatus()
        statusText = "Visible Browser opened."
    }

    @MainActor
    func runConnectorAction(_ action: ConnectorActionRecord) async {
        do {
            latestConnectorActionReceipt = try await client.runConnectorAction(id: action.id, dryRun: true)
            connectorActionRegistry = try? await client.getConnectorActions()
            statusText = "Connector action: \(latestConnectorActionReceipt?.status ?? "recorded")"
        } catch {
            statusText = "Connector action failed: \(error.localizedDescription)"
        }
    }

    @MainActor
    func runImprovementGauntlet() async {
        do {
            latestGauntletRun = try await client.runImprovementGauntlet()
            improvementGauntletStatus = try? await client.getImprovementGauntlet()
            statusText = "Gauntlet: \(latestGauntletRun?.status ?? "recorded")"
        } catch {
            statusText = "Gauntlet failed: \(error.localizedDescription)"
        }
    }

    @MainActor
    func installDemoCapabilityPack() async {
        do {
            let receipt = try await client.installDemoCapabilityPack()
            disabledFeature = nil
            statusText = "Installed signed pack \(receipt.name ?? receipt.packId)"
            await refreshAll()
        } catch let err as NSError where AppModel.isNotImplemented(err) {
            disabledFeature = AppModel.disabledBadge(for: "Demo capability pack install", error: err)
            statusText = disabledFeature ?? "Pack install disabled"
        } catch {
            statusText = "Pack install failed: \(error.localizedDescription)"
        }
    }

    @MainActor
    func rollbackCapabilityPack(_ install: CapabilityPackInstall) async {
        do {
            _ = try await client.rollbackCapabilityPack(id: install.id)
            statusText = "Rolled back \(install.name ?? install.packId)"
            await refreshAll()
        } catch {
            statusText = "Rollback failed: \(error.localizedDescription)"
        }
    }

    @MainActor
    func createProductionExport(support: Bool = false) async {
        do {
            let export = support ? try await client.createSupportBundle() : try await client.createProductionExport()
            statusText = "\(support ? "Support bundle" : "Export") created: \(export.id)"
            await refreshAll()
        } catch {
            statusText = "Export failed: \(error.localizedDescription)"
        }
    }

    @MainActor
    func startImprovement(objective: String) async {
        let trimmed = objective.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        do {
            _ = try await client.startImprovement(objective: trimmed)
            statusText = "Improvement started"
            await refreshAll()
        } catch {
            statusText = "Improvement failed: \(error.localizedDescription)"
        }
    }

    @MainActor
    func createRecurringImprovement(objective: String, intervalSeconds: Int) async {
        let trimmed = objective.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        do {
            _ = try await client.createRecurringImprovement(objective: trimmed, intervalSeconds: intervalSeconds)
            statusText = "Continuous self-improvement scheduled"
            await refreshAll()
        } catch {
            statusText = "Recurring improvement failed: \(error.localizedDescription)"
        }
    }

    @MainActor
    func cleanupImprovementNoise() async {
        do {
            let result = try await client.cleanupImprovementNoise()
            statusText = "Cleaned \(result.removedJobs) smoke job(s), \(result.removedInterruptedTestRuns) test run(s), repaired \(result.repairedReceiptFailures)"
            await refreshAll()
        } catch {
            statusText = "Improvement cleanup failed: \(error.localizedDescription)"
        }
    }

    @MainActor
    func runHarnessBenchmark() async {
        do {
            let result = try await client.runHarnessBenchmark()
            let passed = result.checks?.filter { $0.passed == true }.count ?? 0
            let total = result.checks?.count ?? 0
            statusText = "Harness benchmark \(result.status ?? "completed"): \(passed)/\(total) checks"
            improvementSummary = try? await client.getImprovementSummary()
        } catch {
            statusText = "Harness benchmark failed: \(error.localizedDescription)"
        }
    }

    // PATCH-2026-05-08: improve-review-loop — AppModel wrappers for diff/promote/discard
    @MainActor
    func loadImprovementDiff(runId: String) async throws -> ImprovementDiffPayload {
        try await client.getImprovementDiff(runId: runId)
    }

    @MainActor
    func promoteImprovement(runId: String) async throws -> ImprovementPromoteResult {
        let result = try await client.promoteImprovement(runId: runId)
        if result.ok {
            statusText = "Promoted run \(runId.prefix(8)) — commit \(result.commitSha?.prefix(8) ?? "?")"
        } else {
            statusText = "Promote failed: \(result.error ?? "unknown error")"
        }
        improvements = (try? await client.getImprovements()) ?? improvements
        improvementSummary = try? await client.getImprovementSummary()
        return result
    }

    @MainActor
    func discardImprovement(runId: String) async throws -> ImprovementRevertResult {
        let result = try await client.discardImprovement(runId: runId)
        if result.ok {
            statusText = "Run \(runId.prefix(8)) discarded"
        } else {
            statusText = "Discard failed: \(result.error ?? "unknown error")"
        }
        improvements = (try? await client.getImprovements()) ?? improvements
        improvementSummary = try? await client.getImprovementSummary()
        return result
    }

    @MainActor
    func revertImprovement(runId: String) async throws -> ImprovementRevertResult {
        let result = try await client.revertImprovement(runId: runId)
        if result.ok {
            statusText = "Reverted run \(runId.prefix(8)) — revert commit \(result.revertCommitSha?.prefix(8) ?? "?")"
        } else {
            statusText = "Revert failed: \(result.error ?? "unknown error")"
        }
        improvements = (try? await client.getImprovements()) ?? improvements
        improvementSummary = try? await client.getImprovementSummary()
        return result
    }

    // PATCH-2026-05-08: no-terminal-moments — AppModel wrappers
    @MainActor
    func runFullRebuild() async {
        do {
            let result = try await client.systemRebuild()
            statusText = result.message ?? (result.ok ? "Rebuild started" : result.error ?? "Rebuild failed")
        } catch {
            // If the in-process rebuild call fails, fall back to spawning
            // install_app.sh directly so the user can still recover.
            statusText = "Rebuild failed (\(error.localizedDescription)) — running install_app.sh directly"
            _spawnInstallScriptDirectly()
        }
    }

    @MainActor
    private func _spawnInstallScriptDirectly() {
        guard !directInstallInFlight else {
            statusText = "Install already running..."
            return
        }
        directInstallInFlight = true
        let stampedRepo = Bundle.main.resourceURL
            .map { $0.appendingPathComponent("REPO_PATH") }
            .flatMap { try? String(contentsOf: $0, encoding: .utf8).trimmingCharacters(in: .whitespacesAndNewlines) }
            .flatMap { NativeAgentPaths.validateStampedPath(URL(fileURLWithPath: $0, isDirectory: true)) }
        let installScript = (stampedRepo ?? FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Projects/NativeAgent"))
            .appendingPathComponent("script/install_app.sh")
        guard FileManager.default.isExecutableFile(atPath: installScript.path) else {
            statusText = "Reinstall requires a valid NativeAgent source checkout or REPO_PATH stamp. Use the updater or reinstall from the app bundle."
            directInstallInFlight = false
            return
        }
        let task = Process()
        task.executableURL = URL(fileURLWithPath: "/bin/bash")
        task.arguments = [installScript.path]
        let ts = ISO8601DateFormatter().string(from: Date())
        let safeTs = ts.replacingOccurrences(of: ":", with: "-")
        let logDir = NativeAgentPaths.dataRoot.appendingPathComponent("logs", isDirectory: true)
        try? FileManager.default.createDirectory(at: logDir, withIntermediateDirectories: true)
        let logURL = logDir.appendingPathComponent("install-fallback-\(safeTs).log")
        FileManager.default.createFile(atPath: logURL.path, contents: nil)
        let logHandle = FileHandle(forWritingAtPath: logURL.path)
        let nullInput = FileHandle(forReadingAtPath: "/dev/null")
        task.standardInput = nullInput
        task.standardOutput = logHandle ?? FileHandle.nullDevice
        task.standardError = logHandle ?? FileHandle.nullDevice
        // S.1: Use a minimal explicit environment to prevent leaking sensitive
        // vars from launchd / the dev shell into the install script.
        // PATCH-2026-05-08: review-fix-r8 Pass through TZ if set so install logs
        // and date stamps match the user's clock.
        var minimalEnv: [String: String] = [
            "PATH":    "/usr/local/bin:/usr/bin:/bin:/opt/homebrew/bin",
            "HOME":    NSHomeDirectory(),
            "USER":    NSUserName(),
            "LANG":    "en_US.UTF-8",
            "TMPDIR":  NSTemporaryDirectory(),
        ]
        if let tz = ProcessInfo.processInfo.environment["TZ"], !tz.isEmpty {
            minimalEnv["TZ"] = tz
        }
        task.environment = minimalEnv
        do {
            try task.run()
        } catch {
            try? logHandle?.close()
            try? nullInput?.close()
            directInstallInFlight = false
            statusText = "Failed to spawn install_app.sh: \(error.localizedDescription)"
            return
        }
        try? logHandle?.close()
        try? nullInput?.close()
        statusText = "Installer started detached — NativeAgent will relaunch. Log: \(logURL.lastPathComponent)"
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.0) {
            NSApp.terminate(nil)
        }
    }

    @MainActor
    func pushToRemote() async -> GitPushResult? {
        do {
            return try await client.gitPush()
        } catch let nsErr as NSError where nsErr.code == 409 {
            // No remote configured — graceful, not scary
            return GitPushResult(ok: false, branch: nil, output: nil, error: "No GitHub remote configured")
        } catch {
            return GitPushResult(ok: false, branch: nil, output: nil, error: error.localizedDescription)
        }
    }

    @MainActor
    func recoverStash(label: String) async -> GitStashRecoverResult? {
        do {
            return try await client.gitStashRecover(label: label)
        } catch {
            return GitStashRecoverResult(ok: false, stashRef: nil, output: nil, error: error.localizedDescription)
        }
    }

}
