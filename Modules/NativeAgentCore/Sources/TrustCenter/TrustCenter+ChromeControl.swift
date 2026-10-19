import Foundation
import PersistenceCore

public enum ChromeControlAuthorityError: Error, LocalizedError, Sendable, Equatable {
    case disabled
    case unavailable

    public var errorDescription: String? {
        switch self {
        case .disabled:
            return "Chrome control is off in Trust Center."
        case .unavailable:
            return "Chrome control authority is unavailable because the Trust Center policy could not be verified."
        }
    }
}

extension SwiftNativeTrustCenter {
    /// Reads the checked policy generation for one Chrome effect. This is not
    /// cached by a relay session: every navigation,
    /// snapshot, click, fill, type, wait, and scroll calls this exact seam again.
    public func authorizeChromeControlEffect(tool: String = "browser.chrome", origin: SecurityOriginContext? = nil) async throws {
        let snapshot: TrustPolicyAuthorizationSnapshot
        do {
            snapshot = try await loadAuthorizationSnapshotChecked()
        } catch {
            throw ChromeControlAuthorityError.unavailable
        }
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
