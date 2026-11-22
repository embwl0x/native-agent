import Foundation
import NativeAgentShared
import NativeAgentCore
import PersistenceCore
import Transcripts
import CognitiveSubstrate
// Blueprint: | `DreamCycleRunner+Messages.swift` | `DreamCycleRunner`, `gatherRecentMessagesAcrossSessions`: oldest-first whole exchanges. |

extension DreamCycleRunner {
    private static let convCharBudget: Int = 160_000
    private static let convCountLimit: Int = 600

    // MARK: cross-session message gather

    /// Gather eligible conversation across sessions, oldest whole exchange first, until the budget is full. The returned mark is the last
    /// exchange read, so what did not fit is the next dream's first material; tool/system rows are not identity input.
    func gatherRecentMessagesAcrossSessions(since mark: Date) throws -> (
        messages: [(sessionId: String, role: String, content: String, source: String?)],
        newest: Date?,
        sources: [DreamSourceRef],
        material: [String: CognitiveReflectionCause],
        moreMessagesRemain: Bool
    ) {
        let messagesDir = dataRoot.appendingPathComponent("chat", isDirectory: true)
            .appendingPathComponent("messages", isDirectory: true)
        let names: [String]
        do { names = try fm.contentsOfDirectory(atPath: messagesDir.path) }
        catch CocoaError.fileReadNoSuchFile { return ([], nil, [], [:], false) }
        let conversations = try SessionConversation(dataRoot: dataRoot, includingArchived: true)
        struct Row {
            let at: Date;
            let sid: String;
            let mid: String?;
            let runID: String?;
            let role: String;
            let content: String;
            let peers: [String]?;
            var lived = true
        }
        var all: [Row] = []
        for name in names where name.hasSuffix(".jsonl") {
            let url = messagesDir.appendingPathComponent(name)
            let attrs = try fm.attributesOfItem(atPath: url.path)
            let mtime = (attrs[.modificationDate] as? Date) ?? .distantPast
            // Allow one hour of skew in file prefiltering; exact exchange timestamps remain authoritative.
            if mtime.addingTimeInterval(3600) <= mark { continue }
            let sid = (name as NSString).deletingPathExtension
            guard conversations.kind(sid)?.isOwnWork != true, !conversations.isHelper(sid) else { continue }
            let text = try String(contentsOf: url, encoding: .utf8)
            for line in text.split(separator: "\n", omittingEmptySubsequences: true) {
                let s = String(line).trimmingCharacters(in: .whitespacesAndNewlines)
                if s.isEmpty { continue }
                let parsed = try JSONValue.parse(Data(s.utf8))
                guard case .object(let obj) = parsed else {
                    throw PersistenceCoreError.ioFailure("transcript row is not an object: \(url.path)")
                }
                var role = "unknown"
                var content = ""
                var messageId: String?
                if case .string(let r)? = obj["role"] { role = r.lowercased() }
                if case .string(let c)? = obj["content"] { content = c }
                // Use the row's canonical ID to join felt origins and claim lineage.
                if case .string(let mid)? = obj["id"] { messageId = mid }
                if content.isEmpty { continue }
                // Only agent and user speech shape identity; exclude tool/system rows.
                if !Self.identityRoles.contains(role.lowercased()) { continue }
                let metadata: [String: JSONValue]
                switch obj["metadata"] {
                case .object(let value)?: metadata = value
                case .string(let text)?:
                    guard case .object(let value) = try JSONValue.parse(Data(text.utf8)) else {
                        throw PersistenceCoreError.ioFailure("transcript metadata is not an object: \(url.path)")
                    }
                    metadata = value
                default: metadata = [:]
                }
                let runID: String? = if case .string(let id)? = obj["runId"], !id.isEmpty { id } else { nil }
                let lived = !CognitiveMechanicalRowKind.marksMechanicalRow(metadata)
                guard let at = NativeTimestampFormat.parseTrimmedISO8601FractionalFirst(obj["createdAt"]?.stringValue) else {
                    throw PersistenceCoreError.ioFailure(
                        "Transcript occurrence time unavailable at \(url.path); preserve and repair its createdAt before dreaming it")
                }
                // Keep admitted origins until exchange grouping because a new reply may belong to an origin just before the mark.
                all.append(Row(at: at, sid: sid, mid: messageId, runID: runID, role: role, content: content,
                    peers: DreamEntryProvenance.transcriptCause(obj, session: sid, dataRoot: dataRoot)?.sourcePeerIds, lived: lived))
            }
        }
        let paired = ConversationHistory.pairExchanges(all.map { ($0.sid, $0.runID, $0.role, $0.lived) })
        let ordered = paired.map { (exchange: $0.exchange, row: all[$0.row]) }.sorted { $0.row.at < $1.row.at }
        let exchangeByIndex = ordered.map(\.exchange)
        all = ordered.map(\.row)
        struct Exchange {
            let start: Int
            var rows: [(index: Int, row: Row)]
            var at: Date
            var length: Int
        }
        func rowLength(_ row: Row) -> Int { row.role.count + row.content.count + 4 }
        var exchanges: [Exchange] = []
        let grouped = Dictionary(grouping: all.enumerated(), by: { exchangeByIndex[$0.offset] })
        for entries in grouped.values {
            let rows = entries.map { (index: $0.offset, row: $0.element) }
            guard let first = rows.first else { continue }
            exchanges.append(Exchange(start: first.index, rows: rows, at: rows.map { $0.row.at }.max() ?? first.row.at,
                length: rows.reduce(0) { $0 + rowLength($1.row) }))
        }
        exchanges.removeAll { $0.at <= mark }
        exchanges.sort { ($0.at, $0.start) < ($1.at, $1.start) }
        var pickedEntries: [(index: Int, row: Row)] = []
        var used = 0, count = 0
        var moreMessagesRemain = false
        var newest: Date?, firstAt: Date?, stoppedAt: Date?
        for (index, exchange) in exchanges.enumerated() {
            if count + exchange.rows.count <= Self.convCountLimit, used + exchange.length <= Self.convCharBudget {
                pickedEntries.append(contentsOf: exchange.rows)
                used += exchange.length
                count += exchange.rows.count
                if firstAt == nil { firstAt = exchange.at }
                newest = exchange.at
                continue
            }
            // An exchange larger than a whole dream is read first in its own night, as much of its end as fits; anything else waits.
            if pickedEntries.isEmpty {
                for entry in exchange.rows.sorted(by: { $0.index > $1.index }) {
                    var entry = entry
                    // A single message larger than a whole dream is read from its end.
                    if pickedEntries.isEmpty, rowLength(entry.row) > Self.convCharBudget {
                        let row = entry.row
                        entry.row = Row(at: row.at, sid: row.sid, mid: row.mid, runID: row.runID, role: row.role,
                            content: String(row.content.suffix(Self.convCharBudget - row.role.count - 4)), peers: row.peers, lived: row.lived)
                    }
                    let length = rowLength(entry.row)
                    guard count < Self.convCountLimit, used + length <= Self.convCharBudget else { break }
                    pickedEntries.append(entry)
                    used += length
                    count += 1
                }
                newest = exchange.at
                moreMessagesRemain = index + 1 < exchanges.count
            } else {
                stoppedAt = exchange.at
                moreMessagesRemain = true
            }
            break
        }
        // An unread exchange ending at the same instant as the last one read stays eligible: the mark stops just before that instant and
        // the exchanges read at it come again. When every exchange read shares that instant, the mark moves past it so the night advances.
        if let last = newest, stoppedAt == last, let first = firstAt, first < last {
            newest = last.addingTimeInterval(-0.001)
        }
        // Restore chronology so the dream reads a day rather than a ranking.
        pickedEntries.sort { $0.index < $1.index }
        // Rows remain citable without a run; only known runs establish exchange grouping.
        var sourcesByIndex: [Int: DreamSourceRef] = [:]
        var material: [String: CognitiveReflectionCause] = [:]
        for (index, row) in pickedEntries {
            guard let mid = row.mid, !mid.isEmpty else { continue }
            let source = DreamSourceRef(
                kind: row.runID == nil ? "message" : "exchange",
                id: row.runID ?? mid, sessionID: row.sid,
                livedDate: DreamEntryProvenance.dateStem(for: row.at), messageID: row.runID == nil ? nil : mid)
            sourcesByIndex[index] = source
            material[source.reference] = CognitiveReflectionCause(text: "\(row.role):\n\(row.content)", sourcePeerIds: row.peers)
        }
        let sources = pickedEntries.compactMap { sourcesByIndex[$0.index] }
        return (
            pickedEntries.map { ($0.row.sid, $0.row.role, $0.row.content, sourcesByIndex[$0.index]?.reference) },
            newest,
            sources,
            material,
            moreMessagesRemain
        )
    }

    // Exclude tool-call rows before prompt assembly so tool-heavy days cannot dilute identity input.
    private static let identityRoles: Set<String> = ["user", "assistant"]


}
