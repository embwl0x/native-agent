import Foundation
import NativeAgentCore
import PersistenceCore
// Blueprint: | `ApprovalInbox+InjectionSpend.swift` | `SwiftNativeApprovalInbox`: `consumeInjectionApproval`, `loadSpends` |

// The versioned spend object is locally backed up and exported, never phone
// synced, and inventoried under PrivacyMap's Approvals category.
extension SwiftNativeApprovalInbox {
    public static let injectionSpendSchema = "mac-injection-approval-spend.v1"

    nonisolated var injectionSpendPath: URL { Self.injectionSpendPath(root: root) }

    /// Spend before dispatch, permanently, even if the injection fails or the app stops.
    public func consumeInjectionApproval(
        id: String,
        digest: String,
        tool: String,
        surface: String
    ) async -> ApprovalEffectSpendOutcome {
        let id = id.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !id.isEmpty else { return .unavailable }
        return await consumeApprovedEffect(id: id, marker: [
            "digest": .string(digest), "tool": .string(tool),
            "surface": .string(surface), "spentAt": .string(Self.isoTimestamp(Date())),
        ], at: injectionSpendPath, schema: Self.injectionSpendSchema, actionField: "tool")
    }
}
