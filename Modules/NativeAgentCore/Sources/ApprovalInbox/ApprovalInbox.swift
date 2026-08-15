import Foundation
import NativeAgentCore
import PersistenceCore

// MARK: - Records

/// One record in the autonomy approval queue. Preserves the stable
/// `create_approval_request` shape.
///
/// Timestamps are ISO-8601 strings. The `decision` and `resolvedAt` fields
/// stay nil until the request is resolved.
///
/// `executedAction` and `detail` are post-resolve fields written by the
/// daemon after action execution. They are lossless `JSONValue?` because
/// Python persists them in many shapes (dataclass asdict, error dict,
/// receipt dict — see executedAction sites at the retired daemon,
/// L7432, L7464, L7487, L7541-7700). Unlike `resolvedAt`/`decision` which
/// are written as explicit JSON null on pending records, these two are
/// OMITTED entirely when nil — matching Python's behavior.
public struct ApprovalRecord: Sendable, Equatable {
    public var id: String
    public var title: String
    public var action: String
    public var risk: String
    public var reason: String
    public var status: String            // "pending" | "resolved" | "denied" | "canceled" | "orphaned"
    public var payload: JSONValue        // arbitrary JSON dict
    public var payloadPreview: String
    public var createdAt: String         // ISO-8601
    public var resolvedAt: String?       // ISO-8601 or nil
    public var decision: String?         // "approved" | "denied" | "canceled" | nil
    public var remoteResolvable: Bool
    public var localOnly: Bool
    public var executedAction: JSONValue?
    public var detail: String?

    public init(
        id: String,
        title: String,
        action: String,
        risk: String,
        reason: String,
        status: String,
        payload: JSONValue,
        payloadPreview: String,
        createdAt: String,
        resolvedAt: String? = nil,
        decision: String? = nil,
        remoteResolvable: Bool,
        localOnly: Bool,
        executedAction: JSONValue? = nil,
        detail: String? = nil
    ) {
        self.id = id
        self.title = title
        self.action = action
        self.risk = risk
        self.reason = reason
        self.status = status
        self.payload = payload
        self.payloadPreview = payloadPreview
        self.createdAt = createdAt
        self.resolvedAt = resolvedAt
        self.decision = decision
        self.remoteResolvable = remoteResolvable
        self.localOnly = localOnly
        self.executedAction = executedAction
        self.detail = detail
    }
}

extension ApprovalRecord {
    /// Build a record from the JSONValue object dict produced by the Python
    /// daemon. Tolerant of missing keys (matches Python's defensive reads).
    public init?(json: JSONValue) {
        guard case .object(let obj) = json else { return nil }
        func str(_ key: String) -> String {
            if case .string(let s) = obj[key] ?? .null { return s }
            return ""
        }
        func optStr(_ key: String) -> String? {
            switch obj[key] ?? .null {
            case .string(let s): return s
            case .null: return nil
            default: return nil
            }
        }
        func bool(_ key: String) -> Bool {
            if case .bool(let b) = obj[key] ?? .null { return b }
            return false
        }
        let idStr = str("id")
        if idStr.isEmpty { return nil }
        self.id = idStr
        self.title = str("title")
        self.action = str("action")
        self.risk = str("risk")
        self.reason = str("reason")
        self.status = str("status")
        self.payload = obj["payload"] ?? .object([:])
        self.payloadPreview = str("payloadPreview")
        self.createdAt = str("createdAt")
        self.resolvedAt = optStr("resolvedAt")
        self.decision = optStr("decision")
        self.remoteResolvable = bool("remoteResolvable")
        self.localOnly = bool("localOnly")
        // executedAction is lossless: preserve whatever shape Python wrote.
        if let v = obj["executedAction"], case .null = v {
            self.executedAction = nil
        } else if let v = obj["executedAction"] {
            self.executedAction = v
        } else {
            self.executedAction = nil
        }
        self.detail = optStr("detail")
    }

    /// Serialize back to JSONValue with Python-equivalent shape: nullable
    /// fields become explicit `null` (not absent) to match Python's
    /// `"decision": None` / `"resolvedAt": None` serialization.
    ///
    /// `executedAction` and `detail` are OMITTED when nil (not written as
    /// null) — Python only adds these keys after action execution.
    public func toJSON() -> JSONValue {
        var obj: [String: JSONValue] = [
            "id": .string(id),
            "title": .string(title),
            "action": .string(action),
            "risk": .string(risk),
            "reason": .string(reason),
            "status": .string(status),
            "payload": payload,
            "payloadPreview": .string(payloadPreview),
            "createdAt": .string(createdAt),
            "remoteResolvable": .bool(remoteResolvable),
            "localOnly": .bool(localOnly),
        ]
        obj["resolvedAt"] = resolvedAt.map(JSONValue.string) ?? .null
        obj["decision"] = decision.map(JSONValue.string) ?? .null
        if let ea = executedAction {
            obj["executedAction"] = ea
        }
        if let d = detail {
            obj["detail"] = .string(d)
        }
        return .object(obj)
    }
}

// MARK: - Filter / Decision

public struct ApprovalFilter: Sendable, Equatable {
    /// "pending", "resolved", "denied", "canceled", "orphaned", or nil for all.
    public var status: String?
    /// If set, only records whose `action` matches — compared through
    /// `ExecutionEventVocabulary`, so `mission.step` and `execution.step`
    /// are the same filter.
    public var action: String?

    public init(status: String? = nil, action: String? = nil) {
        self.status = status
        self.action = action
    }

    public static let all = ApprovalFilter()
    public static let pending = ApprovalFilter(status: "pending")
    public static let resolved = ApprovalFilter(status: "resolved")
}

/// Accepted approval decision values.
public enum ApprovalDecision: String, Sendable, Equatable {
    case approved
    case denied
    case canceled
}

// MARK: - Errors

public enum ApprovalInboxError: Error, Equatable {
    /// Approval id was not found in the queue.
    case notFound(String)
    /// Tried to resolve an approval that's already in a terminal state.
    case alreadyResolved(id: String, status: String)
    /// Decision verb was outside {approved, denied, canceled}.
    case invalidDecision(String)
    /// Method is outside the Swift-native surface.
    case unsupported(String)
    /// Legacy transport error case retained for API compatibility.
    case http(status: Int, body: String)
    /// JSON serialization or shape mismatch.
    case malformedResponse(String)
    /// Legacy transport-level failure case retained for API compatibility.
    case unavailable(underlying: String)
}

// MARK: - Protocol

/// Subsystem #2 — autonomy approval request queue.
///
/// Storage: `<root>/workflows/approvals/requests.json` (single JSON file,
/// list of records). Mutation is single-writer per process: callers must
/// not run two `resolve` calls concurrently against the same on-disk file.
public protocol ApprovalInboxProtocol: Sendable {
    /// Return the queue, newest-first by createdAt, optionally filtered.
    func list(filter: ApprovalFilter) async throws -> [ApprovalRecord]

    /// Return a single record by id, or `.notFound` if absent.
    func get(_ id: String) async throws -> ApprovalRecord

    /// Create and persist a pending approval request. Preserves the
    /// `create_approval_request` record shape; notification/chat side effects
    /// are owned by higher-level surfaces.
    @discardableResult
    func create(_ body: JSONValue) async throws -> ApprovalRecord

    /// Resolve a pending approval. Throws `.alreadyResolved` for terminal
    /// states. `decidedBy` is captured for the audit trail; the on-disk
    /// stable shape only sets `status`, `decision`,
    /// `resolvedAt`.
    @discardableResult
    func resolve(_ id: String, decision: ApprovalDecision, decidedBy: String) async throws -> ApprovalRecord

    /// Drop terminal records older than `cutoff`. Returns the count
    /// removed. Pending records are NEVER archived.
    @discardableResult
    func archive(olderThan cutoff: Date) async throws -> Int
}

// MARK: - SwiftNative implementation

/// File-backed implementation. Reads/writes
/// `<root>/workflows/approvals/requests.json` via PersistenceCore for
/// atomic, 0600, sorted-keys, UTF-8 IO.
///
/// Actor-isolated: serializes concurrent resolve/archive calls so two
/// in-flight mutations against the same on-disk file can't clobber each
/// other's writes.
public actor SwiftNativeApprovalInbox: ApprovalInboxProtocol {
    // Module-internal (not private) so `ApprovalInbox+InjectionSpend.swift`
    // can build the durable spend marker against the same root/persistence.
    let root: URL
    let persistence: any PersistenceCoreProtocol
    let clock: @Sendable () -> Date
    /// Serializes mutating ops (resolve/archive) against actor reentrancy:
    /// each new mutation chains after the prior one so two concurrent
    /// resolve calls can't interleave their read→mutate→write sequence.
    private var mutationTail: Task<Void, Never>? = nil

    /// - root: the daemon's data root (e.g. `<repo>/data`). The approvals
    ///   file lives at `<root>/workflows/approvals/requests.json`.
    /// - persistence: defaults to SwiftNativePersistenceCore.
    /// - clock: injectable for tests.
    public init(
        root: URL,
        persistence: (any PersistenceCoreProtocol)? = nil,
        clock: @escaping @Sendable () -> Date = { Date() }
    ) {
        self.root = root
        self.persistence = persistence ?? SwiftNativePersistenceCore()
        self.clock = clock
    }

    /// Path the daemon reads/writes (matches `self.approvals_path` in
    /// the retired daemon).
    public var approvalsPath: URL {
        root
            .appendingPathComponent("workflows", isDirectory: true)
            .appendingPathComponent("approvals", isDirectory: true)
            .appendingPathComponent("requests.json")
    }

    public func list(filter: ApprovalFilter) async throws -> [ApprovalRecord] {
        let items = try await persistence.withFileLock(approvalsPath) { [approvalsPath] in
            try Self.loadApprovalRowsChecked(at: approvalsPath)
        }
        // `loadApprovalRowsChecked` validates every row before returning, so
        // compactMap cannot hide a corrupt record as a shorter healthy queue.
        let records = items.compactMap(ApprovalRecord.init(json:))
        let sorted = records.sorted { lhs, rhs in
            // Match Python's: sorted(..., key=lambda x: str(x.createdAt or ""), reverse=True).
            lhs.createdAt > rhs.createdAt
        }
        return sorted.filter { record in
            if let s = filter.status, record.status != s { return false }
            // P2-4: `mission.step` records written before 0.3.8 sit in
            // approvals.jsonl forever and are never rewritten. Match through
            // the vocabulary bridge so an old record answers a new-vocabulary
            // filter and a new record answers an old-vocabulary one.
            if let a = filter.action, !ExecutionEventVocabulary.matches(record.action, a) {
                return false
            }
            return true
        }
    }

    public func get(_ id: String) async throws -> ApprovalRecord {
        let records = try await list(filter: .all)
        guard let match = records.first(where: { $0.id == id }) else {
            throw ApprovalInboxError.notFound(id)
        }
        return match
    }

    @discardableResult
    public func create(_ body: JSONValue) async throws -> ApprovalRecord {
        try await runSerialized { [persistence, approvalsPath, clock] in
            try await Self._createImpl(
                body: body,
                persistence: persistence,
                approvalsPath: approvalsPath,
                now: clock()
            )
        }
    }

    /// Reentrancy-safe mutation gate: each mutating call wraps its work
    /// in a Task and chains the next call behind the prior Task's value.
    /// Because the read→mutate→write happens INSIDE the spawned Task and
    /// the next caller awaits the prior Task before spawning its own,
    /// two concurrent resolve() calls cannot interleave their IO.
    private func runSerialized<T: Sendable>(
        _ body: @Sendable @escaping () async throws -> T
    ) async throws -> T {
        let prior = mutationTail
        let task = Task<T, Error> {
            _ = await prior?.value  // wait for previous mutation to finish
            return try await body()
        }
        // Erase to Void-returning Task for the tail chain.
        mutationTail = Task { _ = try? await task.value }
        return try await task.value
    }

    @discardableResult
    public func resolve(
        _ id: String,
        decision: ApprovalDecision,
        decidedBy: String
    ) async throws -> ApprovalRecord {
        try await runSerialized { [persistence, approvalsPath, clock] in
            _ = decidedBy
            return try await Self._resolveImpl(
                id: id, decision: decision,
                persistence: persistence,
                approvalsPath: approvalsPath,
                now: clock()
            )
        }
    }

    private static func _createImpl(
        body: JSONValue,
        persistence: any PersistenceCoreProtocol,
        approvalsPath: URL,
        now: Date
    ) async throws -> ApprovalRecord {
      return try await persistence.withFileLock(approvalsPath) {
        let bodyObj: [String: JSONValue]
        if case .object(let obj) = body {
            bodyObj = obj
        } else {
            bodyObj = [:]
        }
        let payload: JSONValue
        if case .object = bodyObj["payload"] ?? .null {
            payload = bodyObj["payload"] ?? .object([:])
        } else {
            payload = .object([:])
        }
        // A caller-provided human preview wins — stagers write readable
        // previews like "[GROWTH.md] <lesson>", and unconditionally
        // serializing the payload here made every rich card render raw JSON
        // with \uXXXX escapes in the Approvals panel (User, 2026-07-03).
        // Fallback stays the serialized payload for callers without one.
        let rawPayloadPreview: String
        if case .string(let s)? = bodyObj["payloadPreview"],
           !s.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            rawPayloadPreview = s
        } else {
            rawPayloadPreview = (try? payload.serialize(pretty: false)) ?? ""
        }
        let payloadPreview = String(rawPayloadPreview.prefix(4000))
        let action = codepointPrefix(pyStr(bodyObj["action"], fallback: "unknown"), 120)
        let localOnlyActions: Set<String> = [
            "backup_restore",
            "memory.update",
            "memory.delete",
            "memory.consolidate",
            "memory.proposal.approve",
            "memory.proposal.reject",
            "improvement.promote",
            "improvement.revert",
            // U4 Wave C: a confirm→auto autonomy promotion is a SECURITY
            // loosening; forcing it local-only means a remote/chat surface
            // can never approve one (remoteResolvable=false / localOnly=true).
            "autonomy.promote",
            // U4 Wave D (gpt-5.5 review BLOCKER): a self_evolution.apply approval
            // COMMITS a code change to the live repo (and stages a self-install).
            // It is the single most sensitive approval in the system, so a
            // remote/iCloud/chat surface must NEVER be able to approve one —
            // forcing it local-only here makes MacSyncEngine's remote-resolve
            // guard (Wave C B1) deny it. The wave-2 stager + the wave-D
            // `self_install` chat tool both create this action through here, so
            // the local-only-ness is pinned at the single create chokepoint.
            "self_evolution.apply",
            // Compiled-procedure review and exact production activation are
            // authority changes even though their effects remain low-risk and
            // local. No remote/chat surface can mint either decision.
            SwiftNativeApprovalInbox.procedureReviewApprovalAction,
            SwiftNativeApprovalInbox.procedureExactActivationApprovalAction,
        ]
        // SECURITY (U4 Wave C, gpt-5.5 review): for an action hardcoded as
        // local-only, the local-only-ness is NOT negotiable by the caller — a
        // caller (incl. a remote/chat surface) must not be able to stage e.g.
        // `autonomy.promote` with remoteResolvable=true and thereby make a
        // security loosening remotely approvable. Force the flags; ignore any
        // caller-supplied override for these actions.
        // SECURITY (best-agent sweep R4, finding B2): `remoteResolvable` is an
        // AUTHORITY field — it decides whether a remote/chat/iCloud surface may
        // mint the decision. Two fail-OPEN holes existed here:
        //   1. `pyBool` is Python-truthiness, so the string "false" (any
        //      non-empty string) coerced to TRUE. A malformed caller — or a
        //      JSON round-trip that stringified the flag — silently WIDENED
        //      the approval's authority.
        //   2. A MISSING flag defaulted to `true`, so every caller that simply
        //      forgot the key got remote resolution by accident.
        // Both now fail CLOSED: only a literal JSON `true`/`false` is honored,
        // and anything else (missing, malformed, wrong type) means NOT
        // remotely resolvable unless the action is explicitly declared
        // remote-safe below. The hard-local override above still wins outright.
        let isHardLocalOnly = localOnlyActions.contains(action)
        let declaredRemoteResolvable = Self.strictBool(bodyObj["remoteResolvable"])
        let remoteResolvable: Bool
        if isHardLocalOnly {
            remoteResolvable = false
        } else if let declaredRemoteResolvable {
            remoteResolvable = declaredRemoteResolvable
        } else {
            remoteResolvable = Self.remoteSafeActions.contains(action)
        }
        let localOnly: Bool
        if isHardLocalOnly {
            localOnly = true
        } else if let declared = Self.strictBool(bodyObj["localOnly"]) {
            localOnly = declared
        } else {
            localOnly = !remoteResolvable
        }
        let stamp = isoTimestamp(now)
        let approval = ApprovalRecord(
            id: UUID().uuidString.lowercased(),
            title: codepointPrefix(strip(pyStr(bodyObj["title"], fallback: "Approval required")), 160),
            action: action,
            risk: pyStr(bodyObj["risk"], fallback: "medium"),
            reason: codepointPrefix(strip(pyStr(bodyObj["reason"], fallback: "")), 1000),
            status: "pending",
            payload: payload,
            payloadPreview: payloadPreview,
            createdAt: stamp,
            resolvedAt: nil,
            decision: nil,
            remoteResolvable: remoteResolvable,
            localOnly: localOnly
        )

        var items = try Self.loadApprovalRowsChecked(at: approvalsPath)
        items.insert(approval.toJSON(), at: 0)
        try await persistence.writeJSON(.array(Array(items.prefix(300))), to: approvalsPath)
        return approval
      }
    }

    private static func _resolveImpl(
        id: String,
        decision: ApprovalDecision,
        persistence: any PersistenceCoreProtocol,
        approvalsPath: URL,
        now: Date
    ) async throws -> ApprovalRecord {
      return try await persistence.withFileLock(approvalsPath) {
        let items = try Self.loadApprovalRowsChecked(at: approvalsPath)
        var mutated: [JSONValue] = items
        var resolvedRecord: ApprovalRecord?
        for (idx, item) in items.enumerated() {
            guard case .object(var obj) = item else { continue }
            guard case .string(let recordId) = obj["id"] ?? .null, recordId == id else { continue }
            let currentStatus: String = {
                if case .string(let s) = obj["status"] ?? .null { return s }
                return ""
            }()
            let terminal: Set<String> = ["resolved", "denied", "canceled", "orphaned"]
            if terminal.contains(currentStatus) {
                throw ApprovalInboxError.alreadyResolved(id: id, status: currentStatus)
            }
            // Python writes status="resolved" regardless of decision, and
            // captures decision separately. Mirror that exactly.
            obj["status"] = .string("resolved")
            obj["decision"] = .string(decision.rawValue)
            obj["resolvedAt"] = .string(Self.isoTimestamp(now))
            mutated[idx] = .object(obj)
            guard let rec = ApprovalRecord(json: .object(obj)) else {
                throw ApprovalInboxError.malformedResponse("could not re-parse mutated record")
            }
            resolvedRecord = rec
            break
        }
        guard let final = resolvedRecord else {
            throw ApprovalInboxError.notFound(id)
        }
        try await persistence.writeJSON(.array(mutated), to: approvalsPath)
        return final
      }
    }

    @discardableResult
    public func archive(olderThan cutoff: Date) async throws -> Int {
      return try await persistence.withFileLock(approvalsPath) { [persistence, approvalsPath] in
        let items = try Self.loadApprovalRowsChecked(at: approvalsPath)
        let cutoffISO = Self.isoTimestamp(cutoff)
        let terminal: Set<String> = ["resolved", "denied", "canceled", "orphaned"]
        var kept: [JSONValue] = []
        var dropped = 0
        for item in items {
            guard case .object(let obj) = item else {
                kept.append(item)
                continue
            }
            let status: String = {
                if case .string(let s) = obj["status"] ?? .null { return s }
                return ""
            }()
            if !terminal.contains(status) {
                kept.append(item)
                continue
            }
            let ts: String = {
                if case .string(let s) = obj["resolvedAt"] ?? .null { return s }
                if case .string(let s) = obj["createdAt"] ?? .null { return s }
                return ""
            }()
            // ISO-8601 lexicographic compare works for same-offset zulu/+00:00
            // timestamps. The daemon emits +00:00; cutoff is also +00:00.
            if !ts.isEmpty && ts < cutoffISO {
                dropped += 1
            } else {
                kept.append(item)
            }
        }
        if dropped > 0 {
            try await persistence.writeJSON(.array(kept), to: approvalsPath)
        }
        return dropped
      }
    }

    // MARK: - Helpers

    nonisolated static func parseRecords(_ raw: JSONValue) -> [ApprovalRecord] {
        guard case .array(let items) = raw else { return [] }
        return items.compactMap(ApprovalRecord.init(json:))
    }

    /// Strict authoritative-store read used by every approval read/mutation.
    /// A missing file is the one legitimate empty queue. Once the file exists,
    /// unreadable bytes, malformed JSON, the wrong top-level shape, or even one
    /// malformed row make the whole queue unavailable. In particular, mutation
    /// callers must never turn damaged state into `[]` and overwrite pending
    /// approvals with a newly created record.
    nonisolated private static func loadApprovalRowsChecked(at path: URL) throws -> [JSONValue] {
        let fileManager = FileManager.default
        guard fileManager.fileExists(atPath: path.path) else { return [] }

        let data: Data
        do {
            data = try Data(contentsOf: path)
        } catch {
            throw ApprovalInboxError.unavailable(
                underlying: "approval store unreadable: \(error.localizedDescription)"
            )
        }

        let raw: JSONValue
        do {
            raw = try JSONValue.parse(data)
        } catch {
            throw ApprovalInboxError.malformedResponse(
                "approval store contains malformed JSON: \(error.localizedDescription)"
            )
        }
        guard case .array(let items) = raw else {
            throw ApprovalInboxError.malformedResponse(
                "approval store is not a JSON array"
            )
        }
        for (index, item) in items.enumerated() where ApprovalRecord(json: item) == nil {
            throw ApprovalInboxError.malformedResponse(
                "approval store row \(index) is not a valid approval record"
            )
        }
        return items
    }

    private nonisolated static func strip(_ value: String) -> String {
        value.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private nonisolated static func codepointPrefix(_ value: String, _ n: Int) -> String {
        let scalars = value.unicodeScalars
        if scalars.count <= n { return value }
        return String(String.UnicodeScalarView(scalars.prefix(n)))
    }

    private nonisolated static func pyStr(_ value: JSONValue?, fallback: String) -> String {
        guard let value else { return fallback }
        switch value {
        case .null: return fallback
        case .string(let s): return s
        case .bool(let b): return b ? "True" : "False"
        case .int(let i): return String(i)
        case .double(let d): return String(d)
        case .array, .object: return ""
        }
    }

    /// STRICT JSON bool parse for authority fields. Unlike `pyBool` (Python
    /// truthiness, used for cosmetic/behavioral flags), this returns nil for
    /// ANYTHING that is not a literal JSON `true`/`false` — no string coercion,
    /// no numeric coercion. Callers of authority fields treat nil as
    /// "undeclared" and fall back to the fail-CLOSED default.
    nonisolated static func strictBool(_ value: JSONValue?) -> Bool? {
        guard case .bool(let b)? = value else { return nil }
        return b
    }

    /// Actions declared REMOTE-SAFE: an approval for one of these may be
    /// resolved from a remote surface (iCloud/Telegram/chat) even when the
    /// creating caller did not pass an explicit `remoteResolvable` boolean.
    /// Everything NOT listed here (and not carrying an explicit `true`) fails
    /// closed to local-only. Keep this list minimal and justified — adding an
    /// entry widens who can approve that action.
    ///
    /// Workflow/MCP step gates live here because "the run is parked waiting on
    /// you" is exactly the case a phone approval exists for, and both actions
    /// were remotely resolvable before the fail-closed flip (behavior preserved
    /// deliberately, not by accident).
    nonisolated static let remoteSafeActions: Set<String> = [
        "workflow_step",
        "mcp_tool",
    ]

    private nonisolated static func pyBool(_ value: JSONValue) -> Bool {
        switch value {
        case .null: return false
        case .bool(let b): return b
        case .int(let i): return i != 0
        case .double(let d): return d != 0
        case .string(let s): return !s.isEmpty
        case .array(let arr): return !arr.isEmpty
        case .object(let obj): return !obj.isEmpty
        }
    }

    /// Matches Python's `now_iso()` shape: an ISO-8601 string with
    /// fractional seconds and a `+00:00` offset.
    nonisolated static func isoTimestamp(_ date: Date) -> String {
        let fmt = ISO8601DateFormatter()
        fmt.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        // Stored approval timestamps use "+00:00" rather than "Z". Convert.
        let zulu = fmt.string(from: date)
        if zulu.hasSuffix("Z") {
            return String(zulu.dropLast()) + "+00:00"
        }
        return zulu
    }

    // MARK: - Data root resolution (delegated to PersistenceCore)

    /// Thin delegator to `PersistenceCore.defaultDataRoot()` — the single
    /// source of truth for the Python `_resolve_data_root` priority chain.
    /// Kept on the actor for back-compat with the existing factory + tests.
    public nonisolated static func defaultDataRoot() -> URL {
        PersistenceCore.defaultDataRoot()
    }
}

// MARK: - Factory

/// Always SwiftNative. Callers wanting an in-process or override path should
/// construct `SwiftNativeApprovalInbox` directly.
public func makeApprovalInbox() -> any ApprovalInboxProtocol {
    let root = SwiftNativeApprovalInbox.defaultDataRoot()
    return SwiftNativeApprovalInbox(root: root)
}
