/// Shared registry timestamp compatibility; registry owners retain ordering and IO.
package enum RegistryTimestampSortKey {
    private static func isTruthy(_ v: JSONValue) -> Bool {
        switch v {
        case .null: return false
        case .bool(let b): return b
        case .int(let i): return i != 0
        case .double(let d): return d != 0
        case .string(let s): return !s.isEmpty
        case .array(let a): return !a.isEmpty
        case .object(let o): return !o.isEmpty
        }
    }

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
        if let u = obj["updatedAt"], isTruthy(u) { return pyStr(u) }
        if let c = obj["createdAt"], isTruthy(c) { return pyStr(c) }
        return ""
    }
}
