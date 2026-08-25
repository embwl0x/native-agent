import Foundation
import Testing
@testable import NativeAgentApp

@Suite("Mac-control Spotlight frame route")
struct MacControlSpotlightFrameRouteEvalTests {
    @Test("GET serializes the live Spotlight frame with its full geometry")
    func frameResponseUsesProbeGeometry() {
        let response = MacControlSpotlightFrameRoute.response(method: "GET") {
            .frame(-32, 18, 600, 360)
        }

        #expect(response.status == 200)
        #expect(response.error == nil)
        #expect(response.frame == .init(x: -32, y: 18, width: 600, height: 360))
        #expect(response.object["ok"] as? Bool == true)
        #expect(response.object["width"] as? Int == 600)
        #expect(response.object["height"] as? Int == 360)
    }

    @Test("absent and timed-out probes remain distinct adverse HTTP results")
    func adverseProbeResultsAreHonest() {
        let absent = MacControlSpotlightFrameRoute.response(method: "GET") { .absent }
        #expect(absent.status == 404)
        #expect(absent.frame == nil)
        #expect(absent.object["ok"] as? Bool == false)
        #expect(absent.object["error"] as? String == "panel_not_open")

        let timedOut = MacControlSpotlightFrameRoute.response(method: "GET") { .timedOut }
        #expect(timedOut.status == 503)
        #expect(timedOut.frame == nil)
        #expect(timedOut.object["ok"] as? Bool == false)
        #expect(timedOut.object["error"] as? String == "spotlight_probe_timed_out")
    }

    @Test("non-GET routes are rejected before reading the AppKit probe")
    func wrongMethodDoesNotReadSpotlightState() {
        var probeRead = false
        let response = MacControlSpotlightFrameRoute.response(method: "POST") {
            probeRead = true
            return .frame(0, 0, 600, 360)
        }

        #expect(response.status == 405)
        #expect(response.frame == nil)
        #expect(response.object["error"] as? String == "method_not_allowed")
        #expect(!probeRead)
    }
}
