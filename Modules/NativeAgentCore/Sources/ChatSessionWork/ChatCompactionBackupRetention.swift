import Foundation
import NativeAgentCore
import PersistenceCore
import Transcripts

/// Result of one bounded sweep over pre-compaction transcript backups.
public struct ChatCompactionBackupRetentionReport: Sendable, Equatable {
    public let sessionsScanned: Int
    public let removedArtifactPaths: [String]
    public let failures: Int
    public let truncated: Bool

    public var removed: Int { removedArtifactPaths.count }

    public init(
        sessionsScanned: Int,
        removedArtifactPaths: [String],
        failures: Int,
        truncated: Bool
    ) {
        self.sessionsScanned = sessionsScanned
        self.removedArtifactPaths = removedArtifactPaths
        self.failures = failures
        self.truncated = truncated
    }
}

/// Converges old session directories to the same five-backup recovery window
/// enforced immediately after a successful compaction. This is intentionally a
/// maintenance operation rather than another background loop.
public enum ChatCompactionBackupRetention {
    public static let defaultMaximumSessions = 500
    public static let recoveryWindowSeconds: TimeInterval = 30 * 24 * 60 * 60
    public static let maximumRecoverySessions = 200
    public static let maximumRecoveryBytes: Int64 = 128 * 1024 * 1024

    public static func enforce(
        dataRoot: URL,
        maximumSessions: Int = defaultMaximumSessions,
        now: Date = Date(),
        persistence: SwiftNativePersistenceCore = SwiftNativePersistenceCore()
    ) async -> ChatCompactionBackupRetentionReport {
        let sessionsRoot = dataRoot
            .appendingPathComponent("chat", isDirectory: true)
            .appendingPathComponent("sessions", isDirectory: true)
        guard maximumSessions > 0,
              let entries = try? FileManager.default.contentsOfDirectory(
                  at: sessionsRoot,
                  includingPropertiesForKeys: [.isDirectoryKey],
                  options: [.skipsHiddenFiles]
              )
        else {
            return ChatCompactionBackupRetentionReport(
                sessionsScanned: 0,
                removedArtifactPaths: [],
                failures: 0,
                truncated: false
            )
        }

        let inventory = entries.compactMap { directory -> (directory: URL, count: Int, bytes: Int64, newest: Date)? in
            guard (try? directory.resourceValues(forKeys: [.isDirectoryKey, .isSymbolicLinkKey]).isDirectory) == true,
                  directory.resolvingSymlinksInPath() == directory.standardizedFileURL,
                  NativeAgentChatSessionID.normalizedPathComponent(directory.lastPathComponent) == directory.lastPathComponent,
                  let children = try? FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil)
            else { return nil }
            let backups = children.filter(Self.isCompactBackup)
            guard !backups.isEmpty else { return nil }
            var bytes: Int64 = 0
            var newest = Date.distantPast
            for file in backups {
                guard let values = try? file.resourceValues(forKeys: [.fileSizeKey, .contentModificationDateKey, .isRegularFileKey, .isSymbolicLinkKey]),
                      values.isRegularFile == true, values.isSymbolicLink != true,
                      let size = values.fileSize, let modified = values.contentModificationDate else { return nil }
                bytes += Int64(size)
                newest = max(newest, modified)
            }
            return (directory, backups.count, bytes, newest)
        }.sorted { $0.newest > $1.newest }
        var retainedBytes: Int64 = 0
        let cutoff = now.addingTimeInterval(-recoveryWindowSeconds)
        let candidates = inventory.enumerated().compactMap { offset, item -> (directory: URL, retire: Bool, newest: Date)? in
            retainedBytes += item.bytes
            let retire = item.newest < cutoff || offset >= maximumRecoverySessions || retainedBytes > maximumRecoveryBytes
            return retire || item.count > ChatSessionAutocompactor.maximumCompactBackups ? (item.directory, retire, item.newest) : nil
        }.sorted { $0.directory.lastPathComponent < $1.directory.lastPathComponent }
        let selected = candidates.prefix(maximumSessions)
        var removedPaths: [String] = []
        var failures = 0

        for candidate in selected {
            let directory = candidate.directory
            let sessionID = directory.lastPathComponent
            let transcript = dataRoot
                .appendingPathComponent("chat/messages", isDirectory: true)
                .appendingPathComponent("\(sessionID).jsonl")
            do {
                let index = dataRoot.appendingPathComponent("chat/sessions.json")
                let result = try await persistence.withFileLock(index) {
                    let rows = try ChatSessionIndexFile.loadObjectRowsForMutation(at: index)
                    var canonical = rows.first { $0["id"] == .string(sessionID) }
                    if canonical == nil {
                        let archiveIndex = dataRoot.appendingPathComponent("chat/archive/sessions.jsonl")
                        let archive = try await persistence.readJSONLReporting(archiveIndex)
                        guard archive.report.malformedLineCount == 0, !archive.report.trailingPartialLine else {
                            throw NSError(domain: "NativeAgent.ChatCompactionRetention", code: 1)
                        }
                        canonical = archive.rows.compactMap { row -> [String: JSONValue]? in
                            guard case .object(let fields) = row, fields["id"] == .string(sessionID) else { return nil }
                            return fields
                        }.last
                    }
                    guard let canonical else { throw NSError(domain: "NativeAgent.ChatCompactionRetention", code: 2) }
                    return try await persistence.withFileLock(transcript) {
                        let source: URL
                        if FileManager.default.fileExists(atPath: transcript.path) { source = transcript }
                        else if case .string(let relative)? = canonical["messagesArchivePath"],
                                relative.hasPrefix("chat/archive/messages/"), !relative.contains("..") {
                            source = dataRoot.appendingPathComponent(relative)
                        } else { throw NSError(domain: "NativeAgent.ChatCompactionRetention", code: 3) }
                        guard FileManager.default.fileExists(atPath: source.path) else {
                            throw NSError(domain: "NativeAgent.ChatCompactionRetention", code: 4)
                        }
                        let scan = try await persistence.readJSONLReporting(source)
                        guard scan.report.malformedLineCount == 0, !scan.report.trailingPartialLine else {
                            throw NSError(domain: "NativeAgent.ChatCompactionRetention", code: 5)
                        }
                        let files = try FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: [.contentModificationDateKey])
                        let unchanged = files.filter(Self.isCompactBackup).allSatisfy {
                            ((try? $0.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? .distantFuture) <= candidate.newest
                        }
                        let keeping = candidate.retire && unchanged ? 0 : ChatSessionAutocompactor.maximumCompactBackups
                        let removed = ChatSessionAutocompactor.pruneCompactBackups(
                            in: directory, keeping: keeping,
                            originals: ChatSessionAutocompactor.originalsPath(dataRoot: dataRoot, sessionId: sessionID),
                            pendingRows: scan.rows
                        )
                        let remaining = try FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil)
                            .filter(Self.isCompactBackup)
                        let protected = ChatSessionAutocompactor.protectedCompactBackupNames(in: scan.rows)
                        let unprotected = protected.map { names in remaining.filter { !names.contains($0.lastPathComponent) }.count } ?? 0
                        if remaining.isEmpty,
                           (try? FileManager.default.contentsOfDirectory(atPath: directory.path).isEmpty) == true {
                            try FileManager.default.removeItem(at: directory)
                        }
                        return (removed: removed, converged: unprotected <= keeping)
                    }
                }
                removedPaths.append(contentsOf: result.removed.map {
                    "chat/sessions/\(sessionID)/\($0.lastPathComponent)"
                })
                if !result.converged { failures += 1 }
            } catch {
                nativeLog("Chat compaction retention: preserved recovery copies for %@: %@", sessionID, String(describing: error))
                failures += 1
            }
        }

        return ChatCompactionBackupRetentionReport(
            sessionsScanned: selected.count,
            removedArtifactPaths: removedPaths.sorted(),
            failures: failures,
            truncated: candidates.count > selected.count
        )
    }

    private static func isCompactBackup(_ url: URL) -> Bool {
        url.lastPathComponent.hasPrefix("messages.compact.") && url.pathExtension == "jsonl"
    }
}
