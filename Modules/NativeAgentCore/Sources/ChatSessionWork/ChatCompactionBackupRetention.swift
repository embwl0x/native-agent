import Foundation
import NativeAgentCore
import PersistenceCore

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

    public static func enforce(
        dataRoot: URL,
        maximumSessions: Int = defaultMaximumSessions,
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

        // Select only directories that presently need work. Once the first
        // bounded group converges it drops out, so a large historical backlog
        // drains across later wakes instead of starving behind the same first
        // 500 healthy session directories forever.
        let candidates = entries.filter {
            guard (try? $0.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true,
                  NativeAgentChatSessionID.normalizedPathComponent($0.lastPathComponent) != nil,
                  let children = try? FileManager.default.contentsOfDirectory(
                      at: $0,
                      includingPropertiesForKeys: nil
                  )
            else { return false }
            return children.lazy.filter(Self.isCompactBackup).count
                > ChatSessionAutocompactor.maximumCompactBackups
        }.sorted { $0.lastPathComponent < $1.lastPathComponent }
        let selected = candidates.prefix(maximumSessions)
        var removedPaths: [String] = []
        var failures = 0

        for directory in selected {
            let sessionID = directory.lastPathComponent
            let transcript = dataRoot
                .appendingPathComponent("chat/messages", isDirectory: true)
                .appendingPathComponent("\(sessionID).jsonl")
            do {
                let result = try await persistence.withFileLock(transcript) {
                    let removed = ChatSessionAutocompactor.pruneCompactBackups(
                        in: directory,
                        keeping: ChatSessionAutocompactor.maximumCompactBackups
                    )
                    let remaining = (try? FileManager.default.contentsOfDirectory(
                        at: directory,
                        includingPropertiesForKeys: nil
                    ).lazy.filter(Self.isCompactBackup).count) ?? Int.max
                    return (removed: removed, converged: remaining <= ChatSessionAutocompactor.maximumCompactBackups)
                }
                removedPaths.append(contentsOf: result.removed.map {
                    "chat/sessions/\(sessionID)/\($0.lastPathComponent)"
                })
                if !result.converged { failures += 1 }
            } catch {
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
