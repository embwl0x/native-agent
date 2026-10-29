// Shared SSE framing; event routing, sentinels and errors belong to callers.
import Foundation
// Blueprint: | `SSEEventStream.swift` | Shared SSE framing and `ProviderStreamContext`; transport opening and activity for every event/comment; optional round-scoped diagnostic event capture before provider decoding |

/// Transport activity is independent of reply content. Bound by the stream
/// guard before creating an adapter, and inherited by its transport task.
public enum ProviderStreamContext {
    @TaskLocal public static var activity: (@Sendable () -> Void)?
    /// The provider admitted the request: a validated 2xx body is being read.
    @TaskLocal public static var admitted: (@Sendable () -> Void)?
    @TaskLocal public static var stallOnly: Bool = false
    /// The HTTP request went out and its response head is awaited.
    @TaskLocal public static var sending: (@Sendable () -> Void)?
    @TaskLocal public static var diagnosticEvent: (@Sendable (SSEEvent) -> Void)?
    /// The transport validated the route, chose the adapter and is sending.
    @TaskLocal public static var dispatched: (@Sendable () -> Void)?
}

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
///   streams both work).
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

    /// Providers read only a status-validated 2xx body as SSE, so starting to
    /// read one is the provider's admission of the request.
    public func makeAsyncIterator() -> AsyncIterator {
        ProviderStreamContext.admitted?()
        return AsyncIterator(bytes: bytes.makeAsyncIterator())
    }

    public struct AsyncIterator: AsyncIteratorProtocol {
        var bytes: Bytes.AsyncIterator
        var parser = SSEEventParser(onActivity: ProviderStreamContext.activity)
        var finished = false
        var lineBuf: [UInt8] = []

        public mutating func next() async throws -> SSEEvent? {
            guard !finished else { return nil }
            while let byte = try await bytes.next() {
                guard byte == 0x0A else {
                    lineBuf.append(byte)
                    continue
                }
                let event = parser.consume(lineBytes: lineBuf)
                lineBuf.removeAll(keepingCapacity: true)
                if let event { return event }
            }
            finished = true
            defer { lineBuf = [] }
            // EOF: a final line without a trailing LF still counts…
            if !lineBuf.isEmpty, let event = parser.consume(lineBytes: lineBuf) {
                return event
            }
            // …and a pending event without a final blank line still flushes.
            return parser.flush()
        }
    }
}

/// Shared SSE state machine; a blank line completes an event.
public struct SSEEventParser: Sendable {
    private var dataLines: [String] = []
    private var eventName: String?
    private let onActivity: (@Sendable () -> Void)?
    private var lineBytes: [UInt8] = []
    private var afterCR = false
    private var bufferedBytes = 0
    private var invalidLine = false

    public init(onActivity: (@Sendable () -> Void)? = nil) {
        self.onActivity = onActivity
    }

    /// Strict bounded byte framing for peers: CR, LF and CRLF end lines;
    /// incomplete lines/events remain pending until a blank line, never EOF.
    public mutating func consume(byte: UInt8, maximumBytes: Int) throws -> SSEEvent? {
        if afterCR, byte == 0x0A {
            afterCR = false
            if bufferedBytes > 0 { bufferedBytes += 1 }
            guard bufferedBytes <= maximumBytes else { throw CocoaError(.fileReadTooLarge) }
            return nil
        }
        afterCR = false
        guard bufferedBytes < maximumBytes else { throw CocoaError(.fileReadTooLarge) }
        bufferedBytes += 1
        guard byte == 0x0A || byte == 0x0D else { lineBytes.append(byte); return nil }
        afterCR = byte == 0x0D
        let line = String(bytes: lineBytes, encoding: .utf8)
        lineBytes.removeAll(keepingCapacity: true)
        guard let line else { invalidLine = true; return nil }
        if line.isEmpty {
            guard !invalidLine else { throw CocoaError(.fileReadInapplicableStringEncoding) }
            bufferedBytes = 0
        }
        return consume(line: line)
    }

    /// Consume one raw line (LF already stripped). Returns a completed
    /// event on the blank-line delimiter, nil otherwise. The single
    /// trailing-CR strip happens in `consume(line:)` — not here too, or a
    /// payload legitimately ending in CR would lose two.
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
        if line.hasPrefix(":") {
            onActivity?() // real provider keep-alive, never reply content
            return nil
        }

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
        if !dataLines.isEmpty || eventName != nil { onActivity?() }
        guard !dataLines.isEmpty else { return nil }
        let event = SSEEvent(event: eventName, data: dataLines.joined(separator: "\n"))
        ProviderStreamContext.diagnosticEvent?(event)
        return event
    }
}
