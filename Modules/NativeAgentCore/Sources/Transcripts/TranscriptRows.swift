import Foundation
import NativeAgentShared
import Darwin
import NativeAgentCore
import PersistenceCore
// Blueprint: | `TranscriptRows.swift` | `ContactThread` uses PersistenceCore's canonical JSONL serialization and owns durable append and exact-byte row edits/replacement for chat, compaction and archive restoration; writes share the owner lock and compound caller lock boundaries; session-index mutate provides checked read/edit/commit. `read` shares tail/incremental byte reads; `Line` retains each row's stamp, words, speaker and answers-id; `project` is the shared presentation; displayed contact speech alone calls `consume`; `DelegatedReplyEnvelope` shares reply/header syntax for search and presentation under caller-owned provenance admission |

/// The shared storage and reading of conversations. Routing extends this owner;
/// presentation never derives a speaker from the session that holds a row.
public enum ContactThread {
    // Transcript JSONL is locally/off-disk backed up and inventoried under chat.
    // Production export excludes it; ChatExport writes Markdown and
    // DeviceSync publishes bounded person-visible rows.

    public static func append(_ row: JSONValue, to path: URL,
                              uniqueRunID: String? = nil) async throws {
        try await SwiftNativePersistenceCore.withFileLock(path) {
            if let uniqueRunID {
                let rows = try await SwiftNativePersistenceCore.readJSONL(path)
                guard !rows.contains(where: {
                    if case .object(let existing) = $0 { return existing["runId"] == .string(uniqueRunID) }
                    return false
                }) else { return }
            }
            try await SwiftNativePersistenceCore.appendJSONLDurable(row, to: path)
        }
    }

    public static func replace(_ bytes: Data, to path: URL) throws {
        try CredentialFileLock.withLock(path) {
            try SwiftNativePersistenceCore.writeDataAtomicDurable(bytes, to: path)
            _ = chmod(path.path, 0o600)
        }
    }

    /// Edit one admitted row; every other byte, including blank lines and
    /// final-newline state, belongs to the original transcript.
    public static func editingRow(in bytes: Data, last: Bool = false,
                                  matching: ([String: JSONValue]) -> Bool,
                                  replacement: ([String: JSONValue]) throws -> [JSONValue]) throws -> Data? {
        var lines = bytes.split(separator: 10, omittingEmptySubsequences: false).map { Data($0) }
        let indices = last ? Array(lines.indices.reversed()) : Array(lines.indices)
        for index in indices {
            guard case .object(let row)? = try? JSONValue.parse(lines[index]), matching(row) else { continue }
            lines[index] = Data(try replacement(row).map { try $0.serialize(pretty: false) }.joined(separator: "\n").utf8)
            var edited = Data()
            for i in lines.indices {
                if i > 0 { edited.append(10) }
                edited.append(lines[i])
            }
            return edited
        }
        return nil
    }

    @discardableResult
    public static func replace(_ rows: [JSONValue], to path: URL) throws -> Data {
        let bytes = try SwiftNativePersistenceCore.serializeJSONL(rows)
        try replace(bytes, to: path)
        return bytes
    }

    public struct Line: Sendable, Equatable {
        public var id: String
        public var role: String
        public var text: String
        public var timestamp: String?
        public var date: Date?
        public var at: Date { date ?? .distantPast }
        public var run: String?
        public let stamp: TranscriptRowStamp
        public var byPerson: Bool
        public var door: String?
        public var fetched = false
        public var answers: String?
        public var sendID: String?
        public var sendState: String?
        public var metadata: [String: JSONValue] = [:]
        public var speaker = ""
        public var mine: Bool { role == "assistant" || stamp.source == "self" }
        public var contact: Bool { stamp.contact && !mine }
        public var source: String? { contact ? stamp.source : nil }
        public var steeredBy: [String] { stamp.steeredBy }
        public var speakers: [String] { contact ? [source ?? "another agent"] : [] }
        public var human: Bool {
            role == "user" && metadata["mechanicalKind"] == nil && !mine && !contact
                && Self.object(metadata["origin"])["authored"] != .string("agent")
        }

        /// Cached previews keep the writer's stamp beside the words they quote.
        public init(text: String, stamp: TranscriptRowStamp, id: String = "", role: String = "user") {
            self.id = id; self.role = role; self.text = text; self.stamp = stamp
            self.byPerson = false
        }

        public init(_ row: [String: JSONValue], role: String? = nil, text: String? = nil, timestamp: String? = nil, metadata: [String: JSONValue]? = nil) {
            let role = role ?? row["role"]?.stringValue ?? ""
            let metadata = metadata ?? Self.object(row["metadata"])
            let id = row["id"]?.stringValue ?? ""
            self.init(text: text ?? (row["content"] ?? row["text"])?.stringValue ?? "",
                      stamp: TranscriptRowStamp(json: row["stamp"])
                        ?? .of(id: id, role: role, metadata: metadata, rowSource: row["source"]?.stringValue), id: id, role: role)
            self.metadata = metadata
            self.timestamp = timestamp ?? (row["createdAt"] ?? row["timestamp"])?.stringValue
            self.date = self.timestamp.flatMap(NativeTimestampFormat.parseISO8601FractionalFirst)
            self.run = row["runId"]?.stringValue
            self.byPerson = metadata["byPerson"] == .bool(true)
            self.answers = role == "user" ? Self.object(metadata["origin"])["replyTo"]?.stringValue.flatMap {
                $0.hasPrefix("agent-conversation:") ? String($0.dropFirst("agent-conversation:".count)) : nil
            } : nil
            self.sendID = role == "assistant" ? metadata["dotClientUserMessageID"]?.stringValue : nil
            self.sendState = metadata["sendState"]?.stringValue
        }

        public init?(jsonl data: Data) {
            guard case .object(let row)? = try? JSONValue.parse(data),
                  case .string? = row["content"] ?? row["text"] else { return nil }
            self.init(row)
        }

        fileprivate static func object(_ value: JSONValue?) -> [String: JSONValue] {
            if case .object(let fields)? = value { return fields }
            if case .string(let text)? = value, let parsed = try? JSONValue.parse(Data(text.utf8)) { return object(parsed) }
            return [:]
        }
    }

    public enum TextStyle { case verbatim, log, thread }

    /// The byte read shared by tail and incremental adapters; each owns its row boundaries and selection.
    public static func read(_ handle: FileHandle, from offset: UInt64, bytes: Int? = nil) -> Data? {
        try? handle.seek(toOffset: offset)
        if let bytes { return try? handle.read(upToCount: bytes) }
        return try? handle.readToEnd()
    }

    /// One stamped-row projection for sessions, contact threads and retained
    /// previews. A cache/index read omits `mark`; only the selected display
    /// supplies it, so each displayed contact line is consumed exactly once.
    public static func project(_ rows: some Sequence<Line>, style: TextStyle = .verbatim, thread owner: String? = nil,
                               person: String = "the person", own: String = "you", names: [String: String] = [:],
                               contactPrefix: String = "", unlistedPeer: String? = nil, unattested: String? = nil,
                               answering: String? = nil, fallback: Line? = nil,
                               mark: ((_ principal: String, _ words: String) -> Void)? = nil) -> [Line] {
        var started: Set<String> = [], seen: Set<String> = []
        var lines = rows.filter { row in
            guard let owner else { return true }
            guard !seen.contains(row.id) else { return false }
            let origin = Line.object(row.metadata["origin"]), envelope = Line.object(row.metadata["envelope"])
            if row.role == "user" {
                let peers: [JSONValue] = if case .array(let peers)? = origin["peerSources"] { peers } else { [] }
                guard envelope["surface"] == .string("agent-bridge") || origin["agent"] == .string(owner)
                    || peers.contains(.string("peer:" + owner)) else { return false }
                seen.insert(row.id)
                let handed = row.answers != nil || {
                    if case .string(let id)? = envelope["correlationId"] { return id.hasPrefix("dot-room:") }; return false
                }()
                if !handed, let run = row.run { started.insert(run) }
                return true
            }
            guard row.mine && (row.sendID != nil || row.run != nil) else { return false }
            seen.insert(row.id)
            return true
        }
        if owner != nil { lines = lines.filter { !$0.mine || $0.sendID != nil || ($0.run.map(started.contains) ?? true) } }
        if let answering { lines = (lines.last { !$0.mine && $0.answers == answering } ?? fallback).map { [$0] } ?? [] }
        return lines.compactMap { row in
            var row = row
            switch style {
            case .verbatim: break
            case .log:
                var lines = row.text.split(separator: "\n", omittingEmptySubsequences: false)[...]
                while let first = lines.first?.trimmingCharacters(in: .whitespaces),
                      first.isEmpty || (first.hasPrefix("[") && first.hasSuffix("]")) { lines = lines.dropFirst() }
                row.text = lines.joined(separator: "\n")
                if row.text.hasPrefix("[from: "), let end = row.text.range(of: "]") { row.text = String(row.text[end.upperBound...]) }
                row.text = row.text.trimmingCharacters(in: .whitespaces)
            case .thread:
                if !row.mine {
                    row.text = bridgedText(row.text)
                    if owner != nil, let note = row.text.range(of: "(Dot sees your answer only if", options: .backwards) {
                        row.text = row.text[..<note.lowerBound].trimmingCharacters(in: .whitespacesAndNewlines)
                    }
                }
            }
            if (style == .log || owner != nil) && row.text.isEmpty { return nil }
            // A recorded route can name unattested words for display alone;
            // `consume` still sees only the stamp ("another agent").
            let source = row.source ?? [unattested, Line.object(row.metadata["origin"])["agent"]?.stringValue,
                Line.object(row.metadata["envelope"])["agent"]?.stringValue].compactMap { $0 }
                .first { !["", "agent", "peer", "another agent"].contains($0) }
            let name = source.map { (names[$0] ?? ($0.hasPrefix("peer:") ? unlistedPeer : nil) ?? $0)
                + (row.source == nil ? " (unattested)" : "") } ?? "another agent"
            row.speaker = row.byPerson ? person : row.mine ? own : row.contact ? contactPrefix + name : person
            if let mark { consume(row, mark: mark) }
            return row
        }
    }

    /// Reading marks the speaker alone. Recorded steering is provenance;
    /// reading it never steers this turn or marks her words as someone else's.
    @discardableResult
    public static func consume(_ line: Line, mark: (_ principal: String, _ words: String) -> Void) -> [String] {
        for speaker in line.speakers { mark(speaker, line.text) }
        return line.speakers
    }

    public static func bridgedText(_ content: String) -> String {
        var rows = BridgeRoutingPrefix.stripping(content).split(separator: "\n", omittingEmptySubsequences: false)[...]
        while let first = rows.first?.trimmingCharacters(in: .whitespaces),
              first.isEmpty || (first.hasPrefix("[") && first.hasSuffix("]")) || (first.hasPrefix("{\"agent\"") && first.hasSuffix("}")) {
            rows = rows.dropFirst()
        }
        return rows.joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines)
    }
}

/// Syntax shared by delegated-reply presentation and search. Callers decide
/// whether recorded provenance admits interpreting a row as an envelope.
public struct DelegatedReplyEnvelope: Sendable {
    public let text: String
    public let header: Substring
    public let reply: String
    public let codexTitle: String?
    private let marked: Bool

    public init(_ content: String) {
        let text = BridgeRoutingPrefix.stripping(content)
        self.text = text
        let rows = text.split(separator: "\n", maxSplits: 2, omittingEmptySubsequences: false)
        let notice = "this is an asynchronous completion event for work you delegated."
        let title = rows.first.map { String($0).lowercased() } ?? ""
        let codex = rows.count == 3 && rows[1].isEmpty
            && rows[2].prefix(notice.count).lowercased() == notice && text.contains("\nCodex result:\n")
            && ["codex replied to ", "codex wakeup failed", "codex turn stalled", "codex wakeup produced no reply"].contains(where: title.hasPrefix)
        codexTitle = codex ? title : nil
        let markers = ["--- Claude's reply ---", "--- OMP's reply ---"]
        let marker = markers.compactMap { text.range(of: $0) }.min(by: { $0.lowerBound < $1.lowerBound })
        let codexResult = text.range(of: "\nCodex result:\n")
        let start = codex ? codexResult : marker
        marked = start != nil
        header = text[..<([marker?.lowerBound, codexResult?.lowerBound].compactMap { $0 }.min() ?? text.endIndex)]
        var body = start.map { String(text[$0.upperBound...]) } ?? content
        if codex {
            body = body.trimmingCharacters(in: .whitespacesAndNewlines)
            if body.hasSuffix(" to ask whether Codex finished."),
               let footer = body.range(of: "\n\nNow give ", options: .backwards) {
                body = String(body[..<footer.lowerBound])
            }
        } else if let end = body.range(of: "--- end reply ---") {
            body = String(body[..<end.lowerBound])
        }
        reply = body.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    public var isHistorical: Bool {
        let head = text.prefix(400).lowercased()
        return head.hasPrefix("originating message id:") || head.hasPrefix("[claude-wake]")
            || head.hasPrefix("[omp-wake]") || head.hasPrefix("[delegation update from nativeagent")
            || codexTitle != nil
    }

    public var searchText: String {
        if marked { return reply }
        let head = text.prefix(400).lowercased()
        guard head.contains("automated completion event") || head.hasPrefix("originating message id:")
            || head.hasPrefix("[claude-wake]") || head.hasPrefix("[omp-wake]") else { return text }
        let keys = ["originating message id:", "topic:", "priority:", "status:", "duration:"]
        return text.split(separator: "\n", omittingEmptySubsequences: false).drop { line in
            let lowered = line.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
            return lowered.isEmpty || lowered.contains("automated completion event")
                || lowered.hasPrefix("[claude-wake] [notice]") || keys.contains(where: lowered.hasPrefix)
        }.joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines)
    }
}
