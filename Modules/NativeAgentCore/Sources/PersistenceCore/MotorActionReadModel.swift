import Foundation

/// Shared, read-only language for observing action progress across NativeAgent.
///
/// This is a projection, never an executor or authority owner. Domain reducers
/// remain canonical and `domainState` preserves their exact vocabulary so the
/// shared phase cannot erase a meaningful distinction.
public enum MotorActionPhase: String, Codable, Sendable, CaseIterable {
    case proposed
    case ready
    case running
    case awaitingApproval = "awaiting_approval"
    case awaitingHuman = "awaiting_human"
    case waitingExternal = "waiting_external"
    case verifying
    case blocked
    case succeeded
    case failed
    case cancelled
    case expired
    case unknown

    public var isTerminal: Bool {
        switch self {
        case .succeeded, .failed, .cancelled, .expired: return true
        default: return false
        }
    }
}

/// Whether a claimed action outcome has been checked against canonical reality.
/// `unverified` is intentionally distinct from `notRequired`: completion and
/// verification are not synonyms.
public enum MotorVerificationState: String, Codable, Sendable, CaseIterable {
    case notStarted = "not_started"
    case pending
    case satisfied
    case failed
    case unverified
    case notRequired = "not_required"
    case unknown
}

/// Exact deadline policy already enforced by a domain owner. A duration is
/// deliberately not rendered as a projected wall-clock timestamp; each owner
/// remains authoritative for when its attempt or operation actually begins.
public struct MotorActionDeadlineReadModel: Codable, Sendable, Equatable {
    public enum Scope: String, Codable, Sendable, CaseIterable {
        case stepAttempt = "step_attempt"
        case operation
    }

    public let scope: Scope
    public let timeoutSeconds: Int

    public init(scope: Scope, timeoutSeconds: Int) {
        self.scope = scope
        self.timeoutSeconds = timeoutSeconds
    }
}

public struct MotorActionReadModel: Codable, Sendable, Equatable {
    public let domain: String
    public let actionIdentity: String
    public let phase: MotorActionPhase
    public let domainState: String
    public let verification: MotorVerificationState
    public let expectedNextEvidence: String?
    public let updatedAt: String?
    /// Opaque correlation of the canonical domain cancellation target. This is
    /// never a dispatch argument; `nil` means no shared cancellation identity.
    public let cancellationIdentity: String?
    /// Existing domain deadline policy only; never a projected/invented timer.
    public let deadline: MotorActionDeadlineReadModel?

    public init(
        domain: String,
        actionIdentity: String,
        phase: MotorActionPhase,
        domainState: String,
        verification: MotorVerificationState,
        expectedNextEvidence: String?,
        updatedAt: String?,
        cancellationIdentity: String? = nil,
        deadline: MotorActionDeadlineReadModel? = nil
    ) {
        self.domain = domain
        self.actionIdentity = actionIdentity
        self.phase = phase
        self.domainState = domainState
        self.verification = verification
        self.expectedNextEvidence = expectedNextEvidence
        self.updatedAt = updatedAt
        self.cancellationIdentity = cancellationIdentity
        self.deadline = deadline
    }
}

/// Narrow observation seam shared by action domains. Implementations must be
/// side-effect free: no dispatch, transition, approval, notification, or write.
public protocol MotorActionReadModelProviding: Sendable {
    func motorActionReadModel(actionId: String) async throws -> MotorActionReadModel?
}
