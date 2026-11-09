import Foundation
import EngineRuntime
import SwiftUI
import NativeAgentShared
import MemoryV2
import PersistenceCore

// Blueprint: | `MemoryView.swift` | Canonical Spotlight reindex operation and checked outcome words |

extension SwiftNativeMemoryIndexer.ReindexOutcome {
    var userMessage: String {
        switch self {
        case .indexed(let count):
            return "Spotlight reindexed \(count) memories"
        case .changedDuringReindex:
            return "Memories changed while indexing. Reindex again from the latest saved state."
        case .failed(let message, _):
            return "Spotlight reindex failed: \(message)"
        }
    }

    var agentMessage: String {
        if case .failed(_, let cause) = self { return UserFacingError.forAgent(userMessage, cause: cause) }
        return userMessage
    }
}

struct MemorySpotlightReindexOperation {
    static func run(dataRoot: URL) async -> SwiftNativeMemoryIndexer.ReindexOutcome {
        do {
            return try await SwiftNativeMemoryIndexer.reindex(
                dataRoot: dataRoot, client: SwiftNativeMemoryIndexer.liveClient(dataRoot: dataRoot)
            )
        } catch {
            return .failed(message: UserFacingError.cause(error, action: "reindex Spotlight"), cause: error.localizedDescription)
        }
    }
}
