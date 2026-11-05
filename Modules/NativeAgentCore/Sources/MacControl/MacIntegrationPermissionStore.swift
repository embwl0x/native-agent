import Foundation
import Darwin
import NativeAgentShared
import NativeAgentCore
import PersistenceCore
// Blueprint: | `MacIntegrationPermissionStore.swift` | Checked, flocked consent; complete supported axes; explicit OFF fences Full Mac |

// MARK: - Permission store

/// Unset integrations use shipped defaults; present entries must contain every supported axis, and read failures never mean OFF.
public actor MacIntegrationPermissionStore {
    public static let shared = MacIntegrationPermissionStore()
    public static let didChange = Notification.Name("NativeAgent.SystemPermissionPreflight.permissionDidChange")

    public struct Snapshot: Sendable {
        public let permissions: [String: MacIntegrationPermission]
        public let readiness: MacIntegrationPermissionReadiness

        public func allows(_ integrationId: String, mode: MacIntegrationPermissionMode) -> Bool {
            // An app with no read switch (the Scheduler) has nothing that refuses a read.
            if mode == .read, !MacIntegrationID.supportsRead(integrationId) { return true }
            guard let permission = permissions[integrationId],
                  (mode == .read ? MacIntegrationID.supportsRead(integrationId) : MacIntegrationID.supportsWrite(integrationId)),
                  !(mode == .read ? readiness.operatorReadOff : readiness.operatorWriteOff).contains(integrationId) else { return false }
            // The owner’s switches fence Full Mac; Full Mac never widens them.
            return mode == .read ? permission.read : permission.write
        }

        /// This snapshot with one stored write applied, for showing until the next read confirms it.
        public func with(_ integrationId: String, _ permission: MacIntegrationPermission) -> Snapshot {
            var permissions = permissions
            permissions[integrationId] = permission
            return Snapshot(permissions: permissions, readiness: readiness)
        }
    }

    private let dataRoot: URL

    public init() {
        self.dataRoot = defaultDataRoot()
    }

    /// Authority must use the engine’s data root.
    public init(dataRoot: URL) {
        self.dataRoot = dataRoot
    }

    private nonisolated var storePath: URL {
        dataRoot
            .appendingPathComponent("security", isDirectory: true)
            .appendingPathComponent("mac_integration_permissions.json")
    }

    // MARK: - Read

    /// Environment presentation reads authority without mutating it or probing OS permissions.
    public func readinessChecked() async throws -> MacIntegrationPermissionReadiness {
        try await snapshotChecked().readiness
    }

    public func currentChecked() async throws -> [String: MacIntegrationPermission] {
        try await snapshotChecked().permissions
    }

    public func snapshotChecked() async throws -> Snapshot {
        try snapshotNowChecked()
    }

    /// Effect boundaries cannot suspend before posting; use the checked disk owner rather than a cached grant.
    public nonisolated func snapshotNowChecked() throws -> Snapshot {
        let raw = try Self.loadRawStoreChecked(at: storePath)
        let overrides = Self.operatorOverrides(in: raw)
        var out: [String: MacIntegrationPermission] = [:]
        out.reserveCapacity(MacIntegrationID.all.count)
        for id in MacIntegrationID.all {
            out[id] = Self.effectiveEntry(id, in: raw)
        }
        return Snapshot(permissions: out, readiness: MacIntegrationPermissionReadiness(
            operatorReadOff: Set(overrides.compactMap { $0.value["read"] == false ? $0.key : nil }),
            operatorWriteOff: Set(overrides.compactMap { $0.value["write"] == false ? $0.key : nil })))
    }

    /// Explicit OFF wins over Full Mac; unsupported axes can never be granted.
    public func allows(_ integrationId: String, mode: MacIntegrationPermissionMode) async throws -> Bool {
        do {
            return try await snapshotChecked().allows(integrationId, mode: mode)
        } catch {
            throw ToolFailureError(error.localizedDescription, effects: .none,
                owner: "security/mac_integration_permissions.json", tap: "Trust > Mac",
                code: "integration_permission_unavailable", instruction: "Preserve the saved permission bytes and repair the authority before continuing.")
        }
    }

    // MARK: - Write

    /// Read under the authority lock so changing one axis preserves the other and its override.
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

    /// Embed provenance and axes atomically so validation or persistence failures leave authority unchanged. Additive cards preserve unrequested axes under the
    /// same lock; removals cannot grant an absent or explicitly disabled axis.
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
            // Lock read-modify-write to preserve concurrent choices; only missing storage bootstraps, while damaged bytes remain intact.
            var dict = try Self.loadRawStoreChecked(at: path)
            let effectiveBefore = Self.effectiveEntry(integrationId, in: dict)
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
            // Merge under the read lock so unrequested axes survive concurrent grants.
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
                // Idempotent signed retries must not undo newer local choices.
                return effectiveBefore
            }
            // Explicit human choices outlive the bounded receipt journal; agents cannot undo an explicit OFF.
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
            // Persist only supported axes so the authority shape cannot invent capabilities.
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
        NotificationCenter.default.post(name: Self.didChange, object: dataRoot)
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
        guard dict.isEmpty || dict["_operatorOverrides"] != nil else {
            throw MacIntegrationPermissionStoreError.malformedStore
        }

        // Malformed per-axis authority metadata is unavailable, never permission through Full Mac.
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
                      // Clamp receipt axes exactly as the writer does so unsupported grants cannot validate as ours.
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
                // Present null or nonstring identity is malformed, never absent.
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

        // Unknown authority fields are unavailable rather than retained for another build.
        let knownKeys = Set(MacIntegrationID.all).union(["_operatorOverrides", "_mutationReceipts"])
        guard Set(dict.keys).isSubset(of: knownKeys) else {
            throw MacIntegrationPermissionStoreError.malformedStore
        }
        for id in MacIntegrationID.all {
            guard let value = dict[id] else { continue }
            guard case .object(let entry) = value else {
                throw MacIntegrationPermissionStoreError.invalidKnownEntry(id)
            }
            let supportedAxes = Set((MacIntegrationID.supportsRead(id) ? ["read"] : [])
                + (MacIntegrationID.supportsWrite(id) ? ["write"] : []))
            guard Set(entry.keys) == supportedAxes else {
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

    /// Schema validation guarantees complete present entries; only missing integrations remain untouched.
    private nonisolated static func effectiveEntry(_ id: String, in raw: [String: JSONValue]) -> MacIntegrationPermission {
        let permission: MacIntegrationPermission
        if case .object(let entry)? = raw[id] {
            permission = MacIntegrationPermission(read: entry["read"] == .bool(true), write: entry["write"] == .bool(true))
        } else { permission = MacIntegrationID.defaultPermission(for: id) }
        let overrides = operatorOverrides(in: raw)[id]
        return MacIntegrationPermission(
            read: MacIntegrationID.supportsRead(id) && permission.read && overrides?["read"] != false,
            write: MacIntegrationID.supportsWrite(id) && permission.write && overrides?["write"] != false)
    }

    /// The validated override map is the sole owner of explicit operator choices.
    private nonisolated static func operatorOverrides(in dict: [String: JSONValue]) -> [String: [String: Bool]] {
        if case .object(let rows)? = dict["_operatorOverrides"] {
            return rows.reduce(into: [String: [String: Bool]]()) { result, row in
                guard case .object(let axes) = row.value else { return }
                result[row.key] = axes.compactMapValues { value -> Bool? in
                    guard case .bool(let bit) = value else { return nil }
                    return bit
                }
            }
        }
        return [:]
    }

}
