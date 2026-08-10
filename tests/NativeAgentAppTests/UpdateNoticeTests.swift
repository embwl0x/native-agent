import XCTest
@testable import NativeAgentApp

/// Persistent update-available notice (Settings row + app menu). The
/// controller's Sparkle wiring is exercised only in release bundles; these
/// tests pin the pure display logic the views read.
@MainActor
final class UpdateNoticeTests: XCTestCase {

    private var validInfo: [String: Any] {
        [
            "CFBundleShortVersionString": "0.3.8",
            "SUFeedURL": "https://updates.nativeagent.dev/appcast.xml",
            "SUPublicEDKey": Data(repeating: 7, count: 32).base64EncodedString(),
            "NativeAgentUpdateFeedPublished": true,
        ]
    }

    func testMenuTitleNamesAvailableUpdate() {
        let controller = UpdateController.shared
        defer { controller.status.availableVersion = nil }
        controller.status.availableVersion = "9.9.9"
        XCTAssertEqual(controller.menuTitle, "Update Available — 9.9.9…")
        XCTAssertEqual(controller.updateNoticeText, "NativeAgent 9.9.9 is available.")
    }

    func testMenuTitleFallsBackWhenNoUpdateKnown() {
        let controller = UpdateController.shared
        defer { controller.status.availableVersion = nil }
        controller.status.availableVersion = nil
        XCTAssertNil(controller.updateNoticeText)
        // Test bundles carry no Sparkle config, so the truthful dev-build
        // title is the expected fallback here.
        XCTAssertEqual(controller.menuTitle, "About Software Updates…")
    }

    func testNoticeSurvivesRestartForSameInstalledVersionAndFeed() throws {
        let data = try XCTUnwrap(UpdateController.persistedNoticeData(
            availableVersion: "0.3.9",
            info: validInfo
        ))
        XCTAssertEqual(
            UpdateController.restoredNoticeVersion(data: data, info: validInfo),
            "0.3.9"
        )
    }

    func testInstalledEqualOrNewerVersionClearsPersistedNotice() throws {
        let data = try XCTUnwrap(UpdateController.persistedNoticeData(
            availableVersion: "0.3.9",
            info: validInfo
        ))
        XCTAssertNil(UpdateController.restoredNoticeVersion(
            data: data,
            info: validInfo.merging(["CFBundleShortVersionString": "0.3.9"]) { _, new in new }
        ))
        XCTAssertNil(UpdateController.restoredNoticeVersion(
            data: data,
            info: validInfo.merging(["CFBundleShortVersionString": "0.4.0"]) { _, new in new }
        ))
    }

    func testFeedOrSigningKeyChangeClearsPersistedNotice() throws {
        let data = try XCTUnwrap(UpdateController.persistedNoticeData(
            availableVersion: "0.3.9",
            info: validInfo
        ))
        XCTAssertNil(UpdateController.restoredNoticeVersion(
            data: data,
            info: validInfo.merging(["SUFeedURL": "https://updates.nativeagent.dev/v2.xml"]) { _, new in new }
        ))
        XCTAssertNil(UpdateController.restoredNoticeVersion(
            data: data,
            info: validInfo.merging([
                "SUPublicEDKey": Data(repeating: 8, count: 32).base64EncodedString(),
            ]) { _, new in new }
        ))
    }

    func testCorruptCacheAndInsecureFeedAreRejected() {
        XCTAssertNil(UpdateController.restoredNoticeVersion(
            data: Data("not-json".utf8),
            info: validInfo
        ))
        let insecure = validInfo.merging([
            "SUFeedURL": "http://updates.nativeagent.dev/appcast.xml",
        ]) { _, new in new }
        XCTAssertEqual(UpdateController.resolveUnavailability(info: insecure), .notConfigured)
        XCTAssertNil(UpdateController.persistedNoticeData(
            availableVersion: "0.3.9",
            info: insecure
        ))
        XCTAssertNil(UpdateController.persistedNoticeData(
            availableVersion: "   ",
            info: validInfo
        ))
    }
}
