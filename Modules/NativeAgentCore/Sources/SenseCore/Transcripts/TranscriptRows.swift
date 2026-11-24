import Foundation
import NativeAgentShared
import Darwin
import Synchronization
import NativeAgentCore
import PersistenceCore
// Blueprint: | `TranscriptRows.swift` | `ContactThread`, `read`, `Line`, `project`, `DelegatedReplyEnvelope`: Locked transcripts; shared display |

/// The shared storage and reading of conversations. Routing extends this owner; presentation never derives a speaker from the session that holds a row.
public enum ContactThread {
    // Transcript JSONL is locally/off-disk backed up and inventoried under chat. Production export excludes it; ChatExport writes Markdown and DeviceSync
    // publishes bounded person-visible rows.

    public static func decodeRow(_ data: Data) throws -> [String: JSONValue] {
        do {
            guard case .object(let fields) = try JSONValue.parseUTF8(data.bytes) else { throw CocoaError(.fileReadCorruptFile) }
            return fields
        } catch where data.contains(0) {
            throw CocoaError(.fileReadCorruptFile)
        }
    }

    private struct RunIndex {
        var stamp: SnapshotTailOpLog.FileStamp
        var ids: Set<String>
    }

    private static let runIndices = Mutex<[String: RunIndex]>([:])

    public static func append(_ row: JSONValue, to path: URL,
                              uniqueRunID: String? = nil) async throws {
        try await SwiftNativePersistenceCore.withFileLock(path) {
            let key = path.standardizedFileURL.path
            var index = runIndices.withLock { $0.removeValue(forKey: key) }
            if let cached = index {
                let duplicate = uniqueRunID.map(cached.ids.contains) == true
                if cached.stamp != SnapshotTailOpLog.fileStamp(path) {
                    index = nil
                } else if duplicate {
                    runIndices.withLock { $0[key] = cached }
                    return
                }
            }
            if let uniqueRunID, index == nil {
                guard let stamp = SnapshotTailOpLog.fileStamp(path) else {
                    throw PersistenceCoreError.ioFailure("Cannot inspect transcript at \(path.path)")
                }
                let read = try SwiftNativePersistenceCore.readJSONL(path, at: stamp) { .object(try decodeRow($0)) }
                let ids = Set(read.rows.compactMap { $0.objectValue?["runId"]?.stringValue })
                guard let revision = read.stamp, revision == SnapshotTailOpLog.fileStamp(path) else {
                    throw PersistenceCoreError.ioFailure("Transcript changed while reading \(path.path)")
                }
                index = RunIndex(stamp: revision, ids: ids)
                if ids.contains(uniqueRunID) {
                    runIndices.withLock { $0[key] = index }
                    return
                }
            }
            let written = try SwiftNativePersistenceCore.appendRecords([row], to: path, durable: true,
                                                                     trackingRevision: index != nil)
            if let written, let stamp = index?.stamp, written.extended(stamp) {
                if let id = row.objectValue?["runId"]?.stringValue { index?.ids.insert(id) }
                index?.stamp = written.after
                runIndices.withLock { $0[key] = index }
            }
        }
    }

    public static func replace(_ bytes: Data, to path: URL) throws {
        try CredentialFileLock.withLock(path) {
            try SwiftNativePersistenceCore.writeDataAtomicDurable(bytes, to: path)
            _ = chmod(path.path, 0o600)
            runIndices.withLock { $0[path.standardizedFileURL.path] = nil }
        }
    }

    /// Edit one admitted row; every other byte, including blank lines and final-newline state, belongs to the original transcript.
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
        /// A damaged authoritative field withholds this row; it is never reconstructed.
        public private(set) var provenanceFailure: String?
        public var mine: Bool { role == "assistant" || stamp.source == "self" }
        public var contact: Bool { stamp.contact && !mine }
        public var source: String? { contact ? stamp.source : nil }
        public var steeredBy: [String] { stamp.steeredBy }
        public var speakers: [String] { contact ? [source ?? "another agent"] : [] }
        public var human: Bool {
            provenanceFailure == nil && role == "user" && metadata["mechanicalKind"] == nil && !mine && !contact
                && JSONValue.objectOrEmpty(metadata["origin"])["authored"] != .string("agent")
        }

        /// Cached previews keep the writer's stamp beside the words they quote.
        public init(text: String, stamp: TranscriptRowStamp, id: String = "", role: String = "user") {
            self.id = id; self.role = role; self.text = text; self.stamp = stamp
            self.byPerson = false
        }

        public init(_ row: [String: JSONValue], role: String? = nil, text: String? = nil, timestamp: String? = nil, metadata: [String: JSONValue]? = nil) {
            let role = role ?? row["role"]?.stringValue ?? ""
            let metadata = metadata ?? JSONValue.objectOrEmpty(row["metadata"])
            let id = row["id"]?.stringValue ?? ""
            let failure = Self.provenanceFailure(in: row, metadata: metadata)
            self.init(text: text ?? row["content"]?.stringValue ?? "",
                      stamp: failure != nil ? .init(source: nil, steeredBy: [], contact: false) : row["stamp"] == nil
                        ? .of(id: id, role: role, metadata: metadata, rowSource: row["source"]?.stringValue)
                        : (TranscriptRowStamp(json: row["stamp"]) ?? .init(source: nil, steeredBy: [], contact: false)), id: id, role: role)
            self.metadata = metadata
            self.timestamp = timestamp ?? row["createdAt"]?.stringValue
            self.date = self.timestamp.flatMap(NativeTimestampFormat.parseISO8601FractionalFirst)
            self.run = row["runId"]?.stringValue
            self.byPerson = metadata["byPerson"] == .bool(true)
            self.answers = role == "user" ? JSONValue.objectOrEmpty(metadata["origin"])["replyTo"]?.stringValue.flatMap {
                $0.hasPrefix("agent-conversation:") ? String($0.dropFirst("agent-conversation:".count)) : nil
            } : nil
            self.sendID = role == "assistant" ? metadata["dotClientUserMessageID"]?.stringValue : nil
            self.sendState = metadata["sendState"]?.stringValue
            if let failure {
                self.provenanceFailure = "Transcript row \(id.isEmpty ? "<missing id>" : id): \(failure). Repair its saved provenance before reading it."
                self.text = ""
                self.byPerson = false
                nativeLog("Transcript row %@ unavailable: %@", id, failure)
            }
        }

        public init?(jsonl data: Data) {
            guard let row = try? ContactThread.decodeRow(data),
                  case .string? = row["content"] else { return nil }
            self.init(row)
        }

        private static func provenanceFailure(in row: [String: JSONValue], metadata: [String: JSONValue]) -> String? {
            if let stamp = row["stamp"], TranscriptRowStamp(json: stamp) == nil { return "saved stamp is malformed" }
            if let source = row["source"], case .string = source {} else if row["source"] != nil { return "saved source is not text" }
            for key in ["byPerson", "unattested"] {
                if let value = metadata[key], case .bool = value {} else if metadata[key] != nil { return "\(key) is not a Boolean" }
            }
            if let value = row["metadata"] {
                switch value {
                case .object: break
                default: return "saved metadata is not an object"
                }
            }
            for key in ["origin", "envelope"] {
                guard let value = metadata[key] else { continue }
                let fields: [String: JSONValue]
                switch value {
                case .object(let object): fields = object
                default: return "\(key) is not an object"
                }
                for name in ["agent", "userId", "surface", "replyTo", "authored"] {
                    if let field = fields[name], case .string = field {} else if fields[name] != nil { return "\(key).\(name) is not text" }
                }
            }
            if let sources = metadata["untrusted_sources"] {
                guard case .array(let values) = sources,
                      values.allSatisfy({ if case .string = $0 { true } else { false } }) else { return "untrusted_sources is malformed" }
            }
            return nil
        }
    }

    public enum TextStyle { case verbatim, log, thread }

    /// The byte read shared by tail and incremental adapters; each owns its row boundaries and selection.
    public static func read(_ handle: FileHandle, from offset: UInt64, bytes: Int? = nil) throws -> Data? {
        try handle.seek(toOffset: offset)
        if let bytes { return try handle.read(upToCount: bytes) }
        return try handle.readToEnd()
    }

    @concurrent package static func readCheckedRows(at path: URL, after previous: SnapshotTailOpLog.FileStamp?) async throws
        -> (rows: [JSONValue], newlineRevision: SnapshotTailOpLog.FileStamp?) {
        if let read = try readRows(at: path, after: previous) { return read }
        if let read = try readRows(at: path, after: nil) { return read }
        throw PersistenceCoreError.ioFailure("Transcript changed while reading \(path.path)")
    }

    private static func readRows(at path: URL, after previous: SnapshotTailOpLog.FileStamp?) throws
        -> (rows: [JSONValue], newlineRevision: SnapshotTailOpLog.FileStamp?)? {
        let fd = open(path.path, O_RDONLY | O_NONBLOCK | O_CLOEXEC)
        guard fd >= 0 else { throw NSError(domain: NSPOSIXErrorDomain, code: Int(errno)) }
        defer { _ = close(fd) }
        let handle = FileHandle(fileDescriptor: fd, closeOnDealloc: false)
        var info = stat()
        guard unsafe fstat(fd, &info) == 0 else { throw NSError(domain: NSPOSIXErrorDomain, code: Int(errno)) }
        guard (info.st_mode & S_IFMT) == S_IFREG, info.st_size >= 0 else {
            throw CocoaError(.fileReadCorruptFile)
        }
        let revision = SnapshotTailOpLog.FileStamp(info)
        var start: UInt64 = 0
        if case .present(let device, let inode, let size, _, _, _, _)? = previous,
           device == info.st_dev, inode == info.st_ino, size > 0, size < info.st_size,
           try read(handle, from: UInt64(size - 1), bytes: 1)?.first == 0x0A {
            start = UInt64(size)
        }
        guard let count = Int(exactly: UInt64(info.st_size) - start) else { throw CocoaError(.fileReadTooLarge) }
        let data = count == 0 ? Data() : (try read(handle, from: start, bytes: count) ?? Data())
        guard data.count == count else { return nil }
        let decoded = SwiftNativePersistenceCore.decodeJSONL(data) { row, _ in row }
        let current = regularFileRevision(at: path)
        guard revision == current || (start == 0 && revision == SnapshotTailOpLog.fileStamp(path)) else { return nil }
        guard decoded.report.isClean else {
            throw PersistenceCoreError.ioFailure("""
                JSONL evidence is incomplete at \(path.path): \(decoded.report.malformedLineCount) malformed row(s), \
                trailingPartial=\(decoded.report.trailingPartialLine).
                """)
        }
        return (decoded.rows, revision == current && data.last == 0x0A ? revision : nil)
    }

    package static func regularFileRevision(at path: URL) -> SnapshotTailOpLog.FileStamp? {
        var info = stat()
        guard unsafe lstat(path.path, &info) == 0, (info.st_mode & S_IFMT) == S_IFREG else { return nil }
        return SnapshotTailOpLog.FileStamp(info)
    }

    /// One stamped-row projection for sessions, contact threads and retained previews; answer selection requires the matching canonical line.
    public static func project(_ rows: some Sequence<Line>, style: TextStyle = .verbatim, thread owner: String? = nil,
                               person: String = "the person", own: String = "you", names: [String: String] = [:],
                               contactPrefix: String = "", unlistedPeer: String? = nil, unattested: String? = nil,
                               answering: String? = nil) -> [Line] {
        var started: Set<String> = [], seen: Set<String> = []
        var lines = rows.filter { row in
            guard row.provenanceFailure == nil else { return false }
            guard let owner else { return true }
            guard !seen.contains(row.id) else { return false }
            let origin = JSONValue.objectOrEmpty(row.metadata["origin"]), envelope = JSONValue.objectOrEmpty(row.metadata["envelope"])
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
        if let answering { lines = lines.last { !$0.mine && $0.answers == answering }.map { [$0] } ?? [] }
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
            if (style == .log || owner != nil) && row.text.isEmpty {
                guard row.mine, row.sendID != nil, case .array(let files)? = row.metadata["attachments"], !files.isEmpty else { return nil }
            }
            // A recorded route can name unattested words for display; speaker provenance comes from the stamp.
            let source = row.source ?? [unattested, JSONValue.objectOrEmpty(row.metadata["origin"])["agent"]?.stringValue,
                JSONValue.objectOrEmpty(row.metadata["envelope"])["agent"]?.stringValue].compactMap { $0 }
                .first { !["", "agent", "peer", "another agent"].contains($0) }
            let name = source.map { (names[$0] ?? ($0.hasPrefix("peer:") ? unlistedPeer : nil) ?? $0)
                + (row.source == nil ? " (unattested)" : "") } ?? "another agent"
            row.speaker = row.byPerson ? person : row.mine ? own : row.contact ? contactPrefix + name : person
            return row
        }
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

/// Syntax shared by delegated-reply presentation and search. Callers decide whether recorded provenance admits interpreting a row as an envelope.
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
        let markers = ["--- OMP's reply ---"]
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
        return head.hasPrefix("originating message id:") || head.hasPrefix("[omp-wake]")
            || codexTitle != nil
    }

    public var searchText: String {
        if marked { return reply }
        let head = text.prefix(400).lowercased()
        guard head.contains("automated completion event") || head.hasPrefix("originating message id:")
            || head.hasPrefix("[omp-wake]") else { return text }
        let keys = ["originating message id:", "topic:", "priority:", "status:", "duration:"]
        return text.split(separator: "\n", omittingEmptySubsequences: false).drop { line in
            let lowered = line.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
            return lowered.isEmpty || lowered.contains("automated completion event")
                || keys.contains(where: lowered.hasPrefix)
        }.joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines)
    }
}
