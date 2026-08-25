import Foundation
import XCTest
@testable import NativeAgentMobile

/// Executable fence for `ios.screens / ios.skills.pairingGate`.
@MainActor
final class SkillLifecyclePairingGateEvalTests: XCTestCase {
    func test_unpairedRefreshGateClearsAPreviouslyPublishedSkillCatalog() throws {
        let skill = try JSONDecoder().decode(
            SkillManifestEntry.self,
            from: Data(#"{"id":"catalog-skill","name":"Published skill","state":"active"}"#.utf8)
        )
        let store = SkillLifecycleStore()
        store.skills = [skill]

        XCTAssertFalse(store.applyPairingGate(isPaired: false))
        XCTAssertTrue(store.skills.isEmpty, "an unpaired phone must not keep displaying a prior Mac skill catalog")
        XCTAssertEqual(store.bannerError, "Pair iPhone with the Mac to see skills.")

        XCTAssertTrue(store.applyPairingGate(isPaired: true))
        XCTAssertNil(store.bannerError)
    }

    func test_refreshStartsItsVisibleLoadingLifecycleBeforeCheckingPairing() throws {
        let source = try MobileEvalSources.mobileSource("SkillLifecycleView.swift")
        let refresh = try XCTUnwrap(
            MobileEvalSources.blockBody(named: "refresh(pairingStore: PairingStore) async", keyword: "func", in: source)
        )
        let loading = try XCTUnwrap(refresh.range(of: "isLoading = true"))
        let pairingGate = try XCTUnwrap(refresh.range(of: "applyPairingGate(isPaired: pairingStore.isPaired)"))

        XCTAssertLessThan(loading.lowerBound, pairingGate.lowerBound)
        XCTAssertTrue(refresh.contains("defer { isLoading = false }"))
    }
}
