import Foundation
import NativeAgentCore
import NativeAgentShared
import PersistenceCore
// Blueprint: | `SecurityCenter+Models.swift` | `SecurityToolDecision` enum; `PairedPhoneAuthority` checked pairing reader |

public enum PairedPhoneAuthority {
    public struct Phone: Codable, Identifiable, Sendable {
        public enum Status: String, Codable, Sendable { case pending, paired, removed }
        public let id: String
        public let publicKey: Data
        public var status: Status

        public init(id: String, publicKey: Data, status: Status) {
            self.id = id
            self.publicKey = publicKey
            self.status = status
        }
    }

    public static func pairedCountChecked(at url: URL) throws -> Int {
        try read(at: url).filter { $0.status == .paired }.count
    }

    public static func read(at url: URL) throws -> [Phone] {
        let fm = FileManager.default
        let attributes: [FileAttributeKey: Any]
        do { attributes = try fm.attributesOfItem(atPath: url.path) }
        catch let error as NSError {
            if error.domain == NSCocoaErrorDomain && error.code == NSFileReadNoSuchFileError { return [] }
            throw error
        }
        guard attributes[.type] as? FileAttributeType == .typeRegular else { throw unavailable }
        guard let size = attributes[.size] as? NSNumber, size.int64Value <= 128 * 1024 else {
            throw unavailable
        }
        let handle = try FileHandle(forReadingFrom: url)
        defer { try? handle.close() }
        let data = try handle.read(upToCount: 128 * 1024 + 1) ?? Data()
        guard data.count <= 128 * 1024 else { throw unavailable }
        let rows = try JSONDecoder().decode([Phone].self, from: data)
        guard Set(rows.map(\.id)).count == rows.count,
              rows.allSatisfy({ $0.publicKey.count == 32 && $0.id == DeviceApprovalSignature.deviceID(publicKey: $0.publicKey) }) else {
            throw unavailable
        }
        return rows
    }

    private static var unavailable: NSError {
        NSError(domain: "NativeAgentPairing", code: 1, userInfo: [
            NSLocalizedDescriptionKey: "I couldn’t read the paired phones. I haven’t accepted this decision.",
        ])
    }
}

public enum SecurityToolDecision: String, Codable, Sendable, Equatable {
    case allow
    case ask
    case block
}

/// Origin-checked Full Mac may flatten ask/confirm, never explicit blocks or domain-owned boundaries such as TCC.
public enum FullMacYoloAuthorityState: String, Codable, Sendable, Equatable {
    case admitted
    case inactive
    /// The current Full Mac kill switch explicitly blocks the action.
    case explicitlyBlocked = "explicitly_blocked"
    case untrustedOrigin = "untrusted_origin"
    case unavailable
}

public struct FullMacYoloAuthorityAssessment: Codable, Sendable, Equatable {
    public var state: FullMacYoloAuthorityState
    public var reason: String

    public init(state: FullMacYoloAuthorityState, reason: String) {
        self.state = state
        self.reason = reason
    }

    public var admitted: Bool { state == .admitted }
}

/// Every driven-agent launch uses explicit checked values so a downgrade cannot inherit broader thread or CLI defaults.
public enum DrivenAgentLaunchPermission: Sendable, Equatable {
    case fullMac
    case restricted
    case denied(reason: String)

    public var codexSandbox: String { self == .fullMac ? "danger-full-access" : "workspace-write" }
    /// Unattended: nobody is there to answer an approval either way.
    public var codexApprovalPolicy: String { "never" }

    public func arguments(_ flags: AgentHostCommandLine.PermissionFlags) -> [String] {
        switch flags {
        case .codex: return ["-c", "sandbox_mode=\"\(codexSandbox)\"", "-c", "approval_policy=\"\(codexApprovalPolicy)\""]
        case .claude: return self == .fullMac
            ? ["--permission-mode", "bypassPermissions"]
            : ["--restricted", "--strict-mcp-config", "--permission-mode", "plan", "--permission-prompts", "none"]
        }
    }
}

public struct SecurityOriginContext: Codable, Sendable, Equatable {
    public var surface: String
    public var sessionId: String?
    public var userId: String?
    public var chatId: String?
    public var deviceId: String?
    public var source: String?
    public var isRemote: Bool?
    public var commandSignatureVerified: Bool?

    public init(
        surface: String,
        sessionId: String? = nil,
        userId: String? = nil,
        chatId: String? = nil,
        deviceId: String? = nil,
        source: String? = nil,
        isRemote: Bool? = nil,
        commandSignatureVerified: Bool? = nil
    ) {
        self.surface = surface
        self.sessionId = sessionId
        self.userId = userId
        self.chatId = chatId
        self.deviceId = deviceId
        self.source = source
        self.isRemote = isRemote
        self.commandSignatureVerified = commandSignatureVerified
    }
}

public struct SecurityReason: Codable, Sendable, Equatable {
    public enum Kind: String, Sendable { case cause, note, autonomy, origin }
    public var kind: Kind
    public var sentence: String

    public init(_ kind: Kind, _ sentence: String) {
        self.kind = kind
        self.sentence = sentence
    }

    // Reasons persist as strings; only this boundary reads prefixes, while live decisions carry their kind.
    public var persistedValue: String { "\(kind.rawValue): \(sentence)" }

    public init(persistedValue: String) {
        let parts = persistedValue.split(separator: ":", maxSplits: 1).map(String.init)
        if parts.count == 2, let kind = Kind(rawValue: parts[0]) {
            self.init(kind, parts[1].trimmingCharacters(in: .whitespaces))
        } else {
            self.init(.cause, persistedValue)
        }
    }

    public init(from decoder: Decoder) throws {
        self.init(persistedValue: try decoder.singleValueContainer().decode(String.self))
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        try container.encode(persistedValue)
    }

    public static func firstCause(in reasons: [Self]) -> String {
        reasons.last { $0.kind == .cause }?.sentence ?? "Security policy evaluated this action."
    }
}

public struct SecurityToolEnvelope: Codable, Sendable, Equatable, Identifiable {
    public var id: String
    public var createdAt: String
    public var tool: String
    public var surface: String
    public var origin: SecurityOriginContext
    public var originTrusted: Bool
    public var originTrustReason: String
    public var capabilities: [String]
    public var risk: String
    public var autonomyLevel: String
    public var fullMacYoloAuthority: FullMacYoloAuthorityState
    public var decision: SecurityToolDecision
    public var allowed: Bool
    public var requiresApproval: Bool
    public var reasons: [SecurityReason]
    public var primaryReason: String { SecurityReason.firstCause(in: reasons) }
    public var redactedInputPreview: JSONValue
    public var auditReceiptsEnabled: Bool
    public var autonomyReason: String? = nil
    public var remedy: JSONValue? = nil

    /// Derive effects from the same capability vocabulary as authorization so presentation cannot mislabel mutations as reads.
    public var hasSideEffects: Bool {
        SecurityCapabilityClassifier.hasSideEffects(capabilities)
    }
}

public enum SecurityCapabilityClassifier {
    /// Sensitivity and read tags do not imply mutation of app, host, remote or visible state.
    public static let sideEffecting: Set<String> = [
        "agent_delegate",
        "approval_stage",
        "app_data_write",
        "ax_injection",
        "browser_interaction",
        "clipboard_write",
        "destructive",
        "external_send",
        "file_write",
        "filesystem_delete",
        "filesystem_write",
        "image_generation",
        "ledger_write",
        "mac_control",
        "memory_write",
        "money",
        "network_write",
        "notification",
        "organism_state_write",
        "other_app_settings_write",
        "outside_app_data_write",
        "process_spawn",
        "remote_effect",
        "shell",
        "skill_write",
        "system_control",
        "system_permission_reset",
    ]

    public static func hasSideEffects(_ capabilities: [String]) -> Bool {
        !sideEffecting.isDisjoint(with: capabilities)
    }
}

public struct SecurityStatusFlag: Codable, Sendable, Equatable, Identifiable {
    public var id: String
    public var title: String
    public var status: String
    public var detail: String
    public var enabled: Bool
}

public struct SecurityReceiptSummary: Codable, Sendable, Equatable, Identifiable {
    public var id: String
    public var at: String
    public var tool: String
    public var surface: String
    public var decision: String
    public var risk: String
    public var reason: String
}

public struct SecurityCenterStatus: Codable, Sendable, Equatable {
    public var status: String
    public var mode: String
    public var developerMode: Bool
    public var fullMac: Bool
    public var killSwitchEnabled: Bool
    public var trustedOrigins: Int
    public var auditReceiptsPath: String
    public var flags: [SecurityStatusFlag]
    public var recentReceipts: [SecurityReceiptSummary]
}
