import Foundation
import Testing
@testable import SwarmRuns
import NativeAgentCore
import PersistenceCore

private enum LifecycleReceiptError: Error { case injectedWriteFailure }

@Test func swarmDeadlineRetainsLateEvidenceWithoutClaimingCompletion() async throws {
    let executor = SwiftNativeAgentSwarmExecutor(llm: LifecycleTraceLLM(),
        runsPath: FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString))
    do {
        _ = try await executor.withTimeout(seconds: 1, reportID: "deadline-fixture") {
            // A worker that settles after cancellation, rather than throwing.
            do { try await Task.sleep(for: .seconds(60)) } catch { }
            return "late retained evidence"
        }
        Issue.record("Late output must not count as successful completion")
    } catch let incomplete as AgentSwarmWorkerIncomplete {
        #expect(incomplete.output == "late retained evidence")
        #expect(incomplete.reason.contains("settlement awaited"))
        #expect(incomplete.reason.contains("not verified completion"))
    }
    let onTime = try await executor.withTimeout(seconds: 60, reportID: "on-time-fixture") { "on time" }
    #expect(onTime == "on time")
}

private struct LifecycleIncompleteWorker: AgentSwarmWorkerRunning {
    func runWorker(prompt: String, model: String, reasoningEffort: String, access: String,
                   originSurface: String, originSessionId: String?) async throws -> String {
        throw AgentSwarmWorkerIncomplete(output: String(repeating: "retained partial evidence ", count: 40),
                                         reason: "tool turn incomplete; attempted effects remain unverified")
    }
}

private actor LifecycleTraceLLM: LLMClient {
    private(set) var traceIds: [String?] = []

    func complete(prompt: String, system: String?, model: String?) async throws -> String {
        traceIds.append(TurnTraceContext.turnId)
        TurnTraceBus.fireFromContext(kind: "llm.call", surface: "swarms", payload: .object(["fixture": .bool(true)]))
        return "retained fixture result"
    }
}

private actor LifecycleTraceWorker: AgentSwarmWorkerRunning {
    private(set) var callerTraceId: String?
    private(set) var ownTraceId: String?
    private(set) var origin: String?
    private(set) var session: String?

    func runWorker(prompt: String, model: String, reasoningEffort: String, access: String, originSurface: String, originSessionId: String?) async throws -> String {
        callerTraceId = TurnTraceContext.turnId
        origin = originSurface
        session = originSessionId
        return TurnTraceContext.$turnId.withValue("ephemeral-worker-owned-id") {
            ownTraceId = TurnTraceContext.turnId
            return "inherited fixture result"
        }
    }
}

@Test(arguments: [false, true])
func swarmLifecycle_promptTraceIDsMatchStoredReceiptsAndKeepParentLinks(hasParent: Bool) async throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent("swarm-trace-\(UUID().uuidString)")
    defer { try? FileManager.default.removeItem(at: root) }
    let workerRoot = root.appendingPathComponent("worker-trace")
    let parentRoot = root.appendingPathComponent("parent-trace")
    let workerBus = TurnTraceBus(persistLane: TurnTracePersistLane(dataRootOverride: workerRoot))
    let parentBus = TurnTraceBus(persistLane: TurnTracePersistLane(dataRootOverride: parentRoot))
    let llm = LifecycleTraceLLM()
    let inherited = LifecycleTraceWorker()
    let executor = SwiftNativeAgentSwarmExecutor(llm: llm, runsPath: root.appendingPathComponent("swarms/runs.json"),
                                               workerRunner: inherited, turnTraceBus: workerBus)
    let request = try AgentSwarmRunRequest.parse(input: [
        "objective": .string("private objective must not be in link events"),
        "surface": .string("telegram"), "__session_id": .string("telegram:verified"),
        "agents": .array([
            .object(["role": .string("first")]),
            .object(["role": .string("second")]),
            .object(["role": .string("inherited"), "access": .string("inherit")]),
        ]),
    ], policy: AgentSwarmPolicy())
    let result = try await TurnTraceContext.$turnId.withValue(hasParent ? "parent-turn-id" : nil) {
        try await TurnTraceContext.$bus.withValue(hasParent ? parentBus : nil) {
            try await executor.run(request: request, policy: AgentSwarmPolicy())
        }
    }
    let expected = Set([result.workers[0].id, result.workers[1].id, "\(result.id)-synthesis"])
    let calls = await llm.traceIds
    #expect(Set(calls.compactMap { $0 }) == expected)
    #expect(calls.count == 3)
    #expect(await inherited.callerTraceId == (hasParent ? "parent-turn-id" : nil))
    #expect(await inherited.ownTraceId == "ephemeral-worker-owned-id")
    #expect(await inherited.origin == "telegram")
    #expect(await inherited.session == "telegram:verified")
    let selectedBus = hasParent ? parentBus : workerBus
    await selectedBus.drainForProcessExit()
    let snapshot = try await TurnTraceRecentReader(dataRootOverride: hasParent ? parentRoot : workerRoot).read()
    let links = snapshot.events.filter { $0.kind == "swarm.report.started" }
    #expect(links.count == 3)
    #expect(Set(links.map(\.turnId)) == expected)
    #expect(Set(snapshot.events.filter { $0.kind == "llm.call" }.map(\.turnId)) == expected)
    for link in links {
        guard case .object(let payload) = link.payload else { Issue.record("missing link IDs"); continue }
        #expect(payload["swarmRunId"] == .string(result.id))
        #expect(payload["parentTurnId"] == (hasParent ? .string("parent-turn-id") : nil))
        #expect(Set(payload.keys) == Set(hasParent ? ["swarmRunId", "reportId", "parentTurnId"] : ["swarmRunId", "reportId"]))
        #expect(link.sessionId == "telegram:verified")
        #expect(payload["reportId"] == .string(link.turnId == "\(result.id)-synthesis" ? "synthesis" : link.turnId))
    }
    let other = try await TurnTraceRecentReader(dataRootOverride: hasParent ? workerRoot : parentRoot).read()
    #expect(other.events.isEmpty)
    let stored = await SwiftNativePersistenceCore().readJSON(root.appendingPathComponent("swarms/runs.json"), defaultValue: .null)
    // Compare the complete persisted representation. JSONSerialization can
    // round a submillisecond Double duration by a few ULPs during decoding;
    // in-memory bit equality is not the receipt's wire contract. IDs, links,
    // outputs, statuses and every other field still have to match exactly.
    let expectedStored = try JSONValue.parse(JSONValue.array([result.json]).serializedData(pretty: true))
    #expect(stored == expectedStored)
}

/// A controllable cancellation-sensitive persistence suspension. This models
/// the contended lock's cancellation checkpoint without wall-clock sleeps.
private actor LifecycleReceiptPersistence: PersistenceCoreProtocol {
    let inner = SwiftNativePersistenceCore()
    let failWrites: Bool
    let failAfterCommit: Bool
    private var entered = false
    private var released: Bool
    private var enteredWaiter: CheckedContinuation<Void, Never>?
    private var releaseWaiter: CheckedContinuation<Void, Never>?
    private(set) var cancelledAtWrite: Bool?
    private(set) var traceAtWrite: String?

    init(failWrites: Bool = false, failAfterCommit: Bool = false) {
        self.failWrites = failWrites
        self.failAfterCommit = failAfterCommit
        released = failWrites
    }

    func waitForWrite() async {
        if entered { return }
        await withCheckedContinuation { enteredWaiter = $0 }
    }

    func releaseWrite() {
        released = true
        releaseWaiter?.resume()
        releaseWaiter = nil
    }

    func readJSON(_ path: URL, defaultValue: JSONValue) async -> JSONValue {
        await inner.readJSON(path, defaultValue: defaultValue)
    }

    func writeJSON(_ value: JSONValue, to path: URL) async throws {
        cancelledAtWrite = Task.isCancelled
        traceAtWrite = TurnTraceContext.turnId
        entered = true
        enteredWaiter?.resume()
        enteredWaiter = nil
        if !released { await withCheckedContinuation { releaseWaiter = $0 } }
        try Task.checkCancellation()
        if failWrites {
            if failAfterCommit { try await inner.writeJSON(value, to: path) }
            throw LifecycleReceiptError.injectedWriteFailure
        }
        try await inner.writeJSON(value, to: path)
    }

    func appendJSONL(_ record: JSONValue, to path: URL) async throws { try await inner.appendJSONL(record, to: path) }
    func tailJSONL(_ path: URL, limit: Int, maxBytes: Int?) async throws -> [JSONValue] {
        try await inner.tailJSONL(path, limit: limit, maxBytes: maxBytes)
    }
    func readJSONL(_ path: URL) async throws -> [JSONValue] { try await inner.readJSONL(path) }
}

/// All providers are inert. The cancellation gate synchronizes on actual
/// worker admission, not a delay that can pass before work has started.
private actor LifecycleSwarmLLM: LLMClient {
    enum Behavior: Sendable {
        case blankWorkers
        case blankSynthesis
        case suspendSecondWorker
        case reports
    }

    let behavior: Behavior
    private(set) var prompts: [String] = []
    private var secondStarted = false
    private var secondWaiter: CheckedContinuation<Void, Never>?

    init(_ behavior: Behavior) { self.behavior = behavior }

    func waitForSecondWorker() async {
        if secondStarted { return }
        await withCheckedContinuation { secondWaiter = $0 }
    }

    func complete(prompt: String, system: String?, model: String?) async throws -> String {
        try await complete(prompt: prompt, system: system, model: model, surface: "swarms")
    }

    func complete(prompt: String, system: String?, model: String?, surface: String) async throws -> String {
        prompts.append(prompt)
        let synthesis = prompt.contains("SYNTHESIS:")
        switch behavior {
        case .blankWorkers:
            return " \n\t "
        case .blankSynthesis:
            return synthesis ? " \n " : "useful worker finding"
        case .suspendSecondWorker:
            if prompts.count == 2 {
                secondStarted = true
                secondWaiter?.resume()
                secondWaiter = nil
                try await Task.sleep(nanoseconds: 120_000_000_000)
            }
            return "completed worker finding"
        case .reports:
            return synthesis ? "bounded summary" : String(repeating: "evidence ", count: 100)
        }
    }
}

private func lifecycleRequest(count: Int = 2) throws -> AgentSwarmRunRequest {
    try AgentSwarmRunRequest.parse(
        input: [
            "objective": .string("Answer a bounded general-purpose question"),
            "agentCount": .int(Int64(count)),
            "maxParallel": .int(1),
            "synthesize": .bool(true),
            "maxOutputChars": .int(500),
        ],
        policy: AgentSwarmPolicy(storeReceipts: false)
    )
}

@Test(arguments: [false, true])
func swarmLifecycle_incompleteToolWorkerRetainsBoundedEvidenceWithoutCompletion(includeCompletedSibling: Bool) async throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent("swarm-incomplete-\(UUID().uuidString)")
    defer { try? FileManager.default.removeItem(at: root) }
    let llm = LifecycleSwarmLLM(.reports)
    var workers: [JSONValue] = [.object(["role": .string("tool worker"), "access": .string("inherit")])]
    if includeCompletedSibling { workers.append(.object(["role": .string("prompt-only sibling")])) }
    let policy = AgentSwarmPolicy(storeReceipts: true)
    let request = try AgentSwarmRunRequest.parse(input: [
        "objective": .string("Retain evidence without claiming completion"), "agents": .array(workers),
        "maxOutputChars": .int(500), "synthesize": .bool(true),
    ], policy: policy)
    let path = root.appendingPathComponent("runs.json")
    let result = try await SwiftNativeAgentSwarmExecutor(llm: llm, runsPath: path,
                                                        workerRunner: LifecycleIncompleteWorker()).run(request: request, policy: policy)
    #expect(result.status == (includeCompletedSibling ? "partial" : "failed"))
    #expect(result.summary.failed == 1)
    #expect(result.summary.completed == (includeCompletedSibling ? 1 : 0))
    let worker = result.workers[0]
    #expect(worker.status == "failed")
    #expect(worker.output.hasPrefix("retained partial evidence"))
    #expect(worker.outputTruncated)
    #expect(worker.output.count == 500)
    #expect(worker.error?.contains("incomplete") == true)
    #expect(worker.error?.contains("unverified") == true)
    #expect(result.synthesis?.status == (includeCompletedSibling ? "completed" : nil))
    #expect(await llm.prompts.count == (includeCompletedSibling ? 2 : 0))
    let stored = await SwiftNativePersistenceCore().readJSON(path, defaultValue: .null)
    // Compare at the persisted JSON boundary: submillisecond durations may
    // round during decimal serialization without changing any receipt field.
    let expectedStored = try JSONValue.parse(JSONValue.array([result.json]).serializedData(pretty: false))
    #expect(stored == expectedStored)
}

@Test func swarmLifecycle_blankWorkersFailAndDoNotSpendOnSynthesis() async throws {
    let llm = LifecycleSwarmLLM(.blankWorkers)
    let result = try await SwiftNativeAgentSwarmExecutor(llm: llm).run(
        request: lifecycleRequest(), policy: AgentSwarmPolicy(storeReceipts: false)
    )
    #expect(result.status == "failed")
    #expect(result.summary.failed == 2)
    #expect(result.workers.allSatisfy { $0.error?.contains("no usable output") == true })
    #expect(result.synthesis?.status == "skipped")
    #expect(await llm.prompts.count == 2)
}

@Test func swarmLifecycle_blankSynthesisIsPartialNotCompleted() async throws {
    let llm = LifecycleSwarmLLM(.blankSynthesis)
    let result = try await SwiftNativeAgentSwarmExecutor(llm: llm).run(
        request: lifecycleRequest(), policy: AgentSwarmPolicy(storeReceipts: false)
    )
    #expect(result.status == "partial")
    #expect(result.summary.completed == 2)
    #expect(result.synthesis?.status == "failed")
    #expect(result.synthesis?.error?.contains("no usable output") == true)
    #expect(await llm.prompts.count == 3)
}

@Test func swarmLifecycle_cancellationStopsQueuedWorkersAndSynthesisRetainingCompletedEvidence() async throws {
    let llm = LifecycleSwarmLLM(.suspendSecondWorker)
    let request = try lifecycleRequest(count: 4)
    let task = Task {
        try await SwiftNativeAgentSwarmExecutor(llm: llm).run(
            request: request, policy: AgentSwarmPolicy(storeReceipts: false)
        )
    }
    await llm.waitForSecondWorker()
    task.cancel()
    let result = try await task.value
    #expect(result.status == "cancelled")
    #expect(result.summary.completed == 1)
    #expect(result.summary.failed == 0)
    #expect(result.summary.cancelled == 3)
    #expect(result.workers[0].output == "completed worker finding")
    #expect(result.workers[1].error?.contains("unverified") == true)
    #expect(result.workers[2].error?.contains("not started") == true)
    #expect(result.synthesis?.status == "skipped")
    #expect(await llm.prompts.count == 2)
}

@Test func swarmLifecycle_preCancelledRunNeverCallsProvider() async throws {
    let llm = LifecycleSwarmLLM(.reports)
    let request = try lifecycleRequest()
    let task = Task {
        withUnsafeCurrentTask { $0?.cancel() }
        return try await SwiftNativeAgentSwarmExecutor(llm: llm).run(
            request: request, policy: AgentSwarmPolicy(storeReceipts: false)
        )
    }
    let result = try await task.value
    #expect(result.status == "cancelled")
    #expect(result.summary.cancelled == 2)
    #expect(await llm.prompts.isEmpty)
}

@Test func swarmLifecycle_cancelledParentStillAwaitsTerminalReceiptsWithTraceContext() async throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent("swarm-terminal-receipt-\(UUID().uuidString)")
    defer { try? FileManager.default.removeItem(at: root) }
    let runsPath = root.appendingPathComponent("swarms/runs.json")
    let persistence = LifecycleReceiptPersistence()
    let llm = LifecycleSwarmLLM(.suspendSecondWorker)
    let request = try lifecycleRequest(count: 4)
    let task = Task {
        try await TurnTraceContext.$turnId.withValue("original-swarm-turn") {
            try await SwiftNativeAgentSwarmExecutor(llm: llm, runsPath: runsPath, persistence: persistence).run(
                request: request, policy: AgentSwarmPolicy(storeReceipts: true)
            )
        }
    }
    await llm.waitForSecondWorker()
    task.cancel()
    await persistence.waitForWrite()
    await persistence.releaseWrite()
    let result = try await task.value
    #expect(await persistence.cancelledAtWrite == false)
    #expect(await persistence.traceAtWrite == "original-swarm-turn")
    #expect(result.status == "cancelled")
    #expect(result.summary.completed == 1)
    #expect(result.summary.cancelled == 3)
    let stored = await SwiftNativePersistenceCore().readJSON(runsPath, defaultValue: .null)
    guard case .array(let receipts) = stored else {
        Issue.record("cancelled swarm must retain its terminal receipt")
        return
    }
    let expectedStored = try JSONValue.parse(JSONValue.array([result.json]).serializedData(pretty: false))
    #expect(JSONValue.array(receipts) == expectedStored)
    #expect(result.workers[0].output == "completed worker finding")
    #expect(result.workers[1].error?.contains("unverified") == true)
    #expect(result.workers[2].error?.contains("not started") == true)
    let summary = await SwiftNativePersistenceCore().readJSON(root.appendingPathComponent("runs/runs.json"), defaultValue: .null)
    guard case .array(let rows) = summary, case .object(let row)? = rows.first else {
        Issue.record("cancelled swarm must retain its cross-surface summary")
        return
    }
    #expect(row["id"] == .string(result.id))
    #expect(row["status"] == .string("cancelled"))
    #expect(row["output"] == .string("1 worker(s) completed, 0 failed, 3 cancelled"))
    #expect(row["error"] == .string("swarm cancelled; completed worker output is retained, but interrupted effects are not verified"))
    #expect(await llm.prompts.count == 2)
}

@Test(arguments: [false, true])
func swarmLifecycle_terminalShieldPreservesRealWriteErrors(failAfterCommit: Bool) async throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent("swarm-terminal-error-\(UUID().uuidString)")
    defer { try? FileManager.default.removeItem(at: root) }
    let persistence = LifecycleReceiptPersistence(failWrites: true, failAfterCommit: failAfterCommit)
    do {
        _ = try await SwiftNativeAgentSwarmExecutor(
            llm: LifecycleSwarmLLM(.reports), runsPath: root.appendingPathComponent("swarms/runs.json"), persistence: persistence
        ).run(request: lifecycleRequest(), policy: AgentSwarmPolicy(storeReceipts: true))
        Issue.record("an actual receipt-write failure must still throw")
    } catch let failure as AgentSwarmReceiptPersistenceError {
        #expect(failure.underlyingError is LifecycleReceiptError)
        #expect(UUID(uuidString: failure.runID) != nil)
        #expect(failure.runStatus == "completed")
        #expect(failure.summary.completed == 2)
        #expect(failure.summary.failed == 0)
        #expect(failure.summary.cancelled == 0)
        let message = try #require(failure.errorDescription)
        #expect(message.count < 2_000)
        #expect(message.contains("run_id='\(failure.runID)'"))
        #expect(message.contains("Receipt persistence is unconfirmed"))
        #expect(message.contains("Do not rerun workers"))
        #expect(!message.contains(root.path))
        let stored = await SwiftNativePersistenceCore().readJSON(root.appendingPathComponent("swarms/runs.json"), defaultValue: .null)
        if failAfterCommit {
            guard case .array(let rows) = stored, case .object(let row)? = rows.first else {
                Issue.record("fixture committed receipt must remain inspectable"); return
            }
            #expect(row["id"] == .string(failure.runID))
        } else {
            #expect(stored == .null)
        }
        #expect(!FileManager.default.fileExists(atPath: root.appendingPathComponent("runs/runs.json").path))
    }
}

@Test func swarmLifecycle_receiptFailureMessageKeepsUnderlyingDiagnosticsPrivate() throws {
    let privateDescription = String(repeating: "/private/fixture/secret-diagnostic ", count: 100)
    let underlying = NSError(domain: NSCocoaErrorDomain, code: NSFileWriteOutOfSpaceError,
                             userInfo: [NSLocalizedDescriptionKey: privateDescription])
    let failure = AgentSwarmReceiptPersistenceError(
        runID: UUID().uuidString, runStatus: "partial",
        summary: AgentSwarmSummary(completed: 1, failed: 1, cancelled: 0), underlyingError: underlying
    )
    let message = try #require(failure.errorDescription)
    #expect(message.count < 2_000)
    #expect(message.contains("filesystem_error_\(NSFileWriteOutOfSpaceError)"))
    #expect(message.contains("execution status partial, 1 completed, 1 failed, 0 cancelled"))
    #expect(message.contains("Do not rerun workers"))
    #expect(!message.contains("secret-diagnostic"))
    #expect(!message.contains("/private/"))
    #expect((failure.underlyingError as NSError).localizedDescription == privateDescription)
}

@Test func swarmLifecycle_handoffAndSynthesisCarryEvidenceLimits() async throws {
    let llm = LifecycleSwarmLLM(.reports)
    let result = try await SwiftNativeAgentSwarmExecutor(llm: llm).run(
        request: lifecycleRequest(), policy: AgentSwarmPolicy(storeReceipts: false)
    )
    #expect(result.status == "completed")
    #expect(result.workers.allSatisfy { $0.outputTruncated })
    let prompts = await llm.prompts
    #expect(prompts.first?.contains("parent assistant owns integration") == true)
    #expect(prompts.first?.contains("Do not claim to have used tools") == true)
    #expect(prompts.last?.contains("output_truncated=true") == true)
    #expect(prompts.last?.contains("agreement is not verification") == true)
}
