import Foundation
import MacNerves
import NativeAgentCore
import NativeAgentShared
import PersistenceCore
import DeskCore
// Blueprint: | `EngineDoctor+CapabilityActions.swift` | Verified exports live in Doctor, publishing start and settlement to Capabilities |

extension DoctorFacade {
    public func createProductionExport(support: Bool) async throws -> ProductionExport {
        guard productionExportWork == nil else {
            throw PartCallError(code: "already_running", message: "An export is already being created. Wait for its receipt.")
        }
        productionExportWork = (support, Date())
        productionExportFailure = nil
        await capabilitiesDidChange?()
        let root = dataRoot
        let runProcess: ProductionExport.ArtifactProcessRunner = { executable, arguments, directory in
            let result = try await ProcessExecution().run(executable: executable, arguments: arguments,
                currentDirectory: directory, environment: nil, standardInput: nil, timeoutSeconds: nil)
            return (result.exitCode, result.stdout, result.stderr)
        }
        do {
            let health = try readHealth()
            // Capture the retained report and its availability together; diagnostics must not depend on a new Doctor run.
            let diagnostics: JSONValue = support ? .object([
                "app": .string(health.app), "version": .string(health.version),
                "generatedAt": .string(NativeTimestampFormat.plainZulu(Date())),
                "doctorStatus": health.doctorStatus.map(JSONValue.string) ?? .null,
                "doctorIssue": health.doctorIssue.map(JSONValue.string) ?? .null,
                "doctorReport": try report.map { try JSONValue.parse(JSONEncoder().encode($0)) } ?? .null,
                "doctorReportCompletedAt": reportCompletedAt.map { .string(NativeTimestampFormat.plainZulu($0)) } ?? .null,
            ]) : .null
            let export = support
                ? try await ProductionExport.createSupportBundle(dataRoot: root, runProcess: runProcess,
                    diagnostics: { @Sendable in diagnostics }, health: { @Sendable in health })
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
