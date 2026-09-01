import XCTest
@testable import NativeAgentMobile

/// Coverage-ledger fence `ios.screens / ios.shared.macStatusChip`.
///
/// iCloud accepting an outgoing phone message is not evidence that the Mac is
/// awake. The navigation chip must leave that state visibly uncertain.
@MainActor
final class MacStatusChipEvalTests: XCTestCase {
    func test_availableICloudWithoutMacEvidenceIsNotShownAsFreshMacConnection() {
        let status = MacBridgeClient.bridgeStatusDecision(
            bridgeAvailable: true,
            lastSeenAt: nil,
            connectingStartedAt: nil,
            bridgeUnavailableSince: nil,
            isPaired: true,
            now: Date()
        )

        XCTAssertEqual(status, .awaitingMacActivity)
        XCTAssertNotEqual(status, .online)
        XCTAssertEqual(status.displayName, "Waiting for Mac activity")
    }

    func test_statusChipNamesTheWaitingStateAndOutgoingSendDoesNotConfirmMacActivity() throws {
        let chrome = try MobileEvalSources.mobileSource("SystemToastBar.swift")
        XCTAssertTrue(chrome.contains("MacStatusChipPresentation.shortLabel(for: status)"))
        XCTAssertTrue(chrome.contains("this phone has not received any activity from the Mac yet"))

        let client = try MobileEvalSources.mobileSource("MacBridgeClient.swift")
        let send = try XCTUnwrap(MobileEvalSources.blockBody(named: "sendMessage(", keyword: "func", in: client))
        XCTAssertFalse(send.contains("recordMacConfirmation()"))
        XCTAssertTrue(client.contains("self?.recordMacConfirmation()"))
    }

    func test_everyStatusHasAVerboseChipLabelIncludingHealthy() {
        XCTAssertEqual(MacStatusChipPresentation.shortLabel(for: .online), "Live")
        XCTAssertEqual(MacStatusChipPresentation.shortLabel(for: .awaitingMacActivity), "Waiting for Mac")
        XCTAssertEqual(MacStatusChipPresentation.shortLabel(for: .offline), "No iCloud")
        XCTAssertEqual(MacStatusChipPresentation.shortLabel(for: .macUnreachable), "Mac unavailable")
        XCTAssertEqual(MacStatusChipPresentation.shortLabel(for: .deviceOffline), "iPhone offline")
        XCTAssertEqual(MacStatusChipPresentation.shortLabel(for: .stale(minutesAgo: 4)), "4m ago")
        XCTAssertEqual(MacStatusChipPresentation.shortLabel(for: .connecting), "Connecting")
    }

    func test_statusChipLabelCannotWrapWhenTheNavigationBarCompressesIt() throws {
        let chrome = try MobileEvalSources.mobileSource("SystemToastBar.swift")
        let chip = try XCTUnwrap(
            MobileEvalSources.blockBody(named: "MacStatusChip", keyword: "struct", in: chrome)
        )

        XCTAssertTrue(chip.contains(".lineLimit(1)"))
        XCTAssertTrue(chip.contains(".fixedSize(horizontal: true, vertical: false)"))
        XCTAssertTrue(chip.contains(".frame(minWidth: 44, minHeight: 44)"))
    }

    func test_unreachableCopyDoesNotInventSleepOrHealthyICloud() {
        let explanation = MacStatusChipPresentation.explanation(for: .macUnreachable)
        XCTAssertFalse(explanation.contains("iCloud is fine"))
        XCTAssertTrue(explanation.contains("may be asleep or offline"))
        XCTAssertTrue(explanation.contains("iCloud may be unavailable"))

        let recent = MacStatusChipPresentation.explanation(for: .online)
        XCTAssertTrue(recent.contains("checked in recently"))
        XCTAssertFalse(recent.contains("picking up what you send"))
    }

    func test_everyMacSnapshotSurfaceMountsTheSharedConnectionChip() throws {
        let mounts: [(file: String, owner: String)] = [
            ("ChatView.swift", "ChatView"),
            ("ActivityView.swift", "ActivityView"),
            ("MemoryView.swift", "MemoryView"),
            ("SkillsToolsView.swift", "SkillsToolsView"),
            ("DeskView.swift", "MobileDeskView"),
            ("InboxView.swift", "InboxView"),
            ("ApprovalsView.swift", "ApprovalsView"),
            ("SkillLifecycleView.swift", "SkillLifecycleDetailSheet"),
            ("MacToolsView.swift", "MacToolsView"),
            ("MacIntegrationView.swift", "MacIntegrationView"),
            ("KnowledgeGraphView.swift", "KnowledgeGraphView"),
            ("TurnInspectorView.swift", "TurnInspectorView"),
            ("AdvancedView.swift", "AdvancedView"),
            ("SettingsViewFull.swift", "SettingsViewFull"),
        ]

        for mount in mounts {
            let source = try MobileEvalSources.mobileSource(mount.file)
            let owner = try XCTUnwrap(
                MobileEvalSources.blockBody(named: mount.owner, keyword: "struct", in: source),
                "Expected (mount.owner) in (mount.file)"
            )
            XCTAssertTrue(owner.contains("MacStatusChip()"), "Expected (mount.owner) to name the shared chip")
        }
    }
}
