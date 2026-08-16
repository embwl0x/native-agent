import Testing
import Foundation
@testable import WorkflowOrchestration
import ApprovalInbox
import NativeAgentCore
import PersistenceCore
import ToolExecution

// MARK: - Helpers

private func tempRoot() -> URL {
    let dir = FileManager.default.temporaryDirectory
        .appendingPathComponent("wf-orch-test-\(UUID().uuidString)")
    try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    return dir
}

private func idOf(_ v: JSONValue) -> String? {
    if case .object(let o) = v, case .string(let s)? = o["id"] { return s }
    return nil
}

private func stringField(_ v: JSONValue, _ key: String) -> String? {
    if case .object(let o) = v, case .string(let s)? = o[key] { return s }
    return nil
}

private func writeRegistry(_ root: URL, _ items: [JSONValue]) throws {
    let dir = root.appendingPathComponent("workflows")
    try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    let data = try JSONValue.array(items).serializedData(pretty: true)
    try data.write(to: dir.appendingPathComponent("registry.json"))
}

private func appendRun(_ root: URL, _ run: JSONValue) throws {
    let dir = root.appendingPathComponent("workflows")
    try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    let path = dir.appendingPathComponent("runs.jsonl")
    var line = try run.serialize(pretty: false)
    line += "\n"
    let bytes = Data(line.utf8)
    if FileManager.default.fileExists(atPath: path.path) {
        let h = try FileHandle(forWritingTo: path)
        try h.seekToEnd()
        h.write(bytes)
        try h.close()
    } else {
        try bytes.write(to: path)
    }
}

private func seedWorkflowTool(root: URL, id: String) throws {
    let activeDir = root
        .appendingPathComponent("tools", isDirectory: true)
        .appendingPathComponent("active", isDirectory: true)
        .appendingPathComponent(id, isDirectory: true)
    try FileManager.default.createDirectory(at: activeDir, withIntermediateDirectories: true)
    let manifest: JSONValue = .object([
        "id": .string(id),
        "name": .string(id),
        "entrypoint": .string("tool.swift"),
        "timeoutSeconds": .int(10),
    ])
    try manifest.serializedData(pretty: true).write(to: activeDir.appendingPathComponent("manifest.json"))
    let body = """
    import Foundation
    let raw = String(data: FileHandle.standardInput.readDataToEndOfFile(), encoding: .utf8) ?? "{}"
    print("{\\"ok\\":true,\\"result\\":{\\"received\\":\\(raw)}}")
    """
    try Data(body.utf8).write(to: activeDir.appendingPathComponent("tool.swift"))
    try Data("[{\"name\":\"smoke\",\"input\":{}}]".utf8).write(to: activeDir.appendingPathComponent("tests.json"))
    let fingerprint = computeToolCodeFingerprint(toolRoot: activeDir, entrypointName: "tool.swift")
    let registryPath = root
        .appendingPathComponent("tools", isDirectory: true)
        .appendingPathComponent("registry.json")
    let record: JSONValue = .object([
        "id": .string(id),
        "name": .string(id),
        "status": .string("active"),
        "createdAt": .string("2026-06-03T00:00:00+00:00"),
        "updatedAt": .string("2026-06-03T00:00:00+00:00"),
        "activePath": .string(activeDir.path),
        "codeFingerprint": .string(fingerprint),
    ])
    try JSONValue.array([record]).serializedData(pretty: true).write(to: registryPath)
}

private final class WorkflowRaceResolutionRecorder: @unchecked Sendable {
    private let lock = NSLock()
    private var resolvedAt: UInt64?
    private var activeWorkersAtResolution: Int?

    func record(_ value: UInt64, activeWorkers: Int? = nil) {
        lock.lock()
        if resolvedAt == nil {
            resolvedAt = value
            activeWorkersAtResolution = activeWorkers
        }
        lock.unlock()
    }

    func value() -> UInt64? {
        lock.lock()
        defer { lock.unlock() }
        return resolvedAt
    }

    func activeWorkers() -> Int? {
        lock.lock()
        defer { lock.unlock() }
        return activeWorkersAtResolution
    }
}

private final class WorkflowCancellationReadCounter: @unchecked Sendable {
    private let lock = NSLock()
    private var count = 0

    func record() {
        lock.lock()
        count += 1
        lock.unlock()
    }

    func value() -> Int {
        lock.lock()
        defer { lock.unlock() }
        return count
    }
}

private final class WorkflowPoolSaturationProbe: @unchecked Sendable {
    private let lock = NSLock()
    private var active = 0

    func run(until deadlineNanos: UInt64) {
        lock.lock()
        active += 1
        lock.unlock()
        defer {
            lock.lock()
            active -= 1
            lock.unlock()
        }
        var churn: UInt64 = 0
        while DispatchTime.now().uptimeNanoseconds < deadlineNanos {
            churn &+= 1
        }
        withExtendedLifetime(churn) {}
    }

    func activeCount() -> Int {
        lock.lock()
        defer { lock.unlock() }
        return active
    }
}

private final class WorkflowUncooperativeAttemptProbe: @unchecked Sendable {
    private let lock = NSLock()
    private var dispatches = 0
    private var active = 0
    private var released = false
    private var waiters: [CheckedContinuation<Void, Never>] = []

    func run() async {
        let shouldWait = lock.withLock {
            dispatches += 1
            active += 1
            return dispatches == 1
        }

        if shouldWait {
            await withCheckedContinuation { continuation in
                let resumeImmediately = lock.withLock {
                    if released { return true }
                    waiters.append(continuation)
                    return false
                }
                if resumeImmediately { continuation.resume() }
            }
        }

        lock.withLock { active -= 1 }
    }

    func releaseAll() {
        let pending = lock.withLock {
            released = true
            let pending = waiters
            waiters.removeAll()
            return pending
        }
        for waiter in pending { waiter.resume() }
    }

    func snapshot() -> (dispatches: Int, active: Int) {
        lock.withLock { (dispatches, active) }
    }
}

// MARK: - Defaults

@Test func defaultsHaveExactlyThreeBuiltins() {
    let defs = WorkflowDefaults.defaults(now: "2026-06-01T00:00:00+00:00")
    #expect(defs.count == 3)
    let ids = defs.compactMap { idOf($0) }
    #expect(ids == ["research-to-brief", "safe-tool-forge", "memory-capture"])
    // memory-capture is the only "active" default; the others are templates.
    #expect(stringField(defs[0], "status") == "template")
    #expect(stringField(defs[1], "status") == "template")
    #expect(stringField(defs[2], "status") == "active")
}

// MARK: - Empty registry -> just defaults (sorted)

@Test func listWorkflowsEmptyRegistryReturnsDefaults() async throws {
    let root = tempRoot()
    let client = SwiftNativeWorkflowOrchestrationClient(
        root: root,
        now: { "2026-06-01T00:00:00+00:00" },
        useFileLock: false
    )
    let result = try await client.listWorkflows()
    #expect(result.count == 3)
    // All three share the same timestamp, so stable sort preserves defaults
    // order (research-to-brief, safe-tool-forge, memory-capture).
    #expect(result.compactMap { idOf($0) } == ["research-to-brief", "safe-tool-forge", "memory-capture"])

    // Write-back persisted the merged list.
    let onDisk = try Data(contentsOf: root.appendingPathComponent("workflows/registry.json"))
    guard case .array(let arr) = try JSONValue.parse(onDisk) else {
        Issue.record("registry.json is not a JSON array")
        return
    }
    #expect(arr.count == 3)
}

// MARK: - Saved override wins over default keys

@Test func savedOverrideWinsOverDefault() async throws {
    let root = tempRoot()
    // Override the "memory-capture" default's status + add a custom field.
    try writeRegistry(root, [
        .object([
            "id": .string("memory-capture"),
            "status": .string("disabled"),
            "name": .string("Custom Memory Capture"),
            "updatedAt": .string("2026-05-01T00:00:00+00:00"),
        ]),
    ])
    let client = SwiftNativeWorkflowOrchestrationClient(
        root: root,
        now: { "2026-06-01T00:00:00+00:00" },
        useFileLock: false
    )
    let result = try await client.listWorkflows()
    #expect(result.count == 3)
    let mem = result.first { idOf($0) == "memory-capture" }
    #expect(mem != nil)
    // Override keys win.
    #expect(stringField(mem!, "status") == "disabled")
    #expect(stringField(mem!, "name") == "Custom Memory Capture")
    // Default keys NOT in the override survive (e.g. trigger).
    #expect(stringField(mem!, "trigger") == "remember this")
    // Default still has steps from the built-in.
    if case .object(let o) = mem!, case .array(let steps)? = o["steps"] {
        #expect(steps.count == 3)
    } else {
        Issue.record("memory-capture lost its steps after merge")
    }
}

// MARK: - Saved-only item appended

@Test func savedOnlyItemAppendedAndSorted() async throws {
    let root = tempRoot()
    // A saved-only workflow with a newer updatedAt than the defaults; it must
    // sort to the FRONT (DESC), since defaults use "2026-06-01..." and this is
    // "2026-12-01...".
    try writeRegistry(root, [
        .object([
            "id": .string("custom-flow"),
            "name": .string("Custom Flow"),
            "status": .string("active"),
            "updatedAt": .string("2026-12-01T00:00:00+00:00"),
        ]),
    ])
    let client = SwiftNativeWorkflowOrchestrationClient(
        root: root,
        now: { "2026-06-01T00:00:00+00:00" },
        useFileLock: false
    )
    let result = try await client.listWorkflows()
    #expect(result.count == 4)
    #expect(idOf(result.first!) == "custom-flow")  // newest sorts first
    // The three defaults follow in their original order (same timestamp).
    #expect(result.dropFirst().compactMap { idOf($0) } == ["research-to-brief", "safe-tool-forge", "memory-capture"])
}

// MARK: - Older saved-only item sorts after defaults

@Test func olderSavedItemSortsAfterDefaults() async throws {
    let root = tempRoot()
    try writeRegistry(root, [
        .object([
            "id": .string("ancient-flow"),
            "name": .string("Ancient Flow"),
            "createdAt": .string("2025-01-01T00:00:00+00:00"),
        ]),
    ])
    let client = SwiftNativeWorkflowOrchestrationClient(
        root: root,
        now: { "2026-06-01T00:00:00+00:00" },
        useFileLock: false
    )
    let result = try await client.listWorkflows()
    #expect(result.count == 4)
    #expect(idOf(result.last!) == "ancient-flow")  // oldest sorts last
}

// MARK: - Item with no timestamp sorts last (empty key)

@Test func itemWithNoTimestampSortsLast() async throws {
    let root = tempRoot()
    try writeRegistry(root, [
        .object([
            "id": .string("no-ts-flow"),
            "name": .string("No Timestamp Flow"),
        ]),
    ])
    let client = SwiftNativeWorkflowOrchestrationClient(
        root: root,
        now: { "2026-06-01T00:00:00+00:00" },
        useFileLock: false
    )
    let result = try await client.listWorkflows()
    #expect(result.count == 4)
    // Empty sort key ("") < any non-empty timestamp in DESC order -> last.
    #expect(idOf(result.last!) == "no-ts-flow")
}

// MARK: - Runs tail + reverse

@Test func listWorkflowRunsReturnsNewestFirst() async throws {
    let root = tempRoot()
    // Append 3 runs in chronological order; expect reverse (newest first).
    try appendRun(root, .object(["id": .string("run-1"), "status": .string("succeeded")]))
    try appendRun(root, .object(["id": .string("run-2"), "status": .string("succeeded")]))
    try appendRun(root, .object(["id": .string("run-3"), "status": .string("failed")]))
    let client = SwiftNativeWorkflowOrchestrationClient(
        root: root,
        now: { "2026-06-01T00:00:00+00:00" },
        useFileLock: false
    )
    let runs = try await client.listWorkflowRuns()
    #expect(runs.count == 3)
    #expect(idOf(runs[0]) == "run-3")
    #expect(idOf(runs[1]) == "run-2")
    #expect(idOf(runs[2]) == "run-1")
}

@Test func listWorkflowRunsEmptyWhenNoFile() async throws {
    let root = tempRoot()
    let client = SwiftNativeWorkflowOrchestrationClient(
        root: root,
        now: { "2026-06-01T00:00:00+00:00" },
        useFileLock: false
    )
    let runs = try await client.listWorkflowRuns()
    #expect(runs.isEmpty)
}

@Test func listWorkflowRunsCapsAtFifty() async throws {
    let root = tempRoot()
    for i in 1...60 {
        try appendRun(root, .object(["id": .string("run-\(i)"), "status": .string("succeeded")]))
    }
    let client = SwiftNativeWorkflowOrchestrationClient(
        root: root,
        now: { "2026-06-01T00:00:00+00:00" },
        useFileLock: false
    )
    let runs = try await client.listWorkflowRuns()
    // tail_jsonl(50) keeps the last 50 physical lines (run-11..run-60),
    // reversed -> run-60 first, run-11 last.
    #expect(runs.count == 50)
    #expect(idOf(runs.first!) == "run-60")
    #expect(idOf(runs.last!) == "run-11")
}

// MARK: - Factory gate

@Test func factoryReturnsSwiftNative() {
    let client = makeWorkflowOrchestrationClient(root: tempRoot())
    #expect(client is SwiftNativeWorkflowOrchestrationClient)
}

@Test func workflowFactoryConfinesMemoryOwnerToInjectedRoot() async throws {
    let root = tempRoot().standardizedFileURL
    let client = try #require(
        makeWorkflowOrchestrationClient(root: root) as? SwiftNativeWorkflowOrchestrationClient
    )

    #expect(await client._testMemoryStoragePath() == root
        .appendingPathComponent("memory", isDirectory: true)
        .appendingPathComponent("memory.sqlite"))
}

// MARK: - Sort-key retired truthiness (gpt-5.5 review #3)

@Test func sortKeyUsesCreatedAtWhenUpdatedAtFalsey() {
    // updatedAt present but empty string (falsey) -> fall through to createdAt.
    let v = JSONValue.object([
        "id": .string("x"),
        "updatedAt": .string(""),
        "createdAt": .string("2026-01-01T00:00:00+00:00"),
    ])
    #expect(WorkflowMerge.sortKey(v) == "2026-01-01T00:00:00+00:00")
}

@Test func sortKeyStringifiesTruthyNumericTimestamp() {
    // A truthy non-string updatedAt is str()'d, mirroring Python.
    let v = JSONValue.object(["id": .string("x"), "updatedAt": .int(123)])
    #expect(WorkflowMerge.sortKey(v) == "123")
}

@Test func sortKeyEmptyWhenBothFalsey() {
    let v = JSONValue.object(["id": .string("x"), "updatedAt": .null, "createdAt": .string("")])
    #expect(WorkflowMerge.sortKey(v) == "")
}

// MARK: - nowISO microsecond format (gpt-5.5 review #2)

@Test func nowISOEmitsMicrosecondsAndUTCOffset() {
    // 2026-06-01T12:00:00.123456 UTC.
    var comps = DateComponents()
    comps.year = 2026; comps.month = 6; comps.day = 1
    comps.hour = 12; comps.minute = 0; comps.second = 0
    comps.timeZone = TimeZone(identifier: "UTC")
    var cal = Calendar(identifier: .gregorian)
    cal.timeZone = TimeZone(identifier: "UTC")!
    let base = cal.date(from: comps)!
    let date = base.addingTimeInterval(0.123456)
    let s = WorkflowOrchestrationClock.nowISO(from: date)
    #expect(s.hasPrefix("2026-06-01T12:00:00."))
    #expect(s.hasSuffix("+00:00"))
    // Exactly six fractional digits between '.' and '+'.
    if let dot = s.firstIndex(of: "."), let plus = s.lastIndex(of: "+") {
        let frac = s[s.index(after: dot)..<plus]
        #expect(frac.count == 6)
    } else {
        Issue.record("nowISO missing fractional or offset section: \(s)")
    }
}

// MARK: - File-lock path smoke (write-back still succeeds with lock on)

@Test func listWorkflowsWithFileLockWritesBack() async throws {
    let root = tempRoot()
    let client = SwiftNativeWorkflowOrchestrationClient(
        root: root,
        now: { "2026-06-01T00:00:00+00:00" },
        useFileLock: true
    )
    let result = try await client.listWorkflows()
    #expect(result.count == 3)
    #expect(FileManager.default.fileExists(atPath: root.appendingPathComponent("workflows/registry.json").path))
}

// MARK: - cancel / rollback helpers

/// Writes a per-run state file at the SAME slugified path the impl reads from.
private func writeRunState(_ root: URL, runId: String, _ state: JSONValue) throws {
    let dir = root.appendingPathComponent("workflows/run_state")
    try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    let path = dir.appendingPathComponent("\(WorkflowRunState.slugify(runId)).json")
    let data = try state.serializedData(pretty: true)
    try data.write(to: path)
}

private func arrayField(_ v: JSONValue, _ key: String) -> [JSONValue]? {
    if case .object(let o) = v, case .array(let a)? = o[key] { return a }
    return nil
}

/// Reads the first JSONL record from a traces/events.jsonl file.
private func firstTrace(_ root: URL) throws -> JSONValue {
    let path = root.appendingPathComponent("traces/events.jsonl")
    let text = try String(contentsOf: path, encoding: .utf8)
    guard let firstLine = text.split(separator: "\n").first else {
        Issue.record("traces/events.jsonl is empty")
        return .null
    }
    return try JSONValue.parse(Data(firstLine.utf8))
}

// MARK: - slugify mirror

@Test func slugifyMirrorsPython() {
    // lowercase + non-alnum runs collapse to single dash + strip leading/trailing.
    #expect(WorkflowRunState.slugify("Run ID 42!!") == "run-id-42")
    #expect(WorkflowRunState.slugify("--Edge__Case--") == "edge-case")
    // A UUID-style id keeps its hyphens (already lowercase alnum + dashes).
    #expect(WorkflowRunState.slugify("a1b2c3d4-e5f6-7890-abcd-ef0123456789")
            == "a1b2c3d4-e5f6-7890-abcd-ef0123456789")
    // [:80] cap.
    let long = String(repeating: "a", count: 100)
    #expect(WorkflowRunState.slugify(long).count == 80)
}

// MARK: - cancel

@Test func cancelMarksStateCanceledAndReturnsPublicRun() async throws {
    let root = tempRoot()
    try writeRunState(root, runId: "run-cancel-1", .object([
        "id": .string("run-cancel-1"),
        "workflowId": .string("wf-1"),
        "workflowName": .string("My Flow"),
        "objective": .string("do the thing"),
        "status": .string("waiting_approval"),
        "engineVersion": .string("2"),
        "steps": .array([.object(["id": .string("s1"), "status": .string("succeeded")])]),
        "createdAt": .string("2026-05-01T00:00:00+00:00"),
        "approvalId": .string("appr-1"),
        "currentStepIndex": .int(0),
    ]))
    let client = SwiftNativeWorkflowOrchestrationClient(
        root: root, now: { "2026-06-01T12:00:00.000000+00:00" }, useFileLock: false
    )
    let run = try await client.cancelWorkflowRun(id: "run-cancel-1")
    #expect(stringField(run, "status") == "canceled")
    #expect(stringField(run, "mode") == "execute")
    #expect(stringField(run, "id") == "run-cancel-1")
    #expect(stringField(run, "workflowId") == "wf-1")
    #expect(stringField(run, "completedAt") == "2026-06-01T12:00:00.000000+00:00")
    // public_run carries the steps through.
    #expect(arrayField(run, "steps")?.count == 1)

    // State file on disk is now canceled with completedAt/updatedAt stamped.
    let onDisk = try JSONValue.parse(try Data(contentsOf:
        root.appendingPathComponent("workflows/run_state/run-cancel-1.json")))
    #expect(stringField(onDisk, "status") == "canceled")
    #expect(stringField(onDisk, "completedAt") == "2026-06-01T12:00:00.000000+00:00")
    #expect(stringField(onDisk, "updatedAt") == "2026-06-01T12:00:00.000000+00:00")

    // A trace event was appended. Top-level event status matches the retired
    // str(payload.get("status") or "ok") -> "canceled" (NOT "ok").
    let traces = try firstTrace(root)
    #expect(stringField(traces, "kind") == "workflow.v2.cancel")
    #expect(stringField(traces, "title") == "My Flow")
    #expect(stringField(traces, "status") == "canceled")
}

@Test func cancelUnknownRunThrows() async throws {
    let root = tempRoot()
    let client = SwiftNativeWorkflowOrchestrationClient(
        root: root, now: { "2026-06-01T00:00:00+00:00" }, useFileLock: false
    )
    await #expect(throws: WorkflowOrchestrationError.self) {
        _ = try await client.cancelWorkflowRun(id: "does-not-exist")
    }
}

// MARK: - rollback

@Test func rollbackBuildsCompensationReceiptsForSucceededStepsOnly() async throws {
    let root = tempRoot()
    try writeRunState(root, runId: "run-rb-1", .object([
        "id": .string("run-rb-1"),
        "workflowId": .string("wf-2"),
        "workflowName": .string("Rollback Flow"),
        "status": .string("succeeded"),
        "engineVersion": .string("2"),
        "steps": .array([
            .object(["id": .string("a"), "status": .string("succeeded")]),
            .object(["id": .string("b"), "status": .string("failed")]),
            .object(["id": .string("c"), "status": .string("succeeded")]),
        ]),
        "createdAt": .string("2026-05-01T00:00:00+00:00"),
    ]))
    let client = SwiftNativeWorkflowOrchestrationClient(
        root: root, now: { "2026-06-01T12:00:00.000000+00:00" }, useFileLock: false
    )
    let run = try await client.rollbackWorkflowRun(id: "run-rb-1")
    #expect(stringField(run, "status") == "rolled_back")
    // Only the two succeeded steps get compensation receipts, in REVERSED order
    // (c before a, since Python iterates reversed(steps)).
    let receipts = arrayField(run, "rollbackReceipts")
    #expect(receipts?.count == 2)
    #expect(stringField(receipts![0], "id") == "rollback:c")
    #expect(stringField(receipts![0], "stepId") == "c")
    #expect(stringField(receipts![0], "status") == "rolled_back")
    #expect(stringField(receipts![1], "id") == "rollback:a")

    // State file persisted with rolled_back + the receipts.
    let onDisk = try JSONValue.parse(try Data(contentsOf:
        root.appendingPathComponent("workflows/run_state/run-rb-1.json")))
    #expect(stringField(onDisk, "status") == "rolled_back")
    #expect(arrayField(onDisk, "rollbackReceipts")?.count == 2)

    // Trace event carries rollbackCount == 2 and top-level status "rolled_back".
    let traces = try firstTrace(root)
    #expect(stringField(traces, "kind") == "workflow.v2.rollback")
    #expect(stringField(traces, "status") == "rolled_back")
    if case .object(let o) = traces, case .object(let p)? = o["payload"] {
        #expect(p["rollbackCount"] == JSONValue.int(2))
    } else {
        Issue.record("rollback trace missing payload.rollbackCount")
    }
}

@Test func rollbackWithNoSucceededStepsYieldsEmptyReceipts() async throws {
    let root = tempRoot()
    try writeRunState(root, runId: "run-rb-empty", .object([
        "id": .string("run-rb-empty"),
        "workflowId": .string("wf-3"),
        "status": .string("failed"),
        "steps": .array([.object(["id": .string("x"), "status": .string("failed")])]),
    ]))
    let client = SwiftNativeWorkflowOrchestrationClient(
        root: root, now: { "2026-06-01T12:00:00.000000+00:00" }, useFileLock: false
    )
    let run = try await client.rollbackWorkflowRun(id: "run-rb-empty")
    #expect(stringField(run, "status") == "rolled_back")
    #expect(arrayField(run, "rollbackReceipts")?.isEmpty == true)
}

// MARK: - publicRun engineVersion fallback

@Test func publicRunEngineVersionFallsBackToTwo() {
    // Missing engineVersion -> "2".
    let v = WorkflowRunState.publicRun(.object(["id": .string("r"), "status": .string("canceled")]))
    #expect(stringField(v, "engineVersion") == "2")
    // Empty-string engineVersion (falsey) -> "2".
    let v2 = WorkflowRunState.publicRun(.object(["id": .string("r"), "engineVersion": .string("")]))
    #expect(stringField(v2, "engineVersion") == "2")
    // Present non-empty -> preserved.
    let v3 = WorkflowRunState.publicRun(.object(["id": .string("r"), "engineVersion": .string("1")]))
    #expect(stringField(v3, "engineVersion") == "1")
}

// MARK: - create (wave 34 W11)

/// Reads the first JSONL record from activity/events.jsonl.
private func firstActivity(_ root: URL) throws -> JSONValue {
    let path = root.appendingPathComponent("activity/events.jsonl")
    let text = try String(contentsOf: path, encoding: .utf8)
    guard let firstLine = text.split(separator: "\n").first else {
        Issue.record("activity/events.jsonl is empty")
        return .null
    }
    return try JSONValue.parse(Data(firstLine.utf8))
}

private func readRegistry(_ root: URL) throws -> [JSONValue] {
    let path = root.appendingPathComponent("workflows/registry.json")
    let data = try Data(contentsOf: path)
    if case .array(let a) = try JSONValue.parse(data) { return a }
    return []
}

private func intField(_ v: JSONValue, _ key: String) -> Int64? {
    if case .object(let o) = v, case .int(let i)? = o[key] { return i }
    return nil
}

private func boolField(_ v: JSONValue, _ key: String) -> Bool? {
    if case .object(let o) = v, case .bool(let b)? = o[key] { return b }
    return nil
}

private func makeIDFactory(_ ids: [String]) -> @Sendable () -> String {
    final class Box: @unchecked Sendable {
        var values: [String]
        var index = 0
        init(_ values: [String]) { self.values = values }
        func next() -> String {
            if index < values.count {
                let value = values[index]
                index += 1
                return value
            }
            index += 1
            return "generated-\(index)"
        }
    }
    let box = Box(ids)
    return { box.next() }
}

@Test func buildRecordDefaultsForEmptyBody() throws {
    let (id, rec, stepCount) = try WorkflowCreate.buildRecord(
        body: .object([:]), now: "2026-06-02T00:00:00.000000+00:00", uuid: { "fixed-uuid" }
    )
    #expect(stepCount == 1)  // empty-default single "plan" step
    // name -> "Untitled workflow"; id = slugify(name).
    #expect(stringField(rec, "name") == "Untitled workflow")
    #expect(id == "untitled-workflow")
    #expect(stringField(rec, "status") == "active")
    #expect(stringField(rec, "engineVersion") == "2")
    #expect(stringField(rec, "description") == "")
    #expect(stringField(rec, "trigger") == "")
    // Empty steps -> single "plan" router step default.
    let steps = arrayField(rec, "steps")
    #expect(steps?.count == 1)
    #expect(stringField(steps![0], "id") == "plan")
    #expect(stringField(steps![0], "kind") == "router")
    #expect(boolField(steps![0], "requiresApproval") == false)
    #expect(stringField(rec, "createdAt") == "2026-06-02T00:00:00.000000+00:00")
    #expect(stringField(rec, "updatedAt") == "2026-06-02T00:00:00.000000+00:00")
}

@Test func buildRecordExplicitIdAndStepNormalization() throws {
    let body: JSONValue = .object([
        "name": .string("  My Flow!  "),
        "id": .string("Custom ID 7"),
        "description": .string("  desc  "),
        "trigger": .string("  go  "),
        "status": .string("template"),
        "engine_version": .string("2"),
        "steps": .array([
            .object([
                "title": .string("  Do A Thing  "),
                "kind": .string("tool_run"),
                "requiresApproval": .bool(true),
                "dependsOn": .array([.string("x"), .int(7), .null]),
                "tool_id": .string("t-1"),
                "timeout_seconds": .int(30),
            ]),
            // non-dict step is dropped
            .string("garbage"),
            .object(["name": .string("Second")]),  // id derives from title
        ])
    ])
    let (id, rec, _) = try WorkflowCreate.buildRecord(body: body, now: "T", uuid: { "uuid" })
    #expect(id == "custom-id-7")              // slugify("Custom ID 7")
    #expect(stringField(rec, "name") == "My Flow!")    // stripped, kept "!"? name not slugified
    #expect(stringField(rec, "description") == "desc")
    #expect(stringField(rec, "trigger") == "go")
    #expect(stringField(rec, "status") == "template")
    #expect(stringField(rec, "engineVersion") == "2")  // engine_version snake fallback
    let steps = arrayField(rec, "steps")
    #expect(steps?.count == 2)  // garbage dropped
    // Step 0: id derived from slugify(title) since no id given.
    #expect(stringField(steps![0], "id") == "do-a-thing")
    #expect(stringField(steps![0], "title") == "Do A Thing")
    #expect(stringField(steps![0], "kind") == "tool_run")
    #expect(boolField(steps![0], "requiresApproval") == true)
    #expect(stringField(steps![0], "toolId") == "t-1")
    #expect(intField(steps![0], "timeoutSeconds") == 30)
    // dependsOn stringifies each element: [str("x"), str(7), str(None)].
    #expect(arrayField(steps![0], "dependsOn") == [.string("x"), .string("7"), .string("None")])
    // Step 1: title from "name", id from slugify(title).
    #expect(stringField(steps![1], "title") == "Second")
    #expect(stringField(steps![1], "id") == "second")
}

@Test func buildRecordRefusesMoreThan24StepsWithoutDroppingTail() throws {
    var raw: [JSONValue] = []
    for i in 0..<40 { raw.append(.object(["title": .string("Step \(i)")])) }
    #expect(throws: WorkflowOrchestrationError.tooManySteps(count: 40, maximum: 24)) {
        _ = try WorkflowCreate.buildRecord(
            body: .object(["steps": .array(raw)]), now: "T", uuid: { "u" }
        )
    }
}

@Test func createWorkflowOversizeRefusalWritesNoRegistryOrReceipts() async throws {
    let root = tempRoot()
    let client = SwiftNativeWorkflowOrchestrationClient(root: root, useFileLock: false)
    let steps = (0..<25).map { JSONValue.object(["title": .string("Step \($0)")]) }
    await #expect(throws: WorkflowOrchestrationError.tooManySteps(count: 25, maximum: 24)) {
        _ = try await client.createWorkflow(.object(["name": .string("Too Large"), "steps": .array(steps)]))
    }
    #expect(!FileManager.default.fileExists(atPath: root.appendingPathComponent("workflows/registry.json").path))
    #expect(!FileManager.default.fileExists(atPath: root.appendingPathComponent("activity/events.jsonl").path))
    #expect(!FileManager.default.fileExists(atPath: root.appendingPathComponent("traces/events.jsonl").path))
}

@Test func buildRecordWhitespaceOnlyTitleFallsBackToStepId() throws {
    // title/name whitespace-only -> stripped to "" -> id falls back to step-N.
    let body: JSONValue = .object(["steps": .array([.object(["title": .string("   ")])])])
    let (_, rec, _) = try WorkflowCreate.buildRecord(body: body, now: "T", uuid: { "u" })
    let steps = arrayField(rec, "steps")
    // title was "   " (truthy in Python) so titleRaw = "   ", stripped -> "".
    #expect(stringField(steps![0], "title") == "")
    // id: step.get("id") falsey, title "" falsey -> "step-1".
    #expect(stringField(steps![0], "id") == "step-1")
}

@Test func buildRecordEmptyNameSlugFallsBackToUUID() throws {
    // name = "!!!" -> stripped "!!!" -> id = slugify("!!!") -> "" -> uuid.
    let (id, _, _) = try WorkflowCreate.buildRecord(
        body: .object(["name": .string("!!!")]), now: "T", uuid: { "fallback-uuid" }
    )
    #expect(id == "fallback-uuid")
}

@Test func buildRecordEnumerateIndexAdvancesAcrossNonDictSteps() throws {
    // Python enumerate(steps) advances the index across SKIPPED non-dict steps,
    // so the dict at raw index 2 gets the "Step 3"/"step-3" fallback even though
    // it is the 2nd surviving dict (gpt-5.5 review finding #2).
    let body: JSONValue = .object(["steps": .array([
        .object([:]),          // index 0 -> "Step 1" / "step-1"
        .string("dropped"),    // index 1 -> skipped, index still advances
        .object([:]),          // index 2 -> "Step 3" / "step-3"  (NOT "Step 2")
    ])])
    let (_, rec, stepCount) = try WorkflowCreate.buildRecord(body: body, now: "T", uuid: { "u" })
    let steps = arrayField(rec, "steps")
    #expect(steps?.count == 2)
    #expect(stringField(steps![0], "title") == "Step 1")
    #expect(stringField(steps![0], "id") == "step-1")
    #expect(stringField(steps![1], "title") == "Step 3")
    #expect(stringField(steps![1], "id") == "step-3")
    #expect(stepCount == 2)
}

@Test func buildRecordNonNumericTimeoutThrows() {
    // Python int("abc" or ... or 0) RAISES ValueError -> the route 500s. The
    // native client throws WorkflowOrchestrationError.invalidTimeout rather than
    // silently coercing to 0 (gpt-5.5 review finding #5).
    let body: JSONValue = .object(["steps": .array([
        .object(["title": .string("x"), "timeout_seconds": .string("abc")]),
    ])])
    #expect(throws: WorkflowOrchestrationError.self) {
        _ = try WorkflowCreate.buildRecord(body: body, now: "T", uuid: { "u" })
    }
    // A float-shaped string also raises (Python int("1.2") raises).
    let body2: JSONValue = .object(["steps": .array([
        .object(["title": .string("x"), "timeoutSeconds": .string("1.2")]),
    ])])
    #expect(throws: WorkflowOrchestrationError.self) {
        _ = try WorkflowCreate.buildRecord(body: body2, now: "T", uuid: { "u" })
    }
    // A whitespace-only string is TRUTHY in Python so it reaches int("   "),
    // which RAISES — must NOT silently coerce to 0 (re-review finding).
    let body3: JSONValue = .object(["steps": .array([
        .object(["title": .string("x"), "timeoutSeconds": .string("   ")]),
    ])])
    #expect(throws: WorkflowOrchestrationError.self) {
        _ = try WorkflowCreate.buildRecord(body: body3, now: "T", uuid: { "u" })
    }
}

@Test func buildRecordTimeoutOrChainHandlesFalseyCollections() throws {
    // Python int(timeoutSeconds or timeout_seconds or 0): a FALSEY []/{}/0 is
    // collapsed by `or` BEFORE int() runs, so it degrades to 0 rather than
    // raising. Only a TRUTHY un-parseable value raises (re-review finding).
    // timeoutSeconds=0(int, falsey) + timeout_seconds=[](falsey) -> 0.
    let body: JSONValue = .object(["steps": .array([
        .object(["title": .string("x"), "timeoutSeconds": .int(0), "timeout_seconds": .array([])]),
    ])])
    let (_, rec, _) = try WorkflowCreate.buildRecord(body: body, now: "T", uuid: { "u" })
    #expect(intField(arrayField(rec, "steps")![0], "timeoutSeconds") == 0)
    // A newline-wrapped numeric string parses like Python int("\n5\n") == 5.
    let body2: JSONValue = .object(["steps": .array([
        .object(["title": .string("x"), "timeoutSeconds": .string("\n5\n")]),
    ])])
    let (_, rec2, _) = try WorkflowCreate.buildRecord(body: body2, now: "T", uuid: { "u" })
    #expect(intField(arrayField(rec2, "steps")![0], "timeoutSeconds") == 5)
}

@Test func createWorkflowPersistsSortedOrderNewAtEnd() async throws {
    // Python create filters the SORTED return of _list_workflows_locked (DESC by
    // updatedAt|createdAt), appends the new workflow last, and overwrites. The
    // persisted order must be sorted(minus same-id) + new-at-end, NOT the
    // unsorted merge order (gpt-5.5 review finding #3).
    let root = tempRoot()
    // Seed two saved workflows with DIFFERENT timestamps so sort order is
    // observable and distinct from insertion order.
    try writeRegistry(root, [
        .object(["id": .string("alpha"), "name": .string("Alpha"), "steps": .array([]),
                 "updatedAt": .string("2026-01-01T00:00:00+00:00")]),
        .object(["id": .string("zeta"), "name": .string("Zeta"), "steps": .array([]),
                 "updatedAt": .string("2026-12-01T00:00:00+00:00")]),
    ])
    let client = SwiftNativeWorkflowOrchestrationClient(
        root: root, now: { "2026-06-02T00:00:00.000000+00:00" }, uuid: { "u" }, useFileLock: false
    )
    _ = try await client.createWorkflow(.object(["id": .string("mid"), "name": .string("Mid")]))
    let reg = try readRegistry(root)
    // The newly-created "mid" must be LAST regardless of its timestamp sort
    // position; everything before it must be in DESC-timestamp order.
    #expect(WorkflowMerge.idKey(reg.last!) == "mid")
    let preceding = reg.dropLast().map { WorkflowMerge.sortKey($0) }
    let sortedDesc = preceding.sorted(by: >)
    #expect(Array(preceding) == sortedDesc)
}

@Test func createWorkflowWithFileLockDoesNotDeadlock() async throws {
    // The registry write does the FULL _list_workflows_locked merge + the
    // filter+append+overwrite inside ONE withFileLock(registryPath). If the
    // inner merge re-acquired the SAME lock it would deadlock (flock(2) is not
    // recursive across fds). This proves the locked path completes against the
    // real SwiftNativePersistenceCore (not the useFileLock:false bypass the
    // other create tests use).
    let root = tempRoot()
    let client = SwiftNativeWorkflowOrchestrationClient(
        root: root, now: { WorkflowOrchestrationClock.nowISO() }, uuid: { "u" }, useFileLock: true
    )
    let saved = try await client.createWorkflow(.object(["name": .string("Locked Flow")]))
    #expect(stringField(saved, "id") == "locked-flow")
    let reg = try readRegistry(root)
    #expect(reg.map { WorkflowMerge.idKey($0) }.contains("locked-flow"))
    // Defaults were merged + written back under the lock too.
    #expect(reg.map { WorkflowMerge.idKey($0) }.contains("memory-capture"))
}

@Test func createWorkflowPersistsAndEmitsSideEffects() async throws {
    let root = tempRoot()
    let client = SwiftNativeWorkflowOrchestrationClient(
        root: root,
        now: { "2026-06-02T12:00:00.000000+00:00" },
        uuid: { "test-uuid" },
        useFileLock: false
    )
    let saved = try await client.createWorkflow(.object([
        "name": .string("Nightly Sync"),
        "steps": .array([.object(["title": .string("Pull"), "kind": .string("router")])]),
    ]))
    #expect(stringField(saved, "id") == "nightly-sync")
    #expect(stringField(saved, "name") == "Nightly Sync")

    // Registry: defaults merged in + the new workflow appended.
    let reg = try readRegistry(root)
    let ids = reg.map { WorkflowMerge.idKey($0) }
    #expect(ids.contains("nightly-sync"))
    #expect(ids.contains("research-to-brief"))  // default written back
    #expect(ids.contains("memory-capture"))
    // new workflow is last.
    #expect(ids.last == "nightly-sync")

    // Activity side-effect.
    let act = try firstActivity(root)
    #expect(stringField(act, "kind") == "workflow")
    #expect(stringField(act, "title") == "Workflow saved")
    #expect(stringField(act, "detail") == "Nightly Sync")
    #expect(stringField(act, "status") == "ok")
    if case .object(let o) = act, case .object(let p)? = o["payload"] {
        #expect(p["workflowId"] == JSONValue.string("nightly-sync"))
    } else { Issue.record("activity missing payload.workflowId") }

    // Trace side-effect.
    let tr = try firstTrace(root)
    #expect(stringField(tr, "kind") == "workflow.save")
    #expect(stringField(tr, "title") == "Nightly Sync")
    #expect(stringField(tr, "status") == "ok")
    if case .object(let o) = tr, case .object(let p)? = o["payload"] {
        #expect(p["workflowId"] == JSONValue.string("nightly-sync"))
        #expect(p["stepCount"] == JSONValue.int(1))
    } else { Issue.record("trace missing payload") }
}

@Test func createWorkflowReplacesSameIdRow() async throws {
    let root = tempRoot()
    // Pre-seed a registry with a custom workflow.
    try writeRegistry(root, [.object([
        "id": .string("my-flow"),
        "name": .string("Old Name"),
        "steps": .array([]),
        "updatedAt": .string("2026-01-01T00:00:00+00:00"),
    ])])
    let client = SwiftNativeWorkflowOrchestrationClient(
        root: root, now: { "2026-06-02T00:00:00.000000+00:00" }, uuid: { "u" }, useFileLock: false
    )
    _ = try await client.createWorkflow(.object(["id": .string("my-flow"), "name": .string("New Name")]))
    let reg = try readRegistry(root)
    let myFlows = reg.filter { WorkflowMerge.idKey($0) == "my-flow" }
    #expect(myFlows.count == 1)  // replaced, not duplicated
    #expect(stringField(myFlows[0], "name") == "New Name")
}

@Test func createWorkflowRedactsSecretInActivity() async throws {
    let root = tempRoot()
    let client = SwiftNativeWorkflowOrchestrationClient(
        root: root, now: { "T" }, uuid: { "u" }, useFileLock: false
    )
    // A workflow name containing a credential-shaped token must be redacted in
    // the activity feed `detail` (record_activity redacts title/detail/payload).
    // NOTE: the daemon applies patterns in order and the OPENAI_KEY pattern
    // (\bsk-(?:proj-)?[A-Za-z0-9_-]{20,}\b) is tried BEFORE ANTHROPIC_KEY, so a
    // "sk-ant-..." token is captured under OPENAI_KEY — faithful to Python's
    // sequential redact_secret_text. We assert redaction happened, not the kind.
    let secret = "sk-ant-AAAAAAAAAAAAAAAAAAAAAAAAAAAA"
    _ = try await client.createWorkflow(.object(["name": .string("leak \(secret)")]))
    let act = try firstActivity(root)
    let detail = stringField(act, "detail") ?? ""
    #expect(!detail.contains(secret))
    #expect(detail.contains("[REDACTED_"))
    // A token that ONLY matches ANTHROPIC (sk-ant- with the unambiguous prefix
    // already consumed) is impossible to isolate here because OPENAI is broader;
    // verify a Slack token routes to its own kind to prove kind-labeling works.
    // Split literal so secret scanners don't flag this fixture; runtime value unchanged.
    let slack = "xoxb-" + "1234567890-abcdefghijklmnop"
    _ = try await client.createWorkflow(.object(["name": .string("slack \(slack)")]))
    let reg2detail = WorkflowRedaction.redactText("slack \(slack)")
    #expect(!reg2detail.contains(slack))
    #expect(reg2detail.contains("[REDACTED_SLACK_TOKEN:"))
}

// MARK: - run / resume

@Test func runWorkflowV1DryRunRecordsReceiptsAndRunLedger() async throws {
    let root = tempRoot()
    try writeRegistry(root, [
        .object([
            "id": .string("dry-flow"),
            "name": .string("Dry Flow"),
            "engineVersion": .string("1"),
            "steps": .array([
                .object(["id": .string("route"), "title": .string("Route"), "kind": .string("router")]),
                .object(["id": .string("approve"), "title": .string("Approve"), "kind": .string("approval"), "requiresApproval": .bool(true)]),
            ]),
            "createdAt": .string("2026-06-01T00:00:00+00:00"),
            "updatedAt": .string("2026-06-01T00:00:00+00:00"),
        ]),
    ])
    let client = SwiftNativeWorkflowOrchestrationClient(
        root: root,
        now: { "2026-06-03T00:00:00.000000+00:00" },
        uuid: makeIDFactory(["run-v1"]),
        useFileLock: false
    )
    let run = try await client.runWorkflow(
        id: "dry-flow",
        objective: "draft a plan",
        execute: false,
        engineVersion: nil,
        variables: nil
    )
    #expect(stringField(run, "id") == "run-v1")
    #expect(stringField(run, "status") == "waiting_approval")
    #expect(stringField(run, "mode") == "dry_run")
    let steps = arrayField(run, "steps") ?? []
    #expect(steps.count == 2)
    #expect(stringField(steps[0], "status") == "succeeded")
    #expect(stringField(steps[1], "status") == "waiting_approval")

    let runs = try await client.listWorkflowRuns()
    #expect(runs.count == 1)
    #expect(stringField(runs[0], "id") == "run-v1")
}

@Test func legacyV1LiveApprovalRunHealsOntoResumableV2() async throws {
    let root = tempRoot()
    try writeRegistry(root, [
        .object([
            "id": .string("legacy-live"),
            "name": .string("Legacy Live"),
            "engineVersion": .string("1"),
            "steps": .array([
                .object([
                    "id": .string("gate"), "title": .string("Gate"),
                    "kind": .string("approval"), "requiresApproval": .bool(true),
                ]),
            ]),
            "createdAt": .string("T"), "updatedAt": .string("T"),
        ]),
    ])
    let client = SwiftNativeWorkflowOrchestrationClient(
        root: root, now: { "2026-08-16T00:00:00Z" },
        uuid: makeIDFactory(["legacy-run"]), useFileLock: false
    )
    let waiting = try await client.runWorkflow(
        id: "legacy-live", objective: "finish safely", execute: true,
        engineVersion: nil, variables: nil
    )
    #expect(stringField(waiting, "id") == "legacy-run")
    #expect(stringField(waiting, "engineVersion") == "2")
    #expect(stringField(waiting, "status") == "waiting_approval")
    #expect(FileManager.default.fileExists(atPath: root
        .appendingPathComponent("workflows/run_state/legacy-run.json").path))
}

@Test func deniedApprovalSettlesRunOnceInsteadOfParkingForever() async throws {
    let root = tempRoot()
    try writeRegistry(root, [
        .object([
            "id": .string("deny-flow"), "name": .string("Deny Flow"),
            "engineVersion": .string("2"),
            "steps": .array([.object([
                "id": .string("gate"), "title": .string("Gate"),
                "kind": .string("approval"), "requiresApproval": .bool(true),
            ])]),
            "createdAt": .string("T"), "updatedAt": .string("T"),
        ]),
    ])
    let client = SwiftNativeWorkflowOrchestrationClient(
        root: root, now: { "2026-08-16T00:00:00Z" },
        uuid: makeIDFactory(["denied-run"]), useFileLock: false
    )
    let waiting = try await client.runWorkflow(
        id: "deny-flow", objective: "test", execute: true,
        engineVersion: nil, variables: nil
    )
    let approvalID = try #require(stringField(waiting, "approvalId"))
    _ = try await SwiftNativeApprovalInbox(root: root).resolve(
        approvalID, decision: .denied, decidedBy: "test"
    )
    let terminal = try await client.resumeWorkflowRun(id: "denied-run")
    #expect(stringField(terminal, "status") == "failed")
    #expect(stringField(arrayField(terminal, "steps")?.last ?? .null, "detail") == "Approval denied.")
    let repeated = try await client.resumeWorkflowRun(id: "denied-run")
    #expect(stringField(repeated, "status") == "failed")
    #expect((try await client.listWorkflowRuns()).count == 2)
}

@Test func canceledApprovalSettlesRunCanceledOnceInsteadOfParkingForever() async throws {
    let root = tempRoot()
    try writeRegistry(root, [
        .object([
            "id": .string("cancel-approval-flow"),
            "name": .string("Cancel Approval Flow"),
            "engineVersion": .string("2"),
            "steps": .array([.object([
                "id": .string("gate"), "title": .string("Gate"),
                "kind": .string("approval"), "requiresApproval": .bool(true),
            ])]),
            "createdAt": .string("T"), "updatedAt": .string("T"),
        ]),
    ])
    let client = SwiftNativeWorkflowOrchestrationClient(
        root: root,
        now: { "2026-08-16T00:00:00Z" },
        uuid: makeIDFactory(["canceled-approval-run"]),
        useFileLock: false
    )
    let waiting = try await client.runWorkflow(
        id: "cancel-approval-flow",
        objective: "test",
        execute: true,
        engineVersion: nil,
        variables: nil
    )
    let approvalID = try #require(stringField(waiting, "approvalId"))
    _ = try await SwiftNativeApprovalInbox(root: root).resolve(
        approvalID,
        decision: .canceled,
        decidedBy: "test"
    )

    let terminal = try await client.resumeWorkflowRun(id: "canceled-approval-run")
    #expect(stringField(terminal, "status") == "canceled")
    #expect(stringField(arrayField(terminal, "steps")?.last ?? .null, "status") == "canceled")
    #expect(stringField(arrayField(terminal, "steps")?.last ?? .null, "detail") == "Approval canceled.")
    let repeated = try await client.resumeWorkflowRun(id: "canceled-approval-run")
    #expect(stringField(repeated, "status") == "canceled")
    let runs = try await client.listWorkflowRuns()
    #expect(runs.count == 2)
}

@Test func restartRepairsDispatchedAttemptWithoutBlindReplay() async throws {
    struct InjectedCrash: Error {}
    let root = tempRoot()
    try writeRegistry(root, [
        .object([
            "id": .string("crash-flow"), "name": .string("Crash Flow"),
            "engineVersion": .string("2"),
            "steps": .array([.object([
                "id": .string("trace"), "title": .string("Trace"), "kind": .string("trace"),
            ])]),
            "createdAt": .string("T"), "updatedAt": .string("T"),
        ]),
    ])
    let crashing = SwiftNativeWorkflowOrchestrationClient(
        root: root, now: { "2026-08-16T00:00:00Z" },
        uuid: makeIDFactory(["crash-run"]), useFileLock: false,
        afterStepAttemptPersisted: { _, _ in throw InjectedCrash() },
        processIdentity: "crashed-process"
    )
    await #expect(throws: InjectedCrash.self) {
        _ = try await crashing.runWorkflow(
            id: "crash-flow", objective: "test", execute: true,
            engineVersion: nil, variables: nil
        )
    }

    let sameProcessReader = SwiftNativeWorkflowOrchestrationClient(
        root: root, now: { "2026-08-16T00:00:30Z" }, useFileLock: false,
        processIdentity: "crashed-process"
    )
    let sameProcessRuns = try await sameProcessReader.listWorkflowRuns()
    #expect(sameProcessRuns.isEmpty)

    let restarted = SwiftNativeWorkflowOrchestrationClient(
        root: root, now: { "2026-08-16T00:01:00Z" }, useFileLock: false,
        processIdentity: "restarted-process"
    )
    let firstList = try await restarted.listWorkflowRuns()
    #expect(firstList.count == 1)
    #expect(stringField(firstList[0], "status") == "blocked")
    #expect(stringField(firstList[0], "blockedReason") == "interrupted_after_step_dispatch")
    let secondList = try await restarted.listWorkflowRuns()
    #expect(secondList.count == 1)
    let resumed = try await restarted.resumeWorkflowRun(id: "crash-run")
    #expect(stringField(resumed, "status") == "blocked")
}

@Test func runWorkflowV2PausesForApprovalThenResumeCompletesTraceStep() async throws {
    let root = tempRoot()
    try writeRegistry(root, [
        .object([
            "id": .string("approval-flow"),
            "name": .string("Approval Flow"),
            "engineVersion": .string("2"),
            "steps": .array([
                .object(["id": .string("gate"), "title": .string("Gate"), "kind": .string("approval"), "requiresApproval": .bool(true)]),
                .object(["id": .string("trace"), "title": .string("Trace"), "kind": .string("trace")]),
            ]),
            "createdAt": .string("2026-06-01T00:00:00+00:00"),
            "updatedAt": .string("2026-06-01T00:00:00+00:00"),
        ]),
    ])
    let client = SwiftNativeWorkflowOrchestrationClient(
        root: root,
        now: { "2026-06-03T00:00:00.000000+00:00" },
        uuid: makeIDFactory(["run-v2", "trace-id"]),
        useFileLock: false
    )
    let waiting = try await client.runWorkflow(
        id: "approval-flow",
        objective: "ship safely",
        execute: true,
        engineVersion: nil,
        variables: nil
    )
    #expect(stringField(waiting, "status") == "waiting_approval")
    guard let approvalId = stringField(waiting, "approvalId") else {
        Issue.record("run missing approvalId")
        return
    }
    let inbox = SwiftNativeApprovalInbox(root: root)
    _ = try await inbox.resolve(approvalId, decision: .approved, decidedBy: "test")

    let resumed = try await client.resumeWorkflowRun(id: "run-v2")
    #expect(stringField(resumed, "status") == "succeeded")
    #expect(intField(resumed, "currentStepIndex") == 2)
    let steps = arrayField(resumed, "steps") ?? []
    #expect(steps.count == 2)
    #expect(stringField(steps[0], "status") == "succeeded")
    #expect(stringField(steps[0], "detail") == "Approval resolved; workflow resumed.")
    #expect(stringField(steps[1], "status") == "succeeded")
}

@Test func runWorkflowV2ToolRunExecutesPromotedSwiftTool() async throws {
    let root = tempRoot()
    try seedWorkflowTool(root: root, id: "example")
    try writeRegistry(root, [
        .object([
            "id": .string("tool-flow"),
            "name": .string("Tool Flow"),
            "engineVersion": .string("2"),
            "steps": .array([
                .object([
                    "id": .string("tool"),
                    "title": .string("Tool"),
                    "kind": .string("tool_run"),
                    "toolId": .string("example"),
                    "input": .object(["message": .string("hello")]),
                    "outputKey": .string("toolOutput"),
                ]),
            ]),
            "createdAt": .string("2026-06-01T00:00:00+00:00"),
            "updatedAt": .string("2026-06-01T00:00:00+00:00"),
        ]),
    ])
    let client = SwiftNativeWorkflowOrchestrationClient(
        root: root,
        now: { "2026-06-03T00:00:00.000000+00:00" },
        uuid: makeIDFactory(["run-tool"]),
        useFileLock: false
    )
    let run = try await client.runWorkflow(
        id: "tool-flow",
        objective: "run the tool",
        execute: true,
        engineVersion: nil,
        variables: nil
    )
    #expect(stringField(run, "status") == "succeeded")
    let steps = arrayField(run, "steps") ?? []
    #expect(steps.count == 1)
    #expect(stringField(steps[0], "status") == "succeeded")
    #expect((stringField(steps[0], "detail") ?? "").contains("Tool example returned ok"))
    guard case .object(let stepObj) = steps[0],
          case .object(let output)? = stepObj["output"],
          case .object(let resultEnvelope)? = output["result"],
          case .object(let result)? = resultEnvelope["result"],
          case .object(let received)? = result["received"] else {
        Issue.record("tool_run workflow output did not expose parsed tool result")
        return
    }
    #expect(received["message"] == .string("hello"))
    let statePath = root
        .appendingPathComponent("workflows/run_state")
        .appendingPathComponent("\(WorkflowRunState.slugify("run-tool")).json")
    let state = try JSONValue.parse(Data(contentsOf: statePath))
    guard case .object(let stateObj) = state,
          case .object(let outputs)? = stateObj["outputs"],
          outputs["toolOutput"] != nil else {
        Issue.record("tool_run outputKey was not stored")
        return
    }
}

@Test func runWorkflowV2UnknownStepKindIsRejectedBeforeRunStateMutation() async throws {
    let root = tempRoot()
    try writeRegistry(root, [
        .object([
            "id": .string("llm-flow"),
            "name": .string("LLM Flow"),
            "engineVersion": .string("2"),
            "steps": .array([
                .object(["id": .string("brief"), "title": .string("Draft brief"), "kind": .string("llm")]),
            ]),
            "createdAt": .string("2026-06-01T00:00:00+00:00"),
            "updatedAt": .string("2026-06-01T00:00:00+00:00"),
        ]),
    ])
    let client = SwiftNativeWorkflowOrchestrationClient(
        root: root,
        now: { "2026-06-03T00:00:00.000000+00:00" },
        uuid: makeIDFactory(["run-llm"]),
        useFileLock: false
    )
    await #expect(throws: WorkflowOrchestrationError.self) {
        _ = try await client.runWorkflow(
            id: "llm-flow",
            objective: "draft a brief",
            execute: true,
            engineVersion: nil,
            variables: nil
        )
    }
    let runs = try await client.listWorkflowRuns()
    #expect(runs.isEmpty)
    let stateDirectory = root
        .appendingPathComponent("workflows", isDirectory: true)
        .appendingPathComponent("run_state", isDirectory: true)
    let stateFiles = (try? FileManager.default.contentsOfDirectory(atPath: stateDirectory.path)) ?? []
    #expect(stateFiles.isEmpty)
}

@Test func builtInWorkflowAvailabilityDoesNotAdvertiseFossilStepKinds() {
    let defaults = WorkflowDefaults.defaults(now: "2026-06-01T00:00:00Z")
    let availabilityByID = Dictionary(uniqueKeysWithValues: defaults.compactMap { workflow -> (String, WorkflowExecutionAvailability)? in
        guard let id = stringField(workflow, "id") else { return nil }
        return (id, WorkflowExecutionPreflight.evaluate(workflow: workflow))
    })

    #expect(availabilityByID["memory-capture"]?.isRunnable == true)
    #expect(availabilityByID["research-to-brief"]?.isRunnable == false)
    #expect(availabilityByID["research-to-brief"]?.unsupportedStepKinds == ["llm", "receipt"])
    #expect(availabilityByID["safe-tool-forge"]?.isRunnable == false)
    #expect(availabilityByID["safe-tool-forge"]?.unsupportedStepKinds == ["analysis", "tool_proposal", "validation"])
}

@Test func resumeWorkflowRunRejectsMissingApprovalRecord() async throws {
    let root = tempRoot()
    try writeRegistry(root, [
        .object([
            "id": .string("approval-flow"),
            "name": .string("Approval Flow"),
            "engineVersion": .string("2"),
            "steps": .array([
                .object(["id": .string("gate"), "title": .string("Gate"), "kind": .string("approval"), "requiresApproval": .bool(true)]),
                .object(["id": .string("trace"), "title": .string("Trace"), "kind": .string("trace")]),
            ]),
            "createdAt": .string("2026-06-01T00:00:00+00:00"),
            "updatedAt": .string("2026-06-01T00:00:00+00:00"),
        ]),
    ])
    let client = SwiftNativeWorkflowOrchestrationClient(
        root: root,
        now: { "2026-06-03T00:00:00.000000+00:00" },
        uuid: makeIDFactory(["run-missing"]),
        useFileLock: false
    )
    let waiting = try await client.runWorkflow(
        id: "approval-flow",
        objective: "ship safely",
        execute: true,
        engineVersion: nil,
        variables: nil
    )
    #expect(stringField(waiting, "status") == "waiting_approval")
    // Simulate a pruned/corrupt inbox: the run still carries an approvalId but
    // no record exists. Resume must REFUSE, not fall through as approved.
    let requests = root
        .appendingPathComponent("workflows")
        .appendingPathComponent("approvals")
        .appendingPathComponent("requests.json")
    try FileManager.default.removeItem(at: requests)
    do {
        _ = try await client.resumeWorkflowRun(id: "run-missing")
        Issue.record("expected resume to throw when the approval record is missing")
    } catch {
        #expect(error.localizedDescription.contains("approval record missing"))
    }
}

@Test func resumeWorkflowRunExecutesApprovalGatedRealStep() async throws {
    let root = tempRoot()
    try writeRegistry(root, [
        .object([
            "id": .string("gated-trace-flow"),
            "name": .string("Gated Trace Flow"),
            "engineVersion": .string("2"),
            "steps": .array([
                .object([
                    "id": .string("trace"),
                    "title": .string("Trace"),
                    "kind": .string("trace"),
                    "requiresApproval": .bool(true),
                    "outputKey": .string("traceOutput"),
                ]),
            ]),
            "createdAt": .string("2026-06-01T00:00:00+00:00"),
            "updatedAt": .string("2026-06-01T00:00:00+00:00"),
        ]),
    ])
    let client = SwiftNativeWorkflowOrchestrationClient(
        root: root,
        now: { "2026-06-03T00:00:00.000000+00:00" },
        uuid: makeIDFactory(["run-gated", "trace-id"]),
        useFileLock: false
    )
    let waiting = try await client.runWorkflow(
        id: "gated-trace-flow",
        objective: "record the receipt",
        execute: true,
        engineVersion: nil,
        variables: nil
    )
    #expect(stringField(waiting, "status") == "waiting_approval")
    guard let approvalId = stringField(waiting, "approvalId") else {
        Issue.record("run missing approvalId")
        return
    }
    let inbox = SwiftNativeApprovalInbox(root: root)
    _ = try await inbox.resolve(approvalId, decision: .approved, decidedBy: "test")

    // Approving a REAL-kind step must re-dispatch its work, not just flip the
    // receipt to "succeeded" without executing anything.
    let resumed = try await client.resumeWorkflowRun(id: "run-gated")
    #expect(stringField(resumed, "status") == "succeeded")
    #expect(intField(resumed, "currentStepIndex") == 1)
    let steps = arrayField(resumed, "steps") ?? []
    #expect(steps.count == 1)
    #expect(stringField(steps[0], "status") == "succeeded")
    #expect(stringField(steps[0], "detail") == "Trace receipt recorded.")
    guard case .object(let stepObj) = steps[0],
          case .object(let output)? = stepObj["output"],
          output["traceId"] != nil else {
        Issue.record("re-dispatched step did not record real trace output")
        return
    }
    let statePath = root
        .appendingPathComponent("workflows/run_state")
        .appendingPathComponent("\(WorkflowRunState.slugify("run-gated")).json")
    let state = try JSONValue.parse(Data(contentsOf: statePath))
    guard case .object(let stateObj) = state,
          case .object(let outputs)? = stateObj["outputs"],
          outputs["traceOutput"] != nil else {
        Issue.record("re-dispatched step outputKey was not stored")
        return
    }
}

/// Reads ALL JSONL records from traces/events.jsonl (empty if missing).
private func allTraces(_ root: URL) throws -> [JSONValue] {
    let path = root.appendingPathComponent("traces/events.jsonl")
    guard let text = try? String(contentsOf: path, encoding: .utf8) else { return [] }
    return try text.split(separator: "\n").map { try JSONValue.parse(Data($0.utf8)) }
}

@Test func resumeWorkflowRunClaimsRunSoConcurrentResumeExecutesStepOnce() async throws {
    let root = tempRoot()
    try writeRegistry(root, [
        .object([
            "id": .string("race-flow"),
            "name": .string("Race Flow"),
            "engineVersion": .string("2"),
            "steps": .array([
                .object([
                    "id": .string("trace"),
                    "title": .string("Trace"),
                    "kind": .string("trace"),
                    "requiresApproval": .bool(true),
                ]),
            ]),
            "createdAt": .string("2026-06-01T00:00:00+00:00"),
            "updatedAt": .string("2026-06-01T00:00:00+00:00"),
        ]),
    ])
    // useFileLock: true — the resume claim's compare-and-swap is what this
    // test exercises, and it is only atomic under the real flock.
    let client = SwiftNativeWorkflowOrchestrationClient(
        root: root,
        now: { "2026-06-03T00:00:00.000000+00:00" },
        uuid: makeIDFactory(["run-race"]),
        useFileLock: true
    )
    let waiting = try await client.runWorkflow(
        id: "race-flow",
        objective: "record exactly once",
        execute: true,
        engineVersion: nil,
        variables: nil
    )
    #expect(stringField(waiting, "status") == "waiting_approval")
    guard let approvalId = stringField(waiting, "approvalId") else {
        Issue.record("run missing approvalId")
        return
    }
    let inbox = SwiftNativeApprovalInbox(root: root)
    _ = try await inbox.resolve(approvalId, decision: .approved, decidedBy: "test")

    // Two CONCURRENT resume calls: both can pass the waiting_approval read,
    // but only the claim (CAS) winner may dispatch the side-effecting step;
    // the loser must return the committed state without executing anything.
    async let firstCall = client.resumeWorkflowRun(id: "run-race")
    async let secondCall = client.resumeWorkflowRun(id: "run-race")
    let (first, second) = try await (firstCall, secondCall)
    let statuses = [stringField(first, "status"), stringField(second, "status")]
    #expect(statuses.contains("succeeded"))

    // The gated trace step must have executed EXACTLY once.
    let stepTraces = try allTraces(root).filter { stringField($0, "kind") == "workflow.step" }
    #expect(stepTraces.count == 1)

    // A later (sequential) resume of the completed run is a read-only no-op:
    // it returns the final state and re-executes nothing.
    let third = try await client.resumeWorkflowRun(id: "run-race")
    #expect(stringField(third, "status") == "succeeded")
    let stepTracesAfter = try allTraces(root).filter { stringField($0, "kind") == "workflow.step" }
    #expect(stepTracesAfter.count == 1)
}

// MARK: - v2 state-machine scaffolding (Wave 35 W03, CUTOVER_PLAN §6.117)
//
// Pure-helper coverage for the run-path DECISION logic ported ahead of the live
// engine: WorkflowRunState.evaluateStepCondition / .decideStep / .maxAttempts.

private func step(_ fields: [String: JSONValue]) -> JSONValue { .object(fields) }

// --- evaluateStepCondition ---

@Test func conditionEmptyOrMissingReturnsTrue() {
    // Missing condition.
    #expect(WorkflowRunState.evaluateStepCondition(step: step([:]), variables: [:], outputs: [:]))
    // Empty-string condition (falsey -> "").
    #expect(WorkflowRunState.evaluateStepCondition(step: step(["condition": .string("")]), variables: [:], outputs: [:]))
    // Whitespace-only condition strips to "" -> True.
    #expect(WorkflowRunState.evaluateStepCondition(step: step(["condition": .string("   ")]), variables: [:], outputs: [:]))
    // Falsey non-string condition (0 / false / null) -> "" -> True.
    #expect(WorkflowRunState.evaluateStepCondition(step: step(["condition": .int(0)]), variables: [:], outputs: [:]))
    #expect(WorkflowRunState.evaluateStepCondition(step: step(["condition": .bool(false)]), variables: [:], outputs: [:]))
    #expect(WorkflowRunState.evaluateStepCondition(step: step(["condition": .null]), variables: [:], outputs: [:]))
}

@Test func conditionVarPrefixReadsVariableTruthiness() {
    let s = step(["condition": .string("var:ready")])
    #expect(WorkflowRunState.evaluateStepCondition(step: s, variables: ["ready": .bool(true)], outputs: [:]))
    #expect(!WorkflowRunState.evaluateStepCondition(step: s, variables: ["ready": .bool(false)], outputs: [:]))
    // Missing var key -> falsey -> false.
    #expect(!WorkflowRunState.evaluateStepCondition(step: s, variables: [:], outputs: [:]))
    // Non-empty string var -> truthy.
    #expect(WorkflowRunState.evaluateStepCondition(step: s, variables: ["ready": .string("yes")], outputs: [:]))
    // Empty string var -> falsey.
    #expect(!WorkflowRunState.evaluateStepCondition(step: s, variables: ["ready": .string("")], outputs: [:]))
}

@Test func conditionOutputPrefixReadsOutputTruthiness() {
    let s = step(["condition": .string("output:brief")])
    #expect(WorkflowRunState.evaluateStepCondition(step: s, variables: [:], outputs: ["brief": .int(1)]))
    #expect(!WorkflowRunState.evaluateStepCondition(step: s, variables: [:], outputs: ["brief": .int(0)]))
    #expect(!WorkflowRunState.evaluateStepCondition(step: s, variables: [:], outputs: [:]))
}

@Test func conditionLiteralFalseSkipDisabledReturnsFalse() {
    for word in ["false", "skip", "disabled", "FALSE", "Skip", "DISABLED"] {
        #expect(!WorkflowRunState.evaluateStepCondition(step: step(["condition": .string(word)]), variables: [:], outputs: [:]))
    }
    // Anything else (unknown literal) -> True.
    #expect(WorkflowRunState.evaluateStepCondition(step: step(["condition": .string("whenever")]), variables: [:], outputs: [:]))
}

// --- decideStep ---

@Test func decideStepSkipWhenConditionFalse() {
    let s = step(["id": .string("a"), "condition": .string("skip")])
    #expect(WorkflowRunState.decideStep(step: s, variables: [:], outputs: [:], completedIds: []) == .skip)
}

@Test func decideStepBlockedOnUnmetDependency() {
    let s = step(["id": .string("b"), "dependsOn": .array([.string("a"), .string("z")])])
    let d = WorkflowRunState.decideStep(step: s, variables: [:], outputs: [:], completedIds: ["a"])
    #expect(d == .blocked(missing: ["z"]))
}

@Test func decideStepExecuteWhenDepsMet() {
    let s = step(["id": .string("b"), "dependsOn": .array([.string("a")])])
    #expect(WorkflowRunState.decideStep(step: s, variables: [:], outputs: [:], completedIds: ["a"]) == .execute)
    // No deps at all -> execute.
    let s2 = step(["id": .string("c")])
    #expect(WorkflowRunState.decideStep(step: s2, variables: [:], outputs: [:], completedIds: []) == .execute)
}

@Test func decideStepWaitApprovalOnFlagOrKind() {
    let byFlag = step(["id": .string("d"), "requiresApproval": .bool(true)])
    #expect(WorkflowRunState.decideStep(step: byFlag, variables: [:], outputs: [:], completedIds: []) == .waitApproval)
    let byKind = step(["id": .string("e"), "kind": .string("approval")])
    #expect(WorkflowRunState.decideStep(step: byKind, variables: [:], outputs: [:], completedIds: []) == .waitApproval)
}

@Test func decideStepConditionTakesPrecedenceOverDeps() {
    // Python evaluates condition FIRST: a skipped step never reports blocked even
    // with an unmet dependency.
    let s = step(["id": .string("f"), "condition": .string("false"), "dependsOn": .array([.string("missing")])])
    #expect(WorkflowRunState.decideStep(step: s, variables: [:], outputs: [:], completedIds: []) == .skip)
}

@Test func decideStepDependencyStringifiesNonStringElements() {
    // depends_on = [str(x) for x in dependsOn]; an int dep 7 -> "7".
    let s = step(["id": .string("g"), "dependsOn": .array([.int(7)])])
    #expect(WorkflowRunState.decideStep(step: s, variables: [:], outputs: [:], completedIds: ["7"]) == .execute)
    #expect(WorkflowRunState.decideStep(step: s, variables: [:], outputs: [:], completedIds: []) == .blocked(missing: ["7"]))
}

// --- maxAttempts ---

@Test func maxAttemptsDefaultsToOne() {
    #expect(WorkflowRunState.maxAttempts(forStep: step([:])) == 1)
    // retry present but empty -> or 1 -> 1.
    #expect(WorkflowRunState.maxAttempts(forStep: step(["retry": .object([:])])) == 1)
    // retry not a dict -> 1.
    #expect(WorkflowRunState.maxAttempts(forStep: step(["retry": .string("nope")])) == 1)
}

@Test func maxAttemptsClampsToFive() {
    #expect(WorkflowRunState.maxAttempts(forStep: step(["retry": .object(["maxAttempts": .int(99)])])) == 5)
    #expect(WorkflowRunState.maxAttempts(forStep: step(["retry": .object(["maxAttempts": .int(3)])])) == 3)
    // snake_case fallback key.
    #expect(WorkflowRunState.maxAttempts(forStep: step(["retry": .object(["max_attempts": .int(2)])])) == 2)
    // camelCase wins over snake_case when both present + truthy.
    #expect(WorkflowRunState.maxAttempts(forStep: step(["retry": .object(["maxAttempts": .int(4), "max_attempts": .int(2)])])) == 4)
    // <1 clamps up to 1.
    #expect(WorkflowRunState.maxAttempts(forStep: step(["retry": .object(["maxAttempts": .int(0)])])) == 1)
}

// R2 in-flight abort (blueprint follow-up): a run whose run-state file already
// says canceled must PREEMPT an in-flight step dispatch. The event-driven
// observer performs its initial canonical read immediately, then cooperatively
// cancels the op Task instead of letting the long dispatch run to completion.
@Test func raceStepAbortsInFlightStepWhenRunCanceled() async throws {
    let root = tempRoot()
    try writeRunState(root, runId: "cancel-race", .object([
        "id": .string("cancel-race"),
        "status": .string("canceled"),
    ]))
    let client = SwiftNativeWorkflowOrchestrationClient(
        root: root, now: { "2026-06-01T00:00:00+00:00" }, useFileLock: false)

    let reads = WorkflowCancellationReadCounter()
    let started = DispatchTime.now().uptimeNanoseconds
    // A long op; the initial canonical read detects the canceled run-state and
    // cancels this Task.sleep without waiting for a polling interval.
    let result = await client.raceStepAgainstCancelOrTimeout(
        runId: "cancel-race",
        cancellationReadObserver: { reads.record() }
    ) {
        try? await Task.sleep(nanoseconds: 3_000_000_000)
        return .object(["status": .string("succeeded")])
    }
    let elapsed = DispatchTime.now().uptimeNanoseconds - started
    guard case .canceled(let terminal) = result else {
        Issue.record("expected .canceled (watcher must preempt the in-flight op), got \(result)")
        return
    }
    // Structural guarantees: the watcher preempted the in-flight op (terminal
    // == canceled) after exactly one cancellation read. These always run.
    #expect(terminal == "canceled")
    #expect(reads.value() == 1)
    print("[workflow-cancel-race] elapsed_ms=\(elapsed / 1_000_000)")
    // The absolute wall-clock bound only proves the sleep was NOT awaited out;
    // the structural asserts above already prove preemption, so gate the numeric
    // tripwire behind NATIVE_AGENT_PERF_ASSERTS. See
    // nativeagent-hangproof-subprocess-tests.
    if ProcessInfo.processInfo.environment["NATIVE_AGENT_PERF_ASSERTS"] == "1" {
        #expect(elapsed < 400_000_000)
    }
}

// Control: a running (non-canceled) run lets the dispatch complete normally —
// the race wrapper must not spuriously cancel healthy steps.
@Test func raceStepCompletesWhenRunNotCanceled() async throws {
    let root = tempRoot()
    try writeRunState(root, runId: "running-race", .object([
        "id": .string("running-race"),
        "status": .string("running"),
    ]))
    let client = SwiftNativeWorkflowOrchestrationClient(
        root: root, now: { "2026-06-01T00:00:00+00:00" }, useFileLock: false)

    let result = await client.raceStepAgainstCancelOrTimeout(runId: "running-race") {
        .object(["status": .string("succeeded"), "id": .string("s1")])
    }
    guard case .completed(let receipt) = result else {
        Issue.record("expected .completed for a running run, got \(result)")
        return
    }
    #expect(stringField(receipt, "status") == "succeeded")
}

@Test func runningWorkflowCancellationObserverDoesNotPollWhileIdle() async throws {
    let root = tempRoot()
    try writeRunState(root, runId: "idle-race", .object([
        "id": .string("idle-race"),
        "status": .string("running"),
    ]))
    let client = SwiftNativeWorkflowOrchestrationClient(root: root, useFileLock: false)
    let reads = WorkflowCancellationReadCounter()

    let result = await client.raceStepAgainstCancelOrTimeout(
        runId: "idle-race",
        cancellationReadObserver: { reads.record() }
    ) {
        try? await Task.sleep(nanoseconds: 300_000_000)
        return .object(["status": .string("succeeded")])
    }

    guard case .completed = result else {
        Issue.record("expected idle running workflow to complete, got \(result)")
        return
    }
    #expect(reads.value() == 1)
}

@Test func executeStepWithRetryEnforcesStoredTimeoutSeconds() async throws {
    let root = tempRoot()
    let client = SwiftNativeWorkflowOrchestrationClient(
        root: root,
        now: { "2026-06-01T00:00:00+00:00" },
        useFileLock: false
    )
    let workflow: JSONValue = .object(["id": .string("deadline-flow")])
    let step: JSONValue = .object([
        "id": .string("slow-step"),
        "title": .string("Slow step"),
        "kind": .string("trace"),
        "timeoutSeconds": .int(1),
    ])

    let startedNanos = DispatchTime.now().uptimeNanoseconds
    let resolution = WorkflowRaceResolutionRecorder()
    let receipt = await client.executeStepWithRetry(
        workflow: workflow,
        step: step,
        objective: "prove the deadline",
        runId: "",
        operationOverride: {
            // Deliberately ignores Task cancellation. The deadline owner must
            // return without structurally awaiting this late completion.
            await withCheckedContinuation { continuation in
                DispatchQueue.global().asyncAfter(deadline: .now() + 3) {
                    continuation.resume()
                }
            }
            return .object(["status": .string("succeeded")])
        },
        raceResolutionObserver: { resolution.record($0) }
    )

    #expect(stringField(receipt, "status") == "failed")
    #expect(stringField(receipt, "detail") == "Step timed out after 1 second.")
    #expect(stringField(receipt, "error") == "workflow step deadline exceeded")
    #expect(boolField(receipt, "timedOut") == true)
    #expect(intField(receipt, "timeoutSeconds") == 1)
    #expect(stringField(receipt, "attemptTerminality") == "unproven")
    #expect(stringField(receipt, "retryDisposition") == "suppressed_unproven_terminality")
    let attempts = try #require(arrayField(receipt, "attempts"))
    #expect(attempts.count == 1)
    #expect(stringField(attempts[0], "attemptTerminality") == "unproven")
    #expect(stringField(attempts[0], "retryDisposition") == "suppressed_unproven_terminality")
    let resolvedNanos = try #require(resolution.value())
    #expect(resolvedNanos >= startedNanos)
    #expect(resolvedNanos - startedNanos < 2_000_000_000)
}

@Test(
    .enabled(
        if: ProcessInfo.processInfo.environment["NATIVE_AGENT_RUN_WORKFLOW_DEADLINE_STRESS"] == "1"
    )
)
func executeStepDeadlineSurvivesSharedPoolSaturation() async throws {
    let root = tempRoot()
    let client = SwiftNativeWorkflowOrchestrationClient(
        root: root,
        now: { "2026-06-01T00:00:00+00:00" },
        useFileLock: false
    )
    let workflow: JSONValue = .object(["id": .string("deadline-stress-flow")])
    let step: JSONValue = .object([
        "id": .string("saturated-step"),
        "title": .string("Saturated step"),
        "kind": .string("trace"),
        "timeoutSeconds": .int(1),
    ])
    let probe = WorkflowPoolSaturationProbe()
    let resolution = WorkflowRaceResolutionRecorder()
    let startedNanos = DispatchTime.now().uptimeNanoseconds
    let saturationDuration: UInt64 = 3_000_000_000
    let workerPairs = min(
        64,
        max(8, ProcessInfo.processInfo.activeProcessorCount * 2)
    )

    let receipt = await client.executeStepWithRetry(
        workflow: workflow,
        step: step,
        objective: "prove the deadline under shared-pool saturation",
        runId: "",
        operationOverride: {
            let loadStarted = DispatchTime.now().uptimeNanoseconds
            let (loadDeadline, overflow) = loadStarted
                .addingReportingOverflow(saturationDuration)
            let saturationUntil = overflow ? UInt64.max : loadDeadline
            for _ in 0..<workerPairs {
                _ = Task.detached(priority: .high) {
                    probe.run(until: saturationUntil)
                }
                DispatchQueue.global(qos: .userInitiated).async {
                    probe.run(until: saturationUntil)
                }
            }
            try? await Task.sleep(nanoseconds: 5_000_000_000)
            return .object(["status": .string("succeeded")])
        },
        raceResolutionObserver: {
            resolution.record($0, activeWorkers: probe.activeCount())
        }
    )

    #expect(stringField(receipt, "status") == "failed")
    #expect(boolField(receipt, "timedOut") == true)
    let resolvedNanos = try #require(resolution.value())
    #expect(resolvedNanos >= startedNanos)
    #expect(resolvedNanos - startedNanos < 2_000_000_000)
    let activeWorkers = try #require(resolution.activeWorkers())
    #expect(activeWorkers > 0)

    // The stress proof is opt-in, but it must not leave synthetic load behind
    // when a developer runs additional focused tests in the same process.
    while probe.activeCount() > 0 {
        try? await Task.sleep(nanoseconds: 25_000_000)
    }
}

@Test func timedOutAttemptSuppressesRetryWhenTerminalityIsUnproven() async throws {
    let root = tempRoot()
    let client = SwiftNativeWorkflowOrchestrationClient(
        root: root,
        now: { "2026-06-01T00:00:00+00:00" },
        useFileLock: false
    )
    let step: JSONValue = .object([
        "id": .string("retry-timeout"),
        "title": .string("Retry timeout"),
        "kind": .string("trace"),
        "timeoutSeconds": .int(1),
        "retry": .object(["maxAttempts": .int(2)]),
    ])

    let receipt = await client.executeStepWithRetry(
        workflow: .object(["id": .string("deadline-flow")]),
        step: step,
        objective: "do not overlap an unproven timed-out attempt",
        runId: "",
        operationOverride: {
            return .object([
                "id": .string("retry-timeout"),
                "status": .string("succeeded"),
                "detail": .string("retry completed"),
            ])
        },
        raceOverride: { attempt, timeoutSeconds, operation in
            if attempt == 1 { return .timedOut(timeoutSeconds) }
            return .completed(await operation())
        }
    )

    #expect(stringField(receipt, "status") == "failed")
    #expect(stringField(receipt, "attemptTerminality") == "unproven")
    #expect(stringField(receipt, "retryDisposition") == "suppressed_unproven_terminality")
    let attempts = try #require(arrayField(receipt, "attempts"))
    #expect(attempts.count == 1)
    #expect(stringField(attempts[0], "status") == "failed")
    #expect(stringField(attempts[0], "detail") == "Step timed out after 1 second.")
    #expect(stringField(attempts[0], "attemptTerminality") == "unproven")
    #expect(stringField(attempts[0], "retryDisposition") == "suppressed_unproven_terminality")
}

@Test func uncooperativeTimedOutAttemptNeverOverlapsRetryDispatch() async throws {
    let root = tempRoot()
    let client = SwiftNativeWorkflowOrchestrationClient(
        root: root,
        now: { "2026-06-01T00:00:00+00:00" },
        useFileLock: false
    )
    let probe = WorkflowUncooperativeAttemptProbe()
    defer { probe.releaseAll() }
    let step: JSONValue = .object([
        "id": .string("uncooperative-timeout"),
        "title": .string("Uncooperative timeout"),
        "kind": .string("trace"),
        "timeoutSeconds": .int(1),
        "retry": .object(["maxAttempts": .int(3)]),
    ])

    let receipt = await client.executeStepWithRetry(
        workflow: .object(["id": .string("deadline-flow")]),
        step: step,
        objective: "never overlap timed-out side effects",
        runId: "",
        operationOverride: {
            await probe.run()
            return .object([
                "id": .string("uncooperative-timeout"),
                "status": .string("failed"),
                "detail": .string("late attempt returned"),
            ])
        },
        raceOverride: { attempt, timeoutSeconds, operation in
            if attempt == 1 {
                _ = Task { _ = await operation() }
                while probe.snapshot().dispatches == 0 {
                    await Task.yield()
                }
                return .timedOut(timeoutSeconds)
            }
            return .completed(await operation())
        }
    )

    let whileTimedOut = probe.snapshot()
    #expect(whileTimedOut.dispatches == 1)
    #expect(whileTimedOut.active == 1)
    #expect(stringField(receipt, "status") == "failed")
    #expect(stringField(receipt, "attemptTerminality") == "unproven")
    #expect(stringField(receipt, "retryDisposition") == "suppressed_unproven_terminality")
    #expect(arrayField(receipt, "attempts")?.count == 1)

    probe.releaseAll()
    for _ in 0..<100 {
        if probe.snapshot().active == 0 { break }
        try? await Task.sleep(nanoseconds: 5_000_000)
    }
    let settled = probe.snapshot()
    #expect(settled.active == 0)
    #expect(settled.dispatches == 1)
}

// MARK: - Shared motor-tissue projection

@Test func workflowMotorProjectionExposesExactActiveDeadlineAndOpaqueCancellation() async throws {
    let root = tempRoot()
    defer { try? FileManager.default.removeItem(at: root) }
    let runId = "private-workflow-run"
    try writeRegistry(root, [
        .object([
            "id": .string("private-workflow"),
            "name": .string("Private workflow title"),
            "status": .string("active"),
            "steps": .array([
                .object([
                    "id": .string("private-step"),
                    "title": .string("Private step title"),
                    "kind": .string("trace"),
                    // The definition may be edited after dispatch; the motor
                    // view must use the run-owned attempt snapshot below.
                    "timeoutSeconds": .int(99),
                ]),
            ]),
        ]),
    ])
    try writeRunState(root, runId: runId, .object([
        "id": .string(runId),
        "workflowId": .string("private-workflow"),
        "objective": .string("Private objective"),
        "status": .string("running"),
        "mode": .string("execute"),
        "currentStepIndex": .int(0),
        "activeStepTimeoutSeconds": .int(37),
        "updatedAt": .string("2026-07-12T12:00:00Z"),
    ]))
    let client = SwiftNativeWorkflowOrchestrationClient(root: root, useFileLock: false)

    let model = try #require(try await client.motorActionReadModel(actionId: runId))
    #expect(model.domain == "workflow_orchestration")
    #expect(model.phase == .running)
    #expect(model.domainState == "running")
    #expect(model.verification == .notStarted)
    #expect(model.expectedNextEvidence == "step_or_terminal_outcome")
    #expect(model.actionIdentity == CausalTransitionEvidence.opaqueIdentity(runId))
    #expect(model.cancellationIdentity == CausalTransitionEvidence.opaqueIdentity(runId))
    #expect(model.deadline == MotorActionDeadlineReadModel(scope: .stepAttempt, timeoutSeconds: 37))

    let encoded = String(decoding: try JSONEncoder().encode(model), as: UTF8.self)
    #expect(!encoded.contains(runId))
    #expect(!encoded.contains("private-workflow"))
    #expect(!encoded.contains("Private"))
    #expect(!encoded.contains("private-step"))
}

@Test func workflowMotorProjectionPreservesApprovalAndTerminalTruth() async throws {
    let root = tempRoot()
    defer { try? FileManager.default.removeItem(at: root) }
    let runId = "workflow-terminal-private"
    let client = SwiftNativeWorkflowOrchestrationClient(root: root, useFileLock: false)

    try writeRunState(root, runId: runId, .object([
        "id": .string(runId),
        "status": .string("waiting_approval"),
        "approvalId": .string("private-approval"),
        "updatedAt": .string("2026-07-12T12:01:00Z"),
    ]))
    let waiting = try #require(try await client.motorActionReadModel(actionId: runId))
    #expect(waiting.phase == .awaitingApproval)
    #expect(waiting.verification == .notStarted)
    #expect(waiting.expectedNextEvidence == "approval_resolution")
    #expect(waiting.deadline == nil)

    try writeRunState(root, runId: runId, .object([
        "id": .string(runId),
        "status": .string("succeeded"),
        "mode": .string("execute"),
        "completedAt": .string("2026-07-12T12:02:00Z"),
    ]))
    let succeeded = try #require(try await client.motorActionReadModel(actionId: runId))
    #expect(succeeded.phase == .succeeded)
    #expect(succeeded.verification == .unverified)
    #expect(succeeded.expectedNextEvidence == "domain_verification")
    #expect(succeeded.phase.isTerminal)

    try writeRunState(root, runId: runId, .object([
        "id": .string(runId),
        "status": .string("canceled"),
        "completedAt": .string("2026-07-12T12:03:00Z"),
    ]))
    let cancelled = try #require(try await client.motorActionReadModel(actionId: runId))
    #expect(cancelled.phase == .cancelled)
    #expect(cancelled.verification == .notRequired)
    #expect(cancelled.expectedNextEvidence == nil)
    #expect(cancelled.phase.isTerminal)

    try writeRunState(root, runId: runId, .object([
        "id": .string(runId),
        "status": .string("future_domain_state"),
        "updatedAt": .string("2026-07-12T12:04:00Z"),
    ]))
    let unknown = try #require(try await client.motorActionReadModel(actionId: runId))
    #expect(unknown.phase == .unknown)
    #expect(unknown.verification == .unknown)
    #expect(!unknown.phase.isTerminal)

    let encoded = String(decoding: try JSONEncoder().encode([waiting, succeeded, cancelled, unknown]), as: UTF8.self)
    #expect(!encoded.contains(runId))
    #expect(!encoded.contains("private-approval"))
}

@Test func workflowMotorProjectionReadsV1DryRunWithoutInventingVerification() async throws {
    let root = tempRoot()
    defer { try? FileManager.default.removeItem(at: root) }
    let runId = "private-v1-dry-run"
    try appendRun(root, .object([
        "id": .string(runId),
        "workflowId": .string("private-workflow"),
        "objective": .string("Private dry-run objective"),
        "status": .string("succeeded"),
        "mode": .string("dry_run"),
        "createdAt": .string("2026-07-12T12:04:00Z"),
        "completedAt": .string("2026-07-12T12:04:01Z"),
    ]))
    let client = SwiftNativeWorkflowOrchestrationClient(root: root, useFileLock: false)

    let model = try #require(try await client.motorActionReadModel(actionId: runId))
    #expect(model.phase == .succeeded)
    #expect(model.verification == .notRequired)
    #expect(model.deadline == nil)
    #expect(model.updatedAt == "2026-07-12T12:04:01Z")
    #expect(try await client.motorActionReadModel(actionId: "missing-run") == nil)

    let encoded = String(decoding: try JSONEncoder().encode(model), as: UTF8.self)
    #expect(!encoded.contains(runId))
    #expect(!encoded.contains("Private"))
}

@Test func workflowMotorProjectionFailsLoudWhenAuthoritativeV2StateIsCorrupt() async throws {
    let root = tempRoot()
    defer { try? FileManager.default.removeItem(at: root) }
    let runId = "corrupt-v2-private"
    try appendRun(root, .object([
        "id": .string(runId),
        "status": .string("succeeded"),
        "mode": .string("dry_run"),
    ]))
    let stateURL = root
        .appendingPathComponent("workflows/run_state", isDirectory: true)
        .appendingPathComponent("\(WorkflowRunState.slugify(runId)).json")
    try FileManager.default.createDirectory(
        at: stateURL.deletingLastPathComponent(),
        withIntermediateDirectories: true
    )
    try Data("not-json".utf8).write(to: stateURL)
    let client = SwiftNativeWorkflowOrchestrationClient(root: root, useFileLock: false)

    await #expect(throws: WorkflowOrchestrationError.self) {
        _ = try await client.motorActionReadModel(actionId: runId)
    }
}
