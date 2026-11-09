import Foundation
import NativeAgentCore
import PersistenceCore
// Blueprint: | `Research+Lab.swift` | `SwiftNativeResearchClient`: saved research runs, read whole or refused |

extension SwiftNativeResearchClient {
    // MARK: research lab

    public func researchLabRuns() async throws -> [ResearchLabRun] {
        let raw = try await SwiftNativePersistenceCore.readJSON(labRunsPath, ifMissing: .array([]))
        guard case .array(let rows) = raw else {
            throw PersistenceCoreError.ioFailure(
                "Saved research runs must be an array. Original contents have been preserved."
            )
        }
        let decorated = try rows.enumerated().map { index, row -> (Int, ResearchLabRun) in
            guard let run = ResearchLabRun(row: row) else {
                throw ResearchClientError.malformedResponse("""
                    Saved research history is unavailable: runs[\(index)] is not a complete current run. Original contents have been preserved.
                    """)
            }
            return (index, run)
        }
        let sorted = decorated.sorted { a, b in
            if a.1.createdAt != b.1.createdAt { return a.1.createdAt > b.1.createdAt }
            return a.0 < b.0                      // stable: preserve input order on ties
        }
        return sorted.map { $0.1 }
    }
}
