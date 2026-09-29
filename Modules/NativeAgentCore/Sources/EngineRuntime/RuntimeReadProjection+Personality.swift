import Foundation
import PersonaEngine
import MemoryV2
import Cognition

extension RuntimeReadProjection {
    public static func swiftPersonalityGrowth(
        growthWeekProvider: @escaping @Sendable () async throws -> [String]
    ) async throws -> PersonalityGrowthSummary {
        let compiler = PersonaCompiler()
        let feedbackProvider: @Sendable () async throws -> Int = {
            let mem = SwiftNativeMemoryV2.shared
            let records = try await mem.listMemory(kind: nil)
            return records.reduce(0) { acc, rec in
                let tags = rec.tags ?? []
                return acc + (tags.contains("persona-feedback") ? 1 : 0)
            }
        }
        // 2026-09-13: the week's actual changes, from the substrate that owns
        // the records. PersonaEngine must not depend on CognitiveSubstrate, so
        // the rows are injected here exactly as the feedback count is.
        let summary = try await compiler.growthSummary(
            feedbackMemoryProvider: feedbackProvider,
            growthWeekProvider: growthWeekProvider,
            now: Date.init
        )
        return PersonalityGrowthSummary(
            engineVersion: summary.engineVersion,
            activeKind: summary.activeKind,
            fingerprint: summary.fingerprint,
            growthWeek: summary.growthWeek,
            feedbackMemories: summary.feedbackMemories,
            nextActions: summary.nextActions,
            createdAt: summary.createdAt.isEmpty ? nil : summary.createdAt
        )
    }
}
