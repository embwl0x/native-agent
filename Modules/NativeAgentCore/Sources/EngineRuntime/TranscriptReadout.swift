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
    ) async throws -> (cardsByRow: [String: [TranscriptReadout.Card]], heading: String) {
        var built: [String: [TranscriptReadout.Card]] = [:]
        var collapsed = InlineInteractionResolver.collapsedCards(pairs)
        var origins = collapsed.pairs.map { (rowID: $0.rowID, interaction: $0.interaction, sessionID: sessionID) }
        for message in messages {
            if let mirror = message.metadata?.interactionMirror {
                do {
                    if let interaction = try await InlineInteractionResolver.interaction(
                        id: mirror.interactionID, sessionID: mirror.sessionID, dataRoot: dataRoot) {
                        origins.append((message.id, interaction, mirror.sessionID))
                    }
                } catch {
                    origins.append((message.id,
                        InlineInteractionResolver.unavailableInteraction(rowID: message.id, error: error), mirror.sessionID))
                }
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
            return """
                This conversation's transcript version cannot advance any further, so clearing it could not be published to your other devices. \
                Nothing was deleted.
                """
        }
    }
}
/// Read displayed messages and cards from the same transcript.
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
    var interactions: [(rowID: String, interaction: InlineInteraction)] = []
    public var cardsHeading: String = ""
    public var cardsByRow: [String: [Card]] {
        Dictionary(messages.filter { !$0.inlineCards.isEmpty }.map { ($0.id, $0.inlineCards) }, uniquingKeysWith: { _, last in last })
    }
    public var readStatus: ReadStatus = .current

    public static let empty = TranscriptReadout(messages: [])
    public init(messages: [ChatMessage]) {
        self.messages = messages
    }
}
/// A Mac conversation's groups are the shared transcript groups over its rows.
public typealias MessageGroup = TranscriptGroup<ChatMessage>
/// Persist cards on tool rows while mounting them under the next readable reply.
public enum InlineCardMount {
    public struct Map {
        public var byHost: [String: [String]] = [:]
        public var relocated: Set<String> = []
        public var cardsByRow: [String: [InlineCardModel]] = [:]
    }
    public static func map(groups: [MessageGroup], messages: [ChatMessage], readStatus: TranscriptReadout.ReadStatus) -> Map {
        let byHost = hosts(groups: groups)
        var mount = Map(byHost: byHost, relocated: Set(byHost.values.joined()))
        if case .unavailable = readStatus { return mount }
        // Prepared groups own placement; live messages own request state.
        let rowIDs = Set(groups.flatMap { $0.messages.map(\.id) })
        for message in messages where rowIDs.contains(message.id) {
            mount.cardsByRow[message.id] = message.inlineCards.map(\.model)
        }
        return mount
    }
    static func hosts(groups: [MessageGroup]) -> [String: [String]] {
        TranscriptGrouping.cardHosts(groups)
    }
    /// The reply's words without its protocol `<tool_use …>` markers, which draw nothing.
    public static func readableText(_ content: String) -> String {
        TranscriptGrouping.readableText(content)
    }
}
public enum MessageGrouper {
    /// Share immutable history while streaming changes so visible-page materialization cannot copy the whole cache per delta.
    public struct GroupedTranscript: RandomAccessCollection, Sendable {
        let base: [MessageGroup]
        var liveTail: MessageGroup?

        public var startIndex: Int { base.startIndex }
        public var endIndex: Int { base.endIndex }

        public subscript(position: Int) -> MessageGroup {
            if position == endIndex - 1, let liveTail { return liveTail }
            return base[position]
        }
        /// Share structure but read current reply content so settled replies cannot return to their first copy.
        func readingTail(from messages: [ChatMessage]) -> GroupedTranscript {
            guard var tail = last, !tail.isToolGroup, tail.messages.count == 1,
                  let current = messages.last(where: { $0.id == tail.messages[0].id }) else { return self }
            tail.messages[0] = current
            var projection = self
            projection.liveTail = tail
            return projection
        }
    }
    public static func projection(for messages: [ChatMessage]) -> GroupedTranscript {
        GroupedTranscript(base: _compute(for: messages))
    }
    static func _compute(for messages: [ChatMessage]) -> [MessageGroup] {
        TranscriptGrouping.groups(messages)
    }
}
