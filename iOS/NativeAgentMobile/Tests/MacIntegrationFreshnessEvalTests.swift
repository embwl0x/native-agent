import XCTest
@testable import NativeAgentMobile

/// Executable fence for `ios.screens / ios.macintegration.freshness`.
@MainActor
final class MacIntegrationFreshnessEvalTests: XCTestCase {
    func test_securitySettingsScreenHasConnectionAndExplicitFreshnessPaths() throws {
        let view = try MobileEvalSources.mobileSource("MacIntegrationView.swift")
        let sync = try MobileEvalSources.mobileSource("MacIntegrationPermissionsSync.swift")

        XCTAssertTrue(view.contains("MacStatusChip()"))
        XCTAssertTrue(view.contains(".refreshable"))
        XCTAssertTrue(view.contains(".task"))
        XCTAssertTrue(view.contains("refreshMacIntegrationProjection"))
        XCTAssertTrue(view.contains("identity.refreshTrustSnapshot()"))
        XCTAssertTrue(view.contains("sync.refreshProjection()"))
        XCTAssertTrue(sync.contains("func refreshProjection()"))
        XCTAssertTrue(sync.contains("kvs.synchronize()"))
    }

    func test_screenEntryRefreshReReadsAMacChangeWhenNotificationWasMissed() {
        var projection: [String: Any]? = ["calendar": ["read": true, "write": false]]
        let sync = MacIntegrationPermissionsSync(
            projectionLoader: { projection },
            observesExternalChanges: false
        )
        XCTAssertTrue(sync.get(id: "calendar", mode: "read"))

        // No KVS notification is delivered while the phone is backgrounded.
        // The screen's task/refresh path must still pull the new Mac value.
        projection = ["calendar": ["read": false, "write": false]]
        sync.refreshProjection()

        XCTAssertFalse(sync.get(id: "calendar", mode: "read"))
    }
}
