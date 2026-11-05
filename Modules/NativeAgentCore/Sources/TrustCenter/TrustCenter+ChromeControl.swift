import Foundation
import NativeAgentCore
import PersistenceCore
// Blueprint: | `TrustCenter+ChromeControl.swift` | `SwiftNativeTrustCenter.authorizeChromeControlEffect`; Fresh authority per effect. |

public enum ChromeControlAuthorityError: Error, LocalizedError, Sendable, Equatable {
    case disabled
    case unavailable
    case paused(reason: String)

    public var errorDescription: String? {
        switch self {
        case .disabled:
            return "chrome_control_disabled: Chrome control is off. Only the owner can enable it at Trust > Mac > Chrome control."
        case .unavailable:
            return """
                trust_policy_unavailable: Chrome control cannot verify the saved Trust policy. Ask the owner to preserve the damaged policy and \
                authorize Safe at Trust > Access and policy > Preserve damaged policy and authorize Safe.
                """
        case .paused(let reason):
            return reason
        }
    }
}

extension SwiftNativeTrustCenter {
    /// Recheck authority for every Chrome effect; a relay session cannot cache a grant.
    public func authorizeChromeControlEffect(origin: SecurityOriginContext? = nil, turn: Turn?) async throws {
        let snapshot = try await loadAuthorizationSnapshotChecked()
        if let paused = SwiftNativeSecurityCenter.killSwitchRefusal(policy: snapshot.policy) {
            throw ChromeControlAuthorityError.paused(reason: paused.reason)
        }
        if let origin {
            let authority = await SwiftNativeSecurityCenter(dataRoot: dataRoot)
                .fullMacYoloAuthority(origin: origin, snapshot: snapshot, turn: turn)
            if authority.admitted { return }
        }
        guard case .object(let chromePolicy)? = snapshot.policy["chromeControlPolicy"],
              case .bool(true)? = chromePolicy["enabled"] else {
            throw ChromeControlAuthorityError.disabled
        }
    }
}
