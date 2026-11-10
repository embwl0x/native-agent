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

/// Hold decoded history across appends; optimistic rows and rendering remain outside the disk cache.
public actor ChatTranscriptCache {
    static let shared = ChatTranscriptCache()

    private struct Entry {
        let identity: SnapshotTailOpLog.FileStamp
        var history: SessionHistoryReadResult
        let offset: Int64?
        let boundary: Data
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
        // Taking the entry lets an unshared message array grow in place.
        var entry = entries.removeValue(forKey: key)
        recentPaths.removeAll { $0 == key }
        if cached, let before, let hit = entry, hit.identity == before {
            store(hit, for: key)
            return (hit.history, true)
        }
        let root = path.deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        if limit == nil, cached, let offset = entry?.offset,
           case .present(_, _, let size, _, _, _, _)? = before, size > offset {
            let reader = SessionHistoryReader(dataRoot: root)
            let id = path.deletingPathExtension().lastPathComponent
            if let safeID = NativeAgentChatSessionID.normalizedPathComponent(id) {
                let source = try reader.transcriptPath(for: safeID, transcriptURL: nil)
                if let appended = try appendHistory(at: source, key: key, id: safeID, entry: &entry) { return appended }
            }
        }
        let history = try await SessionHistoryReader(dataRoot: root).messagesWithStats(
            forSessionId: path.deletingPathExtension().lastPathComponent, limit: limit)
        // Retention inspects only the boundary; the owner's full/limited read above is returned unchanged.
        if !history.stats.truncated, let before, Self.identity(at: path) == before, history.stats.mode != "read_failed",
           case .present(_, _, let size, _, _, _, _) = before {
            let boundary: Data?
            do { boundary = try Self.boundary(at: path, identity: before) }
            catch { return (history, false) } // Unreadable cache metadata cannot certify a held revision.
            if let boundary, Self.identity(at: path) == before {
                let offset: Int64? = limit == nil && ["full", "damaged_history"].contains(history.stats.mode) ? size : nil
                store(Entry(identity: before, history: history, offset: offset, boundary: boundary), for: key)
            }
        }
        return (history, false)
    }

    private func appendHistory(at source: URL, key: String, id: String, entry: inout Entry?) throws
        -> (history: SessionHistoryReadResult, cacheHit: Bool)? {
        let handle: FileHandle
        do { handle = try FileHandle(forReadingFrom: source) }
        catch let error as CocoaError where error.isFileAbsent { return nil }
        let result = Result { try readHistory(handle, source: source, key: key, id: id, entry: &entry) }
        do { try handle.close() }
        catch {
            entries[key] = nil
            recentPaths.removeAll { $0 == key }
            if case .failure(let readError) = result {
                throw NSError(domain: "NativeAgent.ChatHistory", code: 1, userInfo: [NSLocalizedDescriptionKey:
                    "Reading this conversation failed: \(readError.localizedDescription). Closing its file also failed: \(error.localizedDescription)."])
            }
            throw error
        }
        return try result.get()
    }

    private func readHistory(_ handle: FileHandle, source: URL, key: String, id: String, entry: inout Entry?) throws
        -> (history: SessionHistoryReadResult, cacheHit: Bool)? {
        var info = stat()
        guard fstat(handle.fileDescriptor, &info) == 0 else {
            throw NSError(domain: NSPOSIXErrorDomain, code: Int(errno))
        }
        guard let size = Int(exactly: info.st_size), size >= 0 else { throw CocoaError(.fileReadTooLarge) }
        let identity = SnapshotTailOpLog.FileStamp(info)
        if let offset = entry?.offset, let heldIdentity = entry?.identity,
           case .present(let device, let inode, _, _, _, _, _) = heldIdentity,
           device == info.st_dev, inode == info.st_ino, offset < info.st_size,
           let start = Int(exactly: offset), let boundary = entry?.boundary,
           boundary.count <= start {
            let checked = try Self.bytes(handle, from: start - boundary.count, count: boundary.count)
            // Transcript mutations append on this inode or replace it atomically; the exact boundary also detects tail edits.
            if checked == boundary {
                let appended = try Self.bytes(handle, from: start, count: size - start)
                if appended.last == 0x0A, var held = entry {
                    entry = nil
                    let previousLines = held.history.stats.linesRead
                    try SessionHistoryReader.appendCompleteMessages(from: appended, sourceBytes: Int64(size), to: &held.history)
                    let history = held.history
                    if ["full", "damaged_history"].contains(history.stats.mode) {
                        if appended.dropLast().last != 0x0D, Self.identity(at: source) == identity {
                            store(Entry(identity: identity, history: history, offset: Int64(size), boundary: Self.boundary(in: appended)), for: key)
                        }
                        ModuleLog.app("[transcript-tail] session=%@ prefix=%lld appended=%ld rows=%ld", id, offset,
                            appended.count, history.stats.linesRead - previousLines)
                    }
                    return (history, false)
                }
            }
        }
        entry = nil
        return nil
    }

    private static func bytes(_ handle: FileHandle, from offset: Int, count: Int) throws -> Data {
        guard count > 0 else { return Data() }
        guard let data = try ContactThread.read(handle, from: UInt64(offset), bytes: count), data.count == count else {
            throw CocoaError(.fileReadCorruptFile)
        }
        return data
    }

    private static func boundary(in data: Data) -> Data {
        let preceding = data.dropLast()
        if let newline = preceding.lastIndex(of: 0x0A) { return Data(data[data.index(after: newline)...]) }
        return data
    }

    private static func boundary(at path: URL, identity: SnapshotTailOpLog.FileStamp) throws -> Data? {
        let handle = try FileHandle(forReadingFrom: path)
        let result = Result<Data?, Error> {
            var info = stat()
            guard fstat(handle.fileDescriptor, &info) == 0 else { throw NSError(domain: NSPOSIXErrorDomain, code: Int(errno)) }
            guard SnapshotTailOpLog.FileStamp(info) == identity,
                  let size = Int(exactly: info.st_size), size > 0,
                  try bytes(handle, from: size - 1, count: 1).last == 0x0A else { return nil }
            var end = size - 1
            var start = 0
            while end > 0 {
                let offset = max(0, end - 4096)
                let chunk = try bytes(handle, from: offset, count: end - offset)
                if let newline = chunk.lastIndex(of: 0x0A) {
                    start = offset + chunk.distance(from: chunk.startIndex, to: newline) + 1
                    break
                }
                end = offset
            }
            let boundary = try bytes(handle, from: start, count: size - start)
            // String's LF splitter keeps CRLF as one character; that boundary cannot separate decoded selections.
            return boundary.dropLast().last == 0x0D ? nil : boundary
        }
        try handle.close()
        return try result.get()
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
