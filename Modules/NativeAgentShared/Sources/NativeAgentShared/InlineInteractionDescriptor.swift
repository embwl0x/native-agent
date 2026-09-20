import Foundation

/// What the card needs to know about the thing being asked for, and WHICH
/// existing control resolves it.
///
/// The point of the descriptor is that the card renderer switches on six
/// interaction kinds and never on a service name. Adding a connector adds a
/// row to the connector registry; it adds no card code, no button code, and
/// no branch here.
///
/// A descriptor never carries a URL, a selector, a settings path, or anything
/// else executable. `control` is a CLOSED enum of controls this app already
/// ships; the app maps it to the real sheet. An id with no control resolves to
/// `.unavailable` and the card says so rather than offering a dead button.
public struct InlineInteractionDescriptor: Codable, Sendable, Equatable {
    /// Which existing control opens. Closed by construction: the model cannot
    /// invent one, and a build that does not know a value decodes `.unknown`.
    public enum Control: String, Codable, Sendable, Equatable {
        /// Connectors' own setup: a manual token paste (GitHub, Slack, Notion).
        case connectorManualToken = "connector_manual_token"
        /// Connectors' native OAuth flow.
        case connectorOAuth = "connector_oauth"
        case internetAccounts = "internet_accounts"
        /// Trust's Mac Control switch plus the per-capability grant.
        case macPermissionGrant = "mac_permission_grant"
        /// The Trust POSTURE forbids this capability outright, so no card may
        /// grant it: Safe and Workspace are the person's own standing choice
        /// and a card never changes them. The only honest control is the page
        /// where that choice lives.
        case trustPostureRequired = "trust_posture_required"
        /// Providers' group model save.
        case providerGroupModel = "provider_group_model"
        /// Providers' API-key sheet.
        case providerAPIKey = "provider_api_key"
        /// A capability flag write through Trust's own writer.
        case capabilityFlag = "capability_flag"
        /// An answer picked in the card itself; nothing outside opens.
        case inlineChoice = "inline_choice"
        /// Known id, no executable control on this build. Renders unavailable.
        case unavailable
        case unknown

        public init(from decoder: any Decoder) throws {
            let raw = try decoder.singleValueContainer().decode(String.self)
            self = Control(rawValue: raw) ?? .unknown
        }

        /// True when the card may offer a working primary action.
        public var isActionable: Bool {
            switch self {
            case .unavailable, .unknown: return false
            default: return true
            }
        }
    }

    /// Where the action can actually be completed. API keys, OAuth that needs
    /// the Mac, and macOS permission prompts are Mac-only; the phone shows
    /// "Continue on Mac" instead of a dead control.
    public enum Location: String, Codable, Sendable, Equatable {
        case anywhere
        case macRequired = "mac_required"

        public init(from decoder: any Decoder) throws {
            let raw = try decoder.singleValueContainer().decode(String.self)
            self = Location(rawValue: raw) ?? .anywhere
        }
    }

    public var kind: InlineInteraction.Kind
    public var target: String
    public var displayName: String
    /// SF Symbol name, when the registry knows one.
    public var icon: String?
    public var control: Control
    public var location: Location
    /// Why the control is unavailable, when it is. One sentence, shown as-is.
    public var unavailableReason: String?

    public init(
        kind: InlineInteraction.Kind,
        target: String,
        displayName: String,
        icon: String? = nil,
        control: Control,
        location: Location = .anywhere,
        unavailableReason: String? = nil
    ) {
        self.kind = kind
        self.target = target
        self.displayName = displayName
        self.icon = icon
        self.control = control
        self.location = location
        self.unavailableReason = unavailableReason
    }

    public var isActionable: Bool { control.isActionable }
}
