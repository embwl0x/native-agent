import Foundation
import PersistenceCore
// Blueprint: | `TrustPolicyToolWriter.swift` | `TrustPolicyToolWriter` enum; `applyTrustPolicyPatch` |

public enum TrustPolicyToolWriter {
    public static func applyTrustPolicyPatch(
        body: [String: Any],
        dataRoot root: URL,
        guardedByLockedPolicy: (@Sendable ([String: JSONValue]) throws -> Void)? = nil
    ) async throws -> TrustPolicy {
        let patch = JSONValue(fromFoundation: body)
        guard case .object(let patchObject) = patch else {
            throw TrustCenterError.invalidRequest
        }
        return try TrustPolicy(policyObject: try await SwiftNativeTrustCenter(dataRoot: root)
            .applyPolicyPatchChecked(patchObject, guardedByLockedPolicy: guardedByLockedPolicy))
    }

}
