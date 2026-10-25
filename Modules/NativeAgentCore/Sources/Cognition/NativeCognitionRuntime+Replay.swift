import Foundation
import CognitiveSubstrate
import DreamREMCycle
import PersistenceCore
// Blueprint: | `NativeCognitionRuntime+Replay.swift` | `NativeCognitionRuntime`: `makeReplayIntegrationInput` |

extension NativeCognitionRuntime {
    func makeReplayIntegrationInput(reason: String) async -> CognitiveReplayIntegrationInput {
        let root = dataRoot
        var unavailable: [String] = []
        let diary = FileBackedDreamDiary(dataRoot: root).listEntriesChecked(limit: 8)
        if diary.storageUnreadable { unavailable.append("dream_diary: the diary could not be listed") }
        unavailable += diary.failures.sorted { $0.key < $1.key }.map { "dream_diary/\($0.key): \($0.value)" }
        let dreamEntries = diary.entries
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

        let rem = REMProposalStore(dataRoot: root).loadAllChecked()
        unavailable += rem.unreadable.map { "rem_proposals/\($0)" }
        let remProposals = rem.rows
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
                    confidence: row.confidence,
                    createdAt: row.createdAt
                )
            }

        return CognitiveReplayIntegrationInput(
            reason: reason,
            dreamEntries: dreamEntries,
            remProposals: Array(remProposals),
            unavailableEvidence: unavailable
        )
    }
}
