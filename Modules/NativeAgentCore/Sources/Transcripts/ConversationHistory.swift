import Foundation
import NativeAgentShared
import NativeAgentCore
import PersistenceCore
// Blueprint: | `ConversationHistory.swift` | Exchange pairing, transcript provenance and dream consumption marks |

public enum ConversationHistory {
    /// Rows arrive in conversation order. Ineligible origins block their replies; runless replies use adjacency, and other roles stand alone and break it. The
    /// agent's own opening (a contact send, a post it started) answers no one and stands as its own exchange: it is lived, not a reply to drop.
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

    /// Share experience identity across live subjects, dated refs and historical IDs to prevent duplicate intake.
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
                let path = undated.dropFirst(undated.hasPrefix("message:") ? 8 : 0)
                    .split(separator: "/", maxSplits: 1).map(String.init)
                let id = path.last ?? undated
                if undated.hasPrefix("message:") || UUID(uuidString: undated) != nil {
                    let canonical = UUID(uuidString: id)?.uuidString ?? id
                    identities[reference] = "message:" + canonical
                    messages[reference] = (path.count == 2 ? path[0] : nil, canonical, nil)
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
                            if let run, !run.isEmpty {
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

    package static func admitsContinuity(
        role: String,
        metadata: [String: JSONValue]?,
        participant: String,
        source: String?,
        scope: String?
    ) -> Bool {
        guard ["user", "assistant"].contains(role) else { return true }
        guard let actual = continuityBinding(role: role, metadata: metadata),
              let expected = continuityBinding(participant: participant, source: source, scope: scope) else { return false }
        return actual == expected
    }

    package static func continuityBinding(role: String, metadata: [String: JSONValue]?) -> JSONValue? {
        guard let metadata else { return nil }
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
        if ["chat", "ios"].contains(surface) {
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

    /// Read current ISO8601 timestamps without changing the saved observation time.
    public static func parseTimestamp(_ value: JSONValue?) -> Date? {
        guard case .string(let raw)? = value else { return nil }
        let text = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return nil }
        return NativeTimestampFormat.parseISO8601FractionalFirst(text)
    }
}
