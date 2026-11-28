import Darwin
import Foundation
import NativeAgentShared
import NativeAgentCore
import PersistenceCore
import SenseCore
// Blueprint: | `ChatSessionIndexReconciler.swift` | `ChatSessionIndexReconciler` actor; `reconcile` selects repairs and commits through ChatSessionIndexFile |

/// Repair the two-file commit window without rewriting transcript bytes; a damaged shared index refuses repair.
public struct ChatSessionIndexReconciliationReport: Sendable, Equatable {
    public var transcriptsExamined = 0
    public var sessionsRecovered = 0
    public var corruptTranscripts = 0
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

    /// Revisit previews generated before reconciliation read the row's saved provenance.
    private static let legacyTranscriptStampKey = "reconciledTranscriptModifiedAt"
    private static let transcriptStampKey = "reconciledTranscriptPreviewAt"

    /// Recheck selected updatedAt/stamp values before writing a repair computed outside the index lock.
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

        let preview: (text: String, stamp: TranscriptRowStamp)?
        let firstSpokenStamp: String?
        let lastSpokenStamp: String?
    }

    private struct StaleRepair: Sendable {
        let candidate: StaleCandidate
        let read: StaleRead
    }

    private struct SelectionPass: Sendable {
        var candidates: [StaleCandidate]
        var orphans: [URL]
    }

    public func reconcile(
        maximumBytes: Int64 = 32 * 1_024 * 1_024
    ) async throws -> ChatSessionIndexReconciliationReport {
        let sessionsPath = dataRoot.appendingPathComponent("chat/sessions.json")
        let messagesDirectory = dataRoot.appendingPathComponent("chat/messages", isDirectory: true)
        guard FileManager.default.fileExists(atPath: messagesDirectory.path) else { return .init() }

        let selection = try await selectRepairs(sessionsPath: sessionsPath, messagesDirectory: messagesDirectory)
        let (recovered, startingReport, consumedBytes) = try await readOrphanRepairs(selection, maximumBytes: maximumBytes)
        let (repairs, readReport) = try await readStaleRepairs(
            selection, maximumBytes: maximumBytes, startingBytes: consumedBytes, startingReport: startingReport
        )
        var report = readReport
        guard !repairs.isEmpty || !recovered.isEmpty else { return report }
        let writes = try await commitRepairs(sessionsPath: sessionsPath, pendingRepairs: repairs, pendingRecovered: recovered)
        report.sessionsRecovered += writes.recovered
        report.staleRowsRepaired += writes.repaired
        return report
    }

    private func selectRepairs(sessionsPath: URL, messagesDirectory: URL) async throws -> SelectionPass {
        // Select by metadata under the index lock; acquire transcript locks and parse outside it.
        return try await SwiftNativePersistenceCore.withFileLock(sessionsPath) { () -> SelectionPass in
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

            // Exclude indexed transcripts before the bounded recovery budget so healthy history cannot starve orphan repair.
            // Keep invalid filenames visible as corruption candidates.
            let candidates = directoryEntries.filter { transcript in
                let raw = transcript.deletingPathExtension().lastPathComponent
                guard NativeAgentChatSessionID.normalizedPathComponent(raw) == raw else {
                    return true
                }
                return !knownIDs.contains(raw)
            }.sorted { lhs, rhs in
                // Prioritize valid orphan IDs so damaged filenames cannot starve recoverable sessions.
                func priority(_ url: URL) -> Int {
                    let raw = url.deletingPathExtension().lastPathComponent
                    return NativeAgentChatSessionID.normalizedPathComponent(raw) == raw ? 0 : 1
                }
                let lhsPriority = priority(lhs)
                let rhsPriority = priority(rhs)
                if lhsPriority != rhsPriority { return lhsPriority < rhsPriority }
                return lhs.lastPathComponent < rhs.lastPathComponent
            }

            let fileLimit = 256
            let boundedCandidates = candidates.prefix(fileLimit)

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

            // Bound transcript locks across all stale repairs, including legacy previews.
            var staleCandidates: [StaleCandidate] = []
            for row in rows {
                let legacy = row[Self.legacyTranscriptStampKey] != nil
                guard case .string(let sessionID)? = row["id"],
                      let transcript = transcriptsByID[sessionID],
                      let version = ChatSessionIndexFile.transcriptVersion(at: transcript.url),
                      legacy || row[ChatSessionIndexFile.acknowledgedTranscriptKey] != version
                          || row[TranscriptRowStamp.previewKey] == nil else { continue }
                let candidate = StaleCandidate(
                    sessionID: sessionID,
                    url: transcript.url,
                    modified: transcript.modified,
                    updatedAt: row["updatedAt"],
                    stamp: row[Self.transcriptStampKey],
                    version: row[ChatSessionIndexFile.acknowledgedTranscriptKey]
                )
                staleCandidates.append(candidate)
                if staleCandidates.count == 50 { break }
            }

            return SelectionPass(
                candidates: staleCandidates,
                orphans: Array(boundedCandidates)
            )
        }
    }

    private func readOrphanRepairs(
        _ selection: SelectionPass, maximumBytes: Int64
    ) async throws -> (recovered: [[String: JSONValue]], report: ChatSessionIndexReconciliationReport, consumedBytes: Int64) {
        var report = ChatSessionIndexReconciliationReport()

        // Release the index lock for transcript reads; a busy transcript cannot block its siblings' recovery.
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
                continue
            }
            consumedBytes += read.bytes
            guard let objectRows = read.rows else {
                report.corruptTranscripts += 1
                continue
            }
            guard !objectRows.isEmpty else { continue }

            guard let createdAt = (objectRows.first?["createdAt"])?.trimmedString else {
                report.corruptTranscripts += 1
                continue
            }
            let updatedAt = (objectRows.last?["createdAt"])?.trimmedString ?? createdAt
            let firstUserContent = objectRows.first(where: {
                ($0["role"])?.trimmedString?.lowercased() == "user"
            }).flatMap { Self.readableSpeech($0)?.text }
            let title = Self.bounded(firstUserContent ?? "", to: 80)
            // Session origin comes from the first surface-authored row, excluding system rows.
            let creation = objectRows.first(where: { row in
                guard (row["source"])?.trimmedString != nil else { return false }
                return (row["role"])?.trimmedString?.lowercased() != "system"
            })
            let source = creation.flatMap { ($0["source"])?.trimmedString } ?? "app"
            let kind = SessionConversation.kind(threadKind: creation.flatMap { ($0["threadKind"])?.trimmedString }, source: source,
                                                sourceKey: creation.flatMap { ($0["sourceKey"])?.trimmedString })
            var recoveredRow: [String: JSONValue] = [
                "id": .string(sessionID),
                "title": .string(title.isEmpty ? "Recovered Chat" : title),
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
            recoveredRow[TranscriptRowStamp.previewKey] = read.preview?.stamp.json ?? .null
            // Stamp the pre-read mtime so a concurrent change remains eligible for repair.
            if let modified = values.contentModificationDate {
                recoveredRow[Self.transcriptStampKey] = .string(NativeTimestampFormat.fractionalZulu(modified))
            }
            recoveredRow[ChatSessionIndexFile.acknowledgedTranscriptKey] = read.version
            recoveredRow[ChatSessionIndexFile.transcriptGenerationKey] = .int(1)
            recovered.append(recoveredRow)
        }
        return (recovered, report, consumedBytes)
    }

    private func readStaleRepairs(
        _ selection: SelectionPass, maximumBytes: Int64, startingBytes: Int64,
        startingReport: ChatSessionIndexReconciliationReport
    ) async throws -> (repairs: [StaleRepair], report: ChatSessionIndexReconciliationReport) {
        var report = startingReport
        var consumedBytes = startingBytes
        // Each transcript read holds its own lock through completion.
        var repairs: [StaleRepair] = []
        for candidate in selection.candidates {
            try Task.checkCancellation()
            report.transcriptsExamined += 1
            guard maximumBytes >= 0, consumedBytes <= maximumBytes else {
                continue
            }
            let remainingBytes = maximumBytes - consumedBytes
            // Measure transcript bytes under the read's lock so the charged size matches the evidence.
            guard let read = try await Self.readTranscript(candidate.url, sessionID: candidate.sessionID,
                                                          maximumBytes: remainingBytes) else {
                continue
            }
            consumedBytes += read.bytes

            // Stale and orphan repairs require the same trusted transcript shape.
            guard read.rows != nil else {
                // Leave damaged transcripts unstamped; repair the index only from trusted transcript evidence.
                report.corruptTranscripts += 1
                continue
            }

            repairs.append(StaleRepair(candidate: candidate, read: read))
        }
        return (repairs, report)
    }

    private func commitRepairs(
        sessionsPath: URL, pendingRepairs: [StaleRepair], pendingRecovered: [[String: JSONValue]]
    ) async throws -> (recovered: Int, repaired: Int) {
        return try await SwiftNativePersistenceCore.withFileLock(sessionsPath) { () -> (recovered: Int, repaired: Int) in
            var rows = try ChatSessionIndexFile.loadObjectRowsForMutation(at: sessionsPath)
            // A concurrent archive's durable claim takes precedence over orphan recovery.
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
                let count = read.rows?.count ?? 0
                let indexedCount = JSONValue.int(Int64(count))
                // Only the clear operation can confirm that a previously nonempty chat was emptied.
                let confirmsTranscript = count > 0 || row["messageCount"] == .int(0)
                if confirmsTranscript {
                    if count == 0 || row["firstMessageAt"] == nil || row["firstMessageAt"] == .null {
                        row["firstMessageAt"] = read.firstSpokenStamp.map(JSONValue.string)
                    }
                    row["lastMessageAt"] = read.lastSpokenStamp.map(JSONValue.string)
                    if row["messageCount"] != indexedCount {
                        row["messageCount"] = indexedCount
                        disagreed = true
                    }
                    row[Self.transcriptStampKey] = .string(NativeTimestampFormat.fractionalZulu(repair.candidate.modified))
                    row[ChatSessionIndexFile.acknowledgedTranscriptKey] = read.version
                }
                // No preview can quote a missing or provenance-damaged row.
                let preview = JSONValue.string(read.preview?.text ?? "")
                let previewStamp = read.preview?.stamp.json ?? .null
                if row["lastMessagePreview"] != preview || row[TranscriptRowStamp.previewKey] != previewStamp {
                    row["lastMessagePreview"] = preview
                    row[TranscriptRowStamp.previewKey] = previewStamp
                    disagreed = true
                }
                // Advance updatedAt only: an older appended row must not lower sidebar ordering.
                if let lastStamp = read.lastSpokenStamp,
                   let lastDate = NativeTimestampFormat.parseOptionalISO8601FractionalFirst(lastStamp),
                   let rowDate = NativeTimestampFormat.parseOptionalISO8601FractionalFirst(row["updatedAt"]?.trimmedString),
                   lastDate > rowDate {
                    row["updatedAt"] = .string(lastStamp)
                    disagreed = true
                }
                if disagreed && confirmsTranscript {
                    // An unexplained empty read cannot authorize clearing the phone's transcript.
                    ChatSessionIndexFile.bumpTranscriptGeneration(in: &row)
                }
                row[Self.legacyTranscriptStampKey] = nil
                guard row != rows[position] else { continue }
                rows[position] = row
                wroteRow = true
                if disagreed { repaired += 1 }
            }
            // A concurrent writer's index row takes precedence over the launch snapshot.
            let insertions = pendingRecovered.filter {
                guard let id = ($0["id"])?.trimmedString else { return false }
                return positions[id] == nil && !archivedIDs.contains(id)
            }.sorted {
                (($0["updatedAt"])?.trimmedString ?? "") > (($1["updatedAt"])?.trimmedString ?? "")
            }
            rows.insert(contentsOf: insertions, at: 0)
            if wroteRow || !insertions.isEmpty {
                try ChatSessionIndexFile.write(rows, to: sessionsPath)
            }
            return (insertions.count, repaired)
        }
    }

    /// Archived transcripts remain on disk intentionally; their absence from the hot index must not trigger orphan recovery.
    private nonisolated static func archivedSessionIDs(dataRoot: URL) throws -> Set<String> {
        Set(try ChatSessionRetention.archiveIndexRows(dataRoot: dataRoot).compactMap { row in
            guard case .string(let id)? = row["id"] else { return nil }
            return id
        })
    }

    /// Skip busy transcripts; size, validation and preview must describe the same locked read.
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
            let spoken = rows.filter { ["user", "assistant"].contains($0["role"]?.trimmedString?.lowercased() ?? "") }
            return StaleRead(bytes: bytes, rows: valid ? rows : nil,
                             version: ChatSessionIndexFile.transcriptVersion(at: transcript),
                             preview: spoken.last.flatMap(readableSpeech).map { (SwiftNativeChatOrchestrationClient.previewText($0.text), $0.stamp) },
                             firstSpokenStamp: spoken.first?["createdAt"]?.trimmedString,
                             lastSpokenStamp: spoken.last?["createdAt"]?.trimmedString)
        } ?? nil
    }

    private nonisolated static func withAvailableTranscriptLock<T: Sendable>(
        _ transcript: URL,
        _ body: @Sendable () async throws -> T
    ) async throws -> T? {
        try Task.checkCancellation()
        do {
            return try await SwiftNativePersistenceCore.withFileLock(transcript, tryingOnce: true, body)
        } catch let error as NSError where error.domain == "FileLock" && error.code == Int(ETIMEDOUT) {
            return nil
        }
    }

    /// Repair only from JSON-object rows with string role/content and no conflicting session identity.
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
        return nil
    }

    private nonisolated static func readableSpeech(_ row: [String: JSONValue]) -> ContactThread.Line? {
        let line = ContactThread.Line(row)
        return !line.id.isEmpty && line.provenanceFailure == nil ? line : nil
    }

    private nonisolated static func bounded(_ raw: String, to limit: Int) -> String {
        let clean = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        return clean.count <= limit ? clean : String(clean.prefix(limit)) + "…"
    }
}
