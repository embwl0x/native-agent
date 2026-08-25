import Testing
@testable import NativeAgentApp

// EVAL FENCE: app.settings / ui.SlimSettings.pairDeviceLink

@Suite("Slim Settings device-pairing link")
struct SlimSettingsPairDeviceLinkEvalTests {
    @Test("the link targets the real Mac pairing setup screen")
    func pairDeviceLinkRoutesToPairingSetup() {
        #expect(SlimSettingsPairDeviceLink.destination == .pairDevice)
        #expect(SlimSettingsPairDeviceLink.destination.content == .macPairing)
        #expect(SlimSettingsPairDeviceLink.title == "Pair iPhone / iPad")
        #expect(SlimSettingsPairDeviceLink.systemImage == "iphone.and.arrow.right.outward")
    }

    @Test("the link does not present opening setup as evidence that a device paired")
    func pairingClaimRemainsBoundedToTheSetupRoute() {
        let hint = SlimSettingsPairDeviceLink.accessibilityHint.lowercased()

        #expect(hint.contains("opens secure device pairing setup"))
        #expect(hint.contains("not paired until"))
        #expect(!hint.contains("device paired"))
    }
}
