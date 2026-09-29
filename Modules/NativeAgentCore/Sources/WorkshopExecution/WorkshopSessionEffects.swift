import Foundation
import ChatTurnContracts
import NativeAgentCore
import PersistenceCore

/// Concrete dispatcher and resident chat factories supplied by the app host.
/// The session calls these only after its durable reservation claim is checked.
public protocol WorkshopSessionEffects: Sendable {
    func makeToolDispatcher(dataRoot: URL) -> any ToolDispatchClient
    func productionTurnExecutor(
        dataRoot: URL
    ) -> @Sendable (_ request: WorkshopSessionRequest, _ tools: any ToolDispatchClient) async throws -> (model: String, output: String)
}
