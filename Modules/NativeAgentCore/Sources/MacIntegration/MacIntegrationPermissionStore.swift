import Foundation
import Darwin
import NativeAgentShared
import NativeAgentCore
import Speech
import AVFoundation
import ApplicationServices
import CoreBluetooth
import CoreGraphics
import CoreLocation
import EventKit
import Contacts
import OSLog
import PersistenceCore
import Photos
import MacControl
import UserNotifications
// Blueprint: | `MacIntegrationPermissionStore.swift` | Saved integration consent under one checked, flocked authority; explicit operator off wins over Full Mac |

// MARK: - Permission store

/// Disk-backed, flocked permission store. Reads fall back to `MacIntegrationID.defaultPermission(for:)` for unset keys; the hot-path `allows` gate is the chat dispatcher's check before executing any integration-bound tool.
public actor MacIntegrationPermissionStore {
    public static let shared = MacIntegrationPermissionStore()

    public struct Snapshot: Sendable {
        public let permissions: [String: MacIntegrationPermission]
        public let readiness: MacIntegrationPermissionReadiness

        public func allows(_ integrationId: String, mode: MacIntegrationPermissionMode, fullMacAdmitted: Bool = false) -> Bool {
            guard let permission = permissions[integrationId],
                  (mode == .read ? MacIntegrationID.supportsRead(integrationId) : MacIntegrationID.supportsWrite(integrationId)),
                  !(mode == .read ? readiness.operatorReadOff : readiness.operatorWriteOff).contains(integrationId) else { return false }
            return fullMacAdmitted || (mode == .read ? permission.read : permission.write)
        }
    }

    private let dataRoot: URL

    /// Public default init — uses PersistenceCore.defaultDataRoot().
    public init() {
        self.dataRoot = defaultDataRoot()
    }

    /// Pin the authority owner to the engine's data root.
    public init(dataRoot: URL) {
        self.dataRoot = dataRoot
    }

    /// On-disk path: `<dataRoot>/security/mac_integration_permissions.json`.
    private var storePath: URL {
        dataRoot
            .appendingPathComponent("security", isDirectory: true)
            .appendingPathComponent("mac_integration_permissions.json")
    }

    // MARK: - Read

    /// One checked read for environment presentation; no migration write, permission request, OS probe, or authority change is performed here.
    public func readinessChecked() async throws -> MacIntegrationPermissionReadiness {
        try await snapshotChecked().readiness
    }

    /// Returns the current effective permission map: stored values merged on top of defaults for any unset key. Every entry in `MacIntegrationID.all` is present in the returned dict.
    public func currentChecked() async throws -> [String: MacIntegrationPermission] {
        try await snapshotChecked().permissions
    }

    public func snapshotChecked() async throws -> Snapshot {
        let raw = try Self.loadRawStoreChecked(at: storePath)
        let overrides = Self.operatorOverrides(in: raw)
        var out: [String: MacIntegrationPermission] = [:]
        out.reserveCapacity(MacIntegrationID.all.count)
        for id in MacIntegrationID.all {
            var permission = MacIntegrationID.defaultPermission(for: id)
            if case .object(let entry)? = raw[id] {
                permission = MacIntegrationPermission(read: entry["read"] == .bool(true), write: entry["write"] == .bool(true))
            }
            permission.read = MacIntegrationID.supportsRead(id) && permission.read && overrides[id]?["read"] != false
            permission.write = MacIntegrationID.supportsWrite(id) && permission.write && overrides[id]?["write"] != false
            out[id] = permission
        }
        return Snapshot(permissions: out, readiness: MacIntegrationPermissionReadiness(
            operatorReadOff: Set(overrides.compactMap { $0.value["read"] == false ? $0.key : nil }),
            operatorWriteOff: Set(overrides.compactMap { $0.value["write"] == false ? $0.key : nil })))
    }

    /// Hot-path gate. An explicit operator OFF wins over Full Mac; otherwise a valid saved preference or checked Full Mac admission permits the mode. Unsupported axes (e.g. `read` on `notify_mac`) ALWAYS return false — there is no concept
    /// to grant.
    public func allows(_ integrationId: String, mode: MacIntegrationPermissionMode, fullMacAdmitted: Bool = false) async -> Bool {
        do {
            return try await snapshotChecked().allows(integrationId, mode: mode, fullMacAdmitted: fullMacAdmitted)
        } catch {
            return false
        }
    }

    // MARK: - Write

    /// Persist only the selected axis; the other axis and its operator override stay as freshly read under the authority file's lock.
    @discardableResult
    public func set(integrationId: String, read: Bool?, write: Bool?, onlyRemovingAxes: Bool = false) async throws -> MacIntegrationPermission {
        try await setWithReceipt(
            integrationId: integrationId,
            read: read,
            write: write,
            actionID: UUID().uuidString.lowercased(),
            surface: "mac_ui",
            provenance: .local(),
            onlyRemovingAxes: onlyRemovingAxes
        )
    }

    /// One-generation permission mutation + provenance receipt. The receipt is embedded in the same atomic authority document, so receipt validation or persistence failure leaves the permission axes unchanged.  `onlyAddingAxes` makes the
    /// write ADDITIVE: an axis passed `false` is left exactly as the store already has it instead of being cleared. The inline permission card asks for ONE axis — a refused file READ raises a read-only card — and the old replace-both write
    /// then revoked the write grant the person had already given (and the mirror case revoked read). The merge happens inside the same lock as the read, so a concurrent grant on the other axis cannot be lost between them.
    /// `onlyRemovingAxes` refuses any requested grant absent from the current effective axes under that same lock, including explicit operator OFFs.
    @discardableResult
    public func setWithReceipt(
        integrationId: String,
        read: Bool?,
        write: Bool?,
        actionID: String,
        surface: String,
        provenance: MacIntegrationPermissionMutationProvenance,
        onlyAddingAxes: Bool = false,
        onlyRemovingAxes: Bool = false
    ) async throws -> MacIntegrationPermission {
        guard MacIntegrationID.all.contains(integrationId) else {
            throw NSError(
                domain: "MacIntegrationPermissionStore",
                code: -1,
                userInfo: [NSLocalizedDescriptionKey:
                    "Unknown integration id: \(integrationId)"]
            )
        }
        let requestedRead = MacIntegrationID.supportsRead(integrationId) ? read : false
        let requestedWrite = MacIntegrationID.supportsWrite(integrationId) ? write : false
        let actionID = actionID.trimmingCharacters(in: .whitespacesAndNewlines)
        let surface = surface.trimmingCharacters(in: .whitespacesAndNewlines)
        let provenance = MacIntegrationPermissionMutationProvenance(
            kind: provenance.kind,
            decidedBy: provenance.decidedBy.trimmingCharacters(in: .whitespacesAndNewlines),
            clientID: provenance.clientID?.trimmingCharacters(in: .whitespacesAndNewlines))
        guard !actionID.isEmpty, actionID.utf8.count <= 128,
              !surface.isEmpty, surface.utf8.count <= 64,
              provenance.isValid else {
            throw NSError(
                domain: "MacIntegrationPermissionStore",
                code: -2,
                userInfo: [NSLocalizedDescriptionKey: "Permission mutation provenance is invalid."]
            )
        }

        let path = storePath
        let permission = try await SwiftNativePersistenceCore.withFileLock(path) {
            // Read-modify-write inside the lock so concurrent writers don't clobber each other's keys. Missing is the only bootstrap-empty case. Existing unreadable, malformed, or invalid authority bytes throw before this write so a toggle
            // cannot erase the evidence and silently resurrect defaults for every sibling integration.
            var dict = try Self.loadRawStoreChecked(at: path)
            let effectiveBefore: MacIntegrationPermission = {
                guard case .object(let current)? = dict[integrationId] else {
                    return MacIntegrationID.defaultPermission(for: integrationId)
                }
                let defaults = MacIntegrationID.defaultPermission(for: integrationId)
                let beforeRead: Bool = {
                    guard MacIntegrationID.supportsRead(integrationId),
                          case .bool(let value)? = current["read"] else { return onlyRemovingAxes ? false : defaults.read }
                    return value
                }()
                let beforeWrite: Bool = {
                    guard MacIntegrationID.supportsWrite(integrationId),
                          case .bool(let value)? = current["write"] else { return onlyRemovingAxes ? false : defaults.write }
                    return value
                }()
                return MacIntegrationPermission(read: beforeRead, write: beforeWrite)
            }()
            var overrides = Self.operatorOverrides(in: dict)
            if onlyRemovingAxes {
                var gained: [String] = []
                if requestedRead == true, !effectiveBefore.read || overrides[integrationId]?["read"] == false {
                    gained.append("read")
                }
                if requestedWrite == true, !effectiveBefore.write || overrides[integrationId]?["write"] == false {
                    gained.append("write")
                }
                guard gained.isEmpty else { throw MacIntegrationPermissionStoreError.wouldGainAxes(gained) }
            }
            // Additive writes merge onto the generation just read, under this same lock, so the axis the card did not ask about survives.
            let clampedRead = onlyAddingAxes
                ? (effectiveBefore.read || requestedRead == true)
                : requestedRead ?? effectiveBefore.read
            let clampedWrite = onlyAddingAxes
                ? (effectiveBefore.write || requestedWrite == true)
                : requestedWrite ?? effectiveBefore.write
            var receipts: [JSONValue] = {
                guard case .array(let rows)? = dict["_mutationReceipts"] else { return [] }
                return rows
            }()
            if let existing = receipts.first(where: {
                guard case .object(let object) = $0 else { return false }
                return object["actionId"] == .string(actionID)
            }) {
                guard case .object(let object) = existing,
                      object["integrationId"] == .string(integrationId),
                      object["surface"] == .string(surface),
                      case .object(let after)? = object["after"],
                      after["read"] == .bool(clampedRead),
                      after["write"] == .bool(clampedWrite),
                      case .object(let priorProvenance)? = object["provenance"],
                      priorProvenance["kind"] == .string(provenance.kind),
                      priorProvenance["decidedBy"] == .string(provenance.decidedBy),
                      priorProvenance["clientId"] == provenance.clientID.map(JSONValue.string) else {
                    throw NSError(
                        domain: "MacIntegrationPermissionStore",
                        code: -3,
                        userInfo: [NSLocalizedDescriptionKey:
                            "Permission action id is already bound to a different mutation."]
                    )
                }
                // Signed inbox retries are idempotent and, critically, an old retried action may not revert a newer local choice.
                return effectiveBefore
            }
            // Explicit human choices live with the canonical permission axes, independently of the bounded receipt journal. Permission cards only touch the axis they actually request. An agent may add an untouched default, but cannot undo
            // a person's explicit OFF.
            var integrationOverrides = overrides[integrationId] ?? [:]
            if provenance.kind == "agent" {
                guard !(requestedRead == true && integrationOverrides["read"] == false),
                      !(requestedWrite == true && integrationOverrides["write"] == false) else {
                    throw NSError(domain: "MacIntegrationPermissionStore", code: -4,
                        userInfo: [NSLocalizedDescriptionKey:
                            "The operator turned this permission off. Only an explicit operator choice can turn it back on."])
                }
            } else {
                if MacIntegrationID.supportsRead(integrationId), let requestedRead, !onlyAddingAxes || requestedRead {
                    integrationOverrides["read"] = requestedRead
                }
                if MacIntegrationID.supportsWrite(integrationId), let requestedWrite, !onlyAddingAxes || requestedWrite {
                    integrationOverrides["write"] = requestedWrite
                }
            }
            if !integrationOverrides.isEmpty { overrides[integrationId] = integrationOverrides }
            dict["_operatorOverrides"] = .object(overrides.mapValues { axes in
                .object(axes.mapValues(JSONValue.bool))
            })
            // Persist only the supported axes for this id (matches the contract: the file does not store an entry for an axis the integration doesn't have).
            var perEntry: [String: JSONValue] = [:]
            if MacIntegrationID.supportsRead(integrationId) {
                perEntry["read"] = .bool(clampedRead)
            }
            if MacIntegrationID.supportsWrite(integrationId) {
                perEntry["write"] = .bool(clampedWrite)
            }
            dict[integrationId] = .object(perEntry)
            receipts.append(.object([
                "kind": .string("mac_integration_permission_mutation.v1"),
                "actionId": .string(actionID),
                "surface": .string(surface),
                "integrationId": .string(integrationId),
                "before": .object([
                    "read": .bool(effectiveBefore.read),
                    "write": .bool(effectiveBefore.write),
                ]),
                "after": .object([
                    "read": .bool(clampedRead),
                    "write": .bool(clampedWrite),
                ]),
                "provenance": provenance.json,
                "recordedAt": .string(NativeTimestampFormat.plainZulu(Date())),
            ]))
            if receipts.count > 500 { receipts = Array(receipts.suffix(500)) }
            dict["_mutationReceipts"] = .array(receipts)
            try await SwiftNativePersistenceCore.writeJSON(.object(dict), to: path)
            return MacIntegrationPermission(read: clampedRead, write: clampedWrite)
        }
        NotificationCenter.default.post(name: SystemPermissionPreflight.permissionDidChange, object: dataRoot)
        return permission
    }

    // MARK: - Disk reader

    /// Missing file means a fresh store. Existing damaged bytes are unavailable and remain untouched for explicit repair.
    private nonisolated static func loadRawStoreChecked(
        at path: URL
    ) throws -> [String: JSONValue] {
        var entry = stat()
        if lstat(path.path, &entry) != 0 {
            guard errno == ENOENT else { throw MacIntegrationPermissionStoreError.unreadableStore }
            return [:]
        }
        guard entry.st_mode & S_IFMT == S_IFREG else {
            throw MacIntegrationPermissionStoreError.unreadableStore
        }

        let data: Data
        do {
            data = try Data(contentsOf: path)
        } catch {
            throw MacIntegrationPermissionStoreError.unreadableStore
        }

        let raw: JSONValue
        do {
            raw = try JSONDecoder().decode(JSONValue.self, from: data)
        } catch {
            throw MacIntegrationPermissionStoreError.malformedStore
        }
        guard case .object(let dict) = raw else {
            throw MacIntegrationPermissionStoreError.invalidRoot
        }

        // Authority metadata has an exact, supported per-axis Boolean shape. Malformed metadata cannot quietly fall back to Full Mac admission.
        if let metadata = dict["_operatorOverrides"] {
            guard case .object(let integrations) = metadata else {
                throw MacIntegrationPermissionStoreError.malformedStore
            }
            for (id, value) in integrations {
                guard MacIntegrationID.all.contains(id), case .object(let axes) = value,
                      !axes.isEmpty else { throw MacIntegrationPermissionStoreError.malformedStore }
                for (axis, value) in axes {
                    guard case .bool = value,
                          (axis == "read" && MacIntegrationID.supportsRead(id))
                            || (axis == "write" && MacIntegrationID.supportsWrite(id)) else {
                        throw MacIntegrationPermissionStoreError.malformedStore
                    }
                }
            }
        }

        if let receiptValue = dict["_mutationReceipts"] {
            guard case .array(let receipts) = receiptValue else {
                throw MacIntegrationPermissionStoreError.malformedStore
            }
            for receipt in receipts {
                guard case .object(let object) = receipt,
                      object["kind"] == .string("mac_integration_permission_mutation.v1"),
                      case .string(let actionID)? = object["actionId"],
                      !actionID.isEmpty, actionID.utf8.count <= 128,
                      case .string(let surface)? = object["surface"],
                      !surface.isEmpty, surface.utf8.count <= 64,
                      case .string(let integrationID)? = object["integrationId"],
                      MacIntegrationID.all.contains(integrationID),
                      case .object(let before)? = object["before"],
                      case .bool(let beforeRead)? = before["read"],
                      case .bool(let beforeWrite)? = before["write"],
                      case .object(let after)? = object["after"],
                      case .bool(let afterRead)? = after["read"],
                      case .bool(let afterWrite)? = after["write"],
                      // The same support clamps the writer applies: an axis the integration has no concept of is false on both sides of every receipt this store ever wrote, so a receipt claiming spotlight was granted WRITE is not one of
                      // ours.
                      MacIntegrationID.supportsRead(integrationID)
                        || (!beforeRead && !afterRead),
                      MacIntegrationID.supportsWrite(integrationID)
                        || (!beforeWrite && !afterWrite),
                      case .object(let provenance)? = object["provenance"],
                      case .string(let provenanceKind)? = provenance["kind"],
                      case .string(let decidedBy)? = provenance["decidedBy"],
                      case .string(let recordedAt)? = object["recordedAt"], !recordedAt.isEmpty else {
                    throw MacIntegrationPermissionStoreError.malformedStore
                }
                // A present null/nonstring identity is malformed, never absence.
                let clientID: String?
                if let value = provenance["clientId"] {
                    guard case .string(let text) = value else {
                        throw MacIntegrationPermissionStoreError.malformedStore
                    }
                    clientID = text.trimmingCharacters(in: .whitespacesAndNewlines)
                } else { clientID = nil }
                guard MacIntegrationPermissionMutationProvenance(
                    kind: provenanceKind, decidedBy: decidedBy, clientID: clientID).isValid else {
                    throw MacIntegrationPermissionStoreError.malformedStore
                }
            }
        }

        // Unknown ids/fields are retained for forward compatibility. Every known row and known axis must have its exact authority type.
        for id in MacIntegrationID.all {
            guard let value = dict[id] else { continue }
            guard case .object(let entry) = value else {
                throw MacIntegrationPermissionStoreError.invalidKnownEntry(id)
            }
            for axis in ["read", "write"] {
                guard let value = entry[axis] else { continue }
                guard case .bool = value else {
                    throw MacIntegrationPermissionStoreError.invalidKnownAxis(
                        integrationID: id,
                        axis: axis
                    )
                }
            }
        }
        return dict
    }

    /// Called only after strict document/receipt validation. Legacy stores did not record additive-vs-replacement intent. Supported reads default ON, so a saved read-OFF is a revocation even without a receipt. Default write-OFF still needs
    /// a changed human axis to establish an override. On the next normal mutation this migration is persisted before receipts can rotate away.
    private nonisolated static func operatorOverrides(in dict: [String: JSONValue]) -> [String: [String: Bool]] {
        if case .object(let rows)? = dict["_operatorOverrides"] {
            var result = rows.reduce(into: [String: [String: Bool]]()) { result, row in
                guard case .object(let axes) = row.value else { return }
                result[row.key] = axes.compactMapValues { value -> Bool? in
                    guard case .bool(let bit) = value else { return nil }
                    return bit
                }
            }
            for id in MacIntegrationID.all where MacIntegrationID.supportsRead(id) {
                guard result[id]?["read"] == nil,
                      case .object(let entry)? = dict[id], entry["read"] == .bool(false) else { continue }
                result[id, default: [:]]["read"] = false
            }
            return result
        }
        var result: [String: [String: Bool]] = [:]
        let receipts: [JSONValue]
        if case .array(let rows)? = dict["_mutationReceipts"] { receipts = rows }
        else { receipts = [] }
        for receipt in receipts {
            guard case .object(let row) = receipt,
                  case .object(let provenance)? = row["provenance"],
                  provenance["kind"] == .string("local") || provenance["kind"] == .string("signed_ios"),
                  case .string(let id)? = row["integrationId"],
                  case .object(let before)? = row["before"],
                  case .object(let after)? = row["after"] else { continue }
            var axes = result[id] ?? [:]
            for axis in ["read", "write"] {
                if case .bool(let old)? = before[axis], case .bool(let new)? = after[axis], old != new {
                    axes[axis] = new
                }
            }
            if !axes.isEmpty { result[id] = axes }
        }
        for id in MacIntegrationID.all where MacIntegrationID.supportsRead(id) {
            guard case .object(let entry)? = dict[id], entry["read"] == .bool(false) else { continue }
            result[id, default: [:]]["read"] = false
        }
        return result
    }


}
