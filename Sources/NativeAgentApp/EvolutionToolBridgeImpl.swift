import Foundation
import ChatOrchestration
import PersistenceCore
import SelfImprovement

/// App assembly connects the shared proposal owner to canonical install staging.
struct EvolutionToolBridgeImpl: EvolutionToolBridge {
    private let actions: EvolutionChatActions

    init(dataRoot: URL = PersistenceCore.defaultDataRoot()) {
        actions = EvolutionChatActions(dataRoot: dataRoot) { root, id in
            await BackgroundLoopsAssembly.stageEvolutionApprovals(
                dataRoot: root, onlyProposalId: id)
        }
    }

    func evolutionPropose(input: [String: JSONValue]) async throws -> JSONValue {
        try await actions.evolutionPropose(input: input)
    }

    func evolutionStatus(input: [String: JSONValue]) async throws -> JSONValue {
        try await actions.evolutionStatus(input: input)
    }

    func evolutionWithdraw(input: [String: JSONValue]) async throws -> JSONValue {
        try await actions.evolutionWithdraw(input: input)
    }

    func evolutionStageInstall(input: [String: JSONValue]) async throws -> JSONValue {
        try await actions.evolutionStageInstall(input: input)
    }
}
