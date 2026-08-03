import Foundation
import Testing
@testable import NativeAgentApp

// The coding-organ return bridge is deliberately always resident and is
// protected by loopback binding, a per-launch bearer, and endpoint-level Trust
// Center gates. MacControl is different: it remains an explicit user-granted
// capability and these tests pin that authority boundary.
@Suite("Mac Control bridge start gate")
struct BridgeStartGateTests {

    // MARK: - MacControlBridge (macControlPolicy.enabled)

    @Test("MacControlBridge starts only when macControlPolicy.enabled is true")
    func macControlAllowsWhenEnabled() {
        #expect(MacControlBridge.startGateAllows(
            policyJSON: ["macControlPolicy": ["enabled": true]]
        ))
    }

    @Test("MacControlBridge stays down when disabled, absent, or unreadable")
    func macControlDeniesWhenNotEnabled() {
        #expect(MacControlBridge.startGateAllows(
            policyJSON: ["macControlPolicy": ["enabled": false]]
        ) == false)
        // macControlPolicy block present but no `enabled` key.
        #expect(MacControlBridge.startGateAllows(
            policyJSON: ["macControlPolicy": ["applescript_allowed": true]]
        ) == false)
        // No macControlPolicy block at all (non-developer-mode policy scrub
        // strips it entirely).
        #expect(MacControlBridge.startGateAllows(
            policyJSON: ["permissionLevel": "balanced"]
        ) == false)
        // Missing / unparseable policy file must fail CLOSED.
        #expect(MacControlBridge.startGateAllows(policyJSON: nil) == false)
        // Non-Bool truthy value must not satisfy the gate.
        #expect(MacControlBridge.startGateAllows(
            policyJSON: ["macControlPolicy": ["enabled": "true"]]
        ) == false)
    }

    @Test("developerMode does not open the Mac Control bridge gate")
    func macControlIgnoresDeveloperMode() {
        #expect(MacControlBridge.startGateAllows(
            policyJSON: ["developerMode": true]
        ) == false)
    }

    // MARK: - Numeric truthiness must NOT open the Mac Control gate
    //
    // The Foundation trap these pin: `NSNumber(1) as? Bool` SUCCEEDS, so a
    // policy file carrying `{"developerMode": 1}` would have bound a port and
    // minted a bearer token through `as? Bool == true`. The app's own writer
    // emits real JSON booleans, so this is about damaged or tampered authority
    // bytes — where the direction of error must be "stay down".
    //
    // These parse real JSON BYTES through JSONSerialization rather than
    // hand-building a dictionary: a Swift literal `1` would bridge to NSNumber
    // anyway, but going through the parser proves the exact object graph the
    // production reader sees.

    private func parsed(_ json: String) -> [String: Any]? {
        guard let data = json.data(using: .utf8) else { return nil }
        return (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
    }

    @Test("numeric 1 does not open the Mac Control bridge gate")
    func macControlDeniesNumericTruthy() {
        #expect(MacControlBridge.startGateAllows(
            policyJSON: parsed(#"{"macControlPolicy": {"enabled": 1}}"#)
        ) == false)
        #expect(MacControlBridge.startGateAllows(
            policyJSON: parsed(#"{"macControlPolicy": {"enabled": 0}}"#)
        ) == false)
        #expect(MacControlBridge.startGateAllows(
            policyJSON: parsed(#"{"macControlPolicy": {"enabled": true}}"#)
        ))
    }

    @Test("strictBool accepts only real JSON booleans")
    func strictBoolIsStrict() {
        #expect(BridgeCore.strictBool(true))
        #expect(BridgeCore.strictBool(false) == false)
        #expect(BridgeCore.strictBool(NSNumber(value: 1)) == false)
        #expect(BridgeCore.strictBool(NSNumber(value: 1.0)) == false)
        #expect(BridgeCore.strictBool("true") == false)
        #expect(BridgeCore.strictBool(nil) == false)
        #expect(BridgeCore.strictBool(NSNumber(value: true)))
    }
}
