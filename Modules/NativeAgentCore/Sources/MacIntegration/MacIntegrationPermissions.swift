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
// Blueprint: | `MacIntegrationPermissions.swift` | Integration identity, consent values and mutation provenance; persisted integration IDs are stable |

// MARK: - Mac Integration permissions
//
// `MacIntegrationPermissionStore.shared.allows` gates host effects; explicit OFF wins over Full Mac.
// Supported reads default on; writes default off except notifications and scheduler.
// Writes require a grant or admitted Full Mac. Authority lives in security/mac_integration_permissions.json.
// PersistenceCore serializes atomic writes under the file's cross-process flock.

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

/// Read-only readiness evidence. Explicit revocations are distinct from the untouched defaults that an admitted Full Mac conversation may cover.
public struct MacIntegrationPermissionReadiness: Sendable {
    public let operatorReadOff: Set<String>
    public let operatorWriteOff: Set<String>

    public func refusal(integration: String, mode: MacIntegrationPermissionMode) -> String? {
        guard (mode == .read ? operatorReadOff : operatorWriteOff).contains(integration) else { return nil }
        if integration == MacIntegrationID.mail, mode == .write {
            return "operator_permission_off: Mail Write is off. Only the owner can enable Trust > Mac > Apps and features > Mail > Write. For Mail content, use mail.recent, mail.search or mail.read; do not open or screen-read Mail."
        }
        return "operator_permission_off: \(MacIntegrationID.displayName(for: integration)) \(mode.rawValue.capitalized) is off. Only the owner can enable Trust > Mac > Apps and features > \(MacIntegrationID.displayName(for: integration)) > \(mode.rawValue.capitalized)."
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

    /// An agent decision names its exact card, independently of operator decisions.
    public static func agent(interactionID: String) -> Self {
        Self(kind: "agent", decidedBy: "agent_interaction_act", clientID: interactionID)
    }

    var isValid: Bool {
        guard !decidedBy.isEmpty, decidedBy.utf8.count <= 128 else { return false }
        switch kind {
        case "local": return clientID == nil
        case "signed_ios", "agent":
            return clientID?.isEmpty == false && (clientID?.utf8.count ?? 0) <= 256
                && (kind != "agent" || decidedBy == "agent_interaction_act")
        default: return false
        }
    }

    var json: JSONValue {
        var fields: [String: JSONValue] = ["kind": .string(kind), "decidedBy": .string(decidedBy)]
        if let clientID { fields["clientId"] = .string(clientID) }
        return .object(fields)
    }
}

/// Persistence failures are authority failures, not permission defaults. Only a missing store may bootstrap from `defaultPermission(for:)`.
public enum MacIntegrationPermissionStoreError: Error, Sendable, Equatable, LocalizedError {
    case unreadableStore
    case malformedStore
    case invalidRoot
    case invalidKnownEntry(String)
    case invalidKnownAxis(integrationID: String, axis: String)
    case wouldGainAxes([String])

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
        case .wouldGainAxes(let axes):
            return "A lower-only permission change cannot give \(axes.joined(separator: " and ")) access."
        }
    }
}

// MARK: - Stable identifiers

/// Stable string IDs for each Mac integration. UI rows + tool dispatch both reference these strings — do NOT rename without a migration step that rewrites the on-disk permissions file.
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
        case music:        return "See now-playing + control playback (write = play/pause/stop/skip)"
        case notifyMac:    return "Send Mac notifications"
        case notifyMobile: return "Send notifications to paired iPhone"
        case spotlight:    return "Search via Spotlight"
        case scheduler:    return "Schedule future-firing jobs"
        default:           return ""
        }
    }

    // MARK: - Axis support

    /// True iff the integration has a meaningful "read" axis. notify_mac / notify_mobile / scheduler are send-only — no read concept.
    public static func supportsRead(_ id: String) -> Bool {
        switch id {
        case notifyMac, notifyMobile, scheduler:
            return false
        default:
            return true
        }
    }

    /// True iff the integration has a meaningful "write" axis. Spotlight is search-only — no write concept.
    public static func supportsWrite(_ id: String) -> Bool {
        switch id {
        case spotlight:
            return false
        default:
            return true
        }
    }

    // MARK: - Defaults

    /// the user's chosen defaults — read ON for everything that has a read axis, write OFF for the sensitive surfaces (contacts/mail/messages/notes/ music), write ON for notifications + scheduler (she already uses these and the user trusts
    /// them). For an axis the integration doesn't support, the returned value on that axis is `false` (no concept).
    public static func defaultPermission(for id: String) -> MacIntegrationPermission {
        let read = supportsRead(id) // default ON for every read-capable surface
        let write: Bool
        switch id {
        case notifyMac, notifyMobile, scheduler:
            write = true
        default:
            write = false
        }
        // Spotlight has no write axis — clamp to false even though the switch above would default it to false; this keeps the rule explicit.
        let writeClamped = supportsWrite(id) ? write : false
        return MacIntegrationPermission(read: read, write: writeClamped)
    }
}
