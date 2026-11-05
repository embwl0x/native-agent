import Foundation
import NativeAgentShared
import NativeAgentCore
import PersistenceCore
import TrustCenter
// Blueprint: | `Context.swift` | `SwiftNativeContextClient`: current feature-surface lookup with one typed query and bounded results |

// MARK: - Result type

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

    public func lookup(query: String) -> ContextLookupResult {
        let createdAt = ContextLookupResult.isoTimestamp(now())
        let records = featureSurfaceRecords(nowISO: createdAt)
        let needle = query.lowercased()
        let filtered = needle.isEmpty ? records : records.filter {
            $0.name.lowercased().contains(needle) || $0.description.lowercased().contains(needle)
        }
        return ContextLookupResult(status: "ready", type: "lookup_feature_surface",
            query: query, features: filtered.prefix(30).map { $0.contextLookupJSON() }, createdAt: createdAt)
    }
}

extension ContextLookupResult {
    public static func isoTimestamp(_ date: Date) -> String {
        NativeTimestampFormat.flooredOptionalMicrosecondUTCOffset(date)
    }
}
