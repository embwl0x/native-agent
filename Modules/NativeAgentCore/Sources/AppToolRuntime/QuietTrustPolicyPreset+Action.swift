import Foundation
import NativeAgentShared
import PersistenceCore
import TrustCenter
// Blueprint: | `QuietTrustPolicyPreset+Action.swift` | trust preset action receipts |

extension TrustPolicyPreset {
    public enum Outcome: Sendable {
        case confirmationRequired(TrustPolicyPresetPlan)
        case applied(TrustPolicy)
        case failed(String)
    }

    public func apply(
        dataRoot: URL,
        fullMacConfirmed: Bool = false,
        guardedByLockedPolicy: (@Sendable ([String: JSONValue]) throws -> Void)? = nil
    ) async throws -> Outcome {
        guard !plan.requiresFullMacConfirmation || fullMacConfirmed else {
            return .confirmationRequired(plan)
        }
        return .applied(try await save(
            dataRoot: dataRoot,
            fullMacConfirmed: fullMacConfirmed,
            guardedByLockedPolicy: guardedByLockedPolicy
        ))
    }
}
