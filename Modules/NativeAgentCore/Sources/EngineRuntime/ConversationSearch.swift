import Foundation
import Cognition
import ChatSessionWork
import Transcripts
import NativeAgentCore
@_exported import NativeAgentShared
import StandingBots
import MemoryV2
import Connectors
import DeviceSync
import PersistenceCore
import ProviderRouting
import CloudKit
import DoctorChecks
import Observation
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
import Darwin
import Combine
import UserNotifications
import Research
import ImageIO
import UniformTypeIdentifiers
import AppKit
import Dispatcher
import SystemOps
import CoreGraphics
// Blueprint: | `ConversationSearch.swift` | Canonical conversation ranking, saved-result readers and cause-preserving message index |

public enum ConversationPaletteRanking {
    public static func matches(_ sessions: [NativeAgentShared.ChatSession], query: String) -> [[String]] {
        let query = query.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard !query.isEmpty else { return [] }
        let ordered = sessions.filter { $0.archived != true }.sorted {
            let lhs = $0.updatedAt ?? $0.createdAt, rhs = $1.updatedAt ?? $1.createdAt
            return lhs == rhs ? $0.id < $1.id : lhs > rhs
        }
        var ranks: [Int: [String]] = [:]
        for session in ordered {
            let title = ChatShellConversationRow.faceTitle(session.displayTitle).lowercased()
            let preview = ChatShellConversationRow.preview(for: session).lowercased()
            let rank: Int
            if title == query { rank = 0 }
            else if title.hasPrefix(query) { rank = 1 }
            else if preview.hasPrefix(query) { rank = 2 }
            else if title.contains(query) { rank = 3 }
            else if preview.contains(query) { rank = 4 }
            else { continue }
            ranks[rank, default: []].append(session.id)
        }
        return (0..<5).map { ranks[$0] ?? [] }
    }
}

extension TranscriptsFacade {
    public func observeSavedSearch(bots: BotRunnerScheduler, memory: MemoryFacade) async {
        let paths = ["memory/memory.sqlite", "memory/memory.sqlite-wal", "bots/definitions",
                     "bots/shelf-index.json", "clock/times.json", "bots/missed-runs.json", "bots/last-events.json", "trust/policy.json"]
        await EventDeadlinePhysiology.refreshOnChanges(paths: paths.map { dataRoot.appendingPathComponent($0) },
                                                       notifications: [BotRunQueue.didChange]) {
            await self.refreshSavedSearch(bots: bots, memory: memory)
        }
    }

    /// Share saved search inputs with the transcript owner; Desk and dreams own their revisions.
    public func refreshSavedSearch(bots: BotRunnerScheduler, memory: MemoryFacade) async {
        _ = await savedSearchRead.read({
        var failures: [String] = []
        var botReplies: [(BotsShelfRecord, ShelfEntry)]?
        var memories: [MemoryV2.MemoryRecord]?
        do {
            let timing = try await bots.effectiveSchedule()
            let root = dataRoot
            let records = try await Task.detached(priority: .utility) {
                try BotsShelfRecord.read(root: root, timing: timing)
            }.value
            let replies = records.flatMap { record in
                record.sortedEntries.filter { !$0.actualReply.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
                    .map { (record, $0) }
            }.sorted { $0.1.runAt > $1.1.runAt }
            botReplies = Array(replies.prefix(40))
        } catch {
            failures.append(UserFacingError.message(error, action: "read saved bot replies"))
        }
        do {
            memories = try await memory.activeMemories(limit: nil)
        } catch {
            failures.append(UserFacingError.message(error, action: "read saved memories"))
        }
        return (botReplies, memories, failures)
        }, publish: { botReplies, memories, failures in
        if let botReplies { savedBotReplies = botReplies }
        if let memories { savedMemories = memories }
        savedSearchError = failures.isEmpty ? nil
            : (failures + ["Saved results may be out of date."]).joined(separator: " ")
        })
    }
}

/// Share visible search words across open chat and the palette; revision-driven indexes stay scoped to each engine root.
public actor CommandPaletteMessageIndex {

    public struct Hit: Sendable {
        public let sessionID: String
        public let snippet: String
    }

    private struct Snapshot: Sendable {
        var texts: [String: (stamp: String, lines: [String])] = [:]
        var order: [String] = []
    }

    @MainActor private final class SearchSnapshotPublication {
        var snapshot = Snapshot()
        let latest = LatestRead()
        nonisolated init() {}

        func refresh(_ sessions: [(id: String, stamp: String)], transcripts: TranscriptsFacade) async -> [String: String] {
            let read = await latest.read({
                let stale = sessions.filter { snapshot.texts[$0.id]?.stamp != $0.stamp }
                return await withTaskGroup(of: (String, String, [String]?, String?).self) { group in
                    for session in stale {
                        group.addTask {
                            guard let safeID = NativeAgentChatSessionID.normalizedPathComponent(session.id) else {
                                return (session.id, session.stamp, nil, "The saved conversation id is not a safe path component.")
                            }
                            do {
                                let transcript = try await transcripts.readTranscript(safeSessionId: safeID)
                                return (session.id, session.stamp, TranscriptSearch.documents(from: transcript.messages).map(\.content), nil)
                            } catch { return (session.id, session.stamp, nil, error.localizedDescription) }
                        }
                    }
                    var read: [(String, String, [String]?, String?)] = []
                    for await row in group { read.append(row) }
                    return read
                }
            }, publish: { read in
                snapshot.order = sessions.map(\.id)
                for (id, stamp, lines, _) in read {
                    if let lines { snapshot.texts[id] = (stamp, lines) }
                }
                let kept = Set(snapshot.order)
                snapshot.texts = snapshot.texts.filter { kept.contains($0.key) }
            })
            return read.reduce(into: [:]) { if let issue = $1.3 { $0[$1.0] = issue } }
        }
    }
    private let projection = SearchSnapshotPublication()

    public nonisolated static func stamp(_ session: NativeAgentShared.ChatSession) -> String {
        "\(session.updatedAt ?? session.createdAt)|\(session.transcriptGeneration ?? -1)|\(session.messageCount ?? -1)"
    }

    /// Failed reads retain proven text without caching failure; the next revision refresh can read it again.
    public func refreshWithFailures(_ sessions: [(id: String, stamp: String)], transcripts: TranscriptsFacade) async -> [String: String] {
        await projection.refresh(sessions, transcripts: transcripts)
    }

    public func search(_ query: String) async -> [Hit] {
        let snapshot = await projection.snapshot
        let texts = snapshot.texts
        let order = snapshot.order
        var hits: [Hit] = []
        for id in order {
            guard !Task.isCancelled else { break }
            guard let lines = texts[id]?.lines else { continue }
            for line in lines.reversed() {
                guard let range = line.range(of: query, options: .caseInsensitive) else { continue }
                hits.append(Hit(sessionID: id, snippet: Self.snippet(line, around: range)))
                break
            }
        }
        return hits
    }

    private static func snippet(_ text: String, around range: Range<String.Index>) -> String {
        var start = text.index(range.lowerBound, offsetBy: -40, limitedBy: text.startIndex) ?? text.startIndex
        if start != text.startIndex, let space = text[start..<range.lowerBound].firstIndex(of: " ") {
            start = text.index(after: space)
        }
        let flat = text[start...].split(whereSeparator: \.isNewline).joined(separator: " ")
        return (start == text.startIndex ? "" : "…") + TodayWords.line(flat, limit: 90)
    }
}

extension TranscriptSearch {
    public static func documents(from messages: [ChatMessage]) -> [TranscriptSearchDocument] {
        messages.enumerated().compactMap { ordinal, message in
            document(from: message, ordinal: ordinal)
        }
    }

    public static func document(from message: ChatMessage, ordinal: Int) -> TranscriptSearchDocument? {
        let role = message.role.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard role != "tool" else { return nil }
        guard !(role == "system" && message.content.hasPrefix("[tool:")) else { return nil }
        let visible = visibleText(of: message)
        guard !visible.isEmpty else { return nil }
        return TranscriptSearchDocument(
            messageID: message.id,
            ordinal: ordinal,
            content: visible
        )
    }

    /// Rendering and search must share provenance-selected visible words.
    public static func visibleText(of message: ChatMessage) -> String {
        let content = message.content
        let bridged = ChatShellConversationRow.isBridgeRouted(message.metadata?.origin)
        let role = message.role.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        if role == "user", bridged, ChatShellEnvelope.isEnvelope(content, envelope: message.metadata?.envelope) {
            return DelegatedReplyEnvelope(content).reply
        }
        if role == "user", ["agent-bridge", "bot"].contains(message.metadata?.origin?.surface?
            .trimmingCharacters(in: .whitespacesAndNewlines).lowercased() ?? "") {
            return ContactThread.bridgedText(content)
        }
        guard bridged, ChatShellConversationRow.hasBridgePrefix(content) else { return content }
        return ChatShellConversationRow.stripBridgePrefix(content)
    }

}
