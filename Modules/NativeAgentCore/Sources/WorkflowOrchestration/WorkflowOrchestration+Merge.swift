import Foundation
import PersistenceCore

// MARK: - Merge helpers (shared, pure)

public enum WorkflowMerge {
    /// Reads the `id` field of a workflow object as a string (mirrors
    /// `str(item.get("id"))`, so a missing/non-string id becomes "" / "None"-ish).
    /// Python's `str(None)` == "None"; we mirror that for missing ids so two
    /// id-less records collide the same way they would in Python.
    public static func idKey(_ value: JSONValue) -> String {
        guard case .object(let obj) = value else { return "None" }
        guard let idv = obj["id"] else { return "None" }
        switch idv {
        case .string(let s): return s
        case .int(let i): return String(i)
        case .double(let d): return String(d)
        case .bool(let b): return b ? "True" : "False"
        case .null: return "None"
        default: return "None"
        }
    }

    /// Retired-runtime truthiness for a scalar/collection JSONValue (matches the
    /// `bool(x)`): "" / 0 / 0.0 / false / null / [] / {} are falsey.
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

    /// Python `str(value)` for the scalar JSON types that can appear in a
    /// timestamp field (mirrors `str(None)`/`str(True)`/`str(123)` etc.).
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

    /// Sort key: `str(updatedAt or createdAt or "")`. Empty string sorts last
    /// in DESC order. Mirrors Python `key=lambda item: str(item.get("updatedAt")
    /// or item.get("createdAt") or "")` — including Python's `or` truthiness
    /// across non-string scalars (a truthy numeric/bool timestamp sorts under
    /// its `str(...)` form, not "").
    public static func sortKey(_ value: JSONValue) -> String {
        guard case .object(let obj) = value else { return "" }
        if let u = obj["updatedAt"], isTruthy(u) { return pyStr(u) }
        if let c = obj["createdAt"], isTruthy(c) { return pyStr(c) }
        return ""
    }

    /// dict.update merge: overlay `override` keys onto a copy of `base`.
    public static func merge(base: JSONValue, override: JSONValue) -> JSONValue {
        guard case .object(var baseObj) = base else { return base }
        guard case .object(let ovObj) = override else { return base }
        for (k, v) in ovObj { baseObj[k] = v }
        return .object(baseObj)
    }

    /// Full mirror of Runtime.list_workflows merge logic. Returns
    /// (mergedUnsorted, sortedDescending). The caller persists `mergedUnsorted`
    /// and returns `sortedDescending`.
    public static func mergeRegistry(defaults: [JSONValue], saved: [JSONValue]) -> (mergedUnsorted: [JSONValue], sorted: [JSONValue]) {
        // by_id = {str(item.get("id")): item for item in saved}  — last write wins
        var byId: [String: JSONValue] = [:]
        for item in saved { byId[idKey(item)] = item }

        var merged: [JSONValue] = []
        for def in defaults {
            let override = byId[idKey(def)] ?? .object([:])
            merged.append(merge(base: def, override: override))
        }
        let savedIds = Set(merged.map { idKey($0) })
        for item in saved where !savedIds.contains(idKey(item)) {
            merged.append(item)
        }
        // Stable descending sort by sortKey. Swift's sort is not guaranteed
        // stable, but Python's sorted() IS stable; emulate by tagging index.
        let sorted = merged.enumerated()
            .sorted { lhs, rhs in
                let lk = sortKey(lhs.element)
                let rk = sortKey(rhs.element)
                if lk != rk { return lk > rk }      // DESC
                return lhs.offset < rhs.offset       // stable tie-break
            }
            .map { $0.element }
        return (merged, sorted)
    }
}

