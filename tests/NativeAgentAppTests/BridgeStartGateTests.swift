import Foundation
import Testing
@testable import NativeAgentApp

// A1.2 / A1.3 (prerelease-upgrade-campaign): both localhost bridges used to
// bind a port and mint a bearer token unconditionally at launch. On a public
// install that handed any same-user process a full LLM-turn + tool-dispatch
// channel (ClaudeBridge, 8771) and a Mac-control channel (MacControlBridge,
// 8770) with no user-visible purpose.
//
// These pin the PURE decision seam of each gate — same semantics the file-
// reading entry point delegates to — so the gate can be asserted without
// mutating the process environment or the resolved data root.
@Suite("Bridge start gates")
struct BridgeStartGateTests {

    // MARK: - ClaudeBridge (developerMode || NATIVEAGENT_BRIDGE_FORCE=1)

    @Test("ClaudeBridge starts when developerMode is true")
    func claudeAllowsUnderDeveloperMode() {
        #expect(ClaudeBridge.startGateAllows(
            policyJSON: ["developerMode": true],
            forceEnvValue: nil
        ))
    }

    @Test("ClaudeBridge stays down when developerMode is false or absent")
    func claudeDeniesWithoutDeveloperMode() {
        #expect(ClaudeBridge.startGateAllows(
            policyJSON: ["developerMode": false],
            forceEnvValue: nil
        ) == false)
        // Absent key — the shape of a real public-install policy.json.
        #expect(ClaudeBridge.startGateAllows(
            policyJSON: ["permissionLevel": "balanced"],
            forceEnvValue: nil
        ) == false)
        // Missing / unparseable policy file must fail CLOSED, not open.
        #expect(ClaudeBridge.startGateAllows(
            policyJSON: nil,
            forceEnvValue: nil
        ) == false)
        // A non-Bool truthy value must not satisfy the gate.
        #expect(ClaudeBridge.startGateAllows(
            policyJSON: ["developerMode": "true"],
            forceEnvValue: nil
        ) == false)
    }

    @Test("NATIVEAGENT_BRIDGE_FORCE=1 overrides a developerMode-off policy")
    func claudeEnvForceOverrides() {
        #expect(ClaudeBridge.startGateAllows(
            policyJSON: ["developerMode": false],
            forceEnvValue: "1"
        ))
        #expect(ClaudeBridge.startGateAllows(
            policyJSON: nil,
            forceEnvValue: "1"
        ))
    }

    @Test("only the exact value \"1\" forces the bridge on")
    func claudeEnvForceIsExactMatch() {
        for value in ["0", "", "true", "yes", "2", " 1"] {
            #expect(ClaudeBridge.startGateAllows(
                policyJSON: ["developerMode": false],
                forceEnvValue: value
            ) == false, "env value \(value.debugDescription) must not open the gate")
        }
    }

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

    // MARK: - Numeric truthiness must NOT open either gate
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

    @Test("numeric 1 does not open the Claude bridge gate")
    func claudeDeniesNumericTruthy() {
        #expect(ClaudeBridge.startGateAllows(
            policyJSON: parsed(#"{"developerMode": 1}"#),
            forceEnvValue: nil
        ) == false)
        #expect(ClaudeBridge.startGateAllows(
            policyJSON: parsed(#"{"developerMode": 0}"#),
            forceEnvValue: nil
        ) == false)
        // Real JSON `true` still opens it — the strict read didn't break the
        // only shape that should work.
        #expect(ClaudeBridge.startGateAllows(
            policyJSON: parsed(#"{"developerMode": true}"#),
            forceEnvValue: nil
        ))
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
