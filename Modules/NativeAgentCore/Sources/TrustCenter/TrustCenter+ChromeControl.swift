import Foundation
import PersistenceCore
// Blueprint: | `TrustCenter+ChromeControl.swift` | `SwiftNativeTrustCenter.authorizeChromeControlEffect`: checked authority distinguishes disabled from unavailable without a Boolean wrapper |

public enum ChromeControlAuthorityError: Error, LocalizedError, Sendable, Equatable {
    case disabled
    case unavailable

    public var errorDescription: String? {
        switch self {
        case .disabled:
            return "chrome_control_disabled: Chrome control is off. Only the owner can enable it at Trust > Mac > Chrome control."
        case .unavailable:
            return "trust_policy_unavailable: Chrome control cannot verify the saved Trust policy. Ask the owner to preserve the damaged policy and authorize Safe at Trust > Access and policy > Preserve damaged policy and authorize Safe."
        }
    }
}

extension SwiftNativeTrustCenter {
    /// Reads the checked policy generation for one Chrome effect. This is not
    /// cached by a relay session: every navigation,
    /// snapshot, click, fill, type, wait, and scroll calls this exact seam again.
    public func authorizeChromeControlEffect(tool: String = "browser.chrome", origin: SecurityOriginContext? = nil) async throws {
        let snapshot = try await loadAuthorizationSnapshotChecked()
        if let origin {
            let authority = await SwiftNativeSecurityCenter(dataRoot: dataRoot)
                .fullMacYoloAuthority(tool: tool, origin: origin, snapshot: snapshot)
            if authority.admitted { return }
        }
        guard case .object(let chromePolicy)? = snapshot.policy["chromeControlPolicy"],
              case .bool(true)? = chromePolicy["enabled"] else {
            throw ChromeControlAuthorityError.disabled
        }
    }
}
