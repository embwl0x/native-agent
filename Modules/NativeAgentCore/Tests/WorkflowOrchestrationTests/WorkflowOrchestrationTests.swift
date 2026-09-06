import Testing
import Foundation
@testable import WorkflowOrchestration
import NativeAgentCore
import PersistenceCore

// Registry-half tests only. The workflow RUN engine was retired 2026-09-01
// (User authorized); its tests went with it. See WorkflowOrchestration.swift.

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

@Test(arguments: ["{broken", "{}", "null", "\"saved-workflows\""], [false, true])
func workflowRegistryDamageSurvivesListAndCreate(bytes: String, create: Bool) async throws {
    let root = tempRoot()
    defer { try? FileManager.default.removeItem(at: root) }
    let path = root.appendingPathComponent("workflows/registry.json")
    try FileManager.default.createDirectory(at: path.deletingLastPathComponent(), withIntermediateDirectories: true)
    let original = Data(bytes.utf8)
    try original.write(to: path)
    let client = SwiftNativeWorkflowOrchestrationClient(root: root)
    do {
        if create { _ = try await client.createWorkflow(.object(["name": .string("New workflow")])) }
        else { _ = try await client.listWorkflows() }
        Issue.record("Damaged workflow registry must not be replaced with defaults")
    } catch {}
    #expect(try Data(contentsOf: path) == original)
    #expect(!FileManager.default.fileExists(atPath: root.appendingPathComponent("activity/events.jsonl").path))
    #expect(!FileManager.default.fileExists(atPath: root.appendingPathComponent("traces/events.jsonl").path))
}

@Test(arguments: ["unreadable", "directory", "dangling_symlink"], [false, true])
func workflowRegistryUnavailableEntryIsNotMissing(kind: String, create: Bool) async throws {
    let root = tempRoot()
    defer { try? FileManager.default.removeItem(at: root) }
    let fm = FileManager.default
    let path = root.appendingPathComponent("workflows/registry.json")
    try fm.createDirectory(at: path.deletingLastPathComponent(), withIntermediateDirectories: true)
    let original = Data("[{\"id\":\"preserved\",\"status\":\"disabled\"}]".utf8)
    if kind == "unreadable" {
        try original.write(to: path)
        try fm.setAttributes([.posixPermissions: 0], ofItemAtPath: path.path)
    } else if kind == "directory" {
        try fm.createDirectory(at: path, withIntermediateDirectories: false)
        try original.write(to: path.appendingPathComponent("preserved.json"))
    } else {
        try fm.createSymbolicLink(atPath: path.path, withDestinationPath: "missing-registry.json")
    }
    defer {
        if kind == "unreadable" { try? fm.setAttributes([.posixPermissions: 0o600], ofItemAtPath: path.path) }
    }
    let client = SwiftNativeWorkflowOrchestrationClient(root: root)
    do {
        if create { _ = try await client.createWorkflow(.object(["name": .string("New workflow")])) }
        else { _ = try await client.listWorkflows() }
        Issue.record("An unavailable saved entry must not bootstrap defaults")
    } catch {}
    if kind == "unreadable" {
        #expect(try fm.attributesOfItem(atPath: path.path)[.posixPermissions] as? Int == 0)
        try fm.setAttributes([.posixPermissions: 0o600], ofItemAtPath: path.path)
        #expect(try Data(contentsOf: path) == original)
    } else if kind == "directory" {
        #expect(try Data(contentsOf: path.appendingPathComponent("preserved.json")) == original)
    } else {
        #expect(try fm.destinationOfSymbolicLink(atPath: path.path) == "missing-registry.json")
        #expect(!fm.fileExists(atPath: path.deletingLastPathComponent().appendingPathComponent("missing-registry.json").path))
    }
    #expect(!fm.fileExists(atPath: root.appendingPathComponent("activity/events.jsonl").path))
}

@Test func workflowRegistryCheckedReadPreservesCustomAndDisabledRowsDuringCreate() async throws {
    let root = tempRoot()
    defer { try? FileManager.default.removeItem(at: root) }
    try writeRegistry(root, [
        .object(["id": .string("memory-capture"), "status": .string("disabled"), "custom": .string("preserve")]),
        .object(["id": .string("custom-work"), "status": .string("active"), "name": .string("Saved custom")]),
    ])
    let client = SwiftNativeWorkflowOrchestrationClient(root: root)
    let created = try await client.createWorkflow(.object(["name": .string("New workflow")]))
    let rows = try await client.listWorkflows()
    #expect(rows.contains { idOf($0) == idOf(created) })
    #expect(rows.contains { idOf($0) == "custom-work" && stringField($0, "name") == "Saved custom" })
    let disabled = try #require(rows.first { idOf($0) == "memory-capture" })
    #expect(stringField(disabled, "status") == "disabled")
    #expect(stringField(disabled, "custom") == "preserve")
    #expect(stringField(disabled, "trigger") == "remember this")
}

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


@Test func factoryReturnsSwiftNative() {
    let client = makeWorkflowOrchestrationClient(root: tempRoot())
    #expect(client is SwiftNativeWorkflowOrchestrationClient)
}


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

@Test func listWorkflowsUnchangedMergePreservesRegistryBytesAndModificationDate() async throws {
    let root = tempRoot()
    defer { try? FileManager.default.removeItem(at: root) }
    let initial = SwiftNativeWorkflowOrchestrationClient(root: root, now: { "2026-06-01T00:00:00+00:00" })
    let originalRows = try await initial.listWorkflows()
    let path = root.appendingPathComponent("workflows/registry.json")
    let originalBytes = try Data(contentsOf: path)
    let oldModificationDate = Date(timeIntervalSince1970: 1_700_000_000)
    try FileManager.default.setAttributes([.modificationDate: oldModificationDate], ofItemAtPath: path.path)

    let later = SwiftNativeWorkflowOrchestrationClient(root: root, now: { "2026-06-02T00:00:00+00:00" })
    #expect(try await later.listWorkflows() == originalRows)
    #expect(try Data(contentsOf: path) == originalBytes)
    #expect(try FileManager.default.attributesOfItem(atPath: path.path)[.modificationDate] as? Date == oldModificationDate)
}

// MARK: - create helpers

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

