import Foundation
import NativeAgentCore
import PersistenceCore

/// Bounded launch repair for the one unavoidable two-file chat commit window:
/// a transcript row is durable before `sessions.json` is synchronized. This
/// reconciler never rewrites transcript bytes and refuses to operate when the
/// shared index itself is damaged.
public struct ChatSessionIndexReconciliationReport: Sendable, Equatable {
    public var transcriptsExamined = 0
    public var sessionsRecovered = 0
    public var corruptTranscripts = 0
    public var skippedForBounds = 0
    /// Rows that survived the crash but described the transcript wrongly —
    /// stale `messageCount`, `lastMessagePreview`, or `updatedAt` — and were
    /// rewritten from the transcript. See the stale-row pass in `reconcile`.
    public var staleRowsRepaired = 0

    public init() {}
}

public actor ChatSessionIndexReconciler {
    private let dataRoot: URL
    private let persistence: SwiftNativePersistenceCore

    public init(
        dataRoot: URL = PersistenceCore.defaultDataRoot(),
        persistence: SwiftNativePersistenceCore = SwiftNativePersistenceCore()
    ) {
        self.dataRoot = dataRoot
        self.persistence = persistence
    }

    /// Index row key: the transcript modification time this row was last
    /// proven to agree with. Purely a reconciler stamp — no other reader keys
    /// on it, and a writer that drops it only costs one extra stat-gated read.
    static let transcriptStampKey = "reconciledTranscriptModifiedAt"

    /// How far a transcript's mtime may lead its row's `updatedAt` before the
    /// row is treated as stale. The live writer mints `updatedAt` from a
    /// timestamp taken just BEFORE the append it describes, so on a perfectly
    /// healthy row the file is always a little newer than the row it produced —
    /// one serialize plus one `F_FULLFSYNC`. Only a wider gap is evidence of an
    /// index write that never happened.
    static let transcriptStampTolerance: TimeInterval = 2

    /// 2026-09-06: wall-clock ceiling on the stale pass's transcript reads.
    /// The index lock is released before them, but each read still waits on
    /// that transcript's own lock, whose contention loop has no deadline
    /// (`PersistenceCore+FileLock`). Launch repair is opportunistic: stop
    /// looking after this long and leave the rest to the next launch.
    static let staleReadCeiling: TimeInterval = 5

    /// A row the stat gate tripped, picked under the index lock and read after
    /// it is released. `updatedAt`/`stamp` are the values the selection was
    /// made from, re-checked before the repair is written.
    private struct StaleCandidate: Sendable {
        let sessionID: String
        let url: URL
        let modified: Date
        let updatedAt: JSONValue?
        let stamp: JSONValue?
    }

    private struct StaleRead: Sendable {
        let bytes: Int64
        let rows: [JSONValue]
        let readReport: JSONLReadReport
    }

    private struct StaleRepair: Sendable {
        let candidate: StaleCandidate
        let messageCount: Int64
        let preview: String
        /// 2026-09-06: whether the transcript held a conversational row AT ALL.
        /// An empty `preview` used to mean both "no user/assistant row" and
        /// "the last one has no readable string content" (a structured or
        /// empty body), and the repair cleared the row's preview for both — so
        /// a live conversation whose last turn carried non-string content lost
        /// its sidebar line on the phone and the Mac.
        let hasConversationalRow: Bool
        let lastSpokenStamp: String?
    }

    private struct SelectionPass: Sendable {
        var report: ChatSessionIndexReconciliationReport
        var candidates: [StaleCandidate]
        var consumedBytes: Int64
    }

    public func reconcile(
        maximumFiles: Int = 256,
        maximumBytes: Int64 = 32 * 1_024 * 1_024,
        maximumStaleRepairs: Int = 50
    ) async throws -> ChatSessionIndexReconciliationReport {
        let sessionsPath = dataRoot.appendingPathComponent("chat/sessions.json")
        let messagesDirectory = dataRoot.appendingPathComponent("chat/messages", isDirectory: true)
        guard FileManager.default.fileExists(atPath: messagesDirectory.path) else { return .init() }

        // PASS 1 — under the index lock: recover rows that are missing
        // entirely, and pick the stale-row candidates by STAT ONLY.
        //
        // 2026-09-06: the stale pass used to read its transcripts here too,
        // holding `sessions.json` across every one of them and across the
        // nested transcript locks, whose contention loop has no deadline
        // (`PersistenceCore+FileLock`). A live append at launch takes the same
        // index lock (`syncSessionIndex`), so it could wait on the whole pass.
        // Selecting by stat is cheap and safe to hold the lock for; reading is
        // not, so it happens below with the index lock released.
        let selection = try await persistence.withFileLock(sessionsPath) { () -> SelectionPass in
            var report = ChatSessionIndexReconciliationReport()
            var rows = try ChatSessionIndexFile.loadObjectRowsForMutation(at: sessionsPath)
            var knownIDs = Set(rows.compactMap { row -> String? in
                guard case .string(let raw)? = row["id"],
                      NativeAgentChatSessionID.normalizedPathComponent(raw) == raw else { return nil }
                return raw
            })

            let directoryEntries = try FileManager.default.contentsOfDirectory(
                at: messagesDirectory,
                includingPropertiesForKeys: [
                    .isRegularFileKey, .isSymbolicLinkKey, .fileSizeKey, .contentModificationDateKey,
                ],
                options: [.skipsHiddenFiles]
            ).filter { $0.pathExtension == "jsonl" }

            // This is a missing-index-row repair, not a transcript health
            // audit. A transcript whose normalized filename already has a
            // canonical index row cannot change the result below: the old
            // implementation still locked, read, JSON-parsed, and validated
            // every such file on every launch before reaching the final
            // `knownIDs` guard. On a healthy long-lived root that meant all
            // historical active transcripts and no repair. Keep invalid names
            // visible as corruption candidates, but remove known transcripts
            // before applying the bounded recovery budget.
            let candidates = directoryEntries.filter { transcript in
                let raw = transcript.deletingPathExtension().lastPathComponent
                guard NativeAgentChatSessionID.normalizedPathComponent(raw) == raw else {
                    return true
                }
                return !knownIDs.contains(raw)
            }.sorted { lhs, rhs in
                // Valid orphan IDs are the repair target. Examine them before
                // invalid filenames so a pile of damaged names cannot starve a
                // recoverable session under the file bound.
                func priority(_ url: URL) -> Int {
                    let raw = url.deletingPathExtension().lastPathComponent
                    return NativeAgentChatSessionID.normalizedPathComponent(raw) == raw ? 0 : 1
                }
                let lhsPriority = priority(lhs)
                let rhsPriority = priority(rhs)
                if lhsPriority != rhsPriority { return lhsPriority < rhsPriority }
                return lhs.lastPathComponent < rhs.lastPathComponent
            }

            let fileLimit = max(0, maximumFiles)
            let boundedCandidates = candidates.prefix(fileLimit)
            report.skippedForBounds += max(0, candidates.count - boundedCandidates.count)

            var consumedBytes: Int64 = 0
            var recovered: [[String: JSONValue]] = []
            for transcript in boundedCandidates {
                report.transcriptsExamined += 1
                let values = try transcript.resourceValues(
                    forKeys: [
                        .isRegularFileKey, .isSymbolicLinkKey, .fileSizeKey,
                        .contentModificationDateKey,
                    ]
                )
                guard values.isRegularFile == true, values.isSymbolicLink != true else {
                    report.corruptTranscripts += 1
                    continue
                }
                let fileBytes = Int64(values.fileSize ?? 0)
                guard maximumBytes >= 0, fileBytes >= 0,
                      consumedBytes <= maximumBytes,
                      fileBytes <= maximumBytes - consumedBytes else {
                    report.skippedForBounds += 1
                    continue
                }
                let rawID = transcript.deletingPathExtension().lastPathComponent
                guard let sessionID = NativeAgentChatSessionID.normalizedPathComponent(rawID),
                      sessionID == rawID else {
                    report.corruptTranscripts += 1
                    continue
                }
                consumedBytes += fileBytes

                let scan = try await persistence.withFileLock(transcript) {
                    try await persistence.readJSONLReporting(transcript)
                }
                let objectRows: [[String: JSONValue]] = scan.rows.compactMap {
                    guard case .object(let object) = $0 else { return nil }
                    return object
                }
                if scan.report.malformedLineCount > 0
                    || scan.report.trailingPartialLine
                    || !Self.rowsAreTrustworthy(
                        objectRows,
                        parsedRowCount: scan.rows.count,
                        sessionID: sessionID
                    ) {
                    report.corruptTranscripts += 1
                    continue
                }
                guard !knownIDs.contains(sessionID), !objectRows.isEmpty else { continue }

                guard let createdAt = Self.string(objectRows.first?["createdAt"])
                        ?? Self.string(objectRows.first?["timestamp"]) else {
                    report.corruptTranscripts += 1
                    continue
                }
                let updatedAt = Self.string(objectRows.last?["createdAt"])
                    ?? Self.string(objectRows.last?["timestamp"])
                    ?? createdAt
                let firstUserContent = objectRows.first(where: {
                    Self.string($0["role"])?.lowercased() == "user"
                }).flatMap { Self.string($0["content"]) }
                let lastContent = objectRows.last.flatMap { Self.string($0["content"]) } ?? ""
                // 2026-09-06: a session's `source` says what the conversation
                // IS, and the live writer stamps it ONCE at creation and never
                // restamps it (see the §1.3 note in
                // ChatOrchestrationClient+MessagePersistence). Recovering it
                // from the LAST row rebuilt exactly the last-writer-wins value
                // that note removed — a Mac chat one iPhone reply touched came
                // back as an iOS session. Take the creation row's source.
                //
                // 2026-09-06: the creation row is the first row a SURFACE
                // authored. Compaction PREPENDS a system row of its own
                // (ChatSessionAutocompactor writes source
                // "native_autocompaction"; TelegramSessionStore writes
                // "telegram_native_compaction"), so on any compacted session the
                // first physical row is the compactor, and taking it stamped the
                // compactor as the session's origin surface.
                let source = objectRows.first(where: { row in
                    guard Self.string(row["source"]) != nil else { return false }
                    return Self.string(row["role"])?.lowercased() != "system"
                }).flatMap { Self.string($0["source"]) } ?? "app"
                var recoveredRow: [String: JSONValue] = [
                    "id": .string(sessionID),
                    "title": .string(Self.bounded(firstUserContent ?? "Recovered Chat", to: 80)),
                    "source": .string(source),
                    "createdAt": .string(createdAt),
                    "updatedAt": .string(updatedAt),
                    "archived": .bool(false),
                    "messageCount": .int(Int64(objectRows.count)),
                    "summary": .string(""),
                ]
                let preview = Self.bounded(lastContent, to: 160)
                if !preview.isEmpty { recoveredRow["lastMessagePreview"] = .string(preview) }
                // 2026-09-06: stamp the transcript state this row was built
                // from, so the stale-row pass below does not re-open a file
                // this pass just finished reading, on this launch or any later
                // one. The mtime is the pre-read one: if the file moved under
                // the read, the stamp is behind and the next launch re-reads —
                // the safe direction.
                if let modified = values.contentModificationDate {
                    recoveredRow[Self.transcriptStampKey] = .string(Self.iso8601(modified))
                }
                recovered.append(recoveredRow)
                knownIDs.insert(sessionID)
                report.sessionsRecovered += 1
            }

            // 2026-09-06: STALE-ROW SELECTION. The scan above deliberately
            // never opens a transcript that already has a canonical index row —
            // re-reading all ~2000 of them at launch is exactly the cost this
            // reconciler removed. But the two-file commit window it repairs
            // has a second outcome, and this one leaves the row in place: the
            // transcript append is durable, the crash lands before
            // `syncSessionIndex` rewrites `sessions.json`, and the row
            // survives describing a transcript it no longer matches — short
            // `messageCount`, previous turn's `lastMessagePreview`, `updatedAt`
            // one message behind. Nothing repairs it later:
            // `ChatTranscriptLineCountCache` is in-memory and cold at launch,
            // and the row is only rewritten when the session is next appended
            // to, which for a finished conversation is never. Autocompaction
            // has the same shape — it rewrites the transcript and never touches
            // the index.
            //
            // The gate is a stat, not a read. Both sides are already in hand:
            // the row's `updatedAt` and the transcript's mtime, which the
            // directory enumeration above fetched with the size it was already
            // fetching. A transcript is opened only when its mtime leads the
            // moment its row was last known to agree with it. That moment is
            // `updatedAt` — or, once this pass has verified a row,
            // `reconciledTranscriptModifiedAt`, without which a compacted or
            // just-repaired session would be re-read on every launch forever.
            //
            // Bounded per launch, so a pile of stale rows cannot starve a
            // session that is missing from the sidebar entirely.
            var staleCandidates: [StaleCandidate] = []
            var staleRepairBudget = max(0, maximumStaleRepairs)
            if staleRepairBudget > 0 {
                var transcriptsByID: [String: (url: URL, modified: Date)] = [:]
                for entry in directoryEntries {
                    let raw = entry.deletingPathExtension().lastPathComponent
                    guard NativeAgentChatSessionID.normalizedPathComponent(raw) == raw,
                          let values = try? entry.resourceValues(forKeys: [
                              .isRegularFileKey, .isSymbolicLinkKey,
                              .contentModificationDateKey,
                          ]),
                          values.isRegularFile == true, values.isSymbolicLink != true,
                          let modified = values.contentModificationDate else { continue }
                    transcriptsByID[raw] = (entry, modified)
                }

                for row in rows {
                    guard case .string(let sessionID)? = row["id"],
                          let transcript = transcriptsByID[sessionID],
                          let agreedAt = Self.lastAgreement(with: row),
                          transcript.modified.timeIntervalSince(agreedAt)
                            > Self.transcriptStampTolerance else { continue }
                    guard staleRepairBudget > 0 else {
                        // Left for the next launch. The gate cost one stat.
                        report.skippedForBounds += 1
                        continue
                    }
                    staleRepairBudget -= 1
                    staleCandidates.append(
                        StaleCandidate(
                            sessionID: sessionID,
                            url: transcript.url,
                            modified: transcript.modified,
                            updatedAt: row["updatedAt"],
                            stamp: row[Self.transcriptStampKey]
                        )
                    )
                }
            }

            if !recovered.isEmpty {
                recovered.sort {
                    (Self.string($0["updatedAt"]) ?? "") > (Self.string($1["updatedAt"]) ?? "")
                }
                rows.insert(contentsOf: recovered, at: 0)
                let data = try ChatSessionIndexFile.serializedData(for: rows)
                try await persistence.writeDataAtomicDurable(data, to: sessionsPath)
            }
            return SelectionPass(
                report: report,
                candidates: staleCandidates,
                consumedBytes: consumedBytes
            )
        }

        var report = selection.report
        guard !selection.candidates.isEmpty else { return report }

        // PASS 2 — index lock RELEASED. Each tripped transcript is read under
        // its own lock only, and the pass stops looking once the ceiling is
        // reached; launch repair never gets to be the reason a live append
        // waits.
        var consumedBytes = selection.consumedBytes
        var repairs: [StaleRepair] = []
        let deadline = Date().addingTimeInterval(Self.staleReadCeiling)
        for (offset, candidate) in selection.candidates.enumerated() {
            guard Date() < deadline else {
                report.skippedForBounds += selection.candidates.count - offset
                break
            }
            report.transcriptsExamined += 1
            guard maximumBytes >= 0, consumedBytes <= maximumBytes else {
                report.skippedForBounds += 1
                continue
            }
            let remainingBytes = maximumBytes - consumedBytes
            // 2026-09-06: the size is measured UNDER the transcript lock, and
            // it is that size the budget is charged. Measured before the lock
            // it described a file the read no longer sees — an append between
            // the two undercharged the budget by exactly the bytes the read
            // then paid for.
            let read = try await persistence.withFileLock(candidate.url) { () -> StaleRead? in
                let attributes = try? FileManager.default.attributesOfItem(
                    atPath: candidate.url.path
                )
                let bytes = (attributes?[.size] as? NSNumber)?.int64Value ?? 0
                guard bytes >= 0, bytes <= remainingBytes else { return nil }
                let scan = try await persistence.readJSONLReporting(candidate.url)
                return StaleRead(bytes: bytes, rows: scan.rows, readReport: scan.report)
            }
            guard let read else {
                report.skippedForBounds += 1
                continue
            }
            consumedBytes += read.bytes

            let objectRows: [[String: JSONValue]] = read.rows.compactMap {
                guard case .object(let object) = $0 else { return nil }
                return object
            }
            // 2026-09-06: the SAME row validation the recovery pass applies.
            // Accepting any parseable non-empty object let a malformed row
            // count toward `messageCount` and stamped the index row as verified
            // against a transcript this reconciler does not actually trust.
            guard read.readReport.malformedLineCount == 0,
                  !read.readReport.trailingPartialLine,
                  !objectRows.isEmpty,
                  Self.rowsAreTrustworthy(
                      objectRows,
                      parsedRowCount: read.rows.count,
                      sessionID: candidate.sessionID
                  ) else {
                // Damaged transcripts stay visible and unstamped: this pass
                // repairs an index row from a transcript it trusts, and never
                // the other way round.
                report.corruptTranscripts += 1
                continue
            }

            // Preview and `updatedAt` come from the last CONVERSATIONAL row,
            // not the last physical one: `syncSessionIndex` is only ever called
            // for a "user" or "assistant" row, so a trailing tool receipt is
            // not what it would have written, and its serialized result is not
            // a sidebar preview.
            let lastSpoken = objectRows.last { candidate in
                let role = Self.string(candidate["role"])?.lowercased()
                return role == "user" || role == "assistant"
            }
            repairs.append(
                StaleRepair(
                    candidate: candidate,
                    messageCount: Int64(objectRows.count),
                    preview: Self.bounded(
                        lastSpoken.flatMap { Self.string($0["content"]) } ?? "",
                        to: 160
                    ),
                    hasConversationalRow: lastSpoken != nil,
                    lastSpokenStamp: Self.string(lastSpoken?["createdAt"])
                        ?? Self.string(lastSpoken?["timestamp"])
                )
            )
        }

        guard !repairs.isEmpty else { return report }
        let pendingRepairs = repairs

        // PASS 3 — the index lock again, briefly, for the writes only.
        report.staleRowsRepaired += try await persistence.withFileLock(sessionsPath) { () -> Int in
            var rows = try ChatSessionIndexFile.loadObjectRowsForMutation(at: sessionsPath)
            var positions: [String: Int] = [:]
            for (offset, row) in rows.enumerated() {
                guard case .string(let id)? = row["id"], positions[id] == nil else { continue }
                positions[id] = offset
            }
            var repaired = 0
            var wroteRow = false
            for repair in pendingRepairs {
                guard let position = positions[repair.candidate.sessionID] else { continue }
                var row = rows[position]
                // 2026-09-06: the index lock was released for the read, so a
                // live append may have rewritten this row since it was
                // selected. Only a row still exactly as it was selected is
                // repaired from a transcript read against that same state;
                // anything else is already fresher than this pass, and the
                // stat gate will pick it up again next launch if it is not.
                guard row["updatedAt"] == repair.candidate.updatedAt,
                      row[Self.transcriptStampKey] == repair.candidate.stamp else { continue }
                var disagreed = false
                let count = JSONValue.int(repair.messageCount)
                if row["messageCount"] != count {
                    row["messageCount"] = count
                    disagreed = true
                }
                if !repair.hasConversationalRow {
                    // 2026-09-06: the transcript this row was repaired from
                    // carries no conversational row at all, so the preview on
                    // the row quotes a message the transcript no longer holds.
                    // Leaving it made the sidebar (and the phone's session
                    // list) show a line from a conversation that was cleared
                    // back to tool receipts. Clear it instead.
                    if row["lastMessagePreview"] != nil,
                       row["lastMessagePreview"] != .string("") {
                        row["lastMessagePreview"] = .string("")
                        disagreed = true
                    }
                } else if repair.preview.isEmpty {
                    // 2026-09-06: there IS a last user/assistant row, it just
                    // has no readable string content to quote. That is not
                    // evidence the stored preview is wrong, so the row keeps
                    // whatever it has rather than being blanked.
                } else if row["lastMessagePreview"] != .string(repair.preview) {
                    row["lastMessagePreview"] = .string(repair.preview)
                    disagreed = true
                }
                // `updatedAt` orders the sidebar, so it only ever moves
                // FORWARD here. Compaction PREPENDS its summary row and keeps
                // an older tail, so a transcript's last row can be older than
                // the row that describes it; that is not a reason to send the
                // conversation down the list.
                if let lastStamp = repair.lastSpokenStamp,
                   let lastDate = Self.date(lastStamp),
                   let rowDate = Self.date(Self.string(row["updatedAt"])),
                   lastDate > rowDate {
                    row["updatedAt"] = .string(lastStamp)
                    disagreed = true
                }
                if disagreed {
                    // 2026-09-06: the phone orders published transcripts by
                    // this counter. A repair that changes what the row says
                    // about its transcript without moving the counter left the
                    // phone holding its pre-repair copy for good — nothing
                    // published afterwards looked newer than the snapshot it
                    // already had.
                    ChatSessionIndexFile.bumpTranscriptGeneration(in: &row)
                }
                row[Self.transcriptStampKey] = .string(Self.iso8601(repair.candidate.modified))
                rows[position] = row
                wroteRow = true
                if disagreed { repaired += 1 }
            }
            if wroteRow {
                let data = try ChatSessionIndexFile.serializedData(for: rows)
                try await persistence.writeDataAtomicDurable(data, to: sessionsPath)
            }
            return repaired
        }
        return report
    }

    /// The shape both passes demand of a transcript before an index row is
    /// written from it: every physical line a JSON object, every object
    /// carrying string `role` and `content`, and no object claiming a
    /// different session.
    private nonisolated static func rowsAreTrustworthy(
        _ objectRows: [[String: JSONValue]],
        parsedRowCount: Int,
        sessionID: String
    ) -> Bool {
        guard objectRows.count == parsedRowCount else { return false }
        return !objectRows.contains { object in
            guard case .string(_)? = object["role"],
                  case .string(_)? = object["content"] else { return true }
            if case .string(let storedSession)? = object["sessionId"] {
                return storedSession != sessionID
            }
            return false
        }
    }

    private nonisolated static func string(_ value: JSONValue?) -> String? {
        guard case .string(let raw)? = value else { return nil }
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }

    /// The latest moment this index row is known to have described its
    /// transcript correctly: the row's own `updatedAt`, or the transcript
    /// mtime a previous reconcile verified it against, whichever is later.
    /// `nil` — a row with no parsable `updatedAt` — is not a repair candidate:
    /// there is no baseline to compare an mtime against, and treating every
    /// such row as stale would reopen the whole directory at launch.
    private nonisolated static func lastAgreement(with row: [String: JSONValue]) -> Date? {
        guard let updatedAt = date(string(row["updatedAt"])) else { return nil }
        guard let stamped = date(string(row[transcriptStampKey])) else { return updatedAt }
        return max(updatedAt, stamped)
    }

    private nonisolated static func date(_ raw: String?) -> Date? {
        guard let raw, !raw.isEmpty else { return nil }
        let fractional = ISO8601DateFormatter()
        fractional.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        if let parsed = fractional.date(from: raw) { return parsed }
        let standard = ISO8601DateFormatter()
        standard.formatOptions = [.withInternetDateTime]
        return standard.date(from: raw)
    }

    private nonisolated static func iso8601(_ date: Date) -> String {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return formatter.string(from: date)
    }

    private nonisolated static func bounded(_ raw: String, to limit: Int) -> String {
        let clean = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        return clean.count <= limit ? clean : String(clean.prefix(limit)) + "…"
    }
}
