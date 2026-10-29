import Foundation
import NativeAgentShared
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
    static func firstNonEmptyString(_ body: [String: JSONValue], keys: [String]) -> String? {
        for k in keys {
            if let s = pythonStr(body[k]) { return s }
        }
        return nil
    }

    /// Skip falsey values; retain capitalized true and container sentinels.
    /// Other scalars keep JSONValue's verbatim strings and numeric spelling.
    static func pythonStr(_ value: JSONValue?) -> String? {
        guard let value, value.isTruthy else { return nil }
        switch value {
        case .bool: return "True"
        case .array: return "<array>"
        case .object: return "<object>"
        default: return value.scalarText
        }
    }
}

extension ContextLookupResult {
    /// ISO-8601 UTC timestamp preserving legacy feature-surface lookup formatting.
    public static func isoTimestamp(_ date: Date) -> String {
        NativeTimestampFormat.flooredOptionalMicrosecondUTCOffset(date)
    }
}
