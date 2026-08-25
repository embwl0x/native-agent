import XCTest
@testable import NativeAgentMobile

/// EVAL FENCE: ios.screens / ios.settings.forceRefreshFromICloud
final class SettingsForceRefreshFromICloudEvalTests: XCTestCase {
    func testCompletedRefreshAcknowledgesBothPairingAndSettingsSnapshotOutcomes() {
        XCTAssertEqual(
            SettingsICloudRefreshPresentation.statusText(
                pairingMaterialChanged: true,
                snapshotError: nil
            ),
            "New pairing material installed. Settings snapshot reload completed."
        )

        XCTAssertEqual(
            SettingsICloudRefreshPresentation.statusText(
                pairingMaterialChanged: false,
                snapshotError: nil
            ),
            "No new pairing material was installed. Settings snapshot reload completed."
        )
    }

    func testIncompleteSettingsSnapshotIsReportedWithoutPretendingPairingFailed() {
        XCTAssertEqual(
            SettingsICloudRefreshPresentation.statusText(
                pairingMaterialChanged: false,
                snapshotError: "Settings snapshots are still downloading from iCloud. Try again in a moment."
            ),
            "No new pairing material was installed. Settings snapshots are still downloading from iCloud. Try again in a moment."
        )
    }

    func testSettingsActionRefreshesPairingThenSettingsAndPreventsOverlappingRefreshes() throws {
        let source = try MobileEvalSources.mobileSource("SettingsViewFull.swift")
        let settingsView = try XCTUnwrap(
            MobileEvalSources.blockBody(named: "SettingsViewFull", keyword: "struct", in: source)
        )

        XCTAssertTrue(settingsView.contains("await pairingStore.refreshFromKVS()"))
        XCTAssertTrue(settingsView.contains("await store.refresh()"))
        XCTAssertTrue(settingsView.contains("SettingsICloudRefreshPresentation.statusText("))
        XCTAssertTrue(settingsView.contains(".disabled(isForceRefreshing)"))
    }
}
