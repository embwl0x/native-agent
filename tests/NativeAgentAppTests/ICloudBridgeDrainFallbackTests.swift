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

        // E3 made the constant the FAST cadence rather than the only cadence,
        // so the constant alone no longer proves this test's claim. The claim
        // is about the scenario the phone is actually in when a push is missed
        // — a turn in flight — so assert the policy there.
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        var policy = AdaptiveDrainPolicy()
        policy.fastInterval = fallback
        policy.noteOutstanding("in-flight-turn", at: now)
        #expect(policy.interval(now: now.addingTimeInterval(30)) == fallback)
        // Even a turn that has run for a while stays inside the 180s watchdog.
        #expect(policy.interval(now: now.addingTimeInterval(170)) < 180)
    }

    @Test("an idle Mac stops paying the fast cadence")
    func idleMacStretchesTheFallback() {
        // The other half of E3: without this the fallback was ~10,800 CloudKit
        // fetches a day on a Mac whose phone had not spoken in hours.
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        var policy = AdaptiveDrainPolicy()
        policy.notePeerActivity(at: now.addingTimeInterval(-10_000))
        #expect(policy.interval(now: now) == policy.idleInterval)
        #expect(policy.idleInterval > iCloudBridge.responsiveDeviceDrainFallbackSeconds)
    }
}
