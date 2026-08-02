import Foundation
import NativeAgentCore
import Testing
@testable import NativeAgentApp

// fix-exec-slot-leak (2026-08-02), Track C of
// docs/build_plans/lifecycle-prevention-design.md.
//
// /macctl/exec acquires one of `execLimit` exec slots. The ONLY release used to
// be a `defer` inside the background dispatch block. The durable `.started`
// transition between the acquire and that block can throw (flock contention,
// disk full); the throw unwound to the request's outer catch without ever
// entering the block, so the slot was never released. Two of those pinned the
// active count at execLimit forever — every subsequent exec returned 429, and
// `stopAllProcesses` deliberately refuses to zero the count, so emergency_stop
// could not recover it. Restart-only.
//
// The slot is now a `ScopedSlot` handle from a `ScopedSlotCounter` whose count
// is PRIVATE to the counter: nothing can admit an exec without holding a
// handle, and `deinit` is the only release path. These tests drive the exact
// handler shape — acquire, throw or hand off, unwind — against a local counter,
// plus the production counter's own wiring.
// `.serialized`: two of these drive the PROCESS-GLOBAL production counter and
// assert its absolute count.
@Suite("Mac Control exec slot lifecycle", .serialized)
struct MacControlBridgeExecSlotTests {
    private struct TransitionFailure: Error {}

    /// The handler's structure, verbatim: acquire a handle, do durable work
    /// that can throw, then hand the handle to the background block that owns
    /// the rest of its life.
    private func runExecHandler(
        counter: ScopedSlotCounter,
        transitionThrows: Bool,
        onBackgroundDone: (@Sendable () -> Void)? = nil
    ) throws -> Bool {
        guard let execSlot = counter.acquire() else { return false }
        // Throwing here is the leak that shipped: this unwinds THROUGH the
        // handle, whose deinit releases.
        if transitionThrows { throw TransitionFailure() }
        DispatchQueue.global().async { [execSlot] in
            defer { withExtendedLifetime(execSlot) {} }
            Thread.sleep(forTimeInterval: 0.02)
            onBackgroundDone?()
        }
        return true
    }

    private func waitForCount(_ counter: ScopedSlotCounter, toReach target: Int) async -> Bool {
        for _ in 0..<500 {
            if counter.activeCount == target { return true }
            try? await Task.sleep(nanoseconds: 10_000_000)
        }
        return counter.activeCount == target
    }

    @Test("a throw before the background handoff still releases the slot")
    func throwingTransitionReleasesSlot() {
        let counter = ScopedSlotCounter(name: "test-exec", limit: 2)
        #expect(throws: TransitionFailure.self) {
            _ = try runExecHandler(counter: counter, transitionThrows: true)
        }
        #expect(counter.activeCount == 0)
    }

    @Test("repeated pre-handoff throws never saturate the exec limit")
    func repeatedThrowsDoNotBrickTheBridge() throws {
        let counter = ScopedSlotCounter(name: "test-exec", limit: 2)
        for _ in 0..<5 {
            #expect(throws: TransitionFailure.self) {
                _ = try runExecHandler(counter: counter, transitionThrows: true)
            }
        }
        // Old behavior: after two throws the count sat at execLimit and every
        // further exec was rejected 429 until the app restarted.
        #expect(counter.activeCount == 0)
        #expect(try runExecHandler(counter: counter, transitionThrows: false))
    }

    @Test("the background block owns the slot until it finishes")
    func backgroundBlockOwnsTheRelease() async throws {
        let counter = ScopedSlotCounter(name: "test-exec", limit: 2)
        #expect(try runExecHandler(counter: counter, transitionThrows: false))
        // The exec is still running: the captured handle keeps the slot held
        // past the enclosing scope, with no `defer` to forget.
        #expect(counter.activeCount == 1)
        #expect(await waitForCount(counter, toReach: 0))
    }

    @Test("a saturated counter admits nothing and holds no extra slot")
    func saturatedCounterRefusesAdmission() throws {
        let counter = ScopedSlotCounter(name: "test-exec", limit: 1)
        let held = counter.acquire()
        #expect(held != nil)
        #expect(try runExecHandler(counter: counter, transitionThrows: false) == false)
        #expect(counter.activeCount == 1)
        withExtendedLifetime(held) {}
    }

    @Test("the production exec gate is a bounded ScopedSlotCounter")
    func productionExecGateIsBounded() {
        // The count lives inside the counter; the bridge cannot increment it
        // without taking a handle, and cannot decrement it at all.
        #expect(MacControlBridge.execSlots.limit == 2)
        #expect(MacControlBridge.execSlots.activeCount == 0)
        let first = MacControlBridge.execSlots.acquire()
        let second = MacControlBridge.execSlots.acquire()
        #expect(first != nil)
        #expect(second != nil)
        #expect(MacControlBridge.execSlots.acquire() == nil)
        withExtendedLifetime(first) {}
        withExtendedLifetime(second) {}
    }

    @Test("dropping the production handles restores the gate")
    func productionExecGateRecovers() {
        do {
            let slot = MacControlBridge.execSlots.acquire()
            #expect(MacControlBridge.execSlots.activeCount == 1)
            withExtendedLifetime(slot) {}
        }
        #expect(MacControlBridge.execSlots.activeCount == 0)
    }
}
