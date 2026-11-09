import NativeAgentShared
import Foundation
import NativeAgentCore
import PersistenceCore
// Blueprint: | `SecurityCenter+FullMacPolicy.swift` | Origin-aware Full Mac admission and driven-agent launch permission |

extension SwiftNativeSecurityCenter {
    /// Full Mac follows the saved policy without a timer.
    static func fullMacActive(policy: [String: JSONValue]) -> Bool {
        PermissionLaw.posture(policy) == .fullMac
    }

    /// Concrete origin proof and readable saved policy are both required; a surface label cannot confer Full Mac authority.
    public func fullMacYoloAuthority(
        origin: SecurityOriginContext,
        snapshot: TrustPolicyAuthorizationSnapshot? = nil,
        turn: Turn?
    ) async -> FullMacYoloAuthorityAssessment {
        do {
            let checkedSnapshot: TrustPolicyAuthorizationSnapshot
            if let snapshot {
                checkedSnapshot = snapshot
            } else {
                checkedSnapshot = try await trustCenter.loadAuthorizationSnapshotChecked()
            }
            let originAssessment = try await assessOrigin(origin, policy: checkedSnapshot.policy, turn: turn)
            return Self.fullMacYoloAuthority(
                originAssessment: originAssessment,
                snapshot: checkedSnapshot
            )
        } catch {
            return FullMacYoloAuthorityAssessment(
                state: .unavailable,
                reason: "saved trust policy is unavailable: \(error.localizedDescription)"
            )
        }
    }

    /// Origin-aware admission selects full or restricted launch; unreadable authority cannot launch anything.
    public func drivenAgentLaunchPermission(
        origin: SecurityOriginContext,
        turn: Turn?
    ) async -> DrivenAgentLaunchPermission {
        let authority = await fullMacYoloAuthority(origin: origin, turn: turn)
        switch authority.state {
        case .admitted: return .fullMac
        case .inactive, .untrustedOrigin: return .restricted
        case .explicitlyBlocked, .unavailable: return .denied(reason: authority.reason)
        }
    }

    /// One checked generation owns YOLO evaluation, without a separate tool exclusion or saved-entry policy.
    static func fullMacYoloAuthority(
        originAssessment: OriginAssessment,
        snapshot: TrustPolicyAuthorizationSnapshot
    ) -> FullMacYoloAuthorityAssessment {
        if let paused = Self.killSwitchRefusal(policy: snapshot.policy) {
            return FullMacYoloAuthorityAssessment(state: .explicitlyBlocked, reason: paused.reason)
        }
        guard Self.fullMacActive(policy: snapshot.policy) else {
            return FullMacYoloAuthorityAssessment(
                state: .inactive,
                reason: "Full Mac is not turned on"
            )
        }
        // The authenticated origin carries the authority, whatever its door.
        if originAssessment.isRemote, !originAssessment.trusted {
            return FullMacYoloAuthorityAssessment(
                state: .untrustedOrigin,
                reason: originAssessment.reason
            )
        }
        return FullMacYoloAuthorityAssessment(
            state: .admitted,
            reason: originAssessment.reason
        )
    }

    public nonisolated static func fullMacYoloAuthority(
        surface: String,
        originTrusted: Bool,
        snapshot: TrustPolicyAuthorizationSnapshot
    ) -> FullMacYoloAuthorityAssessment {
        let remote = ConversationSurfaceProfile(surface).isRemote
        return fullMacYoloAuthority(
            originAssessment: OriginAssessment(
                trusted: remote ? originTrusted : true,
                reason: remote
                    ? (originTrusted ? "origin authenticated by conversation surface" : "remote origin is not authenticated")
                    : "local app surface",
                isRemote: remote
            ),
            snapshot: snapshot
        )
    }
}
