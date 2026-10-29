import Foundation
import NativeAgentShared
import NativeAgentCore
import EngineRuntime
import MemoryV2
import ToolExecution
import TrustCenter
import ChatToolParsing
import Research
import SystemOps
import MacControl
import TrustPersistence
import DoctorChecks
import Browser
import AppToolRuntime
import Senses
// Blueprint: | `AppModel+GraphCapabilityActions.swift` | `AppModel`: `searchGraph`, `refreshGraph`, `runResearchLab`; Lab's frozen evidence calls the editable `research-lab` part through `Parts.call` and the canonical admission-only gate; native Research commits the accepted proposal |

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
        _ = await graphSearchRead.read({ () async -> Result<[GraphSearchResult], Error> in
            do { return Result.success(try await engine.memory.searchGraph(query: trimmed).results) }
            catch { return Result<[GraphSearchResult], Error>.failure(error) }
        }, publish: { result in
        do {
            graphSearchResults = try result.get()
            statusText = "Graph search found \(graphSearchResults.count)"
        } catch {
            setFailureStatus(error, action: "search the knowledge graph")
        }
        })
    }

    @MainActor
    func refreshGraph() async {
        await engine.memory.loadGraph()
        statusText = engine.memory.graphLoadError ?? "Knowledge graph refreshed"
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
            let root = engine.dataRoot
            let chain = engine.bridgeToolDispatchClient(fileAccess: "read_only")
            let host = AppToolExecutor.authoredProgramHost(dataRoot: root) { id, input in
                do {
                    let admission = try await AuthoredToolEffects.$admissionOnly.withValue(true) {
                        try await chain.dispatch(tool: "app", input: ["action": .string("authored." + id),
                            "args": .object(input)], surface: "chat")
                    }
                    if case .object(let fields) = admission, fields["status"] == .string("admitted") { return nil }
                    return admission
                } catch { return ChatToolOutcome.failure(error: error, tool: id) }
            }
            let run = try await SwiftNativeResearchClient(dataRoot: root).runResearchLab(objective: trimmed, maxResults: 5) { input in
                let result: PartCallResult<ResearchLabProposal> = await OwnedProgramInvocation.$host.withValue(host) {
                    await Parts(root: root).call(id: "research-lab", input: input)
                }
                switch result {
                case .success(let value): return value
                case .failure(let error): throw error
                }
            }
            engine.desk.recordResearchRun(run)
            let outcome = ResearchLabActionOutcome.recorded(run)
            statusText = CapabilitiesResearchLabPresentation.message(for: outcome).text
            return outcome
        } catch {
            let outcome = ResearchLabActionOutcome.failed(UserFacingError.cause(error, action: "start the research run"))
            statusText = CapabilitiesResearchLabPresentation.message(for: outcome).text
            return outcome
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
                try await engine.trust.refreshCatalogSources()
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
    func evaluateCapabilityTrust(_ capability: CapabilityRecord) async {
        _ = await capabilityEvaluationRead.read({ () async -> Result<CapabilityTrustEvaluation, Error> in
            do {
                let evaluation = try await engine.trust.evaluateCapability(id: capability.id)
                _ = await engine.trust.refreshCapabilityCatalog()
                return Result.success(evaluation)
            }
            catch { return .failure(error) }
        }, publish: { result in
        do {
            latestCapabilityTrustEvaluation = try result.get()
            statusText = "Capability trust evaluated"
        } catch {
            setFailureStatus(error, action: "evaluate that against trust")
        }
        })
    }

    @MainActor
    func runNativeAction(_ action: NativeActionRecord, dryRun: Bool = true) async {
        do {
            _ = try await NativeActionRoutes.runNativeAction(
                id: action.id, dryRun: dryRun, input: [:], dataRoot: nil, browser: .app)
            _ = await engine.tools.refreshNativePower()
            await engine.approvals.refresh()
            statusText = "Native action recorded"
        } catch {
            setFailureStatus(error, action: "run that action")
        }
    }

    @MainActor
    func runBrowserDryRun(url: String = "https://example.com") async {
        do {
            let run = try await BrowserActionRoutes.app.runBrowser(
                url: url, dryRun: true, captureSource: false, captureScreenshot: false, dataRoot: engine.dataRoot
            )
            _ = await engine.tools.refreshNativePower()
            statusText = "Browser dry run: \(run.status)"
        } catch {
            setFailureStatus("Browser run failed: " + UserFacingError.cause(error, action: "run the browser"), cause: error)
        }
    }

    @MainActor
    func cancelBrowserRun() async {
        do {
            let run = try await BrowserActionRoutes.app.cancelBrowserRun(id: engine.tools.browserStatus?.latestReceipt?.id, dataRoot: engine.dataRoot)
            _ = await engine.tools.refreshNativePower()
            statusText = "Browser run \(run.status)"
        } catch {
            setFailureStatus(error, action: "cancel the browser run")
        }
    }

    @MainActor
    func showVisibleBrowser() async {
        BrowserWindowController.shared.showWindow()
        _ = await engine.tools.refreshNativePower()
        statusText = "Visible Browser opened."
    }

    @MainActor
    func runConnectorAction(_ action: ConnectorActionRecord) async {
        do {
            let receipt = try await runConnectorAction(id: action.id, dryRun: true)
            _ = try? await engine.connectors.refreshActions()
            statusText = "Connector action: \(receipt.status)"
        } catch {
            setFailureStatus(error, action: "run that connector action")
        }
    }

    @MainActor
    func runImprovementGauntlet() async {
        do {
            let run = try await ImprovementGauntletRun.run(dataRoot: engine.dataRoot)
            _ = await engine.doctor.refreshHardening()
            statusText = "Gauntlet: \(run.status)"
        } catch {
            setFailureStatus("Gauntlet failed: " + UserFacingError.cause(error, action: "run the gauntlet"), cause: error)
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
                    dataRoot: root, runProcess: ProcessExecution.runBounded,
                    diagnostics: { @Sendable in await SupportDiagnostics.read(reusingChecks: nil) },
                    health: { @Sendable in DoctorFacade(dataRoot: root).readHealth() }
                )
                : try await ProductionExport.createArchive(
                    dataRoot: root, runProcess: ProcessExecution.runBounded
                ) { @Sendable in try await DoctorReadout.getProductionHardening(dataRoot: root) }
            let verification = try await export.verifyRegistry(dataRoot: root)
            if let detail = verification.failure {
                statusText = "\(label) failed verification: \(detail)"
                return .failed(support: support, detail: detail)
            }
            engine.doctor.recordProductionExports(verification.records)
            statusText = "\(label) created and verified: \(export.id)"
            return .verified(export)
        } catch {
            let detail = UserFacingError.cause(error, action: "create the \(label.lowercased())")
            statusText = "\(label) failed: \(detail)"
            return .failed(support: support, detail: detail)
        }
    }


}
