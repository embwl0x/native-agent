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

    func test_statusChipLabelCanGrowVerticallyWithoutLosingItsTouchTarget() throws {
        let chrome = try MobileEvalSources.mobileSource("SystemToastBar.swift")
        let chip = try XCTUnwrap(
            MobileEvalSources.blockBody(named: "MacStatusChip", keyword: "struct", in: chrome)
        )

        XCTAssertFalse(chip.contains(".lineLimit(1)"))
        XCTAssertTrue(chip.contains(".fixedSize(horizontal: false, vertical: true)"))
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
            if mount.owner == "MemoryView" {
                XCTAssertTrue(owner.contains("memorySyncStatus"))
                XCTAssertTrue(owner.contains("bridgeClient.bridgeStatus != .online"))
                XCTAssertTrue(owner.contains("Connection unavailable; memories cannot update."))
            } else if mount.owner == "ChatView" {
                XCTAssertTrue(owner.contains("runtimeControlsBar"))
                XCTAssertTrue(source.contains("private var runtimeControlsBar: some View"))
                XCTAssertTrue(source.contains("MacStatusChip().fixedSize(horizontal: true, vertical: false)"))
            } else {
                XCTAssertTrue(owner.contains("MacStatusChip()"), "Expected \(mount.owner) to name the shared chip")
            }
        }
    }
}
