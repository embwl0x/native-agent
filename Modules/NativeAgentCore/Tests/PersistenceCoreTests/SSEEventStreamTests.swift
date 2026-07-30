// R15 (2026-07-02): framing tests for the shared SSE decoder. These pin
// the exact edge cases the seven retired hand-rolled parsers disagreed on.
import Foundation
import Testing
@testable import PersistenceCore

@Suite("SSEEventStream framing")
struct SSEEventStreamTests {

    private func decode(_ raw: String) async throws -> [SSEEvent] {
        var events: [SSEEvent] = []
        for try await event in SSEEventStream(Array(raw.utf8).async) {
            events.append(event)
        }
        return events
    }

    // MARK: - Basic framing

    @Test func singleEvent_dataWithSpace() async throws {
        let events = try await decode("data: {\"a\":1}\n\n")
        #expect(events == [SSEEvent(event: nil, data: "{\"a\":1}")])
    }

    @Test func dataWithoutSpace_equivalent() async throws {
        // MCPHTTPTransport tolerated `data:x`; the LLM adapters required
        // `data: x`. The decoder accepts both (spec: strip ONE leading space).
        let events = try await decode("data:{\"a\":1}\n\n")
        #expect(events == [SSEEvent(event: nil, data: "{\"a\":1}")])
    }

    @Test func multipleEvents_inOrder() async throws {
        let events = try await decode("data: one\n\ndata: two\n\ndata: three\n\n")
        #expect(events.map(\.data) == ["one", "two", "three"])
    }

    @Test func multiLineData_joinsWithNewline() async throws {
        let events = try await decode("data: line1\ndata: line2\n\n")
        #expect(events == [SSEEvent(event: nil, data: "line1\nline2")])
    }

    // MARK: - CRLF (audit #14: CR treated as its own terminator split one
    // event's data lines with a phantom blank line)

    @Test func crlfStream_multiLineData_staysOneEvent() async throws {
        let events = try await decode("data: line1\r\ndata: line2\r\n\r\n")
        #expect(events == [SSEEvent(event: nil, data: "line1\nline2")])
    }

    @Test func crlfStream_eventField_associates() async throws {
        let events = try await decode("event: delta\r\ndata: x\r\n\r\n")
        #expect(events == [SSEEvent(event: "delta", data: "x")])
    }

    // MARK: - event: field lifecycle

    @Test func eventName_associatesWithItsData() async throws {
        let events = try await decode("event: message_stop\ndata: {}\n\n")
        #expect(events == [SSEEvent(event: "message_stop", data: "{}")])
    }

    @Test func eventName_resetsBetweenEvents() async throws {
        // A data-only frame after a named one must NOT inherit the stale
        // name (the sticky-currentEvent mis-route audit #15 worried about).
        let events = try await decode("event: a\ndata: 1\n\ndata: 2\n\n")
        #expect(events == [SSEEvent(event: "a", data: "1"), SSEEvent(event: nil, data: "2")])
    }

    @Test func eventNameWithoutData_dispatchesNothing_andResets() async throws {
        let events = try await decode("event: ghost\n\ndata: real\n\n")
        #expect(events == [SSEEvent(event: nil, data: "real")])
    }

    // MARK: - Ignored lines

    @Test func comments_idAndRetry_ignored() async throws {
        let raw = ": keep-alive\nid: 42\nretry: 3000\ndata: payload\n\n"
        let events = try await decode(raw)
        #expect(events == [SSEEvent(event: nil, data: "payload")])
    }

    @Test func blankLinesOnly_noEvents() async throws {
        let events = try await decode("\n\n\n")
        #expect(events.isEmpty)
    }

    @Test func fieldWithNoColon_ignored() async throws {
        let events = try await decode("noise\ndata: ok\n\n")
        #expect(events == [SSEEvent(event: nil, data: "ok")])
    }

    // MARK: - EOF tolerance (deliberate spec deviation shared by all the
    // parsers this replaces: providers/proxies close without a final blank)

    @Test func eofWithoutFinalBlankLine_flushesPendingEvent() async throws {
        let events = try await decode("data: tail")
        #expect(events == [SSEEvent(event: nil, data: "tail")])
    }

    @Test func eofAfterFinalNewline_flushesPendingEvent() async throws {
        let events = try await decode("event: e\ndata: tail\n")
        #expect(events == [SSEEvent(event: "e", data: "tail")])
    }

    @Test func cleanEOFAfterDispatch_noPhantomEvent() async throws {
        let events = try await decode("data: only\n\n")
        #expect(events.count == 1)
    }

    // MARK: - Payload fidelity

    @Test func doneSentinel_passesThroughAsData() async throws {
        // [DONE] is provider semantics, not framing — callers decide.
        let events = try await decode("data: [DONE]\n\n")
        #expect(events == [SSEEvent(event: nil, data: "[DONE]")])
    }

    @Test func emptyDataLine_yieldsEmptyString() async throws {
        // `data:` with nothing after contributes an empty line (spec) —
        // callers already skip empty payloads.
        let events = try await decode("data:\n\n")
        #expect(events == [SSEEvent(event: nil, data: "")])
    }

    @Test func colonInsideValue_preserved() async throws {
        let events = try await decode("data: {\"url\":\"https://x\"}\n\n")
        #expect(events == [SSEEvent(event: nil, data: "{\"url\":\"https://x\"}")])
    }

    @Test func payloadEndingInBareCR_keepsIt_onlyOneCRStripped() async throws {
        // "v\r" + CRLF terminator: exactly ONE trailing CR strips (the
        // line terminator's), the payload's own CR survives (review
        // 2026-07-02 — the byte path briefly stripped two).
        let events = try await decode("data: v\r\r\n\n")
        #expect(events == [SSEEvent(event: nil, data: "v\r")])
    }

    @Test func utf8MultibytePayload_survivesChunking() async throws {
        let payload = "héllo — 世界 🌍"
        let events = try await decode("data: \(payload)\n\n")
        #expect(events == [SSEEvent(event: nil, data: payload)])
    }

    // MARK: - Synchronous buffered parse (parseResponsesSSEDetailed path)

    @Test func syncParse_matchesAsyncSemantics() async throws {
        let raw = "event: a\r\ndata: 1\r\ndata: 2\r\n\r\ndata: [DONE]\r\n\r\n"
        let sync = SSEEventParser.parse(data: Data(raw.utf8))
        let async_ = try await decode(raw)
        #expect(sync == async_)
        #expect(sync == [SSEEvent(event: "a", data: "1\n2"), SSEEvent(event: nil, data: "[DONE]")])
    }

    @Test func syncParse_eofFlush() {
        let events = SSEEventParser.parse(data: Data("data: tail".utf8))
        #expect(events == [SSEEvent(event: nil, data: "tail")])
    }
}

// Minimal async-bytes shim so tests can feed synthetic streams without
// URLSession. `.async` on a byte array yields elements one at a time —
// worst-case chunking, which is exactly what we want to exercise.
private extension Array where Element == UInt8 {
    var async: AsyncStream<UInt8> {
        AsyncStream { continuation in
            for byte in self { continuation.yield(byte) }
            continuation.finish()
        }
    }
}
