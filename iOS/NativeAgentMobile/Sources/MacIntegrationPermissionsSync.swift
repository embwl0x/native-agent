// Read-only CloudKit snapshot of the Mac's canonical permission store.
// Signed actions carry permission changes back to the Mac.

import Foundation
import SwiftUI

@MainActor
final class MacIntegrationPermissionsSync: ObservableObject {
    static let shared = MacIntegrationPermissionsSync()

    private struct Snapshot: Decodable, Sendable {
        let permissions: [String: [String: Bool]]?

        init(from decoder: Decoder) throws {
            permissions = try? [String: [String: Bool]](from: decoder)
        }
    }

    @Published private(set) var permissions: [String: [String: Bool]] = [:]

    enum ProjectionState: Equatable {
        case awaitingMac
        case published
        case malformed(String)
    }

    @Published private(set) var projectionState: ProjectionState = .awaitingMac

    var projectionError: String? {
        if case let .malformed(message) = projectionState { return message }
        return nil
    }

    var hasMacProjection: Bool { projectionState == .published }

    private var refreshGeneration = 0

    func refreshProjection() async {
        refreshGeneration &+= 1
        let generation = refreshGeneration
        let engine = iCloudSyncEngine.shared
        let lifecycle = engine.lifecycleGeneration
        let filename = "mac_integration_permissions.json"
        let snapshot: Snapshot? = await engine.loadSnapshotObjectAsync(named: filename)
        guard generation == refreshGeneration, lifecycle == engine.lifecycleGeneration else { return }
        guard let snapshot else {
            permissions = [:]
            let exists = engine.snapshotDir.map {
                FileManager.default.fileExists(atPath: $0.appendingPathComponent(filename).path)
            } ?? false
            projectionState = exists ? .malformed("Mac permission sync is unavailable. Refresh after the Mac publishes its permissions.") : .awaitingMac
            return
        }
        guard let rows = snapshot.permissions, !rows.isEmpty,
              rows.values.allSatisfy({ !$0.isEmpty && $0.keys.allSatisfy { $0 == "read" || $0 == "write" } }) else {
            permissions = [:]
            projectionState = .malformed("Mac permission sync is unavailable. Refresh after the Mac publishes its permissions.")
            return
        }
        permissions = rows
        projectionState = .published
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
