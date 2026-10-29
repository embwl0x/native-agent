import AppToolRuntime
import Transcripts
import ApprovalTransactions
import Foundation
import Observation
import ChatTurnRuntime
import AgentWorkspace
import ChatSessionWork
import NativeAgentCore
import NativeAgentShared
import PersistenceCore
import ProviderRouting
import Cognition
import StandingBots
import MemoryV2
import AuthoredCapabilities
import AttentionRouting
import TurnTrace
import Privacy
import MacControl
import Darwin
import ChatTurnContracts
import ChatToolParsing
// Blueprint: | `TranscriptReadout.swift` | Transcript/card structures, page-bounded inline mounts and structural message grouping |
extension InlineCards {
    @MainActor
    public static func cardsByRow(
        _ pairs: [(rowID: String, interaction: InlineInteraction)], messages: [ChatMessage],
        sessionID: String, dataRoot: URL
    ) async -> (cardsByRow: [String: [TranscriptReadout.Card]], heading: String) {
        var built: [String: [TranscriptReadout.Card]] = [:]
        var collapsed = InlineInteractionResolver.collapsedCards(pairs)
        var origins = collapsed.pairs.map { (rowID: $0.rowID, interaction: $0.interaction, sessionID: sessionID) }
        for message in messages {
            if let mirror = message.metadata?.interactionMirror,
               let interaction = await InlineInteractionResolver.interaction(
                id: mirror.interactionID, sessionID: mirror.sessionID, dataRoot: dataRoot) {
                origins.append((message.id, interaction, mirror.sessionID))
            }
        }
        for pair in origins {
            let interaction = await InlineInteractionResolver.liveProjection(pair.interaction, dataRoot: dataRoot)
            let descriptor = InlineInteractionResolver.descriptor(for: interaction, dataRoot: dataRoot)
            var model = InlineCards.model(interaction, descriptor: descriptor,
                repeatCount: collapsed.counts[interaction.id] ?? 1)
            model.sessionID = pair.sessionID
            built[pair.rowID, default: []].append(
                .init(interaction: interaction, descriptor: descriptor, sessionID: pair.sessionID,
                       model: model, repeatCount: collapsed.counts[interaction.id] ?? 1)
            )
        }
        collapsed.pairs = origins.map { ($0.rowID, $0.interaction) }
        return (built, collapsed.heading)
    }
}
public enum ChatMessageClearError: Error, LocalizedError, Sendable {
    case transcriptClearedMetadataNotSaved(String)
    case transcriptVersionExhausted

    public var errorDescription: String? {
        switch self {
        case .transcriptClearedMetadataNotSaved(let reason):
            return "Messages were cleared, but conversation metadata could not be saved: \(reason)"
        case .transcriptVersionExhausted:
            return "This conversation's transcript version cannot advance any further, so clearing it could not be published to your other devices. Nothing was deleted."
        }
    }
}
/// One transcript, projected for the UI: the messages a view renders and
/// the recollections the same rows carry, read together.
public struct TranscriptReadout: Sendable {
    public enum ReadStatus: Equatable, Sendable {
        case loading, current
        case unavailable(String)
    }
    public struct Card: Sendable, Equatable {
        public let interaction: InlineInteraction
        public let descriptor: InlineInteractionDescriptor
        public let sessionID: String
        public let model: InlineCardModel
        public let repeatCount: Int
    }
    public var messages: [ChatMessage]
    /// Oldest first, in transcript order as decoded by the shared row parser.
    public let recollections: [ChatSessionRecollection]
    var interactions: [(rowID: String, interaction: InlineInteraction)] = []
    public var cardsHeading: String = ""
    public var cardsByRow: [String: [Card]] {
        Dictionary(messages.filter { !$0.inlineCards.isEmpty }.map { ($0.id, $0.inlineCards) }, uniquingKeysWith: { _, last in last })
    }
    public var readStatus: ReadStatus = .current

    public static let empty = TranscriptReadout(messages: [], recollections: [])
    public init(messages: [ChatMessage], recollections: [ChatSessionRecollection]) {
        self.messages = messages
        self.recollections = recollections
    }
}
public struct MessageGroup: Identifiable, Sendable {
    public var id: String
    public var messages: [ChatMessage]
    public var isToolGroup: Bool
    /// Set when this row follows more than an hour of quiet: when it began.
    public var gapAbove: Date? = nil
}
/// Cards persist on their tool row but mount below the following readable reply when present.
public enum InlineCardMount {
    /// Card hosts and the tool rows whose cards were relocated within this page.
    public struct Map {
        public var byHost: [String: [String]] = [:]
        public var relocated: Set<String> = []
        public var cardsByRow: [String: [InlineCardModel]] = [:]
    }
    public static func map(groups: [MessageGroup], messages: [ChatMessage], readStatus: TranscriptReadout.ReadStatus) -> Map {
        let byHost = hosts(groups: groups)
        var mount = Map(byHost: byHost, relocated: Set(byHost.values.joined()))
        if case .unavailable = readStatus { return mount }
        // Prepared groups own placement; current messages own request state.
        let rowIDs = Set(groups.flatMap { $0.messages.map(\.id) })
        for message in messages where rowIDs.contains(message.id) {
            mount.cardsByRow[message.id] = message.inlineCards.map(\.model)
        }
        return mount
    }
    /// Assistant row id → ordinary tool rows whose cards mount under it.
    static func hosts(groups: [MessageGroup]) -> [String: [String]] {
        var hosts: [String: [String]] = [:]
        for (index, group) in groups.enumerated() where group.isToolGroup {
            guard index + 1 < groups.count else { continue }
            let next = groups[index + 1]
            guard !next.isToolGroup,
                  let reply = next.messages.first,
                  reply.role == "assistant",
                  isReadableReply(reply.content)
            else { continue }
            hosts[reply.id, default: []].append(contentsOf: group.messages.filter { $0.metadata?.interactionMirror == nil }.map(\.id))
        }
        return hosts
    }
    /// Only visible prose can host cards; protocol-only tool-use markers draw no reply.
    static func isReadableReply(_ content: String) -> Bool {
        var visible = ""
        var rest = Substring(content)
        while let open = rest.range(of: "<tool_use") {
            visible += rest[rest.startIndex..<open.lowerBound]
            let after = rest[open.upperBound...]
            if let close = after.range(of: "</tool_use>") {
                rest = after[close.upperBound...]
            } else if let end = after.range(of: ">") {
                rest = after[end.upperBound...]
            } else {
                rest = after[after.endIndex...]
            }
        }
        visible += rest
        return visible.contains { !$0.isWhitespace }
    }
}
public enum MessageGrouper {
    /// Historical groups stay shared and immutable while the streaming tail
    /// changes. Materializing a visible page copies at most that page, rather
    /// than triggering a copy of the entire cached array on every delta.
    public struct GroupedTranscript: RandomAccessCollection, Sendable {
        let base: [MessageGroup]
        var liveTail: MessageGroup?

        public var startIndex: Int { base.startIndex }
        public var endIndex: Int { base.endIndex }

        public subscript(position: Int) -> MessageGroup {
            if position == endIndex - 1, let liveTail { return liveTail }
            return base[position]
        }
        /// Structural preparation stays shared; the current rows supply the
        /// reply's content so a settled reply never returns to its first copy.
        func readingTail(from messages: [ChatMessage]) -> GroupedTranscript {
            guard var tail = last, !tail.isToolGroup, tail.messages.count == 1,
                  let current = messages.last(where: { $0.id == tail.messages[0].id }) else { return self }
            tail.messages[0] = current
            var projection = self
            projection.liveTail = tail
            return projection
        }
    }
    static func projection(for messages: [ChatMessage]) -> GroupedTranscript {
        GroupedTranscript(base: _compute(for: messages))
    }
    static func _compute(for messages: [ChatMessage]) -> [MessageGroup] {
        var result: [MessageGroup] = []
        var toolRun: [ChatMessage] = []
        func flushTools() {
            guard !toolRun.isEmpty else { return }
            // The first tool owns the stable identity of its growing run.
            result.append(MessageGroup(id: "toolrun-" + (toolRun.first?.id ?? UUID().uuidString), messages: toolRun, isToolGroup: true))
            toolRun = []
        }
        for msg in messages {
            // Tool-summary system rows are memory aids, not chat bubbles.
            if msg.role == "system" && msg.content.hasPrefix("[tool:") { continue }
            if msg.role == "tool", msg.metadata?.interactionMirror == nil {
                toolRun.append(msg)
            } else if msg.metadata?.interactionMirror != nil {
                // A mirrored card is its own row, always, never folded into a tool run.
                flushTools()
                result.append(MessageGroup(id: msg.id, messages: [msg], isToolGroup: true))
            } else {
                flushTools()
                result.append(MessageGroup(id: msg.id, messages: [msg], isToolGroup: false))
            }
        }
        flushTools()
        // A row after an hour of quiet carries its time, so a morning message
        // never reads as the end of last night's reply.
        var previous: Date?
        for index in result.indices {
            let group = result[index]
            let first = group.messages.first.flatMap { UserDisplayFormatters.parseISOTimestamp($0.createdAt) }
            if let first, let previous, first.timeIntervalSince(previous) > quietGap {
                result[index].gapAbove = first
            }
            previous = group.messages.last.flatMap { UserDisplayFormatters.parseISOTimestamp($0.createdAt) } ?? previous
        }
        return result
    }
    static let quietGap: TimeInterval = 60 * 60
}
