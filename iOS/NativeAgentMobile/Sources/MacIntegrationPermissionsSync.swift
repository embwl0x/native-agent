// PATCH-2026-07-15: mac-integration-tab-ios — read-only iCloud projection of
// the Mac side's <dataRoot>/security/mac_integration_permissions.json store.
//
// The Mac's MacIntegrationPermissionStore is the source of truth on disk. This
// class reads its KVS projection and holds optimistic UI state while signed
// actions are in flight. It never writes authority through KVS.
//
// Shape on the wire (matches the on-disk shape exactly):
//   {
//     "calendar":   {"read": true,  "write": false},
//     "reminders":  {"read": true,  "write": false},
//     "notify_mac": {"write": true},
//     "spotlight":  {"read": true},
//     ...
//   }
//
// An axis the integration doesn't support is omitted (matches the Mac store's
// clamping rule). Reads coalesce stored values on top of defaults via
// `defaultValue(id:mode:)` so an unset key still answers the hot-path gate.

import Foundation
import SwiftUI

@MainActor
final class MacIntegrationPermissionsSync: ObservableObject {
    static let shared = MacIntegrationPermissionsSync()

    /// KVS key shared with the Mac side. Do NOT rename without a coordinated
    /// migration on the Mac side — the user's settings would silently revert to
    /// defaults on first launch after the rename.
    static let kvsKey = "nativeagent.mac_integration_permissions"

    private let kvs = NSUbiquitousKeyValueStore.default

    /// `id -> ["read": Bool, "write": Bool]`. Only axes the integration supports
    /// are stored; axis lookups fall back to `defaultValue(id:mode:)` via
    /// `get(id:mode:)`.
    @Published private(set) var permissions: [String: [String: Bool]] = [:]

    private init() {
        load()
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(externalChange(_:)),
            name: NSUbiquitousKeyValueStore.didChangeExternallyNotification,
            object: kvs
        )
        kvs.synchronize()
    }

    deinit {
        NotificationCenter.default.removeObserver(self)
    }

    // MARK: - Persistence

    /// Pull the current KVS dictionary into `permissions`. Tolerates malformed
    /// entries (silently drops anything that isn't a `[String: Bool]`-shaped
    /// inner dict) so a corrupted KVS write can't crash the iOS app.
    private func load() {
        guard let raw = kvs.dictionary(forKey: Self.kvsKey) else {
            permissions = [:]
            return
        }
        var out: [String: [String: Bool]] = [:]
        out.reserveCapacity(raw.count)
        for (id, value) in raw {
            guard let entry = value as? [String: Any] else { continue }
            var pair: [String: Bool] = [:]
            if let r = entry["read"] as? Bool { pair["read"] = r }
            if let w = entry["write"] as? Bool { pair["write"] = w }
            if !pair.isEmpty {
                out[id] = pair
            }
        }
        permissions = out
    }

    /// Fired when the Mac side (or another paired iPhone) updates KVS while
    /// the app is open. Re-reads on the main actor so SwiftUI views observing
    /// `permissions` re-render.
    @objc private func externalChange(_ note: Notification) {
        Task { @MainActor in
            self.load()
        }
    }

    // MARK: - Gate

    /// Effective value for one (id, mode) pair: the stored axis if present,
    /// otherwise the default from `defaultValue(id:mode:)`. Callers that need
    /// the whole row should read `permissions[id]` directly and let the row
    /// view fall back per axis.
    func get(id: String, mode: String) -> Bool {
        permissions[id]?[mode] ?? defaultValue(id: id, mode: mode)
    }

    /// Apply a local projection only. The caller must pair this with a signed
    /// Mac action and replace or roll back the optimistic value from its
    /// terminal response.
    func applyProjection(id: String, read: Bool?, write: Bool?) {
        var entry: [String: Bool] = [:]
        if let read { entry["read"] = read }
        if let write { entry["write"] = write }
        permissions[id] = entry
    }

    // MARK: - Defaults
    //
    // Mirrors `MacIntegrationID.defaultPermission(for:)` in
    // Modules/NativeAgentCore/Sources/MacIntegration/MacIntegrationPermissions.swift.
    // Update both sides if the user changes the policy.

    private func defaultValue(id: String, mode: String) -> Bool {
        switch mode {
        case "read":
            // Every read-capable surface defaults ON. The three send-only
            // surfaces (notify_mac, notify_mobile, scheduler) report false
            // because they have no read concept.
            switch id {
            case "calendar", "reminders", "contacts", "mail",
                 "messages", "notes", "music", "spotlight":
                return true
            default:
                return false
            }
        case "write":
            // Notifications + scheduler are already-trusted outbound channels;
            // every PII-touching surface defaults OFF. Spotlight has no write
            // concept.
            switch id {
            case "notify_mac", "notify_mobile", "scheduler":
                return true
            default:
                return false
            }
        default:
            return false
        }
    }
}
