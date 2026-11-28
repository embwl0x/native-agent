import Foundation
// Blueprint: | `SettingsFace.swift` | Finished settings groups, preference scalars and permission-dock words at the settings feed key |

public struct SettingsFace: FaceValue {
    public struct Window: FaceValue {
        public var leaves: [String]
        /// For each page left in place, the chance a turn follows from it anyway, so the record keeps learning if the person changes.
        public var sampling: [String: Double]
        public init(leaves: [String] = [], sampling: [String: Double] = [:]) { self.leaves = leaves; self.sampling = sampling }
        private enum CodingKeys: String, CodingKey { case leaves, sampling }
        /// A body from before sampling sends leaves alone: those pages carry no sampling chance yet.
        public init(from decoder: Decoder) throws {
            let values = try decoder.container(keyedBy: CodingKeys.self)
            leaves = try values.decode([String].self, forKey: .leaves)
            sampling = try values.decodeIfPresent([String: Double].self, forKey: .sampling) ?? [:]
        }
    }
    /// Absent from a body that predates it: such a body has learned no pages to leave.
    public var window: Window?
    public var providers = ProviderSettingsFace()
    public var trust = TrustSettingsFace()
    public var persona = PersonaSettingsFace()
    public var connectors = ConnectorSettingsFace()
    public var permissions = PermissionSettingsFace()
    public var updates: SoftwareUpdateSettingsFace?
    public var preferences: [String: PartFace.Value] = [:]
    public var preferenceIssues: [String: String] = [:]
    public var hasReadPreferences = false

    public init() {}
}

public struct SoftwareUpdateSettingsFace: FaceValue {
    public enum Unavailability: FaceValue {
        case feedNotPublished, notConfigured
        public var detail: String {
            switch self {
            case .feedNotPublished:
                "This build has no published update feed, so NativeAgent can’t check for new versions. "
                    + "Install newer builds by downloading the latest release disk image and dragging it to Applications."
            case .notConfigured:
                "This is a locally-built copy of NativeAgent, which ships without updater configuration. "
                    + "Rebuild from source to update, or install a signed release build."
            }
        }
    }
    public struct Source: FaceValue {
        public let availableVersion: String?
        public init(availableVersion: String?) {
            self.availableVersion = availableVersion
        }
    }
    public let source: Source
    public init(source: Source) {
        self.source = source
    }
}

public struct TrustSettingsFace: FaceValue {
    public var policy: TrustPolicy?
    public var effectiveMacControlPolicy: MacControlPolicyWireSnapshot?
    public var issue: String?
    public var word = "Reading Trust…"
    public var activePreset: String?
    public var fullMacGrantIsActive: Bool?
    public var hasPolicy: Bool { policy != nil }
    public init() {}
}

public struct PersonaSettingsFace: FaceValue {
    public var profile: PersonalityProfile?
    public var documents: [PersonaDocSpec] = []
    public var profileIssue: String?
    public var documentsIssue: String?
    public var displayName = ""
    public init() {}
}

public struct ConnectorSettingsFace: FaceValue {
    public struct Slack: FaceValue {
        public let allowedChannelIds: Set<String>
        public let allowedUserIds: Set<String>
        public let requireMention: Bool
        public init(allowedChannelIds: Set<String>, allowedUserIds: Set<String>, requireMention: Bool) {
            self.allowedChannelIds = allowedChannelIds
            self.allowedUserIds = allowedUserIds
            self.requireMention = requireMention
        }
    }
    public var slack: Slack?
    public var slackIssue: String?
    public init() {}
}

public struct PermissionSettingsFace: FaceValue {
    public struct Dock: FaceValue {
        public let line: String
        public let highlight: String?
        public init(line: String, highlight: String?) { self.line = line; self.highlight = highlight }
    }
    public var docks: [String: Dock] = [:]
    public init() {}
}
