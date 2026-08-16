import Foundation
import PersistenceCore

// MARK: - Mac Integration permissions
//
// Per-integration READ/WRITE permission gating for the Mac Integration surface
// (Calendar / Reminders / Contacts / Mail / Messages / Notes / Music /
// Notifications / Spotlight / Scheduler). The hot-path gate is
// `MacIntegrationPermissionStore.shared.allows(id, mode:)`, called by the
// chat tool dispatcher BEFORE executing any side effect against the host OS.
//
// Defaults bias to READ ON for sensitive surfaces, WRITE OFF — Agent can SEE
// what's on the user's machine but can't write/send/play without an explicit flip.
// Notifications and the scheduler default ON because they're already trusted
// outbound channels (no PII read concept).
//
// Persistence: `<dataRoot>/security/mac_integration_permissions.json`. Atomic
// writes via PersistenceCore.SwiftNativePersistenceCore behind a cross-process
// flock so concurrent Swift owners stay byte-consistent.

// MARK: - Public types

/// Which axis a caller is asking about.
public enum MacIntegrationPermissionMode: String, Sendable, Codable {
    case read
    case write
}

/// The pair of axis bits for one integration.
public struct MacIntegrationPermission: Sendable, Codable, Equatable {
    public var read: Bool
    public var write: Bool
    public init(read: Bool, write: Bool) {
        self.read = read
        self.write = write
    }
}

public struct MacIntegrationPermissionMutationProvenance: Sendable, Equatable {
    public let kind: String
    public let decidedBy: String
    public let clientID: String?

    public static func local(decidedBy: String = "mac_operator") -> Self {
        Self(kind: "local", decidedBy: decidedBy, clientID: nil)
    }

    public static func signedIOS(clientID: String, decidedBy: String = "ios_signed_operator") -> Self {
        Self(kind: "signed_ios", decidedBy: decidedBy, clientID: clientID)
    }
}

/// Persistence failures are authority failures, not permission defaults.
/// Only a missing store may bootstrap from `defaultPermission(for:)`.
public enum MacIntegrationPermissionStoreError: Error, Sendable, Equatable, LocalizedError {
    case unreadableStore
    case malformedStore
    case invalidRoot
    case invalidKnownEntry(String)
    case invalidKnownAxis(integrationID: String, axis: String)

    public var errorDescription: String? {
        switch self {
        case .unreadableStore:
            return "The saved Mac Integration permissions are unreadable."
        case .malformedStore:
            return "The saved Mac Integration permissions are malformed."
        case .invalidRoot:
            return "The saved Mac Integration permissions must be a JSON object."
        case .invalidKnownEntry(let id):
            return "The saved Mac Integration permission for \(id) must be a JSON object."
        case .invalidKnownAxis(let id, let axis):
            return "The saved Mac Integration permission \(id).\(axis) must be a Boolean."
        }
    }
}

// MARK: - Stable identifiers

/// Stable string IDs for each Mac integration. UI rows + tool dispatch both
/// reference these strings — do NOT rename without a migration step that
/// rewrites the on-disk permissions file.
public enum MacIntegrationID {
    public static let calendar      = "calendar"
    public static let reminders     = "reminders"
    public static let contacts      = "contacts"
    public static let mail          = "mail"
    public static let messages      = "messages"
    public static let notes         = "notes"
    public static let music         = "music"
    public static let notifyMac     = "notify_mac"
    public static let notifyMobile  = "notify_mobile"
    public static let spotlight     = "spotlight"
    public static let scheduler     = "scheduler"

    /// Stable display-order for the UI tab.
    public static let all: [String] = [
        calendar, reminders, contacts, mail, messages, notes, music,
        notifyMac, notifyMobile, spotlight, scheduler,
    ]

    // MARK: - UI strings

    /// Per-id display name for the UI row.
    public static func displayName(for id: String) -> String {
        switch id {
        case calendar:     return "Calendar"
        case reminders:    return "Reminders"
        case contacts:     return "Contacts"
        case mail:         return "Mail"
        case messages:     return "Messages"
        case notes:        return "Notes"
        case music:        return "Music"
        case notifyMac:    return "Mac Notifications"
        case notifyMobile: return "iPhone Notifications"
        case spotlight:    return "Spotlight Search"
        case scheduler:    return "Scheduler"
        default:           return id
        }
    }

    /// Per-id description for the UI tooltip.
    public static func description(for id: String) -> String {
        switch id {
        case calendar:     return "Read upcoming events + create/modify events"
        case reminders:    return "Read due reminders + create/check off"
        case contacts:     return "Look up contacts + create/edit (write OFF by default)"
        case mail:         return "Read inbox + send mail (write = send, OFF by default)"
        case messages:     return "Read recent threads + send iMessage (write = send, OFF by default)"
        case notes:        return "Search + create Apple Notes (write OFF by default)"
        case music:        return "See now-playing + control playback (write = play/pause/skip)"
        case notifyMac:    return "Send Mac notifications"
        case notifyMobile: return "Send notifications to paired iPhone"
        case spotlight:    return "Search via Spotlight"
        case scheduler:    return "Schedule future-firing jobs"
        default:           return ""
        }
    }

    // MARK: - Axis support

    /// True iff the integration has a meaningful "read" axis. notify_mac /
    /// notify_mobile / scheduler are send-only — no read concept.
    public static func supportsRead(_ id: String) -> Bool {
        switch id {
        case notifyMac, notifyMobile, scheduler:
            return false
        default:
            return true
        }
    }

    /// True iff the integration has a meaningful "write" axis. Spotlight is
    /// search-only — no write concept.
    public static func supportsWrite(_ id: String) -> Bool {
        switch id {
        case spotlight:
            return false
        default:
            return true
        }
    }

    // MARK: - Defaults

    /// the user's chosen defaults — read ON for everything that has a read axis,
    /// write OFF for the sensitive surfaces (contacts/mail/messages/notes/
    /// music), write ON for notifications + scheduler (she already uses these
    /// and the user trusts them). For an axis the integration doesn't support, the
    /// returned value on that axis is `false` (no concept).
    public static func defaultPermission(for id: String) -> MacIntegrationPermission {
        let read = supportsRead(id) // default ON for every read-capable surface
        let write: Bool
        switch id {
        case notifyMac, notifyMobile, scheduler:
            write = true
        default:
            write = false
        }
        // Spotlight has no write axis — clamp to false even though the switch
        // above would default it to false; this keeps the rule explicit.
        let writeClamped = supportsWrite(id) ? write : false
        return MacIntegrationPermission(read: read, write: writeClamped)
    }
}

// MARK: - Permission store

/// Disk-backed, flocked permission store. Reads fall back to
/// `MacIntegrationID.defaultPermission(for:)` for unset keys; the hot-path
/// `allows` gate is the chat dispatcher's check before executing any
/// integration-bound tool.
public actor MacIntegrationPermissionStore {
    public static let shared = MacIntegrationPermissionStore()

    private let persistence: SwiftNativePersistenceCore
    private let dataRoot: URL

    /// Public default init — uses PersistenceCore.defaultDataRoot().
    public init() {
        self.persistence = SwiftNativePersistenceCore()
        self.dataRoot = defaultDataRoot()
    }

    /// Test seam — pin a specific data root (and optionally a custom
    /// persistence impl). Not used in production.
    public init(dataRoot: URL, persistence: SwiftNativePersistenceCore = SwiftNativePersistenceCore()) {
        self.persistence = persistence
        self.dataRoot = dataRoot
    }

    /// On-disk path: `<dataRoot>/security/mac_integration_permissions.json`.
    private var storePath: URL {
        dataRoot
            .appendingPathComponent("security", isDirectory: true)
            .appendingPathComponent("mac_integration_permissions.json")
    }

    // MARK: - Read

    /// Returns the current effective permission map: stored values merged on
    /// top of defaults for any unset key. Every entry in
    /// `MacIntegrationID.all` is present in the returned dict.
    public func currentChecked() async throws -> [String: MacIntegrationPermission] {
        let stored = try loadStoredChecked()
        var out: [String: MacIntegrationPermission] = [:]
        out.reserveCapacity(MacIntegrationID.all.count)
        for id in MacIntegrationID.all {
            let def = MacIntegrationID.defaultPermission(for: id)
            if let s = stored[id] {
                // Clamp stored values to axis support so a corrupted file
                // that put a `true` on an unsupported axis can't grant access.
                let r = MacIntegrationID.supportsRead(id) ? s.read : false
                let w = MacIntegrationID.supportsWrite(id) ? s.write : false
                out[id] = MacIntegrationPermission(read: r, write: w)
            } else {
                out[id] = def
            }
        }
        return out
    }

    /// Compatibility projection for nonthrowing status callers. Existing
    /// damaged authority state is deliberately all-denied; it must never look
    /// like a fresh install whose bootstrap defaults grant read/notification
    /// access. UI and repair surfaces should use `currentChecked()` so they can
    /// distinguish unavailable state from intentional off toggles.
    public func current() async -> [String: MacIntegrationPermission] {
        do {
            return try await currentChecked()
        } catch {
            return Self.denyAllPermissions()
        }
    }

    /// Hot-path gate. Returns true iff the integration permits the requested
    /// mode. Unsupported axes (e.g. `read` on `notify_mac`) ALWAYS return
    /// false — there is no concept to grant.
    public func allows(_ integrationId: String, mode: MacIntegrationPermissionMode) async -> Bool {
        // Unknown integration → deny. (Stops a typo'd id from accidentally
        // matching the "default to ON" branch.)
        guard MacIntegrationID.all.contains(integrationId) else { return false }
        switch mode {
        case .read:
            if !MacIntegrationID.supportsRead(integrationId) { return false }
        case .write:
            if !MacIntegrationID.supportsWrite(integrationId) { return false }
        }
        let stored: [String: MacIntegrationPermission]
        do {
            stored = try loadStoredChecked()
        } catch {
            return false
        }
        let perm = stored[integrationId] ?? MacIntegrationID.defaultPermission(for: integrationId)
        switch mode {
        case .read:  return perm.read
        case .write: return perm.write
        }
    }

    // MARK: - Write

    /// Persist a per-integration permission. Writes under flock via
    /// PersistenceCore. Read/write are clamped to axis support so a caller
    /// can't accidentally grant write to spotlight (or read to scheduler).
    public func set(integrationId: String, read: Bool, write: Bool) async throws {
        _ = try await setWithReceipt(
            integrationId: integrationId,
            read: read,
            write: write,
            actionID: UUID().uuidString.lowercased(),
            surface: "mac_ui",
            provenance: .local()
        )
    }

    /// One-generation permission mutation + provenance receipt. The receipt is
    /// embedded in the same atomic authority document, so receipt validation or
    /// persistence failure leaves the permission axes unchanged.
    @discardableResult
    public func setWithReceipt(
        integrationId: String,
        read: Bool,
        write: Bool,
        actionID: String,
        surface: String,
        provenance: MacIntegrationPermissionMutationProvenance
    ) async throws -> MacIntegrationPermission {
        guard MacIntegrationID.all.contains(integrationId) else {
            throw NSError(
                domain: "MacIntegrationPermissionStore",
                code: -1,
                userInfo: [NSLocalizedDescriptionKey:
                    "Unknown integration id: \(integrationId)"]
            )
        }
        let clampedRead = MacIntegrationID.supportsRead(integrationId) ? read : false
        let clampedWrite = MacIntegrationID.supportsWrite(integrationId) ? write : false
        let actionID = actionID.trimmingCharacters(in: .whitespacesAndNewlines)
        let surface = surface.trimmingCharacters(in: .whitespacesAndNewlines)
        let decidedBy = provenance.decidedBy.trimmingCharacters(in: .whitespacesAndNewlines)
        let clientID = provenance.clientID?.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !actionID.isEmpty, actionID.utf8.count <= 128,
              !surface.isEmpty, surface.utf8.count <= 64,
              !decidedBy.isEmpty, decidedBy.utf8.count <= 128,
              provenance.kind == "local" || provenance.kind == "signed_ios",
              provenance.kind != "signed_ios" || (clientID?.isEmpty == false && (clientID?.utf8.count ?? 0) <= 256) else {
            throw NSError(
                domain: "MacIntegrationPermissionStore",
                code: -2,
                userInfo: [NSLocalizedDescriptionKey: "Permission mutation provenance is invalid."]
            )
        }

        let path = storePath
        return try await persistence.withFileLock(path) {
            // Read-modify-write inside the lock so concurrent writers don't
            // clobber each other's keys.
            // Missing is the only bootstrap-empty case. Existing unreadable,
            // malformed, or invalid authority bytes throw before this write so
            // a toggle cannot erase the evidence and silently resurrect
            // defaults for every sibling integration.
            var dict = try Self.loadRawStoreChecked(at: path)
            let effectiveBefore: MacIntegrationPermission = {
                guard case .object(let current)? = dict[integrationId] else {
                    return MacIntegrationID.defaultPermission(for: integrationId)
                }
                let defaults = MacIntegrationID.defaultPermission(for: integrationId)
                let beforeRead: Bool = {
                    guard MacIntegrationID.supportsRead(integrationId),
                          case .bool(let value)? = current["read"] else { return defaults.read }
                    return value
                }()
                let beforeWrite: Bool = {
                    guard MacIntegrationID.supportsWrite(integrationId),
                          case .bool(let value)? = current["write"] else { return defaults.write }
                    return value
                }()
                return MacIntegrationPermission(read: beforeRead, write: beforeWrite)
            }()
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
                      priorProvenance["decidedBy"] == .string(decidedBy),
                      priorProvenance["clientId"] == clientID.map(JSONValue.string) else {
                    throw NSError(
                        domain: "MacIntegrationPermissionStore",
                        code: -3,
                        userInfo: [NSLocalizedDescriptionKey:
                            "Permission action id is already bound to a different mutation."]
                    )
                }
                // Signed inbox retries are idempotent and, critically, an old
                // retried action may not revert a newer local choice.
                return effectiveBefore
            }
            // Persist only the supported axes for this id (matches the
            // contract: the file does not store an entry for an axis the
            // integration doesn't have).
            var perEntry: [String: JSONValue] = [:]
            if MacIntegrationID.supportsRead(integrationId) {
                perEntry["read"] = .bool(clampedRead)
            }
            if MacIntegrationID.supportsWrite(integrationId) {
                perEntry["write"] = .bool(clampedWrite)
            }
            dict[integrationId] = .object(perEntry)
            var provenanceJSON: [String: JSONValue] = [
                "kind": .string(provenance.kind),
                "decidedBy": .string(decidedBy),
            ]
            if let clientID { provenanceJSON["clientId"] = .string(clientID) }
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
                "provenance": .object(provenanceJSON),
                "recordedAt": .string(ISO8601DateFormatter().string(from: Date())),
            ]))
            if receipts.count > 500 { receipts = Array(receipts.suffix(500)) }
            dict["_mutationReceipts"] = .array(receipts)
            try await self.persistence.writeJSON(.object(dict), to: path)
            return MacIntegrationPermission(read: clampedRead, write: clampedWrite)
        }
    }

    // MARK: - Disk reader

    /// Missing file means a fresh store. Existing damaged bytes are unavailable
    /// and remain untouched for explicit repair.
    private nonisolated static func loadRawStoreChecked(
        at path: URL
    ) throws -> [String: JSONValue] {
        guard FileManager.default.fileExists(atPath: path.path) else { return [:] }

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

        if let receiptValue = dict["_mutationReceipts"] {
            guard case .array(let receipts) = receiptValue else {
                throw MacIntegrationPermissionStoreError.malformedStore
            }
            for receipt in receipts {
                guard case .object(let object) = receipt,
                      object["kind"] == .string("mac_integration_permission_mutation.v1"),
                      case .string(let actionID)? = object["actionId"], !actionID.isEmpty,
                      case .string(let surface)? = object["surface"], !surface.isEmpty,
                      case .string(let integrationID)? = object["integrationId"],
                      MacIntegrationID.all.contains(integrationID),
                      case .object(let before)? = object["before"],
                      case .bool(_)? = before["read"], case .bool(_)? = before["write"],
                      case .object(let after)? = object["after"],
                      case .bool(_)? = after["read"], case .bool(_)? = after["write"],
                      case .object(let provenance)? = object["provenance"],
                      case .string(let provenanceKind)? = provenance["kind"],
                      provenanceKind == "local" || provenanceKind == "signed_ios",
                      case .string(let decidedBy)? = provenance["decidedBy"], !decidedBy.isEmpty,
                      case .string(let recordedAt)? = object["recordedAt"], !recordedAt.isEmpty else {
                    throw MacIntegrationPermissionStoreError.malformedStore
                }
                if provenanceKind == "signed_ios" {
                    guard case .string(let clientID)? = provenance["clientId"], !clientID.isEmpty else {
                        throw MacIntegrationPermissionStoreError.malformedStore
                    }
                }
            }
        }

        // Unknown ids/fields are retained for forward compatibility. Every
        // known row and known axis must have its exact authority type.
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

    private func loadStoredChecked() throws -> [String: MacIntegrationPermission] {
        let dict = try Self.loadRawStoreChecked(at: storePath)
        var out: [String: MacIntegrationPermission] = [:]
        out.reserveCapacity(dict.count)
        for (id, val) in dict {
            guard MacIntegrationID.all.contains(id), case .object(let entry) = val else {
                continue
            }
            var r = false
            var w = false
            if case .bool(let b) = entry["read"] ?? .null { r = b }
            if case .bool(let b) = entry["write"] ?? .null { w = b }
            out[id] = MacIntegrationPermission(read: r, write: w)
        }
        return out
    }

    private nonisolated static func denyAllPermissions() -> [String: MacIntegrationPermission] {
        Dictionary(
            uniqueKeysWithValues: MacIntegrationID.all.map {
                ($0, MacIntegrationPermission(read: false, write: false))
            }
        )
    }
}
