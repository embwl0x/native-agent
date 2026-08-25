import XCTest
@testable import NativeAgentMobile

/// Coverage-ledger fence `ios.screens`.
///
/// Rows exercised here:
/// - ios.mactools.policyGate / ios.mactools.policyGate.loadPolicy
/// - ios.mactools.quickAction.unknownActionSilentSuccess
/// - ios.mactools.remoteActionCards / ios.mactools.remoteActionLedger
/// - ios.mactools.remoteActionCard.approvalClassification
/// - ios.mactools.reviewApprovalButton / ios.mactools.retryButton
///
/// The phone is not allowed to say an action happened just because it managed
/// to post an envelope.  MacControl is a privileged, remote operation: all
/// response shapes must pass through the same `applied == false` rejection
/// boundary used by approvals and Desk mutations, unknown commands must not
/// fall through to the optimistic completion copy, and a user must have an
/// honest recovery path for denied/failed cards.
@MainActor
final class MacControlTruthfulnessEvalTests: XCTestCase {
    func testMacControlResponsesUseTheSharedAppliedTruthBoundary() throws {
        let actions = try MobileEvalSources.mobileSource("iCloudSyncEngine+Actions.swift")

        XCTAssertTrue(
            actions.contains("requireSuccessfulActionResponse("),
            "Mac-control replies must use the shared mutation boundary: an ok=true/applied=false reply is not evidence that the Mac changed anything."
        )
    }

    func testQuickActionHasAClosedCommandSetBeforeItCreatesACompletionCard() async {
        var sent: [MacSystemQuickAction] = []
        let lock = await MacSystemQuickActionExecution.execute(named: "lock_screen") { action in
            sent.append(action)
        }
        let sleep = await MacSystemQuickActionExecution.execute(named: "sleep_display") { action in
            sent.append(action)
        }
        let unsupported = await MacSystemQuickActionExecution.execute(named: "erase_mac") { action in
            sent.append(action)
        }

        XCTAssertEqual(sent, [.lockScreen, .sleepDisplay])
        XCTAssertEqual(lock.state, .ranOnMac)
        XCTAssertEqual(lock.status, "Done.")
        XCTAssertEqual(sleep.state, .ranOnMac)
        XCTAssertEqual(unsupported.state, .failed)
        XCTAssertTrue(unsupported.status.contains("Unsupported Mac system action"))
        XCTAssertFalse(unsupported.status.contains("Done."))
    }

    func testPolicyGatedControlsExplainEveryDisabledPrivilege() {
        XCTAssertEqual(MacToolsPolicyGatePresentation.state(for: nil), .snapshotUnavailable)
        XCTAssertTrue(
            MacToolsPolicyGatePresentation.disabledDescription(for: nil)
                .contains("No Mac Control policy snapshot yet.")
        )

        var enabled = TrustMacControlPolicy()
        enabled.enabled = true
        enabled.remoteFromIosAllowed = true
        enabled.shortcutsAllowed = true
        enabled.notificationsAllowed = true
        enabled.systemControlAllowed = true
        enabled.spotlightAllowed = true

        for privilege in MacToolsPrivilege.allCases {
            XCTAssertTrue(
                MacToolsPrivilegePresentation.isAllowed(privilege, policy: enabled),
                "\(privilege) must remain available when its Mac-side gate is enabled"
            )
            XCTAssertFalse(
                MacToolsPrivilegePresentation.disabledDescription(for: privilege).isEmpty,
                "a disabled privileged control must explain the Mac-side policy gate, not merely appear dimmed"
            )
        }

        for privilege in MacToolsPrivilege.allCases {
            var locked = enabled
            switch privilege {
            case .shortcuts: locked.shortcutsAllowed = false
            case .notifications: locked.notificationsAllowed = false
            case .systemControl: locked.systemControlAllowed = false
            case .spotlight: locked.spotlightAllowed = false
            }
            XCTAssertFalse(MacToolsPrivilegePresentation.isAllowed(privilege, policy: locked))
        }
    }

    func testRemoteActionCardsKeepApprovalAndFailureDistinctAndRecoverable() {
        let approvalState = RemoteActionState.forError(
            SyncError.approvalRequired("Approval wording can change on the Mac.")
        )
        let failureState = RemoteActionState.forError(SyncError.timeout("iCloud timed out"))

        XCTAssertEqual(approvalState, .waitingApproval)
        XCTAssertEqual(failureState, .failed)
        XCTAssertEqual(
            RemoteActionCardRecoveryPresentation.control(for: approvalState),
            .reviewApproval
        )
        XCTAssertEqual(
            RemoteActionCardRecoveryPresentation.control(for: failureState),
            .retry
        )
        XCTAssertEqual(
            RemoteActionCardRecoveryPresentation.control(for: .ranOnMac),
            .none
        )
    }
}
