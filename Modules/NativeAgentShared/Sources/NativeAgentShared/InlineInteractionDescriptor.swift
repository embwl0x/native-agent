import Foundation

// Blueprint: | `InlineInteractionDescriptor.swift` | Registry-supplied control/location bindings and shared `InlineCardField` connector vocabulary for Mac and phone |

/// What the card needs to know about the thing being asked for, and WHICH
/// existing control resolves it.
///
/// Renderers select an existing control and render its shared field description.
/// Connector setup and field vocabulary add no service branch to either renderer.
///
/// A descriptor never carries a URL, a selector, a settings path, or anything
/// else executable. `control` is a CLOSED enum of controls this app already
/// ships; the app maps it to the real sheet. An id with no control resolves to
/// `.unavailable` and the card says so rather than offering a dead button.
public struct InlineInteractionDescriptor: Codable, Sendable, Equatable {
    /// Which existing control opens. Closed by construction: the model cannot
    /// invent one, and a build that does not know a value decodes `.unknown`.
    public enum Control: String, Codable, Sendable, Equatable {
        /// Connectors' own setup: a manual token paste (Slack, Telegram).
        case connectorManualToken = "connector_manual_token"
        case internetAccounts = "internet_accounts"
        /// Trust's Chrome switch, the extension folder and Chrome's extensions
        /// page, settled when the extension connects.
        case chromeSetup = "chrome_setup"
        /// The iPhone pairing page, settled when a phone is paired.
        case pairDevice = "pair_device"
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
        /// The keyring: a pasted secret, or a sign-in NativeAgent runs.
        case keyring
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

    /// The setup's owning surface. Native setup and browser sign-in stay on
    /// the Mac; supported phone controls can submit sealed input.
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

    public var connectorFields: [InlineCardField] {
        let stays = "Your key stays on this Mac. It never goes into the chat."
        switch target.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() {
        case "telegram":
            return [
                InlineCardField(label: "Bot token", placeholder: "123456789:ABC… from @BotFather",
                                helper: stays, id: "token"),
                InlineCardField(label: "Allowed chat ID", placeholder: "Numeric chat ID",
                                helper: "Send your bot a message, then open Telegram setup and use Check sender to find your ID. Only a recipient you admit can reach the agent.",
                                isSecret: false, id: "allowed_chat_id"),
            ]
        case "slack":
            return [
                InlineCardField(label: "Slack bot token", placeholder: "xoxb-...", helper: stays, id: "token"),
                InlineCardField(label: "Socket Mode app token (optional)", placeholder: "xapp-...",
                                helper: "Slack chat needs it; it can be added later.",
                                id: "app_token", isOptional: true),
                InlineCardField(label: "Allowed channel IDs", placeholder: "C0123, C0456",
                                isSecret: false, id: "allowed_channels", isOptional: true),
                InlineCardField(label: "Allowed user IDs", placeholder: "U0123",
                                helper: "Add at least one channel or user.",
                                isSecret: false, id: "allowed_users", isOptional: true),
            ]
        default:
            return []
        }
    }
}

/// One value the card collects. Secrets never become transcript content.
public struct InlineCardField: Sendable, Equatable {
    public var label: String
    public var placeholder: String
    public var helper: String?
    public var isSecret: Bool
    /// The key the value travels under when a card collects several.
    public var id: String
    /// An optional field never holds the primary back.
    public var isOptional: Bool

    public init(label: String, placeholder: String, helper: String? = nil, isSecret: Bool = true,
         id: String = "value", isOptional: Bool = false) {
        self.label = label
        self.placeholder = placeholder
        self.helper = helper
        self.isSecret = isSecret
        self.id = id
        self.isOptional = isOptional
    }
}
