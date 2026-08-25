import XCTest
@testable import NativeAgentMobile

/// Executable fence for `ios.screens / ios.connectors.detail`.
///
/// Connector configuration is not proof of connector health. An enabled row
/// without a health result must stay visibly unknown rather than green.
final class ConnectorsDetailHealthEvalTests: XCTestCase {
    func test_onlyAnExplicitHealthyResultGetsTheHealthyPresentation() {
        XCTAssertEqual(
            ConnectorHealthPresentation.resolve(enabled: true, healthStatus: "ok"),
            .healthy("ok")
        )
        XCTAssertEqual(
            ConnectorHealthPresentation.resolve(enabled: nil, healthStatus: " READY "),
            .healthy("READY")
        )
    }

    func test_enabledConnectorWithoutHealthIsExplicitlyUnknownNotHealthy() {
        for health in [nil, "", " \n\t "] {
            let presentation = ConnectorHealthPresentation.resolve(enabled: true, healthStatus: health)
            XCTAssertEqual(presentation, .unknown)
            XCTAssertEqual(presentation.displayText, "Health unknown")
            XCTAssertNotEqual(presentation.tint, .green)
        }
    }

    func test_disabledAndAttentionHealthAreNotShownAsHealthy() {
        let disabled = ConnectorHealthPresentation.resolve(enabled: false, healthStatus: "ok")
        XCTAssertEqual(disabled, .disabled)
        XCTAssertEqual(disabled.displayText, "Disabled")
        XCTAssertNotEqual(disabled.tint, .green)

        let needsAuth = ConnectorHealthPresentation.resolve(enabled: true, healthStatus: "needs_auth")
        XCTAssertEqual(needsAuth, .needsAttention("needs_auth"))
        XCTAssertEqual(needsAuth.displayText, "Needs Auth")
        XCTAssertNotEqual(needsAuth.tint, .green)
    }

    func test_connectorCardsUseTheHealthProjectionForBothDotAndCopy() throws {
        let source = try MobileEvalSources.mobileSource("SettingsViewFull.swift")
        XCTAssertTrue(source.contains("ConnectorHealthPresentation.resolve("))
        XCTAssertTrue(source.contains("PulsingDot(color: health.tint)"))
        XCTAssertTrue(source.contains("Text(health.displayText)"))
        XCTAssertFalse(source.contains("connector.enabled == true ? .green : .secondary"))
        XCTAssertFalse(source.contains("connector.healthStatus ?? (connector.enabled == true ? \"Enabled\" : \"Disabled\")"))
    }
}
