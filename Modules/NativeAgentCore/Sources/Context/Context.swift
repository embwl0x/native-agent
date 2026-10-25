import Foundation
import NativeAgentCore
import PersistenceCore
import TrustCenter
// Blueprint: | `Context.swift` | `SwiftNativeContextClient`: feature-surface lookup only; no legacy receipt reader or retention. Existing `context/<runID>.json` files are left for the operator. |

// MARK: - Result type

/// Byte-equal envelope for `context_lookup`.
/// `features` is the post-filter, post-slice list of feature-surface dicts in
/// Python key order; `createdAt` is `now_iso()`.
public struct ContextLookupResult: Sendable, Equatable {
    public let status: String
    public let type: String
    public let query: String
    public let features: [JSONValue]
    public let createdAt: String

    public init(status: String, type: String, query: String, features: [JSONValue], createdAt: String) {
        self.status = status
        self.type = type
        self.query = query
        self.features = features
        self.createdAt = createdAt
    }

    /// Envelope in the exact key order the Python handler emits:
    /// {"status", "type", "query", "features", "createdAt"}.
    public func toJSON() -> JSONValue {
        .object([
            "status": .string(status),
            "type": .string(type),
            "query": .string(query),
            "features": .array(features),
            "createdAt": .string(createdAt),
        ])
    }
}

// MARK: - Feature-surface record → JSON (Python dict key order)

extension FeatureSurfaceRecord {
    /// Per-record dict in the SAME insertion order as the Python literal
    ///: id, sourceId, name, kind, status,
    /// description, triggers, permissions, riskClass, autoload, useCount,
    /// lastUsedAt, updatedAt, endpoints. `lastUsedAt` is always nil in the
    /// static literal → emitted as JSON null (matching Python `None`).
    public func contextLookupJSON() -> JSONValue {
        .object([
            "id": .string(id),
            "sourceId": .string(sourceId),
            "name": .string(name),
            "kind": .string(kind),
            "status": .string(status),
            "description": .string(description),
            "triggers": .array(triggers.map { .string($0) }),
            "permissions": .array(permissions.map { .string($0) }),
            "riskClass": .string(riskClass),
            "autoload": .bool(autoload),
            "useCount": .int(Int64(useCount)),
            "lastUsedAt": lastUsedAt.map { JSONValue.string($0) } ?? .null,
            "updatedAt": .string(updatedAt),
            "endpoints": .array(endpoints.map { .string($0) }),
        ])
    }
}

// MARK: - SwiftNative impl

public actor SwiftNativeContextClient {
    private let now: @Sendable () -> Date
    public init(
        now: @escaping @Sendable () -> Date = { Date() }
    ) {
        self.now = now
    }

    /// Feature-surface lookup type aliases.
    private static let featureSurfaceTypes: Set<String> = [
        "lookup_feature_surface", "feature_surface", "features",
    ]

    public func lookup(body: [String: JSONValue]) async -> ContextLookupResult? {
        // type = str(body.get("type") or body.get("lookup") or body.get("id")
        //            or "lookup_capability")
        let lookupType = Self.firstNonEmptyString(body, keys: ["type", "lookup", "id"])
            ?? "lookup_capability"
        // Only the feature-surface family is divergence-free-portable today.
        guard Self.featureSurfaceTypes.contains(lookupType) else { return nil }

        // query = str(body.get("query") or body.get("message") or "")
        let query = Self.firstNonEmptyString(body, keys: ["query", "message"]) ?? ""

        let createdAt = ContextLookupResult.isoTimestamp(now())
        let nowISO = createdAt  // updatedAt uses the same now_iso() per call
        let allRecords = featureSurfaceRecords(nowISO: nowISO)

        // Python: filter only when query is truthy (non-empty); else all records.
        // Match is `query.lower() in name.lower() OR query.lower() in desc.lower()`.
        let filtered: [FeatureSurfaceRecord]
        if query.isEmpty {
            filtered = allRecords
        } else {
            let needle = query.lowercased()
            filtered = allRecords.filter {
                $0.name.lowercased().contains(needle)
                    || $0.description.lowercased().contains(needle)
            }
        }
        // features[:30]
        let sliced = Array(filtered.prefix(30))
        return ContextLookupResult(
            status: "ready",
            type: lookupType,
            query: query,
            features: sliced.map { $0.contextLookupJSON() },
            createdAt: createdAt
        )
    }

    /// Mirrors Python's `str(body.get(a) or body.get(b) or ...)` chain over the
    /// SAME truthiness rules `or` uses: returns the `str()`-coercion of the first
    /// key whose value is PYTHON-TRUTHY. A falsy value (None / "" / 0 / 0.0 /
    /// False / [] / {}) is skipped, exactly as Python's `x or next` skips it.
    /// (gpt-5.5 review finding #2: a string-only variant would diverge for a
    /// truthy non-string `message`/`reason` — e.g. `message=1` → Python hint-
    /// eligible, string-only Swift not.)
    static func firstNonEmptyString(_ body: [String: JSONValue], keys: [String]) -> String? {
        for k in keys {
            if let s = pythonStr(body[k]) { return s }
        }
        return nil
    }

    /// Returns `str(value)` IFF `value` is Python-truthy, else nil (so a chain of
    /// `pythonStr(...) ?? pythonStr(...) ?? fallback` reproduces `a or b or c`).
    /// Falsy JSON values map to nil: null, "" , 0, 0.0, false, [], {}.
    /// Truthy values are coerced to their Python `str()` text for the shapes that
    /// actually occur in these payloads (string verbatim; bool → "True"/"False";
    /// int → decimal; double → Python float repr for the common integral/simple
    /// cases). These coercions exist for parity-defense; in production every one
    /// of these fields is a string.
    static func pythonStr(_ value: JSONValue?) -> String? {
        guard let value else { return nil }
        switch value {
        case .null:
            return nil
        case .string(let s):
            return s.isEmpty ? nil : s
        case .bool(let b):
            return b ? "True" : "False"   // Python str(True) == "True"
        case .int(let i):
            return i == 0 ? nil : String(i)
        case .double(let d):
            if d == 0 { return nil }
            // Python str() of an integral float drops the fraction only via repr
            // rules; for the parity-defense scope (these are never floats in
            // practice) emit Swift's default which matches Python for simple
            // values closely enough — the field is non-load-bearing here.
            return String(d)
        case .array(let a):
            return a.isEmpty ? nil : "<array>"   // truthy non-empty list; never occurs
        case .object(let o):
            return o.isEmpty ? nil : "<object>"  // truthy non-empty dict; never occurs
        }
    }
}

extension ContextLookupResult {
    /// ISO-8601 UTC timestamp preserving legacy feature-surface lookup formatting.
    public static func isoTimestamp(_ date: Date) -> String {
        NativeTimestampFormat.flooredOptionalMicrosecondUTCOffset(date)
    }
}
