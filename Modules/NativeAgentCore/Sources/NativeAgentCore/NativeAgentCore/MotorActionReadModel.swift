import Foundation

// Blueprint: | `MotorActionReadModel.swift` | `MotorActionReadModel`: progress projection; domain authority stays native |

/// Shared, read-only language for observing action progress across NativeAgent. This is a projection, never an executor or authority owner. Domain reducers
/// remain canonical and `domainState` preserves their exact vocabulary so the shared phase cannot erase a meaningful distinction.
public enum MotorActionPhase: String, Codable, Sendable, CaseIterable {
    case ready
    case running
    case awaitingApproval = "awaiting_approval"
    case waitingExternal = "waiting_external"
    case blocked
    case succeeded
    case failed
    case cancelled
    case expired
    case unknown
}

/// Whether a claimed action outcome has been checked against canonical reality. `unverified` is intentionally distinct from `notRequired`: completion and
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

public struct MotorActionReadModel: Codable, Sendable, Equatable {
    public let domain: String
    public let actionIdentity: String
    public let phase: MotorActionPhase
    public let domainState: String
    public let verification: MotorVerificationState
    public let expectedNextEvidence: String?
    public let updatedAt: String?

    public init(
        domain: String,
        actionIdentity: String,
        phase: MotorActionPhase,
        domainState: String,
        verification: MotorVerificationState,
        expectedNextEvidence: String?,
        updatedAt: String?
    ) {
        self.domain = domain
        self.actionIdentity = actionIdentity
        self.phase = phase
        self.domainState = domainState
        self.verification = verification
        self.expectedNextEvidence = expectedNextEvidence
        self.updatedAt = updatedAt
    }
}

/// Narrow observation seam shared by action domains. Implementations must be side-effect free: no dispatch, transition, approval, notification, or write.
public protocol MotorActionReadModelProviding: Sendable {
    func motorActionReadModel(actionId: String) async throws -> MotorActionReadModel?
}
