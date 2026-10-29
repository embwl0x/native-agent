import Combine
import NativeAgentShared
import SwiftUI
// Blueprint: | `AdvancedStore.swift` | Shared health and runs refresh loading/errors |

// MARK: - Store

@MainActor
final class AdvancedStore: ObservableObject {
    @Published private(set) var healthLoadError: String?
    @Published private(set) var runsLoadError: String?
    private var healthRefreshInFlight = false
    private var runsRefreshInFlight = false

    func refreshHealth() async {
        guard !healthRefreshInFlight else { return }
        healthRefreshInFlight = true
        defer { healthRefreshInFlight = false }
        let engine = iCloudSyncEngine.shared
        healthLoadError = await engine.refreshHealthSnapshot().feedbackMessage
    }

    func refreshRuns() async {
        guard !runsRefreshInFlight else { return }
        runsRefreshInFlight = true
        defer { runsRefreshInFlight = false }
        let engine = iCloudSyncEngine.shared
        runsLoadError = await engine.refreshRunsSnapshot().feedbackMessage
    }

    func runsDidChange(_ next: [RunRecord]) {
        if !next.isEmpty { runsLoadError = iCloudSyncEngine.shared.snapshotHealth.damageSentence(for: ["runs.json"]) }
    }
}
