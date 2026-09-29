import Foundation
import WorkshopExecution

struct AppWorkshopPumpPlatform: WorkshopPumpPlatform {
    func isUnderResourcePressure() -> Bool {
        let process = ProcessInfo.processInfo
        if process.isLowPowerModeEnabled { return true }
        switch process.thermalState {
        case .serious, .critical: return true
        default: return false
        }
    }

    func artifactIsReadable(dataRoot: URL, handle: String, relativePath: String) -> Bool {
        let reader = WorkshopArtifactWriter(dataRoot: dataRoot, handle: handle)
        return (try? reader.read(relativePath: relativePath, maximumBytes: 1)) != nil
    }

    func validateArtifactComponent(_ value: String) throws -> String {
        try WorkshopArtifactWriter.validateSafeComponent(value)
    }
}
