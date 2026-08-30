import Foundation
import XCTest
@testable import NativeAgentMobile

/// E2 (upgrade-sweep 2026-08): action responses rendezvous on a continuation
/// keyed by correlationID instead of a sub-second poll.
///
/// Silent-failure class: BATTERY/QUOTA. Nothing errors; the phone just spends
/// ~400 CloudKit drains per privileged tap. The failure mode a test must catch
/// is the opposite one — a waiter that never wakes, turning a responsive tap
/// into a 5s stall, or worse a permanent park.
@MainActor
final class ActionResponseWaiterEvalTests: XCTestCase {

    func test_signalBeforeWaitIsNotLost() async {
        let waiters = ActionResponseWaiters()
        let id = UUID().uuidString
        waiters.arm(id)
        waiters.signal(id)
        // The arrival raced the first poll; the waiter must not park on it.
        let signalled = await waiters.wait(id, timeout: 30)
        XCTAssertTrue(signalled)
        waiters.disarm(id)
    }

    func test_signalWhileParkedResumesTheWaiterEarly() async {
        let waiters = ActionResponseWaiters()
        let id = UUID().uuidString
        waiters.arm(id)
        let started = Date()
        async let parked = waiters.wait(id, timeout: 30)
        // Yield so the continuation is registered before the signal lands.
        await Task.yield()
        try? await Task.sleep(nanoseconds: 20_000_000)
        waiters.signal(id)
        let signalled = await parked
        XCTAssertTrue(signalled)
        XCTAssertLessThan(Date().timeIntervalSince(started), 5,
                          "a push must not wait out the backstop interval")
        waiters.disarm(id)
    }

    func test_backstopTimeoutReturnsUnsignalledRatherThanParkingForever() async {
        let waiters = ActionResponseWaiters()
        let id = UUID().uuidString
        waiters.arm(id)
        let signalled = await waiters.wait(id, timeout: 0.1)
        XCTAssertFalse(signalled, "the backstop tick must be distinguishable from a push")
        waiters.disarm(id)
    }

    func test_signalForAnUnarmedCorrelationIsIgnored() async {
        let waiters = ActionResponseWaiters()
        let id = UUID().uuidString
        // No arm(): a response for a correlation nobody awaits must not
        // accumulate in the arrival set for the life of the session.
        waiters.signal(id)
        XCTAssertFalse(waiters.hasArrived(id))
    }

    func test_disarmReleasesAParkedWaiter() async {
        let waiters = ActionResponseWaiters()
        let id = UUID().uuidString
        waiters.arm(id)
        async let parked = waiters.wait(id, timeout: 600)
        await Task.yield()
        try? await Task.sleep(nanoseconds: 20_000_000)
        waiters.disarm(id)
        let signalled = await parked
        XCTAssertFalse(signalled)
    }

    func test_theBackstopIntervalIsTheFiveSecondContract() {
        XCTAssertEqual(ActionResponseWaiters.backstopInterval, 5)
    }
}
