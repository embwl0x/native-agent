import XCTest
@testable import NativeAgentMobile

/// EVAL FENCE: ios.screens / ios.mactools.setVolume
final class MacToolsSetVolumeEvalTests: XCTestCase {
    func testSliderValueIsNormalizedIntoASafeVolumeTarget() {
        XCTAssertEqual(MacVolumeControlPresentation.targetPercent(for: 0), 0)
        XCTAssertEqual(MacVolumeControlPresentation.targetPercent(for: 0.55), 55)
        XCTAssertEqual(MacVolumeControlPresentation.targetPercent(for: -0.1), 0)
        XCTAssertEqual(MacVolumeControlPresentation.targetPercent(for: 1.2), 100)
        XCTAssertEqual(MacVolumeControlPresentation.targetPercent(for: .nan), 50)
    }

    func testOnlyTheMacActionBoundaryAcceptsValidPercentages() {
        XCTAssertTrue(MacVolumeControlPresentation.isValid(percent: 0))
        XCTAssertTrue(MacVolumeControlPresentation.isValid(percent: 100))
        XCTAssertFalse(MacVolumeControlPresentation.isValid(percent: -1))
        XCTAssertFalse(MacVolumeControlPresentation.isValid(percent: 101))
    }

    func testAcknowledgementDoesNotClaimTheSliderIsMacVolumeReadback() {
        let acknowledgement = MacVolumeControlPresentation.acknowledgement(percent: 55)

        XCTAssertEqual(
            acknowledgement,
            "The Mac accepted the request to set volume to 55%. Its current output volume is not read back to iPhone."
        )
        XCTAssertTrue(MacVolumeControlPresentation.currentVolumeDisclosure.contains("not a readback"))
    }

    func testActionChannelValidatesBeforeSendingAVolumeValue() throws {
        let actions = try MobileEvalSources.mobileSource("iCloudSyncEngine+Actions.swift")

        XCTAssertTrue(actions.contains("guard MacVolumeControlPresentation.isValid(percent: percent)"))
        XCTAssertTrue(actions.contains("Volume must be between 0% and 100%."))
    }
}
