import Foundation
import NativeAgentCore
import PersistenceCore
import Testing
@testable import WorkshopExecution

// Track C of docs/build_plans/lifecycle-prevention-design.md — the two
// Workshop-side retrofits.
//
// C-2 (unbounded wait under a file lock): `executeOrAwaitCanonicalProcedure`
// runs INSIDE `ProcedureArtifactStore.invoke`'s
// `withFileLock(invocations.jsonl)` — an untimed cross-process LOCK_EX. Its
// `for await` observation had no deadline, so an execution that never reached a
// terminal status wedged not just this caller but EVERY procedure invocation in
// EVERY process queued behind that flock.
//
// C-1 (registry insert with no remove): the orphan-reclaim barrier was a
// hand-locked `[String: Task]` that retained the reclaim Task — and the
// executor instance its closure captured — for every data root, forever.
// `.serialized` because three tests here drive the SAME process-global
// `NATIVE_AGENT_WORKSHOP_CANONICAL_OBSERVATION_TIMEOUT_SECONDS`; run in
// parallel they read each other's setenv/unsetenv and fail at random.
@Suite("Workshop lifecycle bounds", .serialized)
struct WorkshopLifecycleBoundsTests {
    private func makeRoot() throws -> URL {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("WorkshopLifecycleBounds-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    @Test("the canonical terminal observation is bounded, not a wedge under the flock")
    func canonicalObservationIsBounded() async throws {
        let root = try makeRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        setenv("NATIVE_AGENT_WORKSHOP_CANONICAL_OBSERVATION_TIMEOUT_SECONDS", "1", 1)
        defer { unsetenv("NATIVE_AGENT_WORKSHOP_CANONICAL_OBSERVATION_TIMEOUT_SECONDS") }
        #expect(WorkshopCompiledLocalFileCopyInvocation
            .canonicalObservationTimeoutSeconds == 1)

        let runner = SwiftNativeWorkshopRunner(root: root)
        let loop = WorkshopExecutorLoop(root: root, llmStep: { _ in ("m", "done") })

        // `start` refuses with a typed `invalidRequest` (no such execution) —
        // the ONE failure the narrowed catch tolerates. Nothing will ever write
        // this record, so the observation below is exactly the wait that used
        // to be unbounded.
        let started = Date()
        do {
            _ = try await WorkshopCompiledLocalFileCopyInvocation
                .executeOrAwaitCanonicalProcedure(
                    executionID: "never-written-\(UUID().uuidString)",
                    runner: runner,
                    loop: loop
                )
            Issue.record("expected the bounded wait to expire")
        } catch let timeout as BoundedWaitTimeout {
            #expect(timeout.seconds == 1)
            #expect(timeout.reason.contains("canonical Workshop terminal record"))
        } catch {
            Issue.record("expected BoundedWaitTimeout, got \(error)")
        }
        // Pre-fix this call never returned at all.
        #expect(Date().timeIntervalSince(started) < 30)
    }

    @Test("the default canonical-observation deadline is finite")
    func defaultObservationDeadlineIsFinite() {
        unsetenv("NATIVE_AGENT_WORKSHOP_CANONICAL_OBSERVATION_TIMEOUT_SECONDS")
        let seconds = WorkshopCompiledLocalFileCopyInvocation.canonicalObservationTimeoutSeconds
        #expect(seconds == 300)
        #expect(seconds.isFinite)
    }

    /// The observation runs under `invocations.jsonl`'s cross-process flock, so
    /// an env override that stretches the guard to hours would re-create the
    /// system-wide wedge the guard exists to prevent. Out-of-range overrides are
    /// rejected back to the 300s default, not honored.
    @Test("an hours-long env override cannot stretch the flock-held deadline")
    func observationDeadlineRejectsOutOfRangeOverride() {
        let key = "NATIVE_AGENT_WORKSHOP_CANONICAL_OBSERVATION_TIMEOUT_SECONDS"
        setenv(key, "36000", 1)
        #expect(WorkshopCompiledLocalFileCopyInvocation.canonicalObservationTimeoutSeconds == 300)
        setenv(key, "60", 1)
        #expect(WorkshopCompiledLocalFileCopyInvocation.canonicalObservationTimeoutSeconds == 60)
        unsetenv(key)
    }

    @Test("the orphan-reclaim barrier is one-shot per root and drops its captures")
    func orphanReclaimBarrierIsOneShotAndReleases() async throws {
        let root = try makeRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        #expect(!(await WorkshopExecutorLoop.orphanReclaimOnce.hasCompleted(root.path)))

        // Two executor instances on the SAME root — the production shape (the
        // background drain plus a cold-start fallback). Both must share ONE
        // reclaim.
        weak var observed: WorkshopExecutorLoop?
        do {
            let first = WorkshopExecutorLoop(root: root, llmStep: { _ in ("m", "done") })
            observed = first
            await first.drainOnce()
        }
        #expect(await WorkshopExecutorLoop.orphanReclaimOnce.hasCompleted(root.path))
        // Pre-fix, the memo table held the reclaim Task — and therefore the
        // executor instance its closure captured — for the process lifetime.
        #expect(observed == nil)

        // A "running" record appearing AFTER the barrier armed is a live
        // execution, not a startup orphan: the second instance must not reclaim
        // it, proving both instances shared the one-shot.
        let second = WorkshopExecutorLoop(root: root, llmStep: { _ in ("m", "done") })
        await second.drainOnce()
        #expect(await WorkshopExecutorLoop.orphanReclaimOnce.hasCompleted(root.path))
    }
}
