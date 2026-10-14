import Foundation
import NativeAgentCore
import PersistenceCore

// MARK: - Errors

/// Errors raised by the tool registry.
public enum ToolRegistryError: Error, LocalizedError {
    case invalidRequest(String)
    case toolNotFound(String)
    case registryUnreadable(reason: String)
    case unavailable
    case underlying(String)
    /// Record's status/field combination is internally inconsistent — e.g.
    /// status=="active" but activePath is nil. Mirrors Python's hard-raise
    /// on the same shape so we never quarantine the wrong bytes.
    case invalidState(String)
    /// Quarantine dispatcher returned status=="pending_approval" — the
    /// receipt envelope is preserved verbatim for the caller.
    case pendingApproval(receipt: JSONValue)
    /// Quarantine dispatcher returned status=="blocked" — trust policy
    /// rejected the action; the reason string carries the human-readable why.
    case blocked(reason: String)

    public var errorDescription: String? {
        switch self {
        case .invalidRequest(let msg): return "invalid request: \(msg)"
        case .toolNotFound(let id): return "tool not found: \(id)"
        case .registryUnreadable(let r): return "registry unreadable: \(r)"
        case .unavailable: return "native tool registry unavailable"
        case .underlying(let m): return m
        case .pendingApproval: return "pending approval"
        case .blocked(let r): return "blocked: \(r)"
        case .invalidState(let m): return "invalid state: \(m)"
        }
    }
}

// MARK: - ToolRecord
//
// The daemon writes a schema-loose dict per tool. We carve a small set of
// "typed" fields the Swift impl reasons about (id/name/status, the lifecycle
// stamps, the signing block carve-outs, validationStatus, phase) and stash
// EVERYTHING ELSE in `extras` so a round-trip never drops daemon-written
// keys. presence-tracking optionals distinguish absent (nil → omit on write)
// from explicit-null (presentNullKeys → re-emit as JSON null).
//
// `extras` is JSONValue.object(...) when non-empty, nil otherwise — same
// shape as MCPDispatcher's records.

public struct ToolRecord: Sendable, Equatable {
    // Required fields — always present.
    public var id: String
    public var name: String
    public var status: String
    public var createdAt: String

    // Typed presence-tracking optionals. nil ⇒ key absent.
    public var updatedAt: String?
    public var phase: String?
    public var lastUsedAt: String?
    public var manifestSignature: String?
    public var codeFingerprint: String?
    public var signedAt: String?
    public var activePath: String?
    public var proposalPath: String?
    public var validationStatus: String?

    /// Bag of unknown / non-typed keys the daemon writes. Lossless on
    /// round-trip. Subject to the `__presentNullKeys` reserved-name strip
    /// (extras may never contain a key named `__presentNullKeys`).
    public var extras: JSONValue?

    /// Bookkeeping: which TYPED keys arrived as JSON null (not absent). On
    /// emit, these get re-written as explicit null so the daemon never sees
    /// a field disappear just because Swift parsed it through an optional.
    /// NOT public, NOT part of `extras`. The reserved name
    /// `__presentNullKeys` is stripped from extras on read AND on write.
    private var presentNullKeys: Set<String>

    public init(
        id: String,
        name: String,
        status: String,
        createdAt: String,
        updatedAt: String? = nil,
        phase: String? = nil,
        lastUsedAt: String? = nil,
        manifestSignature: String? = nil,
        codeFingerprint: String? = nil,
        signedAt: String? = nil,
        activePath: String? = nil,
        proposalPath: String? = nil,
        validationStatus: String? = nil,
        extras: JSONValue? = nil
    ) {
        self.id = id
        self.name = name
        self.status = status
        self.createdAt = createdAt
        self.updatedAt = updatedAt
        self.phase = phase
        self.lastUsedAt = lastUsedAt
        self.manifestSignature = manifestSignature
        self.codeFingerprint = codeFingerprint
        self.signedAt = signedAt
        self.activePath = activePath
        self.proposalPath = proposalPath
        self.validationStatus = validationStatus
        self.extras = extras
        self.presentNullKeys = []
    }
}

extension ToolRecord {
    /// Typed key set the struct claims directly. Everything else round-trips
    /// through `extras`. KEEP IN SYNC with both `init(json:)` and `toJSON()`.
    static let typedKeys: Set<String> = [
        "id", "name", "status", "createdAt",
        "updatedAt", "phase", "lastUsedAt",
        "manifestSignature", "codeFingerprint", "signedAt",
        "activePath", "proposalPath", "validationStatus",
    ]

    /// Reserved key never round-tripped through `extras` — used internally
    /// for the present-null bookkeeping channel.
    static let reservedExtrasKey = "__presentNullKeys"

    public init?(json: JSONValue) {
        guard case .object(let obj) = json else { return nil }

        // Required fields. If id / name / status / createdAt are missing or
        // empty, the record is malformed — drop it (caller filters nils).
        func str(_ k: String) -> String {
            if case .string(let s) = obj[k] ?? .null { return s }
            return ""
        }
        let idS = str("id")
        let nameS = str("name")
        let statusS = str("status")
        let createdS = str("createdAt")
        if idS.isEmpty || nameS.isEmpty || statusS.isEmpty || createdS.isEmpty {
            return nil
        }
        self.id = idS
        self.name = nameS
        self.status = statusS
        self.createdAt = createdS

        // Presence-tracking optionals. ABSENT → nil. PRESENT-AS-NULL → nil
        // but recorded in presentNullKeys so the explicit null re-emits.
        // PRESENT-AS-STRING → some(value).
        var nulls: Set<String> = []
        func optStr(_ k: String) -> String? {
            guard let v = obj[k] else { return nil } // absent
            switch v {
            case .null:
                nulls.insert(k); return nil
            case .string(let s):
                return s
            default:
                return nil
            }
        }
        self.updatedAt = optStr("updatedAt")
        self.phase = optStr("phase")
        self.lastUsedAt = optStr("lastUsedAt")
        self.manifestSignature = optStr("manifestSignature")
        self.codeFingerprint = optStr("codeFingerprint")
        self.signedAt = optStr("signedAt")
        self.activePath = optStr("activePath")
        self.proposalPath = optStr("proposalPath")
        self.validationStatus = optStr("validationStatus")
        self.presentNullKeys = nulls

        // Stash everything else in extras. Strip the reserved key on read so
        // a malicious / corrupted on-disk record can't smuggle a fake
        // present-null channel through us.
        var extra: [String: JSONValue] = [:]
        for (k, v) in obj where !ToolRecord.typedKeys.contains(k) && k != ToolRecord.reservedExtrasKey {
            extra[k] = v
        }
        self.extras = extra.isEmpty ? nil : .object(extra)
    }

    public func toJSON() -> JSONValue {
        var obj: [String: JSONValue] = [
            "id": .string(id),
            "name": .string(name),
            "status": .string(status),
            "createdAt": .string(createdAt),
        ]
        // Emit typed optionals using presence semantics:
        //   - .some(v)         → key present with v
        //   - .none + nullKey  → key present as JSON null
        //   - .none            → key omitted
        func emitOpt(_ key: String, _ value: String?) {
            if let v = value {
                obj[key] = .string(v)
            } else if presentNullKeys.contains(key) {
                obj[key] = .null
            }
        }
        emitOpt("updatedAt", updatedAt)
        emitOpt("phase", phase)
        emitOpt("lastUsedAt", lastUsedAt)
        emitOpt("manifestSignature", manifestSignature)
        emitOpt("codeFingerprint", codeFingerprint)
        emitOpt("signedAt", signedAt)
        emitOpt("activePath", activePath)
        emitOpt("proposalPath", proposalPath)
        emitOpt("validationStatus", validationStatus)
        // Merge extras (skip typed keys defensively + strip reserved key).
        if case .object(let extra)? = extras {
            for (k, v) in extra where !ToolRecord.typedKeys.contains(k) && k != ToolRecord.reservedExtrasKey {
                obj[k] = v
            }
        }
        return .object(obj)
    }
}

extension ToolRecord: Identifiable {}

/// The authored-tool fields the registry keeps in `extras`, read as the Tools
/// page shows them (S10). Reads only: writes still go through `extras`.
extension ToolRecord {
    private func extra(_ key: String) -> JSONValue? {
        guard case .object(let obj)? = extras else { return nil }
        return obj[key]
    }

    private func extraString(_ key: String) -> String? {
        if case .string(let value)? = extra(key) { return value }
        return nil
    }

    private func extraBool(_ key: String) -> Bool? {
        if case .bool(let value)? = extra(key) { return value }
        return nil
    }

    private func extraStrings(_ key: String) -> [String]? {
        guard case .array(let values)? = extra(key) else { return nil }
        return values.compactMap { value in
            if case .string(let string) = value { return string }
            return nil
        }
    }

    public var description: String { extraString("description") ?? "" }

    public var triggers: [String] { extraStrings("triggers") ?? [] }
    public var permissions: [String]? { extraStrings("permissions") }
    public var validationErrors: [String]? { extraStrings("validationErrors") }
    public var autoCreated: Bool? { extraBool("autoCreated") }
    public var autoRun: Bool? { extraBool("autoRun") }

    public var language: String? { extraString("language") }
    public var pendingCandidate: Bool {
        guard let candidate = extraString("candidateDigest") else { return false }
        return candidate != codeFingerprint
    }

    public var useCount: Int? {
        switch extra("useCount") {
        case .int(let value)?: return Int(exactly: value)
        case .double(let value)?: return Int(exactly: value)
        default: return nil
        }
    }

    /// The first registry string field of a raw record that is present but
    /// not a string. `init(json:)` reads such a field as absent, so a caller
    /// holding the raw record checks it first.
    public static func stringFieldProblem(in json: JSONValue) -> String? {
        guard case .object(let obj) = json else { return "record" }
        for key in ["id", "name", "status", "phase", "validationStatus", "proposalPath", "activePath",
                    "sourceRunId", "createdAt", "updatedAt", "lastUsedAt"] {
            switch obj[key] {
            case nil, .null?, .string?: continue
            default: return key
            }
        }
        return nil
    }

    /// The first authored field that does not read as the Tools page reads
    /// it, or nil when every one does: `description` and `triggers` are
    /// required, the rest may be absent or null but never of another type. A
    /// record naming one is damaged authority, not a row to render.
    public var authoredFieldProblem: String? {
        func isString(_ value: JSONValue) -> Bool { if case .string = value { return true }; return false }
        func isStrings(_ value: JSONValue) -> Bool {
            guard case .array(let values) = value else { return false }
            return values.allSatisfy(isString)
        }
        func isBool(_ value: JSONValue) -> Bool { if case .bool = value { return true }; return false }
        func isCount(_ value: JSONValue) -> Bool {
            switch value {
            case .int(let n): return Int(exactly: n) != nil
            case .double(let d): return Int(exactly: d) != nil
            default: return false
            }
        }
        guard let description = extra("description"), isString(description) else { return "description" }
        guard let triggers = extra("triggers"), isStrings(triggers) else { return "triggers" }
        let optional: [(String, (JSONValue) -> Bool)] = [
            ("language", isString), ("entrypoint", isString), ("permissions", isStrings), ("actions", isStrings),
            ("autoCreated", isBool), ("autoPromote", isBool), ("autoRun", isBool), ("autoPromotable", isBool),
            ("validationErrors", isStrings), ("disabledReason", isString),
            ("sourceRunId", isString), ("useCount", isCount),
        ]
        for (key, reads) in optional {
            if let value = extra(key), value != .null, !reads(value) { return key }
        }
        return nil
    }
}

// MARK: - Filter

public enum ToolFilter: Sendable, Equatable {
    case all
    case status(String)
}

// MARK: - Protocol

public protocol ToolRegistryProtocol: Sendable {
    func listTools(filter: ToolFilter) async throws -> [ToolRecord]
    func getTool(id: String) async throws -> ToolRecord?
    @discardableResult
    func quarantine(id: String, reason: String, ownerAuthorized: Bool) async throws -> ToolRecord
}

// MARK: - SwiftNative impl

/// Checked ability-file reads; mutations use the canonical storage owner.
public actor SwiftNativeToolRegistry: ToolRegistryProtocol {
    private let root: URL
    private let clock: @Sendable () -> Date
    public init(
        root: URL = PersistenceCore.defaultDataRoot(),
        clock: @escaping @Sendable () -> Date = { Date() }
    ) {
        self.root = root
        self.clock = clock
    }

    // MARK: list / get

    public func listTools(filter: ToolFilter) async throws -> [ToolRecord] {
        let items = try ToolRegistryActions.entries(dataRoot: root)
        let records = try items.enumerated().map { index, item in
            guard let record = ToolRecord(json: item) else {
                throw ToolRegistryError.registryUnreadable(reason: "row \(index + 1) has missing or invalid required fields")
            }
            return record
        }
        // Newest effective timestamp first; ties retain their on-disk order.
        func sortKey(_ r: ToolRecord) -> String {
            (r.updatedAt?.isEmpty == false ? r.updatedAt : nil) ?? r.createdAt
        }
        let indexed = records.enumerated().map { (idx: $0.offset, rec: $0.element) }
        let sorted = indexed.sorted { lhs, rhs in
            let lk = sortKey(lhs.rec)
            let rk = sortKey(rhs.rec)
            if lk != rk { return lk > rk }   // primary: key DESC
            return lhs.idx < rhs.idx         // tie-break: input order ASC (stable)
        }.map(\.rec)
        switch filter {
        case .all: return sorted
        case .status(let s): return sorted.filter { $0.status == s }
        }
    }

    public func getTool(id: String) async throws -> ToolRecord? {
        let all = try await listTools(filter: .all)
        return all.first { $0.id == id }
    }

    @discardableResult
    public func quarantine(id: String, reason: String, ownerAuthorized: Bool = false) async throws -> ToolRecord {
        try await ToolRegistryActions.mutate(id: id, dataRoot: root, ownerAuthorized: ownerAuthorized) { current in
            guard var fields = current else { throw ToolRegistryError.toolNotFound(id) }
            fields["status"] = .string("disabled"); fields["phase"] = .string("disabled")
            fields["updatedAt"] = .string(Self.isoTimestamp(self.clock()))
            fields["disabledReason"] = .string(reason)
            return fields
        }
        guard let updated = try await getTool(id: id) else { throw ToolRegistryError.toolNotFound(id) }
        return updated
    }

    // MARK: ISO timestamp helper

    /// Match Python's `now_iso()`: ISO-8601 with fractional seconds,
    /// `+00:00` suffix (not `Z`). Same convention as MCPDispatcher +
    /// ApprovalInbox.
    public nonisolated static func isoTimestamp(_ date: Date) -> String {
        let fmt = ISO8601DateFormatter()
        fmt.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        let zulu = fmt.string(from: date)
        if zulu.hasSuffix("Z") {
            return String(zulu.dropLast()) + "+00:00"
        }
        return zulu
    }

    // MARK: data root convenience

    public nonisolated static func defaultDataRoot() -> URL {
        PersistenceCore.defaultDataRoot()
    }
}

// MARK: - Factory

public func makeToolRegistry() -> any ToolRegistryProtocol {
    return SwiftNativeToolRegistry()
}
