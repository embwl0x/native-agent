import Foundation
import Testing
import PersistenceCore
import ChatOrchestration
@testable import NativeAgentApp

// EVAL FENCE: app.bridges / bridge.claude.route.events

@Suite("Claude events route", .serialized)
struct ClaudeBridgeEventsRouteEvalTests {
    @Test("ordinary and enqueued chat notices are bounded, redacted and precede terminal events")
    func chatNoticesPrecedeTerminalEvents() async throws {
        for enqueued in [false, true] {
            let bridge = ClaudeBridge()
            let requestID = UUID().uuidString
            let sink = bridge.chatNoticeSink(
                requestID: requestID, sessionID: enqueued ? "session" : nil,
                runID: enqueued ? "run" : nil
            )
            if enqueued {
                bridge.publishEvent(kind: "message_enqueued", payload: ["requestId": requestID])
            }
            await sink(.delta("private assistant text"))
            await sink(.toolUse(name: "private tool", input: .string("private input")))
            await sink(.notice(kind: "empty", text: " \n "))
            let secret = "sk-" + String(repeating: "x", count: 40)
            await sink(.notice(kind: "provider_recovery", text: "Reconnecting \(secret)"))
            await sink(.notice(kind: secret + String(repeating: "!", count: 100),
                               text: String(repeating: "a", count: 990) + " " + secret))
            bridge.publishEvent(kind: "message_out", payload: [
                "requestId": requestID, "sessionId": "session", "runId": "run",
            ])
            let events = bridge.recentEventPayloads()
            #expect(events.compactMap { $0["kind"] as? String } ==
                    (enqueued ? ["message_enqueued", "message_notice", "message_notice", "message_out"] :
                        ["message_notice", "message_notice", "message_out"]))
            for event in events where event["kind"] as? String == "message_notice" {
                #expect(event["requestId"] as? String == requestID)
                if enqueued {
                    #expect(event["sessionId"] as? String == "session")
                    #expect(event["runId"] as? String == "run")
                } else {
                    #expect(event["sessionId"] is NSNull)
                    #expect(event["runId"] is NSNull)
                }
                let text = try #require(event["text"] as? String)
                let kind = try #require(event["noticeKind"] as? String)
                #expect(text.count <= 1_000 && kind.count <= 80)
                #expect(!text.contains("sk-") && !kind.contains("sk-"))
                #expect(JSONSerialization.isValidJSONObject(event))
            }
        }
    }

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
