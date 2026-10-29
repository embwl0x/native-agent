// Blueprint: | `RegistryTimestampSortKey.swift` | `RegistryTimestampSortKey` enum; `sortKey` |
/// Shared registry timestamp compatibility; registry owners retain ordering and IO.
package enum RegistryTimestampSortKey {
    private static func pyStr(_ v: JSONValue) -> String {
        switch v {
        case .null: return "None"
        case .bool(let b): return b ? "True" : "False"
        case .int(let i): return String(i)
        case .double(let d): return String(d)
        case .string(let s): return s
        case .array, .object: return ""  // not expected for timestamp fields
        }
    }

    /// Select updatedAt, then createdAt, using compatibility truthiness.
    /// A nonempty collection selects the field but renders an empty key;
    /// it must not fall through to createdAt or use Python collection repr.
    package static func sortKey(_ value: JSONValue) -> String {
        guard case .object(let obj) = value else { return "" }
        if let u = obj["updatedAt"], u.isTruthy { return pyStr(u) }
        if let c = obj["createdAt"], c.isTruthy { return pyStr(c) }
        return ""
    }
}
