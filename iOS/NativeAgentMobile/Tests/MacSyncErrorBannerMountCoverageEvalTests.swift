import XCTest
@testable import NativeAgentMobile

/// Coverage-ledger fence `ios.shared.macSyncErrorBanner.mountCoverage`.
final class MacSyncErrorBannerMountCoverageEvalTests: XCTestCase {
    func test_everySnapshotReadingScreenMountsTheSharedMacSyncErrorBanner() throws {
        let snapshotReadingScreens = [
            ("ActivityView.swift", "ActivityView"),
            ("ApprovalsView.swift", "ApprovalsView"),
            ("AutonomyView.swift", "AutonomyView"),
            ("AdvancedView.swift", "AdvancedView"),
            ("ChatView.swift", "ChatView"),
            ("DeskView.swift", "MobileDeskView"),
            ("InboxView.swift", "InboxView"),
            ("KnowledgeGraphView.swift", "KnowledgeGraphView"),
            ("MacIntegrationView.swift", "MacIntegrationView"),
            ("MacToolsView.swift", "MacToolsView"),
            ("MemoryView.swift", "MemoryView"),
            ("ProviderSettingsView.swift", "ProviderSettingsView"),
            ("SettingsViewFull.swift", "SettingsViewFull"),
            ("SkillsToolsView.swift", "SkillsToolsView"),
            ("TurnInspectorView.swift", "TurnInspectorView"),
            ("WorkshopView.swift", "WorkshopView"),
        ]

        for (file, screen) in snapshotReadingScreens {
            let source = try MobileEvalSources.mobileSource(file)
            let body = try XCTUnwrap(
                MobileEvalSources.blockBody(named: screen, keyword: "struct", in: source),
                "Could not find \(screen) in \(file)"
            )
            XCTAssertTrue(
                body.contains(".macSyncErrorBanner()"),
                "\(screen) reads Mac-published state but does not surface iCloudSyncEngine.syncError."
            )
        }
    }
}
