import Testing
import Foundation
@testable import WorkshopExecution
import NativeAgentCore
import PersistenceCore
import ProviderRouting
import NativeAgentTestSupport

// MARK: - Helpers

private func makeTempRoot() throws -> URL {
    let dir = FileManager.default.temporaryDirectory
        .appendingPathComponent("WorkshopExecutionsTests-\(UUID().uuidString)")
    try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    return dir
}

// Non-throwing variant for inline use at `SwiftNativeWorkshopRunner(root:)`
// sites (U5 W-F test hermeticity). The runner's `root:` parameter defaults to
// `PersistenceCore.defaultDataRoot()` — the LIVE app data root under
// `swift test` — so any root-less construction whose `planWorkshopExecution`/run path
// touches `<root>/missions/...` pollutes live data. Pinning every site to a
// fresh temp dir makes the suite hermetic by construction.
private func hermeticWorkshopExecutionRoot() -> URL {
    let dir = FileManager.default.temporaryDirectory
        .appendingPathComponent("WorkshopExecutionsTests-\(UUID().uuidString)")
    try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    return dir
}

private func obj(_ v: JSONValue) -> [String: JSONValue]? {
    if case .object(let o) = v { return o }
    return nil
}
private func str(_ v: JSONValue?) -> String? {
    if case .string(let s) = v ?? .null { return s }
    return nil
}

@Test func workshopPlannerAlternateRootDoesNotInheritProcessCredentials() throws {
    let root = try makeTempRoot()
    defer { try? FileManager.default.removeItem(at: root) }
    let canonical = root.appendingPathComponent("canonical", isDirectory: true)
    let environment = SwiftNativeWorkshopPlannerLLM.codexEnvironment(
        dataRoot: root,
        processEnvironment: [
            "PATH": "/usr/bin:/bin",
            "LANG": "en_US.UTF-8",
            "HOME": "/Users/private",
            "OPENAI_API_KEY": "must-not-cross-root",
            "ANTHROPIC_API_KEY": "must-not-cross-root",
            "NATIVE_AGENT_PERSONA_ROOT": "/private/persona"
        ],
        defaultDataRoot: canonical
    )

    #expect(environment["PATH"] == "/usr/bin:/bin")
    #expect(environment["LANG"] == "en_US.UTF-8")
    #expect(environment["HOME"] == root.appendingPathComponent("codex_home").path)
    #expect(environment["CODEX_HOME"] == root.appendingPathComponent("codex_home").path)
    #expect(environment["NATIVE_AGENT_DATA_ROOT"] == root.standardizedFileURL.path)
    #expect(environment["OPENAI_API_KEY"] == nil)
    #expect(environment["ANTHROPIC_API_KEY"] == nil)
    #expect(environment["NATIVE_AGENT_PERSONA_ROOT"] == nil)
}

@Test func workshopPlannerCanonicalRootPreservesProductionEnvironment() throws {
    let root = try makeTempRoot()
    defer { try? FileManager.default.removeItem(at: root) }
    let environment = SwiftNativeWorkshopPlannerLLM.codexEnvironment(
        dataRoot: root,
        processEnvironment: [
            "PATH": "/usr/bin:/bin",
            "OPENAI_API_KEY": "production-key",
            "HOME": "/Users/production"
        ],
        defaultDataRoot: root
    )

    #expect(environment["OPENAI_API_KEY"] == "production-key")
    #expect(environment["HOME"] == "/Users/production")
    #expect(environment["CODEX_HOME"] == root.appendingPathComponent("codex_home").path)
    #expect(environment["NATIVE_AGENT_DATA_ROOT"] == root.standardizedFileURL.path)
}

// Recording planner with injectable runCodex closure + fixed connector actions.
private final class RecordingWorkshopPlannerLLM: WorkshopPlannerLLM, @unchecked Sendable {
    let directProviderCallCountPerInvocation: Int? = 1
    let actions: [JSONValue]
    let codex: @Sendable (String) async throws -> (String, String)
    init(
        actions: [JSONValue] = [],
        codex: @escaping @Sendable (String) async throws -> (String, String)
    ) {
        self.actions = actions
        self.codex = codex
    }
    func availableConnectorActions() async -> [JSONValue] { actions }
    func runCodex(prompt: String, surface: String, timeoutSeconds: Int) async throws -> (model: String, output: String) {
        return try await codex(prompt)
    }
}

private final class ThrowingWorkshopPlannerLLM: WorkshopPlannerLLM, @unchecked Sendable {
    let directProviderCallCountPerInvocation: Int? = 1
    func availableConnectorActions() async -> [JSONValue] { [] }
    func runCodex(prompt: String, surface: String, timeoutSeconds: Int) async throws -> (model: String, output: String) {
        throw WorkshopExecutionError.plannerFailure("boom")
    }
}

// Order-recording persistence wrapper. Delegates to a real SwiftNativePersistenceCore
// but appends each call name (with the file's last path component) to a recorder
// before delegation. NOT a SwiftNativePersistenceCore subclass, so the runner's
// withFileLock branch is bypassed — we record raw call order through the protocol.
private actor CallRecorder {
    var calls: [String] = []
    func append(_ s: String) { calls.append(s) }
    func snapshot() -> [String] { calls }
}

private final class RecordingPersistence: PersistenceCoreProtocol, @unchecked Sendable {
    let recorder: CallRecorder
    let inner = SwiftNativePersistenceCore()
    init(recorder: CallRecorder) { self.recorder = recorder }

    func readJSON(_ path: URL, defaultValue: JSONValue) async -> JSONValue {
        await recorder.append("readJSON:\(path.lastPathComponent)")
        return await inner.readJSON(path, defaultValue: defaultValue)
    }
    func writeJSON(_ value: JSONValue, to path: URL) async throws {
        await recorder.append("writeJSON:\(path.lastPathComponent)")
        try await inner.writeJSON(value, to: path)
    }
    func appendJSONL(_ record: JSONValue, to path: URL) async throws {
        await recorder.append("appendJSONL:\(path.lastPathComponent)")
        try await inner.appendJSONL(record, to: path)
    }
    func tailJSONL(_ path: URL, limit: Int, maxBytes: Int?) async throws -> [JSONValue] {
        try await inner.tailJSONL(path, limit: limit, maxBytes: maxBytes)
    }
    func readJSONL(_ path: URL) async throws -> [JSONValue] {
        try await inner.readJSONL(path)
    }
}

private func fixedNow() -> @Sendable () -> Date {
    let d = Date(timeIntervalSince1970: 1_700_000_000)
    return { d }
}
private func fixedUUID(_ s: String = "11111111-1111-1111-1111-111111111111") -> @Sendable () -> String {
    return { s }
}

// MARK: - Stub fallback fast paths

@Suite("SwiftNativeWorkshopRunner: planWorkshopExecution stub fallback")
struct StubFallbackSuite {
    @Test func autonomyDisabledReturnsStub() async throws {
        let runner = SwiftNativeWorkshopRunner(executorAvailable: true, root: hermeticWorkshopExecutionRoot(),
            planner: RecordingWorkshopPlannerLLM { _ in ("m", "{\"steps\":[]}") },
            enableAutonomy: false
        )
        let plan = try await runner.planWorkshopExecution(spec: WorkshopExecutionSpec(title: "T", objective: "O"))
        #expect(plan.fromStub == true)
        #expect(plan.steps.count == 2)
        #expect(plan.steps[0].id == "step-plan")
        #expect(plan.steps[1].id == "step-report")
        // Byte-for-byte prompt parity.
        guard case .object(let a0) = plan.steps[0].args, case .string(let p0) = a0["prompt"] ?? .null else {
            Issue.record("step-plan args.prompt missing"); return
        }
        #expect(p0 == "Given this objective: O\n\nProduce a brief action plan.")
        guard case .object(let a1) = plan.steps[1].args, case .string(let p1) = a1["prompt"] ?? .null else {
            Issue.record("step-report args.prompt missing"); return
        }
        #expect(p1 == "Summarize the outcome for: O")
    }

    @Test func plannerThrowsReturnsStub() async throws {
        let runner = SwiftNativeWorkshopRunner(executorAvailable: true, root: hermeticWorkshopExecutionRoot(), planner: ThrowingWorkshopPlannerLLM())
        let plan = try await runner.planWorkshopExecution(spec: WorkshopExecutionSpec(title: "T", objective: "O"))
        #expect(plan.fromStub == true)
        #expect(plan.steps.count == 2)
    }

    @Test func plannerReturnsZeroValidStepsReturnsStub() async throws {
        let runner = SwiftNativeWorkshopRunner(executorAvailable: true, root: hermeticWorkshopExecutionRoot(), planner: RecordingWorkshopPlannerLLM { _ in ("m", "{\"steps\":[]}") })
        let plan = try await runner.planWorkshopExecution(spec: WorkshopExecutionSpec(title: "T", objective: "O"))
        #expect(plan.fromStub == true)
    }

    @Test func plannerReturnsNonObjectReturnsStub() async throws {
        let runner = SwiftNativeWorkshopRunner(executorAvailable: true, root: hermeticWorkshopExecutionRoot(), planner: RecordingWorkshopPlannerLLM { _ in ("m", "not json") })
        let plan = try await runner.planWorkshopExecution(spec: WorkshopExecutionSpec(title: "T", objective: "O"))
        #expect(plan.fromStub == true)
    }

    @Test func plannerReturnsMissingStepsKeyReturnsStub() async throws {
        let runner = SwiftNativeWorkshopRunner(executorAvailable: true, root: hermeticWorkshopExecutionRoot(), planner: RecordingWorkshopPlannerLLM { _ in ("m", "{\"foo\":1}") })
        let plan = try await runner.planWorkshopExecution(spec: WorkshopExecutionSpec(title: "T", objective: "O"))
        #expect(plan.fromStub == true)
    }
}

// MARK: - planWorkshopExecution happy paths

@Suite("SwiftNativeWorkshopRunner: planWorkshopExecution happy path")
struct PlanHappyPathSuite {
    @Test func plannerReturns3StepsAreValidated() async throws {
        let output = """
        {"steps":[
          {"id":"a","description":"da","tool_or_action":"chat.synthesize","args":{"prompt":"x"},"autonomy_hint":"auto"},
          {"id":"b","description":"db","tool_or_action":"chat.synthesize","args":{"prompt":"y"},"autonomy_hint":"needs_approval"},
          {"id":"c","description":"dc","tool_or_action":"chat.synthesize","args":{"prompt":"z"},"autonomy_hint":"auto"}
        ]}
        """
        let runner = SwiftNativeWorkshopRunner(executorAvailable: true, root: hermeticWorkshopExecutionRoot(), planner: RecordingWorkshopPlannerLLM { _ in ("m", output) })
        let plan = try await runner.planWorkshopExecution(spec: WorkshopExecutionSpec(title: "T", objective: "O"))
        #expect(plan.fromStub == false)
        #expect(plan.steps.count == 3)
        #expect(plan.steps.map(\.id) == ["a", "b", "c"])
        #expect(plan.steps[0].autonomy == "auto")
        #expect(plan.steps[1].autonomy == "needs_approval")
    }

    @Test func unknownToolFallsBackToChatSynthesize() async throws {
        let output = """
        {"steps":[{"id":"x","description":"d","tool_or_action":"unknown.tool","args":{},"autonomy_hint":"auto"}]}
        """
        let runner = SwiftNativeWorkshopRunner(executorAvailable: true, root: hermeticWorkshopExecutionRoot(), planner: RecordingWorkshopPlannerLLM { _ in ("m", output) })
        let plan = try await runner.planWorkshopExecution(spec: WorkshopExecutionSpec(title: "T", objective: "O"))
        #expect(plan.fromStub == false)
        #expect(plan.steps.count == 1)
        #expect(plan.steps[0].toolOrAction == "chat.synthesize")
    }

    @Test func autonomyHintInvalidClampsToAuto() async throws {
        let output = """
        {"steps":[{"id":"x","description":"d","tool_or_action":"chat.synthesize","args":{},"autonomy_hint":"YOLO"}]}
        """
        let runner = SwiftNativeWorkshopRunner(executorAvailable: true, root: hermeticWorkshopExecutionRoot(), planner: RecordingWorkshopPlannerLLM { _ in ("m", output) })
        let plan = try await runner.planWorkshopExecution(spec: WorkshopExecutionSpec(title: "T", objective: "O"))
        #expect(plan.steps[0].autonomy == "auto")
    }

    @Test func moreThan8StepsTruncatesTo8() async throws {
        var steps: [String] = []
        for i in 0..<12 {
            steps.append("{\"id\":\"s\(i)\",\"description\":\"d\",\"tool_or_action\":\"chat.synthesize\",\"args\":{},\"autonomy_hint\":\"auto\"}")
        }
        let output = "{\"steps\":[\(steps.joined(separator: ","))]}"
        let runner = SwiftNativeWorkshopRunner(executorAvailable: true, root: hermeticWorkshopExecutionRoot(), planner: RecordingWorkshopPlannerLLM { _ in ("m", output) })
        let plan = try await runner.planWorkshopExecution(spec: WorkshopExecutionSpec(title: "T", objective: "O"))
        #expect(plan.steps.count == 8)
    }

    @Test func markdownFencesStripped() async throws {
        let output = """
        ```json
        {"steps":[{"id":"x","description":"d","tool_or_action":"chat.synthesize","args":{},"autonomy_hint":"auto"}]}
        ```
        """
        let runner = SwiftNativeWorkshopRunner(executorAvailable: true, root: hermeticWorkshopExecutionRoot(), planner: RecordingWorkshopPlannerLLM { _ in ("m", output) })
        let plan = try await runner.planWorkshopExecution(spec: WorkshopExecutionSpec(title: "T", objective: "O"))
        #expect(plan.fromStub == false)
        #expect(plan.steps.count == 1)
    }

    @Test func connectorActionsIncludedInValidToolSet() async throws {
        let actions: [JSONValue] = [
            .object([
                "id": .string("gh.list_repos"),
                "description": .string("List GitHub repos"),
            ]),
        ]
        let output = """
        {"steps":[{"id":"x","description":"d","tool_or_action":"gh.list_repos","args":{},"autonomy_hint":"auto"}]}
        """
        let runner = SwiftNativeWorkshopRunner(executorAvailable: true, root: hermeticWorkshopExecutionRoot(),
            planner: RecordingWorkshopPlannerLLM(actions: actions) { _ in ("m", output) }
        )
        let plan = try await runner.planWorkshopExecution(spec: WorkshopExecutionSpec(title: "T", objective: "O"))
        #expect(plan.fromStub == false)
        #expect(plan.steps[0].toolOrAction == "gh.list_repos")
    }
}

// MARK: - submit

@Suite("SwiftNativeWorkshopRunner: submit")
struct SubmitSuite {
    @Test func submitWritesTimelineBeforeWorkshopExecutionJSON() async throws {
        let root = try makeTempRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let recorder = CallRecorder()
        let persistence = RecordingPersistence(recorder: recorder)
        let runner = SwiftNativeWorkshopRunner(executorAvailable: true,
            root: root,
            persistence: persistence,
            planner: ThrowingWorkshopPlannerLLM(),
            now: fixedNow(),
            uuid: fixedUUID()
        )
        _ = try await runner.submit(spec: WorkshopExecutionSpec(title: "T", objective: "O"))
        let calls = await recorder.snapshot()
        let appendIdx = calls.firstIndex(where: { $0.hasPrefix("appendJSONL:timeline.jsonl") })
        let writeIdx = calls.firstIndex(where: { $0.hasPrefix("writeJSON:mission.json") })
        #expect(appendIdx != nil)
        #expect(writeIdx != nil)
        if let a = appendIdx, let w = writeIdx {
            #expect(a < w, "timeline.jsonl must be appended BEFORE mission.json is written (wave-12 finding #4)")
        }
    }

    @Test func submitRoundTrip() async throws {
        let root = try makeTempRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let runner = SwiftNativeWorkshopRunner(executorAvailable: true,
            root: root,
            planner: ThrowingWorkshopPlannerLLM(),
            now: fixedNow(),
            uuid: fixedUUID()
        )
        let result = try await runner.submit(spec: WorkshopExecutionSpec(
            title: "Title",
            objective: "Obj",
            triggerSource: "trigger:morning_brief",
            trustRequired: "draft_auto"
        ))
        #expect(result.status == "queued")
        #expect(!result.executionId.isEmpty)

        let path = runner.executionRecordPath(result.executionId)
        let data = try Data(contentsOf: path)
        let parsed = try JSONValue.parse(data)
        guard case .object(let o) = parsed else { Issue.record("mission.json not object"); return }
        #expect(str(o["status"]) == "queued")
        #expect(str(o["trigger_source"]) == "trigger:morning_brief")
        #expect(str(o["trust_required"]) == "draft_auto")
        #expect(o["result"] == .null)
        #expect(o["rerun_count"] == .int(0))
        #expect(o["expected_outputs"] == .array([]))
        #expect(o["steps_completed"] == .array([]))
        #expect(o["planning_provider_call_count"] == .int(1))
        #expect(o["planning_removable_orchestration_provider_call_count"] == .int(1))
        #expect(str(o["current_step_id"]) == "")
        #expect(str(o["receipts_dir"])?.isEmpty == false)
        if case .array(let arr) = o["plan"] ?? .null {
            #expect(!arr.isEmpty)
        } else {
            Issue.record("plan not array")
        }
    }

    @Test func autonomyDisabledPersistsProvenZeroPlanningCalls() async throws {
        let root = try makeTempRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let runner = SwiftNativeWorkshopRunner(
            executorAvailable: true,
            root: root,
            planner: RecordingWorkshopPlannerLLM { _ in
                Issue.record("disabled autonomy must not call the planner")
                return ("unexpected", "{}")
            },
            enableAutonomy: false,
            now: fixedNow(),
            uuid: fixedUUID("22222222-2222-2222-2222-222222222222")
        )
        let result = try await runner.submit(spec: WorkshopExecutionSpec(title: "T", objective: "O"))
        #expect(result.record.planningProviderCallCount == 0)
        #expect(result.record.planningRemovableOrchestrationProviderCallCount == 0)
        let reread = try #require(await runner.getWorkshopExecution(result.executionId))
        #expect(reread.planningProviderCallCount == 0)
        #expect(reread.planningRemovableOrchestrationProviderCallCount == 0)
    }

    @Test func submitWithEmptyObjectiveThrows() async throws {
        let root = try makeTempRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let runner = SwiftNativeWorkshopRunner(executorAvailable: true, root: root, planner: ThrowingWorkshopPlannerLLM())
        do {
            _ = try await runner.submit(spec: WorkshopExecutionSpec(title: "T", objective: "   "))
            Issue.record("expected throw for empty objective")
        } catch let e as WorkshopExecutionError {
            #expect(e == .invalidRequest("missing_objective"))
        }
    }

    @Test func submitTruncatesTitleAndObjective() async throws {
        let root = try makeTempRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let runner = SwiftNativeWorkshopRunner(executorAvailable: true, root: root, planner: ThrowingWorkshopPlannerLLM())
        let bigTitle = String(repeating: "T", count: 500)
        let bigObjective = String(repeating: "O", count: 5000)
        let result = try await runner.submit(spec: WorkshopExecutionSpec(title: bigTitle, objective: bigObjective))
        #expect(result.record.title.count == 160)
        #expect(result.record.objective.count == 2000)
        // Verify on disk too.
        let data = try Data(contentsOf: runner.executionRecordPath(result.executionId))
        guard case .object(let o) = try JSONValue.parse(data) else {
            Issue.record("not object"); return
        }
        #expect(str(o["title"])?.count == 160)
        #expect(str(o["objective"])?.count == 2000)
    }

    @Test func submitCreatesReceiptsDir() async throws {
        let root = try makeTempRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let runner = SwiftNativeWorkshopRunner(executorAvailable: true, root: root, planner: ThrowingWorkshopPlannerLLM())
        let result = try await runner.submit(spec: WorkshopExecutionSpec(title: "T", objective: "O"))
        let receipts = runner.receiptsDir(result.executionId)
        var isDir: ObjCBool = false
        let exists = FileManager.default.fileExists(atPath: receipts.path, isDirectory: &isDir)
        #expect(exists)
        #expect(isDir.boolValue)
    }

    @Test func timelineJSONLContainsEnqueuedEvent() async throws {
        let root = try makeTempRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let runner = SwiftNativeWorkshopRunner(executorAvailable: true,
            root: root,
            planner: ThrowingWorkshopPlannerLLM(),
            now: fixedNow(),
            uuid: fixedUUID()
        )
        let result = try await runner.submit(spec: WorkshopExecutionSpec(
            title: "MyTitle",
            objective: "MyObj",
            triggerSource: "manual"
        ))
        let timeline = runner.timelinePath(result.executionId)
        let data = try Data(contentsOf: timeline)
        guard let s = String(data: data, encoding: .utf8) else {
            Issue.record("timeline not utf8"); return
        }
        // ThrowingWorkshopPlannerLLM triggers a planner_fallback event before the
        // enqueued event (wave-21 review FIX #3). Find the enqueued line.
        let lines = s.split(separator: "\n").map(String.init).filter { !$0.isEmpty }
        let enqueuedLine = try #require(lines.first(where: { $0.contains("\"enqueued\"") }))
        let parsed = try JSONValue.parse(Data(enqueuedLine.utf8))
        guard case .object(let o) = parsed else { Issue.record("enqueued line not object"); return }
        #expect(str(o["event"]) == "enqueued")
        #expect(str(o["title"]) == "MyTitle")
        #expect(str(o["trigger_source"]) == "manual")
        // ISO-8601-ish — contains a 'T' and ends with offset or Z.
        if let ts = str(o["ts"]) {
            #expect(ts.contains("T"))
        } else {
            Issue.record("ts missing")
        }
    }
}

// MARK: - Concurrency

@Suite("SwiftNativeWorkshopRunner: concurrency")
struct ConcurrencySuite {
    @Test func concurrentSubmitDifferentWorkshopExecutions() async throws {
        let root = try makeTempRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let runner = SwiftNativeWorkshopRunner(executorAvailable: true, root: root, planner: ThrowingWorkshopPlannerLLM())
        let ids = try await withThrowingTaskGroup(of: String.self) { group -> [String] in
            for i in 0..<5 {
                group.addTask {
                    let r = try await runner.submit(spec: WorkshopExecutionSpec(title: "T\(i)", objective: "O\(i)"))
                    return r.executionId
                }
            }
            var ids: [String] = []
            for try await id in group { ids.append(id) }
            return ids
        }
        #expect(Set(ids).count == 5)
        for id in ids {
            let data = try Data(contentsOf: runner.executionRecordPath(id))
            let parsed = try JSONValue.parse(data)
            guard case .object(let o) = parsed else {
                Issue.record("execution \(id) not parseable as object"); continue
            }
            #expect(str(o["id"]) == id)
        }
    }
}

// MARK: - Factory
// Fix 8: makeWorkshopRunner() has no runtime: parameter — executions always
// proceed native. Tests updated to match the no-runtime-param signature.

@Suite("makeWorkshopRunner: factory")
struct FactorySuite {
    @Test func factoryReturnsSwiftNative() async throws {
        // Fix 8: cutover complete — factory always returns SwiftNativeWorkshopRunner.
        let runner = makeWorkshopRunner()
        #expect(runner is SwiftNativeWorkshopRunner)
    }

    @Test func factoryAlwaysProceedsNative() async throws {
        // Fix 8 rewrite of the retired external-runtime delegation path:
        // executions always proceed native now.
        let runner = makeWorkshopRunner()
        #expect(runner is SwiftNativeWorkshopRunner,
                "makeWorkshopRunner must always return SwiftNativeWorkshopRunner (cutover complete)")
    }

    @Test func factoryWiresSwiftNativeWorkshopPlannerLLM() async throws {
        // BLOCKING #1 (wave-24-amendment): the production factory path must wire
        // `SwiftNativeWorkshopPlannerLLM` (the real LLM-backed planner), NOT the
        // `StubWorkshopPlannerLLM` default that ships 2-step stub plans. Wave 24
        // was reverted because the factory was still using the stub default. This
        // test pins the production wiring so a future drift fails loud here
        // instead of silently in production.
        // Fix 8: no runtime: param.
        let runner = makeWorkshopRunner()
        guard let swiftNative = runner as? SwiftNativeWorkshopRunner else {
            Issue.record("makeWorkshopRunner did not return SwiftNativeWorkshopRunner")
            return
        }
        let plannerType = swiftNative._testPlannerTypeName
        // If this fails, production trigger fires would silently ship 2-step
        // stub plans (the wave-24 BLOCKING #1 regression).
        #expect(plannerType == "SwiftNativeWorkshopPlannerLLM")
    }

    @Test func factoryThreadsInjectedRootThroughRunnerAndPlannerLedger() throws {
        let root = try makeTempRoot().standardizedFileURL
        let runner = try #require(
            makeWorkshopRunner(dataRoot: root) as? SwiftNativeWorkshopRunner
        )

        #expect(runner.executionRecordsRoot == root
            .appendingPathComponent("workshop", isDirectory: true)
            .appendingPathComponent("executions", isDirectory: true))
        #expect(runner._testPlannerRunLedgerDataRoot?.standardizedFileURL == root)
    }
}

// MARK: - JSON shape

@Suite("WorkshopExecutionStep / WorkshopExecutionRecord: JSON shape")
struct JSONShapeSuite {
    @Test func workshopExecutionRecordToJSONHasAllPythonFields() async throws {
        let rec = WorkshopExecutionRecord(
            id: "i",
            title: "t",
            objective: "o",
            createdAt: "c",
            status: "queued",
            plan: [],
            stepsCompleted: [],
            receiptsDir: "/x",
            triggerSource: "manual",
            trustRequired: "none",
            expectedOutputs: [],
            currentStepId: "",
            updatedAt: "c",
            result: .null,
            rerunCount: 0
        )
        guard case .object(let o) = rec.toJSON() else { Issue.record("not object"); return }
        let expected: Set<String> = [
            "id", "title", "objective", "created_at", "status", "plan",
            "steps_completed", "receipts_dir", "trigger_source", "trust_required",
            "expected_outputs", "current_step_id", "updated_at", "result", "rerun_count",
        ]
        #expect(Set(o.keys) == expected)
        #expect(o.count == 15)
    }

    @Test func workshopExecutionPlanStepToJSONUsesSnakeCase() async throws {
        let step = WorkshopExecutionStep(
            id: "s1",
            description: "d",
            toolOrAction: "chat.synthesize",
            args: .object(["k": .string("v")]),
            autonomy: "auto"
        )
        guard case .object(let o) = step.toJSON() else { Issue.record("not object"); return }
        let expected: Set<String> = ["id", "description", "tool_or_action", "args", "autonomy"]
        #expect(Set(o.keys) == expected)
        #expect(str(o["tool_or_action"]) == "chat.synthesize")
        #expect(str(o["autonomy"]) == "auto")
    }
}

// MARK: - planner_fallback timeline event + parse fallbacks (wave 21 review)

@Suite("SwiftNativeWorkshopRunner: planner_fallback + parse edge cases")
struct PlannerFallbackEventSuite {
    /// FIX #3: when the planner throws, submit() MUST emit a
    /// `planner_fallback` timeline event BEFORE the `enqueued` event,
    /// byte-shape compatible with the retired daemon.
    @Test func submitEmitsPlannerFallbackBeforeEnqueuedWhenPlannerThrows() async throws {
        let root = try makeTempRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let runner = SwiftNativeWorkshopRunner(executorAvailable: true,
            root: root,
            planner: ThrowingWorkshopPlannerLLM(),
            now: fixedNow(),
            uuid: fixedUUID()
        )
        let result = try await runner.submit(spec: WorkshopExecutionSpec(title: "T", objective: "Obj"))
        let timeline = runner.timelinePath(result.executionId)
        let data = try Data(contentsOf: timeline)
        guard let s = String(data: data, encoding: .utf8) else {
            Issue.record("timeline not utf8"); return
        }
        let lines = s.split(separator: "\n").map(String.init).filter { !$0.isEmpty }
        #expect(lines.count >= 2)
        let first = try JSONValue.parse(Data(lines[0].utf8))
        let second = try JSONValue.parse(Data(lines[1].utf8))
        guard case .object(let o0) = first, case .object(let o1) = second else {
            Issue.record("non-object event lines"); return
        }
        #expect(str(o0["event"]) == "planner_fallback")
        #expect(str(o0["reason"])?.isEmpty == false)
        #expect(str(o0["ts"])?.isEmpty == false)
        #expect(str(o1["event"]) == "enqueued")
    }

    /// FIX #4 (id/description empty-string fallback): when codex returns
    /// id="" / description="", parsePlanJSON must replace them with the
    /// step-{i+1} / "Step {i+1}" defaults (Python `str(x or default)`).
    @Test func parsePlanJSONFallsBackToDefaultWhenIdOrDescEmpty() async throws {
        let output = """
        {"steps":[
          {"id":"","description":"","tool_or_action":"chat.synthesize","args":{},"autonomy_hint":"auto"},
          {"id":"   ","description":"keep","tool_or_action":"chat.synthesize","args":{},"autonomy_hint":"auto"}
        ]}
        """
        let runner = SwiftNativeWorkshopRunner(executorAvailable: true, root: hermeticWorkshopExecutionRoot(), planner: RecordingWorkshopPlannerLLM { _ in ("m", output) })
        let plan = try await runner.planWorkshopExecution(spec: WorkshopExecutionSpec(title: "T", objective: "O"))
        #expect(plan.fromStub == false)
        #expect(plan.steps.count == 2)
        // Empty id → step-1; non-empty "   " is truthy in Python → preserved verbatim.
        #expect(plan.steps[0].id == "step-1")
        #expect(plan.steps[0].description == "Step 1")
        #expect(plan.steps[1].id == "   ")
        #expect(plan.steps[1].description == "keep")
    }

    /// FIX #4 (chat.synthesize fallback when tool absent): missing tool_or_action
    /// (or non-string) should resolve to chat.synthesize.
    @Test func parsePlanJSONMissingToolFallsBackToChatSynthesize() async throws {
        let output = """
        {"steps":[{"id":"x","description":"d","args":{},"autonomy_hint":"auto"}]}
        """
        let runner = SwiftNativeWorkshopRunner(executorAvailable: true, root: hermeticWorkshopExecutionRoot(), planner: RecordingWorkshopPlannerLLM { _ in ("m", output) })
        let plan = try await runner.planWorkshopExecution(spec: WorkshopExecutionSpec(title: "T", objective: "O"))
        #expect(plan.fromStub == false)
        #expect(plan.steps[0].toolOrAction == "chat.synthesize")
    }

    /// FIX #4 (non-object args → stub fallback): Python's
    /// `dict(s.get("args") or {})` raises TypeError if args is a non-dict
    /// truthy value (e.g. a string). Cascades to the stub.
    @Test func parsePlanJSONNonObjectArgsFallsBackToStub() async throws {
        let output = """
        {"steps":[{"id":"x","description":"d","tool_or_action":"chat.synthesize","args":"oops","autonomy_hint":"auto"}]}
        """
        let runner = SwiftNativeWorkshopRunner(executorAvailable: true, root: hermeticWorkshopExecutionRoot(), planner: RecordingWorkshopPlannerLLM { _ in ("m", output) })
        let plan = try await runner.planWorkshopExecution(spec: WorkshopExecutionSpec(title: "T", objective: "O"))
        #expect(plan.fromStub == true)
        #expect(plan.steps.count == 2) // stub
    }
}

// MARK: - Stub-fallback byte-for-byte parity

@Suite("SwiftNativeWorkshopRunner: stub fallback parity with Python")
struct StubParitySuite {
    @Test func stubFallbackByteForByteMatchesPython() async throws {
        let steps = SwiftNativeWorkshopRunner.stubFallback(spec: WorkshopExecutionSpec(title: "T", objective: "O"))
        #expect(steps.count == 2)
        #expect(steps[0].id == "step-plan")
        #expect(steps[0].description == "Analyze objective and gather context")
        #expect(steps[0].toolOrAction == "chat.synthesize")
        #expect(steps[0].autonomy == "auto")
        guard case .object(let a0) = steps[0].args, case .string(let p0) = a0["prompt"] ?? .null else {
            Issue.record("step-plan args.prompt missing"); return
        }
        #expect(p0 == "Given this objective: O\n\nProduce a brief action plan.")

        #expect(steps[1].id == "step-report")
        #expect(steps[1].description == "Summarize findings")
        #expect(steps[1].toolOrAction == "chat.synthesize")
        #expect(steps[1].autonomy == "auto")
        guard case .object(let a1) = steps[1].args, case .string(let p1) = a1["prompt"] ?? .null else {
            Issue.record("step-report args.prompt missing"); return
        }
        #expect(p1 == "Summarize the outcome for: O")
    }
}

// MARK: - SwiftNativeWorkshopPlannerLLM round-trip (wave 23)

// Mock LLMClient that records the (prompt, model) it was called with
// and returns a fixed output or throws a fixed error.
private final class MockLLMClient: LLMClient, @unchecked Sendable {
    let output: String
    let throwError: Error?
    private(set) var lastPrompt: String?
    private(set) var lastModel: String?
    private(set) var callCount = 0
    init(output: String = "", throwError: Error? = nil) {
        self.output = output
        self.throwError = throwError
    }
    func complete(prompt: String, system: String?, model: String?) async throws -> String {
        self.lastPrompt = prompt
        self.lastModel = model
        self.callCount += 1
        if let e = throwError { throw e }
        return output
    }
}

// Mock router that seeds the 'executions' surface with a fixed model.
private final class MockRouter: ProviderRoutingProtocol, @unchecked Sendable {
    let surfaceModel: String
    init(surfaceModel: String) { self.surfaceModel = surfaceModel }
    func listProviders() async throws -> [Provider] { [] }
    func getProvider(id: String) async throws -> Provider { throw ProviderRoutingError.providerNotFound }
    func configureProvider(id: String, config: JSONValue) async throws -> Provider {
        throw ProviderRoutingError.providerNotFound
    }
    func testProvider(id: String) async throws -> ProviderTestResult {
        ProviderTestResult(rawResponse: .null)
    }
    func getModelPreferences() async throws -> ModelPreferences {
        throw ProviderRoutingError.unavailable
    }
    func saveModelConfig(_ body: JSONValue) async throws -> ModelPreferences {
        throw ProviderRoutingError.unavailable
    }
    func computeModelPreferences() async throws -> [String: SurfacePreference] {
        var out: [String: SurfacePreference] = [:]
        for s in MODEL_SURFACES {
            out[s] = SurfacePreference(
                surface: s,
                model: surfaceModel,
                reasoningEffort: DEFAULT_REASONING_EFFORT,
                modelKnown: nil
            )
        }
        return out
    }
}

// Slow LLM that always exceeds the timeout — used to exercise the
// withThrowingTaskGroup timeout branch.
private final class SlowLLM: LLMClient, @unchecked Sendable {
    func complete(prompt: String, system: String?, model: String?) async throws -> String {
        try await Task.sleep(nanoseconds: 5_000_000_000)
        return "too late"
    }
}

// Mock router that returns DIFFERENT models per surface so a test can prove
// production code reads the WORKSHOP surface's preference and not prefs["chat"]
// / something else. Its map is minted from MODEL_SURFACES, i.e. the CANONICAL
// vocabulary — while the caller below still passes the 0.3.x "missions". That
// mismatch is the point (P2-3).
private final class SurfaceDiscriminatingMockRouter: ProviderRoutingProtocol, @unchecked Sendable {
    func listProviders() async throws -> [Provider] { [] }
    func getProvider(id: String) async throws -> Provider { throw ProviderRoutingError.providerNotFound }
    func configureProvider(id: String, config: JSONValue) async throws -> Provider {
        throw ProviderRoutingError.providerNotFound
    }
    func testProvider(id: String) async throws -> ProviderTestResult {
        ProviderTestResult(rawResponse: .null)
    }
    func getModelPreferences() async throws -> ModelPreferences {
        throw ProviderRoutingError.unavailable
    }
    func saveModelConfig(_ body: JSONValue) async throws -> ModelPreferences {
        throw ProviderRoutingError.unavailable
    }
    func computeModelPreferences() async throws -> [String: SurfacePreference] {
        var out: [String: SurfacePreference] = [:]
        for s in MODEL_SURFACES {
            out[s] = SurfacePreference(
                surface: s,
                model: "model-for-\(s)",
                reasoningEffort: DEFAULT_REASONING_EFFORT,
                modelKnown: nil
            )
        }
        return out
    }
}

private struct WorkshopExecutionRouteRouter: ProviderRoutingProtocol {
    func listProviders() async throws -> [Provider] { [] }

    func getProvider(id: String) async throws -> Provider {
        switch id {
        case "openai":
            return Provider(
                id: id,
                modelCatalog: .array([.object(["id": .string("gpt-5.6-sol")])]),
                extras: .object(["default_model": .string("gpt-5.6-sol")])
            )
        case "anthropic":
            return Provider(
                id: id,
                modelCatalog: .array([.object(["id": .string("claude-opus-4-8")])]),
                extras: .object(["default_model": .string("claude-opus-4-8")])
            )
        default:
            throw ProviderRoutingError.providerNotFound
        }
    }

    func configureProvider(id: String, config: JSONValue) async throws -> Provider {
        throw ProviderRoutingError.invalidRequest
    }

    func testProvider(id: String) async throws -> ProviderTestResult {
        ProviderTestResult(rawResponse: .null)
    }

    func getModelPreferences() async throws -> ModelPreferences { ModelPreferences() }
    func saveModelConfig(_ body: JSONValue) async throws -> ModelPreferences { ModelPreferences() }

    func computeModelPreferences() async throws -> [String: SurfacePreference] {
        [
            "chat": SurfacePreference(
                surface: "chat",
                model: "gpt-5.6-sol",
                reasoningEffort: "max",
                serviceTier: "default"
            ),
            "missions": SurfacePreference(
                surface: "missions",
                model: "claude-opus-4-8",
                reasoningEffort: "low",
                serviceTier: "priority"
            ),
        ]
    }

    func activeProvidersForSurfaces() async -> [String: String] {
        ["chat": "openai", "missions": "anthropic"]
    }
}

private final class RotatingWorkshopRouteRouter: ProviderRoutingProtocol, @unchecked Sendable {
    private let lock = NSLock()
    private var checkedCalls = 0

    var callCount: Int {
        lock.lock(); defer { lock.unlock() }
        return checkedCalls
    }

    func listProviders() async throws -> [Provider] { [] }
    func getProvider(id: String) async throws -> Provider { throw ProviderRoutingError.providerNotFound }
    func configureProvider(id: String, config: JSONValue) async throws -> Provider {
        throw ProviderRoutingError.invalidRequest
    }
    func testProvider(id: String) async throws -> ProviderTestResult { .init(rawResponse: .null) }
    func getModelPreferences() async throws -> ModelPreferences { .init() }
    func saveModelConfig(_ body: JSONValue) async throws -> ModelPreferences { .init() }
    func computeModelPreferences() async throws -> [String: SurfacePreference] {
        fatalError("planner execution must use checkedRoutingSnapshot")
    }
    func activeProvidersForSurfaces() async -> [String: String] {
        fatalError("planner execution must use checkedRoutingSnapshot")
    }
    func checkedRoutingSnapshot() async throws -> ProviderRoutingSnapshot {
        let generation = lock.withLock {
            checkedCalls += 1
            return checkedCalls
        }
        if generation == 1 {
            return ProviderRoutingSnapshot(
                preferences: [
                    "missions": SurfacePreference(
                        surface: "missions",
                        model: "claude-opus-4-8",
                        reasoningEffort: "high",
                        serviceTier: "priority"
                    )
                ],
                activeProviders: ["missions": "anthropic"],
                pinnedModels: [:]
            )
        }
        return ProviderRoutingSnapshot(
            preferences: [
                "missions": SurfacePreference(
                    surface: "missions",
                    model: "gpt-5.6-sol",
                    reasoningEffort: "low",
                    serviceTier: "default"
                )
            ],
            activeProviders: ["missions": "openai"],
            pinnedModels: [:]
        )
    }
}

private final class WorkshopExecutionRouteRecordingAdapter: LLMAdapter, @unchecked Sendable {
    struct Call: Sendable, Equatable {
        let model: String
        let surface: String?
        let reasoningEffort: String?
        let serviceTier: String?
        let sessionId: String?
    }

    let providerId: String
    private let response: String
    private let lock = NSLock()
    private var calls: [Call] = []

    init(providerId: String, response: String) {
        self.providerId = providerId
        self.response = response
    }

    func complete(prompt: String, system: String?, model: String) async throws -> String {
        record(Call(
            model: model,
            surface: LLMCallContext.surface,
            reasoningEffort: LLMCallContext.reasoningEffort,
            serviceTier: LLMCallContext.serviceTier,
            sessionId: LLMCallContext.sessionId
        ))
        return response
    }

    private func record(_ call: Call) {
        lock.lock()
        calls.append(call)
        lock.unlock()
    }

    func snapshot() -> [Call] {
        lock.lock()
        defer { lock.unlock() }
        return calls
    }
}

@Suite("SwiftNativeWorkshopPlannerLLM: LLMClient wiring")
struct HTTPCodexPlannerLLMSuite {
    @Test func roundTripReturnsLLMOutput() async throws {
        let mock = MockLLMClient(output: "{\"steps\":[{\"id\":\"a\",\"description\":\"d\",\"tool_or_action\":\"chat.synthesize\",\"args\":{},\"autonomy_hint\":\"auto\"}]}")
        let router = MockRouter(surfaceModel: "gpt-5.4-mini")
        let planner = SwiftNativeWorkshopPlannerLLM(llm: mock, router: router, runLedgerDataRoot: nil)
        let (model, output) = try await planner.runCodex(prompt: "hi", surface: "missions", timeoutSeconds: 60)
        #expect(model == "gpt-5.4-mini")
        #expect(output.contains("steps"))
        #expect(mock.lastPrompt == "hi")
        #expect(mock.lastModel == "gpt-5.4-mini")
        #expect(mock.callCount == 1)
    }

    @Test func llmThrowMapsToPlannerFailure() async throws {
        let mock = MockLLMClient(throwError: LLMError.transient(message: "net"))
        let router = MockRouter(surfaceModel: "gpt-5.4-mini")
        let planner = SwiftNativeWorkshopPlannerLLM(llm: mock, router: router, runLedgerDataRoot: nil)
        do {
            _ = try await planner.runCodex(prompt: "hi", surface: "missions", timeoutSeconds: 60)
            Issue.record("expected throw")
        } catch let e as WorkshopExecutionError {
            if case .plannerFailure = e { } else { Issue.record("wrong error: \(e)") }
        }
    }

    @Test func timeoutMapsToPlannerFailure() async throws {
        let router = MockRouter(surfaceModel: "gpt-5.4-mini")
        let planner = SwiftNativeWorkshopPlannerLLM(llm: SlowLLM(), router: router, runLedgerDataRoot: nil)
        do {
            _ = try await planner.runCodex(prompt: "hi", surface: "missions", timeoutSeconds: 1)
            Issue.record("expected timeout throw")
        } catch let e as WorkshopExecutionError {
            if case .plannerFailure(let msg) = e {
                #expect(msg.contains("timeout") || msg.lowercased().contains("cancel"))
            } else { Issue.record("wrong error: \(e)") }
        }
    }

    @Test func endToEndProducesRealPlanWithMockLLM() async throws {
        let llmJSON = "{\"steps\":[{\"id\":\"plan\",\"description\":\"Investigate\",\"tool_or_action\":\"chat.synthesize\",\"args\":{\"prompt\":\"Investigate X\"},\"autonomy_hint\":\"auto\"},{\"id\":\"act\",\"description\":\"Act\",\"tool_or_action\":\"chat.synthesize\",\"args\":{},\"autonomy_hint\":\"auto\"},{\"id\":\"report\",\"description\":\"Report\",\"tool_or_action\":\"chat.synthesize\",\"args\":{},\"autonomy_hint\":\"auto\"}]}"
        let mock = MockLLMClient(output: llmJSON)
        let router = MockRouter(surfaceModel: "gpt-5.4-mini")
        let planner = SwiftNativeWorkshopPlannerLLM(llm: mock, router: router, runLedgerDataRoot: nil)
        let runner = SwiftNativeWorkshopRunner(executorAvailable: true, root: hermeticWorkshopExecutionRoot(), planner: planner)
        let plan = try await runner.planWorkshopExecution(spec: WorkshopExecutionSpec(title: "T", objective: "Investigate X"))
        #expect(plan.fromStub == false)
        #expect(plan.steps.count == 3)
        #expect(plan.steps[0].id == "plan")
        #expect(plan.steps[0].description == "Investigate")
        let throwMock = MockLLMClient(throwError: LLMError.transient(message: "boom"))
        let throwPlanner = SwiftNativeWorkshopPlannerLLM(llm: throwMock, router: router, runLedgerDataRoot: nil)
        let throwRunner = SwiftNativeWorkshopRunner(executorAvailable: true, root: hermeticWorkshopExecutionRoot(), planner: throwPlanner)
        let stubPlan = try await throwRunner.planWorkshopExecution(spec: WorkshopExecutionSpec(title: "T", objective: "Investigate X"))
        #expect(stubPlan.fromStub == true)
        #expect(stubPlan.steps.count == 2)
    }

    @Test func resolvesModelForWorkshopExecutionsSurfaceNotChat() async throws {
        // Surface discrimination ACROSS vocabularies: runCodex is called with the
        // legacy surface "missions" while the router's map is keyed by the
        // canonical "workshop". The LLMClient must still receive the WORKSHOP
        // model — falling through to "chat" here is the silent wrong-model bug
        // the P2-3 bridge exists to prevent.
        let mock = MockLLMClient(output: "{\"steps\":[]}")
        let router = SurfaceDiscriminatingMockRouter()
        let planner = SwiftNativeWorkshopPlannerLLM(llm: mock, router: router, runLedgerDataRoot: nil)
        _ = try? await planner.runCodex(prompt: "p", surface: "missions", timeoutSeconds: 60)
        #expect(mock.lastModel == "model-for-workshop")
        // Sanity: also verify the "chat" model would have been different.
        #expect(mock.lastModel != "model-for-chat")
    }

    @Test func routesThroughWorkshopExecutionsProviderAndPreservesSurfaceControls() async throws {
        let router = WorkshopExecutionRouteRouter()
        let chat = WorkshopExecutionRouteRecordingAdapter(providerId: "openai", response: "wrong-chat-route")
        let executions = WorkshopExecutionRouteRecordingAdapter(providerId: "anthropic", response: "execution-route")
        let client = SwiftNativeLLMClient(
            router: router,
            codex: WorkshopExecutionRouteRecordingAdapter(providerId: "codex", response: "wrong-codex-route"),
            anthropic: executions,
            openAI: chat,
            moonshotCatalogDataRoot: hermeticMoonshotCatalogDataRoot()
        )
        let planner = SwiftNativeWorkshopPlannerLLM(
            llm: client,
            router: router,
            runLedgerDataRoot: nil
        )

        let result = try await planner.runCodex(
            prompt: "plan this execution",
            surface: "missions",
            timeoutSeconds: 60
        )

        #expect(result.model == "claude-opus-4-8")
        #expect(result.output == "execution-route")
        #expect(chat.snapshot().isEmpty)
        // The router fake is keyed with the LEGACY "missions" and the caller
        // passes "missions" too, yet the surface carried into the adapter is the
        // CANONICAL one: writers emit `workshop` from here on (P2-3).
        #expect(executions.snapshot() == [WorkshopExecutionRouteRecordingAdapter.Call(
            model: "claude-opus-4-8",
            surface: "workshop",
            reasoningEffort: "low",
            serviceTier: "priority",
            sessionId: nil
        )])
    }

    @Test func plannerFreezesFirstCheckedTupleAcrossSharedLLMReread() async throws {
        let router = RotatingWorkshopRouteRouter()
        let anthropic = WorkshopExecutionRouteRecordingAdapter(
            providerId: "anthropic", response: "frozen-execution-route"
        )
        let openAI = WorkshopExecutionRouteRecordingAdapter(
            providerId: "openai", response: "wrong-new-generation"
        )
        let client = SwiftNativeLLMClient(
            router: router,
            codex: WorkshopExecutionRouteRecordingAdapter(
                providerId: "codex", response: "wrong-codex-route"
            ),
            anthropic: anthropic,
            openAI: openAI,
            moonshotCatalogDataRoot: hermeticMoonshotCatalogDataRoot()
        )
        let planner = SwiftNativeWorkshopPlannerLLM(
            llm: client,
            router: router,
            runLedgerDataRoot: nil
        )

        let result = try await planner.runCodex(
            prompt: "plan with one admitted route",
            surface: "workshop",
            timeoutSeconds: 60
        )

        #expect(router.callCount == 2)
        #expect(result.model == "claude-opus-4-8")
        #expect(result.output == "frozen-execution-route")
        #expect(openAI.snapshot().isEmpty)
        // The router fake's snapshot is keyed with the LEGACY "missions" while
        // the caller passes the canonical "workshop" — the mismatched pair. The
        // surface carried into the adapter is canonical either way (P2-3).
        #expect(anthropic.snapshot() == [WorkshopExecutionRouteRecordingAdapter.Call(
            model: "claude-opus-4-8",
            surface: "workshop",
            reasoningEffort: "high",
            serviceTier: "priority",
            sessionId: nil
        )])
    }

    @Test func runCodexPropagatesCancellation() async throws {
        // Cancellation must propagate, NOT be wrapped as .plannerFailure — a
        // cancelled submit() would otherwise keep going and write a mission.json.
        let router = MockRouter(surfaceModel: "gpt-5.4-mini")
        let planner = SwiftNativeWorkshopPlannerLLM(llm: SlowLLM(), router: router, runLedgerDataRoot: nil)
        let task = Task {
            try await planner.runCodex(prompt: "p", surface: "missions", timeoutSeconds: 60)
        }
        try await Task.sleep(nanoseconds: 100_000_000)
        task.cancel()
        do {
            _ = try await task.value
            Issue.record("expected CancellationError")
        } catch is CancellationError {
            // expected — cancellation propagated.
        } catch let e as WorkshopExecutionError {
            Issue.record("runCodex erased CancellationError into WorkshopExecutionError: \(e)")
        }
    }

    @Test func submitPropagatesCancellation() async throws {
        // End-to-end cancellation: a cancelled submit() must NOT write a mission.json.
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("WorkshopExecutionsTests-CancelE2E-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let router = MockRouter(surfaceModel: "gpt-5.4-mini")
        let planner = SwiftNativeWorkshopPlannerLLM(llm: SlowLLM(), router: router, runLedgerDataRoot: nil)
        let runner = SwiftNativeWorkshopRunner(executorAvailable: true, root: root, planner: planner)
        let task = Task {
            try await runner.submit(spec: WorkshopExecutionSpec(title: "T", objective: "O"))
        }
        try await Task.sleep(nanoseconds: 100_000_000)
        task.cancel()
        do {
            _ = try await task.value
            Issue.record("expected CancellationError or planner failure to abort submit")
        } catch is CancellationError {
            // expected
        } catch {
            // Acceptable: any error path is fine as long as no mission.json is on disk.
        }
        let queueDir = root
            .appendingPathComponent("workshop", isDirectory: true)
            .appendingPathComponent("executions", isDirectory: true)
        if FileManager.default.fileExists(atPath: queueDir.path) {
            let entries = (try? FileManager.default.contentsOfDirectory(at: queueDir, includingPropertiesForKeys: nil)) ?? []
            for entry in entries {
                let executionRecordJSON = entry.appendingPathComponent("mission.json")
                #expect(!FileManager.default.fileExists(atPath: executionRecordJSON.path),
                        "mission.json must not be written on cancelled submit (found at \(executionRecordJSON.path))")
            }
        }
    }

    @Test func submitPropagatesCancellationAfterTimelineWrite() async throws {
        // Asserts that a cancellation landing AFTER timeline append but BEFORE
        // mission.json write leaves mission.json absent — the BLOCKING #2 fix.
        let root = try makeTempRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let slow = SlowPersistenceCore(delay: .milliseconds(200))
        let mock = MockLLMClient(output: "{\"steps\":[{\"id\":\"a\",\"description\":\"d\",\"tool_or_action\":\"chat.synthesize\",\"args\":{},\"autonomy_hint\":\"auto\"}]}")
        let router = MockRouter(surfaceModel: "gpt-5.4-mini")
        let planner = SwiftNativeWorkshopPlannerLLM(llm: mock, router: router, runLedgerDataRoot: nil)
        let runner = SwiftNativeWorkshopRunner(executorAvailable: true,
            root: root,
            persistence: slow,
            planner: planner
        )
        let task = Task {
            try await runner.submit(spec: WorkshopExecutionSpec(
                title: "t", objective: "o",
                triggerSource: "test", trustRequired: "low"
            ))
        }
        try? await Task.sleep(nanoseconds: 50_000_000)
        task.cancel()
        do {
            _ = try await task.value
            Issue.record("expected CancellationError; submit returned")
        } catch is CancellationError {
            // expected
        } catch {
            // Acceptable: a downstream cancel-induced persistence error wraps as
            // WorkshopExecutionError.persistenceFailure. We then verify mission.json is
            // absent which is the structural invariant the BLOCKING-fix guards.
        }
        let queue = root
            .appendingPathComponent("workshop", isDirectory: true)
            .appendingPathComponent("executions", isDirectory: true)
        var leaked: [URL] = []
        if FileManager.default.fileExists(atPath: queue.path),
           let entries = try? FileManager.default.contentsOfDirectory(at: queue, includingPropertiesForKeys: nil) {
            for entry in entries {
                let mj = entry.appendingPathComponent("mission.json")
                if FileManager.default.fileExists(atPath: mj.path) {
                    leaked.append(mj)
                }
            }
        }
        #expect(leaked.isEmpty, "cancelled submit leaked mission.json: \(leaked)")
    }

    @Test func runCodexCancelDuringRouterErrorPropagatesCancellation() async throws {
        // BLOCKING #4: if the LLMClient throws a NON-CancellationError NON-NSURL
        // error while the outer task is cancelled, the broad catch must honor
        // Task.isCancelled and surface CancellationError — NOT wrap as
        // WorkshopExecutionError.plannerFailure.
        final class GenericThrowingLLM: LLMClient, @unchecked Sendable {
            func complete(prompt: String, system: String?, model: String?) async throws -> String {
                // Sleep a touch so the outer cancel lands before the throw.
                try? await Task.sleep(nanoseconds: 50_000_000)
                struct OpaqueError: Error {}
                throw OpaqueError()
            }
        }
        let router = MockRouter(surfaceModel: "gpt-5.4-mini")
        let planner = SwiftNativeWorkshopPlannerLLM(llm: GenericThrowingLLM(), router: router, runLedgerDataRoot: nil)
        let task = Task {
            try await planner.runCodex(prompt: "hi", surface: "missions", timeoutSeconds: 60)
        }
        try? await Task.sleep(nanoseconds: 10_000_000)
        task.cancel()
        do {
            _ = try await task.value
            Issue.record("expected CancellationError; runCodex returned")
        } catch is CancellationError {
            // expected
        } catch let e as WorkshopExecutionError {
            Issue.record("BLOCKING #4 regressed: cancellation swallowed as WorkshopExecutionError: \(e)")
        }
    }
}

// MARK: - Adapter-level cancellation erasure regression

/// URLProtocol stub that, on `startLoading`, schedules a single
/// `URLError(.cancelled)` failure after a short delay. Used to drive
/// OpenAIAdapter.complete()'s catch through the cancellation branch
/// without depending on Task cancellation timing or network reachability.
final class CancelledURLProtocol: URLProtocol {
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        let client = self.client
        DispatchQueue.global().asyncAfter(deadline: .now() + 0.05) { [weak self] in
            guard let self = self else { return }
            client?.urlProtocol(self, didFailWithError: URLError(.cancelled))
        }
    }
    override func stopLoading() {}
}

@Suite("OpenAIAdapter: cancellation propagation")
struct OpenAIAdapterCancellationSuite {
    @Test func cancelledURLSessionSurfacesAsCancellationError() async throws {
        // Injects a URLProtocol that fails the request with URLError(.cancelled).
        // The adapter MUST re-throw CancellationError, not erase it into
        // LLMError.underlying("connection refused: ...").
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [CancelledURLProtocol.self]
        let session = URLSession(configuration: config)
        let adapter = OpenAIAdapter(
            session: session,
            endpoint: URL(string: "https://example.invalid/v1/chat/completions")!,
            apiKeyOverride: "sk-test-fake"
        )
        do {
            _ = try await adapter.complete(prompt: "p", system: nil, model: "gpt-4")
            Issue.record("expected cancellation")
        } catch is CancellationError {
            // expected
        } catch let e as LLMError {
            Issue.record("OpenAIAdapter erased URLError.cancelled into LLMError: \(e)")
        } catch {
            Issue.record("OpenAIAdapter erased URLError.cancelled into: \(error)")
        }
    }

    @Test func codexCompleteCancellationSurfacesAsCancellationError() async throws {
        // Inject a fake runner that hangs until the terminator fires, then
        // resumes with a non-zero exit code (simulating SIGTERM → exit 143).
        // Pre-fix, this would surface as LLMError.underlying("codex exited 143").
        // Post-fix, the post-await Task.checkCancellation() surfaces it as CancellationError.
        let runner: @Sendable (CodexProcessInvocation) async throws -> CodexProcessResult = { inv in
            await withCheckedContinuation { (cont: CheckedContinuation<Void, Never>) in
                inv.terminator.register { cont.resume() }
            }
            return CodexProcessResult(exitCode: 143, stdout: "", stderr: "", timedOut: false)
        }
        let adapter = CodexAdapter(
            codexBin: "/usr/bin/false",
            timeout: 60,
            runner: runner
        )
        let task = Task {
            try await adapter.complete(prompt: "p", system: nil, model: "codex-test")
        }
        try await Task.sleep(nanoseconds: 100_000_000)
        task.cancel()
        do {
            _ = try await task.value
            Issue.record("expected CancellationError")
        } catch is CancellationError {
            // expected
        } catch let e {
            Issue.record("got non-cancellation error: \(e)")
        }
    }

    @Test func anthropicAdapterCancellationPropagatesAsCancellationError() async throws {
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [CancelledURLProtocol.self] + (config.protocolClasses ?? [])
        let session = URLSession(configuration: config)
        let adapter = AnthropicAdapter(
            session: session,
            endpoint: URL(string: "https://api.anthropic.com/v1/messages")!,
            apiKeyOverride: "sk-test-fake"
        )
        do {
            _ = try await adapter.complete(prompt: "p", system: nil, model: "claude-3")
            Issue.record("expected error")
        } catch is CancellationError {
            // expected
        } catch let e as LLMError {
            if case .underlying(let msg) = e {
                Issue.record("AnthropicAdapter erased CancellationError into LLMError.underlying: \(msg)")
            } else {
                Issue.record("AnthropicAdapter erased CancellationError into LLMError: \(e)")
            }
        }
    }
}

/// Test helper: PersistenceCoreProtocol that wraps the real impl with a
/// configurable delay on writeJSON, so a cancel that lands between
/// appendJSONL and writeJSON can be reproduced deterministically.
private final class SlowPersistenceCore: PersistenceCoreProtocol, @unchecked Sendable {
    private let inner: SwiftNativePersistenceCore
    private let delay: Duration
    init(delay: Duration) {
        self.inner = SwiftNativePersistenceCore()
        self.delay = delay
    }
    func readJSON(_ path: URL, defaultValue: JSONValue) async -> JSONValue {
        await inner.readJSON(path, defaultValue: defaultValue)
    }
    func appendJSONL(_ record: JSONValue, to path: URL) async throws {
        try await inner.appendJSONL(record, to: path)
    }
    func tailJSONL(_ path: URL, limit: Int, maxBytes: Int?) async throws -> [JSONValue] {
        try await inner.tailJSONL(path, limit: limit, maxBytes: maxBytes)
    }
    func readJSONL(_ path: URL) async throws -> [JSONValue] {
        try await inner.readJSONL(path)
    }
    func writeJSON(_ value: JSONValue, to path: URL) async throws {
        try await Task.sleep(for: delay)
        try Task.checkCancellation()
        try await inner.writeJSON(value, to: path)
    }
}

// MARK: - WAVE 32 W07: read-side (listing / detail / timeline)
//
// Exercises SwiftNativeWorkshopRunner.listAll / listActive / listHistory /
// getMission / readTimeline / listLegacyWorkshopExecutions / listWorkshopExecutionsMerged against
// hand-seeded on-disk state. These mirror the retired daemon TaskQueue reads
// (L363-L414) + the retired daemon GET /v1/missions merge order (L51360-L51366)
// + list_missions (L5325-L5329). State is seeded directly via the persistence
// core so the reads are tested in isolation from submit()'s planner/auto-start.
@Suite("SwiftNativeWorkshopRunner: reads (wave 32 W07)")
struct SwiftNativeWorkshopRunnerReadTests {

    // Seed a single queue mission.json at <root>/workshop/executions/<id>/mission.json.
    private func seedQueueWorkshopExecution(
        runner: SwiftNativeWorkshopRunner,
        persistence: SwiftNativePersistenceCore,
        id: String,
        status: String,
        createdAt: String,
        updatedAt: String
    ) async throws {
        let obj: JSONValue = .object([
            "id": .string(id),
            "title": .string("title-\(id)"),
            "objective": .string("obj-\(id)"),
            "created_at": .string(createdAt),
            "status": .string(status),
            "plan": .array([.object([
                "id": .string("step-1"),
                "description": .string("d"),
                "tool_or_action": .string("chat.synthesize"),
                "args": .object([:]),
                "autonomy": .string("auto"),
            ])]),
            "steps_completed": .array([]),
            "receipts_dir": .string("/tmp/r/\(id)"),
            "trigger_source": .string("manual"),
            "trust_required": .string("none"),
            "expected_outputs": .array([]),
            "current_step_id": .string(""),
            "updated_at": .string(updatedAt),
            "result": .null,
            "rerun_count": .int(0),
        ])
        try await persistence.writeJSON(obj, to: runner.executionRecordPath(id))
    }

    @Test func listAllSortsByCreatedAtDesc() async throws {
        let root = try makeTempRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let p = SwiftNativePersistenceCore()
        let runner = SwiftNativeWorkshopRunner(executorAvailable: true, root: root, persistence: p, planner: ThrowingWorkshopPlannerLLM())
        try await seedQueueWorkshopExecution(runner: runner, persistence: p, id: "a", status: "queued", createdAt: "2026-01-01", updatedAt: "2026-01-01")
        try await seedQueueWorkshopExecution(runner: runner, persistence: p, id: "b", status: "completed", createdAt: "2026-03-01", updatedAt: "2026-03-09")
        try await seedQueueWorkshopExecution(runner: runner, persistence: p, id: "c", status: "running", createdAt: "2026-02-01", updatedAt: "2026-02-01")
        let all = await runner.listAll()
        #expect(all.map(\.id) == ["b", "c", "a"])  // created_at DESC
    }

    @Test func listActiveFiltersToLiveStatuses() async throws {
        let root = try makeTempRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let p = SwiftNativePersistenceCore()
        let runner = SwiftNativeWorkshopRunner(executorAvailable: true, root: root, persistence: p, planner: ThrowingWorkshopPlannerLLM())
        try await seedQueueWorkshopExecution(runner: runner, persistence: p, id: "q", status: "queued", createdAt: "2026-01-01", updatedAt: "2026-01-01")
        try await seedQueueWorkshopExecution(runner: runner, persistence: p, id: "r", status: "running", createdAt: "2026-01-02", updatedAt: "2026-01-02")
        try await seedQueueWorkshopExecution(runner: runner, persistence: p, id: "x", status: "blocked_on_approval", createdAt: "2026-01-03", updatedAt: "2026-01-03")
        try await seedQueueWorkshopExecution(runner: runner, persistence: p, id: "done", status: "completed", createdAt: "2026-01-04", updatedAt: "2026-01-04")
        let active = Set((await runner.listActive()).map(\.id))
        #expect(active == ["q", "r", "x"])
    }

    @Test func listHistorySortsByUpdatedDescAndCapsAt20() async throws {
        let root = try makeTempRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let p = SwiftNativePersistenceCore()
        let runner = SwiftNativeWorkshopRunner(executorAvailable: true, root: root, persistence: p, planner: ThrowingWorkshopPlannerLLM())
        // 22 terminal Workshop executions; updated_at gives a deterministic order.
        for i in 0..<22 {
            let key = String(format: "%02d", i)
            try await seedQueueWorkshopExecution(runner: runner, persistence: p, id: "m\(key)", status: "completed", createdAt: "2026-01-\(key)", updatedAt: "2026-02-\(key)")
        }
        // One non-terminal that must be excluded.
        try await seedQueueWorkshopExecution(runner: runner, persistence: p, id: "live", status: "running", createdAt: "2026-01-30", updatedAt: "2026-02-28")
        let hist = await runner.listHistory()
        #expect(hist.count == 20)               // capped at 20
        #expect(!hist.contains { $0.id == "live" })  // running excluded
        // Newest updated_at first → m21 then m20 ...
        #expect(hist.first?.id == "m21")
        #expect(hist.last?.id == "m02")          // m21..m02 is 20 entries; m01,m00 dropped
    }

    @Test func getWorkshopExecutionReturnsRecordAndNilForMissing() async throws {
        let root = try makeTempRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let p = SwiftNativePersistenceCore()
        let runner = SwiftNativeWorkshopRunner(executorAvailable: true, root: root, persistence: p, planner: ThrowingWorkshopPlannerLLM())
        try await seedQueueWorkshopExecution(runner: runner, persistence: p, id: "got", status: "queued", createdAt: "2026-01-01", updatedAt: "2026-01-01")
        let rec = await runner.getWorkshopExecution("got")
        #expect(rec?.id == "got")
        #expect(rec?.status == "queued")
        #expect(rec?.plan.count == 1)
        #expect(rec?.plan.first?.toolOrAction == "chat.synthesize")
        // Missing id → nil (daemon's JSON 404 path).
        let missing = await runner.getWorkshopExecution("nope")
        #expect(missing == nil)
    }

    @Test func readTimelineReturnsEventsInOrderAndEmptyForMissing() async throws {
        let root = try makeTempRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let p = SwiftNativePersistenceCore()
        let runner = SwiftNativeWorkshopRunner(executorAvailable: true, root: root, persistence: p, planner: ThrowingWorkshopPlannerLLM())
        let id = "tl"
        let tlPath = runner.timelinePath(id)
        try await p.appendJSONL(.object(["event": .string("enqueued"), "ts": .string("t1")]), to: tlPath)
        try await p.appendJSONL(.object(["event": .string("started"), "ts": .string("t2")]), to: tlPath)
        let events = try await runner.readTimeline(id)
        #expect(events.count == 2)
        if case .object(let e0) = events[0] { #expect(str(e0["event"]) == "enqueued") } else { Issue.record("e0 not object") }
        if case .object(let e1) = events[1] { #expect(str(e1["event"]) == "started") } else { Issue.record("e1 not object") }
        // Missing timeline → [] (matches Python read_timeline on no file).
        let empty = try await runner.readTimeline("no-such")
        #expect(empty.isEmpty)
    }

    @Test func legacyWorkshopExecutionsSortByUpdatedThenCreatedDesc() async throws {
        let root = try makeTempRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let p = SwiftNativePersistenceCore()
        let runner = SwiftNativeWorkshopRunner(executorAvailable: true, root: root, persistence: p, planner: ThrowingWorkshopPlannerLLM())
        // Legacy flat store: camelCase, no plan/timeline. native_agentd L5329
        // sorts by updatedAt|createdAt DESC.
        let legacy: JSONValue = .array([
            .object(["id": .string("L1"), "title": .string("one"), "status": .string("active"), "createdAt": .string("2026-01-01"), "updatedAt": .string("2026-01-05")]),
            .object(["id": .string("L2"), "title": .string("two"), "status": .string("active"), "createdAt": .string("2026-01-02"), "updatedAt": .string("2026-01-09")]),
            .object(["id": .string("L3"), "title": .string("three"), "status": .string("active"), "createdAt": .string("2026-01-08")]),  // no updatedAt → falls back to createdAt
        ])
        try await p.writeJSON(legacy, to: runner.legacyWorkshopExecutionsPath)
        let out = await runner.listLegacyWorkshopExecutions()
        let ids = out.compactMap { v -> String? in
            if case .object(let o) = v, case .string(let id)? = o["id"] { return id }
            return nil
        }
        // updated/created keys: L2=2026-01-09, L3=2026-01-08, L1=2026-01-05 → DESC
        #expect(ids == ["L2", "L3", "L1"])
    }

    @Test func mergedListIsQueueFirstThenLegacy() async throws {
        let root = try makeTempRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let p = SwiftNativePersistenceCore()
        let runner = SwiftNativeWorkshopRunner(executorAvailable: true, root: root, persistence: p, planner: ThrowingWorkshopPlannerLLM())
        try await seedQueueWorkshopExecution(runner: runner, persistence: p, id: "Q1", status: "queued", createdAt: "2026-05-01", updatedAt: "2026-05-01")
        try await seedQueueWorkshopExecution(runner: runner, persistence: p, id: "Q2", status: "running", createdAt: "2026-05-02", updatedAt: "2026-05-02")
        let legacy: JSONValue = .array([
            .object(["id": .string("L1"), "title": .string("legacy"), "status": .string("active"), "createdAt": .string("2026-04-01"), "updatedAt": .string("2026-04-01")]),
        ])
        try await p.writeJSON(legacy, to: runner.legacyWorkshopExecutionsPath)
        let merged = await runner.listWorkshopExecutionsMerged()
        let ids = merged.compactMap { v -> String? in
            if case .object(let o) = v, case .string(let id)? = o["id"] { return id }
            return nil
        }
        // Queue (created_at DESC: Q2, Q1) THEN legacy (L1) — matches
        // the retired daemon `new_missions + old_missions`.
        #expect(ids == ["Q2", "Q1", "L1"])
    }

    @Test func mergedListEmptyWhenNoStores() async throws {
        let root = try makeTempRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let p = SwiftNativePersistenceCore()
        let runner = SwiftNativeWorkshopRunner(executorAvailable: true, root: root, persistence: p, planner: ThrowingWorkshopPlannerLLM())
        // No queue dir, no legacy file → [] (no crash on absent root).
        let merged = await runner.listWorkshopExecutionsMerged()
        #expect(merged.isEmpty)
        let all = await runner.listAll()
        #expect(all.isEmpty)
        let legacy = await runner.listLegacyWorkshopExecutions()
        #expect(legacy.isEmpty)
    }
}

// MARK: - WAVE 32 W07: gpt-5.5 finding #1 regression (verbatim plan preservation)
@Suite("SwiftNativeWorkshopRunner: wire-read plan fidelity (wave 32 W07)")
struct SwiftNativeWorkshopRunnerWireFidelityTests {
    @Test func mergedAndDetailPreserveRawPlanKeysVerbatim() async throws {
        let root = try makeTempRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let p = SwiftNativePersistenceCore()
        let runner = SwiftNativeWorkshopRunner(executorAvailable: true, root: root, persistence: p, planner: ThrowingWorkshopPlannerLLM())
        // A plan step carrying an EXTRA key + a result object — the daemon's
        // asdict(_from_dict(data)) would pass these through verbatim. A
        // WorkshopExecutionRecord round-trip would drop the extra key + the per-step
        // shape would be normalized. The wire path must NOT do that.
        let obj: JSONValue = .object([
            "id": .string("X1"),
            "title": .string("t"),
            "objective": .string("o"),
            "created_at": .string("2026-01-01"),
            "status": .string("running"),
            "plan": .array([.object([
                "id": .string("s1"),
                "description": .string("d"),
                "tool_or_action": .string("calendar.list_events"),
                "args": .object(["q": .string("today")]),
                "autonomy": .string("needs_approval"),
                "expected_output": .string("a list"),   // EXTRA key not in WorkshopExecutionStep
            ])]),
            "steps_completed": .array([]),
            "receipts_dir": .string("/tmp/r"),
            "trigger_source": .string("manual"),
            "trust_required": .string("none"),
            "expected_outputs": .array([.string("calendar events")]),
            "current_step_id": .string("s1"),
            "updated_at": .string("2026-01-02"),
            "result": .object(["summary": .string("done")]),  // result as object, not string
            "rerun_count": .int(2),
        ])
        try await p.writeJSON(obj, to: runner.executionRecordPath("X1"))

        // Merged-list wire path.
        let merged = await runner.listWorkshopExecutionsMerged()
        #expect(merged.count == 1)
        guard case .object(let m0) = merged[0] else { Issue.record("merged[0] not object"); return }
        guard case .array(let plan) = m0["plan"] ?? .null, case .object(let step0) = plan.first ?? .null else {
            Issue.record("plan not preserved"); return
        }
        #expect(str(step0["expected_output"]) == "a list")          // EXTRA key survived
        #expect(str(step0["tool_or_action"]) == "calendar.list_events")
        #expect(m0["result"] == .object(["summary": .string("done")]))  // object result survived
        #expect(m0["rerun_count"] == .int(2))
        #expect(m0["expected_outputs"] == .array([.string("calendar events")]))

        // Detail wire path.
        guard let detail = await runner.getWorkshopExecutionWireJSON("X1"), case .object(let d) = detail else {
            Issue.record("detail nil"); return
        }
        guard case .array(let dplan) = d["plan"] ?? .null, case .object(let dstep0) = dplan.first ?? .null else {
            Issue.record("detail plan not preserved"); return
        }
        #expect(str(dstep0["expected_output"]) == "a list")
        #expect(d["timeline"] == nil)  // wire-json does NOT carry timeline (caller attaches)
        // Missing id → nil.
        let missing = await runner.getWorkshopExecutionWireJSON("nope")
        #expect(missing == nil)
    }
}

// MARK: - writes (wave 33 W07)
//
// Exercises SwiftNativeWorkshopRunner.cancel + updateWorkshopExecution against hand-seeded
// on-disk state. Mirrors MissionRunner.cancel and the
// queue-bridge branch of Runtime.update_mission.
// State is seeded directly via the persistence core so the writes are tested in
// isolation from submit()'s planner / auto-start.
@Suite("SwiftNativeWorkshopRunner: writes (wave 33 W07)")
struct SwiftNativeWorkshopRunnerWriteTests {

    private func seedQueueWorkshopExecution(
        runner: SwiftNativeWorkshopRunner,
        persistence: SwiftNativePersistenceCore,
        id: String,
        status: String,
        currentStepId: String = "step-1",
        result: JSONValue = .null
    ) async throws {
        let o: JSONValue = .object([
            "id": .string(id),
            "title": .string("title-\(id)"),
            "objective": .string("obj-\(id)"),
            "created_at": .string("2026-01-01T00:00:00Z"),
            "status": .string(status),
            "plan": .array([.object([
                "id": .string("step-1"),
                "description": .string("d"),
                "tool_or_action": .string("chat.synthesize"),
                "args": .object([:]),
                "autonomy": .string("auto"),
            ])]),
            "steps_completed": .array([]),
            "receipts_dir": .string("/tmp/r/\(id)"),
            "trigger_source": .string("manual"),
            "trust_required": .string("none"),
            "expected_outputs": .array([]),
            "current_step_id": .string(currentStepId),
            "updated_at": .string("2026-01-01T00:00:00Z"),
            "result": result,
            "rerun_count": .int(0),
        ])
        try await persistence.writeJSON(o, to: runner.executionRecordPath(id))
    }

    private func diskStatus(_ runner: SwiftNativeWorkshopRunner, _ id: String) throws -> String? {
        let data = try Data(contentsOf: runner.executionRecordPath(id))
        guard case .object(let o) = try JSONValue.parse(data) else { return nil }
        return str(o["status"])
    }

    // MARK: cancel

    @Test func cancelFlipsStatusAndPersists() async throws {
        let root = try makeTempRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let p = SwiftNativePersistenceCore()
        let runner = SwiftNativeWorkshopRunner(executorAvailable: true, root: root, persistence: p, planner: ThrowingWorkshopPlannerLLM(), now: fixedNow())
        try await seedQueueWorkshopExecution(runner: runner, persistence: p, id: "m1", status: "running")

        let rec = try await runner.cancel(executionId: "m1")
        #expect(rec.status == "cancelled")
        // Persisted to disk.
        #expect(try diskStatus(runner, "m1") == "cancelled")
        // updated_at bumped (save_mission semantics — the retired daemon).
        #expect(rec.updatedAt == SwiftNativeWorkshopRunner.isoTimestamp(fixedNow()()))
    }

    @Test func cancelAppendsTimelineEvent() async throws {
        let root = try makeTempRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let p = SwiftNativePersistenceCore()
        let runner = SwiftNativeWorkshopRunner(executorAvailable: true, root: root, persistence: p, planner: ThrowingWorkshopPlannerLLM(), now: fixedNow())
        try await seedQueueWorkshopExecution(runner: runner, persistence: p, id: "m1", status: "queued")
        _ = try await runner.cancel(executionId: "m1")

        let events = try await runner.readTimeline("m1")
        let cancelled = events.compactMap { obj($0) }.filter { str($0["event"]) == "cancelled" }
        #expect(cancelled.count == 1)
        #expect(str(cancelled.first?["ts"]) == SwiftNativeWorkshopRunner.isoTimestamp(fixedNow()()))
    }

    @Test func cancelIsIdempotentNoOp() async throws {
        let root = try makeTempRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let p = SwiftNativePersistenceCore()
        let runner = SwiftNativeWorkshopRunner(executorAvailable: true, root: root, persistence: p, planner: ThrowingWorkshopPlannerLLM(), now: fixedNow())
        try await seedQueueWorkshopExecution(runner: runner, persistence: p, id: "m1", status: "cancelled")

        let rec = try await runner.cancel(executionId: "m1")
        #expect(rec.status == "cancelled")
        // Idempotent: NO new `cancelled` timeline event (Python returns early).
        let events = try await runner.readTimeline("m1")
        let cancelled = events.compactMap { obj($0) }.filter { str($0["event"]) == "cancelled" }
        #expect(cancelled.isEmpty, "already-cancelled cancel must not append a timeline event")
    }

    @Test func cancelMissingWorkshopExecutionThrows() async throws {
        let root = try makeTempRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let p = SwiftNativePersistenceCore()
        let runner = SwiftNativeWorkshopRunner(executorAvailable: true, root: root, persistence: p, planner: ThrowingWorkshopPlannerLLM())
        do {
            _ = try await runner.cancel(executionId: "ghost")
            Issue.record("expected throw for missing execution")
        } catch let e as WorkshopExecutionError {
            #expect(e == .invalidRequest("Workshop execution not found: ghost"))
        }
    }

    @Test func cancelEmptyIdThrows() async throws {
        let root = try makeTempRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let runner = SwiftNativeWorkshopRunner(executorAvailable: true, root: root, planner: ThrowingWorkshopPlannerLLM())
        do {
            _ = try await runner.cancel(executionId: "  ")
            Issue.record("expected throw for empty id")
        } catch let e as WorkshopExecutionError {
            #expect(e == .invalidRequest("empty missionId"))
        }
    }

    // MARK: updateWorkshopExecution

    @Test func updatePatchesFieldsAndPersists() async throws {
        let root = try makeTempRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let p = SwiftNativePersistenceCore()
        let runner = SwiftNativeWorkshopRunner(executorAvailable: true, root: root, persistence: p, planner: ThrowingWorkshopPlannerLLM(), now: fixedNow())
        try await seedQueueWorkshopExecution(runner: runner, persistence: p, id: "m1", status: "running")

        let rec = try await runner.updateWorkshopExecution(
            WorkshopExecutionUpdate(id: "m1", title: "new title", objective: "new obj")
        )
        #expect(rec?.title == "new title")
        #expect(rec?.objective == "new obj")
        // Persisted.
        let data = try Data(contentsOf: runner.executionRecordPath("m1"))
        guard case .object(let o) = try JSONValue.parse(data) else { Issue.record("bad json"); return }
        #expect(str(o["title"]) == "new title")
        #expect(str(o["objective"]) == "new obj")
        #expect(str(o["updated_at"]) == SwiftNativeWorkshopRunner.isoTimestamp(fixedNow()()))
    }

    @Test func updateTerminalStatusClearsCurrentStep() async throws {
        let root = try makeTempRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let p = SwiftNativePersistenceCore()
        let runner = SwiftNativeWorkshopRunner(executorAvailable: true, root: root, persistence: p, planner: ThrowingWorkshopPlannerLLM(), now: fixedNow())
        try await seedQueueWorkshopExecution(runner: runner, persistence: p, id: "m1", status: "running", currentStepId: "step-1")

        // "cancelled" is in the queue-bridge terminal set.
        let rec = try await runner.updateWorkshopExecution(WorkshopExecutionUpdate(id: "m1", status: "completed"))
        #expect(rec?.status == "completed")
        #expect(rec?.currentStepId == "", "terminal status must clear current_step_id")
    }

    @Test func updateNonTerminalStatusKeepsCurrentStep() async throws {
        let root = try makeTempRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let p = SwiftNativePersistenceCore()
        let runner = SwiftNativeWorkshopRunner(executorAvailable: true, root: root, persistence: p, planner: ThrowingWorkshopPlannerLLM(), now: fixedNow())
        try await seedQueueWorkshopExecution(runner: runner, persistence: p, id: "m1", status: "queued", currentStepId: "step-1")
        let rec = try await runner.updateWorkshopExecution(WorkshopExecutionUpdate(id: "m1", status: "running"))
        #expect(rec?.status == "running")
        #expect(rec?.currentStepId == "step-1", "non-terminal status must NOT clear current_step_id")
    }

    @Test func updateResultViaSummaryAlias() async throws {
        let root = try makeTempRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let p = SwiftNativePersistenceCore()
        let runner = SwiftNativeWorkshopRunner(executorAvailable: true, root: root, persistence: p, planner: ThrowingWorkshopPlannerLLM(), now: fixedNow())
        try await seedQueueWorkshopExecution(runner: runner, persistence: p, id: "m1", status: "running")
        // fromBody mirrors the daemon: `summary` is read before `result`.
        let patch = WorkshopExecutionUpdate.fromBody([
            "id": .string("m1"),
            "summary": .string("all done"),
        ])
        let rec = try await runner.updateWorkshopExecution(patch)
        #expect(rec?.result == .string("all done"))
    }

    @Test func updateEmptySummaryFallsThroughToResult() async throws {
        // gpt-5.5 finding #1: Python `summary or result` — empty summary is
        // falsy and must fall through to `result`. The earlier `??` kept "".
        let root = try makeTempRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let p = SwiftNativePersistenceCore()
        let runner = SwiftNativeWorkshopRunner(executorAvailable: true, root: root, persistence: p, planner: ThrowingWorkshopPlannerLLM())
        try await seedQueueWorkshopExecution(runner: runner, persistence: p, id: "m1", status: "running")
        let patch = WorkshopExecutionUpdate.fromBody([
            "id": .string("m1"),
            "summary": .string(""),
            "result": .string("real result"),
        ])
        let rec = try await runner.updateWorkshopExecution(patch)
        #expect(rec?.result == .string("real result"))
    }

    @Test func updateEmptyResultPreservesExistingObjectResult() async throws {
        // gpt-5.5 finding #2: an empty body result must NOT clobber a truthy
        // existing .object result to "".
        let root = try makeTempRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let p = SwiftNativePersistenceCore()
        let runner = SwiftNativeWorkshopRunner(executorAvailable: true, root: root, persistence: p, planner: ThrowingWorkshopPlannerLLM())
        let priorResult: JSONValue = .object(["summary": .string("done")])
        try await seedQueueWorkshopExecution(runner: runner, persistence: p, id: "m1", status: "running", result: priorResult)
        // Present-but-empty result with no summary → falsy body contribution →
        // keep existing truthy result.
        let patch = WorkshopExecutionUpdate.fromBody(["id": .string("m1"), "result": .string("")])
        let rec = try await runner.updateWorkshopExecution(patch)
        #expect(rec?.result == priorResult, "empty result patch must preserve existing object result")
    }

    @Test func updateEmptyResultNoPriorYieldsEmptyString() async throws {
        let root = try makeTempRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let p = SwiftNativePersistenceCore()
        let runner = SwiftNativeWorkshopRunner(executorAvailable: true, root: root, persistence: p, planner: ThrowingWorkshopPlannerLLM())
        try await seedQueueWorkshopExecution(runner: runner, persistence: p, id: "m1", status: "running", result: .null)
        let patch = WorkshopExecutionUpdate.fromBody(["id": .string("m1"), "result": .string("")])
        let rec = try await runner.updateWorkshopExecution(patch)
        #expect(rec?.result == .string(""), "empty result + falsy prior → empty string")
    }

    @Test func updateUnknownWorkshopExecutionReturnsNil() async throws {
        let root = try makeTempRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let p = SwiftNativePersistenceCore()
        let runner = SwiftNativeWorkshopRunner(executorAvailable: true, root: root, persistence: p, planner: ThrowingWorkshopPlannerLLM())
        // nil → daemon falls through to legacy missions.jsonl path.
        let rec = try await runner.updateWorkshopExecution(WorkshopExecutionUpdate(id: "ghost", status: "done"))
        #expect(rec == nil)
    }

    @Test func updateEmptyIdReturnsNil() async throws {
        let root = try makeTempRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let runner = SwiftNativeWorkshopRunner(executorAvailable: true, root: root, planner: ThrowingWorkshopPlannerLLM())
        let rec = try await runner.updateWorkshopExecution(WorkshopExecutionUpdate(id: "   "))
        #expect(rec == nil)
    }

    @Test func updateEmptyTitleFallsBackToExisting() async throws {
        let root = try makeTempRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let p = SwiftNativePersistenceCore()
        let runner = SwiftNativeWorkshopRunner(executorAvailable: true, root: root, persistence: p, planner: ThrowingWorkshopPlannerLLM())
        try await seedQueueWorkshopExecution(runner: runner, persistence: p, id: "m1", status: "running")
        // Present-but-empty title: Python `str(body.get("title") or qm.title)` keeps old.
        let patch = WorkshopExecutionUpdate.fromBody(["id": .string("m1"), "title": .string("")])
        let rec = try await runner.updateWorkshopExecution(patch)
        #expect(rec?.title == "title-m1", "present-but-empty title must keep existing value")
    }

    @Test func updateNoMutatingFieldsDoesNotBumpUpdatedAt() async throws {
        let root = try makeTempRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let p = SwiftNativePersistenceCore()
        let runner = SwiftNativeWorkshopRunner(executorAvailable: true, root: root, persistence: p, planner: ThrowingWorkshopPlannerLLM(), now: fixedNow())
        try await seedQueueWorkshopExecution(runner: runner, persistence: p, id: "m1", status: "running")
        // Patch with only an id (no field keys present) → changed=false → no write.
        let patch = WorkshopExecutionUpdate.fromBody(["id": .string("m1")])
        let rec = try await runner.updateWorkshopExecution(patch)
        // Returns the unchanged record with the ORIGINAL updated_at (not bumped).
        #expect(rec?.updatedAt == "2026-01-01T00:00:00Z")
    }

    // MARK: timeline.jsonl cross-process flock (WAVE 34 W07 — §6.96 round-2 #3)

    /// Proves cancel()'s `cancelled` timeline append takes the same
    /// cross-process advisory flock on `<timeline.jsonl>.lock` used by native
    /// sibling writers. Mirrors the blocking-order proof in
    /// ToolRegistryTests.swift::swiftNative_promote_uses_withFileLock_for_cross_process_safety.
    /// A Swift helper grabs the timeline lock and holds it for `holdSeconds`;
    /// the Swift cancel must BLOCK on the append until the helper releases. If the
    /// append were unlocked (the pre-wave-34 state), the Swift cancel would
    /// finish well under the hold window.
    @Test func cancelTimelineAppendBlocksUntilHelperReleasesFlock() async throws {
        let root = try makeTempRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let p = SwiftNativePersistenceCore()
        let runner = SwiftNativeWorkshopRunner(executorAvailable: true, root: root, persistence: p, planner: ThrowingWorkshopPlannerLLM(), now: fixedNow())
        try await seedQueueWorkshopExecution(runner: runner, persistence: p, id: "m1", status: "running")

        // The lock the cancel append will contend on is timeline.jsonl's OWN
        // `.lock` sibling (NOT mission.json's lock) — that is the whole point
        // of §6.96 #3.
        let timelinePath = runner.timelinePath("m1")
        let lockPath = timelinePath.path + ".lock"
        let storeDir = timelinePath.deletingLastPathComponent()
        let acquiredMarker = storeDir.appendingPathComponent("helper_tl_acquired.txt")
        let releasedMarker = storeDir.appendingPathComponent("helper_tl_released.txt")
        let releaseRequest = storeDir.appendingPathComponent("helper_tl_release_request.txt")
        let swiftStartedMarker = storeDir.appendingPathComponent("swift_cancel_started.txt")
        let swiftFinishedMarker = storeDir.appendingPathComponent("swift_cancel_finished.txt")

        let helper = try NativeAgentFlockChild.hold(
            lockPath: lockPath,
            acquiredMarker: acquiredMarker,
            releasedMarker: releasedMarker,
            releaseRequest: releaseRequest
        )
        defer {
            try? Data("release".utf8).write(to: releaseRequest)
            helper.terminate()
        }

        // Wait for the helper to actually hold the flock before we start the cancel.
        let acquireDeadline = Date().addingTimeInterval(10.0)
        while !FileManager.default.fileExists(atPath: acquiredMarker.path) {
            if Date() > acquireDeadline { break }
            try? await Task.sleep(nanoseconds: 20_000_000)
        }
        #expect(FileManager.default.fileExists(atPath: acquiredMarker.path),
                "Swift helper failed to acquire <timeline.jsonl>.lock within deadline")

        let swiftTask = Task {
            try Data("started".utf8).write(to: swiftStartedMarker)
            _ = try await runner.cancel(executionId: "m1")
            try Data("finished".utf8).write(to: swiftFinishedMarker)
        }
        let swiftStartDeadline = Date().addingTimeInterval(10.0)  // task start is a positive step under suite load
        while !FileManager.default.fileExists(atPath: swiftStartedMarker.path) {
            if Date() > swiftStartDeadline { break }
            try? await Task.sleep(nanoseconds: 20_000_000)
        }
        #expect(FileManager.default.fileExists(atPath: swiftStartedMarker.path),
                "Swift cancel task failed to start within deadline")
        try await Task.sleep(nanoseconds: 200_000_000)
        #expect(!FileManager.default.fileExists(atPath: swiftFinishedMarker.path),
                "Swift cancel finished before the foreign timeline lock was released")

        try Data("release".utf8).write(to: releaseRequest)
        try await swiftTask.value
        // Bounded exit wait (never waitUntilExit — a starved helper must fail
        // the test loudly, not wedge the whole serial suite).
        let status = helper.wait(timeout: 30)
        if status == nil {
            helper.terminate()
            Issue.record("flock helper failed to exit within 30s of release — killed")
            return
        }
        #expect(status == 0, "flock helper failed: status \(String(describing: status))")

        let releasedRaw = try String(contentsOf: releasedMarker, encoding: .utf8)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        let helperReleased = try #require(TimeInterval(releasedRaw))
        let swiftFinishedAt = try FileManager.default
            .attributesOfItem(atPath: swiftFinishedMarker.path)[.modificationDate] as? Date
        let swiftEndUnix = try #require(swiftFinishedAt?.timeIntervalSince1970)
        #expect(swiftEndUnix >= helperReleased,
                "Swift cancel finished before helper released the timeline lock — flock ordering violated")

        // Sanity: the cancelled event actually landed after the lock cleared.
        let events = try await runner.readTimeline("m1")
        let cancelled = events.compactMap { obj($0) }.filter { str($0["event"]) == "cancelled" }
        #expect(cancelled.count == 1)
    }
}

// MARK: - WAVE 41 W01 (REOPEN §6.220-rd2 #1) — write-side parity gates
//
// Closes the wave-40 W07 reopen: Mac native execution writes previously bypassed
// the daemon's three submission semantics — the missionPolicy gate
// (_missions_allowed), the _mission_slots capacity gate, and record_activity.
// These tests pin all three on submit() + updateWorkshopExecution().

@Suite("SwiftNativeWorkshopRunner: write-side parity gates (wave 41 W01)")
struct WorkshopExecutionWriteParityGateTests {

    /// Write a `trust/policy.json` under `root` with the given missionPolicy
    /// shape. `workshopPolicyEnabled == nil` omits the `missionPolicy.enabled` key entirely;
    /// `workshopPolicyAbsent == true` omits the whole missionPolicy object.
    private func seedTrustPolicy(
        root: URL,
        persistence: SwiftNativePersistenceCore,
        runner: SwiftNativeWorkshopRunner,
        developerMode: Bool? = nil,
        workshopPolicyEnabled: Bool? = nil,
        workshopPolicyAbsent: Bool = false,
        permissionLevel: String? = nil,
        outsideWorkspaceDefault: String? = nil
    ) async throws {
        var policy: [String: JSONValue] = [:]
        if let dm = developerMode { policy["developerMode"] = .bool(dm) }
        if let pl = permissionLevel { policy["permissionLevel"] = .string(pl) }
        if let od = outsideWorkspaceDefault {
            policy["filePolicy"] = .object(["outsideWorkspaceDefault": .string(od)])
        }
        if !workshopPolicyAbsent {
            var mp: [String: JSONValue] = [:]
            if let en = workshopPolicyEnabled { mp["enabled"] = .bool(en) }
            policy["missionPolicy"] = .object(mp)
        }
        try await persistence.writeJSON(.object(policy), to: runner.trustPolicyPath)
    }

    private func readActivityEvents(_ runner: SwiftNativeWorkshopRunner) -> [[String: JSONValue]] {
        let path = runner.activityPath
        guard let data = try? Data(contentsOf: path),
              let text = String(data: data, encoding: .utf8) else { return [] }
        return text.split(separator: "\n").compactMap { line -> [String: JSONValue]? in
            guard let v = try? JSONValue.parse(Data(line.utf8)), case .object(let o) = v else { return nil }
            return o
        }
    }

    private func seedQueueWorkshopExecution(
        runner: SwiftNativeWorkshopRunner,
        persistence: SwiftNativePersistenceCore,
        id: String,
        status: String,
        currentStepId: String = "step-1"
    ) async throws {
        let o: JSONValue = .object([
            "id": .string(id),
            "title": .string("title-\(id)"),
            "objective": .string("obj-\(id)"),
            "created_at": .string("2026-01-01T00:00:00Z"),
            "status": .string(status),
            "plan": .array([]),
            "steps_completed": .array([]),
            "receipts_dir": .string("/tmp/r/\(id)"),
            "trigger_source": .string("manual"),
            "trust_required": .string("none"),
            "expected_outputs": .array([]),
            "current_step_id": .string(currentStepId),
            "updated_at": .string("2026-01-01T00:00:00Z"),
            "result": .null,
            "rerun_count": .int(0),
        ])
        try await persistence.writeJSON(o, to: runner.executionRecordPath(id))
    }

    // MARK: (a) missionPolicy gate

    @Test func submitAllowedWhenNoTrustPolicyFile() async throws {
        // Fresh root, no policy file → default_trust_policy() has
        // missionPolicy.enabled = true → submit ALLOWED (parity + no regression).
        let root = try makeTempRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let runner = SwiftNativeWorkshopRunner(executorAvailable: true, root: root, planner: ThrowingWorkshopPlannerLLM())
        let result = try await runner.submit(spec: WorkshopExecutionSpec(title: "T", objective: "O"))
        #expect(result.record.status == "queued")
    }

    @Test func submitRefusedWhenWorkshopPolicyDisabled() async throws {
        let root = try makeTempRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let p = SwiftNativePersistenceCore()
        let runner = SwiftNativeWorkshopRunner(executorAvailable: true, root: root, persistence: p, planner: ThrowingWorkshopPlannerLLM())
        try await seedTrustPolicy(root: root, persistence: p, runner: runner, workshopPolicyEnabled: false)
        do {
            _ = try await runner.submit(spec: WorkshopExecutionSpec(title: "T", objective: "O"))
            Issue.record("expected .forbidden when missionPolicy.enabled = false")
        } catch let e as WorkshopExecutionError {
            #expect(e == .forbidden("Workshop execution is disabled by trust policy"))
            #expect(e.parityErrorCode == "forbidden")
        }
    }

    @Test func submitPolicyOffEmptyObjectiveReturnsForbiddenNotMissingObjective() async throws {
        // gpt-5.5 review #1: the daemon route checks _missions_allowed() BEFORE
        // the empty-objective validation, so
        // policy-off + empty objective → 403 forbidden, NOT 400 missing_objective.
        let root = try makeTempRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let p = SwiftNativePersistenceCore()
        let runner = SwiftNativeWorkshopRunner(executorAvailable: true, root: root, persistence: p, planner: ThrowingWorkshopPlannerLLM())
        try await seedTrustPolicy(root: root, persistence: p, runner: runner, workshopPolicyEnabled: false)
        do {
            _ = try await runner.submit(spec: WorkshopExecutionSpec(title: "T", objective: "   "))
            Issue.record("expected .forbidden")
        } catch let e as WorkshopExecutionError {
            #expect(e == .forbidden("Workshop execution is disabled by trust policy"),
                    "policy gate must fire BEFORE objective validation")
        }
    }

    @Test func submitAllowedWhenDeveloperModeTrueDespiteDisabledPolicy() async throws {
        // _missions_allowed = developerMode OR missionPolicy.enabled.
        let root = try makeTempRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let p = SwiftNativePersistenceCore()
        let runner = SwiftNativeWorkshopRunner(executorAvailable: true, root: root, persistence: p, planner: ThrowingWorkshopPlannerLLM())
        try await seedTrustPolicy(root: root, persistence: p, runner: runner,
                                  developerMode: true, workshopPolicyEnabled: false)
        let result = try await runner.submit(spec: WorkshopExecutionSpec(title: "T", objective: "O"))
        #expect(result.record.status == "queued")
    }

    @Test func submitAllowedFullMacPreservesDeveloperModeTrue() async throws {
        // Swift-native policy keeps Developer Mode as the explicit operator
        // escalation independent of the selected access preset.
        let root = try makeTempRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let p = SwiftNativePersistenceCore()
        let runner = SwiftNativeWorkshopRunner(executorAvailable: true, root: root, persistence: p, planner: ThrowingWorkshopPlannerLLM())
        try await seedTrustPolicy(root: root, persistence: p, runner: runner,
                                  developerMode: true, workshopPolicyEnabled: false,
                                  permissionLevel: "full_mac_os")
        let result = try await runner.submit(spec: WorkshopExecutionSpec(title: "T", objective: "O"))
        #expect(result.record.status == "queued")
    }

    @Test func submitAllowedWideOpenReceiptsAllowPreservesDeveloperModeTrue() async throws {
        // The other Full-Mac form: wide_open_receipts + outsideWorkspaceDefault=allow.
        let root = try makeTempRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let p = SwiftNativePersistenceCore()
        let runner = SwiftNativeWorkshopRunner(executorAvailable: true, root: root, persistence: p, planner: ThrowingWorkshopPlannerLLM())
        try await seedTrustPolicy(root: root, persistence: p, runner: runner,
                                  developerMode: true, workshopPolicyEnabled: false,
                                  permissionLevel: "wide_open_receipts", outsideWorkspaceDefault: "allow")
        let result = try await runner.submit(spec: WorkshopExecutionSpec(title: "T", objective: "O"))
        #expect(result.record.status == "queued")
    }

    @Test func submitAllowedDeveloperModeNonFullMacStillHonored() async throws {
        // Sanity: developerMode:true is still honored outside Full Mac too.
        let root = try makeTempRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let p = SwiftNativePersistenceCore()
        let runner = SwiftNativeWorkshopRunner(executorAvailable: true, root: root, persistence: p, planner: ThrowingWorkshopPlannerLLM())
        try await seedTrustPolicy(root: root, persistence: p, runner: runner,
                                  developerMode: true, workshopPolicyEnabled: false,
                                  permissionLevel: "balanced")
        let result = try await runner.submit(spec: WorkshopExecutionSpec(title: "T", objective: "O"))
        #expect(result.record.status == "queued")
    }

    @Test func submitAllowedWhenWorkshopPolicyAbsent() async throws {
        // Saved policy with NO missionPolicy object → merged default enabled=true.
        let root = try makeTempRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let p = SwiftNativePersistenceCore()
        let runner = SwiftNativeWorkshopRunner(executorAvailable: true, root: root, persistence: p, planner: ThrowingWorkshopPlannerLLM())
        try await seedTrustPolicy(root: root, persistence: p, runner: runner, workshopPolicyAbsent: true)
        let result = try await runner.submit(spec: WorkshopExecutionSpec(title: "T", objective: "O"))
        #expect(result.record.status == "queued")
    }

    @Test func submitAllowedWhenEnabledKeyAbsent() async throws {
        // missionPolicy present but NO `enabled` key → merged default true.
        let root = try makeTempRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let p = SwiftNativePersistenceCore()
        let runner = SwiftNativeWorkshopRunner(executorAvailable: true, root: root, persistence: p, planner: ThrowingWorkshopPlannerLLM())
        try await seedTrustPolicy(root: root, persistence: p, runner: runner, workshopPolicyEnabled: nil)
        let result = try await runner.submit(spec: WorkshopExecutionSpec(title: "T", objective: "O"))
        #expect(result.record.status == "queued")
    }

    @Test func updateReturnsNilWhenWorkshopPolicyDisabled() async throws {
        // The daemon runs the queue-bridge ONLY inside `if _missions_allowed()`.
        // Off → native returns nil so the daemon legacy path stays Python.
        // A real queue execution EXISTS on disk, but the gate must short-circuit
        // BEFORE matching it.
        let root = try makeTempRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let p = SwiftNativePersistenceCore()
        let runner = SwiftNativeWorkshopRunner(executorAvailable: true, root: root, persistence: p, planner: ThrowingWorkshopPlannerLLM(), now: fixedNow())
        try await seedTrustPolicy(root: root, persistence: p, runner: runner, workshopPolicyEnabled: false)
        try await seedQueueWorkshopExecution(runner: runner, persistence: p, id: "m1", status: "running")
        let rec = try await runner.updateWorkshopExecution(WorkshopExecutionUpdate(id: "m1", status: "completed"))
        #expect(rec == nil, "policy off → updateWorkshopExecution must return nil (daemon legacy fallthrough)")
        // And the Workshop execution on disk must be UNTOUCHED.
        let data = try Data(contentsOf: runner.executionRecordPath("m1"))
        guard case .object(let o) = try JSONValue.parse(data) else { Issue.record("bad json"); return }
        #expect(str(o["status"]) == "running", "policy-off update must not mutate the execution")
    }

    // MARK: (b) _mission_slots capacity gate

    @Test func submitRefusedWhenSlotsFull() async throws {
        // Override the cap to a tiny number without touching process-global env
        // (Swift Testing runs sibling tests in parallel).
        let root = try makeTempRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let p = SwiftNativePersistenceCore()
        let runner = SwiftNativeWorkshopRunner(
            executorAvailable: true,
            root: root,
            persistence: p,
            planner: ThrowingWorkshopPlannerLLM(),
            workshopExecutionSlotsCapOverride: 2
        )
        // Seed 2 ACTIVE Workshop executions (queued + running) → at cap.
        try await seedQueueWorkshopExecution(runner: runner, persistence: p, id: "a", status: "queued")
        try await seedQueueWorkshopExecution(runner: runner, persistence: p, id: "b", status: "running")
        do {
            _ = try await runner.submit(spec: WorkshopExecutionSpec(title: "T", objective: "O"))
            Issue.record("expected .workshopExecutionsBusy when slots are full")
        } catch let e as WorkshopExecutionError {
            #expect(e == .workshopExecutionsBusy("missions_busy: too many active or pending Workshop executions"))
            #expect(e.parityErrorCode == "missions_busy")
        }
    }

    @Test func submitAllowedWhenSlotsAvailableTerminalDontCount() async throws {
        // Terminal Workshop executions (completed/failed/cancelled) are NOT active, so they
        // don't consume a slot — mirrors list_active.
        let root = try makeTempRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let p = SwiftNativePersistenceCore()
        let runner = SwiftNativeWorkshopRunner(
            executorAvailable: true,
            root: root,
            persistence: p,
            planner: ThrowingWorkshopPlannerLLM(),
            workshopExecutionSlotsCapOverride: 2
        )
        // 1 active + 2 terminal → active count is 1 < cap 2 → allowed.
        try await seedQueueWorkshopExecution(runner: runner, persistence: p, id: "a", status: "running")
        try await seedQueueWorkshopExecution(runner: runner, persistence: p, id: "b", status: "completed")
        try await seedQueueWorkshopExecution(runner: runner, persistence: p, id: "c", status: "cancelled")
        let result = try await runner.submit(spec: WorkshopExecutionSpec(title: "T", objective: "O"))
        #expect(result.record.status == "queued")
    }

    // MARK: (c) record_activity

    @Test func submitEmitsWorkshopExecutionCreatedActivity() async throws {
        let root = try makeTempRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let p = SwiftNativePersistenceCore()
        let runner = SwiftNativeWorkshopRunner(executorAvailable: true, root: root, persistence: p, planner: ThrowingWorkshopPlannerLLM(),
                                              now: fixedNow(), uuid: fixedUUID())
        let result = try await runner.submit(spec: WorkshopExecutionSpec(title: "MyTitle", objective: "O"))
        let events = readActivityEvents(runner)
        let created = events.filter { str($0["title"]) == "Workshop task created" }
        #expect(created.count == 1, "submit must emit exactly one 'Execution created' activity row")
        guard let ev = created.first else { return }
        #expect(str(ev["kind"]) == "mission")
        #expect(str(ev["detail"]) == "MyTitle")
        #expect(str(ev["status"]) == "ok")
        #expect(str(ev["missionId"]) == result.executionId)
        // payload.missionId mirrors the daemon.
        guard case .object(let payload)? = ev["payload"] else { Issue.record("payload missing"); return }
        #expect(str(payload["missionId"]) == result.executionId)
        // createdAt is an ISO timestamp.
        #expect(str(ev["createdAt"]) == SwiftNativeWorkshopRunner.isoTimestamp(fixedNow()()))
    }

    @Test func updateEmitsWorkshopExecutionUpdatedActivity() async throws {
        let root = try makeTempRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let p = SwiftNativePersistenceCore()
        let runner = SwiftNativeWorkshopRunner(executorAvailable: true, root: root, persistence: p, planner: ThrowingWorkshopPlannerLLM(), now: fixedNow())
        try await seedQueueWorkshopExecution(runner: runner, persistence: p, id: "m1", status: "running")
        _ = try await runner.updateWorkshopExecution(WorkshopExecutionUpdate(id: "m1", status: "completed"))
        let events = readActivityEvents(runner)
        let updated = events.filter { str($0["title"]) == "Workshop task updated" }
        #expect(updated.count == 1)
        guard let ev = updated.first else { return }
        #expect(str(ev["kind"]) == "mission")
        #expect(str(ev["detail"]) == "title-m1")
        #expect(str(ev["status"]) == "ok")   // "completed" is not failed/blocked
        #expect(str(ev["missionId"]) == "m1")
        guard case .object(let payload)? = ev["payload"] else { Issue.record("payload missing"); return }
        #expect(str(payload["status"]) == "completed")
        // queue Execution has no phase → null (documented §6.240).
        #expect(payload["phase"] == .null)
    }

    @Test func updateFailedStatusEmitsWarnActivity() async throws {
        let root = try makeTempRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let p = SwiftNativePersistenceCore()
        let runner = SwiftNativeWorkshopRunner(executorAvailable: true, root: root, persistence: p, planner: ThrowingWorkshopPlannerLLM(), now: fixedNow())
        try await seedQueueWorkshopExecution(runner: runner, persistence: p, id: "m1", status: "running")
        _ = try await runner.updateWorkshopExecution(WorkshopExecutionUpdate(id: "m1", status: "failed"))
        let events = readActivityEvents(runner)
        let updated = events.filter { str($0["title"]) == "Workshop task updated" }
        #expect(updated.first.flatMap { str($0["status"]) } == "warn",
                "failed/blocked status maps to 'warn' (native_agentd.py L5494)")
    }

    @Test func updateNoChangeEmitsNoActivity() async throws {
        // changed=false (id-only patch) → daemon writes nothing → no activity row.
        let root = try makeTempRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let p = SwiftNativePersistenceCore()
        let runner = SwiftNativeWorkshopRunner(executorAvailable: true, root: root, persistence: p, planner: ThrowingWorkshopPlannerLLM())
        try await seedQueueWorkshopExecution(runner: runner, persistence: p, id: "m1", status: "running")
        _ = try await runner.updateWorkshopExecution(WorkshopExecutionUpdate.fromBody(["id": .string("m1")]))
        let events = readActivityEvents(runner)
        #expect(events.filter { str($0["title"]) == "Workshop task updated" }.isEmpty,
                "a no-op update must not emit an activity row")
    }

    @Test func unknownWorkshopExecutionUpdateEmitsNoActivity() async throws {
        // nil return (not a queue execution) → no activity row (daemon records on
        // its OWN legacy path, which stays Python).
        let root = try makeTempRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let p = SwiftNativePersistenceCore()
        let runner = SwiftNativeWorkshopRunner(executorAvailable: true, root: root, persistence: p, planner: ThrowingWorkshopPlannerLLM())
        let rec = try await runner.updateWorkshopExecution(WorkshopExecutionUpdate(id: "ghost", status: "done"))
        #expect(rec == nil)
        #expect(readActivityEvents(runner).isEmpty)
    }

    @Test func cancelEmitsNoActivity() async throws {
        // Parity: NEITHER the daemon queue cancel route NOR missions.py cancel
        // calls record_activity. The reopen scoped activity to create/submit/
        // update — NOT cancel. Pin that the native cancel stays silent.
        let root = try makeTempRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let p = SwiftNativePersistenceCore()
        let runner = SwiftNativeWorkshopRunner(executorAvailable: true, root: root, persistence: p, planner: ThrowingWorkshopPlannerLLM(), now: fixedNow())
        try await seedQueueWorkshopExecution(runner: runner, persistence: p, id: "m1", status: "running")
        _ = try await runner.cancel(executionId: "m1")
        #expect(readActivityEvents(runner).isEmpty,
                "cancel must emit NO activity row (daemon parity)")
    }

    // MARK: (c) record_activity — secret redaction (gpt-5.5 review #4)

    @Test func submitActivityRedactsSecretInTitle() async throws {
        // A real-looking OpenAI key in the execution title must be redacted in the
        // Activity feed (parity with the daemon's redact_secret_text).
        let root = try makeTempRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let p = SwiftNativePersistenceCore()
        let runner = SwiftNativeWorkshopRunner(executorAvailable: true, root: root, persistence: p, planner: ThrowingWorkshopPlannerLLM(),
                                              now: fixedNow(), uuid: fixedUUID())
        let secret = ["sk", "proj", "ABCDEFGHIJKLMNOPQRSTUVWX1234"].joined(separator: "-")
        _ = try await runner.submit(spec: WorkshopExecutionSpec(title: "key \(secret) here", objective: "O"))
        let created = readActivityEvents(runner).first { str($0["title"]) == "Workshop task created" }
        let detail = created.flatMap { str($0["detail"]) } ?? ""
        #expect(!detail.contains(secret), "the OpenAI key must NOT appear verbatim in the activity detail")
        #expect(detail.contains("[REDACTED_OPENAI_KEY:"), "the key must be replaced with the redaction marker")
    }

    @Test func updateActivityRedactsSecretInPayloadStatus() async throws {
        // Redaction recurses into payload string values (redact_secret_value).
        let root = try makeTempRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let p = SwiftNativePersistenceCore()
        let runner = SwiftNativeWorkshopRunner(executorAvailable: true, root: root, persistence: p, planner: ThrowingWorkshopPlannerLLM(), now: fixedNow())
        try await seedQueueWorkshopExecution(runner: runner, persistence: p, id: "m1", status: "running")
        // A status carrying a token (contrived, but exercises payload recursion).
        let token = ["ghp", "ABCDEFGHIJKLMNOPQRSTUVWXYZ012345"].joined(separator: "_")
        _ = try await runner.updateWorkshopExecution(WorkshopExecutionUpdate(id: "m1", status: token))
        let updated = readActivityEvents(runner).first { str($0["title"]) == "Workshop task updated" }
        guard case .object(let payload)? = updated?["payload"] else { Issue.record("no payload"); return }
        let st = str(payload["status"]) ?? ""
        #expect(!st.contains(token))
        #expect(st.contains("[REDACTED_GITHUB_TOKEN:"))
    }

    @Test func workshopExecutionsRedactorMirrorsDaemonPatterns() {
        // Pins the redactor's kind labels + marker format against the daemon
        // literals. A plain string is
        // untouched; each credential class is replaced with its named marker.
        #expect(NativeAgentSecretRedactor.redactText("hello world") == "hello world")
        #expect(NativeAgentSecretRedactor.redactText(["AIza", "ABCDEFGHIJKLMNOPQRSTUVWXYZ0"].joined()).contains("[REDACTED_GOOGLE_API_KEY:"))
        #expect(NativeAgentSecretRedactor.redactText(["Bearer", "ABCDEFGHIJKLMNOPQRSTUVWXYZ012345"].joined(separator: " ")).contains("[REDACTED_BEARER_TOKEN:"))
        // redactValue recurses arrays + objects, leaves non-strings alone.
        // NOTE: the OpenAI pattern `sk-(?:proj-)?...` runs BEFORE the Anthropic
        // `sk-ant-...` pattern, so `sk-ant-...` is caught by OPENAI_KEY first —
        // exactly the daemon's order-dependent behavior. Assert it is redacted
        // (any marker), not the specific kind.
        let v: JSONValue = .object([
            "a": .string("sk-ant-ABCDEFGHIJKLMNOPQRSTUVWX"),
            "n": .int(7),
            "arr": .array([.string("xoxb-ABCDEFGHIJKLMNOPQRSTUVWX")]),
        ])
        guard case .object(let out) = NativeAgentSecretRedactor.redactValue(v) else { Issue.record("not object"); return }
        #expect(str(out["a"])?.contains("[REDACTED_") == true)
        #expect(str(out["a"])?.contains("sk-ant-ABCDEFGHIJKLMNOPQRSTUVWX") == false)
        #expect(out["n"] == .int(7))
        if case .array(let arr) = out["arr"], case .string(let s0)? = arr.first {
            #expect(s0.contains("[REDACTED_SLACK_TOKEN:"))
        } else {
            Issue.record("arr not redacted")
        }
    }
}

// MARK: - Executor gate (2026-06-10; default flipped TRUE when the executor port landed)

@Suite("SwiftNativeWorkshopRunner: executor gate")
struct ExecutorGateSuite {
    @Test func defaultRunnerEnqueuesNowThatExecutorExists() async throws {
        // NEW CONTRACT (executor port, 2026-06-10): default
        // executorAvailable=true — WorkshopExecutorLoop drains queued
        // executions, so a default-constructed runner accepts submits and
        // lands the execution durably in `queued`.
        let tmp = FileManager.default.temporaryDirectory
            .appendingPathComponent("executions-exec-gate-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: tmp) }
        let recorder = RecordingWorkshopPlannerLLM { _ in ("m", "{\"steps\":[]}") }
        let runner = SwiftNativeWorkshopRunner(root: tmp, planner: recorder)
        let result = try await runner.submit(spec: WorkshopExecutionSpec(title: "T", objective: "O"))
        #expect(result.status == "queued")
        let executionRecordJSON = tmp.appendingPathComponent("workshop/executions/\(result.executionId)/mission.json")
        #expect(FileManager.default.fileExists(atPath: executionRecordJSON.path))
    }

    @Test func explicitFalseStillRefusesSubmit() async throws {
        // The gate still fails closed when a caller explicitly opts out
        // (executorAvailable: false — an embedding with no executor loop
        // registered): refuse BEFORE the policy gate, validation, slot
        // check, planner, and any file IO. The planner recording proves no
        // LLM call was burned.
        let tmp = FileManager.default.temporaryDirectory
            .appendingPathComponent("executions-exec-gate-off-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: tmp) }
        let recorder = RecordingWorkshopPlannerLLM { _ in ("m", "{\"steps\":[]}") }
        let runner = SwiftNativeWorkshopRunner(executorAvailable: false, root: tmp, planner: recorder)
        await #expect(throws: WorkshopExecutionError.executorUnavailable(
            "Workshop executor unavailable; submission is disabled"
        )) {
            _ = try await runner.submit(spec: WorkshopExecutionSpec(title: "T", objective: "O"))
        }
        let queueDir = tmp.appendingPathComponent("workshop/executions")
        #expect(!FileManager.default.fileExists(atPath: queueDir.path))
    }
}
