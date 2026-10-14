import Foundation
import Darwin
import PersistenceCore

// MARK: - WorkflowOrchestration — registry half
//
// RETIRED 2026-09-01: User authorized retiring the workflow RUN engine.
//
// Evidence at retirement: data/workflows/runs.jsonl held 42 runs, all frozen
// since 2026-05-08 (17 of them permanently `waiting_approval`);
// workflows/registry.json held 5 records, none of which had ever been
// instantiated by a user; the module's own create/cancel/rollback paths were
// labelled PORTED-DORMANT (default OFF) across 16 markers in 8 files; and
// `getWorkflowRuns()` was polled on every AppModel refresh purely to render a
// list that could not change. The live successor for "do a piece of work" is
// workshop/executions.
//
// What went: runWorkflow / resumeWorkflowRun / cancelWorkflowRun /
// rollbackWorkflowRun / listWorkflowRuns, the v1 and v2 step executors, the
// per-run state machine (workflows/run_state), the run ledger append, the run
// ledger feed family, the run-control preflight, the execution preflight, the
// motor-action projection over runs, and every Mac-UI control that drove them.
//
// What stayed and why:
//   • The workflow REGISTRY (this file's protocol) still backs the Capabilities
//     panel's workflow list. The unused creation path has been removed.
//   • The APPROVALS half is a different module (ApprovalInbox) writing
//     data/workflows/approvals/requests.json. It is LIVE — written today — and
//     was never part of the run engine. Nothing here touches it.
//   • data/workflows/runs.jsonl and run_state/*.json stay on disk as history
//     (User's keep-history rule). Nothing in the app reads them any more.
//
// The list path:
//   1. read workflows/registry.json (default []),
//   2. merge each built-in default with its saved override (saved keys win),
//   3. append saved-only items not present in defaults,
//   4. WRITE BACK the merged (unsorted) list to registry.json when it changed,
//   5. RETURN the merged list sorted by (updatedAt | createdAt | "") DESC.
//
// Registry write-back shares the Swift persistence lock with external writers.

extension SwiftNativeWorkflowOrchestrationClient {
    /// The same list as records, for the Capabilities panel; a malformed row
    /// fails the read.
    public func listWorkflowRecords() async throws -> [WorkflowRecord] {
        try await listWorkflows().map(WorkflowRecord.init(row:))
    }
}

public struct WorkflowStep: Identifiable, Codable, Hashable, Sendable {
    public var id: String
    public var title: String
    public var kind: String?
    public var status: String?
    public var requiresApproval: Bool?
    public var detail: String?
}

public struct WorkflowRecord: Identifiable, Codable, Hashable, Sendable {
    public var id: String
    public var name: String
    public var description: String?
    public var status: String?
    public var trigger: String?
    public var steps: [WorkflowStep]
    public var createdAt: String?
    public var updatedAt: String?
}

extension WorkflowRecord {
    init(row: JSONValue) throws {
        let row = try JSONRow(row)
        self.init(
            id: try row.string("id"), name: try row.string("name"),
            description: try row.optionalString("description"), status: try row.optionalString("status"),
            trigger: try row.optionalString("trigger"),
            steps: try row.array("steps").map(WorkflowStep.init(row:)),
            createdAt: try row.optionalString("createdAt"), updatedAt: try row.optionalString("updatedAt"))
    }
}

extension WorkflowStep {
    init(row: JSONValue) throws {
        let row = try JSONRow(row)
        self.init(
            id: try row.string("id"), title: try row.string("title"), kind: try row.optionalString("kind"),
            status: try row.optionalString("status"), requiresApproval: try row.optionalBool("requiresApproval"),
            detail: try row.optionalString("detail"))
    }
}

// MARK: - SwiftNative impl (registry listing only)

public final class SwiftNativeWorkflowOrchestrationClient: Sendable {
    private let root: URL
    private let persistence: SwiftNativePersistenceCore
    private let now: @Sendable () -> String

    public init(
        root: URL,
        persistence: SwiftNativePersistenceCore = SwiftNativePersistenceCore(),
        now: @escaping @Sendable () -> String = { WorkflowOrchestrationClock.nowISO() }
    ) {
        self.root = root
        self.persistence = persistence
        self.now = now
    }

    private var registryPath: URL { root.appendingPathComponent("workflows/registry.json") }

    /// Only an absent directory entry bootstraps defaults; damaged or unreadable
    /// saved workflows must survive a list attempt, including a dangling symlink.
    private static func readWorkflowRegistry(_ path: URL) throws -> [JSONValue] {
        let data: Data
        do {
            data = try Data(contentsOf: path)
        } catch {
            var metadata = stat()
            if lstat(path.path, &metadata) != 0, errno == ENOENT { return [] }
            throw error
        }
        guard case .array(let rows) = try JSONValue.parse(data) else {
            throw NSError(domain: "WorkflowOrchestration", code: -422, userInfo: [
                NSLocalizedDescriptionKey: "Workflow registry is unavailable: expected a JSON array at \(path.path). Saved bytes were preserved."
            ])
        }
        return rows
    }

    public func listWorkflows() async throws -> [JSONValue] {
        // The entire read -> merge -> write-back shares the registry lock.
        let body: @Sendable () async throws -> [JSONValue] = { [persistence, registryPath, now] in
            let saved = try Self.readWorkflowRegistry(registryPath)
            let defaults = WorkflowDefaults.defaults(now: now())
            let (mergedUnsorted, sorted) = WorkflowMerge.mergeRegistry(defaults: defaults, saved: saved)
            // Persist newly introduced defaults/fields, but an ordinary list
            // read must not fsync identical bytes and wake registry observers.
            let merged = JSONValue.array(mergedUnsorted)
            if merged != .array(saved) {
                try await persistence.writeJSON(merged, to: registryPath)
            }
            return sorted
        }
        return try await persistence.withFileLock(registryPath, body)
    }
}

// MARK: - ISO clock (mirror now_iso)

public enum WorkflowOrchestrationClock {
    /// Mirrors Python's `now_iso()` = `datetime.now(timezone.utc).isoformat()`,
    /// which emits SIX fractional digits (microseconds) and a `+00:00` suffix,
    /// e.g. `2026-06-01T12:34:56.789012+00:00`. ISO8601DateFormatter only gives
    /// millisecond precision, so we build the string with a microsecond
    /// component derived from the Date's sub-second fraction (gpt-5.5 review
    /// finding #2, 2026-06-01).
    public static func nowISO() -> String {
        nowISO(from: Date())
    }

    /// Testable seam: format a specific Date the Python `isoformat()` way.
    public static func nowISO(from date: Date) -> String {
        var cal = Calendar(identifier: .gregorian)
        cal.timeZone = TimeZone(identifier: "UTC")!
        let comps = cal.dateComponents([.year, .month, .day, .hour, .minute, .second], from: date)
        // Microseconds from the fractional second of the timestamp.
        let frac = date.timeIntervalSince1970 - floor(date.timeIntervalSince1970)
        let micros = min(999_999, Int((frac * 1_000_000).rounded(.toNearestOrEven)))
        return String(
            format: "%04d-%02d-%02dT%02d:%02d:%02d.%06d+00:00",
            comps.year ?? 1970, comps.month ?? 1, comps.day ?? 1,
            comps.hour ?? 0, comps.minute ?? 0, comps.second ?? 0,
            micros
        )
    }
}

// MARK: - Saved workflow templates

/// Saved planning templates. The workflow registry does not execute them.
public enum WorkflowDefaults {
    public static func defaults(now: String) -> [JSONValue] {
        func step(_ id: String, _ title: String, _ kind: String, requiresApproval: Bool, layer: String? = nil) -> JSONValue {
            var obj: [String: JSONValue] = [
                "id": .string(id),
                "title": .string(title),
                "kind": .string(kind),
                "requiresApproval": .bool(requiresApproval),
            ]
            if let layer { obj["layer"] = .string(layer) }
            return .object(obj)
        }
        return [
            .object([
                "id": .string("research-to-brief"),
                "name": .string("Research to Brief"),
                "description": .string("Saved template for research, source capture, a memory note, and a summary. Workflow execution is unavailable."),
                "status": .string("template"),
                "trigger": .string("research brief"),
                "steps": .array([
                    step("route", "Plan intent route", "router", requiresApproval: false),
                    step("search", "Search private web connector", "research", requiresApproval: false),
                    step("capture", "Capture source receipts", "receipt", requiresApproval: false),
                    step("brief", "Draft concise brief", "llm", requiresApproval: false),
                ]),
                "createdAt": .string(now),
                "updatedAt": .string(now),
            ]),
            .object([
                "id": .string("safe-tool-forge"),
                "name": .string("Safe Tool Forge"),
                "description": .string("Saved template for proposing and validating an app-owned JSON tool with permission-gated promotion. Workflow execution is unavailable."),
                "status": .string("template"),
                "trigger": .string("make a tool"),
                "steps": .array([
                    step("scope", "Define reusable boundary", "analysis", requiresApproval: false),
                    step("proposal", "Create tool proposal", "tool_proposal", requiresApproval: false),
                    step("validate", "Run safety scan and tests", "validation", requiresApproval: false),
                    step("promote", "Promote only safe app-data tool", "approval", requiresApproval: true),
                ]),
                "createdAt": .string(now),
                "updatedAt": .string(now),
            ]),
            .object([
                "id": .string("memory-capture"),
                "name": .string("Memory Capture"),
                "description": .string("Saved template for capturing an objective as a semantic memory with a trace receipt. Workflow execution is unavailable."),
                "status": .string("template"),
                "trigger": .string("remember this"),
                "steps": .array([
                    step("route", "Route objective", "router", requiresApproval: false),
                    step("memory", "Write semantic memory", "memory", requiresApproval: false, layer: "semantic"),
                    step("trace", "Record trace receipt", "trace", requiresApproval: false),
                ]),
                "createdAt": .string(now),
                "updatedAt": .string(now),
            ]),
        ]
    }

    /// Only migrate original seeds; preserve customized rows and their stamps.
    static func migrateUnchangedSeed(_ saved: JSONValue, to current: JSONValue) -> JSONValue {
        guard case .object(var original) = current,
              case .object(var candidate) = saved else { return saved }
        switch WorkflowMerge.idKey(current) {
        case "research-to-brief":
            original["description"] = .string("Route a research objective through search, source capture, memory note, and summary receipt.")
        case "safe-tool-forge":
            original["description"] = .string("Turn repeated work into a proposed app-owned JSON tool, validate it, and leave promotion gated by permissions.")
        case "memory-capture":
            original["description"] = .string("Execute a safe app-owned workflow that routes an objective, writes a memory, and records a trace receipt.")
            original["status"] = .string("active")
        default:
            return saved
        }
        for key in ["createdAt", "updatedAt"] {
            original.removeValue(forKey: key)
            candidate.removeValue(forKey: key)
        }
        guard candidate == original, case .object(var migrated) = saved,
              case .object(let template) = current else { return saved }
        migrated["description"] = template["description"]
        migrated["status"] = template["status"]
        return .object(migrated)
    }
}

// MARK: - Merge helpers (shared, pure)

public enum WorkflowMerge {
    /// Reads the `id` field of a workflow object as a string (mirrors
    /// `str(item.get("id"))`, so a missing/non-string id becomes "" / "None"-ish).
    /// Python's `str(None)` == "None"; we mirror that for missing ids so two
    /// id-less records collide the same way they would in Python.
    static func idKey(_ value: JSONValue) -> String {
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

    /// Sort key: `str(updatedAt or createdAt or "")`. Empty string sorts last
    /// in DESC order. Mirrors Python `key=lambda item: str(item.get("updatedAt")
    /// or item.get("createdAt") or "")` — including Python's `or` truthiness
    /// across non-string scalars (a truthy numeric/bool timestamp sorts under
    /// its `str(...)` form, not "").
    static func sortKey(_ value: JSONValue) -> String {
        RegistryTimestampSortKey.sortKey(value)
    }

    /// dict.update merge: overlay `override` keys onto a copy of `base`.
    static func merge(base: JSONValue, override: JSONValue) -> JSONValue {
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
            let override = byId[idKey(def)].map {
                WorkflowDefaults.migrateUnchangedSeed($0, to: def)
            } ?? .object([:])
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
