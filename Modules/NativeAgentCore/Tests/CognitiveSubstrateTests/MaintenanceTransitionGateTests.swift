import Foundation
import Testing
import PersistenceCore
@testable import CognitiveSubstrate

/// R-F3: `waitForMaintenanceTransition` parks waiters on a `CheckedContinuation`
/// gate instead of busy-spinning `Task.yield()`. Waiters are resumed exactly
/// once when the transition completes, and a cancelled waiter releases itself
/// without leaking its continuation.
@Suite("Maintenance transition gate", .serialized)
struct MaintenanceTransitionGateTests {
    private final class TestClock: @unchecked Sendable {
        private let lock = NSLock()
        private var current: Date
        init(_ current: Date) { self.current = current }
        func now() -> Date { lock.lock(); defer { lock.unlock() }; return current }
    }

    private actor Counter {
        private(set) var value = 0
        private(set) var order: [Int] = []
        func record(_ id: Int) { value += 1; order.append(id) }
    }

    private func makeSubstrate() -> CognitiveSubstrate {
        let clock = TestClock(Date(timeIntervalSince1970: 40_000_000))
        return CognitiveSubstrate(
            configuration: CognitiveConfiguration(enabled: true),
            dependencies: CognitiveSubstrateDependencies(now: { clock.now() })
        )
    }

    /// Bounded spin waiting for the parked-waiter count to reach `target`.
    /// Bounded so a regression fails loudly instead of hanging the suite.
    private func waitForWaiterCount(
        _ substrate: CognitiveSubstrate,
        equals target: Int
    ) async -> Int {
        var count = -1
        for _ in 0..<10_000 {
            count = await substrate.maintenanceTransitionWaiterCountForTesting
            if count == target { return count }
            await Task.yield()
        }
        return count
    }

    @Test("waiters park during a transition and all resume exactly once on completion")
    func waitersResumeOnTransitionEnd() async throws {
        let substrate = makeSubstrate()
        await substrate.beginMaintenanceTransition()

        let counter = Counter()
        let waiters = (0..<4).map { id in
            Task {
                await substrate.waitForMaintenanceTransition()
                await counter.record(id)
            }
        }

        // All four park on the continuation gate — no spin resolves them early.
        #expect(await waitForWaiterCount(substrate, equals: 4) == 4)
        #expect(await counter.value == 0)

        // Completing the transition resumes every parked waiter.
        await substrate.endMaintenanceTransition()
        for waiter in waiters { await waiter.value }

        #expect(await counter.value == 4)
        #expect(await substrate.maintenanceTransitionWaiterCountForTesting == 0)
        // Draining a second time is a harmless no-op (no double-resume / crash).
        await substrate.endMaintenanceTransition()
        #expect(await counter.value == 4)
    }

    @Test("a waiter that arrives after the transition ended returns immediately")
    func waiterAfterTransitionReturnsImmediately() async throws {
        let substrate = makeSubstrate()
        // No transition in flight → the guard short-circuits, never parks.
        await substrate.waitForMaintenanceTransition()
        #expect(await substrate.maintenanceTransitionWaiterCountForTesting == 0)
    }

    @Test("a cancelled waiter releases its continuation but HOLDS at the gate until the transition ends")
    func cancelledWaiterHeldAtGateUntilTransitionEnds() async throws {
        let substrate = makeSubstrate()
        await substrate.beginMaintenanceTransition()

        let counter = Counter()
        let waiter = Task {
            await substrate.waitForMaintenanceTransition()
            await counter.record(0)
        }
        #expect(await waitForWaiterCount(substrate, equals: 1) == 1)

        // Cancellation must resume the parked continuation (not leak it) and
        // remove the waiter from the park set…
        waiter.cancel()
        #expect(await waitForWaiterCount(substrate, equals: 0) == 0)

        // …but the cancelled caller must NOT pass the gate while the
        // transition is still open (review round 2, BLOCKING: a cancelled
        // ingest proceeding into a suspended maintenance commit is the exact
        // race this gate exists to stop — the pre-R-F3 yield-spin held
        // cancelled callers too). Give the task generous opportunity to
        // (wrongly) run to completion before asserting it hasn't.
        for _ in 0..<1_000 { await Task.yield() }
        #expect(
            await counter.value == 0,
            "a cancelled waiter must hold at the gate while the maintenance transition is open"
        )

        // Ending the transition releases it — exactly once, no crash.
        await substrate.endMaintenanceTransition()
        await waiter.value
        #expect(await counter.value == 1)
        #expect(await substrate.maintenanceTransitionWaiterCountForTesting == 0)
    }
}
