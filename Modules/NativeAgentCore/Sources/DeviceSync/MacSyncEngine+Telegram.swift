import Foundation
// Blueprint: | `MacSyncEngine+Telegram.swift` | `MacSyncEngine`: `telegramSnapshotData` |

extension MacSyncEngine {
    func telegramSnapshotData(in directory: URL, rebuilding: Bool) async -> SnapshotGroupBuild {
        do {
            let candidate = try await sync.host.telegramSnapshot()
            let snapshot = try await MobileSnapshotBuilder.shared.state(
                candidate, storedAt: directory.appendingPathComponent("telegram.json"), rebuilding: rebuilding, retainingClocks: {
                    $0.observedAt = $1.observedAt
                }, stamp: { value, previous, now in
                    value.observedAt = previous.map { max(now.timeIntervalSince1970, $0.observedAt + 0.001) } ?? now.timeIntervalSince1970
                })
            return .built(try await MobileSnapshotBuilder.shared.encode(snapshot))
        } catch {
            return .skipped("Telegram settings are unavailable: \(error.localizedDescription). Open Telegram on your Mac to check them.")
        }
    }
}
