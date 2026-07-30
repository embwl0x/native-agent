import Testing
import Foundation
@testable import SwarmRuns
import NativeAgentCore
import PersistenceCore

// MARK: - Helpers

private func obj(_ pairs: [String: JSONValue]) -> JSONValue { .object(pairs) }

private func run(_ id: String, _ createdAt: JSONValue) -> JSONValue {
    obj(["id": .string(id), "createdAt": createdAt])
}

private func ids(_ vals: [JSONValue]) -> [String] {
    vals.compactMap { v in
        if case .object(let o) = v, case .string(let id)? = o["id"] { return id }
        return nil
    }
}

/// Write a JSON document to a temp file and return its URL (caller cleans up).
private func writeTemp(_ value: Any) throws -> URL {
    let dir = FileManager.default.temporaryDirectory
        .appendingPathComponent("swarmruns-tests-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    let url = dir.appendingPathComponent("runs.json")
    let data = try JSONSerialization.data(withJSONObject: value, options: [])
    try data.write(to: url)
    return url
}

// MARK: - Store: sort + slice

@Test func listSwarms_sortsByCreatedAtDescending() {
    let store = SwarmRunsStore(runs: [
        run("a", .string("2026-06-01T10:00:00Z")),
        run("b", .string("2026-06-01T12:00:00Z")),
        run("c", .string("2026-06-01T11:00:00Z")),
    ])
    // Descending createdAt -> b (12), c (11), a (10).
    #expect(ids(store.listAgentSwarms()) == ["b", "c", "a"])
}

@Test func listSwarms_stableTieBreakPreservesInsertionOrder() {
    // Equal createdAt -> Python's stable reverse sort keeps original (file) order.
    let store = SwarmRunsStore(runs: [
        run("first", .string("2026-06-01T10:00:00Z")),
        run("second", .string("2026-06-01T10:00:00Z")),
        run("third", .string("2026-06-01T10:00:00Z")),
    ])
    #expect(ids(store.listAgentSwarms()) == ["first", "second", "third"])
}

@Test func listSwarms_mixedTiesAndOrdering() {
    let store = SwarmRunsStore(runs: [
        run("x", .string("2026-06-01T09:00:00Z")),
        run("y", .string("2026-06-01T12:00:00Z")),
        run("z", .string("2026-06-01T12:00:00Z")),  // ties with y, comes after
        run("w", .string("2026-06-01T11:00:00Z")),
    ])
    // 12:y, 12:z (stable), 11:w, 09:x
    #expect(ids(store.listAgentSwarms()) == ["y", "z", "w", "x"])
}

@Test func listSwarms_sliceCapDefaultIs50() {
    let many = (0..<60).map { i in
        // Strictly descending ISO timestamps so order is deterministic.
        run("r\(String(format: "%02d", i))", .string("2026-06-01T\(String(format: "%02d", 59 - i)):00:00Z"))
    }
    let store = SwarmRunsStore(runs: many)
    let out = store.listAgentSwarms()  // default limit 50
    #expect(out.count == 50)
}

@Test func listSwarms_sliceCapClampsToMax200() {
    let store = SwarmRunsStore(runs: (0..<10).map { run("r\($0)", .string("2026-06-01T00:00:0\($0)Z")) })
    // limit far above 200 clamps to min(limit,200)=200, but only 10 exist -> 10.
    #expect(store.listAgentSwarms(limit: 5000).count == 10)
}

@Test func listSwarms_sliceCapClampsToMin1() {
    let store = SwarmRunsStore(runs: [
        run("a", .string("2026-06-01T10:00:00Z")),
        run("b", .string("2026-06-01T11:00:00Z")),
    ])
    // limit 0 -> max(1, min(0,200)) = 1 ; limit -5 -> max(1, min(-5,200)) = 1.
    #expect(ids(store.listAgentSwarms(limit: 0)) == ["b"])
    #expect(ids(store.listAgentSwarms(limit: -5)) == ["b"])
}

@Test func listSwarms_exactCap200() {
    let store = SwarmRunsStore(runs: (0..<210).map { i in
        run("r\(i)", .string(String(format: "2026-06-01T%02d:%02d:00Z", i / 60, i % 60)))
    })
    #expect(store.listAgentSwarms(limit: 200).count == 200)
    #expect(store.listAgentSwarms(limit: 199).count == 199)
}

// MARK: - Store: createdAt coercion (Python `str(x or "")`)

@Test func listSwarms_falsyAndMissingCreatedAtCoalesceToEmpty() {
    // Records with missing / null / "" createdAt all sort to the "" bucket,
    // which is < any non-empty ISO string, so they land LAST (descending),
    // preserving insertion order among themselves (stable).
    let store = SwarmRunsStore(runs: [
        run("hasDate", .string("2026-06-01T10:00:00Z")),
        obj(["id": .string("missing")]),              // no createdAt key
        run("nullDate", .null),                        // null
        run("emptyStr", .string("")),                  // ""
        run("zeroInt", .int(0)),                       // 0 -> falsy -> ""
        run("falseBool", .bool(false)),                // False -> falsy -> ""
    ])
    let out = ids(store.listAgentSwarms())
    #expect(out.first == "hasDate")
    // The five empty-key records keep insertion order after hasDate.
    #expect(out == ["hasDate", "missing", "nullDate", "emptyStr", "zeroInt", "falseBool"])
}

@Test func listSwarms_nonDictElementCoercesToEmptyKey() {
    // A non-object element cannot answer Python's .get; we defensively coerce its
    // sort key to "" rather than crashing. It sorts into the empty bucket.
    let store = SwarmRunsStore(runs: [
        run("withDate", .string("2026-06-01T10:00:00Z")),
        .string("loose-string"),
        .int(42),
    ])
    let out = store.listAgentSwarms()
    #expect(out.count == 3)
    // withDate (non-empty key) is first; the two scalars follow in order.
    if case .object(let o)? = out.first, case .string(let id)? = o["id"] {
        #expect(id == "withDate")
    } else {
        Issue.record("expected first element to be the withDate object")
    }
}

// MARK: - Store: load from disk

@Test func load_missingFileReturnsEmpty() {
    let url = FileManager.default.temporaryDirectory
        .appendingPathComponent("does-not-exist-\(UUID().uuidString)/runs.json")
    let store = SwarmRunsStore.load(path: url)
    #expect(store.runs.isEmpty)
    #expect(store.listAgentSwarms().isEmpty)
}

@Test func load_nonArrayDocumentReturnsEmpty() throws {
    // The Python guard `if not isinstance(runs, list): return []` collapses an
    // object/scalar top-level doc to [].
    let url = try writeTemp(["status": "ready", "runs": []] as [String: Any])
    defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
    let store = SwarmRunsStore.load(path: url)
    #expect(store.runs.isEmpty)
}

@Test func load_arrayDocumentRoundTrips() throws {
    let url = try writeTemp([
        ["id": "a", "createdAt": "2026-06-01T10:00:00Z"],
        ["id": "b", "createdAt": "2026-06-01T12:00:00Z"],
    ])
    defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
    let store = SwarmRunsStore.load(path: url)
    #expect(store.runs.count == 2)
    #expect(ids(store.listAgentSwarms()) == ["b", "a"])
}

@Test func load_malformedJsonReturnsEmpty() throws {
    let dir = FileManager.default.temporaryDirectory
        .appendingPathComponent("swarmruns-bad-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: dir) }
    let url = dir.appendingPathComponent("runs.json")
    try Data("{ not valid json".utf8).write(to: url)
    #expect(SwarmRunsStore.load(path: url).runs.isEmpty)
}

// MARK: - Reader: envelope + factory gate

@Test func swiftNativeReader_emitsRouteEnvelope() async throws {
    let url = try writeTemp([
        ["id": "a", "createdAt": "2026-06-01T10:00:00Z"],
        ["id": "b", "createdAt": "2026-06-01T12:00:00Z"],
    ])
    defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
    let reader = SwiftNativeSwarmRunsReader(runsPath: url)
    guard case .object(let env)? = await reader.listSwarms(limit: 50) else {
        Issue.record("expected an object envelope"); return
    }
    #expect(env["status"] == .string("ready"))
    if case .array(let runs)? = env["runs"] {
        #expect(ids(runs) == ["b", "a"])
    } else {
        Issue.record("expected runs array")
    }
    // createdAt mirrors the daemon's now_iso() shape: UTC, microsecond fraction,
    // "+00:00" offset (NOT a bare 'Z'), e.g. "2026-06-01T17:08:42.123456+00:00".
    if case .string(let ts)? = env["createdAt"] {
        #expect(ts.hasSuffix("+00:00"))
        #expect(ts.contains("T"))
        #expect(ts.contains("."))   // fractional-seconds component present
    } else {
        Issue.record("expected createdAt string")
    }
}

@Test func factory_returnsSwiftNative() {
    let reader = makeSwarmRunsReader(runsPath: URL(fileURLWithPath: "/tmp/x/runs.json"))
    #expect(reader is SwiftNativeSwarmRunsReader)
}

@Test func factory_returnsSwiftNativeWhenNoPath() {
    let reader = makeSwarmRunsReader()
    #expect(reader is SwiftNativeSwarmRunsReader)
}

@Test func protocolDefaultLimit_matchesRouteDefaultOf50() async throws {
    // A caller holding `any SwarmRunsReader` can call listSwarms() with no
    // arg and get the route's limit=50 default (protocol-extension convenience).
    let many = (0..<60).map { i in
        run("r\(String(format: "%02d", i))", .string("2026-06-01T\(String(format: "%02d", 59 - i)):00:00Z"))
    }
    let url = try writeTemp(many.map { v -> [String: Any] in
        if case .object(let o) = v,
           case .string(let id)? = o["id"],
           case .string(let ca)? = o["createdAt"] {
            return ["id": id, "createdAt": ca]
        }
        return [:]
    })
    defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
    let reader: any SwarmRunsReader = SwiftNativeSwarmRunsReader(runsPath: url)
    guard case .object(let env)? = await reader.listSwarms(),  // no explicit limit
          case .array(let runs)? = env["runs"] else {
        Issue.record("expected runs array"); return
    }
    #expect(runs.count == 50)
}

@Test func codePointSort_matchesPythonForNonAscii() {
    // Python str `>` compares by code point; the highest code-point key sorts
    // FIRST under reverse=True. "é" (U+00E9) > "z" (U+007A) by code point, so a
    // record keyed "é..." outranks one keyed "z..." — Swift's default String
    // collation would order them the other way.
    let store = SwarmRunsStore(runs: [
        run("ascii", .string("z2026")),
        run("accent", .string("é2026")),
    ])
    // Highest code point first under reverse: accent (U+00E9) then ascii (U+007A).
    #expect(ids(store.listAgentSwarms()) == ["accent", "ascii"])
}

@Test func codePointSort_prefixShorterSortsLast() {
    // "2026-06-01T10:00:00Z" vs its prefix "2026-06-01T10:00:00" — Python str
    // comparison treats the longer (extended) string as greater, so it sorts
    // first under reverse=True.
    let store = SwarmRunsStore(runs: [
        run("short", .string("2026-06-01T10:00:00")),
        run("long", .string("2026-06-01T10:00:00Z")),
    ])
    #expect(ids(store.listAgentSwarms()) == ["long", "short"])
}

@Test func defaultPath_endsWithSwarmsRunsJson() {
    let p = SwiftNativeSwarmRunsReader.defaultPath()
    #expect(p.lastPathComponent == "runs.json")
    #expect(p.deletingLastPathComponent().lastPathComponent == "swarms")
}

// MARK: - Swift-native execute path

private final class RecordingSwarmLLM: LLMClient, @unchecked Sendable {
    private let queue = DispatchQueue(label: "RecordingSwarmLLM")
    private var _models: [String?] = []
    private var _surfaces: [String] = []
    private var _prompts: [String] = []

    var models: [String?] { queue.sync { _models } }
    var surfaces: [String] { queue.sync { _surfaces } }
    var prompts: [String] { queue.sync { _prompts } }

    func complete(prompt: String, system: String?, model: String?) async throws -> String {
        queue.sync {
            _models.append(model)
            _surfaces.append("chat")
            _prompts.append(prompt)
        }
        return prompt.contains("SYNTHESIS:") ? "synthesis for \(model ?? "nil")" : "worker for \(model ?? "nil")"
    }

    func complete(prompt: String, system: String?, model: String?, surface: String) async throws -> String {
        queue.sync {
            _models.append(model)
            _surfaces.append(surface)
            _prompts.append(prompt)
        }
        return prompt.contains("SYNTHESIS:") ? "synthesis for \(model ?? "nil")" : "worker for \(model ?? "nil")"
    }
}

@Test func agentSwarmRequest_rejectsMoreThanHardCap() async throws {
    do {
        _ = try AgentSwarmRunRequest.parse(
            input: [
                "objective": .string("review this"),
                "agentCount": .int(21),
            ],
            policy: AgentSwarmPolicy(maxAgents: 20)
        )
        Issue.record("expected policyDenied for 21 workers")
    } catch AgentSwarmError.policyDenied(let message) {
        #expect(message.contains("21"))
        #expect(message.contains("20"))
    } catch {
        Issue.record("wrong error: \(error)")
    }
}

@Test func agentSwarmDryRun_allowsTwentyWorkersWithoutCallingLLM() async throws {
    let llm = RecordingSwarmLLM()
    let executor = SwiftNativeAgentSwarmExecutor(llm: llm)
    let out = try await executor.runTool(
        input: [
            "objective": .string("fan out"),
            "agentCount": .int(20),
            "dryRun": .bool(true),
            "model": .string("gpt-5.5"),
        ],
        policy: AgentSwarmPolicy(maxAgents: 20, storeReceipts: false)
    )
    guard case .object(let obj) = out,
          case .array(let workers)? = obj["workers"] else {
        Issue.record("expected dry-run worker plan")
        return
    }
    #expect(obj["status"] == .string("dry_run"))
    #expect(workers.count == 20)
    #expect(llm.models.isEmpty)
}

@Test func swiftAgentSwarmExecutor_routesPerWorkerModelsOnSwarmsSurface() async throws {
    let llm = RecordingSwarmLLM()
    let executor = SwiftNativeAgentSwarmExecutor(llm: llm)
    let out = try await executor.runTool(
        input: [
            "objective": .string("compare approaches"),
            "agents": .array([
                .object([
                    "name": .string("openai-seat"),
                    "role": .string("planner"),
                    "model": .string("gpt-5.5"),
                ]),
                .object([
                    "name": .string("anthropic-seat"),
                    "role": .string("critic"),
                    "model": .string("claude-opus-4-8"),
                ]),
            ]),
            "synthesize": .bool(false),
            "maxParallel": .int(2),
        ],
        policy: AgentSwarmPolicy(maxAgents: 20, storeReceipts: false)
    )
    guard case .object(let obj) = out,
          case .array(let workers)? = obj["workers"] else {
        Issue.record("expected completed swarm object")
        return
    }
    #expect(obj["status"] == .string("completed"))
    #expect(workers.count == 2)
    #expect(Set(llm.models.compactMap { $0 }) == Set(["gpt-5.5", "claude-opus-4-8"]))
    #expect(llm.surfaces == ["swarms", "swarms"])
}

private final class FailingSwarmLLM: LLMClient, @unchecked Sendable {
    struct Down: Error {}

    func complete(prompt: String, system: String?, model: String?) async throws -> String {
        throw Down()
    }

    func complete(prompt: String, system: String?, model: String?, surface: String) async throws -> String {
        throw Down()
    }
}

private actor RecordingSwarmWorkerRunner: AgentSwarmWorkerRunning {
    private(set) var calls: [(
        model: String,
        effort: String,
        access: String,
        prompt: String,
        originSurface: String,
        originSessionId: String?
    )] = []

    func runWorker(
        prompt: String,
        model: String,
        reasoningEffort: String,
        access: String,
        originSurface: String,
        originSessionId: String?
    ) async throws -> String {
        calls.append((model, reasoningEffort, access, prompt, originSurface, originSessionId))
        return "tool-capable worker"
    }
}

@Test func agentSwarmRequest_defaultsReadOnly_butSupportsPerWorkerInheritedAccess() throws {
    let request = try AgentSwarmRunRequest.parse(
        input: [
            "objective": .string("inspect and repair"),
            "agents": .array([
                .object(["role": .string("inspect")]),
                .object(["role": .string("repair"), "access": .string("inherit")]),
            ]),
        ],
        policy: AgentSwarmPolicy(storeReceipts: false)
    )
    #expect(request.readOnly == false)
    #expect(request.workers.map(\.access) == ["read_only", "inherit"])
}

@Test func swiftAgentSwarmExecutor_usesEphemeralRunnerOnlyForInheritedWorkers() async throws {
    let llm = RecordingSwarmLLM()
    let runner = RecordingSwarmWorkerRunner()
    let executor = SwiftNativeAgentSwarmExecutor(
        llm: llm,
        workerRunner: runner
    )
    let out = try await executor.runTool(
        input: [
            "objective": .string("inspect and repair"),
            "surface": .string("telegram"),
            "__session_id": .string("telegram:123"),
            "agents": .array([
                .object(["role": .string("inspect"), "access": .string("read_only")]),
                .object(["role": .string("repair"), "access": .string("inherit")]),
            ]),
            "synthesize": .bool(false),
        ],
        policy: AgentSwarmPolicy(storeReceipts: false)
    )

    guard case .object(let object) = out,
          case .array(let workers)? = object["workers"] else {
        Issue.record("expected swarm workers")
        return
    }
    #expect(object["access"] == .string("mixed"))
    #expect(llm.models.count == 1)
    let calls = await runner.calls
    #expect(calls.count == 1)
    #expect(calls.first?.access == "inherit")
    #expect(calls.first?.originSurface == "telegram")
    #expect(calls.first?.originSessionId == "telegram:123")
    let accesses: [JSONValue] = workers.compactMap { worker -> JSONValue? in
        guard case .object(let row) = worker else { return nil }
        return row["access"]
    }
    #expect(accesses == [JSONValue.string("read_only"), JSONValue.string("inherit")])
}

@Test func swiftAgentSwarmExecutor_inheritedWorkerFailsHonestlyWithoutToolRunner() async throws {
    let executor = SwiftNativeAgentSwarmExecutor(llm: RecordingSwarmLLM())
    let out = try await executor.runTool(
        input: [
            "objective": .string("write a file"),
            "agentCount": .int(1),
            "access": .string("inherit"),
            "synthesize": .bool(false),
        ],
        policy: AgentSwarmPolicy(storeReceipts: false)
    )
    guard case .object(let object) = out,
          case .array(let workers)? = object["workers"],
          case .object(let worker)? = workers.first else {
        Issue.record("expected failed worker receipt")
        return
    }
    #expect(object["status"] == .string("failed"))
    #expect(worker["status"] == .string("failed"))
    guard case .string(let error)? = worker["error"] else {
        Issue.record("expected worker error")
        return
    }
    #expect(error.contains("unavailable"))
}

@Test func swiftAgentSwarmExecutor_allWorkersFailed_reportsFailedStatus() async throws {
    let executor = SwiftNativeAgentSwarmExecutor(llm: FailingSwarmLLM())
    let out = try await executor.runTool(
        input: [
            "objective": .string("doomed fan-out"),
            "agentCount": .int(2),
            "synthesize": .bool(false),
        ],
        policy: AgentSwarmPolicy(maxAgents: 20, storeReceipts: false)
    )
    guard case .object(let obj) = out,
          case .object(let summary)? = obj["summary"] else {
        Issue.record("expected swarm run object with summary")
        return
    }
    #expect(obj["status"] == .string("failed"))
    #expect(summary["completed"] == .int(0))
    #expect(summary["failed"] == .int(2))
}

@Test func swiftAgentSwarmExecutor_persistsRunReceipt() async throws {
    let dir = FileManager.default.temporaryDirectory
        .appendingPathComponent("swarm-exec-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: dir) }
    let runsPath = dir.appendingPathComponent("runs.json")
    let llm = RecordingSwarmLLM()
    let executor = SwiftNativeAgentSwarmExecutor(llm: llm, runsPath: runsPath)
    let out = try await executor.runTool(
        input: [
            "objective": .string("persist me"),
            "agentCount": .int(2),
            "synthesize": .bool(false),
        ],
        policy: AgentSwarmPolicy(maxAgents: 20, storeReceipts: true)
    )
    guard case .object(let obj) = out,
          case .string(let runID)? = obj["id"] else {
        Issue.record("expected run id")
        return
    }
    let stored = SwarmRunsStore.load(path: runsPath)
    #expect(stored.runs.count == 1)
    guard case .object(let first)? = stored.runs.first else {
        Issue.record("stored record not object")
        return
    }
    #expect(first["id"] == .string(runID))
    #expect(first["runtime"] == .string("swift-native"))
    #expect(first["surface"] == .string("swarms"))
}
