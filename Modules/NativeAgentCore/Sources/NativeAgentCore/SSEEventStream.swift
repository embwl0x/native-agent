// Shared SSE framing; event routing, sentinels and errors belong to callers.
import Foundation
// Blueprint: | `SSEEventStream.swift` | `ProviderRequestLifetime`, `ProviderStreamContext`: explicit SSE activity and trace-only event capture |

/// One request's activity, handed to the guard, transport and parser.
public struct ProviderRequestLifetime: Sendable {
    public var activity: (@Sendable () -> Void)?
    public var admitted: (@Sendable () -> Void)?
    public var stallOnly = false
    public var sending: (@Sendable () -> Void)?
    public var dispatched: (@Sendable () -> Void)?
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
            // A final unterminated line still contributes data.
            if !lineBuf.isEmpty, let event = parser.consume(lineBytes: lineBuf) {
                return event
            }
            // Providers may close before the final blank event delimiter.
            return parser.flush()
        }
    }
}

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
        let line = String(bytes: lineBytes, encoding: .utf8)
        lineBytes.removeAll(keepingCapacity: true)
        guard let line else { invalidLine = true; return nil }
        if line.isEmpty {
            guard !invalidLine else { throw CocoaError(.fileReadInapplicableStringEncoding) }
            bufferedBytes = 0
        }
        return consume(line: line)
    }

    /// Consume one raw line (LF already stripped). Returns a completed event on the blank-line delimiter, nil otherwise. The single trailing-CR strip happens
    /// in `consume(line:)` — not here too, or a payload legitimately ending in CR would lose two.
    public mutating func consume(lineBytes: [UInt8]) -> SSEEvent? {
        consume(line: String(decoding: lineBytes, as: UTF8.self))
    }

    /// Decoded lines exclude their terminator so CR stripping happens exactly once.
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

    /// Dispatch whatever is pending (blank-line delimiter or EOF flush). Per spec an event with no `data:` lines dispatches nothing, but the pending `event:`
    /// name still resets.
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
