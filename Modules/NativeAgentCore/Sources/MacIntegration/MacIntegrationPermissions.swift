import Foundation
import NativeAgentShared
import Speech
import AVFoundation
import ApplicationServices
import CoreGraphics
import CoreLocation
import EventKit
import Contacts
import OSLog
import PersistenceCore
import MacControl
import UserNotifications

// MARK: - Mac Integration permissions
//
// Per-integration READ/WRITE permission gating for the Mac Integration surface
// (Calendar / Reminders / Contacts / Mail / Messages / Notes / Music /
// Notifications / Spotlight / Scheduler). The hot-path gate is
// `MacIntegrationPermissionStore.shared.allows(id, mode:)`, called by the
// chat tool dispatcher BEFORE executing any side effect against the host OS.
//
// Defaults bias to READ ON for sensitive surfaces, WRITE OFF — Agent can SEE
// what's on the user's machine. Writes need a grant or admitted Full Mac;
// an explicit operator OFF always takes precedence over Full Mac.
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

/// Read-only readiness evidence. Explicit revocations are distinct from the
/// untouched defaults that an admitted Full Mac conversation may cover.
public struct MacIntegrationPermissionReadiness: Sendable {
    public let operatorReadOff: Set<String>
    public let operatorWriteOff: Set<String>

    public func refusal(integration: String, mode: MacIntegrationPermissionMode) -> String? {
        guard (mode == .read ? operatorReadOff : operatorWriteOff).contains(integration) else { return nil }
        if integration == MacIntegrationID.mail, mode == .write {
            return "Mail Write is off by the operator's switch. I can write the draft text in chat or save it to a file. For Mail content, use mail.recent, mail.search or mail.read directly; do not open or screen-read Mail."
        }
        return "\(MacIntegrationID.displayName(for: integration)) \(mode.rawValue.capitalized) is off by the operator's switch; only the operator can turn it back on."
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

    /// The agent answered the card itself, with no hand on the trackpad.
    ///
    /// Under Full Mac that is intended (User, 2026-09-13) — but it must never
    /// be INDISTINGUISHABLE from a person tapping the same card, which is what
    /// `.local()` on this path made it. The receipt keeps its own kind, and the
    /// interaction id is carried so the grant can be traced back to the exact
    /// card and the turn that raised it.
    public static func agent(interactionID: String) -> Self {
        Self(kind: "agent", decidedBy: "agent_interaction_act", clientID: interactionID)
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

public enum MacIntegrationFrameworkPermission: String, CaseIterable {
    case calendar
    case reminders
    case contacts
    // Speech Recognition and Microphone share the framework-row grant path,
    // so failure copy must name them as specifically as Calendar et al.
    case speechRecognition = "speech_recognition"
    case microphone

    public var label: String {
        switch self {
        case .speechRecognition: return "Speech Recognition"
        case .microphone: return "Microphone"
        default: return rawValue.capitalized
        }
    }

    public var purpose: String {
        switch self {
        case .speechRecognition: return "Turn voice messages and dictation into text."
        case .microphone: return "Record your voice when you use the microphone."
        case .calendar: return "Read and manage events in Mac Calendar."
        case .reminders: return "Read and manage your reminders."
        case .contacts: return "Find people in your address book."
        }
    }

    /// Single source of truth for the pane anchors: the shared capability
    /// vocabulary, not a second hand-maintained copy.
    public var capability: SystemPermissionCapability {
        switch self {
        case .calendar: return .calendars
        case .reminders: return .reminders
        case .contacts: return .contacts
        case .speechRecognition: return .speechRecognition
        case .microphone: return .microphone
        }
    }

    public var settingsAnchor: String {
        capability.settingsAnchor ?? "Privacy_AllFiles"
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

    /// One checked read for environment presentation; no migration write,
    /// permission request, OS probe, or authority change is performed here.
    public func readinessChecked() async throws -> MacIntegrationPermissionReadiness {
        try await snapshotChecked().readiness
    }

    /// Returns the current effective permission map: stored values merged on
    /// top of defaults for any unset key. Every entry in
    /// `MacIntegrationID.all` is present in the returned dict.
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

    /// Hot-path gate. An explicit operator OFF wins over Full Mac; otherwise a
    /// valid saved preference or checked Full Mac admission permits the mode.
    /// Unsupported axes (e.g. `read` on `notify_mac`) ALWAYS return
    /// false — there is no concept to grant.
    public func allows(_ integrationId: String, mode: MacIntegrationPermissionMode, fullMacAdmitted: Bool = false) async -> Bool {
        do {
            return try await snapshotChecked().allows(integrationId, mode: mode, fullMacAdmitted: fullMacAdmitted)
        } catch {
            return false
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
    ///
    /// `onlyAddingAxes` makes the write ADDITIVE: an axis passed `false` is
    /// left exactly as the store already has it instead of being cleared. The
    /// inline permission card asks for ONE axis — a refused file READ raises a
    /// read-only card — and the old replace-both write then revoked the write
    /// grant the person had already given (and the mirror case revoked read).
    /// The merge happens inside the same lock as the read, so a concurrent
    /// grant on the other axis cannot be lost between them.
    @discardableResult
    public func setWithReceipt(
        integrationId: String,
        read: Bool,
        write: Bool,
        actionID: String,
        surface: String,
        provenance: MacIntegrationPermissionMutationProvenance,
        onlyAddingAxes: Bool = false
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
        let decidedBy = provenance.decidedBy.trimmingCharacters(in: .whitespacesAndNewlines)
        let clientID = provenance.clientID?.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !actionID.isEmpty, actionID.utf8.count <= 128,
              !surface.isEmpty, surface.utf8.count <= 64,
              !decidedBy.isEmpty, decidedBy.utf8.count <= 128,
              ["local", "signed_ios", "agent"].contains(provenance.kind),
              // Per-kind, and the reader checks the same shape: a local
              // decision carries no client identity, a remote or agent one
              // always does, and "agent" has exactly one decider name.
              provenance.kind == "local"
                ? clientID == nil
                : (clientID?.isEmpty == false && (clientID?.utf8.count ?? 0) <= 256),
              provenance.kind != "agent" || decidedBy == "agent_interaction_act" else {
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
            // Additive writes merge onto the generation just read, under this
            // same lock, so the axis the card did not ask about survives.
            let clampedRead = onlyAddingAxes
                ? (effectiveBefore.read || requestedRead)
                : requestedRead
            let clampedWrite = onlyAddingAxes
                ? (effectiveBefore.write || requestedWrite)
                : requestedWrite
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
            // Explicit human choices live with the canonical permission axes,
            // independently of the bounded receipt journal. Permission cards
            // only touch the axis they actually request. An agent may add an
            // untouched default, but cannot undo a person's explicit OFF.
            var overrides = Self.operatorOverrides(in: dict)
            var integrationOverrides = overrides[integrationId] ?? [:]
            if provenance.kind == "agent" {
                guard !(requestedRead && integrationOverrides["read"] == false),
                      !(requestedWrite && integrationOverrides["write"] == false) else {
                    throw NSError(domain: "MacIntegrationPermissionStore", code: -4,
                        userInfo: [NSLocalizedDescriptionKey:
                            "The operator turned this permission off. Only an explicit operator choice can turn it back on."])
                }
            } else {
                if MacIntegrationID.supportsRead(integrationId), !onlyAddingAxes || requestedRead {
                    integrationOverrides["read"] = requestedRead
                }
                if MacIntegrationID.supportsWrite(integrationId), !onlyAddingAxes || requestedWrite {
                    integrationOverrides["write"] = requestedWrite
                }
            }
            if !integrationOverrides.isEmpty { overrides[integrationId] = integrationOverrides }
            dict["_operatorOverrides"] = .object(overrides.mapValues { axes in
                .object(axes.mapValues(JSONValue.bool))
            })
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

        // Authority metadata has an exact, supported per-axis Boolean shape.
        // Malformed metadata cannot quietly fall back to Full Mac admission.
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
                      // The same support clamps the writer applies: an axis
                      // the integration has no concept of is false on both
                      // sides of every receipt this store ever wrote, so a
                      // receipt claiming spotlight was granted WRITE is not
                      // one of ours.
                      MacIntegrationID.supportsRead(integrationID)
                        || (!beforeRead && !afterRead),
                      MacIntegrationID.supportsWrite(integrationID)
                        || (!beforeWrite && !afterWrite),
                      case .object(let provenance)? = object["provenance"],
                      case .string(let provenanceKind)? = provenance["kind"],
                      ["local", "signed_ios", "agent"].contains(provenanceKind),
                      case .string(let decidedBy)? = provenance["decidedBy"],
                      !decidedBy.isEmpty, decidedBy.utf8.count <= 128,
                      case .string(let recordedAt)? = object["recordedAt"], !recordedAt.isEmpty else {
                    throw MacIntegrationPermissionStoreError.malformedStore
                }
                // The reader mirrors the WRITER's per-kind invariants. A reader
                // that accepts provenance no writer of this store could have
                // produced is a reader that will believe a hand-edited receipt:
                // an "agent" row deciding as someone else, or a "local" row
                // wearing a client identity it cannot have.
                // The KEY's presence is the fact, not whether it happens to
                // hold a string. Mapping any non-string `clientId` to nil let a
                // hand-edited local row carry a client identity — a number, an
                // object, a null — and still read as the local row that never
                // has one.
                let clientIDValue = provenance["clientId"]
                let clientID: String? = {
                    guard case .string(let value)? = clientIDValue else { return nil }
                    // Trimmed exactly as `setWithReceipt` trims it before
                    // writing, so the bounds below are checked on the same
                    // bytes the writer bounded.
                    return value.trimmingCharacters(in: .whitespacesAndNewlines)
                }()
                switch provenanceKind {
                case "local":
                    // `.local()` never carries one; a local row that does was
                    // not written here.
                    guard clientIDValue == nil else {
                        throw MacIntegrationPermissionStoreError.malformedStore
                    }
                default:
                    // Both non-local kinds name WHICH client decided: the
                    // paired device, or the card the agent answered.
                    guard let clientID, !clientID.isEmpty, clientID.utf8.count <= 256 else {
                        throw MacIntegrationPermissionStoreError.malformedStore
                    }
                    // The agent path has exactly one decider, and it is not a
                    // free-text field: `.agent(interactionID:)` writes this
                    // name and nothing else does.
                    if provenanceKind == "agent", decidedBy != "agent_interaction_act" {
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

    /// Called only after strict document/receipt validation. Legacy stores did
    /// not record additive-vs-replacement intent. Supported reads default ON,
    /// so a saved read-OFF is a revocation even without a receipt. Default
    /// write-OFF still needs a changed human axis to establish an override.
    /// On the next normal mutation this migration is persisted before receipts
    /// can rotate away.
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

    private nonisolated static func denyAllPermissions() -> [String: MacIntegrationPermission] {
        Dictionary(
            uniqueKeysWithValues: MacIntegrationID.all.map {
                ($0, MacIntegrationPermission(read: false, write: false))
            }
        )
    }
}

/// A macOS privacy (TCC) capability the app depends on.
public enum SystemPermissionCapability: String, CaseIterable, Sendable {
    case speechRecognition
    case microphone
    case accessibility
    case location
    case fullDiskAccess
    case screenRecording
    case inputMonitoring
    case automation
    case calendars
    case reminders
    case contacts
    case notifications

    public var displayName: String {
        switch self {
        case .speechRecognition: return "Speech Recognition"
        case .microphone: return "Microphone"
        case .accessibility: return "Accessibility"
        case .location: return "Location Services"
        case .fullDiskAccess: return "Full Disk Access"
        case .screenRecording: return "Screen Recording"
        case .inputMonitoring: return "Input Monitoring"
        case .automation: return "Automation"
        case .calendars: return "Calendar"
        case .reminders: return "Reminders"
        case .contacts: return "Contacts"
        case .notifications: return "Notifications"
        }
    }

    /// macOS Privacy & Security anchor; Notifications has its own pane.
    public var settingsAnchor: String? {
        switch self {
        case .speechRecognition: return "Privacy_SpeechRecognition"
        case .microphone: return "Privacy_Microphone"
        case .accessibility: return "Privacy_Accessibility"
        case .location: return "Privacy_LocationServices"
        case .fullDiskAccess: return "Privacy_AllFiles"
        case .screenRecording: return "Privacy_ScreenCapture"
        case .inputMonitoring: return "Privacy_ListenEvent"
        case .automation: return "Privacy_Automation"
        case .calendars: return "Privacy_Calendars"
        case .reminders: return "Privacy_Reminders"
        case .contacts: return "Privacy_Contacts"
        case .notifications: return nil
        }
    }
}

public enum SystemPermissionStatus: String, Sendable {
    case granted
    case denied
    case restricted
    case notDetermined
    case unknown
}

public struct SystemPermissionSnapshot: Sendable, Equatable {
    public let capability: SystemPermissionCapability
    public let status: SystemPermissionStatus
    public let detail: String

    public init(capability: SystemPermissionCapability, status: SystemPermissionStatus, detail: String = "") {
        self.capability = capability
        self.status = status
        self.detail = detail
    }
}

public enum SystemPermissionPreflight {
    /// Posted by any permission source that learns of a change in-process (a
    /// Location answer); the card port re-checks its waiting cards on it.
    public static let permissionDidChange = Notification.Name("NativeAgent.SystemPermissionPreflight.permissionDidChange")
    private static let logger = Logger(subsystem: "com.nativeagent.app", category: "permission-preflight")

    public typealias SpeechAuthorizationRequest = @Sendable (
        @escaping @Sendable (SFSpeechRecognizerAuthorizationStatus) -> Void
    ) -> Void

    public static let settingsPanePrefix = "x-apple.systempreferences:com.apple.preference.security?"

    /// Full System Settings deep link for a capability.
    public static func settingsURL(for capability: SystemPermissionCapability) -> URL? {
        if capability == .notifications {
            return URL(string: "x-apple.systempreferences:com.apple.Notifications-Settings.extension")
        }
        guard let anchor = capability.settingsAnchor else { return nil }
        return URL(string: settingsPanePrefix + anchor)
    }

    /// A grant macOS hands a process only when it launches: System Settings
    /// itself offers "Quit & Reopen" for these.
    public static let appliesAtLaunch: Set<SystemPermissionCapability> =
        [.accessibility, .fullDiskAccess, .screenRecording, .inputMonitoring]

    /// The launch-applied grants this process started with, read once at
    /// launch (the app touches it first thing).
    public static let grantedAtLaunch = Set(appliesAtLaunch.filter { status($0) == .granted })

    /// The grants among a card's ids that macOS shows on now but this process
    /// started without: it has them only after it restarts, whatever its
    /// probe says now.
    public static func awaitingLaunch(_ ids: [String]) -> [SystemPermissionCapability] {
        var seen: Set<SystemPermissionCapability> = []
        return ids.compactMap(cardSettingsCapability).filter {
            appliesAtLaunch.contains($0) && !grantedAtLaunch.contains($0)
                && status($0) == .granted && seen.insert($0).inserted
        }
    }

    public static func cardSettingsCapability(_ id: String) -> SystemPermissionCapability? {
        if id.hasPrefix("privacy:") {
            let capability = SystemPermissionCapability(rawValue: String(id.dropFirst(8)))
            return capability == .automation ? nil : capability
        }
        if SystemAppleScriptAdapter.automationTarget(id) != nil { return .automation }
        switch id {
        case "calendar": return .calendars
        case "reminders": return .reminders
        case "contacts": return .contacts
        case "accessibility": return .accessibility
        case "location": return .location
        case "screen_capture", "screen_recording": return .screenRecording
        case "input_monitoring": return .inputMonitoring
        case "full_disk_access", "messages": return .fullDiskAccess
        case "speech_recognition": return .speechRecognition
        case "microphone": return .microphone
        case "notifications", "notify_mac": return .notifications
        default: return nil
        }
    }

    public static func cardSettingsInstructions(_ ids: [String]) -> [String] {
        var seen: Set<SystemPermissionCapability> = []
        return ids.compactMap { id in
            guard let pane = cardSettingsCapability(id), seen.insert(pane).inserted else { return nil }
            return pane == .fullDiskAccess
                ? "Add NativeAgent from Finder to the pane that opens, then turn it on."
                : "Allow \(pane.displayName) on this card; turn on NativeAgent in the pane that opens."
        }
    }

    public static func remedy(_ id: String, mode: InlineInteraction.AccessMode? = nil) -> JSONValue? {
        guard let capability = cardSettingsCapability(id) else { return nil }
        let target = SystemAppleScriptAdapter.automationTarget(id).map { "applescript:" + $0 }
            ?? capability.rawValue
        let name = SystemAppleScriptAdapter.automationTarget(id).map { "Automation for " + $0 } ?? capability.displayName
        var args: [String: JSONValue] = ["capability": .string(target), "why": .string("NativeAgent needs \(name) for this work. Allow?")]
        if let mode { args["mode"] = .string(mode.rawValue) }
        return Repair.remedy(owner: "macOS \(name) grant", nextCall: .object([
            "tool": .string("app"), "input": .object(["action": .string("permissions.request"), "args": .object(args)]),
        ]), tap: "Allow \(name) on the permission card in NativeAgent")
    }

    // MARK: - Non-prompting reads

    /// Reads the current TCC state. **MUST NEVER PROMPT.** Every call below is
    /// the query-only variant of its framework's API; the requesting variants
    /// (`SFSpeechRecognizer.requestAuthorization`,
    /// `CGRequestScreenCaptureAccess`, `AXIsProcessTrustedWithOptions` with
    /// `kAXTrustedCheckOptionPrompt: true`,
    /// `AEDeterminePermissionToAutomateTarget(askUserIfNeeded: true)`) are
    /// deliberately absent. A prompt fired from a background context is not just
    /// invisible — macOS resolves it to a hard `.denied` the user can never undo
    /// from inside the app, which is the exact bug this file exists to fix.
    public static func status(_ capability: SystemPermissionCapability) -> SystemPermissionStatus {
        switch capability {
        case .speechRecognition:
            // Class-level READ. Not requestAuthorization.
            switch SFSpeechRecognizer.authorizationStatus() {
            case .authorized: return .granted
            case .denied: return .denied
            case .restricted: return .restricted
            case .notDetermined: return .notDetermined
            @unknown default: return .unknown
            }
        case .microphone:
            switch AVCaptureDevice.authorizationStatus(for: .audio) {
            case .authorized: return .granted
            case .denied: return .denied
            case .restricted: return .restricted
            case .notDetermined: return .notDetermined
            @unknown default: return .unknown
            }
        case .accessibility:
            // AXIsProcessTrusted() is the no-prompt form; the prompting form is
            // AXIsProcessTrustedWithOptions with kAXTrustedCheckOptionPrompt.
            // AX exposes no notDetermined/restricted distinction — it is a
            // boolean trust bit — so a non-trusted process reads as .denied.
            return AXIsProcessTrusted() ? .granted : .denied
        case .location:
            guard CLLocationManager.locationServicesEnabled() else { return .denied }
            switch MacLocationReader.authorizationStatus {
            case .authorizedAlways, .authorizedWhenInUse: return .granted
            case .denied: return .denied
            case .restricted: return .restricted
            case .notDetermined: return .notDetermined
            @unknown default: return .unknown
            }
        case .fullDiskAccess:
            return MacMessagesHistory.hasAccess ? .granted : .denied
        case .screenRecording:
            // CGPreflightScreenCaptureAccess is the preflight (no prompt);
            // CGRequestScreenCaptureAccess is the prompting sibling.
            return CGPreflightScreenCaptureAccess() ? .granted : .denied
        case .inputMonitoring:
            return CGPreflightListenEventAccess() ? .granted : .denied
        case .calendars:
            return mapEKStatus(EKEventStore.authorizationStatus(for: .event))
        case .reminders:
            return mapEKStatus(EKEventStore.authorizationStatus(for: .reminder))
        case .contacts:
            switch CNContactStore.authorizationStatus(for: .contacts) {
            case .authorized: return .granted
            case .limited: return .granted
            case .denied: return .denied
            case .restricted: return .restricted
            case .notDetermined: return .notDetermined
            @unknown default: return .unknown
            }
        case .automation, .notifications:
            // No CHEAP non-prompting read exists here.
            // Automation: AEDeterminePermissionToAutomateTarget is per-target,
            // requires the target app to be running, and the only variant that
            // resolves a not-yet-determined grant is askUserIfNeeded:true —
            // which prompts. MacIntegrationView owns that per-app probe.
            // Notifications: UNUserNotificationCenter's settings read is async
            // and requires a bundled, registered app.
            return .unknown
        }
    }

    private static func mapEKStatus(_ status: EKAuthorizationStatus) -> SystemPermissionStatus {
        switch status {
        case .authorized: return .granted
        case .denied: return .denied
        case .restricted: return .restricted
        case .notDetermined: return .notDetermined
        case .fullAccess: return .granted
        case .writeOnly:
            // NOT .granted. Write-only means the app may add events but cannot
            // READ them, and every calendar/reminder capability this app
            // surfaces (briefings, watch jobs, mac_calendar_list_upcoming) is a
            // read. Reporting .granted here would show a green row while those
            // reads keep failing — the same "looks fine, silently broken" shape
            // this whole file exists to kill. MacPIMConnectorActions already
            // treats write-only as not read-ready; match it.
            return .denied
        @unknown default: return .unknown
        }
    }

    /// The permission card owns acquisition; status reads never prompt.
    public static func warningSummary(for snapshot: SystemPermissionSnapshot) -> String {
        let name = snapshot.capability.displayName
        switch snapshot.status {
        case .notDetermined, .denied:
            return "NativeAgent needs \(name). Allow it on the permission card."
        case .restricted:
            return "\(name) is restricted by this Mac's administrator. Ask them to allow NativeAgent."
        case .granted, .unknown:
            return "\(name): \(snapshot.status.rawValue)."
        }
    }

    // MARK: - Foreground acquisition

    /// Bridges Speech's callback without inheriting the caller's actor.
    ///
    /// `SFSpeechRecognizer.requestAuthorization` is invoked from the main actor
    /// so macOS can present its consent sheet, but TCC delivers the completion
    /// on an arbitrary dispatch queue. Defining the continuation bridge as
    /// `nonisolated` is essential: otherwise Swift 6 actor inference makes the
    /// callback main-actor isolated and traps when TCC calls it off-main.
    public nonisolated static func awaitSpeechAuthorization(
        using request: SpeechAuthorizationRequest = { completion in
            SFSpeechRecognizer.requestAuthorization(completion)
        }
    ) async -> SFSpeechRecognizerAuthorizationStatus {
        await withCheckedContinuation { continuation in
            request { status in
                continuation.resume(returning: status)
            }
        }
    }

    /// Fires the macOS Speech Recognition consent prompt — but ONLY from the
    /// main actor, and ONLY when the grant is still `.notDetermined`.
    ///
    /// Why main-actor/foreground is not a style preference:
    /// `SFSpeechRecognizer.requestAuthorization` from a headless context (a
    /// background poll loop, a detached utility task with no active app) cannot
    /// render its prompt. macOS does not queue it for later — it resolves the
    /// request `.denied` immediately, WITHOUT writing a real user decision into
    /// the TCC database. The user is then stuck: the app looks denied, the
    /// system never asked, and no in-app button can re-ask, because TCC will not
    /// re-prompt a resolved grant. That is precisely how the Telegram voice-note
    /// path bricked itself (`data/telegram/errors.jsonl`,
    /// context=voice_transcription, speechPermissionDenied("denied")).
    ///
    /// Reading first is the other half of the guard: calling request on an
    /// already-denied grant is a silent no-op, so callers must route those to
    /// System Settings instead of showing a button that appears to do nothing.
    @MainActor
    public static func requestSpeechRecognitionIfNotDetermined() async -> SystemPermissionStatus {
        let current = status(.speechRecognition)
        guard current == .notDetermined else {
            logger.info(
                "speech-recognition preflight: already resolved (\(current.rawValue, privacy: .public)); no prompt fired"
            )
            return current
        }
        let resolved = await awaitSpeechAuthorization()
        let mapped: SystemPermissionStatus
        switch resolved {
        case .authorized: mapped = .granted
        case .denied: mapped = .denied
        case .restricted: mapped = .restricted
        case .notDetermined: mapped = .notDetermined
        @unknown default: mapped = .unknown
        }
        logger.info(
            "speech-recognition preflight: prompt resolved \(mapped.rawValue, privacy: .public)"
        )
        return mapped
    }
}

/// Where this Mac is: a fact it holds, like the time. Its one location manager,
/// kept for the app's life, holds the newest fix CoreLocation gave, and a read
/// answers with it and its age at once. A fix older than `freshness` also asks
/// CoreLocation for the next read; only with no fix held does a read wait, for
/// `answer` at most. A manager made per call cold-started CoreLocation each
/// time and timed out with a grant in place.
@MainActor
public final class MacLocationReader: NSObject, @preconcurrency CLLocationManagerDelegate {
    private static let shared = MacLocationReader()
    private let manager = CLLocationManager()
    private var waiters: [CheckedContinuation<JSONValue, Never>] = []
    private var deadline: Task<Void, Never>?
    /// The kept manager's status, readable from any thread; a manager made per
    /// read answered notDetermined for a moment after launch.
    nonisolated(unsafe) private static var knownStatus: CLAuthorizationStatus?
    public nonisolated static var authorizationStatus: CLAuthorizationStatus {
        if let knownStatus { return knownStatus }
        Task { @MainActor in _ = shared }
        return CLLocationManager().authorizationStatus
    }
    /// A held fix this old asks for a fresh one, for the next read.
    private static let freshness: TimeInterval = 300
    /// With no fix held: CoreLocation gives one this fast or not at all (measured 0.6–1.4 s).
    private static let answer: Duration = .seconds(2)

    override private init() {
        super.init()
        manager.delegate = self
        manager.desiredAccuracy = kCLLocationAccuracyKilometer
        Self.knownStatus = manager.authorizationStatus
    }

    public static func requestAuthorization() {
        if shared.manager.authorizationStatus == .notDetermined {
            shared.manager.requestWhenInUseAuthorization()
        }
    }

    public static func read() async -> JSONValue { await shared.read() }

    /// The newest fix CoreLocation gave this Mac.
    private var held: CLLocation? {
        guard let fix = manager.location, fix.horizontalAccuracy >= 0 else { return nil }
        return fix
    }

    private func read() async -> JSONValue {
        if let held {
            if -held.timestamp.timeIntervalSinceNow >= Self.freshness, deadline == nil { request() }
            return Self.fix(held)
        }
        guard !Task.isCancelled else { return Self.failure("cancelled", "The location read was cancelled.") }
        return await withCheckedContinuation { continuation in
            waiters.append(continuation)
            if waiters.count == 1 { request() }
        }
    }

    /// Not yet asked: macOS's own prompt asks, and its answer fetches the first fix.
    private func request() {
        switch manager.authorizationStatus {
        case .authorizedAlways, .authorizedWhenInUse:
            manager.requestLocation()
            deadline?.cancel()
            deadline = Task {
                do { try await Task.sleep(for: Self.answer) } catch { return }
                finish()
            }
        default: finish(Self.failure("location_not_allowed", "NativeAgent needs Location Services. Allow it on the permission card."))
        }
    }

    public func locationManagerDidChangeAuthorization(_ manager: CLLocationManager) {
        Self.knownStatus = manager.authorizationStatus
        // A card waiting on this permission settles on the answer, whoever gave it.
        NotificationCenter.default.post(name: SystemPermissionPreflight.permissionDidChange, object: nil)
    }

    /// The fix just given is the one the manager now holds.
    public func locationManager(_ manager: CLLocationManager, didUpdateLocations locations: [CLLocation]) { finish() }

    public func locationManager(_ manager: CLLocationManager, didFailWithError error: Error) {
        finish(Self.noFix(error.localizedDescription))
    }

    private static func fix(_ location: CLLocation) -> JSONValue {
        // An answer under a grant settles any card still waiting on it.
        NotificationCenter.default.post(name: SystemPermissionPreflight.permissionDidChange, object: nil)
        return .object(["status": .string("ok"), "effects": .string("none"),
            "latitude": .double(location.coordinate.latitude), "longitude": .double(location.coordinate.longitude),
            "accuracy_m": .double(location.horizontalAccuracy),
            "at": .string(ISO8601DateFormatter().string(from: location.timestamp)),
            "age_seconds": .int(Int64(max(0, -location.timestamp.timeIntervalSinceNow))), "source": .string("this Mac")])
    }

    private static func noFix(_ why: String) -> JSONValue {
        failure("location_unavailable", "This Mac has no location fix: \(why) Try phone.location or give a place.")
    }

    private static func failure(_ reason: String, _ detail: String) -> JSONValue {
        .object(["status": .string("failed"), "reason": .string(reason), "detail": .string(detail), "effects": .string("none"),
                 "remedy": reason == "location_not_allowed" ? SystemPermissionPreflight.remedy("location") ?? .null : .null])
    }

    /// Every waiting read gets the fix the Mac holds, however old, with its age; with none, why not.
    private func finish(_ none: JSONValue = MacLocationReader.noFix("CoreLocation gave none.")) {
        deadline?.cancel()
        deadline = nil
        let result = held.map(Self.fix) ?? none
        let waiting = waiters
        waiters = []
        for continuation in waiting { continuation.resume(returning: result) }
    }
}

// MARK: - Setup cards

extension SystemPermissionPreflight {
    /// The first macOS switch still off for these ids, as the one sentence of
    /// what to click; nil when macOS has nothing against it.
    public static func cardBlockReason(_ ids: [String], mode: InlineInteraction.AccessMode?) async -> String? {
        for id in ids {
            guard let gate = cardSettingsCapability(id) else { continue }
            if let bundleID = SystemAppleScriptAdapter.automationTarget(id) {
                let permission = await SystemAppleScriptAdapter.automationPermission(bundleID: bundleID)
                guard case .object(let fields) = permission, fields["state"] == .string("allowed") else {
                    return (try? permission.serialize(pretty: false)) ?? "Automation consent unavailable."
                }
                continue
            }
            let current: SystemPermissionStatus
            if gate == .notifications {
                let settings = await UNUserNotificationCenter.current().notificationSettings()
                switch settings.authorizationStatus {
                case .authorized, .provisional: current = .granted
                case .notDetermined: current = .notDetermined
                case .denied: current = .denied
                default: current = .unknown
                }
            } else { current = cardStatus(gate, mode: mode) }
            if current == .granted { continue }
            if current == .unknown {
                return "macOS hasn't confirmed \(gate.displayName) yet."
            }
            return "macOS hasn't allowed \(gate.displayName) yet. Return after turning it on; I'll continue."
        }
        return nil
    }

    /// Only a real grant counts. A Calendar WRITE card is satisfied by
    /// macOS's write-only access as well as full access.
    public static func cardStatus(
        _ gate: SystemPermissionCapability, mode: InlineInteraction.AccessMode?
    ) -> SystemPermissionStatus {
        guard gate == .calendars, mode == .write else { return status(gate) }
        switch EKEventStore.authorizationStatus(for: .event) {
        case .writeOnly, .fullAccess, .authorized: return .granted
        case .notDetermined: return .notDetermined
        case .restricted: return .restricted
        default: return .denied
        }
    }

}
