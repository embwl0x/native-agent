import XCTest
@testable import NativeAgentMobile

/// EVAL FENCE: ios.sync / ios.app.pairingSkipped
final class PairingSkippedEvalTests: XCTestCase {
    func testSkipShowsMainAppWithoutClaimingAnUnpairedDeviceIsPaired() {
        XCTAssertEqual(PairingSkipPresentation.mainAppState(isPaired: false, pairingSkipped: false), .pairingRequired)
        XCTAssertEqual(PairingSkipPresentation.mainAppState(isPaired: false, pairingSkipped: true), .skipped)
        XCTAssertEqual(PairingSkipPresentation.mainAppState(isPaired: true, pairingSkipped: true), .paired)
    }

    func testSkipPersistsChoiceAndReconfiguresRetainedPairingTransport() throws {
        let source = try MobileEvalSources.mobileSource("NativeAgentMobileApp.swift")
        XCTAssertTrue(source.contains("pairingSkipped = true\n                        configureTransport()"))
        XCTAssertTrue(source.contains("Does NOT clear any existing pairing credentials."))
    }
}
