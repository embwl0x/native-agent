import XCTest
@testable import NativeAgentMobile

/// Coverage-ledger fence `ios.mactools.approvalClassification`.
///
/// Review-needed state comes from a typed signed-action outcome. It must not
/// depend on whether the Mac happens to include the word "approval" in its
/// display prose.
@MainActor
final class MacToolsApprovalClassificationEvalTests: XCTestCase {
    func test_typedApprovalOutcomeSurvivesACompletelyRewordedMacMessage() {
        let reworded = SyncError.approvalRequired("A human decision is needed before this can continue.")
        XCTAssertEqual(RemoteActionState.forError(reworded), .waitingApproval)
        XCTAssertFalse(RemoteActionState.forError(reworded).offersRetry)
    }

    func test_displayTextThatMentionsApprovalDoesNotTurnAnOrdinaryFailureIntoAReviewCard() {
        let incidentalText = NSError(
            domain: "MacToolsApprovalClassificationEval",
            code: 1,
            userInfo: [NSLocalizedDescriptionKey: "Connection failed after reading an approval setting."]
        )
        XCTAssertEqual(RemoteActionState.forError(incidentalText), .failed)
        XCTAssertTrue(RemoteActionState.forError(incidentalText).offersRetry)
    }

    func test_signedPendingApprovalStatusIsConvertedBeforeMacToolsRendersIt() {
        XCTAssertThrowsError(
            try iCloudSyncEngine.shared.requireSuccessfulActionResponse([
                "status": "pending_approval",
                "message": "A human decision is needed before this can continue.",
            ])
        ) { error in
            guard case SyncError.approvalRequired = error else {
                return XCTFail("pending status was not converted into the typed approval outcome: \(error)")
            }
            XCTAssertEqual(RemoteActionState.forError(error), .waitingApproval)
        }
    }

    func test_remoteActionStateUsesTypedErrorMatchingRatherThanDisplayTextScanning() throws {
        let source = try MobileEvalSources.mobileSource("MacToolsView.swift")
        let state = try XCTUnwrap(MobileEvalSources.blockBody(named: "RemoteActionState", keyword: "enum", in: source))
        XCTAssertTrue(state.contains("case SyncError.approvalRequired = error"))
        XCTAssertFalse(state.contains("localizedDescription.lowercased().contains(\"approval\")"))
    }
}
