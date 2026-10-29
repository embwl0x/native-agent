import Darwin
import Foundation
import NativeAgentShared
import NativeAgentCore
import PersistenceCore
import Transcripts
import TurnTrace
// Blueprint: | `ChatSessionIndexReconciler.swift` | `ChatSessionIndexReconciler` actor; `reconcile` selects repairs and commits through ChatSessionIndexFile |

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

    public init(
        dataRoot: URL = PersistenceCore.defaultDataRoot()
    ) {
        self.dataRoot = dataRoot
    }

    /// Legacy human-readable reconciliation time. Exact version identity is
    /// shared with transcript writers and retention through ChatSessionIndexFile.
    static let transcriptStampKey = "reconciledTranscriptModifiedAt"

    /// Wall-clock ceiling on the stale pass's transcript reads. Contended
    /// transcript locks are skipped immediately; stop selecting further reads
    /// after this long and leave the rest to the next launch.
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
        let version: JSONValue?
    }

    private struct StaleRead: Sendable {
        let bytes: Int64
        let rows: [[String: JSONValue]]?
        let version: JSONValue?

        /// Distinguish an absent conversational row from one with no readable preview.
        let preview: (text: String, stamp: TranscriptRowStamp)?
        let firstSpokenStamp: String?
        let lastSpokenStamp: String?
    }

    /// A transcript row's own stamp (`TranscriptRowStamp`), for the preview taken from it.
    private nonisolated static func stamp(_ row: [String: JSONValue]?) -> TranscriptRowStamp {
        let metadata: [String: JSONValue] = if case .object(let value)? = row?["metadata"] { value } else { [:] }
        return TranscriptRowStamp.of(id: string(row?["id"]) ?? "", role: string(row?["role"])?.lowercased() ?? "",
                                     metadata: metadata, rowSource: string(row?["source"]))
    }

    private struct StaleRepair: Sendable {
        let candidate: StaleCandidate
        let read: StaleRead
    }

    private struct SelectionPass: Sendable {
        var report: ChatSessionIndexReconciliationReport
        var candidates: [StaleCandidate]
        var orphans: [URL]
    }

    public func reconcile(
        maximumFiles: Int = 256,
        maximumBytes: Int64 = 32 * 1_024 * 1_024,
        maximumStaleRepairs: Int = 50
    ) async throws -> ChatSessionIndexReconciliationReport {
        let sessionsPath = dataRoot.appendingPathComponent("chat/sessions.json")
        let messagesDirectory = dataRoot.appendingPathComponent("chat/messages", isDirectory: true)
        guard FileManager.default.fileExists(atPath: messagesDirectory.path) else { return .init() }

        // Select missing and stale rows under the index lock using metadata only.
        // Transcript locks and parsing belong outside this shared critical section.
        let selection = try await SwiftNativePersistenceCore.withFileLock(sessionsPath) { () -> SelectionPass in
            var report = ChatSessionIndexReconciliationReport()
            let rows = try ChatSessionIndexFile.loadObjectRowsForMutation(at: sessionsPath)
            let knownIDs = Set(rows.compactMap { row -> String? in
                guard case .string(let raw)? = row["id"],
                      NativeAgentChatSessionID.normalizedPathComponent(raw) == raw else { return nil }
                return raw
            }).union(try Self.archivedSessionIDs(dataRoot: self.dataRoot))

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

            // Bound stale-row reads by exact transcript version so orphan recovery cannot starve.
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
                          let version = ChatSessionIndexFile.transcriptVersion(at: transcript.url),
                          row[ChatSessionIndexFile.acknowledgedTranscriptKey] != version
                              || row[TranscriptRowStamp.previewKey] == nil else { continue }
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
                            stamp: row[Self.transcriptStampKey],
                            version: row[ChatSessionIndexFile.acknowledgedTranscriptKey]
                        )
                    )
                }
            }

            return SelectionPass(
                report: report,
                candidates: staleCandidates,
                orphans: Array(boundedCandidates)
            )
        }

        var report = selection.report

        // Read orphan transcripts with the shared index lock released. A busy
        // transcript is skipped; all other candidates can still be recovered.
        var consumedBytes: Int64 = 0
        var recovered: [[String: JSONValue]] = []
        for transcript in selection.orphans {
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
            let remainingBytes = maximumBytes - consumedBytes
            guard let read = try await Self.readTranscript(transcript, sessionID: sessionID,
                                                          maximumBytes: remainingBytes) else {
                report.skippedForBounds += 1
                continue
            }
            consumedBytes += read.bytes
            guard let objectRows = read.rows else {
                report.corruptTranscripts += 1
                continue
            }
            guard !objectRows.isEmpty else { continue }

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
            }).flatMap { Self.content($0) }
            // Session origin belongs to the first surface-authored row, excluding compaction system rows.
            let creation = objectRows.first(where: { row in
                guard Self.string(row["source"]) != nil else { return false }
                return Self.string(row["role"])?.lowercased() != "system"
            })
            let source = creation.flatMap { Self.string($0["source"]) } ?? "app"
            let kind = SessionConversation.kind(threadKind: creation.flatMap { Self.string($0["threadKind"]) }, source: source,
                                                sourceKey: creation.flatMap { Self.string($0["sourceKey"]) })
            var recoveredRow: [String: JSONValue] = [
                "id": .string(sessionID),
                "title": .string(Self.bounded(firstUserContent ?? "Recovered Chat", to: 80)),
                "source": .string(source),
                "threadKind": .string(kind.rawValue),
                "createdAt": .string(createdAt),
                "updatedAt": .string(updatedAt),
                "archived": .bool(false),
                "messageCount": .int(Int64(objectRows.count)),
                "summary": .string(""),
            ]
            recoveredRow["firstMessageAt"] = read.firstSpokenStamp.map(JSONValue.string)
            recoveredRow["lastMessageAt"] = read.lastSpokenStamp.map(JSONValue.string)
            recoveredRow["lastMessagePreview"] = .string(read.preview?.text ?? "")
            recoveredRow[TranscriptRowStamp.previewKey] = (read.preview?.stamp ?? Self.stamp(nil)).json
            // Stamp the pre-read mtime so a concurrent change remains eligible for repair.
            if let modified = values.contentModificationDate {
                recoveredRow[Self.transcriptStampKey] = .string(Self.iso8601(modified))
            }
            recoveredRow[ChatSessionIndexFile.acknowledgedTranscriptKey] = read.version
            recovered.append(recoveredRow)
        }
        // PASS 2 — index lock RELEASED. Each tripped transcript is read under
        // its own lock only, and the pass stops looking once the ceiling is
        // reached; launch repair never gets to be the reason a live append
        // waits.
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
            // Measure and charge transcript bytes under the same lock as the read.
            guard let read = try await Self.readTranscript(candidate.url, sessionID: candidate.sessionID,
                                                          maximumBytes: remainingBytes) else {
                report.skippedForBounds += 1
                continue
            }
            consumedBytes += read.bytes

            // Stale repairs require the same trusted transcript rows as orphan recovery.
            guard let objectRows = read.rows, !objectRows.isEmpty else {
                // Damaged transcripts stay visible and unstamped: this pass
                // repairs an index row from a transcript it trusts, and never
                // the other way round.
                report.corruptTranscripts += 1
                continue
            }

            repairs.append(StaleRepair(candidate: candidate, read: read))
        }

        guard !repairs.isEmpty || !recovered.isEmpty else { return report }
        let pendingRepairs = repairs
        let pendingRecovered = recovered

        // PASS 3 — the index lock again, briefly, for the writes only.
        let writes = try await SwiftNativePersistenceCore.withFileLock(sessionsPath) { () -> (recovered: Int, repaired: Int) in
            var rows = try ChatSessionIndexFile.loadObjectRowsForMutation(at: sessionsPath)
            // An archive may have committed while transcript reads were outside
            // the index lock. Its durable claim wins over orphan recovery.
            let archivedIDs = try Self.archivedSessionIDs(dataRoot: self.dataRoot)
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
                let read = repair.read
                // Apply repair only while the selected index state remains unchanged.
                guard row["updatedAt"] == repair.candidate.updatedAt,
                      row[Self.transcriptStampKey] == repair.candidate.stamp,
                      row[ChatSessionIndexFile.acknowledgedTranscriptKey] == repair.candidate.version else { continue }
                var disagreed = false
                if row["firstMessageAt"] == nil || row["firstMessageAt"] == .null {
                    row["firstMessageAt"] = read.firstSpokenStamp.map(JSONValue.string)
                }
                row["lastMessageAt"] = read.lastSpokenStamp.map(JSONValue.string)
                let count = JSONValue.int(Int64(read.rows?.count ?? 0))
                if row["messageCount"] != count {
                    row["messageCount"] = count
                    disagreed = true
                }
                // A transcript with no conversational row has no preview to quote.
                let preview = JSONValue.string(read.preview?.text ?? "")
                let previewStamp = (read.preview?.stamp ?? Self.stamp(nil)).json
                if row["lastMessagePreview"] != preview || row[TranscriptRowStamp.previewKey] != previewStamp {
                    row["lastMessagePreview"] = preview
                    row[TranscriptRowStamp.previewKey] = previewStamp
                    disagreed = true
                }
                // `updatedAt` orders the sidebar, so it only ever moves
                // FORWARD here. Compaction PREPENDS its summary row and keeps
                // an older tail, so a transcript's last row can be older than
                // the row that describes it; that is not a reason to send the
                // conversation down the list.
                if let lastStamp = read.lastSpokenStamp,
                   let lastDate = Self.date(lastStamp),
                   let rowDate = Self.date(Self.string(row["updatedAt"])),
                   lastDate > rowDate {
                    row["updatedAt"] = .string(lastStamp)
                    disagreed = true
                }
                if disagreed {
                    // Changed transcript metadata advances the phone's publication counter.
                    ChatSessionIndexFile.bumpTranscriptGeneration(in: &row)
                }
                row[Self.transcriptStampKey] = .string(Self.iso8601(repair.candidate.modified))
                row[ChatSessionIndexFile.acknowledgedTranscriptKey] = read.version
                rows[position] = row
                wroteRow = true
                if disagreed { repaired += 1 }
            }
            // A live writer may have created an orphan's index row during the read.
            // Its row wins; never replace it with the launch snapshot.
            let insertions = pendingRecovered.filter {
                guard let id = Self.string($0["id"]) else { return false }
                return positions[id] == nil && !archivedIDs.contains(id)
            }.sorted {
                (Self.string($0["updatedAt"]) ?? "") > (Self.string($1["updatedAt"]) ?? "")
            }
            rows.insert(contentsOf: insertions, at: 0)
            if wroteRow || !insertions.isEmpty {
                try ChatSessionIndexFile.write(rows, to: sessionsPath)
            }
            return (insertions.count, repaired)
        }
        report.sessionsRecovered += writes.recovered
        report.staleRowsRepaired += writes.repaired
        return report
    }

    /// Manual archives retain transcript bytes. Those files are intentionally
    /// absent from the hot index, not lost rows to recover at the next launch.
    /// Called under the shared session-index lock used by archive writers.
    private nonisolated static func archivedSessionIDs(dataRoot: URL) throws -> Set<String> {
        Set(try ChatSessionRetention.archiveIndexRows(dataRoot: dataRoot).compactMap { row in
            guard case .string(let id)? = row["id"] else { return nil }
            return id
        })
    }

    /// Launch repair skips busy transcripts without queuing behind a writer.
    /// Size, validation and preview all describe the same locked read.
    private nonisolated static func readTranscript(
        _ transcript: URL, sessionID: String, maximumBytes: Int64
    ) async throws -> StaleRead? {
        try await withAvailableTranscriptLock(transcript) { () -> StaleRead? in
            let attributes = try FileManager.default.attributesOfItem(atPath: transcript.path)
            let bytes = (attributes[.size] as? NSNumber)?.int64Value ?? 0
            guard bytes >= 0, bytes <= maximumBytes else { return nil }
            let scan = try await SwiftNativePersistenceCore.readJSONLReporting(transcript)
            let rows = scan.rows.compactMap { row -> [String: JSONValue]? in
                guard case .object(let object) = row else { return nil }
                return object
            }
            let valid = scan.report.malformedLineCount == 0 && !scan.report.trailingPartialLine
                && rowsAreTrustworthy(rows, parsedRowCount: scan.rows.count, sessionID: sessionID)
            let spoken = rows.filter { ["user", "assistant"].contains(string($0["role"])?.lowercased() ?? "") }
            return StaleRead(bytes: bytes, rows: valid ? rows : nil,
                             version: ChatSessionIndexFile.transcriptVersion(at: transcript),
                             preview: spoken.last.map { (bounded(content($0) ?? "", to: 160), stamp($0)) },
                             firstSpokenStamp: string(spoken.first?["createdAt"]) ?? string(spoken.first?["timestamp"]),
                             lastSpokenStamp: string(spoken.last?["createdAt"]) ?? string(spoken.last?["timestamp"]))
        } ?? nil
    }

    private nonisolated static func withAvailableTranscriptLock<T: Sendable>(
        _ transcript: URL,
        _ body: @Sendable () async throws -> T
    ) async throws -> T? {
        try Task.checkCancellation()
        do {
            return try await SwiftNativePersistenceCore.withFileLock(transcript, waitingAtMost: 0, body)
        } catch let error as NSError where error.domain == "FileLock" && error.code == Int(ETIMEDOUT) {
            return nil
        }
    }

    /// The shape both passes demand of a transcript before an index row is
    /// written from it: every physical line a JSON object, every object
    /// carrying string `role` and `content` or legacy `text`, and no object claiming a
    /// different session.
    private nonisolated static func rowsAreTrustworthy(
        _ objectRows: [[String: JSONValue]],
        parsedRowCount: Int,
        sessionID: String
    ) -> Bool {
        guard objectRows.count == parsedRowCount else { return false }
        return !objectRows.contains { object in
            guard case .string(_)? = object["role"],
                  contentValue(object) != nil else { return true }
            if case .string(let storedSession)? = object["sessionId"] {
                return storedSession != sessionID
            }
            return false
        }
    }

    private nonisolated static func contentValue(_ object: [String: JSONValue]) -> JSONValue? {
        if case .string? = object["content"] { return object["content"] }
        if case .string? = object["text"] { return object["text"] }
        return nil
    }

    private nonisolated static func content(_ object: [String: JSONValue]) -> String? {
        string(contentValue(object))
    }

    private nonisolated static func string(_ value: JSONValue?) -> String? {
        guard case .string(let raw)? = value else { return nil }
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }

    private nonisolated static func date(_ raw: String?) -> Date? {
        guard let raw, !raw.isEmpty else { return nil }
        return NativeTimestampFormat.parseISO8601FractionalFirst(raw)
    }

    private nonisolated static func iso8601(_ date: Date) -> String {
        return NativeTimestampFormat.fractionalZulu(date)
    }

    private nonisolated static func bounded(_ raw: String, to limit: Int) -> String {
        let clean = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        return clean.count <= limit ? clean : String(clean.prefix(limit)) + "…"
    }
}
