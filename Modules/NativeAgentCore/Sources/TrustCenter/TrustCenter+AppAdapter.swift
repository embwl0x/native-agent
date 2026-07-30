import Foundation
import PersistenceCore

// MARK: - App-side adapter
//
// The SwiftNativeApp module (Sources/NativeAgentApp) carries its own
// `TrustPolicy` Codable struct shaped for the app's trust-policy JSON.
// Rather than thread the app-side type into this core module
// (which would create a cross-module type clash with `TrustCenter.TrustPolicy`),
// the adapter returns the JSON bytes directly. NativeClient's swift seam
// then decodes through its existing path:
//
//     let data = try await SwiftNativeTrustCenter().loadTrustPolicyJSON()
//     let policy = try JSONDecoder().decode(TrustPolicy.self, from: data)
//
// JSONValue.serializedData(pretty: false) keeps the payload compact,
// sorted by key, and ASCII-escaped.

extension SwiftNativeTrustCenter {
    /// Encode the in-Swift trust policy to compact, sorted, ASCII-escaped JSON.
    public func loadTrustPolicyJSON() async throws -> Data {
        // A user-facing/authoritative read exposes damaged policy bytes rather
        // than serializing the compatibility fail-closed projection as healthy.
        let dict = try await loadTrustPolicyChecked()
        return try JSONValue.object(dict).serializedData(pretty: false)
    }
}
