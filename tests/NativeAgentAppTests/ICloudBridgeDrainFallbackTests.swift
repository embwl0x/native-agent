import Foundation
import Testing
@testable import NativeAgentApp

@Suite("iPhone CloudKit wake fallback")
struct ICloudBridgeDrainFallbackTests {
    @Test("missed silent push is recovered well before the iPhone watchdog")
    func missedPushRecoveryRemainsResponsive() {
        let fallback = iCloudBridge.responsiveDeviceDrainFallbackSeconds

        #expect(fallback == 8)
        #expect(fallback < 180)
    }
}
