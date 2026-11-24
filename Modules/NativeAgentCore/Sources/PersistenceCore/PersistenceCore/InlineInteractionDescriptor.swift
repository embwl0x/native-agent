import Foundation

// Blueprint: | `InlineInteractionDescriptor.swift` | A card's control binding and `InlineCardField` vocabulary, beside the record its owners keep; no executable descriptors |

/// Renderers select shared controls without service branches. Descriptors contain no executable URLs, selectors or paths; unknown controls remain
/// unavailable.
public struct InlineInteractionDescriptor: Codable, Sendable, Equatable {
    /// A closed enum prevents model-invented controls; unknown values remain inert.
    public enum Control: String, Codable, Sendable, Equatable {
        case connectorManualToken = "connector_manual_token"
        case internetAccounts = "internet_accounts"
        /// Chrome setup settles only when the extension connects.
        case chromeSetup = "chrome_setup"
        case pairDevice = "pair_device"
        case macPermissionGrant = "mac_permission_grant"
        /// Cards cannot change the person’s standing Trust posture; they must open its owning page.
        case trustPostureRequired = "trust_posture_required"
        case providerGroupModel = "provider_group_model"
        case providerAPIKey = "provider_api_key"
        case keyring
        /// Capability changes go through Trust’s writer.
        case capabilityFlag = "capability_flag"
        case inlineChoice = "inline_choice"
        /// Known id, no executable control on this build. Renders unavailable.
        case unavailable
        case unknown

        public init(from decoder: any Decoder) throws {
            let raw = try decoder.singleValueContainer().decode(String.self)
            self = Control(rawValue: raw) ?? .unknown
        }

        public var isActionable: Bool {
            switch self {
            case .unavailable, .unknown: return false
            default: return true
            }
        }
    }

    /// The setup's owning surface. Native setup and browser sign-in stay on the Mac; supported phone controls can submit sealed input.
    public enum Location: String, Codable, Sendable, Equatable {
        case anywhere
        case macRequired = "mac_required"

        public init(from decoder: any Decoder) throws {
            let raw = try decoder.singleValueContainer().decode(String.self)
            guard let value = Location(rawValue: raw) else {
                throw DecodingError.dataCorrupted(.init(codingPath: decoder.codingPath,
                    debugDescription: "Unknown Location: \(raw)"))
            }
            self = value
        }
    }

    public var kind: InlineInteraction.Kind
    public var target: String
    public var displayName: String
    public var icon: String?
    public var control: Control
    public var location: Location
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
                                helper: """
                                    Send your bot a message, then open Telegram setup and use Check sender to find your ID. Only a recipient you \
                                    admit can reach the agent.
                                    """,
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
