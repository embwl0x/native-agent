import Foundation
import Observation
import NativeAgentShared
import PersistenceCore
import TriggerScheduler
import EngineRuntime
import MemoryV2
import DoctorChecks

// Blueprint: | `TrainingImprovementModels.swift` | `HarnessBenchmarkRun.run(dataRoot:)`: app binding of authored-tool count, embedding availability and Doctor statuses to the shared benchmark owner |

extension HarnessBenchmarkRun {
    static func run(dataRoot: URL) async -> HarnessBenchmarkRun {
        await run(
            authoredToolCount: { try await ToolsFacade(dataRoot: dataRoot).listAuthored().count },
            embeddingRuntimeAvailable: { await SwiftNativeMemoryV2.shared.embeddingRuntimeSnapshot() != nil },
            doctorStatuses: { try? await makeDoctorChecks().runAll().map(\.status) }
        )
    }
}
