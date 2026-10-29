import Foundation
import NativeAgentCore
import PersistenceCore
import Transcripts
import CognitiveSubstrate
// Blueprint: | `DreamCycleRunner+Messages.swift` | `DreamCycleRunner`: `gatherRecentMessagesAcrossSessions`, `feltRankIndex`; timestamps read through ChatSessionRecollections |

extension DreamCycleRunner {
    private static let convCharBudget: Int = 80_000
    private static let convCountLimit: Int = 300

    // MARK: cross-session message gather

    /// Merge user/assistant messages from EVERY session whose createdAt is after
    /// `mark`, then SAMPLE them into the `convCountLimit` / `convCharBudget`
    /// budget: reach across sessions first, then weight by what carried feeling.
    /// Per-row timestamp prefers the row's `createdAt`, falling back to the
    /// file's mtime for legacy rows that lack it (so old-shape JSONL still
    /// orders + dedups). Returns the picked messages (chronological) plus the
    /// newest timestamp in the window (the next mark). Tool/system rows excluded.
    ///
    /// `feltRank` is the rank of a felt node's origin in the substrate's
    /// strongest-felt-first order (`feltDayOrigins`), keyed by
    /// `"<sessionId>:<messageId>"` and by bare `messageId`. It is the runtime's
    /// existing record of the exchanges that moved her — inner-state shifts,
    /// flagged moments and corrections all mint felt nodes — and nothing here
    /// persists anything new. Empty means "nothing felt": reach still holds and
    /// the fill falls back to recency, which is the old behaviour.
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
        struct Row { let at: Date; let sid: String; let mid: String?; let runID: String?; let role: String; let content: String; let peers: [String]?; var lived = true }
        var all: [Row] = []
        for name in names where name.hasSuffix(".jsonl") {
            let url = messagesDir.appendingPathComponent(name)
            let attrs = try fm.attributesOfItem(atPath: url.path)
            let mtime = (attrs[.modificationDate] as? Date) ?? .distantPast
            // File prefiltering allows one hour of clock skew; the exchange timestamp remains the real gate.
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
                // Recollections replace aged turns; gate them by consolidatedThrough, never by their write time.
                if let recollection = ChatSessionRecollections.recollection(
                    fromTranscriptRow: parsed,
                    sessionId: sid
                ) {
                    let coveredThrough = recollection.consolidatedThrough ?? mtime
                    if coveredThrough <= mark { continue }
                    // Reject recollections straddling the mark to avoid dreaming consumed material twice.
                    if ChatSessionRecollections.straddles(recollection, mark: mark) {
                        FileHandle.standardError.write(Data(
                            "DreamCycleRunner: skipped recollection straddling the dream mark (session \(sid), row \(recollection.rowId ?? "?"))\n".utf8
                        ))
                        continue
                    }
                    all.append(Row(
                        at: coveredThrough,
                        sid: sid,
                        mid: recollection.rowId,
                        runID: nil,
                        role: Self.recollectionRole,
                        content: recollection.text,
                        peers: DreamEntryProvenance.transcriptCause(obj, session: sid, dataRoot: dataRoot)?.sourcePeerIds
                    ))
                    continue
                }
                var role = "unknown"
                var content = ""
                var messageId: String?
                if case .string(let r)? = obj["role"] { role = r.lowercased() }
                if case .string(let c)? = obj["content"] { content = c }
                // The row's own id — the join key back to the substrate's felt
                // origins (`metadata["messageId"]` / `subject.id`) and to the
                // claim's source lineage.
                if case .string(let mid)? = obj["id"] { messageId = mid }
                if content.isEmpty { continue }
                // Only her + the user's turns shape identity (tool/system rows dropped).
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
                let at: Date = {
                    if let p = ChatSessionRecollections.parseTimestamp(obj["createdAt"]) {
                        return p
                    }
                    return mtime
                }()
                // Keep admitted origins until exchanges are formed. A new
                // reply can belong to an origin just before the watermark.
                all.append(Row(at: at, sid: sid, mid: messageId, runID: runID, role: role, content: content,
                    peers: DreamEntryProvenance.transcriptCause(obj, session: sid, dataRoot: dataRoot)?.sourcePeerIds, lived: lived))
            }
        }
        let paired = ChatSessionRecollections.pairExchanges(all.map { ($0.sid, $0.runID, $0.role, $0.lived) })
        let ordered = paired.map { (exchange: $0.exchange, row: all[$0.row]) }.sorted { $0.row.at < $1.row.at }
        let exchangeByIndex = ordered.map(\.exchange)
        all = ordered.map(\.row)
        // Select whole exchanges deterministically: strongest felt per session first, then feeling weight with recent ties.
        //
        // One indexed unit of conversation, kept whole.
        struct Exchange {
            let sid: String
            let start: Int
            var rows: [(index: Int, row: Row)]
            var at: Date
            var weight: Double
            var length: Int
        }
        // A row's feeling weight: its rank among the substrate's felt origins,
        // strongest first, so rank 0 (the day's most-felt turn) weighs most.
        // Unfelt rows weigh nothing and are reached only by phase 1 or by the
        // recency tiebreak — exactly the "shaped by what moved me, not by what
        // was busiest or what was last" rule.
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
        // Felt first, then recent, then a stable structural tiebreak.
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
        // An exchange is taken WHOLE or not at all. A unit that cannot fit is
        // skipped rather than ending the walk, so one outsized conversation
        // cannot swallow the rest of the day's reach.
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

        // PHASE 1 — reach. Newest-active session first so a budget too small to
        // cover every session still covers the ones alive today.
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
        // PHASE 2 — meaning. Spend what's left on the most-felt remaining
        // exchanges, wherever in the window they happened.
        for exchangeIndex in exchanges.indices.sorted(by: { moreMeaningful(exchanges[$0], exchanges[$1]) }) {
            if count >= Self.convCountLimit { break }
            take(exchangeIndex)
        }
        if pickedEntries.isEmpty, !exchanges.isEmpty {
            throw DreamREMCycleError.oversizedConversationInput
        }
        // Restore chronological order — the dream reads a day, not a ranking.
        pickedEntries.sort { $0.index < $1.index }
        let picked = pickedEntries.map(\.row)
        // Rows remain citable without a run; only known runs establish exchange grouping.
        var sourcesByIndex: [Int: DreamSourceRef] = [:]
        var material: [String: CognitiveReflectionCause] = [:]
        for (index, row) in pickedEntries {
            let recollection = row.role == Self.recollectionRole
            guard let mid = row.mid, !mid.isEmpty else { continue }
            let source = DreamSourceRef(
                kind: recollection ? "recollection" : row.runID == nil ? "message" : "exchange",
                id: row.runID ?? mid, sessionID: row.sid,
                livedDate: DreamEntryProvenance.dateStem(for: row.at), messageID: row.runID == nil ? nil : mid)
            sourcesByIndex[index] = source
            material[source.reference] = CognitiveReflectionCause(text: "\(row.role):\n\(row.content)", sourcePeerIds: row.peers)
        }
        let sources = pickedEntries.compactMap { sourcesByIndex[$0.index] }
        // The mark covers the newest eligible row, including material the
        // budget omitted, so omitted older material is not dreamed next pass.
        return (
            pickedEntries.map { ($0.row.sid, $0.row.role, $0.row.content, sourcesByIndex[$0.index]?.reference) },
            picked.isEmpty ? nil : all.last?.at,
            sources,
            material
        )
    }

    /// Rank the substrate's felt origins into the lookup the sampler weights by.
    /// `feltDayOrigins` is already ordered strongest-felt-first, so a subject's
    /// position IS its feeling weight and the first entry for a key wins. Keyed
    /// both by `"<sessionId>:<messageId>"` and by bare `messageId` because a
    /// node carries the pair in `subject.id`, in metadata, or in both.
    /// Origins with no message to point at (studio entries, say) rank nothing —
    /// they are cited elsewhere and there is no transcript row to weight.
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

    // Tool-call rows are NOT identity input — only her own turns and the
    // user's turns shape who she is. Drop tool/tool_use/tool_result rows
    // BEFORE feeding to the dream prompt so a tool-heavy day doesn't dilute
    // the World-half with tool exhaust. (See the vault skill — this is the
    // "tool calls are excluded" invariant.)
    private static let identityRoles: Set<String> = ["user", "assistant"]

    /// The role label a consolidated recollection carries into the dream
    /// prompt. Deliberately NOT "assistant": it is her own memory of a stretch
    /// of life, not a turn she took, and the World half should read it as such.
    static let recollectionRole = "recollection"

}
