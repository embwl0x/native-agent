import AppToolRuntime
import DoctorChecks
import Foundation
import MacControl
import NativeAgentCore
import NativeAgentShared
import SystemOps
import TrustPersistence
// Blueprint: | `EngineDoctor+CapabilityActions.swift` | Improvement runs and verified exports live in Doctor, publishing start and settlement to Capabilities |

extension DoctorFacade {
    public func runImprovementChecks() async throws -> ImprovementGauntletRun {
        guard improvementRunStartedAt == nil else {
            throw PartCallError(code: "already_running", message: "Improvement checks are already running. Wait for their result.")
        }
        improvementRunStartedAt = Date()
        improvementRunError = nil
        await capabilitiesDidChange?()
        do {
            let run = try await ImprovementGauntletRun.run(dataRoot: dataRoot,
                runProcess: { @Sendable executable, arguments, directory in
                    let result = try await ProcessExecution().run(executable: executable, arguments: arguments,
                        currentDirectory: directory, environment: nil, standardInput: nil, timeoutSeconds: nil)
                    return (result.exitCode, SystemGitActions.processDetail((result.exitCode, result.stdout, result.stderr)))
                }, appendBoundedRun: { @Sendable in try await NativeRegistryEvaluation.appendBoundedRun($0, to: $1) })
            _ = await refreshHardening()
            await settle { await self.finishImprovementChecks() }
            return run
        } catch {
            improvementRunError = error.localizedDescription
            await settle { await self.finishImprovementChecks() }
            throw error
        }
    }

    private func finishImprovementChecks() async {
        improvementRunStartedAt = nil
        await capabilitiesDidChange?()
    }

    public func createProductionExport(support: Bool) async throws -> ProductionExport {
        guard productionExportWork == nil else {
            throw PartCallError(code: "already_running", message: "An export is already being created. Wait for its receipt.")
        }
        productionExportWork = (support, Date())
        productionExportFailure = nil
        await capabilitiesDidChange?()
        let root = dataRoot
        let health = readHealth()
        let runProcess: ProductionExport.ArtifactProcessRunner = { executable, arguments, directory in
            let result = try await ProcessExecution().run(executable: executable, arguments: arguments,
                currentDirectory: directory, environment: nil, standardInput: nil, timeoutSeconds: nil)
            return (result.exitCode, result.stdout, result.stderr)
        }
        do {
            let export = support
                ? try await ProductionExport.createSupportBundle(dataRoot: root, runProcess: runProcess,
                    diagnostics: { @Sendable in await SupportDiagnostics.read(reusingChecks: nil) },
                    health: { @Sendable in health })
                : try await ProductionExport.createArchive(dataRoot: root, runProcess: runProcess) {
                    @Sendable in try await DoctorReadout.getProductionHardening(dataRoot: root)
                }
            let verification = try await export.verifyRegistry(dataRoot: root)
            if let failure = verification.failure {
                throw PartCallError(code: "export_unverified", message: "The export was created but could not be verified: " + failure)
            }
            await recordProductionExports(verification.records)
            await settle { await self.finishProductionExport() }
            return export
        } catch {
            productionExportFailure = (support, error.localizedDescription)
            await settle { await self.finishProductionExport() }
            throw error
        }
    }

    private func finishProductionExport() async {
        productionExportWork = nil
        await capabilitiesDidChange?()
    }
}
