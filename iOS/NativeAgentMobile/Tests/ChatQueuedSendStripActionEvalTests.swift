import Foundation
import XCTest
@testable import NativeAgentMobile

/// EVAL FENCE: ios.screens / ios.chat.queuedSendStrip.sendNow
final class ChatQueuedSendStripActionEvalTests: XCTestCase {
    func testCapturedSendActionDoesNotTurnIntoSteerAfterLoadingStateChanges() {
        let id = UUID()
        var loadingAtTap = false
        let action = QueuedSendStripAction.resolve(id: id, isLoading: loadingAtTap)
        XCTAssertEqual(action.primaryTitle, "Send")

        // The loading state may turn true after this button rendered. The
        // captured action must still take the route named by its visible label.
        loadingAtTap = true
        XCTAssertTrue(loadingAtTap)
        var invoked: String?
        action.apply(
            onSteer: { _ in invoked = "steer" },
            onSend: { sentID in
                XCTAssertEqual(sentID, id)
                invoked = "send"
            }
        )
        XCTAssertEqual(invoked, "send")
    }

    func testCapturedSteerActionDoesNotTurnIntoSendAfterLoadingStateChanges() {
        let id = UUID()
        var loadingAtTap = true
        let action = QueuedSendStripAction.resolve(id: id, isLoading: loadingAtTap)
        XCTAssertEqual(action.primaryTitle, "Steer")
        XCTAssertEqual(action.menuTitle(position: 2, preview: "queued turn"), "Steer 2 now: queued turn")

        loadingAtTap = false
        XCTAssertFalse(loadingAtTap)
        var invoked: String?
        action.apply(
            onSteer: { steeredID in
                XCTAssertEqual(steeredID, id)
                invoked = "steer"
            },
            onSend: { _ in invoked = "send" }
        )
        XCTAssertEqual(invoked, "steer")
    }
}
