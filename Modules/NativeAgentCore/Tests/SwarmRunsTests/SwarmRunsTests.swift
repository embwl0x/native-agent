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

private final class MixedSwarmLLM: LLMClient, @unchecked Sendable {
    struct Down: Error {}

    func complete(prompt: String, system: String?, model: String?) async throws -> String {
        if model == "bad-model" { throw Down() }
        return "completed by \(model ?? "default")"
    }

    func complete(prompt: String, system: String?, model: String?, surface: String) async throws -> String {
        try await complete(prompt: prompt, system: system, model: model)
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

@Test func agentSwarmRequest_malformedExplicitWorkersNeverLaunchDefaultOrPartialSwarm() async throws {
    let llm = RecordingSwarmLLM()
    let runner = RecordingSwarmWorkerRunner()
    let executor = SwiftNativeAgentSwarmExecutor(llm: llm, workerRunner: runner)
    let malformed: [JSONValue] = [
        .object(["role": .string("intended single worker")]), .string("not an array"),
        .array([.bool(false)]), .array([.null]), .array([.string(" \n ")]),
        .array([.object(["role": .string("first")]), .int(3), .object(["role": .string("third")])]),
    ]
    for workers in malformed {
        do {
            _ = try await executor.runTool(input: [
                "objective": .string("Do only the specified worker jobs"),
                "access": .string("inherit"), "agents": workers,
            ], policy: AgentSwarmPolicy(storeReceipts: false))
            Issue.record("malformed explicit workers must fail before any execution")
        } catch AgentSwarmError.invalidRequest(let reason) {
            #expect(reason.contains("worker"))
        }
    }
    #expect(llm.prompts.isEmpty)
    #expect(await runner.calls.isEmpty)
}

@Test func agentSwarmRequest_invalidExplicitAccessNeverSubstitutesDefaultMode() async throws {
    let llm = RecordingSwarmLLM()
    let runner = RecordingSwarmWorkerRunner()
    let executor = SwiftNativeAgentSwarmExecutor(llm: llm, workerRunner: runner)
    let malformed: [[String: JSONValue]] = [
        ["access": .string("inherited")], ["access": .int(1)],
        ["access": .null, "workerAccess": .bool(false)],
        ["access": .string("inherit"), "agents": .array([.object(["access": .string("read_onyl")])])],
        ["access": .string("inherit"), "agents": .array([.object(["access": .array([])])])],
    ]
    for fields in malformed {
        do {
            _ = try await executor.runTool(input: fields.merging(["objective": .string("Execute the exact requested capability mode")]) { first, _ in first },
                                           policy: AgentSwarmPolicy(storeReceipts: false))
            Issue.record("invalid explicit access must not silently select another capability mode")
        } catch AgentSwarmError.invalidRequest(let reason) {
            #expect(reason.contains("access"))
        }
    }
    #expect(llm.prompts.isEmpty)
    #expect(await runner.calls.isEmpty)
}

@Test func agentSwarmRequest_malformedMissionAndContextNeverStartAnyWorker() async throws {
    let llm = RecordingSwarmLLM()
    let runner = RecordingSwarmWorkerRunner()
    let executor = SwiftNativeAgentSwarmExecutor(llm: llm, workerRunner: runner)
    let fields = ["prompt", "lensBrief", "lens_brief", "instructions", "contextSlice", "context_slice", "context"]
    for field in fields {
        for malformed in [JSONValue.bool(false), .int(2), .array([.string("explicit constraint")]), .object(["constraint": .string("inspect only")])] {
            // A valid higher-precedence alias cannot hide malformed supplied
            // context/instructions, and a prior valid worker cannot run alone.
            var worker: [String: JSONValue] = ["prompt": .string("valid brief"), "contextSlice": .string("valid context")]
            worker[field] = malformed
            do {
                _ = try await executor.runTool(input: [
                    "objective": .string("Honor every supplied worker constraint"), "access": .string("inherit"),
                    "agents": .array([.object(["role": .string("valid first worker")]), .object(worker)]),
                ], policy: AgentSwarmPolicy(storeReceipts: false))
                Issue.record("malformed explicit mission/context must not execute")
            } catch AgentSwarmError.invalidRequest(let reason) {
                #expect(reason.contains("worker 2"))
                #expect(reason.contains("field '\(field)'"))
                #expect(reason.contains("No workers were started"))
            }
        }
    }
    #expect(llm.prompts.isEmpty)
    #expect(await runner.calls.isEmpty)
}

@Test func agentSwarmRequest_workerTextPlaceholdersAndAliasPrecedenceStayIntact() throws {
    let request = try AgentSwarmRunRequest.parse(input: [
        "objective": .string("Retain explicit text references"),
        "agents": .array([
            .object(["prompt": .null, "lensBrief": .string(" \n"), "lens_brief": .string(" inspect exact file "),
                     "instructions": .string("later alias remains lower precedence"),
                     "contextSlice": .string(""), "context_slice": .null,
                     "context": .string(" file: /fixture/report.txt\nconstraint: preserve bytes ")]),
            .object(["prompt": .string("first brief"), "instructions": .null,
                     "contextSlice": .string("first context"), "context": .string("later context")]),
            .object(["prompt": .null, "context": .string(" \n ")]),
            .object([:]),
        ]),
    ], policy: AgentSwarmPolicy(storeReceipts: false))
    #expect(request.workers[0].prompt == "inspect exact file")
    #expect(request.workers[0].contextSlice == "file: /fixture/report.txt\nconstraint: preserve bytes")
    #expect(request.workers[1].prompt == "first brief")
    #expect(request.workers[1].contextSlice == "first context")
    #expect(request.workers[2].prompt.isEmpty && request.workers[2].contextSlice == nil)
    #expect(request.workers[3].prompt.isEmpty && request.workers[3].contextSlice == nil)
    #expect(request.workers.allSatisfy { $0.access == "read_only" })
}

@Test func agentSwarmRequest_optionalPlaceholdersDoNotHideLaterWorkerOrAccessAliases() throws {
    let policy = AgentSwarmPolicy(storeReceipts: false)
    let request = try AgentSwarmRunRequest.parse(input: [
        "objective": .string("Respect the populated compatibility worker list"),
        "agents": .null, "workers": .array([]),
        "roles": .array([
            .string("legacy role"), .object([:]),
            .object(["access": .string(""), "workerAccess": .string("read-only")]),
            .object(["access": .null, "readOnly": .null, "read_only": .bool(false)]),
        ]),
        "access": .null, "workerAccess": .string(" tools "), "agentCount": .int(9),
    ], policy: policy)
    #expect(request.workers.count == 4)
    #expect(request.workers[0].role == "legacy role")
    #expect(request.workers[1].role == "independent analyst 2")
    #expect(request.workers.map(\.access) == ["inherit", "inherit", "read_only", "inherit"])
    let defaults = try AgentSwarmRunRequest.parse(input: [
        "objective": .string("Keep ordinary empty defaults"),
        "agents": .array([]), "workers": .null, "roles": .array([]),
        "access": .string(" "), "readOnly": .null, "agentCount": .int(2),
    ], policy: policy)
    #expect(defaults.workers.count == 2)
    #expect(defaults.workers.allSatisfy { $0.access == "read_only" })
    for access in ["inherit", "auto", "tools", "tool_capable", "tool-capable", "workspace", "full"] {
        let inherited = try AgentSwarmRunRequest.parse(input: ["objective": .string("Keep existing admitted modes"), "access": .string(access)], policy: policy)
        #expect(inherited.workers.allSatisfy { $0.access == "inherit" })
    }
    for access in ["read_only", "readonly", "read-only", "reasoning"] {
        let readonly = try AgentSwarmRunRequest.parse(input: ["objective": .string("Keep existing prompt-only modes"), "access": .string(access)], policy: policy)
        #expect(readonly.workers.allSatisfy { $0.access == "read_only" })
    }
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

@Test func swiftAgentSwarmExecutor_mixedWorkersReportPartialThroughRunLedger() async throws {
    let root = FileManager.default.temporaryDirectory
        .appendingPathComponent("swarm-partial-\(UUID().uuidString)", isDirectory: true)
    let swarmDir = root.appendingPathComponent("swarms", isDirectory: true)
    try FileManager.default.createDirectory(at: swarmDir, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: root) }

    let executor = SwiftNativeAgentSwarmExecutor(
        llm: MixedSwarmLLM(),
        runsPath: swarmDir.appendingPathComponent("runs.json"),
        runLedgerDataRoot: root
    )
    let out = try await executor.runTool(
        input: [
            "objective": .string("mixed fan-out"),
            "agents": .array([
                .object(["role": .string("healthy"), "model": .string("good-model")]),
                .object(["role": .string("broken"), "model": .string("bad-model")]),
            ]),
            "synthesize": .bool(false),
        ],
        policy: AgentSwarmPolicy(maxAgents: 20, storeReceipts: true)
    )
    guard case .object(let obj) = out,
          case .object(let summary)? = obj["summary"] else {
        Issue.record("expected partial swarm run object")
        return
    }
    #expect(obj["status"] == .string("partial"))
    #expect(summary["completed"] == .int(1))
    #expect(summary["failed"] == .int(1))

    let ledgerPath = root
        .appendingPathComponent("runs", isDirectory: true)
        .appendingPathComponent("runs.json")
    let ledger = await SwiftNativePersistenceCore().readJSON(
        ledgerPath, defaultValue: .array([])
    )
    guard case .array(let rows) = ledger,
          case .object(let row)? = rows.first else {
        Issue.record("expected partial cross-surface run ledger row")
        return
    }
    #expect(row["status"] == .string("partial"))
    #expect(row["error"] == .string("1 of 2 worker(s) failed"))
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
    let second = try await executor.runTool(
        input: ["objective": .string("append next receipt"), "agentCount": .int(1), "synthesize": .bool(false)],
        policy: AgentSwarmPolicy(storeReceipts: true)
    )
    #expect(SwarmRunsStore.load(path: runsPath).runs == [second, out])
}

@Test func swiftAgentSwarmExecutor_preservesUnavailableReceiptStoreAfterWorkersSettle() async throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent("swarm-preserve-\(UUID().uuidString)")
    let directory = root.appendingPathComponent("swarms")
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: root) }
    let path = directory.appendingPathComponent("runs.json")
    let llm = RecordingSwarmLLM()
    let executor = SwiftNativeAgentSwarmExecutor(llm: llm, runsPath: path)
    func runExpectingUnavailable(_ reason: String) async throws {
        let before = llm.prompts.count
        do {
            _ = try await executor.runTool(
                input: ["objective": .string("inert receipt preservation fixture"), "agentCount": .int(1), "synthesize": .bool(false)],
                policy: AgentSwarmPolicy(storeReceipts: true)
            )
            Issue.record("unavailable existing receipt storage must not be reset")
        } catch let failure as AgentSwarmReceiptPersistenceError {
            guard case PersistenceCoreError.ioFailure(let message) = failure.underlyingError else {
                Issue.record("original checked-read error must be retained"); return
            }
            #expect(message.contains("(\(reason))"))
            #expect(message.contains("Workers have already settled"))
        }
        #expect(llm.prompts.count == before + 1)
        #expect(!FileManager.default.fileExists(atPath: root.appendingPathComponent("runs/runs.json").path))
    }
    for bytes in [Data(), Data("{invalid".utf8), Data("null".utf8), Data("{\"runs\":[]}".utf8)] {
        try bytes.write(to: path)
        try await runExpectingUnavailable("malformed")
        #expect(try Data(contentsOf: path) == bytes)
    }
    try FileManager.default.removeItem(at: path)
    try FileManager.default.createDirectory(at: path, withIntermediateDirectories: true)
    let marker = path.appendingPathComponent("preserve-marker")
    let markerBytes = Data("existing evidence".utf8)
    try markerBytes.write(to: marker)
    try await runExpectingUnavailable("not_a_file")
    #expect(try Data(contentsOf: marker) == markerBytes)
    try FileManager.default.removeItem(at: path)
    let unavailableTarget = directory.appendingPathComponent("missing-target")
    try FileManager.default.createSymbolicLink(at: path, withDestinationURL: unavailableTarget)
    try await runExpectingUnavailable("unreadable")
    #expect(try FileManager.default.destinationOfSymbolicLink(atPath: path.path) == unavailableTarget.path)
    #expect(!FileManager.default.fileExists(atPath: unavailableTarget.path))
}
