import Foundation
import CognitiveSubstrate
import DreamREMCycle
import PersistenceCore

extension NativeCognitionRuntime {
    func makeReplayIntegrationInput(reason: String) async -> CognitiveReplayIntegrationInput {
        let root = dataRoot
        let dreamEntries = FileBackedDreamDiary(dataRoot: root)
            .listEntries(limit: 8)
            .compactMap { entry -> CognitiveDreamReplayReference? in
                guard let content = entry.content?.trimmingCharacters(in: .whitespacesAndNewlines),
                      !content.isEmpty else { return nil }
                return CognitiveDreamReplayReference(
                    id: entry.filename ?? entry.date,
                    date: entry.date,
                    filename: entry.filename,
                    content: content,
                    modifiedAt: entry.modifiedAt
                )
            }

        let remProposals = REMProposalStore(dataRoot: root)
            .loadAll()
            .sorted { lhs, rhs in
                if lhs.createdAt != rhs.createdAt { return lhs.createdAt > rhs.createdAt }
                return lhs.id < rhs.id
            }
            .prefix(8)
            .map { row in
                CognitiveREMProposalReference(
                    id: row.id,
                    target: row.targetDoc,
                    text: row.proposalText,
                    evidenceDates: row.evidenceDates,
                    status: row.status,
                    confidence: row.confidence,
                    createdAt: row.createdAt
                )
            }

        return CognitiveReplayIntegrationInput(
            reason: reason,
            dreamEntries: dreamEntries,
            remProposals: Array(remProposals)
        )
    }
}
