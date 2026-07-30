// R15 (2026-07-02): ONE SSE framing decoder for the whole app. Replaces
// seven hand-rolled `data:`-line parsers (six LLM streaming adapters +
// MCPHTTPTransport) that had three different line-splitting strategies.
// This layer does FRAMING ONLY — event-type routing, `[DONE]` sentinels,
// telemetry, and error mapping are protocol semantics and stay in callers.
import Foundation

/// One parsed Server-Sent Event.
public struct SSEEvent: Sendable, Equatable {
    /// The last `event:` field seen for this event, or nil if the event
    /// had none. Resets between events — a data-only frame following a
    /// named one does NOT inherit the previous name.
    public let event: String?
    /// The `data:` payload; multiple `data:` lines join with "\n" per spec.
    public let data: String

    public init(event: String?, data: String) {
        self.event = event
        self.data = data
    }
}

/// WHATWG-SSE framing over any byte stream (`URLSession.AsyncBytes` in
/// production, synthetic arrays in tests).
///
/// Framing rules:
/// - Lines terminate on LF; one trailing CR is stripped (LF and CRLF
///   streams both work — treating CR as its own terminator is the
///   audit-#14 bug: it splits one CRLF event's `data:` lines with a
///   phantom blank line).
/// - Lines starting `:` are comments (keep-alives) — skipped.
/// - A field splits at the first `:`; one leading space is stripped from
///   the value, so `data:x` and `data: x` are equivalent.
/// - `event:` names the current event; `data:` accumulates; `id:`,
///   `retry:`, and unknown fields are ignored.
/// - A blank line dispatches the accumulated event. No `data:` lines →
///   nothing dispatches (and any pending `event:` name resets).
/// - Deliberate spec deviation: a non-empty event still pending at EOF is
///   dispatched. Real providers/proxies sometimes close without a final
///   blank line, and every parser this replaces tolerated that.
public struct SSEEventStream<Bytes: AsyncSequence & Sendable>: AsyncSequence, Sendable
where Bytes.Element == UInt8 {
    public typealias Element = SSEEvent

    private let bytes: Bytes

    public init(_ bytes: Bytes) {
        self.bytes = bytes
    }

    public func makeAsyncIterator() -> AsyncIterator {
        AsyncIterator(bytes: bytes.makeAsyncIterator())
    }

    public struct AsyncIterator: AsyncIteratorProtocol {
        var bytes: Bytes.AsyncIterator
        var parser = SSEEventParser()
        var finished = false

        public mutating func next() async throws -> SSEEvent? {
            guard !finished else { return nil }
            var lineBuf: [UInt8] = []
            while let byte = try await bytes.next() {
                guard byte == 0x0A else {
                    lineBuf.append(byte)
                    continue
                }
                if let event = parser.consume(lineBytes: lineBuf) {
                    return event
                }
                lineBuf.removeAll(keepingCapacity: true)
            }
            finished = true
            // EOF: a final line without a trailing LF still counts…
            if !lineBuf.isEmpty, let event = parser.consume(lineBytes: lineBuf) {
                return event
            }
            // …and a pending event without a final blank line still flushes.
            return parser.flush()
        }
    }
}

/// The line-level SSE state machine shared by the async stream above and
/// the synchronous buffered parse below. Feed it lines (without their LF);
/// it returns an `SSEEvent` whenever a blank line completes one.
public struct SSEEventParser: Sendable {
    private var dataLines: [String] = []
    private var eventName: String?

    public init() {}

    /// Consume one raw line (LF already stripped). Returns a completed
    /// event on the blank-line delimiter, nil otherwise. The single
    /// trailing-CR strip happens in `consume(line:)` — not here too, or a
    /// payload legitimately ending in CR would lose two (review 2026-07-02).
    public mutating func consume(lineBytes: [UInt8]) -> SSEEvent? {
        consume(line: String(decoding: lineBytes, as: UTF8.self))
    }

    /// Same as `consume(lineBytes:)` for already-decoded lines. The line
    /// must not contain its terminator; a trailing CR is stripped.
    public mutating func consume(line rawLine: String) -> SSEEvent? {
        var line = rawLine
        if line.hasSuffix("\r") { line.removeLast() }

        if line.isEmpty {
            return flush()
        }
        if line.hasPrefix(":") { return nil } // comment / keep-alive

        let name: Substring
        var value: Substring
        if let colon = line.firstIndex(of: ":") {
            name = line[..<colon]
            value = line[line.index(after: colon)...]
            if value.hasPrefix(" ") { value = value.dropFirst() }
        } else {
            // Field with no colon: the whole line is the name, empty value.
            name = line[...]
            value = ""
        }

        switch name {
        case "data":
            dataLines.append(String(value))
        case "event":
            eventName = String(value)
        default:
            break // id:, retry:, unknown fields — ignored
        }
        return nil
    }

    /// Dispatch whatever is pending (blank-line delimiter or EOF flush).
    /// Per spec an event with no `data:` lines dispatches nothing, but the
    /// pending `event:` name still resets.
    public mutating func flush() -> SSEEvent? {
        defer {
            dataLines.removeAll(keepingCapacity: true)
            eventName = nil
        }
        guard !dataLines.isEmpty else { return nil }
        return SSEEvent(event: eventName, data: dataLines.joined(separator: "\n"))
    }
}

extension SSEEventParser {
    /// Synchronously parse a complete SSE body (a non-streamed response
    /// that arrived as `text/event-stream`). Same state machine as the
    /// async path, including the EOF flush.
    public static func parse(data: Data) -> [SSEEvent] {
        var parser = SSEEventParser()
        var events: [SSEEvent] = []
        var lineBuf: [UInt8] = []
        for byte in data {
            guard byte == 0x0A else {
                lineBuf.append(byte)
                continue
            }
            if let event = parser.consume(lineBytes: lineBuf) {
                events.append(event)
            }
            lineBuf.removeAll(keepingCapacity: true)
        }
        if !lineBuf.isEmpty, let event = parser.consume(lineBytes: lineBuf) {
            events.append(event)
        }
        if let event = parser.flush() {
            events.append(event)
        }
        return events
    }
}
