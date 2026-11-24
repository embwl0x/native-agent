import Foundation
import NativeAgentShared
import NativeAgentCore
import PersistenceCore
// Blueprint: | `SecurityCenter+RegistryReceipts.swift` | `SwiftNativeSecurityCenter`: `receiptSummary` |

extension SwiftNativeSecurityCenter {
    static func receiptSummary(_ value: JSONValue) -> SecurityReceiptSummary? {
        guard case .object(let obj) = value else { return nil }
        // Require real nonblank receipt identity and display fields so damaged rows cannot become fabricated UI state.
        func required(_ key: String) -> String? {
            guard let value = obj[key]?.scalarText?.trimmingCharacters(in: .whitespacesAndNewlines),
                  !value.isEmpty else { return nil }
            return value
        }
        guard let id = required("id"),
              let at = required("created_at"),
              let tool = required("tool"),
              let surface = required("surface"),
              let decision = required("decision"),
              let risk = required("risk") else {
            return nil
        }
        let reasons = JSONValue.trimmedScalarTextArray(obj["reasons"])
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
}
