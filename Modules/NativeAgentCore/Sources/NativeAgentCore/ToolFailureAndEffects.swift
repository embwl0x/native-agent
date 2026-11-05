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
    public var baseCapabilities: Set<String> { self == .read ? ["safe_read", "tool_call"] : ["tool_call"] }

    public static func < (lhs: ToolClass, rhs: ToolClass) -> Bool { lhs.rawValue < rhs.rawValue }
}

/// Which side a tool's fixed effects reach; path policy still resolves named paths.
public enum ToolReach: String, Sendable { case agent, person }

/// Argument-dependent effects, declared by their owning tool.
public enum ToolEffectInputPolicy: Sendable { case fixed, agentConnection, agentMessage }
