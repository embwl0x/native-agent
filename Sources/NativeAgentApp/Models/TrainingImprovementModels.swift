import Foundation
import Observation
import NativeAgentShared
import PersistenceCore
import TriggerScheduler
import SelfImprovement
import MCPDispatcher
import MemoryV2
import DoctorChecks

extension HarnessBenchmarkRun {
    static func run(dataRoot: URL) async -> HarnessBenchmarkRun {
        await run(
            dataRoot: dataRoot,
            authoredToolCount: { try await ToolsFacade(dataRoot: dataRoot).listAuthored().count },
            mcpServerCount: { try await makeMCPDispatcher().listServers().count },
            embeddingRuntimeAvailable: { await SwiftNativeMemoryV2.shared.embeddingRuntimeSnapshot() != nil },
            doctorStatuses: { try? await makeDoctorChecks().runAll().map(\.status) }
        )
    }
}
