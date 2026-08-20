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
    /// cached by a relay session or tab lease: every acquire, navigation,
    /// snapshot, click, fill, type, wait, and scroll calls this exact seam again.
    public func authorizeChromeControlEffect() async throws {
        let policy: [String: JSONValue]
        do {
            policy = try await loadTrustPolicyChecked()
        } catch {
            throw ChromeControlAuthorityError.unavailable
        }
        guard case .object(let chromePolicy)? = policy["chromeControlPolicy"],
              case .bool(true)? = chromePolicy["enabled"] else {
            throw ChromeControlAuthorityError.disabled
        }
    }

    public func chromeControlEnabledChecked() async -> Bool {
        do {
            try await authorizeChromeControlEffect()
            return true
        } catch {
            return false
        }
    }
}
