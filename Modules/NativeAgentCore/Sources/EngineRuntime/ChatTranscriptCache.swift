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
// Blueprint: | `ChatTranscriptCache.swift` | `ChatTranscriptCache`; One decoded disk revision shared by transcript readers |

/// Share one decoded revision across readers; optimistic rows and rendering remain outside the disk cache.
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
            if let hit = cached[session.id], hit.revision == revision, hit.issue == nil {
                projections[session.id] = hit
            } else {
                do {
                    var projection = try ChatShellOpeningLine.read(sessionID: session.id, dataRoot: dataRoot)
                    projection.revision = revision
                    projection.lastTurn = try ChatShellOpeningLine.readLastTurn(sessionID: session.id, dataRoot: dataRoot)
                    projections[session.id] = projection
                } catch is CancellationError {
                    throw CancellationError()
                } catch {
                    projections[session.id] = .init(revision: revision,
                        issue: UserFacingError.cause(error, action: "read this conversation's transcript"))
                }
            }
        }
        return projections
    }

    func history(at path: URL, cached: Bool = true, limit: Int? = nil) async throws
        -> (history: SessionHistoryReadResult, cacheHit: Bool) {
        let key = path.path
        let before = Self.identity(at: path)
        if before == nil || entries[key]?.identity != before {
            entries[key] = nil
            recentPaths.removeAll { $0 == key }
        }
        if cached, let history = entries[key]?.history {
            touch(key)
            return (history, true)
        }
        let root = path.deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        let history = try await SessionHistoryReader(dataRoot: root).messagesWithStats(
            forSessionId: path.deletingPathExtension().lastPathComponent, limit: limit)
        // A writer may advance during the load; return this read without certifying a different revision.
        if !history.stats.truncated, let before, Self.identity(at: path) == before, history.stats.mode != "read_failed" {
            store(Entry(identity: before, history: history), for: key)
        }
        return (history, false)
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
        // Cache only inspected regular files. ctime catches restored-mtime rewrites and permission changes; inode catches replacement.
        guard lstat(path.path, &info) == 0,
              (info.st_mode & mode_t(S_IFMT)) == mode_t(S_IFREG) else { return nil }
        return SnapshotTailOpLog.FileStamp(info)
    }
}
