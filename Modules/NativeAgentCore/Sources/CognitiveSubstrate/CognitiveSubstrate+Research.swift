import Foundation
import NativeAgentCore
import PersistenceCore
// Blueprint: | `CognitiveSubstrate+Research.swift` | `CognitiveSubstrate`: live workspace intervention and frozen Observatory summary; experiment metrics are retired |

extension CognitiveSubstrate {
    public func setAblation(_ key: String, enabled: Bool) async {
        await waitForMaintenanceTransition()
        let trimmed = key.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        ablations[trimmed] = enabled
        if trimmed == "workspace" { publishAttentionProjection(at: dependencies.now()) }
    }

    public func observatorySnapshot(from read: CognitiveFrozenRead) -> CognitiveObservatorySnapshot {
        let now = read.fixedAt
        let currentAffect = read.affect
        guard read.configuration.enabled else {
            return CognitiveObservatorySnapshot(
                generatedAt: now,
                nodeCount: 0,
                workspaceCount: 0,
                episodeCount: 0,
                reflectionCount: 0,
                affect: currentAffect,
                ablations: ablations
            )
        }
        let nodeCount = read.snapshot.nodes.count
        let workspaceCount = read.workspace.items.count
        return CognitiveObservatorySnapshot(
            generatedAt: now,
            nodeCount: nodeCount,
            workspaceCount: workspaceCount,
            episodeCount: episodes.count,
            reflectionCount: reflectionReceipts.count,
            affect: currentAffect,
            ablations: ablations
        )
    }

}
