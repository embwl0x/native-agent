// The canonical permission store supplies a read-only phone snapshot.
// Signed iOS actions remain the only remote authority input.

import Foundation
import MacIntegration

@MainActor
public final class MacIntegrationICloudBridge {
    private unowned let sync: DeviceSync

    init(sync: DeviceSync) {
        self.sync = sync
    }

    public func startObserving() {
        requestPublication()
    }

    public func push(id: String, read: Bool, write: Bool) {
        requestPublication()
    }

    private func requestPublication() {
        Task { await sync.engine.writeSnapshots() }
    }

    static func canonicalProjection() async throws -> [String: [String: Bool]] {
        let current = try await MacIntegrationPermissionStore.shared.currentChecked()
        var projection: [String: [String: Bool]] = [:]
        for id in MacIntegrationID.all {
            guard let permission = current[id] else { continue }
            var axes: [String: Bool] = [:]
            if MacIntegrationID.supportsRead(id) { axes["read"] = permission.read }
            if MacIntegrationID.supportsWrite(id) { axes["write"] = permission.write }
            projection[id] = axes
        }
        return projection
    }
}
