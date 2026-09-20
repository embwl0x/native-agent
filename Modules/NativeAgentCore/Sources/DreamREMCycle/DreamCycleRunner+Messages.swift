import Foundation
import NativeAgentCore
import PersistenceCore

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
        messages: [(sessionId: String, role: String, content: String)],
        newest: Date?,
        sources: [DreamSourceRef]
    ) {
        let messagesDir = dataRoot.appendingPathComponent("chat", isDirectory: true)
            .appendingPathComponent("messages", isDirectory: true)
        let names: [String]
        do { names = try fm.contentsOfDirectory(atPath: messagesDir.path) }
        catch CocoaError.fileReadNoSuchFile { return ([], nil, []) }
        struct Row { let at: Date; let sid: String; let mid: String?; let role: String; let content: String }
        var all: [Row] = []
        for name in names where name.hasSuffix(".jsonl") {
            let url = messagesDir.appendingPathComponent(name)
            let attrs = try fm.attributesOfItem(atPath: url.path)
            let mtime = (attrs[.modificationDate] as? Date) ?? .distantPast
            // Cheap prefilter: skip files clearly older than the mark so a
            // months-old session archive isn't re-parsed every night. A 1h
            // slack absorbs the rare case where a row's createdAt runs slightly
            // AHEAD of the file mtime (clock skew on append) — without it the
            // whole file could be skipped while holding a genuinely-new row
            // (gpt-5.5 review, 2026-06-16). The per-row `at <= mark` check below
            // is the real gate; this only avoids needless reads.
            if mtime.addingTimeInterval(3600) <= mark { continue }
            let sid = (name as NSString).deletingPathExtension
            let text = try String(contentsOf: url, encoding: .utf8)
            for line in text.split(separator: "\n", omittingEmptySubsequences: true) {
                let s = String(line).trimmingCharacters(in: .whitespacesAndNewlines)
                if s.isEmpty { continue }
                let parsed = try JSONValue.parse(Data(s.utf8))
                guard case .object(let obj) = parsed else {
                    throw PersistenceCoreError.ioFailure("transcript row is not an object: \(url.path)")
                }
                // ONE consolidation owner (NORTHSTAR clause 1, sweep item 45).
                // The chat lane distills a session's older turns into
                // recollection rows as they age — those raw turns are GONE from
                // the transcript, and the recollection is what remains of them.
                // The dream reads that row instead of re-summarizing the same
                // stretch of life a second time.
                //
                // The mark comparison uses `consolidatedThrough` — the newest
                // turn the recollection COVERS — never the row's own write
                // time. A recollection written today can stand for turns from
                // last week; comparing against its write time would re-dream
                // material this lane already consumed raw.
                if let recollection = ChatSessionRecollections.recollection(
                    fromTranscriptRow: parsed,
                    sessionId: sid
                ) {
                    let coveredThrough = recollection.consolidatedThrough ?? mtime
                    if coveredThrough <= mark { continue }
                    // DEFENSIVE (the writer clamps so this row is never made):
                    // a recollection that STRADDLES the mark would be admitted
                    // whole, re-dreaming the pre-mark stretch this lane already
                    // consumed raw. Refuse it and say so, rather than double
                    // count. A legacy straddling row loses its post-mark tail —
                    // cheaper than counting its head twice.
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
                        role: Self.recollectionRole,
                        content: recollection.text
                    ))
                    continue
                }
                var role = "user"
                var content = ""
                var messageId: String?
                if case .string(let r)? = obj["role"] { role = r }
                if case .string(let c)? = obj["content"] { content = c }
                // The row's own id — the join key back to the substrate's felt
                // origins (`metadata["messageId"]` / `subject.id`). Read only;
                // it never reaches the prompt.
                if case .string(let mid)? = obj["id"] { messageId = mid }
                if content.isEmpty { continue }
                // Only her + the user's turns shape identity (tool/system rows dropped).
                if !Self.identityRoles.contains(role.lowercased()) { continue }
                let at: Date = {
                    if case .string(let ca)? = obj["createdAt"], let p = Self.parseDaemonISO(ca) {
                        return p
                    }
                    return mtime
                }()
                if at <= mark { continue }   // already dreamed — skip
                all.append(Row(at: at, sid: sid, mid: messageId, role: role, content: content))
            }
        }
        all.sort { $0.at < $1.at }
        // SELECTION — "diverse for reach, weighted for meaning" (Agent,
        // 2026-09-13). The old walk was newest-first until the budget filled,
        // so one verbose evening erased every quieter conversation of the day
        // from the material that eventually shapes GROWTH. A day is not evenly
        // distributed either, so this does not flatten it to an even spread:
        //   1. REACH — one exchange from every session that has new material,
        //      strongest-felt in that session first.
        //   2. MEANING — the rest of the budget goes to the remaining exchanges
        //      in descending feeling weight (ties break toward recent).
        // The unit is an EXCHANGE (a user line with the replies that follow it),
        // never a lone row, so the dream never reads half a turn. Ordering is
        // total and value-derived at every step — no RNG, so the same window
        // always produces the same selection without a seed to carry. Budgets,
        // the tool-row exclusion and the mark arithmetic below are unchanged.
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
        var exchangeIndicesBySession: [String: [Int]] = [:]
        for sid in rowsBySession.keys.sorted() {
            var current: Exchange?
            for entry in rowsBySession[sid] ?? [] {
                let role = entry.row.role.lowercased()
                let isRecollection = entry.row.role == Self.recollectionRole
                let breaks: Bool = {
                    guard let open = current else { return true }
                    // A recollection stands for a whole stretch of life; it is
                    // its own unit on both sides.
                    if isRecollection { return true }
                    if open.rows.last?.row.role == Self.recollectionRole { return true }
                    // A new user line opens a new exchange once the open one has
                    // already been answered.
                    return role == "user" && open.rows.contains { $0.row.role.lowercased() != "user" }
                }()
                if breaks {
                    if let open = current {
                        exchangeIndicesBySession[open.sid, default: []].append(exchanges.count)
                        exchanges.append(open)
                    }
                    current = Exchange(
                        sid: sid,
                        start: entry.index,
                        rows: [entry],
                        at: entry.row.at,
                        weight: weight(of: entry.row),
                        length: rowLength(entry.row)
                    )
                } else {
                    current?.rows.append(entry)
                    current?.at = entry.row.at
                    current?.weight += weight(of: entry.row)
                    current?.length += rowLength(entry.row)
                }
            }
            if let open = current {
                exchangeIndicesBySession[open.sid, default: []].append(exchanges.count)
                exchanges.append(open)
            }
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
        // FALLBACK — a window whose every exchange is individually too large
        // would otherwise read as "nothing new" and burn the night. Fall back to
        // the old newest-first row walk rather than lose the dream.
        if pickedEntries.isEmpty {
            for (index, row) in all.enumerated().reversed() {
                if count >= Self.convCountLimit { break }
                let lineLen = rowLength(row)
                if used + lineLen > Self.convCharBudget { break }
                pickedEntries.append((index, row))
                used += lineLen
                count += 1
            }
        }
        // Restore chronological order — the dream reads a day, not a ranking.
        pickedEntries.sort { $0.index < $1.index }
        let picked = pickedEntries.map(\.row)
        // PROVENANCE (item 4). The rows that actually fed this dream, each with
        // the date it HAPPENED. The dream used to keep only `picked.count`'s
        // session count; a count cannot distinguish one night dreamt three
        // times from three nights each dreamt once, and REM was reading the
        // difference off the dream dates — the one place it is not written.
        // Read-only: none of this reaches the prompt.
        let sources: [DreamSourceRef] = picked.compactMap { row in
            guard let mid = row.mid?.trimmingCharacters(in: .whitespacesAndNewlines),
                  !mid.isEmpty else { return nil }
            return DreamSourceRef(
                kind: row.role == Self.recollectionRole ? "recollection" : "message",
                id: mid,
                sessionID: row.sid,
                livedDate: DreamEntryProvenance.dateStem(for: row.at)
            )
        }
        // MARK ARITHMETIC IS UNCHANGED. The old walk always included the newest
        // row in the window, so its `picked.last?.at` WAS `all.last?.at`; the
        // mark advanced past everything older that the budget dropped. Sampling
        // can leave the newest row out, so the newest row IN THE WINDOW is named
        // explicitly here. Same value as before, same intentional drop: omitted
        // older material is not re-dreamed on the next pass.
        return (
            picked.map { ($0.sid, $0.role, $0.content) },
            picked.isEmpty ? nil : all.last?.at,
            sources
        )
    }

    /// Rank the substrate's felt origins into the lookup the sampler weights by.
    /// `feltDayOrigins` is already ordered strongest-felt-first, so a subject's
    /// position IS its feeling weight and the first entry for a key wins. Keyed
    /// both by `"<sessionId>:<messageId>"` and by bare `messageId` because a
    /// node carries the pair in `subject.id`, in metadata, or in both.
    /// Origins with no message to point at (studio entries, say) rank nothing —
    /// they are cited elsewhere and there is no transcript row to weight.
    static func feltRankIndex(from origins: [DreamFeltOrigin]) -> [String: Int] {
        var index: [String: Int] = [:]
        for (rank, origin) in origins.enumerated() {
            var keys: [String] = []
            if let subjectID = origin.subjectID?.trimmingCharacters(in: .whitespacesAndNewlines),
               subjectID.contains(":") {
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

    /// Parse the daemon's ISO8601 createdAt shape. Live JSONL uses
    /// microsecond precision (`2026-05-07T11:33:32.167835+00:00`), but
    /// `ISO8601DateFormatter.withFractionalSeconds` only accepts 3-digit
    /// fractions. Try fractional, plain, then truncate to milliseconds.
    /// Returns nil only on truly unparseable input — that case keeps the
    /// row, mirroring the daemon's "no createdAt → don't filter" rule.
    /// Public so the BackgroundLoopsAssembly Self-half provider can reuse
    /// it without duplicating the regex (the duplicate inline copy drifted
    /// — see pass-3 review).
    public static func parseDaemonISO(_ raw: String) -> Date? {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        let isoFrac = ISO8601DateFormatter()
        isoFrac.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        if let d = isoFrac.date(from: trimmed) { return d }
        let isoPlain = ISO8601DateFormatter()
        isoPlain.formatOptions = [.withInternetDateTime]
        if let d = isoPlain.date(from: trimmed) { return d }
        // Microsecond fallback: truncate the fractional component to 3
        // digits and retry the fractional parser. Match the timezone
        // suffix (`Z` or `±HH:MM`/`±HHMM`) so we splice cleanly.
        if let dotRange = trimmed.range(of: "."),
           let tzMatch = trimmed.range(
               of: #"([Zz]|[+-]\d{2}:?\d{2})$"#,
               options: .regularExpression
           ),
           tzMatch.lowerBound > dotRange.upperBound {
            let fracStart = dotRange.upperBound
            let frac = trimmed[fracStart..<tzMatch.lowerBound]
            if frac.count > 3 {
                let truncated = String(trimmed[..<fracStart])
                    + String(frac.prefix(3))
                    + String(trimmed[tzMatch.lowerBound...])
                return isoFrac.date(from: truncated)
            }
        }
        return nil
    }

}
