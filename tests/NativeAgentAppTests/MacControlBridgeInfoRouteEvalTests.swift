import Testing
@testable import NativeAgentApp

// EVAL FENCE: app.bridges / bridge.macctl.route.info
//
// Executes the exact decision used by the mounted /macctl/info HTTP route.
// A healthy listener produces a concrete discovery receipt; wrong verbs and
// startup/teardown's sentinel port remain adverse responses, never `ok: true`.

@Suite("Mac Control bridge info route")
struct MacControlBridgeInfoRouteEvalTests {
    @Test("GET exposes the supplied bound-listener port")
    func readyInfoRouteReturnsDiscoveryReceipt() {
        let response = MacControlBridge.infoRouteResponse(method: "GET", activePort: 8_770)
        let body = response.responseObject(bundleId: "test.nativeagent")
        #expect(response.state == .ready)
        #expect(response.statusCode == 200)
        #expect(response.ok)
        #expect(body["ok"] as? Bool == true)
        #expect(body["port"] as? Int == 8_770)
        #expect(body["bundleId"] as? String == "test.nativeagent")
        #expect(body["error"] == nil)
    }

    @Test("info refuses non-GET requests after the normal bearer gate")
    func infoRouteRejectsWrongMethod() {
        let post = MacControlBridge.infoRouteResponse(method: "POST", activePort: 8_770)
        #expect(post.state == .methodNotAllowed)
        #expect(post.statusCode == 405)
        #expect(!post.ok)
        #expect(post.responseObject(bundleId: "unused")["error"] as? String == "method_not_allowed")
        #expect(MacControlBridge.infoRouteResponse(method: "get", activePort: 8_770).state
            == .methodNotAllowed)
    }

    @Test("a listener without a bound port reports unavailable rather than success")
    func zeroPortIsNotASuccessfulInfoReceipt() {
        let response = MacControlBridge.infoRouteResponse(method: "GET", activePort: 0)
        let body = response.responseObject(bundleId: "unused")
        #expect(response.state == .unavailable)
        #expect(response.statusCode == 503)
        #expect(!response.ok)
        #expect(body["ok"] as? Bool == false)
        #expect(body["error"] as? String == "bridge_unavailable")
        #expect(body["port"] == nil)
    }
}
