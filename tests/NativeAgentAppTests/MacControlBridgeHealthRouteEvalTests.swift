import Testing
@testable import NativeAgentApp

// EVAL FENCE: app.bridges / bridge.macctl.route.health
@Suite("Mac Control bridge health route")
struct MacControlBridgeHealthRouteEvalTests {
    @Test("health is ready only with policy authority and free execution capacity")
    func healthRejectsDisabledAndSaturatedBridge() {
        let disabled = MacControlBridge.healthRouteResponse(
            method: "GET",
            startGateAllowed: false,
            execSlotLimit: 2,
            activeExecSlots: 0
        )
        #expect(disabled.statusCode == 503)
        #expect(!disabled.ok)
        #expect(disabled.state == .policyDisabled)

        let available = MacControlBridge.healthRouteResponse(
            method: "GET",
            startGateAllowed: true,
            execSlotLimit: 2,
            activeExecSlots: 1
        )
        #expect(available.statusCode == 200)
        #expect(available.ok)
        #expect(available.freeExecSlots == 1)

        let saturated = MacControlBridge.healthRouteResponse(
            method: "GET",
            startGateAllowed: true,
            execSlotLimit: 2,
            activeExecSlots: 2
        )
        #expect(saturated.statusCode == 503)
        #expect(!saturated.ok)
        #expect(saturated.state == .execSaturated)
        #expect(saturated.freeExecSlots == 0)

        let wrongMethod = MacControlBridge.healthRouteResponse(
            method: "POST",
            startGateAllowed: true,
            execSlotLimit: 2,
            activeExecSlots: 0
        )
        #expect(wrongMethod.statusCode == 405)
        #expect(wrongMethod.state == .methodNotAllowed)
    }

    @Test("the route body reports the production exec counter snapshot")
    func responseBodyMatchesTheLiveExecCounter() throws {
        let response = MacControlBridge.healthRouteResponse(method: "GET", startGateAllowed: true)
        let body = response.responseObject(bundleId: "test.nativeagent")
        let slots = try #require(body["execSlots"] as? [String: Int])

        #expect(body["ok"] as? Bool == response.ok)
        #expect(body["state"] as? String == response.state.rawValue)
        #expect(slots["limit"] == MacControlBridge.execSlots.limit)
        #expect(slots["active"] == response.activeExecSlots)
        #expect(slots["active"] == MacControlBridge.execSlots.activeCount)
        #expect(slots["free"] == response.freeExecSlots)
        #expect(response.freeExecSlots == max(0, MacControlBridge.execSlots.limit - response.activeExecSlots))
    }
}
