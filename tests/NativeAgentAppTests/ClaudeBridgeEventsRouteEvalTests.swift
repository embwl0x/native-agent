import Foundation
import Testing
@testable import NativeAgentApp

// EVAL FENCE: app.bridges / bridge.claude.route.events

@Suite("Claude events route", .serialized)
struct ClaudeBridgeEventsRouteEvalTests {
    @Test("published route events use one framed payload and do not retain disconnected subscribers")
    func eventFramesCarrySequenceAndRouteStateStartsLeakFree() throws {
        let bridge = ClaudeBridge()
        let initial = bridge.eventRouteSnapshot()
        #expect(initial.connectionCount == 0)
        #expect(initial.subscriberCount == 0)

        bridge.publishEvent(kind: "tool", payload: ["tool": "time_now", "ok": true])
        let published = bridge.eventRouteSnapshot()
        #expect(published.latestSequence == 1)
        #expect(published.subscriberCount == 0)

        let event = ClaudeBridge.BridgeEvent(
            seq: published.latestSequence,
            timestamp: Date(timeIntervalSince1970: 1_700_000_000),
            kind: "tool",
            payload: ["tool": "time_now", "ok": true]
        )
        let frame = try #require(String(data: ClaudeBridge.eventStreamFrame(for: event), encoding: .utf8))
        #expect(frame.hasPrefix("data: {"))
        #expect(frame.hasSuffix("\n\n"))
        let json = try #require(frame.dropFirst("data: ".count).dropLast(2).data(using: .utf8))
        let payload = try #require(try JSONSerialization.jsonObject(with: json) as? [String: Any])
        #expect(payload["seq"] as? UInt64 == 1)
        #expect(payload["kind"] as? String == "tool")
        #expect(payload["tool"] as? String == "time_now")
        #expect(payload["ok"] as? Bool == true)
    }
}
