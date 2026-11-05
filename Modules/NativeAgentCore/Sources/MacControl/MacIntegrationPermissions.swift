import Foundation
import NativeAgentCore
import PersistenceCore
// Blueprint: | `MacIntegrationPermissions.swift` | Integration identity, consent values and mutation provenance; persisted integration IDs are stable |

// MARK: - Mac Integration permissions
// Explicit OFF fences Full Mac; supported reads default on, writes off except notifications and scheduler. The permission store owns authority; PersistenceCore
// serializes atomic writes with a cross-process flock.

// MARK: - Public types

public struct MacIntegrationPermission: Sendable, Codable, Equatable {
    public var read: Bool
    public var write: Bool
    public init(read: Bool, write: Bool) {
        self.read = read
        self.write = write
    }
}

/// Readiness distinguishes explicit revocations from untouched defaults admitted Full Mac may cover.
public struct MacIntegrationPermissionReadiness: Sendable {
    public let operatorReadOff: Set<String>
    public let operatorWriteOff: Set<String>

    public func refusal(integration: String, mode: MacIntegrationPermissionMode) -> String? {
        guard (mode == .read ? operatorReadOff : operatorWriteOff).contains(integration) else { return nil }
        let name = MacIntegrationID.displayName(for: integration)
        let hands = mode == .write && !MacIntegrationID.appBundleIDs(for: integration).isEmpty
            ? " You can look but not act in \(name)." : ""
        return """
            operator_permission_off: \(name) \(mode.rawValue.capitalized) is off.\(hands) Only the owner can enable Trust > Mac > Apps and features > \(name) \
            > \(mode.rawValue.capitalized).
            """
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
            return "The saved Mac Integration permission for \(id) must be a JSON object containing exactly every supported axis as a Boolean."
        case .invalidKnownAxis(let id, let axis):
            return "The saved Mac Integration permission \(id).\(axis) must be a Boolean."
        case .wouldGainAxes(let axes):
            return "A lower-only permission change cannot give \(axes.joined(separator: " and ")) access."
        }
    }
}

// MARK: - Stable identifiers

/// UI, dispatch and stored authority share these ids; renaming one requires rewriting its stored key.
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

    /// Integration ownership applies equally to tools and physical input.
    public static func appBundleIDs(for id: String) -> [String] {
        switch id {
        case mail: ["com.apple.mail"]
        case messages: ["com.apple.MobileSMS"]
        case notes: ["com.apple.Notes"]
        case contacts: ["com.apple.AddressBook"]
        case calendar: ["com.apple.iCal"]
        case reminders: ["com.apple.reminders"]
        case music: ["com.apple.Music"]
        default: []
        }
    }

    public static func owning(appBundleID: String) -> String? {
        all.first { appBundleIDs(for: $0).contains(appBundleID) }
    }

    public static let all: [String] = [
        calendar, reminders, contacts, mail, messages, notes, music,
        notifyMac, notifyMobile, spotlight, scheduler,
    ]

    // MARK: - UI strings

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

    public static func description(for id: String) -> String {
        switch id {
        case calendar:     return "Read events; Write permits changes and hands in Calendar"
        case reminders:    return "Read reminders; Write permits changes and hands in Reminders"
        case contacts:     return "Look up contacts; Write permits changes and hands in Contacts"
        case mail:         return "Read inbox; Write permits changes, sends and hands in Mail"
        case messages:     return "Read threads; Write permits sends and hands in Messages"
        case notes:        return "Search Notes; Write permits changes and hands in Notes"
        case music:        return "See now-playing; Write permits playback and hands in Music"
        case notifyMac:    return "Send Mac notifications"
        case notifyMobile: return "Send notifications to paired iPhone"
        case spotlight:    return "Search via Spotlight"
        case scheduler:    return "Schedule future-firing jobs"
        default:           return ""
        }
    }

    // MARK: - Axis support

    /// Send-only integrations have no read axis to grant.
    public static func supportsRead(_ id: String) -> Bool {
        switch id {
        case notifyMac, notifyMobile, scheduler:
            return false
        default:
            return true
        }
    }

    /// Search-only Spotlight has no write axis to grant.
    public static func supportsWrite(_ id: String) -> Bool {
        switch id {
        case spotlight:
            return false
        default:
            return true
        }
    }

    // MARK: - Defaults

    /// Shipped defaults are the user’s choice: supported reads on, sensitive writes off, notification and scheduler writes on. Unsupported axes remain false.
    public static func defaultPermission(for id: String) -> MacIntegrationPermission {
        let read = supportsRead(id)
        let write: Bool
        switch id {
        case notifyMac, notifyMobile, scheduler:
            write = true
        default:
            write = false
        }
        // Clamp unsupported writes independently of the switch default.
        let writeClamped = supportsWrite(id) ? write : false
        return MacIntegrationPermission(read: read, write: writeClamped)
    }
}
