import Foundation
import Testing
import PersistenceCore
@testable import NativeAgentApp

// EVAL FENCE: app.bridges / bridge.claude.route.events

@Suite("Claude events route", .serialized)
struct ClaudeBridgeEventsRouteEvalTests {
    @Test("returned tool envelopes retain exact outcomes in the shared event ring")
    func returnedToolEnvelopesAreNotUnconditionallySuccessful() throws {
        let cases: [(JSONValue, String, Bool?)] = [
            (.object(["status": .string("failed"), "reason": .string("missing_session_id")]), "failed", false),
            (.object(["ok": .bool(false), "error": .null]), "failed", false),
            (.object(["ok": .bool(true), "error": .null]), "succeeded", true),
            (.object(["status": .string("queued"), "ok": .bool(true)]), "unknown", nil),
            (.object(["status": .string("pending_approval")]), "unknown", nil),
            (.object(["status": .string("cancelled")]), "cancelled", false),
            (.object(["status": .string("timeout")]), "timeout", false),
            (.string("terminal text"), "succeeded", true),
            (.object(["unclassified": .string("private payload")]), "unknown", nil),
        ]
        let bridge = ClaudeBridge()
        for (result, outcome, ok) in cases {
            bridge.publishToolResultEvent(name: "fixture", surface: "codex-bridge", result: result, durationMs: 7)
            let event = try #require(bridge.recentEventPayloads().last)
            #expect(event["kind"] as? String == "tool")
            #expect(event["resultClass"] as? String == outcome)
            #expect(event["dispatchCompleted"] as? Bool == true)
            if let ok { #expect(event["ok"] as? Bool == ok) }
            else { #expect(event["ok"] is NSNull) }
            #expect(event["durationMs"] as? Int == 7)
            #expect(event["result"] == nil)
            #expect(event["reason"] == nil)
            #expect(JSONSerialization.isValidJSONObject(event))
        }
    }

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
