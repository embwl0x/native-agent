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
        XCTAssertTrue(connectors.contains("case .loading:"))
        XCTAssertTrue(connectors.contains("case .unavailable:"))
        XCTAssertTrue(connectors.contains("case .empty:"))
        XCTAssertTrue(connectors.contains(".refreshable { await store.refresh() }"))
    }

    func test_snapshotContentDistinguishesLoadingFailureAndValidEmpty() {
        XCTAssertEqual(
            SettingsSnapshotContentPresentation.state(
                hasContent: false, fieldAvailable: false, isLoading: false, hasCompletedRefresh: false
            ),
            .loading
        )
        XCTAssertEqual(
            SettingsSnapshotContentPresentation.state(
                hasContent: false, fieldAvailable: false, isLoading: false, hasCompletedRefresh: true
            ),
            .unavailable
        )
        XCTAssertEqual(
            SettingsSnapshotContentPresentation.state(
                hasContent: false, fieldAvailable: true, isLoading: false, hasCompletedRefresh: true
            ),
            .empty
        )
        XCTAssertEqual(
            SettingsSnapshotContentPresentation.state(
                hasContent: true, fieldAvailable: false, isLoading: true, hasCompletedRefresh: true
            ),
            .stale
        )
        XCTAssertEqual(
            SettingsSnapshotContentPresentation.state(
                hasContent: true, fieldAvailable: true, isLoading: false, hasCompletedRefresh: true
            ),
            .content
        )
    }

    func test_personalityHasLoadingAndRecoverableUnavailableStates() throws {
        let source = try MobileEvalSources.mobileSource("SettingsViewFull.swift")
        let personality = try XCTUnwrap(
            MobileEvalSources.blockBody(named: "PersonalityDetailView", keyword: "struct", in: source)
        )
        XCTAssertTrue(personality.contains("store.isLoading || !store.hasCompletedRefresh"))
        XCTAssertTrue(personality.contains("title: \"Personality unavailable\""))
        XCTAssertTrue(personality.contains(".refreshable { await store.refresh() }"))
    }
}
