import Foundation

extension MacSyncEngine {
    func telegramSnapshotData() async -> SnapshotGroupBuild {
        do {
            return .built(try await MobileSnapshotBuilder.shared.encode(sync.host.telegramSnapshot()))
        } catch {
            return .skipped("Telegram settings are unavailable. Open Telegram on your Mac to check them.")
        }
    }
}
