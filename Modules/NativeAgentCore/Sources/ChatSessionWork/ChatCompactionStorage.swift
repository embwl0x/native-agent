import Foundation
import NativeAgentShared
import Experiences
import NativeAgentCore
import PersistenceCore
import TurnTrace
import Transcripts
import ProviderRouting
// Blueprint: | `ChatCompactionStorage.swift` | Retained originals, backups and bounded backup reclamation |
extension ChatSessionAutocompactor {
    func messagesPath(sessionId: String) -> URL {
        dataRoot
            .appendingPathComponent("chat", isDirectory: true)
            .appendingPathComponent("messages", isDirectory: true)
            .appendingPathComponent("\(sessionId).jsonl")
    }
    func sessionDir(sessionId: String) -> URL {
        dataRoot
            .appendingPathComponent("chat", isDirectory: true)
            .appendingPathComponent("sessions", isDirectory: true)
            .appendingPathComponent(sessionId, isDirectory: true)
    }
    func readJSONLHonest(_ path: URL) async throws -> (rows: [JSONValue], bytes: Data) {
        let data: Data
        do { data = try Data(contentsOf: path) } catch {
            throw ChatSessionCompactionTranscriptError(
                errorDescription: "transcript could not be read; nothing was rewritten"
            )
        }
        // Whitespace-only lines are a legacy shape the distiller still writes
        // back; skip them. Any other unreadable line, or a torn tail, refuses.
        let lines = data.split(separator: 0x0A, omittingEmptySubsequences: false)
        let framed = lines.enumerated().flatMap { index, line -> [UInt8] in
            guard line.contains(where: { $0 != 0x20 && $0 != 0x09 && $0 != 0x0D }) else { return [] }
            return Array(line) + (index < lines.count - 1 ? [0x0A] : [])
        }
        let (rows, report) = SwiftNativePersistenceCore.decodeJSONL(Data(framed)) { value, _ -> JSONValue? in
            guard case .object = value else { return nil }
            return value
        }
        guard report.malformedLineCount == 0, !report.trailingPartialLine else {
            throw ChatSessionCompactionTranscriptError(
                errorDescription: "transcript has \(report.malformedLineCount) unreadable line(s)"
                    + (report.trailingPartialLine ? " and a torn last line" : "")
                    + "; refusing to compact until it is repaired"
            )
        }
        return (rows, data)
    }
    /// Copies the live transcript aside and verifies it byte-for-byte before
    /// permitting the destructive rewrite.
    /// Storage: compaction copies are excluded from local backup, data export
    /// and raw phone sync; included in off-disk backup and PrivacyMap/chat.
    @discardableResult
    func backupCurrentMessages(sessionId: String, messagesPath: URL, sourceBytes: Data, rows: [JSONValue]) throws -> URL {
        let dir = sessionDir(sessionId: sessionId)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        // Unique suffix: two compactions in the same second must not collide —
        // a copy failing onto an existing name would otherwise report the STALE
        // backup as fresh and the distiller would distill the wrong prefix.
        // Success = THIS copy succeeded, never "a file with that name exists".
        let suffix = "\(Self.fileSafeTimestamp(now())).\(UUID().uuidString.lowercased().prefix(8))"
        let backup = dir.appendingPathComponent("messages.compact.\(suffix).jsonl")
        do {
            try FileManager.default.copyItem(at: messagesPath, to: backup)
            let backupData = try Data(contentsOf: backup)
            guard backupData == sourceBytes else {
                throw NSError(domain: "NativeAgent.ChatSessionAutocompactor", code: -6, userInfo: [
                    NSLocalizedDescriptionKey: "pre-compaction backup verification failed"
                ])
            }
            Self.pruneCompactBackups(
                in: dir,
                keeping: Self.maximumCompactBackups,
                originals: Self.originalsPath(dataRoot: dataRoot, sessionId: sessionId),
                preserving: backup,
                pendingRows: rows
            )
        } catch {
            try? FileManager.default.removeItem(at: backup)
            throw NSError(domain: "NativeAgent.ChatSessionAutocompactor", code: -5, userInfo: [
                NSLocalizedDescriptionKey: "could not create a verified pre-compaction backup; refusing to compact",
                NSUnderlyingErrorKey: error,
            ])
        }
        return backup
    }
    /// Keep a bounded recovery window without letting every compaction leave a
    /// permanent full-transcript copy. Cleanup is best-effort: preserving an
    /// extra old backup is safer than invalidating the verified fresh one.
    @discardableResult
    static func pruneCompactBackups(
        in directory: URL,
        keeping: Int,
        originals: URL,
        preserving protected: URL? = nil,
        pendingRows: [JSONValue] = []
    ) -> [URL] {
        guard keeping >= 0,
              let entries = try? FileManager.default.contentsOfDirectory(
                  at: directory,
                  includingPropertiesForKeys: nil
              )
        else { return [] }
        guard let pendingBackups = protectedCompactBackupNames(in: pendingRows) else { return [] }
        let backups = entries
            .filter {
                $0.lastPathComponent.hasPrefix("messages.compact.")
                    && $0.pathExtension == "jsonl"
            }
            .sorted { lhs, rhs in
                if lhs == protected { return true }
                if rhs == protected { return false }
                return lhs.lastPathComponent > rhs.lastPathComponent
            }
        let retiring = backups.dropFirst(keeping).filter { !pendingBackups.contains($0.lastPathComponent) }
        guard !retiring.isEmpty else { return [] }
        func lines(_ bytes: Data) throws -> [(line: Data, stamp: String?)] {
            try bytes.split(separator: 0x0A).map { line in
                let data = Data(line)
                guard case .object(let object) = try JSONValue.parse(data) else {
                    throw NSError(domain: "NativeAgent.ChatCompactionArchive", code: 1)
                }
                let stamp: String? = if case .string(let raw)? = object["createdAt"] { raw } else { nil }
                return (data, stamp)
            }
        }
        var removed: [URL] = []
        do {
            let existing: Data
            do { existing = try Data(contentsOf: originals) }
            catch CocoaError.fileReadNoSuchFile { existing = Data() }
            var merged = try lines(existing)
            var known = Set(merged.map(\.line))
            var admitted: [URL] = []
            for stale in retiring {
                do {
                    let source = try lines(Data(contentsOf: stale))
                    for line in source where known.insert(line.line).inserted { merged.append(line) }
                    admitted.append(stale)
                } catch {
                    nativeLog("Chat compaction: unreadable recovery copy preserved: %@", String(describing: error))
                }
            }
            guard !admitted.isEmpty else { return [] }
            // Exact edited versions survive; equal-time rows retain union order.
            var ordered: [(index: Int, line: Data, at: Date)] = []
            ordered.reserveCapacity(merged.count)
            for (index, row) in merged.enumerated() {
                let at: Date = row.stamp.flatMap(NativeTimestampFormat.parseISO8601FractionalFirst) ?? .distantPast
                ordered.append((index: index, line: row.line, at: at))
            }
            ordered.sort { lhs, rhs in lhs.at == rhs.at ? lhs.index < rhs.index : lhs.at < rhs.at }
            var output = Data()
            for row in ordered { output.append(row.line); output.append(0x0A) }
            if output != existing {
                try FileManager.default.createDirectory(at: originals.deletingLastPathComponent(), withIntermediateDirectories: true)
                try ContactThread.replace(output, to: originals)
            }
            let verified = Set(try lines(Data(contentsOf: originals)).map(\.line))
            guard known.isSubset(of: verified) else { throw NSError(domain: "NativeAgent.ChatCompactionArchive", code: 2) }
            for stale in admitted {
                do { try FileManager.default.removeItem(at: stale); removed.append(stale) }
                catch { nativeLog("Chat compaction: archived recovery copy could not retire: %@", String(describing: error)) }
            }
        } catch {
            nativeLog("Chat compaction: recovery copies preserved after archive failure: %@", String(describing: error))
        }
        return removed
    }
    /// nil protects every copy when a pending recollection cannot identify its
    /// exact source. Protected overage is deferred, not failure.
    static func protectedCompactBackupNames(in rows: [JSONValue]) -> Set<String>? {
        var names: Set<String> = []
        for row in rows where hasPendingDistillation(row) {
            guard case .object(let object) = row,
                  case .object(let metadata)? = object["metadata"],
                  case .string(let name)? = metadata["distill_backup"] else { return nil }
            names.insert(name)
        }
        return names
    }
    public static func originalsPath(dataRoot: URL, sessionId: String) -> URL {
        dataRoot.appendingPathComponent("chat/archive/originals", isDirectory: true)
            .appendingPathComponent("\(sessionId).jsonl")
    }
}
