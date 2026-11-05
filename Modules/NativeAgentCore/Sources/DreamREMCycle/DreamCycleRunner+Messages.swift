import Foundation
import NativeAgentCore
import PersistenceCore
import Transcripts
import CognitiveSubstrate
// Blueprint: | `DreamCycleRunner+Messages.swift` | `DreamCycleRunner`, `gatherRecentMessagesAcrossSessions`, `feltRankIndex`. |

extension DreamCycleRunner {
    private static let convCharBudget: Int = 80_000
    private static let convCountLimit: Int = 300

    // MARK: cross-session message gather

    /// Gather eligible conversation across sessions before sampling whole exchanges by felt rank and recency.
    /// Use checked occurrence times and return the newest eligible timestamp for the next mark; tool/system rows are not identity input.
    /// An absent felt rank contributes no feeling weight while recency still orders eligible conversation.
    func gatherRecentMessagesAcrossSessions(
        since mark: Date,
        feltRank: [String: Int] = [:]
    ) throws -> (
        messages: [(sessionId: String, role: String, content: String, source: String?)],
        newest: Date?,
        sources: [DreamSourceRef],
        material: [String: CognitiveReflectionCause]
    ) {
        let messagesDir = dataRoot.appendingPathComponent("chat", isDirectory: true)
            .appendingPathComponent("messages", isDirectory: true)
        let names: [String]
        do { names = try fm.contentsOfDirectory(atPath: messagesDir.path) }
        catch CocoaError.fileReadNoSuchFile { return ([], nil, [], [:]) }
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
                guard let at = ConversationHistory.parseTimestamp(obj["createdAt"]) else {
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
        // Select whole exchanges, preserving session reach before spending remaining room on feeling weight.
        struct Exchange {
            let sid: String
            let start: Int
            var rows: [(index: Int, row: Row)]
            var at: Date
            var weight: Double
            var length: Int
        }
        // Rank zero carries the strongest recorded feeling; unranked rows carry no felt weight.
        func weight(of row: Row) -> Double {
            guard !feltRank.isEmpty, let mid = row.mid, !mid.isEmpty else { return 0 }
            guard let rank = feltRank["\(row.sid):\(mid)"] ?? feltRank[mid] else { return 0 }
            return 1.0 / Double(1 + max(0, rank))
        }
        func rowLength(_ row: Row) -> Int { row.role.count + row.content.count + 4 }

        var rowsBySession: [String: [(index: Int, row: Row)]] = [:]
        for (index, row) in all.enumerated() {
            rowsBySession[row.sid, default: []].append((index, row))
        }
        var exchanges: [Exchange] = []
        let grouped = Dictionary(grouping: all.enumerated(), by: { exchangeByIndex[$0.offset] })
        for entries in grouped.values {
            let rows = entries.map { (index: $0.offset, row: $0.element) }
            guard let first = rows.first else { continue }
            exchanges.append(Exchange(sid: first.row.sid, start: first.index, rows: rows,
                at: rows.map { $0.row.at }.max() ?? first.row.at,
                weight: rows.reduce(0) { $0 + weight(of: $1.row) }, length: rows.reduce(0) { $0 + rowLength($1.row) }))
        }
        exchanges.removeAll { $0.at <= mark }
        var exchangeIndicesBySession: [String: [Int]] = [:]
        for index in exchanges.indices {
            exchangeIndicesBySession[exchanges[index].sid, default: []].append(index)
        }
        // Resolve equal feeling weight by recency and stable structural identity.
        func moreMeaningful(_ lhs: Exchange, _ rhs: Exchange) -> Bool {
            if lhs.weight != rhs.weight { return lhs.weight > rhs.weight }
            if lhs.at != rhs.at { return lhs.at > rhs.at }
            if lhs.sid != rhs.sid { return lhs.sid < rhs.sid }
            return lhs.start < rhs.start
        }

        var takenExchanges = Set<Int>()
        var pickedEntries: [(index: Int, row: Row)] = []
        var used = 0
        var count = 0
        // Skip an oversized whole exchange rather than ending selection so one conversation cannot swallow the day's reach.
        func take(_ exchangeIndex: Int) {
            guard !takenExchanges.contains(exchangeIndex) else { return }
            let exchange = exchanges[exchangeIndex]
            guard count + exchange.rows.count <= Self.convCountLimit,
                  used + exchange.length <= Self.convCharBudget else { return }
            takenExchanges.insert(exchangeIndex)
            pickedEntries.append(contentsOf: exchange.rows)
            used += exchange.length
            count += exchange.rows.count
        }

        // Cover newest-active sessions first when the budget cannot reach every session.
        let sessionOrder = exchangeIndicesBySession.keys.sorted { lhs, rhs in
            let lat = rowsBySession[lhs]?.last?.row.at ?? .distantPast
            let rat = rowsBySession[rhs]?.last?.row.at ?? .distantPast
            if lat != rat { return lat > rat }
            return lhs < rhs
        }
        for sid in sessionOrder {
            guard let indices = exchangeIndicesBySession[sid],
                  let best = indices.max(by: { moreMeaningful(exchanges[$1], exchanges[$0]) })
            else { continue }
            take(best)
        }
        // Spend remaining room on the strongest felt exchanges regardless of their window position.
        for exchangeIndex in exchanges.indices.sorted(by: { moreMeaningful(exchanges[$0], exchanges[$1]) }) {
            if count >= Self.convCountLimit { break }
            take(exchangeIndex)
        }
        if pickedEntries.isEmpty, !exchanges.isEmpty {
            throw DreamREMCycleError.oversizedConversationInput
        }
        // Restore chronology so the dream reads a day rather than a ranking.
        pickedEntries.sort { $0.index < $1.index }
        let picked = pickedEntries.map(\.row)
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
        // Advance across all eligible rows so budget-omitted old material cannot enter the next dream as new.
        return (
            pickedEntries.map { ($0.row.sid, $0.row.role, $0.row.content, sourcesByIndex[$0.index]?.reference) },
            picked.isEmpty ? nil : all.last?.at,
            sources,
            material
        )
    }

    /// First strongest-felt occurrence wins per canonical origin key; accept session/message and bare message IDs from the same owner.
    /// Origins without a message cannot rank transcript rows.
    static func feltRankIndex(from origins: [CognitiveFeltOrigin]) -> [String: Int] {
        var index: [String: Int] = [:]
        for (rank, origin) in origins.enumerated() {
            var keys: [String] = []
            let subjectID = origin.subjectID.trimmingCharacters(in: .whitespacesAndNewlines)
            if subjectID.contains(":") {
                keys.append(subjectID)
            }
            let sessionID = origin.metadata["sessionId"]?
                .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            let messageID = origin.metadata["messageId"]?
                .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            if !sessionID.isEmpty, !messageID.isEmpty { keys.append("\(sessionID):\(messageID)") }
            if !messageID.isEmpty { keys.append(messageID) }
            for key in keys where index[key] == nil { index[key] = rank }
        }
        return index
    }

    // Exclude tool-call rows before prompt assembly so tool-heavy days cannot dilute identity input.
    private static let identityRoles: Set<String> = ["user", "assistant"]


}
