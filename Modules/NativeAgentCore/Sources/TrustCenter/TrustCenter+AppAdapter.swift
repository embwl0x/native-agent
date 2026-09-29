import Foundation
import PersistenceCore

// MARK: - Phone snapshot bytes
//
// The typed read is `getTrust()` (`TrustPolicy`). The phone's
// trust_policy.json is the raw checked policy itself, so keys the typed model
// does not name still reach it. JSONValue.serializedData(pretty: false) keeps
// the payload compact, sorted by key, and ASCII-escaped.

extension SwiftNativeTrustCenter {
    /// Encode the in-Swift trust policy to compact, sorted, ASCII-escaped JSON.
    public func loadTrustPolicyJSON() async throws -> Data {
        // A user-facing/authoritative read exposes damaged policy bytes rather
        // than serializing the compatibility fail-closed projection as healthy.
        let dict = try await loadTrustPolicyChecked()
        return try JSONValue.object(dict).serializedData(pretty: false)
    }
}
