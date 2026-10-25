import DoctorChecks
import Foundation
import Observation
import NativeAgentShared
import PersistenceCore
import EngineRuntime
import AppToolRuntime
import MacControl
import SystemOps
import BackgroundWork
// Blueprint: | `ImprovementNextGenModels.swift` | `ImprovementGauntletRun.run`; app-bound process execution and bounded-run logging adapters |

extension ImprovementGauntletRun {
    static func run(dataRoot: URL) async throws -> ImprovementGauntletRun {
        try await run(
            dataRoot: dataRoot,
            runProcess: { executable, arguments, directory, timeout in
                let result = try await SystemProcessAdapter.runBounded(
                    executable: executable, arguments: arguments,
                    currentDirectory: directory, timeout: timeout
                )
                return (result.status, SystemGitActions.processDetail(result))
            },
            appendBoundedRun: { try await NativeRegistryEvaluation.appendBoundedRun($0, to: $1) }
        )
    }
}
