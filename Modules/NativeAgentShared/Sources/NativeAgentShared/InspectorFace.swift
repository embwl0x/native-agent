import Foundation
import CryptoKit
// Blueprint: | `InspectorFace.swift` | Inspector membership, redacted cards and pure shared collection/document projection |

public struct InspectorFace: FaceValue {
    public enum Status: String, Sendable, Codable { case reading, ready, failed }
    public var status: Status = .reading
    public var observationActive: Bool?
    public var ids: [String] = []
    public var cards: [String: InspectorTurnCard] = [:]
    public var issue: String?
    public var requestedDate: Date?
    public var loadedDate: Date?
    public var unreadable = 0
    public var hasEvidence: Bool?
    public init() {}
}

public enum InspectorRowStatus: String, Equatable, Sendable, Codable {
    case ok, failed, running, neutral
    public var themeStatus: String {
        switch self {
        case .ok: "ok"
        case .failed: "fail"
        case .running: "warn"
        case .neutral: "info"
        }
    }
}

public struct InspectorEventRow: Identifiable, Equatable, Sendable, Codable {
    public let id: String
    public let kind: String
    public let ts: Date
    public let status: InspectorRowStatus
    public let title: String
    public let durationMs: Int?
    public let isExpandable: Bool
    public let detailLines: [DetailLine]
    /// The engine's name for the call this row is; nil for an event that is no call.
    public let call: String?

    public struct DetailLine: Identifiable, Equatable, Sendable, Codable {
        public var id: String { label }
        public let label: String
        public let value: String
        public init(label: String, value: String) { self.label = label; self.value = value }
    }

    public init(id: String, kind: String, ts: Date, status: InspectorRowStatus, title: String,
                durationMs: Int?, isExpandable: Bool, detailLines: [DetailLine], call: String? = nil) {
        self.id = id; self.kind = kind; self.ts = ts; self.status = status; self.title = title
        self.durationMs = durationMs; self.isExpandable = isExpandable; self.detailLines = detailLines; self.call = call
    }

    public var kindChip: String {
        guard let dot = kind.firstIndex(of: ".") else { return kind }
        return String(kind[kind.index(after: dot)...])
    }
}

public struct InspectorTurnCard: Identifiable, Equatable, Sendable, Codable {
    public let id: String
    public let surface: String?
    public let sessionId: String?
    public let rows: [InspectorEventRow]
    public let startedAt: Date
    public let lastAt: Date
    public let eventCount: Int
    public let wallMs: Int
    public let llmTokens: Int?
    public let ttftMs: Int?

    public init(id: String, surface: String?, sessionId: String?, rows: [InspectorEventRow], startedAt: Date, lastAt: Date,
                eventCount: Int, wallMs: Int, llmTokens: Int?, ttftMs: Int?) {
        self.id = id; self.surface = surface; self.sessionId = sessionId; self.rows = rows
        self.startedAt = startedAt; self.lastAt = lastAt; self.eventCount = eventCount; self.wallMs = wallMs
        self.llmTokens = llmTokens; self.ttftMs = ttftMs
    }
}

extension InspectorTurnCard {
    public var pageRevision: String {
        // A call's end settles the row its begin opened without adding one, so the settled count moves the revision too.
        id + ":" + String(rows.count) + ":" + String(rows.filter { $0.durationMs != nil }.count) + ":"
            + startedAt.formatted(.iso8601) + ":" + lastAt.formatted(.iso8601)
    }

    public var collectionCall: PartFace.Call { .init("inspector.events", ["turn": .string(id)]) }

    /// The held Inspector value supplies every continuation; drawing starts no trace read.
    public func pageFace(cursor: String? = nil, anchor: String? = nil) throws -> PartFace {
        let start: Int
        if let anchor, let offset = rows.firstIndex(where: { $0.id == anchor }) { start = offset }
        else if let cursor {
            guard let offset = Int(cursor), offset >= 0, offset <= rows.count else {
                throw PartCallError(code: "inspector_cursor_invalid", message: "The Inspector event cursor is invalid. Open the turn again.")
            }
            start = offset
        } else { start = 0 }
        let slice = rows.dropFirst(start).prefix(256)
        let (next, overflow) = start.addingReportingOverflow(slice.count)
        guard !overflow else {
            throw PartCallError(code: "inspector_cursor_invalid", message: "The Inspector event position exceeds this window's range.")
        }
        // A row is one line: a timed row shows its duration, an untimed one its time.
        let projected: [PartFace.Row] = slice.map { event in
            .init(id: event.id, title: event.title, detail: event.call ?? event.kindChip,
                  value: event.durationMs.map(Self.duration), at: event.durationMs == nil ? event.ts.formatted(.iso8601) : nil,
                  tone: event.faceTone, expands: event.isExpandable, read: event.isExpandable ? event.detailCall(turn: id) : nil,
                  // A call's bar sits where the call ran within its turn.
                  meter: event.durationMs.map { .init(value: Double($0), max: Double(max(wallMs, 1)),
                                                      start: max(0, event.ts.timeIntervalSince(startedAt) * 1_000)) })
        }
        // The turn's own row leads a reading that starts the turn; a continuation adds only the rows after it.
        return PartFace(sections: [
            .init(id: "turn:" + id, footer: String(id.prefix(8)), rows: cursor == nil ? [turnRow] + projected : projected,
                  more: next < rows.count ? .init(next: String(next), total: rows.count + 1, revision: pageRevision, read: collectionCall) : nil,
                  revision: pageRevision),
        ])
    }

    /// The turn in one line: when it started, its whole time and how many calls it made, led by its slowest call.
    private var turnRow: PartFace.Row {
        let calls = rows.filter { $0.call != nil }
        let slowest = calls.compactMap { call in call.durationMs.map { (title: call.title, ms: $0) } }.max { $0.ms < $1.ms }
        var about = slowest.map { ["Slowest: " + $0.title + " · " + Self.duration($0.ms)] } ?? []
        if let llmTokens { about.append("\(llmTokens) tokens") }
        if let ttftMs { about.append(Self.duration(ttftMs) + " to first token") }
        if let surface { about.append(surface) }
        about.append(eventCount == 1 ? "1 event" : "\(eventCount) events")
        let count = calls.isEmpty ? "no calls" : calls.count == 1 ? "1 call" : "\(calls.count) calls"
        let when = Calendar.current.isDateInToday(startedAt) ? "at " + startedAt.formatted(date: .omitted, time: .shortened)
            : "on " + startedAt.formatted(date: .abbreviated, time: .shortened)
        return .init(id: "turn:" + id, title: "Turn " + when, detail: about.joined(separator: " · "),
                     value: Self.duration(wallMs) + " · " + count)
    }

    /// Under a second in milliseconds, under ten with a tenth, longer as the chat card reads it.
    private static func duration(_ ms: Int) -> String {
        if ms < 1_000 { return "\(ms)ms" }
        if ms < 10_000 { return (Double(ms) / 1_000).formatted(.number.precision(.fractionLength(1))) + "s" }
        return MacChatTurnCardFormat.duration(Double(ms) / 1_000)
    }

    public func readFace(_ request: FaceReadRequest) throws -> PartFace {
        if request.expectedCall == collectionCall {
            if let revision = request.revision, revision != pageRevision {
                throw PartCallError(code: "collection_changed", message: "These Inspector events changed. Read again from the visible event.")
            }
            return try pageFace(cursor: request.cursor, anchor: request.cursor == nil ? request.anchor : nil)
        }
        guard let event = rows.first(where: { request.expectedCall == $0.detailCall(turn: id) }) else {
            throw PartCallError(code: "inspector_event_changed", message: "The selected Inspector event is unavailable in this reading.")
        }
        return PartFace(sections: [
            .init(id: "event:" + event.id, title: event.kindChip, rows: [], block: .init(key: event.documentKey,
                  text: event.detailText.utf8.count <= PartFace.Block.inlineByteLimit ? event.detailText : nil,
                  read: event.documentCall(turn: id), revision: event.documentRevision)),
        ])
    }

    public func readDocument(_ request: FaceReadRequest) throws -> String {
        guard let event = rows.first(where: { $0.documentKey == request.key && $0.documentCall(turn: id) == request.expectedCall }),
              request.revision == event.documentRevision else {
            throw PartCallError(code: "inspector_event_changed", message: "The selected Inspector event changed. Open its details again.")
        }
        return event.detailText
    }
}

private extension InspectorEventRow {
    var faceTone: PartFace.Tone {
        switch status {
        case .ok: .done
        case .failed: .failed
        case .running: .live
        case .neutral: .quiet
        }
    }
    var documentKey: String { "inspector-event:" + id }
    var detailText: String { detailLines.map { $0.label + ":\n" + $0.value }.joined(separator: "\n\n") }
    var documentRevision: String {
        SHA256.hash(data: Data(detailText.utf8)).map { String(format: "%02x", $0) }.joined()
    }
    func detailCall(turn: String) -> PartFace.Call { .init("inspector.event", ["turn": .string(turn), "event": .string(id)]) }
    func documentCall(turn: String) -> PartFace.Call { .init("inspector.event.text", ["turn": .string(turn), "event": .string(id)]) }
}
