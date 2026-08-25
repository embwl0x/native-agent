import XCTest
@testable import NativeAgentMobile

/// Coverage-ledger fence `ios.app.refreshOnForeground`.
///
/// A process can start while its scene is already active, which produces no
/// `.onChange` event. The main-app mount must therefore invoke the same owner
/// as later active transitions, behind the iCloud-pairing gate.
final class AppRefreshOnForegroundEvalTests: XCTestCase {
    func test_mainAppMountAndSceneActivationShareThePairedFullRefreshOwner() throws {
        let source = try MobileEvalSources.mobileSource("NativeAgentMobileApp.swift")
        let app = try XCTUnwrap(
            MobileEvalSources.blockBody(named: "NativeAgentMobileApp", keyword: "struct", in: source)
        )
        let foreground = try XCTUnwrap(
            MobileEvalSources.blockBody(named: "refreshOnForeground", keyword: "private func", in: source)
        )

        XCTAssertTrue(foreground.contains("guard pairingStore.usesICloudTransport else { return }"))
        XCTAssertTrue(foreground.contains("await iCloudSyncEngine.shared.refreshSnapshots()"))

        let mainContent = try XCTUnwrap(app.range(of: "ContentView()"))
        let initialRefresh = try XCTUnwrap(
            app.range(of: "refreshOnForeground()", range: mainContent.upperBound..<app.endIndex)
        )
        let sceneRefresh = try XCTUnwrap(
            app.range(of: "if newPhase == .active { refreshOnForeground() }", range: mainContent.upperBound..<app.endIndex)
        )
        XCTAssertLessThan(initialRefresh.lowerBound, sceneRefresh.lowerBound)
    }
}
