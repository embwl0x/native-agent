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
