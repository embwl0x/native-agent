import XCTest
@testable import NativeAgentMobile

/// EVAL FENCE: ios.screens / ios.mactools.policyGate.loadPolicy
@MainActor
final class MacToolsPolicyGateLoadPolicyEvalTests: XCTestCase {
    func testFailedReloadCannotReuseAnOlderEnabledPolicy() {
        var cachedEnabledPolicy = TrustMacControlPolicy()
        cachedEnabledPolicy.enabled = true
        cachedEnabledPolicy.remoteFromIosAllowed = true

        let gatePolicy = MacToolsPolicyGatePresentation.policyForGate(
            snapshotLoaded: false,
            refreshedPolicy: cachedEnabledPolicy
        )

        XCTAssertNil(gatePolicy)
        XCTAssertEqual(
            MacToolsPolicyGatePresentation.state(for: gatePolicy),
            .snapshotUnavailable
        )
    }

    func testLoadedSnapshotContinuesToApplyItsExplicitPolicyGate() {
        var enabledPolicy = TrustMacControlPolicy()
        enabledPolicy.enabled = true
        enabledPolicy.remoteFromIosAllowed = true

        let gatePolicy = MacToolsPolicyGatePresentation.policyForGate(
            snapshotLoaded: true,
            refreshedPolicy: enabledPolicy
        )

        XCTAssertEqual(gatePolicy, enabledPolicy)
        XCTAssertEqual(MacToolsPolicyGatePresentation.state(for: gatePolicy), .enabled)
    }

    func testTrustRefreshReportsFailureWhenNoSnapshotDirectoryIsConfigured() async {
        let engine = iCloudSyncEngine.shared
        let priorSnapshotDir = engine.snapshotDir
        defer { engine.snapshotDir = priorSnapshotDir }

        engine.snapshotDir = nil
        let refreshed = await engine.refreshTrustSnapshot()
        XCTAssertFalse(refreshed)
    }

    func testMacToolsBindsTheGateOnlyToTheCurrentRefreshResult() throws {
        let source = try MobileEvalSources.mobileSource("MacToolsView.swift")
        let loadPolicy = try XCTUnwrap(
            MobileEvalSources.blockBody(named: "loadPolicy", keyword: "private func", in: source)
        )

        XCTAssertTrue(loadPolicy.contains("let snapshotLoaded = await iCloudSyncEngine.shared.refreshTrustSnapshot()"))
        XCTAssertTrue(loadPolicy.contains("MacToolsPolicyGatePresentation.policyForGate("))
        XCTAssertTrue(loadPolicy.contains("snapshotLoaded: snapshotLoaded"))
    }
}
