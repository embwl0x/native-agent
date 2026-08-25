import XCTest
@testable import NativeAgentMobile

/// Executable fence for `ios.screens / ios.mactools.lockScreen`.
final class MacToolsLockScreenPolicyDecodeEvalTests: XCTestCase {
    func test_lockScreenPolicyDecodesEveryGatePublishedByTheMac() throws {
        let fixture = try JSONSerialization.data(withJSONObject: [
            "enabled": true,
            "remote_from_ios_allowed": true,
            "shortcuts_allowed": false,
            "notifications_allowed": false,
            "system_control_allowed": true,
            "spotlight_allowed": false,
        ])

        let policy = try JSONDecoder().decode(TrustMacControlPolicy.self, from: fixture)

        XCTAssertTrue(policy.enabled)
        XCTAssertTrue(policy.remoteFromIosAllowed)
        XCTAssertFalse(policy.shortcutsAllowed)
        XCTAssertFalse(policy.notificationsAllowed)
        XCTAssertTrue(policy.systemControlAllowed)
        XCTAssertFalse(policy.spotlightAllowed)
        XCTAssertEqual(MacToolsPolicyGatePresentation.state(for: policy), .enabled)
    }
}
