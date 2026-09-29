import Foundation

public enum NativeActionRouteSupport {
    public static func jsonValueBody(_ body: [String: Any]) throws -> [String: JSONValue] {
        let data = try JSONSerialization.data(withJSONObject: body, options: [])
        let parsed = try JSONValue.parse(data)
        guard case .object(let obj) = parsed else { return [:] }
        return obj
    }
    public static func notImplemented(method: String, reason: String, followup: String) -> NSError {
        NSError(domain: "NativeAgentNotImplemented", code: -501, userInfo: [
            NSLocalizedDescriptionKey: "\(method): \(reason)",
            "code": "not_implemented", "method": method, "reason": reason,
            "followup": followup, "panelDisabled": true,
        ])
    }
}
