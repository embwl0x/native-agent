import EngineRuntime
import SelfImprovement
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
import AppToolRuntime

/// A production export is successful only after the archive and its persisted
/// registry receipt agree. Creating an archive alone is not enough for the UI
/// to tell a person that it is ready to use.
enum ProductionExportCreationOutcome: Equatable {
    case verified(ProductionExport)
    case failed(support: Bool, detail: String)
}

@MainActor
extension AppModel {
    @MainActor
    func searchGraph(_ query: String) async {
        let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        do {
            graphSearchResults = try await engine.memory.searchGraph(query: trimmed).results
            statusText = "Graph search found \(graphSearchResults.count)"
        } catch {
            setFailureStatus(error, action: "search the knowledge graph")
        }
    }

    @MainActor
    func refreshGraph() async {
        do {
            let read = try await engine.memory.graphView()
            agentGraph = read.agentGraph
            graphEntities = read.entities
            graphStatus = read.status
            graphLoadError = nil
            statusText = "Knowledge graph refreshed"
        } catch {
            let line = UserFacingError.message(error, action: "refresh the knowledge graph")
            graphLoadError = line
            statusText = line
        }
    }

    @MainActor
    @discardableResult
    func runResearchLab(objective: String) async -> ResearchLabActionOutcome {
        let trimmed = objective.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            let outcome = ResearchLabActionOutcome.rejected("Enter a research objective before starting a run.")
            statusText = CapabilitiesResearchLabPresentation.message(for: outcome).text
            return outcome
        }
        do {
            let run = try await SwiftNativeResearchClient(dataRoot: engine.dataRoot).runResearchLab(objective: trimmed, maxResults: 5)
            engine.desk.researchRuns.removeAll { $0.id == run.id }
            engine.desk.researchRuns.insert(run, at: 0)
            let outcome = ResearchLabActionOutcome.recorded(run)
            statusText = CapabilitiesResearchLabPresentation.message(for: outcome).text
            return outcome
        } catch {
            let outcome = ResearchLabActionOutcome.failed(UserFacingError.cause(error, action: "start the research run"))
            statusText = CapabilitiesResearchLabPresentation.message(for: outcome).text
            return outcome
        }
    }

    /// Reads the exact persisted Research Lab receipt store. A failed read
    /// retains prior rows rather than silently replacing them with an empty run
    /// history, so a panel can distinguish "no runs" from "could not read".
    func refreshResearchLabRunsForCapabilities() async -> CapabilitiesResearchLabPresentation.RunList {
        do {
            let rows = try await engine.desk.listResearchRuns()
            engine.desk.researchRuns = rows
            return CapabilitiesResearchLabPresentation.list(rows: rows)
        } catch {
            return CapabilitiesResearchLabPresentation.unavailableList(
                detail: UserFacingError.cause(error, action: "list research runs"),
                retained: engine.desk.researchRuns
            )
        }
    }

    enum CapabilityCatalogSourceSaveOutcome: Equatable {
        case unavailable(String)
        case refused(String)
        case saved(CapabilityCatalogSource)
        case savedNeedsReload(CapabilityCatalogSource, String)
        case failed(String)

        var didSave: Bool {
            switch self {
            case .saved, .savedNeedsReload: true
            case .unavailable, .refused, .failed: false
            }
        }

        var detail: String {
            switch self {
            case .unavailable(let detail), .refused(let detail), .failed(let detail): return detail
            case .saved(let source): return "Saved \(source.name)."
            case .savedNeedsReload(let source, let detail):
                return "Saved \(source.name), but the catalog could not reload: \(detail)"
            }
        }

        var status: String {
            switch self {
            case .saved: return "ok"
            case .unavailable, .refused, .savedNeedsReload: return "warn"
            case .failed: return "failed"
            }
        }
    }

    @MainActor
    @discardableResult
    func addCatalogSource(name: String, url: String) async -> CapabilityCatalogSourceSaveOutcome {
        guard !capabilityCatalogSourceSaveInFlight else {
            return .unavailable("A catalog source is already being saved.")
        }
        let trimmedName = name.trimmingCharacters(in: .whitespacesAndNewlines)
        let trimmedURL = url.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedName.isEmpty || !trimmedURL.isEmpty else {
            return .refused("Enter a source name or URL before adding it.")
        }
        capabilityCatalogSourceSaveInFlight = true
        defer { capabilityCatalogSourceSaveInFlight = false }
        do {
            let source = try await engine.trust.saveCatalogSource(
                name: trimmedName.isEmpty ? "Capability Source" : trimmedName,
                url: trimmedURL,
                kind: "local"
            )
            do {
                capabilityCatalogSources = try await engine.trust.catalogSources()
            } catch {
                let detail = UserFacingError.cause(error, action: "reload the catalog")
                setFailureStatus("Capability source saved, but the catalog couldn't reload. \(detail)", cause: error)
                return .savedNeedsReload(source, detail)
            }
            statusText = "Capability source saved"
            return .saved(source)
        } catch {
            let detail = UserFacingError.cause(error, action: "save that source")
            setFailureStatus("Couldn't save that source. " + detail, cause: error)
            return .failed(detail)
        }
    }

    @MainActor
    func checkCapabilityUpdates() async {
        do {
            latestCapabilityUpdateCheck = try await engine.trust.checkCapabilityUpdates()
            capabilityCatalogSources = (try? await engine.trust.catalogSources()) ?? capabilityCatalogSources
            statusText = latestCapabilityUpdateCheck?.status == "unavailable"
                ? "Capability update checking is unavailable; source versions are not compared."
                : "Capability updates checked"
        } catch {
            setFailureStatus(error, action: "check for updates")
        }
    }

    @MainActor
    func evaluateCapabilityTrust(_ capability: CapabilityRecord) async {
        do {
            latestCapabilityTrustEvaluation = try await engine.trust.evaluateCapability(id: capability.id)
            engine.trust.capabilityNetwork = try? await engine.trust.loadCapabilityNetwork()
            statusText = "Capability trust evaluated"
        } catch {
            setFailureStatus(error, action: "evaluate that against trust")
        }
    }

    @MainActor
    func runNativeAction(_ action: NativeActionRecord, dryRun: Bool = true) async {
        do {
            _ = try await NativeActionRoutes.runNativeAction(
                id: action.id, dryRun: dryRun, input: [:], dataRoot: dataRootOverride, browser: .app
            )
            nativeActionReceipts = await RuntimeReadProjection.tailJSONL(
                path: NativeActionRoutes.nativeActionReceiptsPath(dataRoot: engine.dataRoot), limit: 50)
            engine.approvals.records = (try? await engine.approvals.list()) ?? engine.approvals.records
            statusText = "Native action recorded"
        } catch {
            setFailureStatus(error, action: "run that action")
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
            let receipt = try await nextGenActionReceipt(id: id, dryRun: dryRun)
            latestNextGenReceipt = receipt
            nextGenReceipts = NextGenStatusProjection.merging([receipt], into: nextGenReceipts)
            if let snapshot = await decodeLogged("nextgen snapshot", {
                try await NextGenStatusProjection(dataRoot: engine.dataRoot).snapshot()
            }) {
                nextGenSummary = snapshot.summary
                nextGenPhases = snapshot.phases
                nextGenReceipts = NextGenStatusProjection.merging([receipt] + snapshot.receipts, into: nextGenReceipts)
            }
            let label = dryRun ? "Next-gen dry run" : "Next-gen action"
            statusText = "\(label): \(latestNextGenReceipt?.displayStatus ?? "recorded")"
            return true
        } catch {
            setFailureStatus(error, action: "run the next-gen probe")
            return false
        }
    }

    @MainActor
    @discardableResult
    func runNextGenAction(_ action: NextGenAction, dryRun: Bool = true) async -> Bool {
        await runNextGenAction(id: action.id, dryRun: dryRun)
    }


    @MainActor
    func runBrowserDryRun(url: String = "https://example.com") async {
        do {
            latestBrowserRun = try await BrowserActionRoutes.app.runBrowser(
                url: url, dryRun: true, captureSource: false, captureScreenshot: false, dataRoot: engine.dataRoot
            )
            browserRuntimeStatus = try? await RuntimeReadProjection.getBrowserStatus(dataRoot: engine.dataRoot)
            statusText = "Browser dry run: \(latestBrowserRun?.status ?? "recorded")"
        } catch {
            setFailureStatus("Browser run failed: " + UserFacingError.cause(error, action: "run the browser"), cause: error)
        }
    }

    @MainActor
    func cancelBrowserRun() async {
        do {
            latestBrowserRun = try await BrowserActionRoutes.app.cancelBrowserRun(id: latestBrowserRun?.id, dataRoot: engine.dataRoot)
            browserRuntimeStatus = try? await RuntimeReadProjection.getBrowserStatus(dataRoot: engine.dataRoot)
            statusText = "Browser run \(latestBrowserRun?.status ?? "canceled")"
        } catch {
            setFailureStatus(error, action: "cancel the browser run")
        }
    }

    @MainActor
    func showVisibleBrowser() async {
        BrowserWindowController.shared.showWindow()
        browserRuntimeStatus = try? await RuntimeReadProjection.getBrowserStatus(dataRoot: engine.dataRoot)
        statusText = "Visible Browser opened."
    }

    @MainActor
    func runConnectorAction(_ action: ConnectorActionRecord) async {
        do {
            latestConnectorActionReceipt = try await ConnectorActions(platform: AppConnectorActionPlatform(dataRoot: engine.dataRoot))
                .runConnectorAction(id: action.id, dryRun: true)
            connectorActionRegistry = try? await ConnectorActionRegistry.read(dataRoot: engine.dataRoot, platform: AppConnectorStatusPlatform())
            statusText = "Connector action: \(latestConnectorActionReceipt?.status ?? "recorded")"
        } catch {
            setFailureStatus(error, action: "run that connector action")
        }
    }

    @MainActor
    func runImprovementGauntlet() async {
        do {
            latestGauntletRun = try await ImprovementGauntletRun.run(dataRoot: engine.dataRoot)
            improvementGauntletStatus = try? await RuntimeReadProjection.swiftImprovementGauntlet(dataRoot: engine.dataRoot)
            statusText = "Gauntlet: \(latestGauntletRun?.status ?? "recorded")"
        } catch {
            setFailureStatus("Gauntlet failed: " + UserFacingError.cause(error, action: "run the gauntlet"), cause: error)
        }
    }

    @MainActor
    func installDemoCapabilityPack() async {
        guard !isInstallingDemoCapabilityPack else { return }
        isInstallingDemoCapabilityPack = true
        defer { isInstallingDemoCapabilityPack = false }
        do {
            let receipt = try await NativeSkillRegistryActions.installDemoCapabilityPack(dataRoot: engine.dataRoot)
            disabledFeature = nil
            let name = receipt.name ?? receipt.packId
            capabilityCatalogInstallOutcome = .installed(name: name)
            statusText = "Installed signed pack \(name)"
            await refreshAll()
        } catch let err as NSError where AppModel.isNotImplemented(err) {
            disabledFeature = AppModel.disabledBadge(for: "Demo capability pack install", error: err)
            capabilityCatalogInstallOutcome = .refused(
                message: disabledFeature ?? "Demo capability pack install is disabled."
            )
            statusText = capabilityCatalogInstallOutcome?.message ?? "Pack install refused"
        } catch {
            capabilityCatalogInstallOutcome = .refused(message: UserFacingError.cause(error, action: "install the pack"))
            statusText = capabilityCatalogInstallOutcome?.message ?? "Pack install refused"
        }
    }

    @MainActor
    func rollbackCapabilityPack(_ install: CapabilityPackInstall) async {
        do {
            _ = try await CapabilityPackInstall.rollback(id: install.id, dataRoot: engine.dataRoot)
            statusText = "Rolled back \(install.name ?? install.packId)"
            await refreshAll()
        } catch {
            setFailureStatus(error, action: "roll that back")
        }
    }

    @MainActor
    func createProductionExport(support: Bool = false) async -> ProductionExportCreationOutcome {
        let label = support ? "Support bundle" : "Export"
        let root = engine.dataRoot
        do {
            let export = support
                ? try await ProductionExport.createSupportBundle(
                    dataRoot: root, host: .app, runProcess: SystemProcessAdapter.runBounded,
                    diagnostics: { @Sendable in try await SupportDiagnostics.read(reusingChecks: nil) },
                    health: { @Sendable in DoctorFacade(dataRoot: root).readHealth() }
                )
                : try await ProductionExport.createArchive(
                    dataRoot: root, host: .app, runProcess: SystemProcessAdapter.runBounded
                ) { @Sendable in try await DoctorStatusProjection.getProductionHardening(dataRoot: root) }
            let verification = try await export.verifyRegistry(dataRoot: root)
            if let detail = verification.failure {
                statusText = "\(label) failed verification: \(detail)"
                return .failed(support: support, detail: detail)
            }
            productionExports = verification.records
            statusText = "\(label) created and verified: \(export.id)"
            return .verified(export)
        } catch {
            let detail = UserFacingError.cause(error, action: "create the \(label.lowercased())")
            statusText = "\(label) failed: \(detail)"
            return .failed(support: support, detail: detail)
        }
    }


}
