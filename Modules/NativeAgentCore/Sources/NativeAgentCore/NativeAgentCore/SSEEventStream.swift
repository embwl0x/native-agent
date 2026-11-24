// Shared SSE framing; event routing, sentinels and errors belong to callers.
import Foundation
// Blueprint: | `SSEEventStream.swift` | `ProviderRequestLifetime`, `ProviderStreamContext`: explicit SSE activity and trace-only event capture |

/// One request's activity, handed to the guard, transport and parser.
public struct ProviderRequestLifetime: Sendable {
    public var activity: (@Sendable () -> Void)?
    public var admitted: (@Sendable () -> Void)?
    public var sending: (@Sendable () -> Void)?
    public var dispatched: (@Sendable () -> Void)?
    /// Request-owned wait/reconnect descriptions delivered to the turn's progress sink.
    public var status: (@Sendable (_ kind: String, _ text: String) async -> Void)?
    /// Headers supply server pacing before body decoding can fail.
    public var response: (@Sendable (URLResponse) -> Void)?
    public init() {}
}

/// Raw event capture is trace-only; no routing or decision reads it.
public enum ProviderStreamContext {
    @TaskLocal public static var diagnosticEvent: (@Sendable (SSEEvent) -> Void)?
}

public struct SSEEvent: Sendable, Equatable {
    /// The last `event:` field seen for this event, or nil if the event had none. Resets between events — a data-only frame following a named one does NOT
    /// inherit the previous name.
    public let event: String?
    /// The `data:` payload; multiple `data:` lines join with "\n" per spec.
    public let data: String

    public init(event: String?, data: String) {
        self.event = event
        self.data = data
    }
}

/// Follow WHATWG SSE framing: LF or CRLF lines, colon comments, one optional space after the field colon, event names reset between frames and data lines join
/// with newlines. Ignore id, retry and unknown fields. Dispatch only events with data. Flush a pending provider event at EOF because providers and proxies can
/// close without a final blank line.
public struct SSEEventStream<Bytes: AsyncSequence & Sendable>: AsyncSequence, Sendable
where Bytes.Element == UInt8 {
    public typealias Element = SSEEvent

    private let bytes: Bytes
    private let lifetime: ProviderRequestLifetime

    public init(_ bytes: Bytes, lifetime: ProviderRequestLifetime) {
        self.bytes = bytes
        self.lifetime = lifetime
    }

    /// Providers read only a status-validated 2xx body as SSE, so starting to read one is the provider's admission of the request.
    public func makeAsyncIterator() -> AsyncIterator {
        lifetime.admitted?()
        return AsyncIterator(bytes: bytes.makeAsyncIterator(), parser: SSEEventParser(onActivity: lifetime.activity))
    }

    public struct AsyncIterator: AsyncIteratorProtocol {
        var bytes: Bytes.AsyncIterator
        var parser: SSEEventParser
        var finished = false
        var lineBuf: [UInt8] = []

        public mutating func next() async throws -> SSEEvent? {
            guard !finished else { return nil }
            while let byte = try await bytes.next(isolation: #isolation) {
                guard byte == 0x0A else {
                    lineBuf.append(byte)
                    continue
                }
                let event = parser.consume(lineBuf.span)
                lineBuf.removeAll(keepingCapacity: true)
                if let event { return event }
            }
            finished = true
            defer { lineBuf = [] }
            // A final unterminated line still contributes data.
            if !lineBuf.isEmpty, let event = parser.consume(lineBuf.span) {
                return event
            }
            // Providers may close before the final blank event delimiter.
            return parser.flush()
        }
    }
}

public struct SSEEventParser: Sendable {
    private var payload: [UInt8] = []
    private var hasData = false
    private var eventName: String?
    private let onActivity: (@Sendable () -> Void)?
    private var lineBytes: [UInt8] = []
    private var afterCR = false
    private var bufferedBytes = 0
    private var invalidLine = false

    public init(onActivity: (@Sendable () -> Void)? = nil) {
        self.onActivity = onActivity
    }

    /// Strict bounded byte framing for peers: CR, LF and CRLF end lines; incomplete lines/events remain pending until a blank line, never EOF.
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
        defer { lineBytes.removeAll(keepingCapacity: true) }
        do {
            _ = try UTF8Span(validating: lineBytes.span)
        } catch {
            invalidLine = true
            return nil
        }
        if lineBytes.isEmpty {
            guard !invalidLine else { throw CocoaError(.fileReadInapplicableStringEncoding) }
            bufferedBytes = 0
        }
        let line = lineBytes
        return consume(line.span)
    }

    fileprivate mutating func consume(_ line: Span<UInt8>) -> SSEEvent? {
        let end = line.count > 0 && line[line.count - 1] == 13 ? line.count - 1 : line.count
        guard end > 0 else { return flush() }
        if line[0] == 58 {
            onActivity?()
            return nil
        }
        var colon = 0
        while colon < end, line[colon] != 58 { colon += 1 }
        var start = min(colon + 1, end)
        if start < end, line[start] == 32 { start += 1 }
        let value = line.extracting(start..<end)
        let field = line.extracting(0..<colon)
        if field.withUnsafeBufferPointer({ unsafe $0.elementsEqual("data".utf8) }) {
            if hasData { payload.append(10) }
            hasData = true
            value.withUnsafeBufferPointer { unsafe payload.append(contentsOf: $0) }
        } else if field.withUnsafeBufferPointer({ unsafe $0.elementsEqual("event".utf8) }) {
            eventName = value.withUnsafeBufferPointer { unsafe String(decoding: $0, as: UTF8.self) }
        }
        return nil
    }

    /// Dispatch whatever is pending (blank-line delimiter or EOF flush). Per spec an event with no `data:` lines dispatches nothing, but the pending `event:`
    /// name still resets.
    public mutating func flush() -> SSEEvent? {
        defer {
            payload.removeAll(keepingCapacity: true)
            hasData = false
            eventName = nil
        }
        if hasData || eventName != nil { onActivity?() }
        guard hasData else { return nil }
        let event = SSEEvent(event: eventName, data: String(decoding: payload, as: UTF8.self))
        ProviderStreamContext.diagnosticEvent?(event)
        return event
    }
}
