import Foundation
import NativeAgentCore
import PersistenceCore

extension DreamCycleRunner {
    private static let convCharBudget: Int = 80_000
    private static let convCountLimit: Int = 300

    // MARK: cross-session message gather

    /// Merge user/assistant messages from EVERY session whose createdAt is after
    /// `mark`, sort globally by time, and keep the most-recent `convCountLimit` /
    /// `convCharBudget`. Per-row timestamp prefers the row's `createdAt`, falling
    /// back to the file's mtime for legacy rows that lack it (so old-shape JSONL
    /// still orders + dedups). Returns the picked messages (chronological) plus
    /// the newest timestamp included (the next mark). Tool/system rows excluded.
    func gatherRecentMessagesAcrossSessions(
        since mark: Date
    ) -> (messages: [(sessionId: String, role: String, content: String)], newest: Date?) {
        let messagesDir = dataRoot.appendingPathComponent("chat", isDirectory: true)
            .appendingPathComponent("messages", isDirectory: true)
        guard let names = try? fm.contentsOfDirectory(atPath: messagesDir.path) else {
            return ([], nil)
        }
        struct Row { let at: Date; let sid: String; let role: String; let content: String }
        var all: [Row] = []
        for name in names where name.hasSuffix(".jsonl") {
            let url = messagesDir.appendingPathComponent(name)
            let attrs = try? fm.attributesOfItem(atPath: url.path)
            let mtime = (attrs?[.modificationDate] as? Date) ?? .distantPast
            // Cheap prefilter: skip files clearly older than the mark so a
            // months-old session archive isn't re-parsed every night. A 1h
            // slack absorbs the rare case where a row's createdAt runs slightly
            // AHEAD of the file mtime (clock skew on append) — without it the
            // whole file could be skipped while holding a genuinely-new row
            // (gpt-5.5 review, 2026-06-16). The per-row `at <= mark` check below
            // is the real gate; this only avoids needless reads.
            if mtime.addingTimeInterval(3600) <= mark { continue }
            let sid = (name as NSString).deletingPathExtension
            guard let data = try? Data(contentsOf: url),
                  let text = String(data: data, encoding: .utf8) else { continue }
            for line in text.split(separator: "\n", omittingEmptySubsequences: true) {
                let s = String(line).trimmingCharacters(in: .whitespacesAndNewlines)
                guard !s.isEmpty, let d = s.data(using: .utf8),
                      let parsed = try? JSONValue.parse(d),
                      case .object(let obj) = parsed else { continue }
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
                        role: Self.recollectionRole,
                        content: recollection.text
                    ))
                    continue
                }
                var role = "user"
                var content = ""
                if case .string(let r)? = obj["role"] { role = r }
                if case .string(let c)? = obj["content"] { content = c }
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
                all.append(Row(at: at, sid: sid, role: role, content: content))
            }
        }
        all.sort { $0.at < $1.at }
        // Keep the most-recent messages within the count + char budgets
        // (tail-first walk, then restore chronological order). INTENTIONAL drop:
        // on a gap with more than convCountLimit new messages, the OLDEST
        // overflow (older than picked.first) is not dreamed and the mark advances
        // past it — a reflective journal weights the most recent stretch, and
        // this matches the old per-session budget's drop-oldest behavior. In
        // practice a since-last-dream window rarely exceeds the cap.
        var picked: [Row] = []
        var used = 0
        var count = 0
        for r in all.reversed() {
            if count >= Self.convCountLimit { break }
            let lineLen = r.role.count + r.content.count + 4
            if used + lineLen > Self.convCharBudget { break }
            picked.append(r)
            used += lineLen
            count += 1
        }
        picked.reverse()
        return (picked.map { ($0.sid, $0.role, $0.content) }, picked.last?.at)
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
