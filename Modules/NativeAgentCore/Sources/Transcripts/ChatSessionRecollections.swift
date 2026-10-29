import Foundation
import NativeAgentShared
import NativeAgentCore
import PersistenceCore
// Blueprint: | `ChatSessionRecollections.swift` | Recollection row/coverage parsing, exchange pairing by conversation/run with runless adjacency, incremental scans and timestamps |

/// Shared row and coverage semantics for a session's consolidated recollections.
/// A chat transcript's older turns are distilled as they age
/// past the aging boundary — into `compaction_summary` rows. Those rows ARE the
/// consolidated memory of the turns they replaced: the raw turns no longer
/// exist in the transcript.
///
/// The compaction writer and dream reader share this row shape so consolidated
/// material is not summarized again from raw turns.
public struct ChatSessionRecollection: Sendable, Equatable {
    public let sessionId: String
    public let rowId: String?
    /// The recollection text — the LLM-distilled first-person note when the
    /// distiller upgraded it, else the mechanical role-prefixed summary.
    public let text: String
    /// When the recollection row itself was written.
    public let createdAt: Date?
    /// Oldest turn this recollection covers, when the writer recorded it.
    public let coversFrom: Date?
    /// Newest turn this recollection covers, when the writer recorded it.
    public let coversUntil: Date?
    public let messagesReplaced: Int
    /// True once the LLM pass replaced the mechanical summary.
    public let distilled: Bool

    /// The instant this recollection's material ENDS. Consumers compare their
    /// own high-water mark against THIS, never against `createdAt`: a
    /// recollection written today can cover turns from last week, and a
    /// consumer that already read those turns raw must not read them again
    /// through their recollection. Legacy rows (written before coverage was
    /// recorded) fall back to the row's own timestamp.
    public var consolidatedThrough: Date? { coversUntil ?? createdAt }

    public init(
        sessionId: String,
        rowId: String?,
        text: String,
        createdAt: Date?,
        coversFrom: Date?,
        coversUntil: Date?,
        messagesReplaced: Int,
        distilled: Bool
    ) {
        self.sessionId = sessionId
        self.rowId = rowId
        self.text = text
        self.createdAt = createdAt
        self.coversFrom = coversFrom
        self.coversUntil = coversUntil
        self.messagesReplaced = messagesReplaced
        self.distilled = distilled
    }
}

public enum ChatSessionRecollections {
    /// Rows arrive in conversation order. Ineligible origins block their replies;
    /// runless replies use adjacency, and other roles stand alone and break it.
    /// Her own opening (a contact send, a post she started) answers no one and
    /// stands as its own exchange: it is lived, not a reply to drop.
    public static func pairExchanges(_ rows: [(conversation: String, run: String?, role: String, eligible: Bool)])
        -> [(row: Int, origin: Int, exchange: Int, firstReply: Bool)] {
        var current: [String: (exchange: Int, origin: Int)] = [:]
        var runs: [String: [String: (exchange: Int, origin: Int?)]] = [:]
        var asked = Set<String>(), answered: [String: Set<String>] = [:], blocked = Set<String>()
        var paired: [(row: Int, origin: Int, exchange: Int, firstReply: Bool)] = []
        for (index, row) in rows.enumerated() {
            let conversation = row.conversation
            if row.role == "user" {
                let exchange = row.run.flatMap { runs[conversation]?[$0]?.exchange } ?? index
                if let run = row.run { runs[conversation, default: [:]][run] = (exchange, row.eligible ? index : nil) }
                guard row.eligible else { current[conversation] = nil; blocked.insert(conversation); continue }
                blocked.remove(conversation)
                current[conversation] = (exchange, index)
                asked.insert(conversation)
                paired.append((index, index, exchange, false))
            } else if row.role == "assistant" {
                guard row.eligible else { continue }
                let pair: (exchange: Int, origin: Int)?
                if let run = row.run {
                    let saved = runs[conversation]?[run]
                    pair = saved.flatMap { saved in saved.origin.map { (saved.exchange, $0) } }
                } else { pair = current[conversation] }
                guard let pair else {
                    if row.run == nil, !blocked.contains(conversation) { paired.append((index, index, index, false)) }
                    continue
                }
                let first = row.run.map { answered[conversation, default: []].insert($0).inserted } ?? asked.contains(conversation)
                asked.remove(conversation)
                paired.append((index, pair.origin, pair.exchange, first))
            } else if row.eligible {
                current[conversation] = nil
                paired.append((index, index, index, false))
            }
        }
        return paired
    }

    /// One experience across live subjects, dated exchange refs and historical message IDs.
    public static func experienceIdentities(for references: [String], dataRoot: URL?) async throws -> [String: String] {
        try await ExperienceResolver(dataRoot: dataRoot).resolve(for: references, includingSourceRows: false).identities
    }

    /// A mind pass shares transcript reads, including failures, without coupling unrelated claims.
    public actor ExperienceResolver {
        private let dataRoot: URL?
        private var identities: [String: String] = [:]
        private var transcripts: [URL: Task<[JSONValue], Error>] = [:]
        private var archived: Result<[String: [URL]], Error>?

        public init(dataRoot: URL?) { self.dataRoot = dataRoot }

        public func resolve(for references: [String], includingSourceRows: Bool) async throws -> (
            identities: [String: String], messages: [String: (session: String, row: [String: JSONValue])]
        ) {
            let known = identities
            var identities: [String: String] = [:]
            var messages: [String: (session: String?, id: String, run: String?)] = [:]
            var resolved: [String: (session: String, row: [String: JSONValue])] = [:]
            for reference in references {
                if !includingSourceRows, let identity = known[reference] {
                    identities[reference] = identity
                    continue
                }
                var undated = String(reference.prefix { $0 != "@" })
                for prefix in ["chat.user_turn:", "chat.assistant_turn:"] where undated.hasPrefix(prefix) {
                    let subject = undated.dropFirst(prefix.count)
                    if let separator = subject.lastIndex(of: ":") {
                        undated = "message:" + subject[..<separator] + "/" + subject[subject.index(after: separator)...]
                    }
                }
                if undated.hasPrefix("exchange:") {
                    let citation = undated.components(separatedBy: "#message:")
                    let path = citation[0].dropFirst(9).split(separator: "/", maxSplits: 1).map(String.init)
                    identities[reference] = path.count == 2
                        ? "exchange:" + path[0] + "/" + (UUID(uuidString: path[1])?.uuidString ?? path[1]) : citation[0]
                    if includingSourceRows, path.count == 2, citation.count == 2 {
                        messages[reference] = (path[0], UUID(uuidString: citation[1])?.uuidString ?? citation[1],
                                               UUID(uuidString: path[1])?.uuidString ?? path[1])
                    }
                    continue
                }
                let recollection = undated.hasPrefix("recollection:")
                let path = undated.dropFirst(recollection ? 13 : (undated.hasPrefix("message:") ? 8 : 0))
                    .split(separator: "/", maxSplits: 1).map(String.init)
                let id = path.last ?? undated
                if recollection || undated.hasPrefix("message:") || UUID(uuidString: undated) != nil {
                    let canonical = UUID(uuidString: id)?.uuidString ?? id
                    identities[reference] = recollection ? undated : "message:" + canonical
                    if !recollection || (includingSourceRows && path.count == 2) {
                        messages[reference] = (path.count == 2 ? path[0] : nil, canonical, nil)
                    }
                } else {
                    identities[reference] = undated
                }
            }
            guard !messages.isEmpty, let dataRoot else {
                self.identities.merge(identities) { _, new in new }
                return (identities, resolved)
            }
            let sessions = Set(messages.values.compactMap(\.session))
            let unscoped = messages.values.contains { $0.session == nil }
            func files(_ archived: [String: [URL]]) throws -> [(String, URL)] {
                try unscoped ? ChatSessionRetention.transcriptFiles(dataRoot: dataRoot, archived: archived)
                    : sessions.sorted().flatMap {
                        try ChatSessionRetention.transcriptFiles(dataRoot: dataRoot, sessionId: $0, archived: archived)
                    }
            }
            let byID = Dictionary(grouping: messages, by: { $0.value.id })
            var readFiles: Set<URL> = []
            func read(_ files: [(String, URL)], isolation: isolated ExperienceResolver) async throws {
                for (session, file) in files {
                    guard messages.values.contains(where: { $0.session == nil || $0.session == session }),
                          readFiles.insert(file.standardizedFileURL).inserted else { continue }
                    let key = file.standardizedFileURL
                    let transcript = transcripts[key] ?? Task {
                        let read = try await SwiftNativePersistenceCore.readJSONLReporting(file)
                        guard read.report.isClean else {
                            throw PersistenceCoreError.ioFailure("experience identity transcript is incomplete: \(session)")
                        }
                        return read.rows
                    }
                    transcripts[key] = transcript
                    for value in try await transcript.value {
                        guard case .object(let row) = value, case .string(let id)? = row["id"],
                              let matches = byID[UUID(uuidString: id)?.uuidString ?? id] else { continue }
                        let run: String?
                        if case .string(let value)? = row["runId"] { run = UUID(uuidString: value)?.uuidString ?? value }
                        else { run = nil }
                        for (reference, message) in matches where messages[reference] != nil
                            && (message.session == nil || message.session == session)
                            && (message.run == nil || message.run == run) {
                            resolved[reference] = (session, row)
                            if let run, !run.isEmpty, !reference.hasPrefix("recollection:") {
                                identities[reference] = "exchange:\(session)/\(run)"
                            }
                            messages.removeValue(forKey: reference)
                        }
                    }
                    if messages.isEmpty { break }
                }
            }
            try await read(files([:]), isolation: self)
            if !messages.isEmpty {
                let archive: Result<[String: [URL]], Error>
                if let cached = archived {
                    archive = cached
                } else {
                    archive = Result { try ChatSessionRetention.archivedTranscripts(dataRoot: dataRoot) }
                    archived = archive
                }
                try await read(files(archive.get()), isolation: self)
            }
            self.identities.merge(identities) { _, new in new }
            return (identities, resolved)
        }
    }

    package struct Scan: Sendable {
        package let completeRecollections: [ChatSessionRecollection]
        let trailingRecollection: ChatSessionRecollection?
        /// Start of an unfinished trailing line, or EOF after a newline.
        package let nextOffset: UInt64

        package var recollections: [ChatSessionRecollection] {
            guard let trailingRecollection else { return completeRecollections }
            return completeRecollections + [trailingRecollection]
        }
    }

    /// Streaming/incremental accessor for append-owned transcripts. Callers
    /// must reset the offset on replacement, truncation, or an in-place rewrite.
    /// Only completed lines may be reused as `previous`; the trailing line is reread.
    package static func scan(path: URL, sessionId: String, offset: UInt64 = 0,
                             previous: [ChatSessionRecollection] = []) throws -> Scan {
        let file = try FileHandle(forReadingFrom: path)
        defer { try? file.close() }
        try file.seek(toOffset: offset)
        var pending = Data()
        var recollections = previous
        var consumed = offset
        func parse(_ bytes: Data) -> ChatSessionRecollection? {
            guard let row = try? JSONValue.parse(bytes) else { return nil }
            return recollection(fromTranscriptRow: row, sessionId: sessionId)
        }
        while let chunk = try file.read(upToCount: 64 * 1024), !chunk.isEmpty {
            pending.append(chunk)
            while let newline = pending.firstIndex(of: 10) {
                let end = pending.index(after: newline)
                if let value = parse(Data(pending[..<newline])) { recollections.append(value) }
                consumed += UInt64(pending.distance(from: pending.startIndex, to: end))
                pending.removeSubrange(..<end)
            }
        }
        // Preserve the tolerant accessor's support for a valid final JSON row
        // without a newline. Re-read that line if another append completes it.
        return Scan(completeRecollections: recollections,
                    trailingRecollection: pending.isEmpty ? nil : parse(pending), nextOffset: consumed)
    }

    /// `metadata.kind` marking a transcript row as a consolidated recollection.
    public static let rowKind = "compaction_summary"
    package static let continuityProvenanceKey = "continuity_provenance"

    package static func continuityProvenance(for rows: [JSONValue]) -> JSONValue {
        var provenance: JSONValue?
        for row in rows {
            guard case .object(let fields) = row,
                  case .string(let role)? = fields["role"] else { return .null }
            let metadata: [String: JSONValue]?
            if case .object(let value)? = fields["metadata"] { metadata = value }
            else { metadata = nil }
            guard ["user", "assistant"].contains(role) || metadata?["kind"] == .string(rowKind) else { continue }
            guard let binding = continuityBinding(role: role, metadata: metadata) else { return .null }
            if let provenance, provenance != binding { return .null }
            provenance = binding
        }
        return provenance ?? .null
    }

    package static func admitsContinuity(
        role: String,
        metadata: [String: JSONValue]?,
        participant: String,
        source: String?,
        scope: String?
    ) -> Bool {
        guard ["user", "assistant"].contains(role) || metadata?["kind"] == .string(rowKind) else { return true }
        guard let actual = continuityBinding(role: role, metadata: metadata),
              let expected = continuityBinding(participant: participant, source: source, scope: scope) else { return false }
        return actual == expected
    }

    package static func continuityBinding(role: String, metadata: [String: JSONValue]?) -> JSONValue? {
        guard let metadata else { return nil }
        if metadata["kind"] == .string(rowKind) {
            guard case .object(let recorded)? = metadata[continuityProvenanceKey],
                  let participant = continuityString(recorded["participant"]),
                  let binding = continuityBinding(
                    participant: participant,
                    source: continuityString(recorded["source"]),
                    scope: continuityString(recorded["scope"])),
                  binding == .object(recorded) else { return nil }
            return binding
        }
        guard role != "user" || metadata["mechanicalKind"] == nil,
              case .object(let envelope)? = metadata["envelope"],
              let surface = continuityString(envelope["surface"]) else { return nil }
        if let agent = continuityString(envelope["agent"]) {
            guard agent != "self", !agent.hasPrefix("bot:") else { return nil }
            let participant: String
            if let user = continuityString(envelope["userId"]), !user.isEmpty { participant = "peer:" + user }
            else {
                guard !["agent", "peer", ""].contains(agent) else { return nil }
                participant = "peer:" + agent
            }
            return continuityBinding(participant: participant, source: nil, scope: nil)
        }
        guard metadata["origin"] == nil else { return nil }
        if ["app", "chat", "mac", "default", "ios", "mobile", "iphone", "icloud"].contains(surface) {
            return continuityBinding(participant: "local_operator", source: nil, scope: nil)
        }
        guard let user = continuityString(envelope["userId"]), !user.isEmpty,
              let chat = continuityString(envelope["chatId"]) else { return nil }
        return continuityBinding(
            participant: surface + ":" + user,
            source: surface,
            scope: chat + "\u{1F}" + (continuityString(envelope["threadId"]) ?? ""))
    }

    private static func continuityBinding(participant: String, source: String?, scope: String?) -> JSONValue? {
        if participant == "local_operator" || (participant.hasPrefix("peer:") && participant.count > 5) {
            return .object(["participant": .string(participant)])
        }
        guard !participant.isEmpty, let source, !source.isEmpty, let scope, !scope.isEmpty else { return nil }
        return .object(["participant": .string(participant), "source": .string(source), "scope": .string(scope)])
    }

    private static func continuityString(_ value: JSONValue?) -> String? {
        guard case .string(let text)? = value else { return nil }
        return text.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// `metadata` keys the writer stamps so a reader can tell WHICH stretch of
    /// life a recollection stands for without re-reading the backup.
    public static let coversFromKey = "covers_from"
    public static let coversUntilKey = "covers_until"
    /// Recognize a recollection row. Returns nil for every ordinary transcript
    /// row — this is the only place that knows the shape.
    public static func recollection(
        fromTranscriptRow row: JSONValue,
        sessionId: String
    ) -> ChatSessionRecollection? {
        guard case .object(let obj) = row else { return nil }
        guard case .object(let metadata)? = obj["metadata"],
              case .string(let kind)? = metadata["kind"],
              kind == rowKind
        else { return nil }
        let text: String = {
            if case .string(let value)? = obj["content"] { return value }
            return ""
        }()
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        let rowId: String? = {
            if case .string(let value)? = obj["id"] { return value }
            return nil
        }()
        let replaced: Int = {
            if case .int(let value)? = metadata["messages_replaced"] { return Int(value) }
            if case .double(let value)? = metadata["messages_replaced"] { return Int(exactly: value.rounded(.towardZero)) ?? 0 }
            return 0
        }()
        let distilled: Bool = {
            if case .string(let value)? = metadata["distill"] { return value == "llm" }
            return false
        }()
        return ChatSessionRecollection(
            sessionId: sessionId,
            rowId: rowId,
            text: trimmed,
            createdAt: parseTimestamp(obj["createdAt"]),
            coversFrom: parseTimestamp(metadata[coversFromKey]),
            coversUntil: parseTimestamp(metadata[coversUntilKey]),
            messagesReplaced: replaced,
            distilled: distilled
        )
    }

    /// The dream lane's high-water mark — the newest turn a dream has already
    /// consumed — read from the runner's own `.dream_state.json` sidecar.
    ///
    /// It lives HERE, beside the row shape, because the WRITER needs it as much
    /// as the reader: a recollection whose span straddles this mark
    /// (`covers_from <= mark < covers_until`) is admitted WHOLE by the reader,
    /// so its pre-mark turns get dreamed a second time after they were already
    /// dreamed raw. The writer clamps its replacement against this so no such
    /// row is ever created. Only an absent state has no mark; damage throws.
    public static func dreamConsolidationMark(dataRoot: URL) throws -> Date? {
        let path = dataRoot
            .appendingPathComponent("dream_diary", isDirectory: true)
            .appendingPathComponent(".dream_state.json")
        let data: Data
        do { data = try Data(contentsOf: path) }
        catch let error as CocoaError where error.code == .fileReadNoSuchFile { return nil }
        let parsed: JSONValue
        do { parsed = try JSONValue.parse(data) }
        catch { throw PersistenceCoreError.ioFailure("dreamConsolidationMark could not decode \(path.path): \(error)") }
        guard case .object(let obj) = parsed,
              let mark = parseTimestamp(obj["lastDreamedAt"]) else {
            throw CocoaError(.fileReadCorruptFile, userInfo: [NSFilePathErrorKey: path.path])
        }
        return mark
    }

    /// True when this recollection's material STRADDLES `mark`: part of it was
    /// already consumed at or before the mark, part of it was not. Such a row
    /// cannot be admitted whole and cannot be split after the fact — the raw
    /// turns behind it are gone.
    public static func straddles(_ recollection: ChatSessionRecollection, mark: Date) -> Bool {
        guard let from = recollection.coversFrom,
              let until = recollection.consolidatedThrough else { return false }
        return from <= mark && until > mark
    }

    /// Live transcripts carry microsecond ISO8601 (`...T11:33:32.167835+00:00`)
    /// while `ISO8601DateFormatter.withFractionalSeconds` accepts three digits.
    /// Try fractional, then plain, then truncate to milliseconds.
    public static func parseTimestamp(_ value: JSONValue?) -> Date? {
        guard case .string(let raw)? = value else { return nil }
        let text = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return nil }
        if let date = NativeTimestampFormat.parseISO8601FractionalFirst(text) { return date }
        // Truncate an over-long fractional part to milliseconds and retry.
        if let dot = text.firstIndex(of: ".") {
            let afterDot = text.index(after: dot)
            var digitsEnd = afterDot
            while digitsEnd < text.endIndex, text[digitsEnd].isNumber {
                digitsEnd = text.index(after: digitsEnd)
            }
            let digits = text[afterDot..<digitsEnd]
            if digits.count > 3 {
                let keep = text.index(afterDot, offsetBy: 3)
                let rebuilt = String(text[text.startIndex..<keep]) + String(text[digitsEnd...])
                if let date = NativeTimestampFormat.parseISO8601FractionalFirst(rebuilt) { return date }
            }
        }
        return nil
    }
}
