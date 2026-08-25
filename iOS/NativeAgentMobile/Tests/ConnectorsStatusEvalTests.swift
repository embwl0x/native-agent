import XCTest
@testable import NativeAgentMobile

/// EVAL FENCE: ios.screens / ios.settings.connectors.status
final class ConnectorsStatusEvalTests: XCTestCase {
    func testPublishedStatusRemainsVisibleWithoutBeingTreatedAsHealthProof() {
        let presentation = ConnectorHealthPresentation.resolve(
            enabled: nil,
            status: " configured ",
            healthStatus: nil
        )

        XCTAssertEqual(presentation, .reportedStatus("configured"))
        XCTAssertEqual(presentation.displayText, "Status: Configured")
        XCTAssertNotEqual(presentation.tint, .green)
    }

    func testLiveHealthTakesPrecedenceAndExplicitDisableStillWins() {
        XCTAssertEqual(
            ConnectorHealthPresentation.resolve(
                enabled: true,
                status: "configured",
                healthStatus: "ok"
            ),
            .healthy("ok")
        )
        XCTAssertEqual(
            ConnectorHealthPresentation.resolve(
                enabled: false,
                status: "active",
                healthStatus: "ok"
            ),
            .disabled
        )
    }

    func testConnectorsScreenPassesPublishedStatusIntoTheTruthfulProjection() throws {
        let source = try MobileEvalSources.mobileSource("SettingsViewFull.swift")
        let connectors = try XCTUnwrap(
            MobileEvalSources.blockBody(named: "ConnectorsView", keyword: "struct", in: source)
        )

        XCTAssertTrue(connectors.contains("status: connector.status"))
        XCTAssertTrue(connectors.contains("healthStatus: connector.healthStatus"))
        XCTAssertTrue(connectors.contains("PulsingDot(color: health.tint)"))
        XCTAssertTrue(connectors.contains("Text(health.displayText)"))
    }
}
