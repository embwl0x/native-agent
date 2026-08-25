import Foundation
import PersistenceCore

extension SwiftNativeSecurityCenter {
    static func registryContainsSignedTool(_ raw: JSONValue, tool: String) -> Bool {
        func signed(_ obj: [String: JSONValue]) -> Bool {
            let name = string(obj["name"]) ?? string(obj["id"]) ?? ""
            guard name == tool else { return false }
            let sig = string(obj["manifestSignature"]) ?? string(obj["manifest_signature"]) ?? ""
            return !sig.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        }
        switch raw {
        case .array(let arr):
            return arr.contains { value in
                guard case .object(let obj) = value else { return false }
                return signed(obj)
            }
        case .object(let obj):
            if signed(obj) { return true }
            if case .array(let tools)? = obj["tools"] {
                return tools.contains { value in
                    guard case .object(let toolObj) = value else { return false }
                    return signed(toolObj)
                }
            }
            for (_, value) in obj {
                if case .object(let child) = value, signed(child) { return true }
            }
            return false
        default:
            return false
        }
    }

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
            reason: reasons.first ?? ""
        )
    }

    static func isoTimestamp(_ date: Date) -> String {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        formatter.timeZone = TimeZone(secondsFromGMT: 0)
        return formatter.string(from: date)
    }
}
