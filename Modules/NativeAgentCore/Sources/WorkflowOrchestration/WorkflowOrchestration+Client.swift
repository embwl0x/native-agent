import Foundation
import Darwin
import PersistenceCore

// MARK: - SwiftNative impl (registry half only)
//
// 2026-09-01: User authorized retiring the workflow run engine. Everything that
// created, advanced, paused, cancelled, rolled back, or listed a *run* is gone
// (see WorkflowOrchestration.swift for the retirement note). What remains is
// the workflow REGISTRY: list + create, which is what the Capabilities panel
// actually reads.

public final class SwiftNativeWorkflowOrchestrationClient: WorkflowOrchestrationClient {
    private let root: URL
    private let persistence: SwiftNativePersistenceCore
    private let now: @Sendable () -> String
    private let uuid: @Sendable () -> String
    private let useFileLock: Bool

    /// - Parameters:
    ///   - root: the native data root (the dir that contains `workflows/`).
    ///   - now: ISO timestamp factory for default stamps (injectable for tests).
    ///   - uuid: random-id factory for create_workflow's slugify empty-fallback
    ///     and per-step id fallback (injectable for tests).
    ///   - useFileLock: when true, the registry write-back is wrapped in a
    ///     cross-process flock.
    public init(
        root: URL,
        persistence: SwiftNativePersistenceCore = SwiftNativePersistenceCore(),
        now: @escaping @Sendable () -> String = { WorkflowOrchestrationClock.nowISO() },
        uuid: @escaping @Sendable () -> String = { UUID().uuidString.lowercased() },
        useFileLock: Bool = true
    ) {
        self.root = root
        self.persistence = persistence
        self.now = now
        self.uuid = uuid
        self.useFileLock = useFileLock
    }

    private var registryPath: URL { root.appendingPathComponent("workflows/registry.json") }
    private var tracesPath: URL { root.appendingPathComponent("traces/events.jsonl") }
    private var activityPath: URL { root.appendingPathComponent("activity/events.jsonl") }

    /// traces/events.jsonl is co-written by several Swift emitters; O_APPEND
    /// atomicity alone is NOT enough (payloads can exceed PIPE_BUF, and it does
    /// not serialize against a read-modify-replace prune), so this writer takes
    /// the shared path lock like DispatchLedger.append /
    /// Research.appendResearchTrace / SwiftNativeCatalogWrites.emitCatalogTrace.
    private func appendTrace(kind: String, title: String, payload: [String: JSONValue]) async throws {
        // str(payload.get("status") or "ok"): falsey ("" / missing / null) -> "ok".
        let status: String
        switch payload["status"] {
        case .some(.string(let s)) where !s.isEmpty: status = s
        case .some(.bool(let b)) where b: status = "True"
        case .some(.int(let i)) where i != 0: status = String(i)
        case .some(.double(let d)) where d != 0: status = String(d)
        default: status = "ok"
        }
        let event: JSONValue = .object([
            "id": .string(UUID().uuidString),
            "kind": .string(kind),
            "title": .string(title),
            "status": .string(status),
            "payload": .object(payload),
            "createdAt": .string(now()),
        ])
        let tracesURL = tracesPath
        try await appendPathOwnedJSONL(
            event,
            to: tracesURL,
            using: persistence,
            logLabel: "WorkflowOrchestration.trace"
        )
    }

    /// Envelope = {id, kind, title, detail, status, executionId, payload, createdAt}.
    /// title/detail/payload are redacted. The append is flock-wrapped because
    /// activity/events.jsonl is co-written by every Swift activity emitter
    /// (mirrors Research.recordActivity). A write failure propagates.
    private func appendActivity(kind: String, title: String, detail: String, status: String, payload: [String: JSONValue]) async throws {
        let event: JSONValue = .object([
            "id": .string(UUID().uuidString),
            "kind": .string(kind),
            "title": .string(WorkflowRedaction.redactText(title)),
            "detail": .string(WorkflowRedaction.redactText(detail)),
            "status": .string(status),
            "executionId": .null,
            "payload": WorkflowRedaction.redactValue(.object(payload)),
            "createdAt": .string(now()),
        ])
        let activityURL = activityPath
        try await persistence.withFileLock(activityURL) {
            try await appendJSONLCapped(
                event,
                to: activityURL,
                using: persistence,
                maxLines: JSONLLineCaps.activityEvents,
                logLabel: "WorkflowOrchestration.activity",
                takeLock: false
            )
        }
    }

    /// Called inside the existing registry lock. Only an absent directory entry
    /// bootstraps defaults; damaged or unreadable saved workflows must survive
    /// a list/create attempt, including a dangling symlink at the saved path.
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
        // The ENTIRE read -> merge -> write-back must be atomic under the
        // cross-process lock, otherwise a concurrent writer that commits between
        // our read and our locked write would be silently clobbered by our
        // stale-data write-back.
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
        if useFileLock {
            return try await persistence.withFileLock(registryPath, body)
        }
        return try await body()
    }

    public func createWorkflow(_ body: JSONValue) async throws -> JSONValue {
        // 1. Build the record (pure). ONE timestamp is stamped at the top and
        //    used for createdAt/updatedAt.
        let stampNow = now()
        let uuidFactory = uuid
        let built = try WorkflowCreate.buildRecord(body: body, now: stampNow, uuid: { uuidFactory() })
        let workflowId = built.id
        let workflow = built.record
        let stepCount = built.stepCount

        // 2. Persist into the registry: compute the defaults merge, then
        //    filter+append and persist the final registry ONCE, all inside ONE
        //    flock acquisition. We call the lock-free merge here (NOT
        //    listWorkflows, which would re-acquire the SAME <path>.lock and
        //    deadlock — flock(2) is not recursive across fds).
        let regPath = registryPath
        let nowFn = now
        let body2: @Sendable () async throws -> Void = { [persistence] in
            // workflow_defaults() takes a FRESH timestamp each call (not
            // create's stampNow), so the default rows written back carry their
            // own timestamp.
            let saved = try Self.readWorkflowRegistry(regPath)
            let defaults = WorkflowDefaults.defaults(now: nowFn())
            let (_, mergedSorted) = WorkflowMerge.mergeRegistry(defaults: defaults, saved: saved)
            // Filter the SORTED merge return and append the new workflow, so
            // the final on-disk order = sorted(minus same-id) + new-at-end —
            // NOT the unsorted merge order.
            let kept = mergedSorted.filter { WorkflowMerge.idKey($0) != workflowId }
            let finalList = kept + [workflow]
            try await persistence.writeJSON(.array(finalList), to: regPath)
        }
        if useFileLock {
            try await persistence.withFileLock(regPath, body2)
        } else {
            try await body2()
        }

        // 3. Side-effects (outside the registry lock — different files).
        let name = WorkflowCreate.pyStr(WorkflowCreate.objField(workflow, "name"))
        try await appendActivity(
            kind: "workflow",
            title: "Workflow saved",
            detail: name,
            status: "ok",
            payload: ["workflowId": .string(workflowId)]
        )
        // Oversized definitions refuse before persistence, so a save trace
        // always describes bytes that actually landed.
        try await appendTrace(
            kind: "workflow.save",
            title: name,
            payload: ["workflowId": .string(workflowId), "stepCount": .int(Int64(stepCount))]
        )
        return workflow
    }
}
