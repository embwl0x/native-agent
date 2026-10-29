import Foundation
import NativeAgentCore
import PersistenceCore
// Blueprint: | `SecurityCenter+FullMacPolicy.swift` | `SwiftNativeSecurityCenter`: `fullMacActive`, `fullMacYoloAuthority`, checked local `localFullMacYoloAdmitted`, `drivenAgentLaunchPermission` |

extension SwiftNativeSecurityCenter {
    /// Full Mac follows the saved policy without a timer.
    static func fullMacActive(policy: [String: JSONValue]) -> Bool {
        PermissionLaw.posture(policy) == .fullMac
    }

    /// The local operator has one admission for every native action. Read
    /// checked saved authority at presentation time; never retain a grant.
    public nonisolated static func localFullMacYoloAdmitted(dataRoot: URL) -> Bool {
        switch SavedTrustPolicyAuthority.read(dataRoot: dataRoot) {
        case .present(let policy): fullMacActive(policy: policy)
        case .absent, .damaged: false
        }
    }

    /// The public checked authority door for non-chat/raw consumers. A damaged
    /// saved policy is distinguishable from an inactive grant and always fails
    /// closed. Remote trust is resolved from the concrete origin here; a caller
    /// cannot obtain YOLO authority by supplying only a surface label.
    /// Effect owners may pass the fresh checked generation they just read.
    public func fullMacYoloAuthority(
        origin: SecurityOriginContext,
        snapshot: TrustPolicyAuthorizationSnapshot? = nil
    ) async -> FullMacYoloAuthorityAssessment {
        do {
            let checkedSnapshot: TrustPolicyAuthorizationSnapshot
            if let snapshot {
                checkedSnapshot = snapshot
            } else {
                checkedSnapshot = try await trustCenter.loadAuthorizationSnapshotChecked()
            }
            let originAssessment = try await assessOrigin(origin, policy: checkedSnapshot.policy)
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

    /// THE launch decision for an agent NativeAgent drives, for the request's
    /// real origin: admitted Full Mac runs it with full access, a lower Trust
    /// or an origin not admitted for Full Mac runs it restricted, and an
    /// unreadable policy launches nothing.
    public func drivenAgentLaunchPermission(
        origin: SecurityOriginContext
    ) async -> DrivenAgentLaunchPermission {
        let authority = await fullMacYoloAuthority(origin: origin)
        switch authority.state {
        case .admitted: return .fullMac
        case .inactive, .untrustedOrigin: return .restricted
        case .explicitlyBlocked, .unavailable: return .denied(reason: authority.reason)
        }
    }

    /// Shared pure evaluator for owners that already hold one checked
    /// authorization generation. This is the single YOLO vocabulary: there is
    /// intentionally no tool exclusion list and no saved per-tool entry.
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

    /// Checked-snapshot variant for TrustCenter consumers that already received
    /// the concrete origin proof from SecurityCenter.
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
