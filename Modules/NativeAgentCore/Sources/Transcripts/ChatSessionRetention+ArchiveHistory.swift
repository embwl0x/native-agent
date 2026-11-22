import Foundation
import NativeAgentCore
import PersistenceCore
import NativeAgentShared
import CryptoKit
import os
// Blueprint: | `ChatSessionRetention+ArchiveHistory.swift` | Checked archive restoration under index → transcript locks |

extension ChatSessionRetention {
    /// An append that never finished is cut off before the next one, so it never becomes a damaged interior row.
    package static func dropUnfinishedArchiveAppend(at index: URL) throws {
        // Only a missing index is a fresh one; any other read failure refuses the append, never lets a torn tail become an interior row.
        let bytes: Data
        do { bytes = try Data(contentsOf: index) } catch CocoaError.fileReadNoSuchFile { return }
        guard let last = bytes.last, last != 10 else { return }
        let keep = bytes.lastIndex(of: 10).map { $0 + 1 } ?? bytes.startIndex
        let handle = try FileHandle(forWritingTo: index)
        defer { try? handle.close() }
        try handle.truncate(atOffset: UInt64(keep))
        try handle.synchronize()
    }

    package static func archiveIndexRows(dataRoot: URL) throws -> [[String: JSONValue]] {
        let index = dataRoot.appendingPathComponent("chat/archive/sessions.jsonl")
        let bytes: Data
        do { bytes = try Data(contentsOf: index) }
        catch CocoaError.fileReadNoSuchFile { return [] }
        let directory = dataRoot.appendingPathComponent("chat/archive/messages", isDirectory: true)
            .resolvingSymlinksInPath().standardizedFileURL
        // A final row without its newline is an append that never finished: not a row. Interior damage still refuses the read.
        let committed = bytes.last == 10 ? bytes : bytes[..<(bytes.lastIndex(of: 10).map { $0 + 1 } ?? bytes.startIndex)]
        return try committed.split(separator: 10).map { line in
            guard case .object(let row) = try JSONValue.parse(Data(line)),
                  case .string(let id)? = row["id"],
                  NativeAgentChatSessionID.normalizedPathComponent(id) != nil else {
                throw CocoaError(.fileReadCorruptFile)
            }
            if case .string(let relative)? = row["messagesArchivePath"] {
                let file = dataRoot.appendingPathComponent(relative).standardizedFileURL
                guard file.resolvingSymlinksInPath().deletingLastPathComponent().path == directory.path else {
                    throw CocoaError(.fileReadCorruptFile)
                }
            }
            return row
        }
    }

    public static func archivedTranscripts(dataRoot: URL) throws -> [String: [URL]] {
        var files: [String: [URL]] = [:]
        for row in try archiveIndexRows(dataRoot: dataRoot).reversed() {
            guard case .string(let id)? = row["id"],
                  case .string(let relative)? = row["messagesArchivePath"] else { continue }
            let file = dataRoot.appendingPathComponent(relative).standardizedFileURL
            if !files[id, default: []].contains(file) { files[id, default: []].append(file) }
        }
        return files
    }

    public static func transcriptFiles(
        dataRoot: URL, sessionId: String? = nil, prefix: String = "", archived: [String: [URL]]
    ) throws -> [(String, URL)] {
        let messages = dataRoot.appendingPathComponent("chat/messages", isDirectory: true)
        if let sessionId {
            guard let id = NativeAgentChatSessionID.normalizedPathComponent(sessionId) else {
                throw CocoaError(.fileReadInvalidFileName)
            }
            let hot = messages.appendingPathComponent("\(id).jsonl")
            let cold = archived[id] ?? []
            return ((FileManager.default.fileExists(atPath: hot.path) || cold.isEmpty ? [hot] : []) + cold)
                .map { (id, $0) }
        }
        let hot: [URL]
        do {
            let files = try FileManager.default.contentsOfDirectory(
                at: messages, includingPropertiesForKeys: [.contentModificationDateKey], options: [.skipsHiddenFiles]
            ).filter { $0.pathExtension == "jsonl" && $0.lastPathComponent.hasPrefix(prefix) }
            // One stat per file, never one per comparison.
            let dated: [(url: URL, at: Date)] = files.map { ($0, transcriptModifiedDate($0) ?? .distantPast) }
            hot = dated.sorted { $0.at == $1.at ? $0.url.lastPathComponent < $1.url.lastPathComponent : $0.at > $1.at }.map(\.url)
        } catch CocoaError.fileReadNoSuchFile { hot = [] }
        let coldDated: [(id: String, files: [URL], at: Date)] = archived.filter { $0.key.hasPrefix(prefix) }
            .map { ($0.key, $0.value, $0.value.first.flatMap(transcriptModifiedDate) ?? .distantPast) }
        let cold: [(String, URL)] = coldDated.sorted { $0.at == $1.at ? $0.id < $1.id : $0.at > $1.at }
            .flatMap { entry in entry.files.map { (entry.id, $0) } }
        return hot.map { ($0.deletingPathExtension().lastPathComponent, $0) } + cold
    }

    /// Restore the newest archived row and copy its bytes into the hot tier, retaining the archive. Nil means no archive row. Known history with unavailable
    /// bytes throws. Caller holds the sessions lock before the transcript lock.
    public static func restoreArchivedRow(
        sessionId: String,
        dataRoot: URL
    ) async throws -> [String: JSONValue]? {
        guard let safeSessionId = NativeAgentChatSessionID.normalizedPathComponent(sessionId) else {
            throw CocoaError(.fileReadInvalidFileName)
        }
        let chat = dataRoot.appendingPathComponent("chat", isDirectory: true)
        guard var row = try archiveIndexRows(dataRoot: dataRoot).last(where: { $0["id"] == .string(sessionId) }) else { return nil }
        // A conversation archived as verified empty (zero messages, no transcript file) has nothing to recover: it restores empty.
        let relative: String?
        if case .string(let path)? = row["messagesArchivePath"] { relative = path }
        else if row["messageCount"] == .int(0) { relative = nil }
        else {
            throw PersistenceCoreError.ioFailure("The archived conversation has no transcript path. Its saved history must be repaired before opening it.")
        }
        let archivedBytes: Data
        do { archivedBytes = try relative.map { try Data(contentsOf: dataRoot.appendingPathComponent($0)) } ?? Data() }
        catch {
            throw PersistenceCoreError.ioFailure(
                """
                    The archived conversation’s transcript could not be read: \(error.localizedDescription). Its saved history must be \
                    repaired before opening it.
                    """)
        }
        let messagesPath = chat
            .appendingPathComponent("messages", isDirectory: true)
            .appendingPathComponent("\(safeSessionId).jsonl")
        try await SwiftNativePersistenceCore.withFileLock(messagesPath) {
            let hot: Data
            do { hot = try Data(contentsOf: messagesPath) }
            catch CocoaError.fileReadNoSuchFile { hot = Data() }
            // The atomic copy may have succeeded before the caller's index commit failed. Its exact prefix also survives later appends.
            if !archivedBytes.isEmpty, hot.starts(with: archivedBytes) { return }
            // Two rows are joined by one LF: an archive that ends without its final newline never fuses with the next row.
            let joint: Data = !archivedBytes.isEmpty && !hot.isEmpty && archivedBytes.last != 10 ? Data([10]) : Data()
            try ContactThread.replace(archivedBytes + joint + hot, to: messagesPath)
        }
        for key in ["archivedBy", "retentionArchivedAt", "retentionReason", "messagesArchivePath"] {
            row.removeValue(forKey: key)
        }
        row["archived"] = .bool(false)
        return row
    }

}
