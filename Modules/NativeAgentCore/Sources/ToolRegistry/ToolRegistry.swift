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
    func promote(id: String) async throws -> ToolRecord
    @discardableResult
    func quarantine(id: String, reason: String) async throws -> ToolRecord
}

// MARK: - SwiftNative impl

/// File-backed tool registry mirroring the retired daemon promote_tool +
/// quarantine_tool. Actor-isolated for R-M-W serialization on
/// `<root>/tools/registry.json`.
///
/// HARD SCOPE CARVE-OUTS — Swift impl deliberately does NOT touch:
///   - manifestSignature / signedAt / signatureVersion       (HMAC signing)
///   - codeFingerprint                                       (hash of tool code on disk)
///   - activePath / proposalPath                             (copytree work)
///   - validationStatus / validationErrors / lastValidatedAt (validate_tool pipeline)
///   - autoPromotable / autoRun / autoPromote                (policy fields)
///   - manualApprovalRequired                                (policy)
///   - quarantinePath — promote DOES clear it to JSON null on the way back
///     to active. Quarantine now SETS it: see _quarantineImpl, which
///     mirrors the daemon's shutil.copytree of <tools>/active/<id>/ →
///     <tools>/quarantine/<id>/ and stamps the resulting path onto the
///     record. Carve is therefore symmetric: both paths write this field.
///   - riskAcknowledgedAt / riskAcknowledgedBy / userRequestedActivation
/// All carve-outs round-trip via `extras` untouched.
public actor SwiftNativeToolRegistry: ToolRegistryProtocol {
    private let root: URL
    private let persistence: any PersistenceCoreProtocol
    private let clock: @Sendable () -> Date
    private var mutationTail: Task<Void, Never>? = nil

    public init(
        root: URL = PersistenceCore.defaultDataRoot(),
        persistence: (any PersistenceCoreProtocol)? = nil,
        clock: @escaping @Sendable () -> Date = { Date() }
    ) {
        self.root = root
        self.persistence = persistence ?? SwiftNativePersistenceCore()
        self.clock = clock
    }

    public var registryPath: URL {
        root
            .appendingPathComponent("tools", isDirectory: true)
            .appendingPathComponent("registry.json")
    }

    // MARK: list / get

    public func listTools(filter: ToolFilter) async throws -> [ToolRecord] {
        let raw = await persistence.readJSON(registryPath, defaultValue: .array([]))
        guard case .array(let items) = raw else { return [] }
        let records = items.compactMap(ToolRecord.init(json:))
        // Sort key mirrors daemon list_tools:
        // sorted(tools, key=updatedAt-or-createdAt-or-"", reverse=True).
        // ISO-8601 strings sort lexicographically in the right order, so a
        // plain string compare reproduces the DESC ordering.
        //
        // STABILITY (read-parity gap fix, wave 36 §6.138): Python's `sorted`
        // is STABLE — records that tie on the effective key keep their
        // on-disk (input) order. Swift's `sorted(by:)` makes NO stability
        // guarantee, so a tie could surface in a different order than the
        // daemon and silently diverge the read surface. Pin the order by
        // sorting on (key DESC, originalIndex ASC): the index tie-break
        // reproduces Python's keep-input-order-on-tie behavior exactly.
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

    // MARK: mutating ops — R-M-W serialization gate

    private func runSerialized<T: Sendable>(
        _ body: @Sendable @escaping () async throws -> T
    ) async throws -> T {
        let prior = mutationTail
        let task = Task<T, Error> {
            _ = await prior?.value
            return try await body()
        }
        mutationTail = Task { _ = try? await task.value }
        return try await task.value
    }

    @discardableResult
    public func promote(id: String) async throws -> ToolRecord {
        let trimmed = id.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.isEmpty {
            throw ToolRegistryError.invalidRequest("empty id")
        }
        return try await runSerialized { [persistence, registryPath, clock] in
            let now = clock()
            let work: @Sendable () async throws -> ToolRecord = {
                try await Self._promoteImpl(
                    id: id,
                    persistence: persistence,
                    registryPath: registryPath,
                    now: now
                )
            }
            // Cross-process flock around the R-M-W of registry.json. The
            // daemon's Python side wraps `upsert_tool_record` / `delete_tool`
            // (and the tool_description proposal branch) in the same
            // `<registryPath>.lock` flock. Without this
            // wrap, the Swift promote would be the one-sided mutator.
            // Order: process-local serialize (runSerialized) FIRST, then
            // cross-process flock INSIDE — mirrors the Wave 6 JSONLEmbeddingStore
            // pattern. EVERY conformer takes the flock — see below.
            // Uniform locking (L7, 2026-08-01): `withFileLock` is a
            // PersistenceCoreProtocol EXTENSION (PersistenceCore+FileLock.swift:4), so
            // every conformer already has it. The old downcast to
            // SwiftNativePersistenceCore only had the effect of running this critical
            // section UNLOCKED for any other conformer.
            return try await persistence.withFileLock(registryPath, work)
        }
    }

    private static func _promoteImpl(
        id: String,
        persistence: any PersistenceCoreProtocol,
        registryPath: URL,
        now: Date
    ) async throws -> ToolRecord {
        let raw = await persistence.readJSON(registryPath, defaultValue: .array([]))
        guard case .array(let items) = raw else {
            throw ToolRegistryError.toolNotFound(id)
        }
        var mutated: [JSONValue] = items
        var foundIdx: Int? = nil
        for (idx, item) in items.enumerated() {
            guard case .object(let obj) = item,
                  case .string(let rid) = obj["id"] ?? .null,
                  rid == id else { continue }
            foundIdx = idx; break
        }
        guard let idx = foundIdx, case .object(var obj) = mutated[idx] else {
            throw ToolRegistryError.toolNotFound(id)
        }
        let stamp = isoTimestamp(now)
        // Flip status + phase to active; restamp updatedAt; mirror daemon
        // L33949-33997: write promotedAt, clear quarantineReason+quarantinePath
        // by setting them to JSON null (NOT removing the keys — the daemon
        // emits `None`, which json.dumps writes as `null`).
        obj["status"] = .string("active")
        obj["phase"] = .string("active")
        obj["updatedAt"] = .string(stamp)
        obj["promotedAt"] = .string(stamp)
        obj["quarantineReason"] = .null
        obj["quarantinePath"] = .null
        // CARVED OUT (NOT TOUCHED) — see struct doc above. Listed here so a
        // future reader doesn't think the omission is a bug:
        //   manifestSignature, signedAt, signatureVersion  (daemon HMAC signer)
        //   codeFingerprint                                 (re-hashes tool on disk)
        //   activePath                                      (copytree work)
        //   validationStatus, validationErrors, lastValidatedAt
        //                                                   (daemon validate_tool pipeline)
        //   autoPromotable, autoRun, autoPromote, manualApprovalRequired
        //                                                   (policy fields)
        //   riskAcknowledgedAt, riskAcknowledgedBy, userRequestedActivation
        //                                                   (only set by the daemon's
        //                                                    permission-intersection path)
        mutated[idx] = .object(obj)
        try await persistence.writeJSON(.array(mutated), to: registryPath)
        guard let rec = ToolRecord(json: .object(obj)) else {
            throw ToolRegistryError.registryUnreadable(reason: "post-promote record unparseable")
        }
        return rec
    }

    @discardableResult
    public func quarantine(id: String, reason: String) async throws -> ToolRecord {
        let trimmed = id.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.isEmpty {
            throw ToolRegistryError.invalidRequest("empty id")
        }
        return try await runSerialized { [persistence, registryPath, clock] in
            try await Self._quarantineImpl(
                id: id,
                reason: reason,
                persistence: persistence,
                registryPath: registryPath,
                now: clock()
            )
        }
    }

    private static func _quarantineImpl(
        id: String,
        reason: String,
        persistence: any PersistenceCoreProtocol,
        registryPath: URL,
        now: Date
    ) async throws -> ToolRecord {
        // APPROVAL GATE — intentionally absent.
        //
        // SwiftNativeToolRegistry mirrors the business-logic layer. Dispatcher
        // approval gates must be applied before callers invoke this method.
        let work: @Sendable () async throws -> ToolRecord = {
            let raw = await persistence.readJSON(registryPath, defaultValue: .array([]))
            guard case .array(let items) = raw else {
                throw ToolRegistryError.toolNotFound(id)
            }
            var mutated: [JSONValue] = items
            var foundIdx: Int? = nil
            for (idx, item) in items.enumerated() {
                guard case .object(let obj) = item,
                      case .string(let rid) = obj["id"] ?? .null,
                      rid == id else { continue }
                foundIdx = idx; break
            }
            guard let idx = foundIdx, case .object(var obj) = mutated[idx] else {
                throw ToolRegistryError.toolNotFound(id)
            }

            // File move — mirror daemon L34020-34026:
            //   source_dir = tool_dir_for_record(record)
            //   quarantine_dir = <root>/tools/quarantine/<id>
            //   if quarantine_dir.exists(): shutil.rmtree(quarantine_dir)
            //   if source_dir.exists(): shutil.copytree(source_dir, quarantine_dir)
            // Atomic-ish: copy into a tmp sibling, then renameItem into place.
            let toolsRoot = registryPath.deletingLastPathComponent() // <root>/tools
            let quarantineRoot = toolsRoot.appendingPathComponent("quarantine", isDirectory: true)
            let quarantineDir = quarantineRoot.appendingPathComponent(id, isDirectory: true)
            let sourceDir = try Self._resolveSourceDir(record: obj, toolsRoot: toolsRoot, id: id)
            let fm = FileManager.default
            try fm.createDirectory(at: quarantineRoot, withIntermediateDirectories: true)
            // SAFE-SWAP REORDER (Finding #5):
            //   Old order: rmtree(existing quarantine) → copy(src→tmp) → move(tmp→final).
            //   Risk: if src is missing or copy fails mid-flight, the prior
            //   quarantined body is already gone — data loss.
            //   New order:
            //     1. copy src → .incoming-<uuid>
            //     2. move existing quarantineDir → .backup-<uuid> (atomic)
            //     3. move .incoming-<uuid> → quarantineDir       (atomic)
            //     4. on success: rm .backup-<uuid>
            //     5. on any failure: clean .incoming, restore .backup.
            if let src = sourceDir, fm.fileExists(atPath: src.path) {
                let incoming = quarantineRoot.appendingPathComponent(
                    ".incoming-\(id)-\(UUID().uuidString)", isDirectory: true)
                let backup = quarantineRoot.appendingPathComponent(
                    ".backup-\(id)-\(UUID().uuidString)", isDirectory: true)
                // Step 1: copy into sibling tmp. If this throws, no existing
                // state has been disturbed yet.
                try fm.copyItem(at: src, to: incoming)
                var backedUp = false
                do {
                    // Step 2: rotate existing quarantine aside.
                    if fm.fileExists(atPath: quarantineDir.path) {
                        try fm.moveItem(at: quarantineDir, to: backup)
                        backedUp = true
                    }
                    // Step 3: swing incoming into place.
                    try fm.moveItem(at: incoming, to: quarantineDir)
                    // Step 4: discard the backup.
                    if backedUp {
                        try? fm.removeItem(at: backup)
                    }
                } catch {
                    // Step 5: restore prior state, drop incoming.
                    try? fm.removeItem(at: incoming)
                    if backedUp && !fm.fileExists(atPath: quarantineDir.path) {
                        try? fm.moveItem(at: backup, to: quarantineDir)
                    } else if backedUp {
                        try? fm.removeItem(at: backup)
                    }
                    throw error
                }
            }
            // If sourceDir is nil or missing, do NOT touch an existing
            // quarantine dir — preserving prior body is strictly safer than
            // mirroring the old delete-only branch.

            let stamp = isoTimestamp(now)
            // Flip status + phase to quarantined; stamp quarantinedAt + reason
            // + quarantinePath. Mirrors daemon L34027-34034.
            obj["status"] = .string("quarantined")
            obj["phase"] = .string("quarantined")
            obj["updatedAt"] = .string(stamp)
            obj["quarantinedAt"] = .string(stamp)
            obj["quarantineReason"] = .string(reason)
            obj["quarantinePath"] = .string(quarantineDir.path)
            // CARVED OUT (NOT TOUCHED):
            //   manifestSignature / signedAt / codeFingerprint — the signing
            //                    block is invariant under quarantine; it's
            //                    proof of WHAT was quarantined, not metadata
            //                    about the quarantine.
            mutated[idx] = .object(obj)
            try await persistence.writeJSON(.array(mutated), to: registryPath)
            guard let rec = ToolRecord(json: .object(obj)) else {
                throw ToolRegistryError.registryUnreadable(reason: "post-quarantine record unparseable")
            }
            return rec
        }

        // Cross-process flock around the R-M-W of registry.json + the file
        // move. EVERY conformer takes the flock — see below.
        // Uniform locking (L7, 2026-08-01): `withFileLock` is a
        // PersistenceCoreProtocol EXTENSION (PersistenceCore+FileLock.swift:4), so
        // every conformer already has it. The old downcast to
        // SwiftNativePersistenceCore only had the effect of running this critical
        // section UNLOCKED for any other conformer.
        return try await persistence.withFileLock(registryPath, work)
    }

    /// Mirror of daemon.native_agentd.NativeAgentRuntime.tool_dir_for_record
    /// (L33358-33368). Returns nil only if no candidate string was usable —
    /// the daemon falls back to `<root>/tools/proposals/<id>` in that case
    /// and we do the same, so the caller can existence-check it.
    private static func _resolveSourceDir(
        record: [String: JSONValue],
        toolsRoot: URL,
        id: String
    ) throws -> URL? {
        func str(_ k: String) -> String? {
            if case .string(let s) = record[k] ?? .null, !s.isEmpty { return s }
            return nil
        }
        let status = str("status") ?? ""
        // Finding #6 — Python raises if status=="active" but activePath is
        // missing; falling through to proposalPath would quarantine stale
        // bytes. Match the hard-raise.
        if status == "active" {
            guard let ap = str("activePath") else {
                throw ToolRegistryError.invalidState(
                    "active record missing activePath: \(id)")
            }
            return URL(fileURLWithPath: ap)
        }
        if status == "quarantined", let qp = str("quarantinePath") {
            let url = URL(fileURLWithPath: qp)
            if FileManager.default.fileExists(
                atPath: url.appendingPathComponent("manifest.json").path
            ) {
                return url
            }
        }
        if let pp = str("proposalPath") {
            return URL(fileURLWithPath: pp)
        }
        return toolsRoot
            .appendingPathComponent("proposals", isDirectory: true)
            .appendingPathComponent(id, isDirectory: true)
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
