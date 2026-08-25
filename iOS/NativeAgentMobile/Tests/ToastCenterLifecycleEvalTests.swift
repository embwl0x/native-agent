import Foundation
import XCTest
@testable import NativeAgentMobile

/// Coverage-ledger fence `ios.screens`, row `ios.chrome.toastCenter`.
///
/// Silent-failure class: STATE-LIFECYCLE LEAK. `push(info/warn/error/success)`
/// each arm an auto-dismiss task; the bar renders only the newest three. A
/// dismiss that fails to cancel its task, or a task that fails to remove its
/// toast, leaves the queue growing under a bar that looks calm — and a re-push
/// of the same id must not let the OLD timer kill the NEW entry (the Mac-side
/// SystemToastCenter fix this file is the iOS parity of).
///
/// Every wait here is bounded by a deadline poll, never a bare sleep-and-hope.
@MainActor
final class ToastCenterLifecycleEvalTests: XCTestCase {

    /// Poll until `condition` holds or the deadline passes. Returns whether it
    /// held, so the caller asserts instead of hanging.
    private func waitUntil(
        _ description: String,
        timeout: TimeInterval = 3.0,
        _ condition: () -> Bool
    ) async -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if condition() { return true }
            try? await Task.sleep(nanoseconds: 10_000_000)
        }
        return condition()
    }

    func test_everyAutoDismissingToastLeavesTheQueueOnItsOwn() async {
        let center = iOSSystemToastCenter()
        center.push(info: "saved", autoDismissAfter: 0.05)
        center.push(warn: "slow sync", autoDismissAfter: 0.05)
        center.push(error: "failed", autoDismissAfter: 0.05)
        XCTAssertEqual(center.queue.count, 3)

        let drained = await waitUntil("queue drains") { center.queue.isEmpty }
        XCTAssertTrue(drained, "auto-dismissing toasts stayed in the queue: \(center.queue.map(\.text))")
    }

    func test_aStickyToastIsNeverAutoRemovedAndOnlyDismissClearsIt() async {
        let center = iOSSystemToastCenter()
        center.push(iOSSystemToast(kind: .error, text: "pairing lost", autoDismissAfter: nil))
        center.push(info: "saved", autoDismissAfter: 0.05)

        let transientGone = await waitUntil("transient drains") { center.queue.count == 1 }
        XCTAssertTrue(transientGone)
        XCTAssertEqual(
            center.queue.first?.text, "pairing lost",
            "the sticky toast was auto-removed — a permanent condition would vanish from the screen"
        )

        center.dismiss(center.queue[0].id)
        XCTAssertTrue(center.queue.isEmpty)
    }

    func test_aRePushOfTheSameToastReplacesItWithoutTheOldTimerKillingIt() async {
        let center = iOSSystemToastCenter()
        let sticky = iOSSystemToast(kind: .info, text: "uploading", autoDismissAfter: 0.05)

        // Re-push of the SAME id (a caller updating a sticky row). Replace-by-id
        // must dedup the queue — a duplicate id also breaks ForEach identity —
        // and must re-arm the timer rather than let the first one fire against
        // the new entry.
        center.push(sticky)
        center.push(sticky)
        XCTAssertEqual(center.queue.count, 1, "a re-push duplicated the toast instead of replacing it")

        let drained = await waitUntil("re-pushed toast still auto-dismisses") { center.queue.isEmpty }
        XCTAssertTrue(drained, "the re-pushed toast lost its auto-dismiss and would sit on screen forever")
    }

    func test_dismissAllClearsTheQueueAndDisarmsEveryPendingTimer() async {
        let center = iOSSystemToastCenter()
        for index in 0..<5 { center.push(info: "toast \(index)", autoDismissAfter: 0.05) }
        XCTAssertEqual(center.queue.count, 5)

        center.dismissAll()
        XCTAssertTrue(center.queue.isEmpty)

        // A disarmed timer must not reach back into a queue that has since been
        // refilled — that is how a fresh toast disappears a beat after it shows.
        center.push(iOSSystemToast(kind: .success, text: "done", autoDismissAfter: nil))
        try? await Task.sleep(nanoseconds: 200_000_000)
        XCTAssertEqual(
            center.queue.map(\.text), ["done"],
            "a cancelled auto-dismiss task removed a toast pushed after dismissAll()"
        )
    }

    func test_pushDefaultsGiveErrorsTheLongestDwellAndInfoTheShortest() {
        let center = iOSSystemToastCenter()
        center.push(info: "i")
        center.push(warn: "w")
        center.push(error: "e")
        center.push(success: "s")

        let dwellByKind = Dictionary(
            uniqueKeysWithValues: center.queue.map { ($0.kind, $0.autoDismissAfter ?? .infinity) }
        )
        XCTAssertEqual(center.queue.count, 4)
        XCTAssertGreaterThan(
            dwellByKind[.error] ?? 0, dwellByKind[.warn] ?? 0,
            "errors no longer dwell longer than warnings — the most important toast would be the first to vanish"
        )
        XCTAssertGreaterThan(dwellByKind[.warn] ?? 0, dwellByKind[.info] ?? 0)
        XCTAssertEqual(dwellByKind[.success], dwellByKind[.info])
        for (kind, dwell) in dwellByKind {
            XCTAssertLessThan(dwell, .infinity, "\(kind) defaults to sticky — it would need a manual dismiss")
        }
    }
}
