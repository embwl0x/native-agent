import Foundation
// Blueprint: | `SettingsFace.swift` | Finished settings groups, preference scalars and permission-dock words at the settings feed key |

public struct SettingsFace: FaceValue {
    public var providers = ProviderSettingsFace()
    public var trust = TrustSettingsFace()
    public var persona = PersonaSettingsFace()
    public var connectors = ConnectorSettingsFace()
    public var permissions = PermissionSettingsFace()
    public var updates: SoftwareUpdateSettingsFace?
    public var preferences: [String: PartFace.Value] = [:]
    public var preferenceIssues: [String: String] = [:]
    public var hasReadPreferences = false
    public var searchURL: String?
    public var searchIssue: String?

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
        public let canCheck: Bool
        public let automaticChecks: Bool
        public let failure: String?
        public let unavailable: Unavailability?
        public init(availableVersion: String?, canCheck: Bool, automaticChecks: Bool, failure: String?, unavailable: Unavailability?) {
            self.availableVersion = availableVersion
            self.canCheck = canCheck
            self.automaticChecks = automaticChecks
            self.failure = failure
            self.unavailable = unavailable
        }
    }
    public let source: Source
    public let menuTitle: String
    public let settingsDetail: String
    public var isAvailable: Bool { source.unavailable == nil }
    public init(source: Source) {
        self.source = source
        if let version = source.availableVersion { menuTitle = "Update Available — \(version)…" }
        else { menuTitle = source.unavailable == nil ? "Check for Updates…" : "About Software Updates…" }
        let detail: String
        switch source.unavailable {
        case .some(let unavailable): detail = unavailable.detail
        case nil:
            detail = source.automaticChecks ? "NativeAgent checks the signed release feed automatically. You can also check manually."
                : "Automatic update checks are off. You can still check the signed release feed manually."
        }
        settingsDetail = source.failure.map { $0 + " " + detail } ?? detail
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
    public var systemStatuses: [String: String] = [:]
    public var issue: String?
    public var isReading = true
    public var docks: [String: Dock] = [:]
    public init() {}
}
