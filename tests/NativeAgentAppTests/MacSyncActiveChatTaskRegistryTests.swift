import Foundation
import Testing
@testable import NativeAgentApp

// evals-total-coverage — fence `app.bridges`, row `macsync.activeChatTaskRegistry`
// (Sources/NativeAgentApp/MacSyncEngine.swift:79/:90/:101).
//
// This registry is what makes the iOS "cancelChat" inbox action actually stop a
// running Mac-side turn. Its silent-failure class is state lifecycle:
//   - an entry added and never removed leaks a Task per turn forever, and every
//     later cancel for that session cancels a DEAD task while the live one runs;
//   - a stale unregister (an older turn finishing after a newer one replaced it)
//     removing the CURRENT entry makes cancel report `.noActiveTask` — the phone
//     shows "cancelled", the Mac keeps talking.
// Neither leaves a row anywhere; the only symptom is a cancel that does nothing.
//
// 2026-09-06: `cancelActiveChatTask` returns `MacSyncChatCancelOutcome` instead
// of Bool (394e20ac) so a Stop that names a run can say WHICH of the three
// no-cancel states it hit — `.runMismatch` (a later turn holds the session),
// `.stopRecorded` (the Stop overtook its own turn's handoff) or `.noActiveTask`.
// These tests all call the unscoped form (no `runIDs`), whose two outcomes are
// exactly the old true/false: `.cancelled` and `.noActiveTask`.
//
// `MacSyncEngine.init` is private (singleton-enforced), so these drive
// `.shared` — the same production object the inbox router uses. To stay
// hermetic against the rest of the target, every session id is namespaced with
// a per-test UUID and every assertion is scoped to that namespace, so this suite
// neither reads nor disturbs anything another test registered. Each test drains
// its own namespace to zero: that drain IS the leak assertion.
//
// HANG-PROOFING (nativeagent-hangproof-subprocess-tests): the tasks here only
// finish when someone cancels them, so a regression in the code under test
// would otherwise wedge `await task.value` forever and the whole --no-parallel
// suite with it. Every wait therefore goes through `expectCancelled` (bounded
// poll, then an unconditional force-cancel) and every test force-drains its
// tasks at the end. Verified by running these against a mutated
// `unregisterActiveChatTask`: the suite FAILS in ~3s instead of hanging.
@Suite("MacSync active chat-task registry", .serialized)
@MainActor
struct MacSyncActiveChatTaskRegistryTests {

    private typealias ChatTask = Task<(text: String, deltaSeq: Int, error: String?, toolEvents: Int), Never>

    /// A task that never finishes on its own, so cancellation is observable.
    private func makeTask() -> ChatTask {
        Task {
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: 5_000_000)
            }
            return (text: "", deltaSeq: 0, error: "cancelled", toolEvents: 0)
        }
    }

    /// Assert the code under test cancelled `task` within a bounded deadline,
    /// then force-cancel and drain so the wait can never be unbounded.
    private func expectCancelled(
        _ task: ChatTask,
        _ what: String,
        sourceLocation: SourceLocation = #_sourceLocation
    ) async {
        var observed = false
        let deadline = Date().addingTimeInterval(3)
        while Date() < deadline {
            if task.isCancelled { observed = true; break }
            try? await Task.sleep(nanoseconds: 5_000_000)
        }
        #expect(observed, "\(what) was never cancelled", sourceLocation: sourceLocation)
        await drain([task])
    }

    /// Unconditional teardown: cancel and await every task this test made.
    private func drain(_ tasks: [ChatTask]) async {
        for task in tasks {
            task.cancel()
            _ = await task.value
        }
    }

    /// Session ids registered by THIS test only.
    private func mine(_ engine: MacSyncEngine, _ namespace: String) -> [String] {
        engine.activeChatTasks.keys.filter { $0.hasPrefix(namespace) }.sorted()
    }

    private func namespace() -> String { "eval-\(UUID().uuidString)-" }

    @Test("register then unregister leaves no entry behind")
    func registerUnregisterIsBalanced() async {
        let engine = MacSyncEngine.shared
        let ns = namespace()
        let task = makeTask()
        defer { Task { await self.drain([task]) } }
        #expect(mine(engine, ns).isEmpty)

        engine.registerActiveChatTask(task, for: ns + "a")
        #expect(mine(engine, ns) == [ns + "a"])

        engine.unregisterActiveChatTask(for: ns + "a", expecting: task)
        #expect(mine(engine, ns).isEmpty, "every add path must have a remove path — this one leaked")

        await drain([task])
    }

    @Test("re-registering a session cancels the superseded task instead of orphaning it")
    func reRegisterCancelsPrevious() async {
        let engine = MacSyncEngine.shared
        let ns = namespace()
        let first = makeTask()
        let second = makeTask()

        engine.registerActiveChatTask(first, for: ns + "b")
        engine.registerActiveChatTask(second, for: ns + "b")

        // The superseded task must actually stop — an orphan would keep
        // streaming into a session the user believes is finished.
        await expectCancelled(first, "the superseded task")

        #expect(mine(engine, ns).count == 1, "a superseded task must not leave a second entry")
        #expect(engine.cancelActiveChatTask(for: ns + "b") == .cancelled,
                "the LIVE task must be the one cancel reaches")
        await expectCancelled(second, "the live task after an explicit cancel")

        engine.unregisterActiveChatTask(for: ns + "b", expecting: second)
        #expect(mine(engine, ns).isEmpty)
        await drain([first, second])
    }

    @Test("a stale unregister cannot evict the live task")
    func staleUnregisterDoesNotEvictCurrent() async {
        let engine = MacSyncEngine.shared
        let ns = namespace()
        let stale = makeTask()
        let live = makeTask()

        engine.registerActiveChatTask(stale, for: ns + "c")
        engine.registerActiveChatTask(live, for: ns + "c")   // cancels `stale`
        await expectCancelled(stale, "the superseded task")

        // The older turn's `defer { unregister }` now fires. If it removed the
        // map entry, the next cancelChat from the phone would silently no-op.
        engine.unregisterActiveChatTask(for: ns + "c", expecting: stale)
        #expect(mine(engine, ns).count == 1, "a finished older turn evicted the live turn's registration")
        #expect(engine.cancelActiveChatTask(for: ns + "c") == .cancelled,
                "cancelChat found nothing to cancel — the phone would report success over a running turn")
        await expectCancelled(live, "the live task")

        engine.unregisterActiveChatTask(for: ns + "c", expecting: live)
        #expect(mine(engine, ns).isEmpty)
        await drain([stale, live])
    }

    @Test("cancel reports honestly when there is nothing to cancel")
    func cancelUnknownSessionReturnsNoActiveTask() async {
        let engine = MacSyncEngine.shared
        let ns = namespace()
        // An UNSCOPED Stop (no run named) over an empty registry has nothing to
        // hold against a run id, so it reports `.noActiveTask` rather than
        // recording a stop request.
        #expect(engine.cancelActiveChatTask(for: ns + "never-registered") == .noActiveTask)
        #expect(engine.cancelActiveChatTask(for: "") == .noActiveTask)
        #expect(engine.cancelActiveChatTask(for: "   ") == .noActiveTask)

        let task = makeTask()
        engine.registerActiveChatTask(task, for: ns + "d")
        // Whitespace around the id must not create a second, uncancellable lane.
        #expect(engine.cancelActiveChatTask(for: "  \(ns)d  ") == .cancelled)
        await expectCancelled(task, "the task addressed by a padded session id")
        engine.unregisterActiveChatTask(for: " \(ns)d ", expecting: task)
        #expect(mine(engine, ns).isEmpty, "a padded id took a different code path and orphaned the entry")
        await drain([task])
    }

    @Test("a blank session id is never registered")
    func blankSessionIsNotRegistered() async {
        let engine = MacSyncEngine.shared
        let before = engine.activeChatTasks.count
        let task = makeTask()
        engine.registerActiveChatTask(task, for: "   ")
        #expect(engine.activeChatTasks.count == before,
                "a blank id would create an entry nothing can ever cancel or remove")
        await drain([task])
    }

    @Test("many sessions register and drain to empty")
    func manySessionsDrainToEmpty() async {
        let engine = MacSyncEngine.shared
        let ns = namespace()
        var tasks: [(String, ChatTask)] = []
        for index in 0..<25 {
            let id = "\(ns)\(index)"
            let task = makeTask()
            engine.registerActiveChatTask(task, for: id)
            tasks.append((id, task))
        }
        #expect(mine(engine, ns).count == 25)

        for (id, task) in tasks {
            #expect(engine.cancelActiveChatTask(for: id) == .cancelled)
            await expectCancelled(task, "session \(id)")
            engine.unregisterActiveChatTask(for: id, expecting: task)
        }
        #expect(mine(engine, ns).isEmpty, "registry did not drain — one Task per session leaked")
        await drain(tasks.map { $0.1 })
    }
}
