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
import CoreFoundation
import SwiftUI

@MainActor
final class MacIntegrationPermissionsSync: ObservableObject {
    static let shared = MacIntegrationPermissionsSync()

    /// KVS key shared with the Mac side. Do NOT rename without a coordinated
    /// migration on the Mac side — the user's settings would silently revert to
    /// defaults on first launch after the rename.
    static let kvsKey = "nativeagent.mac_integration_permissions"

    private let kvs = NSUbiquitousKeyValueStore.default
    private let projectionLoader: () -> [String: Any]?

    /// `id -> ["read": Bool, "write": Bool]`. Only axes the integration supports
    /// are stored; axis lookups fall back to `defaultValue(id:mode:)` via
    /// `get(id:mode:)`.
    @Published private(set) var permissions: [String: [String: Bool]] = [:]

    /// What the phone can actually say about the Mac's permission matrix.
    ///
    /// Sweep 2026-09-01 item 36: `load()` used to treat "the Mac has never
    /// published a projection" and "the Mac published a matrix" as the same
    /// state — both left `projectionError` nil, and the view then rendered the
    /// eleven hardcoded `defaultValue(id:mode:)` rows as if the Mac had
    /// confirmed them. An unpaired or never-synced phone showed a complete,
    /// plausible, entirely invented policy. The three cases are now distinct
    /// and the view must say which one it is looking at.
    enum ProjectionState: Equatable {
        /// No projection has ever arrived. Nothing here is authority.
        case awaitingMac
        /// A well-formed projection from the Mac.
        case published
        /// A projection arrived but cannot be read; reads fail closed.
        case malformed(String)
    }

    @Published private(set) var projectionState: ProjectionState = .awaitingMac

    /// Existing malformed KVS state is unavailable, never silently presented
    /// as the Mac's defaults. The view renders this instead of a plausible
    /// toggle matrix until the Mac republishes a complete projection.
    var projectionError: String? {
        if case let .malformed(message) = projectionState { return message }
        return nil
    }

    /// True only when a readable matrix actually came from the Mac. The view
    /// gates every live toggle on this; anything else is a labelled placeholder.
    var hasMacProjection: Bool { projectionState == .published }

    init(
        projectionLoader: @escaping () -> [String: Any]? = {
            NSUbiquitousKeyValueStore.default.dictionary(forKey: MacIntegrationPermissionsSync.kvsKey)
        },
        observesExternalChanges: Bool = true
    ) {
        self.projectionLoader = projectionLoader
        load()
        if observesExternalChanges {
            NotificationCenter.default.addObserver(
                self,
                selector: #selector(externalChange(_:)),
                name: NSUbiquitousKeyValueStore.didChangeExternallyNotification,
                object: kvs
            )
            kvs.synchronize()
        }
    }

    deinit {
        NotificationCenter.default.removeObserver(self)
    }

    // MARK: - Persistence

    /// Pull the current KVS dictionary into `permissions`. A malformed entry
    /// is surfaced and makes permission reads fail closed, rather than being
    /// silently replaced with believable defaults.
    private func load() {
        guard let raw = projectionLoader() else {
            // Key absent from KVS: the Mac has never published. Say so — do
            // not fall through to the default matrix and let the view render
            // eleven confident toggles nobody on the Mac ever agreed to.
            permissions = [:]
            projectionState = .awaitingMac
            return
        }
        var out: [String: [String: Bool]] = [:]
        var malformedIDs: [String] = []
        out.reserveCapacity(raw.count)
        for (id, value) in raw {
            guard let entry = value as? [String: Any] else {
                malformedIDs.append(id)
                continue
            }
            var pair: [String: Bool] = [:]
            var rowIsMalformed = false
            if let rawRead = entry["read"] {
                if let read = Self.strictBool(rawRead) {
                    pair["read"] = read
                } else {
                    rowIsMalformed = true
                }
            }
            if let rawWrite = entry["write"] {
                if let write = Self.strictBool(rawWrite) {
                    pair["write"] = write
                } else {
                    rowIsMalformed = true
                }
            }
            if !pair.isEmpty {
                out[id] = pair
            }
            if pair.isEmpty || rowIsMalformed {
                malformedIDs.append(id)
            }
        }
        permissions = out
        let malformedCount = malformedIDs.count
        projectionState = malformedCount == 0
            ? .published
            : .malformed(
                "Mac permission sync is unavailable: \(malformedCount) malformed \(malformedCount == 1 ? "row" : "rows") in projection (\(malformedIDs.sorted().joined(separator: ", ")))."
            )
    }

    /// `NSUbiquitousKeyValueStore` carries property-list scalars as bridged
    /// Foundation values. A numeric `1` can bridge through `as? Bool`, but it
    /// is not the Mac's documented Boolean wire value and must not make an OFF
    /// permission silently read as ON.
    private static func strictBool(_ value: Any) -> Bool? {
        guard let number = value as? NSNumber,
              CFGetTypeID(number) == CFBooleanGetTypeID() else {
            return nil
        }
        return number.boolValue
    }

    /// Fired when the Mac side (or another paired iPhone) updates KVS while
    /// the app is open. Re-reads on the main actor so SwiftUI views observing
    /// `permissions` re-render.
    @objc private func externalChange(_ note: Notification) {
        Task { @MainActor in
            self.load()
        }
    }

    /// Reconcile the current KVS projection on explicit screen entry or
    /// pull-to-refresh. External-change notifications remain the live-update
    /// path; this prevents a screen opened after a missed notification from
    /// presenting process-start defaults as a fresh Mac policy.
    func refreshProjection() {
        kvs.synchronize()
        load()
    }

    // MARK: - Gate

    /// Effective value for one (id, mode) pair: the stored axis if present,
    /// otherwise the default from `defaultValue(id:mode:)`. Callers that need
    /// the whole row should read `permissions[id]` directly and let the row
    /// view fall back per axis.
    ///
    /// When `projectionState` is `.awaitingMac` this returns the LOCAL default
    /// and nothing more. It is a placeholder, not the Mac's answer — callers
    /// must check `hasMacProjection` before presenting the result as policy.
    func get(id: String, mode: String) -> Bool {
        if projectionError != nil { return false }
        return permissions[id]?[mode] ?? defaultValue(id: id, mode: mode)
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
