import XCTest
@testable import NativeAgentMobile

/// Executable fence for `ios.screens / ios.settings.macUptime`.
final class SettingsMacUptimeEvalTests: XCTestCase {
    func test_uptimeUsesTheSharedDurationFormatterAtReadableBoundaries() {
        for seconds in [0.4, 9.99, 59.5, 134, 3_780, 431_072] {
            XCTAssertEqual(
                SettingsMacHealthPresentation.uptimeText(seconds),
                UserDisplayFormatters.humanizeDuration(seconds),
                "Settings uptime drifted from the app-wide duration formatter for \(seconds)s"
            )
        }
        XCTAssertEqual(SettingsMacHealthPresentation.uptimeText(431_072), "119h 44m")
    }

    func test_invalidUptimeDoesNotRenderAsAnEmptyOrRawSecondsValue() {
        XCTAssertEqual(SettingsMacHealthPresentation.uptimeText(.nan), "Unknown")
        XCTAssertEqual(SettingsMacHealthPresentation.uptimeText(-1), "Unknown")
    }

    func test_settingsMacSectionUsesTheSharedUptimePresentation() throws {
        let source = try MobileEvalSources.mobileSource("SettingsViewFull.swift")
        XCTAssertTrue(source.contains("SettingsMacHealthPresentation.uptimeText(health.uptimeSeconds)"))
        XCTAssertFalse(source.contains("String(format: \"%.0fs\", health.uptimeSeconds)"))
    }
}
