import Foundation
import Darwin
import ChatSessionWork
@_exported import NativeAgentShared
import PersistenceCore
import Connectors
import DeviceSync
import NativeAgentCore
import ProviderRouting
import CloudKit
import DoctorChecks
import MemoryV2
import StandingBots
import Observation
import Cognition
import ChatToolRuntime
import ChatTurnRuntime
import ChatToolParsing
import SlackBot
import TelegramBot
import TriggerScheduler
import WorkshopExecution
import BackgroundLoops
import AppToolRuntime
import TrustCenter
import MacControl
import ApprovalTransactions
import AttentionRouting
import ApprovalInbox
import Desk
import NotificationInbox
import ToolRegistry
import Transcripts
import ChatTurnContracts
import BackgroundWork
import DreamREMCycle
import AuthoredCapabilities
@preconcurrency import EventKit
import MacIntegration
import ToolExecution
import Senses
import Browser
import PersonaEngine
import AgentWorkspace
import Synchronization
import Studio
import Agents
import AgentConversations
import ChromeControl
import CognitiveSubstrate
import Context
import ContextFlow
import TurnTrace
import os
import TrustPersistence
import SwarmRuns
import Onboarding
import Privacy
import Experiences
import CryptoKit
import ActivityWatch
import OSLog
import Procedures
import SchedulerExecution
import Combine
import UserNotifications
import Research
import ImageIO
import UniformTypeIdentifiers
import AppKit
import Dispatcher
import SystemOps
import CoreGraphics
// Blueprint: | `ChatTranscriptCache.swift` | `ChatTranscriptCache`: file-identity disk revisions feed transcript messages, recollections, context statistics and search; bounded shell opening/last-turn scans share the cache owner |

/// One decoded disk revision feeds messages, recollections, raw context counts
/// and search; optimistic rows and rendering stay outside this cache.
public actor ChatTranscriptCache {
    static let shared = ChatTranscriptCache()

    private struct Entry {
        let identity: SnapshotTailOpLog.FileStamp
        let history: SessionHistoryReadResult
    }

    private var entries: [String: Entry] = [:]
    private var recentPaths: [String] = []
    private let maximumSessions = 8

    func shellProjections(
        for sessions: [NativeAgentShared.ChatSession], dataRoot: URL,
        cached: [String: ChatShellOpeningLine.OpeningLine]
    ) throws -> [String: ChatShellOpeningLine.OpeningLine] {
        var projections: [String: ChatShellOpeningLine.OpeningLine] = [:]
        for session in sessions {
            try Task.checkCancellation()
            let revision = ChatShellOpeningLine.revision(for: session)
            if let hit = cached[session.id], hit.revision == revision {
                projections[session.id] = hit
            } else {
                var projection = ChatShellOpeningLine.read(sessionID: session.id, dataRoot: dataRoot)
                projection.revision = revision
                projection.lastTurn = ChatShellOpeningLine.readLastTurn(sessionID: session.id, dataRoot: dataRoot)
                projections[session.id] = projection
            }
        }
        return projections
    }

    func history(at path: URL, cached: Bool = true) async throws -> SessionHistoryReadResult {
        let key = path.path
        let before = Self.identity(at: path)
        if before == nil || entries[key]?.identity != before {
            entries[key] = nil
            recentPaths.removeAll { $0 == key }
        }
        if cached, let history = entries[key]?.history {
            touch(key)
            return history
        }
        let root = path.deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        let history = try await SessionHistoryReader(dataRoot: root).messagesWithStats(forSessionId: path.deletingPathExtension().lastPathComponent)
        // A writer can advance the file while the asynchronous loader is
        // running. Return that read under the existing selection semantics,
        // but never certify it as the projection of a different revision.
        if let before, Self.identity(at: path) == before, history.stats.mode != "read_failed" {
            store(Entry(identity: before, history: history), for: key)
        }
        return history
    }

    func contextStatistics(at path: URL) async -> (totalChars: Int, messageCount: Int) {
        (try? await history(at: path).contextStatistics) ?? (0, 0)
    }

    private func store(_ entry: Entry, for key: String) {
        entries[key] = entry
        touch(key)
        while recentPaths.count > maximumSessions {
            entries[recentPaths.removeFirst()] = nil
        }
    }

    private func touch(_ key: String) {
        recentPaths.removeAll { $0 == key }
        recentPaths.append(key)
    }

    private static func identity(at path: URL) -> SnapshotTailOpLog.FileStamp? {
        var info = stat()
        // Do not cache missing paths, symlinks, nonregular entries or failed
        // inspections. ctime catches same-size rewrites with restored mtime
        // as well as permission changes; inode catches atomic replacement.
        guard lstat(path.path, &info) == 0,
              (info.st_mode & mode_t(S_IFMT)) == mode_t(S_IFREG) else { return nil }
        return SnapshotTailOpLog.FileStamp(info)
    }
}
