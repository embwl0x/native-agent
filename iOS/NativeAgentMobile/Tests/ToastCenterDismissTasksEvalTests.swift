import Foundation
import XCTest
@testable import NativeAgentMobile

/// Coverage-ledger fence `ios.shared.toastCenter.dismissTasks`.
///
/// A replacement toast can keep the same identity while changing its dwell
/// policy. Its retired auto-dismiss task must never remove the replacement.
@MainActor
final class ToastCenterDismissTasksEvalTests: XCTestCase {
    func test_replacingATimedToastWithAStickyToastCancelsTheRetiredTask() async {
        let center = iOSSystemToastCenter()
        let id = UUID()
        center.push(iOSSystemToast(id: id, kind: .info, text: "Saving", autoDismissAfter: 0.04))

        try? await Task.sleep(nanoseconds: 20_000_000)
        center.push(iOSSystemToast(id: id, kind: .success, text: "Saved", autoDismissAfter: nil))

        try? await Task.sleep(nanoseconds: 80_000_000)
        XCTAssertEqual(center.queue.map(\.text), ["Saved"])
        XCTAssertEqual(center.queue.map(\.kind), [.success])
        center.dismissAll()
    }

    func test_invalidDwellTimesNeverReachTaskSleepConversion() {
        XCTAssertNil(iOSSystemToastCenter.dismissDelayNanoseconds(after: nil))
        XCTAssertNil(iOSSystemToastCenter.dismissDelayNanoseconds(after: 0))
        XCTAssertNil(iOSSystemToastCenter.dismissDelayNanoseconds(after: -.infinity))
        XCTAssertNil(iOSSystemToastCenter.dismissDelayNanoseconds(after: .infinity))
        XCTAssertNil(iOSSystemToastCenter.dismissDelayNanoseconds(after: Double.greatestFiniteMagnitude))
        XCTAssertEqual(iOSSystemToastCenter.dismissDelayNanoseconds(after: 0.25), 250_000_000)
    }
}
