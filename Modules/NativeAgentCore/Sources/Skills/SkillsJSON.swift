import Foundation
import CryptoKit
import PersistenceCore

// MARK: - Skills registry shaping (mirror Runtime.list_skills)

public enum SkillsRegistry {
    /// Retired truthiness for a scalar/collection JSONValue (matches `bool(x)`):
    /// "" / 0 / 0.0 / false / null / [] / {} are falsey.
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

    /// Sort key: `str(item.get("updatedAt") or item.get("createdAt") or "")`.
    /// Empty string sorts last in DESC order. Mirrors Python's `or` truthiness
    /// across non-string scalars exactly (a truthy numeric/bool timestamp sorts
    /// under its `str(...)` form, not "").
    public static func sortKey(_ value: JSONValue) -> String {
        guard case .object(let obj) = value else { return "" }
        if let u = obj["updatedAt"], isTruthy(u) { return pyStr(u) }
        if let c = obj["createdAt"], isTruthy(c) { return pyStr(c) }
        return ""
    }

    /// Full mirror of Runtime.list_skills:
    ///   sorted(skills, key=lambda i: str(i.get("updatedAt") or i.get("createdAt") or ""), reverse=True)
    /// Python's sorted() is stable; Swift's sort is not, so we tag the index to
    /// emulate stability on equal keys.
    public static func sortedDescending(_ skills: [JSONValue]) -> [JSONValue] {
        skills.enumerated()
            .sorted { lhs, rhs in
                let lk = sortKey(lhs.element)
                let rk = sortKey(rhs.element)
                if lk != rk { return lk > rk }      // DESC
                return lhs.offset < rhs.offset       // stable tie-break
            }
            .map { $0.element }
    }
}

// MARK: - Manifest registry merge + reshape (mirror manifest_registered_skills + route)

public enum SkillManifestRegistry {
    /// Faithful port of Runtime.manifest_registered_skills MERGE, parameterized
    /// over the two input files' raw contents so it is purely functional and
    /// testable. `entries` is ordered [legacy, dataRoot]; later files win on a
    /// name collision (mirrors the Python loop's `merged["skills"][name] = item`
    /// overwrite as it walks [legacy_path, self.manifest_skills_path]).
    ///
    /// - Parameter entries: list of (rawJSON, parentPath, filePath) tuples in
    ///   the SAME order the daemon iterates them. A file whose root is not an
    ///   object, or whose `skills` is not an object, is skipped (matches the
    ///   `continue` guards). Each surviving entry value is copied and gets
    ///   `sourceRoot` (defaulted to its file's parent dir) and `registryPath`
    ///   (defaulted to its file path) — only when those keys are absent
    ///   (setdefault semantics).
    ///
    /// - Returns: an ORDER-PRESERVING list of (name, mergedEntry) pairs. A
    ///   colliding name updates the value IN PLACE without moving its key's
    ///   position — exactly Python dict `merged[name] = item` semantics, where
    ///   re-assigning an existing key keeps its original insertion order.
    ///   This is what the GET /v1/skills/manifest route's
    ///   `for k, v in merged["skills"].items()` iterates over, so preserving the
    ///   order keeps the emitted list byte-order-equivalent to the daemon
    ///   (gpt-5.5 review finding #2, 2026-06-01).
    public static func merge(
        entries: [(raw: JSONValue, parentPath: String, filePath: String)]
    ) -> [(name: String, entry: JSONValue)] {
        var order: [String] = []
        var byName: [String: JSONValue] = [:]
        for (raw, parentPath, filePath) in entries {
            guard case .object(let root) = raw else { continue }
            guard let skillsV = root["skills"], case .object(let skills) = skillsV else { continue }
            // Python dict iteration over `data["skills"].items()` is insertion
            // order. JSONValue.object backs onto a Swift Dictionary which is
            // unordered, so the per-FILE ordering of brand-new names within one
            // file is not recoverable here. The cross-FILE order (legacy before
            // data-root) and the stable-position-on-collision rule — the parts
            // the route's emitted list actually depends on for a colliding skill
            // name — ARE preserved. Within a single file, names are visited in
            // sorted order for determinism.
            for name in skills.keys.sorted() {
                guard case .object(var entry) = skills[name]! else { continue }  // not a dict → skip
                if entry["sourceRoot"] == nil { entry["sourceRoot"] = .string(parentPath) }
                if entry["registryPath"] == nil { entry["registryPath"] = .string(filePath) }
                if byName[name] == nil { order.append(name) }  // first-seen position
                byName[name] = .object(entry)                  // collision updates in place
            }
        }
        return order.map { (name: $0, entry: byName[$0]!) }
    }

    /// The route's reshape:
    ///   [{"name": k, **v} for k, v in merged["skills"].items()]
    /// Consumes the order-preserving merge output so the emitted list matches
    /// the daemon's iteration order.
    public static func reshapeToList(_ merged: [(name: String, entry: JSONValue)]) -> [JSONValue] {
        merged.map { (name, entryV) in
            guard case .object(var entry) = entryV else {
                return .object(["name": .string(name)])
            }
            // {"name": k, **v} — the explicit "name" key is FIRST, so a `name`
            // already inside the entry value (from **v) WINS, mirroring Python's
            // `{"name": k, **v}` where the spread overwrites the leading literal.
            if entry["name"] == nil { entry["name"] = .string(name) }
            return .object(entry)
        }
    }
}

// MARK: - JSONValue convenience (local to Skills)

extension JSONValue {
    /// The backing dict if this is an `.object`, else nil. Local helper for the
    /// mutation paths' field reads.
    var objectValue: [String: JSONValue]? {
        if case .object(let o) = self { return o }
        return nil
    }
}

// MARK: - Python-semantics helpers for the mutation port

enum SkillMutation {
    /// `urllib.parse.unquote` — percent-decode using UTF-8 (matches Python's
    /// default). Leaves a string with no `%` sequences untouched.
    static func unquote(_ s: String) -> String {
        s.removingPercentEncoding ?? s
    }

    /// `str(body.get(key) or "")`-style read of a top-level string field.
    /// The `or ""` truthiness collapses a missing key, null, false, 0, and ""
    /// all to "" — matching Python (NOT pyStr, which would yield "None"/"False"/
    /// "0" for those). gpt-5.5 review finding (wave 32 W15).
    static func string(_ v: JSONValue, _ key: String) -> String {
        guard case .object(let o) = v else { return "" }
        return pyStrTruthyOr(o[key], "")
    }

    /// Python `str(x)` for the scalar JSON types that flow through these paths.
    /// null→"None", bools→"True"/"False" (matches Python str()), numbers→repr.
    static func pyStr(_ v: JSONValue) -> String {
        switch v {
        case .null: return "None"
        case .bool(let b): return b ? "True" : "False"
        case .int(let i): return String(i)
        case .double(let d): return String(d)
        case .string(let s): return s
        case .array, .object: return ""
        }
    }

    /// `str(value)` only when the value is a NON-NULL string-or-scalar; returns
    /// nil for a missing key or an explicit JSON null. Mirrors Python's
    /// `entry.get("state")` returning `None` (vs the literal "None" string).
    static func pyStrOptional(_ v: JSONValue?) -> String? {
        guard let v, v != .null else { return nil }
        return pyStr(v)
    }

    /// The truthy half of Python's `x or fallback` chain: returns `str(x)` when
    /// `x` is TRUTHY, else nil (so the caller can chain `?? next ?? default`).
    /// Differs from `pyStrOptional` in that a present-but-FALSEY value (""/0/
    /// false/[]/{}) returns nil — matching `body.get("status") or …` where an
    /// empty string falls through (gpt-5.5 review finding, wave 32 W15).
    static func pyTruthyStrOptional(_ v: JSONValue?) -> String? {
        guard let v else { return nil }
        switch v {
        case .null: return nil
        case .bool(let b): return b ? "True" : nil
        case .int(let i): return i == 0 ? nil : String(i)
        case .double(let d): return d == 0 ? nil : String(d)
        case .string(let s): return s.isEmpty ? nil : s
        case .array(let a): return a.isEmpty ? nil : ""
        case .object(let o): return o.isEmpty ? nil : ""
        }
    }

    /// `str(item.get(key) or fallback)` truthiness fold: returns the value's
    /// `str()` form when truthy, else `fallback`. Used for the record_activity
    /// display name `str(skill.get("name") or skill_id)`.
    static func pyStrTruthyOr(_ v: JSONValue?, _ fallback: String) -> String {
        guard let v else { return fallback }
        switch v {
        case .null: return fallback
        case .bool(let b): return b ? "True" : fallback
        case .int(let i): return i == 0 ? fallback : String(i)
        case .double(let d): return d == 0 ? fallback : String(d)
        case .string(let s): return s.isEmpty ? fallback : s
        case .array(let a): return a.isEmpty ? fallback : ""
        case .object(let o): return o.isEmpty ? fallback : ""
        }
    }

    /// `bool(body.get(key, False))` — retired truthiness across the scalar types.
    static func boolValue(_ v: JSONValue?) -> Bool {
        guard let v else { return false }
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

    /// `int(body.get(key) or 0)` for the useCount field. Coerces int/double/
    /// numeric-string; nil/non-numeric → nil (caller defaults to 0).
    static func intValue(_ v: JSONValue?) -> Int? {
        guard let v else { return nil }
        switch v {
        case .int(let i): return Int(i)
        case .double(let d): return Int(d)
        case .string(let s): return Int(s)
        case .bool(let b): return b ? 1 : 0
        default: return nil
        }
    }

    /// 2026-09-06: an id becomes a filename (`skills/bodies/<id>.md`), so it
    /// has to BE a filename: one path segment, nothing that walks. Legacy ids
    /// keep their spelling — this rejects only what could leave the directory.
    static func isSafeSkillID(_ value: String) -> Bool {
        guard !value.isEmpty, value.count <= 120 else { return false }
        guard value != ".", value != ".." else { return false }
        guard !value.hasPrefix(".") else { return false }
        return !value.contains("/") && !value.contains("\\") && !value.contains("\0")
            && value.trimmingCharacters(in: .whitespacesAndNewlines) == value
    }

    /// Allocate only a newly assigned identity; callers preserve explicit ids.
    /// Runs inside the canonical registry lock for both creation and legacy
    /// missing-id repair, before either path writes a body.
    static func availableID(for name: String, existingIDs: Set<String>) -> String {
        let base = slugify(name)
        // Legacy explicit IDs retain their spelling, but readers match IDs
        // case-insensitively and normal Mac volumes share case-only paths.
        let occupied = Set(existingIDs.map { $0.lowercased() })
        var candidate = base
        while occupied.contains(candidate.lowercased()) {
            candidate = "\(base)-\(String(UUID().uuidString.lowercased().prefix(8)))"
        }
        return candidate
    }

    /// `slugify` mirror: lowercase, replace every run of
    /// non-`[a-z0-9]` with `-`, strip leading/trailing `-`, cap at 80; empty →
    /// a fresh uuid4.
    static func slugify(_ value: String) -> String {
        let lowered = value.lowercased()
        var out = ""
        var lastWasDash = false
        for ch in lowered.unicodeScalars {
            let isAllowed = (ch >= "a" && ch <= "z") || (ch >= "0" && ch <= "9")
            if isAllowed {
                out.unicodeScalars.append(ch)
                lastWasDash = false
            } else if !lastWasDash {
                out.append("-")
                lastWasDash = true
            }
        }
        // strip("-")
        while out.hasPrefix("-") { out.removeFirst() }
        while out.hasSuffix("-") { out.removeLast() }
        let capped = String(out.prefix(80))
        return capped.isEmpty ? UUID().uuidString.lowercased() : capped
    }

    /// `now_iso()` = `datetime.now(timezone.utc).isoformat()`. Python emits
    /// MICROSECOND precision with a `+00:00` offset. The Swift cutover convention
    /// (established wave 7 routerPlan / WorkshopExecution.isoTimestamp) uses MILLISECOND
    /// fractional seconds + `+00:00`. This is the documented intra-cutover
    /// deviation: updatedAt/createdAt are never compared for equality across the
    /// boundary, only sorted lexicographically DESC, and a single record is
    /// stamped by exactly ONE side per mutation — so ms-vs-µs only perturbs the
    /// relative order of two records written within the same millisecond, an
    /// ordering the daemon itself does not guarantee.
    static func nowISO(_ now: @Sendable () -> Date) -> String {
        let fmt = ISO8601DateFormatter()
        fmt.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        let zulu = fmt.string(from: now())
        if zulu.hasSuffix("Z") { return String(zulu.dropLast()) + "+00:00" }
        return zulu
    }
}

