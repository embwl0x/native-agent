import XCTest
@testable import NativeAgentMobile

/// EVAL FENCE: ios.screens / ios.actions.orphanedPrivilegedMacActions
@MainActor
final class OrphanedPrivilegedMacActionsEvalTests: XCTestCase {
    func testOrphanedMacActionCannotCrossTheSuccessfulResponseBoundary() {
        let engine = iCloudSyncEngine.shared

        XCTAssertThrowsError(
            try engine.requireSuccessfulActionResponse([
                "status": "orphaned",
                "ok": "true",
                "message": "The approval request no longer exists.",
            ])
        ) { error in
            guard case SyncError.unsupported(let message) = error else {
                return XCTFail("orphaned action must be refused, got \(error)")
            }
            XCTAssertEqual(message, "The approval request no longer exists.")
        }
    }

    func testOrphanedResponsesAreRecordedAsOrphanedRatherThanCompleted() throws {
        let source = try MobileEvalSources.mobileSource("iCloudSyncEngine+Actions.swift")

        XCTAssertTrue(source.contains("if status == \"orphaned\" {\n            state = \"orphaned\""))
        XCTAssertTrue(source.contains("This privileged Mac action was orphaned before it could run."))
        XCTAssertFalse(source.contains(": (status == \"pending_approval\" ? \"pending_approval\" : \"completed\")"))
    }
}
