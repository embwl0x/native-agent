import Foundation
import NativeAgentShared

extension iCloudSyncEngine {
    @discardableResult
    func refreshHelpersSnapshot() async -> Bool {
        guard let snapshotDir else { return false }
        let lifecycle = lifecycleGeneration
        await refreshSnapshotStaleness()
        guard let snapshot: MobileHelpersSnapshot = await Self.loadSnapshotObjectOnly(named: "helpers_agents.json", in: snapshotDir),
              lifecycle == lifecycleGeneration else { return false }
        helpersSnapshot = snapshot
        return staleSnapshotGroups["helpers_agents"] == nil
    }
}
