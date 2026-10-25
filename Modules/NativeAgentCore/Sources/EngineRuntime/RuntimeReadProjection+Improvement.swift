import Foundation
import PersistenceCore
// Blueprint: | `RuntimeReadProjection+Improvement.swift` | `RuntimeReadProjection`: `swiftImprovementGauntlet` |

extension RuntimeReadProjection {
    public static func swiftImprovementGauntlet(dataRoot: URL?) async throws -> ImprovementGauntletStatus {
        var status = try await improvementGauntletStatusLocal(dataRoot: dataRoot ?? defaultDataRoot())
        _ = try status.latestDisplayRun
        status.status = status.status ?? "ready"
        return status
    }
}
