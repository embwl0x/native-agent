import MacNerves
import BodyRuntime
import Foundation
import NativeAgentShared
import DeskCore
// Blueprint: | `AppModel+GraphCapabilityActions.swift` | Production export creation through the Doctor owner |


enum ProductionExportCreationOutcome: Equatable {
    case verified(ProductionExport)
    case failed(support: Bool, detail: String)
}

@MainActor
extension AppModel {

    func createProductionExport(support: Bool = false) async -> ProductionExportCreationOutcome {
        do {
            let export = try await engine.doctor.createProductionExport(support: support)
            statusText = "Created and verified: \(export.path)"
            return .verified(export)
        } catch {
            let detail = UserFacingError.cause(error, action: "create the export")
            statusText = detail
            return .failed(support: support, detail: detail)
        }
    }
}
