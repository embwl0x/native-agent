import DoctorChecks
import Foundation
import SelfImprovement

extension RuntimeReadProjection {
    public static func swiftImprovementGauntlet(dataRoot: URL?) async throws -> ImprovementGauntletStatus {
        var status = try await (dataRoot.map { SwiftNativeSelfImprovement(dataRoot: $0) } ?? SwiftNativeSelfImprovement())
            .improvementGauntletStatusLocal()
        _ = try status.latestDisplayRun
        status.status = status.status ?? "ready"
        return status
    }
}

extension RuntimeReadProjection {
    /// `release/checklist.json`; missing reads as an empty checklist (every
    /// field decodes if present).
    public static func readReleaseChecklist(dataRoot: URL) async throws -> ReleaseChecklist {
        let url = dataRoot
            .appendingPathComponent("release", isDirectory: true)
            .appendingPathComponent("checklist.json")
        return try RuntimeReadProjection.readLocalJSON(url, fallbackJSON: "{}")
    }

}
