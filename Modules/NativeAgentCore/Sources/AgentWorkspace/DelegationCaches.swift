import ChatSessionWork
import Foundation
import NativeAgentShared
import PersistenceCore
import NativeAgentCore
import Darwin
import AppKit
import MacControl
import Desk
import StandingBots
import Transcripts
import ChatToolParsing
// Blueprint: | `DelegationCaches.swift` | Read acceleration over unchanged file stamps |

/// Reuse parses by regular-file stamp, but rerun time-dependent projections on every read.
final class DelegationFileCache: @unchecked Sendable {
    private let lock = NSLock()
    private var jobs: [String: [String: (stamp: SnapshotTailOpLog.FileStamp, object: [String: JSONValue])]] = [:]

    static func stamp(_ url: URL) throws -> SnapshotTailOpLog.FileStamp {
        var info = stat()
        guard stat(url.path, &info) == 0, info.st_mode & S_IFMT == S_IFREG else { throw CocoaError(.fileReadUnknown) }
        return SnapshotTailOpLog.FileStamp(info)
    }

    func jobSnapshot(_ directory: String) -> [String: (stamp: SnapshotTailOpLog.FileStamp, object: [String: JSONValue])] {
        lock.withLock { jobs[directory] ?? [:] }
    }
    func putJobs(_ directory: String, _ files: [String: (stamp: SnapshotTailOpLog.FileStamp, object: [String: JSONValue])]) {
        lock.withLock { jobs[directory] = files }
    }
}
