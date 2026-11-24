import Foundation

// Blueprint: | `ToolFailureAndEffects.swift` | Owner-supplied failures, remedies and declared effects |

/// Failure evidence supplied by the owner, never inferred from an error message.
public struct ToolFailureError: Error, LocalizedError, Sendable {
    public enum Status: String, Sendable { case failed, refused, timeout, cancelled }
    public enum Effects: String, Sendable { case none, occurred, partial, unknown }
    public enum Recovery: String, Sendable {
        case correctArguments = "correct_arguments"
        case repair, reconcile, inspect, terminal
    }
    /// The owner's stable cause, not a dispatch or presentation code.
    public let code: String?
    public let status: Status
    public let message: String
    public let argumentPath: String?
    public let accepted: String?
    public let effects: Effects
    /// External refusal owner, always paired with a lever.
    public let owner: String?
    /// The agent's lever: the call that changes the owner, as `{"tool":…,"input":{…}}` (`ToolFailureError.call` builds it).
    public let nextCall: String?
    /// Person-only decisions name the exact screen, section and control for Trust, peer elevation, macOS consent or sign-in.
    public let tap: String?
    /// A lawful person-only decision (a Trust posture or block, a consent): it names its owner and the owner's control and owes nothing.
    public let personDecides: Bool
    /// The plain fix, separate from the explanation of what happened.
    public let instruction: String?
    /// A terminal recovery instruction must explain why there is no next call.
    public let recovery: Recovery?

    public init(_ message: String, argumentPath: String? = nil, accepted: String? = nil, effects: Effects,
                owner: String? = nil, nextCall: String? = nil, tap: String? = nil, personDecides: Bool = false,
                code: String? = nil, status: Status = .failed, instruction: String? = nil, recovery: Recovery? = nil) {
        self.code = code
        self.status = status
        self.message = message
        self.argumentPath = argumentPath
        self.accepted = accepted
        self.effects = effects
        self.owner = owner
        self.nextCall = nextCall
        self.tap = tap
        self.personDecides = personDecides
        self.instruction = instruction
        self.recovery = recovery
    }

    public var errorDescription: String? { message }
}

/// What a call IS to the permission law: a read, a write, a send that reaches another person or service, or a destructive act with no way back (deleted for
/// good, emptied, an ability's history dropped). Declared once where the tool is declared; Trust derives every decision from it, the posture, the integration
/// switch and who steered the turn.
public enum ToolClass: Int, Sendable, Comparable {
    case read, write, send, destructive

    /// What a tool of this class carries unless it says otherwise: every tool is a tool_call; a read is a safe read.
    public var baseCapabilities: CapabilitySet { self == .read ? [.safeRead, .toolCall] : [.toolCall] }

    public static func < (lhs: ToolClass, rhs: ToolClass) -> Bool { lhs.rawValue < rhs.rawValue }
}

/// Which side a tool's fixed effects reach; path policy still resolves named paths.
public enum ToolReach: String, Sendable { case agent, person }

/// Argument-dependent effects, declared by their owning tool.
public enum ToolEffectInputPolicy: Sendable { case fixed, agentConnection, agentMessage }

public struct UnknownCapabilityError: LocalizedError, Sendable {
    public let name: String
    public var errorDescription: String? { "Unknown tool capability: \(name)." }
}

public struct CapabilitySet: OptionSet, Sendable, Hashable, Codable {
    public let rawValue: UInt64
    public init(rawValue: UInt64) { self.rawValue = rawValue }

    public static let toolCall = Self(rawValue: 1 << 0)
    public static let safeRead = Self(rawValue: 1 << 1)
    public static let appDataRead = Self(rawValue: 1 << 2)
    public static let catalogRead = Self(rawValue: 1 << 3)
    public static let networkRead = Self(rawValue: 1 << 4)
    public static let networkPublic = Self(rawValue: 1 << 5)
    public static let networkLocalhost = Self(rawValue: 1 << 6)
    public static let model = Self(rawValue: 1 << 7)
    public static let secrets = Self(rawValue: 1 << 8)
    public static let applescript = Self(rawValue: 1 << 9)
    public static let appDataWrite = Self(rawValue: 1 << 10)
    public static let outsideAppDataWrite = Self(rawValue: 1 << 11)
    public static let otherAppSettingsWrite = Self(rawValue: 1 << 12)
    public static let fileWrite = Self(rawValue: 1 << 13)
    public static let filesystemWrite = Self(rawValue: 1 << 14)
    public static let filesystemDelete = Self(rawValue: 1 << 15)
    public static let memoryWrite = Self(rawValue: 1 << 16)
    public static let ledgerWrite = Self(rawValue: 1 << 17)
    public static let organismStateWrite = Self(rawValue: 1 << 18)
    public static let skillWrite = Self(rawValue: 1 << 19)
    public static let credentialWrite = Self(rawValue: 1 << 20)
    public static let clipboardWrite = Self(rawValue: 1 << 21)
    public static let browserInteraction = Self(rawValue: 1 << 22)
    public static let macControl = Self(rawValue: 1 << 23)
    public static let axInjection = Self(rawValue: 1 << 24)
    public static let systemControl = Self(rawValue: 1 << 25)
    public static let systemPermissionReset = Self(rawValue: 1 << 26)
    public static let processSpawn = Self(rawValue: 1 << 27)
    public static let shell = Self(rawValue: 1 << 28)
    public static let networkWrite = Self(rawValue: 1 << 29)
    public static let externalSend = Self(rawValue: 1 << 30)
    public static let notification = Self(rawValue: 1 << 31)
    public static let remoteEffect = Self(rawValue: 1 << 32)
    public static let imageGeneration = Self(rawValue: 1 << 33)
    public static let agentDelegate = Self(rawValue: 1 << 34)
    public static let approvalStage = Self(rawValue: 1 << 35)
    public static let money = Self(rawValue: 1 << 36)
    public static let destructive = Self(rawValue: 1 << 37)
    public static let hidInjection = Self(rawValue: 1 << 38)

    private static let byName: [String: Self] = [
        "tool_call": .toolCall, "safe_read": .safeRead, "app_data_read": .appDataRead,
        "catalog_read": .catalogRead, "network_read": .networkRead, "network_public": .networkPublic,
        "network_localhost": .networkLocalhost, "model": .model, "secrets": .secrets,
        "applescript": .applescript, "app_data_write": .appDataWrite, "outside_app_data_write": .outsideAppDataWrite,
        "other_app_settings_write": .otherAppSettingsWrite, "file_write": .fileWrite, "filesystem_write": .filesystemWrite,
        "filesystem_delete": .filesystemDelete, "memory_write": .memoryWrite, "ledger_write": .ledgerWrite,
        "organism_state_write": .organismStateWrite, "skill_write": .skillWrite, "credential_write": .credentialWrite,
        "clipboard_write": .clipboardWrite, "browser_interaction": .browserInteraction, "mac_control": .macControl,
        "ax_injection": .axInjection, "system_control": .systemControl, "system_permission_reset": .systemPermissionReset,
        "process_spawn": .processSpawn, "shell": .shell, "network_write": .networkWrite,
        "external_send": .externalSend, "notification": .notification, "remote_effect": .remoteEffect,
        "image_generation": .imageGeneration, "agent_delegate": .agentDelegate, "approval_stage": .approvalStage,
        "money": .money, "destructive": .destructive, "hid_injection": .hidInjection,
    ]
    public static func parse(_ names: some Sequence<String>) throws(UnknownCapabilityError) -> Self {
        var result = Self()
        for name in names {
            guard let bit = byName[name] else { throw UnknownCapabilityError(name: name) }
            result.insert(bit)
        }
        return result
    }
    public func contains(wireName: String) -> Bool { Self.byName[wireName].map { contains($0) } ?? false }
    public var wireNames: [String] { Self.byName.compactMap { contains($0.value) ? $0.key : nil }.sorted() }
    public init(from decoder: any Decoder) throws { self = try Self.parse([String](from: decoder)) }
    public func encode(to encoder: any Encoder) throws { try wireNames.encode(to: encoder) }

    public static let sideEffecting: Self = [
        .agentDelegate, .approvalStage, .appDataWrite, .axInjection, .browserInteraction,
        .clipboardWrite, .destructive, .externalSend, .fileWrite, .filesystemDelete,
        .filesystemWrite, .imageGeneration, .ledgerWrite, .macControl, .memoryWrite,
        .money, .networkWrite, .notification, .organismStateWrite, .otherAppSettingsWrite,
        .outsideAppDataWrite, .processSpawn, .remoteEffect, .shell, .skillWrite,
        .systemControl, .systemPermissionReset,
    ]
    public static let userReaching: Self = [.outsideAppDataWrite, .otherAppSettingsWrite, .systemControl, .systemPermissionReset,
        .axInjection, .macControl, .clipboardWrite, .remoteEffect]
    public static let destructiveClass: Self = [.destructive, .filesystemDelete, .systemPermissionReset]
    public static let agentReach: Self = [.appDataRead, .appDataWrite, .model, .networkLocalhost]
    public static let desktopInteraction: Self = [.axInjection, .hidInjection, .browserInteraction, .notification, .systemControl, .shell, .processSpawn]
    public static let personInitiatedSendOnly: Self = [.toolCall, .externalSend, .networkWrite]
}
