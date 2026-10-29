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
// Blueprint: | `ConversationSearch.swift` | `CommandPaletteMessageIndex` and saved bot/memory search inputs remain owned by `TranscriptsFacade`; `LatestRead` orders checked publication per root; `TranscriptSearch` projects the same provenance-selected visible words as conversation rendering |

extension TranscriptsFacade {
    public func observeSavedSearch(bots: BotRunnerScheduler, memory: MemoryFacade) async {
        let paths = ["memory/memory.sqlite", "memory/memory.sqlite-wal", "bots/definitions",
                     "bots/shelf-index.json", "bots/runner-jobs.json", "bots/last-events.json", "trust/policy.json"]
        await EventDeadlinePhysiology.refreshOnChanges(paths: paths.map { dataRoot.appendingPathComponent($0) },
                                                       notifications: [BotRunQueue.didChange]) {
            await self.refreshSavedSearch(bots: bots, memory: memory)
        }
    }

    /// The remaining saved search inputs share the transcript search owner;
    /// Desk and dreams already publish their own revisions.
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

/// Every visible conversation's words, for ⌘K: the text ⌘F searches in the
/// open chat (`MacChatTranscriptSearch`), across all of them. A transcript is
/// read again when its session or transcript revision moves. Each engine's
/// transcript facade owns its index, so roots never share search documents.
public actor CommandPaletteMessageIndex {

    public struct Hit: Sendable {
        public let sessionID: String
        public let snippet: String
    }

    private struct Snapshot: Sendable {
        var texts: [String: (stamp: String, lines: [String])] = [:]
        /// Newest conversation first, as the palette lists them.
        var order: [String] = []
    }

    @MainActor private final class SearchSnapshotPublication {
        var snapshot = Snapshot()
        let latest = LatestRead()
        nonisolated init() {}

        func refresh(_ sessions: [(id: String, stamp: String)], transcripts: TranscriptsFacade) async -> Int {
            let read = await latest.read({
                let stale = sessions.filter { snapshot.texts[$0.id]?.stamp != $0.stamp }
                return await withTaskGroup(of: (String, String, [String]?).self) { group in
                    for session in stale {
                        group.addTask {
                            guard let safeID = NativeAgentChatSessionID.normalizedPathComponent(session.id) else { return (session.id, session.stamp, []) }
                            guard let transcript = try? await transcripts.readTranscript(safeSessionId: safeID) else {
                                return (session.id, session.stamp, nil)
                            }
                            return (session.id, session.stamp, TranscriptSearch.documents(from: transcript.messages).map(\.content))
                        }
                    }
                    var read: [(String, String, [String]?)] = []
                    for await row in group { read.append(row) }
                    return read
                }
            }, publish: { read in
                snapshot.order = sessions.map(\.id)
                for (id, stamp, lines) in read {
                    if let lines { snapshot.texts[id] = (stamp, lines) }
                }
                let kept = Set(snapshot.order)
                snapshot.texts = snapshot.texts.filter { kept.contains($0.key) }
            })
            return read.filter { $0.2 == nil }.count
        }
    }
    private let projection = SearchSnapshotPublication()

    public nonisolated static func stamp(_ session: NativeAgentShared.ChatSession) -> String {
        "\(session.updatedAt ?? session.createdAt)|\(session.transcriptGeneration ?? -1)|\(session.messageCount ?? -1)"
    }

    /// Reads what changed and returns how many conversations could not be
    /// read. A failed read is not cached: it keeps whatever text it had
    /// before, and is tried again on the next revision refresh.
    public func refresh(_ sessions: [(id: String, stamp: String)], transcripts: TranscriptsFacade) async -> Int {
        await projection.refresh(sessions, transcripts: transcripts)
    }

    /// The newest line in each conversation that holds `query`, newest
    /// conversation first, every conversation that has one.
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

    /// A line of the message starting a few words before the match.
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

    /// Rendering and search share visible words selected by recorded provenance.
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
