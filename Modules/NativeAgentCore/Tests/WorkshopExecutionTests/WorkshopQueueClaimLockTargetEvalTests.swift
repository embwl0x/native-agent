import Testing
import Foundation
import Darwin
@testable import WorkshopExecution
import NativeAgentCore
import PersistenceCore

// Coverage ledger: `workshop.executor.queueClaimLock`
// (WorkshopExecution+Executor.swift `queueClaimLockTarget` / `claimUnderQueueLock`).
//
// SILENT-FAILURE CLASS: state-lifecycle leak / system-wide wedge. EVERY claim,
// in every executor instance and every process, serializes on ONE flock at
// `<root>/workshop/executions/.claim`. The existing behavioural test
// (`twoConcurrentExecutorsExactlyOneClaims`) proves mutual exclusion between
// two executors built on the same root — but it would keep passing if the
// target moved, because both executors would move together. The two live
// regressions it cannot see:
//   * the target drifts to the DEFAULT data root (or any process-wide path) —
//     unrelated writers now wedge the drain, and two roots share one mutex;
//   * the target drifts to a per-execution path — the mutex splits and two
//     executors double-dispatch the same execution's side-effecting steps.
// `grep -rn queueClaimLockTarget` over the test targets returned nothing.
//
// So this file pins BOTH halves: the resolved path, and that the resolved path
// is the one the claim actually blocks on.

private func claimLockEvalRoot() throws -> URL {
    let dir = FileManager.default.temporaryDirectory
        .appendingPathComponent("WorkshopClaimLockEval-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    return dir
}

private let claimEvalSingleStepPlan = """
[{"id": "step-1", "description": "one step", "tool_or_action": "chat.synthesize", \
"args": {"prompt": "do it"}, "autonomy": "auto"}]
"""

private func seedQueuedExecution(root: URL, id: String) async throws {
    let dir = root.appendingPathComponent("workshop/executions/\(id)", isDirectory: true)
    let receipts = dir.appendingPathComponent("receipts", isDirectory: true)
    try FileManager.default.createDirectory(at: receipts, withIntermediateDirectories: true)
    let stamp = SwiftNativeWorkshopRunner.isoTimestamp(Date())
    let record = WorkshopExecutionRecord(
        id: id, title: id, objective: "claim-lock eval", createdAt: stamp, status: "queued",
        plan: SwiftNativeWorkshopRunner.parsePlanSteps(
            try JSONValue.parse(Data(claimEvalSingleStepPlan.utf8))),
        stepsCompleted: [], receiptsDir: receipts.path, triggerSource: "manual",
        trustRequired: "none", expectedOutputs: [], currentStepId: "", updatedAt: stamp,
        result: .null, rerunCount: 0
    )
    try await SwiftNativePersistenceCore().writeJSON(
        record.toJSON(), to: ExecutionRecordFile.canonicalPath(in: dir))
}

private actor StepCounter {
    private var value = 0
    func bump() { value += 1 }
    func read() -> Int { value }
}

/// Hold an exclusive flock on `path` for the life of this object. `flock` locks
/// are per open-file-description, so a second descriptor in THIS process
/// contends exactly as another process would (verified: the second
/// `LOCK_EX | LOCK_NB` returns EWOULDBLOCK).
private final class HeldFileLock {
    private let fd: Int32
    private var released = false

    init?(path: String) {
        try? FileManager.default.createDirectory(
            atPath: (path as NSString).deletingLastPathComponent,
            withIntermediateDirectories: true)
        let fd = Darwin.open(path, O_CREAT | O_WRONLY, 0o600)
        guard fd >= 0 else { return nil }
        guard flock(fd, LOCK_EX | LOCK_NB) == 0 else { Darwin.close(fd); return nil }
        self.fd = fd
    }

    func release() {
        guard !released else { return }
        released = true
        _ = flock(fd, LOCK_UN)
        Darwin.close(fd)
    }

    deinit { release() }
}

@Suite("EVAL workshop.executor.queueClaimLock")
struct WorkshopQueueClaimLockTargetEvalSuite {

    /// The resolved target is root-relative and EXACTLY the queue-root `.claim`
    /// sentinel — never the process default data root.
    @Test func claimLockTargetIsRootRelativeQueueClaim() throws {
        let root = try claimLockEvalRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let executor = WorkshopExecutorLoop(root: root)

        let expected = root
            .appendingPathComponent("workshop", isDirectory: true)
            .appendingPathComponent("executions", isDirectory: true)
            .appendingPathComponent(".claim")
        #expect(executor.queueClaimLockTarget.standardizedFileURL == expected.standardizedFileURL)
        #expect(executor.queueClaimLockTarget.deletingLastPathComponent().standardizedFileURL
                == executor.executionRecordsRoot.standardizedFileURL)

        // It must NOT resolve under the default data root — that is the drift
        // that turns a per-root mutex into a process-wide one.
        let defaultRoot = PersistenceCore.defaultDataRoot().standardizedFileURL.path
        #expect(executor.queueClaimLockTarget.standardizedFileURL.path.hasPrefix(defaultRoot) == false)

        // Two executors on DIFFERENT roots must not share a claim mutex.
        let otherRoot = try claimLockEvalRoot()
        defer { try? FileManager.default.removeItem(at: otherRoot) }
        #expect(WorkshopExecutorLoop(root: otherRoot).queueClaimLockTarget
                != executor.queueClaimLockTarget)
    }

    /// CONTROL: with nothing holding the lock, a drain claims and runs its one
    /// step promptly. This is what makes the blocked case below meaningful.
    @Test func unlockedDrainRunsItsStep() async throws {
        let root = try claimLockEvalRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        try await seedQueuedExecution(root: root, id: "control")
        let steps = StepCounter()
        let executor = WorkshopExecutorLoop(
            root: root,
            llmStep: { _ in await steps.bump(); return ("m", "done") }
        )
        await executor.drainOnce()
        #expect(await steps.read() == 1)
    }

    /// The claim BLOCKS on exactly `queueClaimLockTarget + ".lock"` (the sibling
    /// `withFileLock` flocks). Holding it stalls the drain; releasing it lets
    /// the drain proceed and run the step exactly once.
    ///
    /// The negative half asserts that NOTHING happened inside a generous 1s
    /// window — load-safe by construction (a slower machine makes the drain
    /// later, not earlier). The positive half is bounded by a deadline and the
    /// drain task is cancelled at the end, so a genuine wedge fails loudly
    /// instead of hanging the suite.
    @Test func claimBlocksOnTheResolvedTargetAndResumesOnRelease() async throws {
        let root = try claimLockEvalRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        try await seedQueuedExecution(root: root, id: "contended")
        let steps = StepCounter()
        let executor = WorkshopExecutorLoop(
            root: root,
            llmStep: { _ in await steps.bump(); return ("m", "done") }
        )

        let lockPath = executor.queueClaimLockTarget.path + ".lock"
        let held = try #require(HeldFileLock(path: lockPath),
                                "could not take the claim flock at \(lockPath)")
        defer { held.release() }

        let drain = Task { await executor.drainOnce() }
        defer { drain.cancel() }

        try await Task.sleep(nanoseconds: 1_000_000_000)
        #expect(await steps.read() == 0,
                "the claim must be blocked while \(lockPath) is held")
        #expect(drain.isCancelled == false)

        held.release()

        let deadline = Date().addingTimeInterval(15)
        while Date() < deadline, await steps.read() == 0 {
            try await Task.sleep(nanoseconds: 25_000_000)
        }
        #expect(await steps.read() == 1, "the drain must resume once the claim lock is released")
        await drain.value

        let record = await SwiftNativeWorkshopRunner(
            executorAvailable: true, root: root
        ).listAll().first { $0.id == "contended" }
        #expect(record?.status == "completed")
    }
}
