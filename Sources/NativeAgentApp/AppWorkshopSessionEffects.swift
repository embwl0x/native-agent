import Foundation
import NativeAgentCore
import ChatOrchestration
import PersistenceCore
import TrustCenter
import WorkshopExecution

struct AppWorkshopSessionEffects: WorkshopSessionEffects {
    func makeToolDispatcher(dataRoot: URL) -> any ToolDispatchClient {
        SwiftToolDispatcher(
            dataRoot: dataRoot,
            allowProcessGlobalTools: dataRoot == PersistenceCore.defaultDataRoot(),
            agentBridgeConfigRoot: NativeAgentPaths.bridgeConfigRoot(dataRoot: dataRoot)
        )
    }

    /// The production turn: one ephemeral, read-only tool turn on the
    /// "workshop" surface (P2-3; "missions" on 0.3.x installs).
    /// surface. No chat session state, no transcript, her pinned model resolves
    /// from the surface picker. The membrane governs writes.
    func productionTurnExecutor(
        dataRoot: URL
    ) -> @Sendable (_ request: WorkshopSessionRequest, _ tools: any ToolDispatchClient) async throws -> (model: String, output: String) {
        return { request, tools in
            let client = NativeAgentEngine.live.chatClient(tools: tools)
            let response = try await client.runEphemeralToolTurn(
                message: request.promptSeed,
                fileAccess: "read_only",
                autonomyResolver: WorkshopAutonomyResolver(
                    base: SwiftNativeTrustCenter(dataRoot: dataRoot)
                ),
                requireCompleted: true,
                surface: WorkshopSurfaceVocabulary.canonical
            )
            return (response.model, response.output)
        }
    }
}
