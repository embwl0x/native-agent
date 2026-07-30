// Mac-side iCloud projection for Mac integration permissions. The canonical
// permission store is mutated locally or through a signed iOS action. KVS is
// read-only projection data for the phone; it is never an authority input.
//
// Key shape matches what iOS writes:
//   { "<id>": {"read": Bool, "write": Bool} }
// e.g. {"calendar": {"read": true, "write": false}, ...}
//
// Note: NSUbiquitousKeyValueStore is the lightweight option for small
// state; total payload here is ~11 entries × 2 bools = trivial. The
// alternative (CloudKit) would be overkill.

import Foundation
import MacIntegration

@MainActor
final class MacIntegrationICloudBridge {
    static let shared = MacIntegrationICloudBridge()

    /// Same key the iOS side uses (MacIntegrationPermissionsSync.kvsKey).
    static let kvsKey = "nativeagent.mac_integration_permissions"

    private let kvs = NSUbiquitousKeyValueStore.default
    /// Publish the Mac-owned state at launch. The historical method name stays
    /// source-compatible with app assembly, but no KVS observer is installed.
    func startObserving() {
        kvs.synchronize()
        Task { await publishCanonicalSnapshot() }
    }

    /// Push a single integration's permission state to KVS — called by the
    /// Mac MacIntegrationView after a successful local persist. The iOS side
    /// picks it up via its own KVS observer the next time iCloud syncs.
    func push(id: String, read: Bool, write: Bool) {
        var current = (kvs.dictionary(forKey: Self.kvsKey) as? [String: [String: Bool]]) ?? [:]
        var entry: [String: Bool] = current[id] ?? [:]
        if MacIntegrationID.supportsRead(id) {
            entry["read"] = read
        } else {
            entry.removeValue(forKey: "read")
        }
        if MacIntegrationID.supportsWrite(id) {
            entry["write"] = write
        } else {
            entry.removeValue(forKey: "write")
        }
        current[id] = entry
        kvs.set(current, forKey: Self.kvsKey)
        kvs.synchronize()
    }

    private func publishCanonicalSnapshot() async {
        do {
            let current = try await MacIntegrationPermissionStore.shared.currentChecked()
            var projection: [String: [String: Bool]] = [:]
            for id in MacIntegrationID.all {
                guard let permission = current[id] else { continue }
                var axes: [String: Bool] = [:]
                if MacIntegrationID.supportsRead(id) { axes["read"] = permission.read }
                if MacIntegrationID.supportsWrite(id) { axes["write"] = permission.write }
                projection[id] = axes
            }
            kvs.set(projection, forKey: Self.kvsKey)
            kvs.synchronize()
        } catch {
            NSLog("[MacIntegrationICloudBridge] canonical projection failed: \(error)")
        }
    }
}
