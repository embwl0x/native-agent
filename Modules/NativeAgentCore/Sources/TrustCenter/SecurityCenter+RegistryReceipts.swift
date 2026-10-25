import Foundation
import NativeAgentCore
import PersistenceCore
// Blueprint: | `SecurityCenter+RegistryReceipts.swift` | `SwiftNativeSecurityCenter`: `receiptSummary`, `isoTimestamp` |

extension SwiftNativeSecurityCenter {
    static func receiptSummary(_ value: JSONValue) -> SecurityReceiptSummary? {
        guard case .object(let obj) = value else { return nil }
        // A damaged receipt is evidence that is unavailable, not a mostly-empty
        // receipt. Fabricating an id here made one corrupt row render as a new
        // blank row on every refresh, which both hid the damage and churned the
        // Security panel. Keep the projection fail-closed like the stores that
        // produced it: every identity/display field must be present and
        // non-blank before it becomes UI state.
        func required(_ key: String, aliases: [String] = []) -> String? {
            for candidate in [key] + aliases {
                if let value = string(obj[candidate])?.trimmingCharacters(in: .whitespacesAndNewlines),
                   !value.isEmpty {
                    return value
                }
            }
            return nil
        }
        guard let id = required("id"),
              let at = required("created_at", aliases: ["at"]),
              let tool = required("tool"),
              let surface = required("surface"),
              let decision = required("decision"),
              let risk = required("risk") else {
            return nil
        }
        let reasons: [String] = {
            guard case .array(let arr)? = obj["reasons"] else { return [] }
            return arr.compactMap { string($0)?.trimmingCharacters(in: .whitespacesAndNewlines) }
                .filter { !$0.isEmpty }
        }()
        return SecurityReceiptSummary(
            id: id,
            at: at,
            tool: tool,
            surface: surface,
            decision: decision,
            risk: risk,
            reason: SecurityReason.firstCause(in: reasons.map(SecurityReason.init(persistedValue:)))
        )
    }

    static func isoTimestamp(_ date: Date) -> String {
        NativeTimestampFormat.fractionalZulu(date)
    }
}
