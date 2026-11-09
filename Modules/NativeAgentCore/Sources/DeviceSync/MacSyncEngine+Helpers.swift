import Foundation
import PersistenceCore
import AgentConversations
// Blueprint: | `MacSyncEngine+Helpers.swift` | `MacSyncEngine`: `startHelpersSnapshotObservation`, `helpersSnapshotData` |

extension MacSyncEngine {
    func startHelpersSnapshotObservation() async {
        helpersSnapshotWatcher?.cancel()
        let root = PersistenceCore.defaultDataRoot()
        let generation = snapshotLifecycleGeneration
        // Publish layout with helpers so phone navigation follows the write immediately.
        let paths = ["bots/definitions", "bots/shelf-index.json", "bots/run-queue.json",
                     "agents/peers.json", "agents/conversations.json", "agents/grok-requests", "agents/conversation-live.json",
                     "ui/layout.json"]
        let watcher = await FileChangeWatcher.armed(paths: paths.map { root.appendingPathComponent($0) }) { [weak self] _ in
            Task { @MainActor in
                guard let self, self.isActive, generation == self.snapshotLifecycleGeneration else { return }
                await self.writeSnapshots()
            }
        }
        guard isActive, generation == snapshotLifecycleGeneration else { watcher.cancel(); return }
        helpersSnapshotWatcher = watcher
    }

    func helpersSnapshotData() async -> SnapshotGroupBuild {
        do {
            let data = try await MobileSnapshotBuilder.shared.encode(sync.host.helpersSnapshot())
            guard data.count <= 192 * 1024 else {
                return .skipped("Helpers and agents exceed the phone snapshot limit.")
            }
            return .built(data)
        } catch {
            return .skipped(error.localizedDescription)
        }
    }
}
