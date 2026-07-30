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
        let reasons: [String] = {
            guard case .array(let arr)? = obj["reasons"] else { return [] }
            return arr.compactMap { string($0) }
        }()
        return SecurityReceiptSummary(
            id: string(obj["id"]) ?? UUID().uuidString,
            at: string(obj["created_at"]) ?? string(obj["at"]) ?? "",
            tool: string(obj["tool"]) ?? "",
            surface: string(obj["surface"]) ?? "",
            decision: string(obj["decision"]) ?? "",
            risk: string(obj["risk"]) ?? "",
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
