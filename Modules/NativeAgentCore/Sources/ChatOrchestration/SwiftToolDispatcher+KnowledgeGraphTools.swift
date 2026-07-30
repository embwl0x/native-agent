import Foundation
import NativeAgentCore
import PersistenceCore
import MemoryV2
import MCPDispatcher
import KnowledgeGraph
import PersonaEngine
import ProviderRouting
import TrustCenter
import Dispatcher
import MacControl
import Context
import SwarmRuns
import WorkshopExecution

// MARK: - Knowledge graph tools

extension SwiftToolDispatcher {
    func impl_search_kg(input: [String: JSONValue]) async throws -> JSONValue {
        let query = try requireString(input, "query")
        let limit = optionalInt(input, "limit") ?? 10
        let reader = SwiftNativeKnowledgeGraphReader(
            graphPath: knowledgeGraphPath,
            flushURL: nil
        )
        let result = try await reader.searchChecked(q: query)
        guard case .object(let obj) = result,
              case .array(let results)? = obj["results"]
        else {
            throw KnowledgeGraphReadError.malformedEnvelope(
                "search_kg did not receive a results array"
            )
        }
        let capped = Array(results.prefix(max(0, limit)))
        return .object(["results": .array(capped)])
    }
}
