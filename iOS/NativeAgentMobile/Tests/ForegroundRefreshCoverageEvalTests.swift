import XCTest
@testable import NativeAgentMobile
import NativeAgentShared

/// Coverage-ledger fence `ios.app.foregroundRefresh`.
final class ForegroundRefreshCoverageEvalTests: XCTestCase {
    func test_foregroundRefreshUsesTheFullLoaderForEveryMobileSnapshotGroup() throws {
        let app = try MobileEvalSources.mobileSource("NativeAgentMobileApp.swift")
        let foreground = try XCTUnwrap(
            MobileEvalSources.blockBody(
                named: "refreshOnForeground",
                keyword: "private func",
                in: app
            )
        )
        let snapshots = try MobileEvalSources.mobileSource("iCloudSyncEngine+Snapshots.swift")
        let fullLoader = try XCTUnwrap(
            MobileEvalSources.blockBody(
                named: "loadAllSnapshots",
                keyword: "private nonisolated static func",
                in: snapshots
            )
        )

        XCTAssertTrue(foreground.contains("guard pairingStore.usesICloudTransport else { return }"))
        XCTAssertTrue(foreground.contains("await iCloudSyncEngine.shared.refreshSnapshots()"))
        XCTAssertFalse(foreground.contains("refreshActivitySnapshot"))

        for group in NAMobileSnapshotGroup.allCases {
            XCTAssertTrue(
                group.filenames.contains { fullLoader.contains("\"\($0)\"") },
                "Foreground refresh no longer reaches the \(group.rawValue) snapshot group."
            )
        }
    }

    func test_sceneActivationStillInvokesTheForegroundRefreshOwner() throws {
        let app = try MobileEvalSources.mobileSource("NativeAgentMobileApp.swift")

        XCTAssertTrue(app.contains(".onChange(of: scenePhase)"))
        XCTAssertTrue(app.contains("if newPhase == .active { refreshOnForeground() }"))
    }
}
