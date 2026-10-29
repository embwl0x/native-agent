import AuthoredCapabilities
import Foundation
import NativeAgentShared
import NativeAgentCore
import PersistenceCore
// Blueprint: | `ToolRegistry.swift` | `ToolRecord` and AbilityStore's checked part-record projection: missing required fields are omitted; invalid authored fields fail listing and dispatch discovery; `keepReview` and `reviewedKeepDigest` bind waiting or selected code to the review captured under the ability-store lock |

// MARK: - Errors

/// Errors raised by the tool registry.
public enum ToolRegistryError: Error, LocalizedError {
    case invalidRequest(String)
    case registryUnreadable(reason: String)

    public var errorDescription: String? {
        switch self {
        case .invalidRequest(let msg): return "invalid request: \(msg)"
        case .registryUnreadable(let r): return "registry unreadable: \(r)"
        }
    }
}

// MARK: - ToolRecord

/// One checked object preserves unknown fields and explicit nulls.
public struct ToolRecord: Sendable, Equatable, Identifiable {
    public let fields: [String: JSONValue]

    public var id: String { (fields["id"]?.stringValue)! }
    public var name: String { (fields["name"]?.stringValue)! }
    public var status: String { (fields["status"]?.stringValue)! }
    public var createdAt: String { (fields["createdAt"]?.stringValue)! }
    public var updatedAt: String? { fields["updatedAt"]?.stringValue }
    public var phase: String? { fields["phase"]?.stringValue }
    public var lastUsedAt: String? { fields["lastUsedAt"]?.stringValue }
    public var manifestSignature: String? { fields["manifestSignature"]?.stringValue }
    /// Selected candidate seal, including manifest/fixtures/dependencies/prior; not source SHA-256.
    public var codeFingerprint: String? { fields["codeFingerprint"]?.stringValue }
    public var signedAt: String? { fields["signedAt"]?.stringValue }
    public var activePath: String? { fields["activePath"]?.stringValue }
    public var proposalPath: String? { fields["proposalPath"]?.stringValue }
    public var validationStatus: String? { fields["validationStatus"]?.stringValue }

    public init?(json: JSONValue) {
        guard case .object(var fields) = json else { return nil }
        for key in ["id", "name", "status", "createdAt"] {
            guard case .string(let value)? = fields[key], !value.isEmpty else { return nil }
        }
        // Malformed optional strings are absent; explicit nulls remain null.
        for key in ["updatedAt", "phase", "lastUsedAt", "manifestSignature", "codeFingerprint",
                    "signedAt", "activePath", "proposalPath", "validationStatus"] {
            switch fields[key] {
            case .string?, .null?, nil: break
            default: fields.removeValue(forKey: key)
            }
        }
        fields.removeValue(forKey: "__presentNullKeys")
        self.fields = fields
    }

    private func extra(_ key: String) -> JSONValue? { fields[key] }

    public var description: String { fields["description"]?.stringValue ?? "" }

    public var triggers: [String] { fields["triggers"]?.arrayValue?.compactMap(\.stringValue) ?? [] }
    public var permissions: [String]? { fields["permissions"]?.arrayValue?.compactMap(\.stringValue) }
    public var actions: [String]? { fields["actions"]?.arrayValue?.compactMap(\.stringValue) }
    public var validationErrors: [String]? { fields["validationErrors"]?.arrayValue?.compactMap(\.stringValue) }
    public var autoCreated: Bool? { fields["autoCreated"]?.boolValue }
    public var autoRun: Bool? { fields["autoRun"]?.boolValue }

    public var language: String? { fields["language"]?.stringValue }
    public var candidateDigest: String? { fields["candidateDigest"]?.stringValue }
    /// Review material and identity captured together by the ability-store read.
    /// Never substitute a fresh catalog digest for the version a row displayed.
    public var keepReview: [String: JSONValue]? {
        guard let digest = candidateDigest ?? codeFingerprint, !digest.isEmpty,
              case .object(let review)? = extra("keepReview"),
              review["version"] == .string(digest), case .string? = review["code"],
              case .object? = review["reach"] else { return nil }
        return review
    }
    public var reviewedKeepDigest: String? {
        guard case .string(let digest)? = keepReview?["version"] else { return nil }
        return digest
    }
    public var useCount: Int? {
        extra("useCount")?.exactIntegerValue
    }


    /// The first authored field that does not read as the Tools page reads
    /// it, or nil when every one does: `description` is required, the rest
    /// may be absent or null but never of another type. A
    /// record naming one is damaged authority, not a row to render.
    public var authoredFieldProblem: String? {
        func isString(_ value: JSONValue) -> Bool { if case .string = value { return true }; return false }
        func isStrings(_ value: JSONValue) -> Bool {
            guard case .array(let values) = value else { return false }
            return values.allSatisfy(isString)
        }
        func isBool(_ value: JSONValue) -> Bool { if case .bool = value { return true }; return false }
        guard let description = extra("description"), isString(description) else { return "description" }
        // Triggers are discovery phrases, not identity: a part found by its
        // description needs none (the seed parts have none).
        let optional: [(String, (JSONValue) -> Bool)] = [
            ("triggers", isStrings),
            ("language", isString), ("entrypoint", isString), ("permissions", isStrings), ("actions", isStrings),
            ("autoCreated", isBool), ("autoPromote", isBool), ("autoRun", isBool), ("autoPromotable", isBool),
            ("validationErrors", isStrings), ("disabledReason", isString),
            ("sourceRunId", isString), ("useCount", { $0.exactIntegerValue != nil }),
        ]
        for (key, reads) in optional {
            if let value = extra(key), value != .null, !reads(value) { return key }
        }
        return nil
    }
}

// MARK: - SwiftNative impl

/// Checked ability-file reads; mutations use the canonical storage owner.
public actor SwiftNativeToolRegistry {
    private let root: URL
    public init(root: URL = PersistenceCore.defaultDataRoot()) {
        self.root = root
    }

    // MARK: list / get

    public func listTools() async throws -> [ToolRecord] {
        let records = try AbilityStore(dataRoot: root).checkedToolRecords()
        // Newest effective timestamp first; ties retain their on-disk order.
        func sortKey(_ r: ToolRecord) -> String {
            (r.updatedAt?.isEmpty == false ? r.updatedAt : nil) ?? r.createdAt
        }
        let indexed = records.enumerated().map { (idx: $0.offset, rec: $0.element) }
        return indexed.sorted { lhs, rhs in
            let lk = sortKey(lhs.rec)
            let rk = sortKey(rhs.rec)
            if lk != rk { return lk > rk }   // primary: key DESC
            return lhs.idx < rhs.idx         // tie-break: input order ASC (stable)
        }.map(\.rec)
    }

    public func getTool(id: String) async throws -> ToolRecord? {
        let all = try await listTools()
        return all.first { $0.id == id }
    }

    // MARK: ISO timestamp helper

    /// Match Python's `now_iso()`: ISO-8601 with fractional seconds,
    /// `+00:00` suffix (not `Z`). Same convention as
    /// ApprovalInbox.
    public nonisolated static func isoTimestamp(_ date: Date) -> String {
        NativeTimestampFormat.fractionalUTCOffset(date)
    }
}

/// The checked part-record projection shared by listing and dispatch discovery.
/// Missing required fields are omitted; invalid authored fields fail the read.
extension AbilityStore {
    public func checkedToolRecords() throws -> [ToolRecord] {
        guard case .array(let items) = try registry(kind: .part) else {
            throw ToolRegistryError.registryUnreadable(reason: "abilities must contain ability records")
        }
        // One malformed part never locks the registry: it is named and left out,
        // and every other part stays usable.
        return try items.enumerated().compactMap { index, item -> ToolRecord? in
            guard let record = ToolRecord(json: item) else {
                var id = ""
                if case .object(let fields) = item, case .string(let name)? = fields["id"] { id = " (" + name + ")" }
                nativeLog("ToolRegistry: row %ld%@ has missing or invalid required fields; left out", index + 1, id)
                return nil
            }
            if let field = record.authoredFieldProblem {
                throw ToolRegistryError.registryUnreadable(reason: "tool \(record.id) has no valid \(field)")
            }
            return record
        }
    }
}
