import XCTest
@testable import NativeAgentMobile

/// Coverage-ledger fence `ios.advanced.hostViews.freshStorePerPush`.
///
/// A returned-to host view must not briefly reuse a stale Settings snapshot
/// from an earlier navigation push while the current Mac snapshot arrives.
@MainActor
final class AdvancedHostViewsFreshStorePerPushEvalTests: XCTestCase {
    func test_storeFactoryProducesIndependentStoresForSeparatePushes() {
        let first = AdvancedHostViewStoreFactory.makeSettingsStore()
        let second = AdvancedHostViewStoreFactory.makeSettingsStore()

        XCTAssertFalse(first === second)
    }

    func test_everySettingsHostReplacesItsStoreWhenItAppears() throws {
        let source = try MobileEvalSources.mobileSource("AdvancedView.swift")
        for host in ["PersonalityDetailHostView", "ConnectorsHostView", "TrustHostView"] {
            let body = try XCTUnwrap(MobileEvalSources.blockBody(named: host, keyword: "private struct", in: source))
            XCTAssertTrue(body.contains("@State private var store: SettingsStore?"), "\(host) retained a StateObject across pushes")
            XCTAssertTrue(body.contains(".onAppear { beginFreshPush() }"), "\(host) does not replace its store on a new push")
            XCTAssertTrue(body.contains("AdvancedHostViewStoreFactory.makeSettingsStore()"), "\(host) does not obtain a fresh store")
        }
    }
}
