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
            let interaction = pair.interaction
            let descriptor = await InlineInteractionResolver.descriptor(for: interaction, dataRoot: dataRoot)
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
        public var secureFace: SecureCardFace {
            SecureCardFace(identity: .init(card: interaction.id, session: sessionID, revision: interaction.revision),
                fields: model.fields.map { .init(id: $0.id, label: $0.label, placeholder: $0.placeholder,
                    helper: $0.helper, secret: $0.isSecret, optional: $0.isOptional) },
                primaryLabel: model.primaryLabel, signInLabel: model.signInLabel, fullSetupLabel: model.fullSetupLabel,
                restartNote: model.restartNote, busyNote: model.state == .running ? model.busyNote : nil,
                acceptsEntry: model.state == .pending || model.canRetry)
        }
    }
    public var messages: [ChatMessage]
    /// False means these are the ending rows, never evidence about the conversation's beginning.
    public var isComplete = true
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
public enum MessageGrouper {
    /// Share immutable history while streaming changes so visible-page materialization cannot copy the whole cache per delta.
    public struct GroupedTranscript: RandomAccessCollection, Sendable {
        let base: [MessageGroup]
        var liveTail: MessageGroup?
        /// The revision these groups were actually built from, attached when their owner's read publishes.
        public internal(set) var structureVersion: UInt64?

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
    public static func projection(for messages: [ChatMessage], structureVersion: UInt64? = nil) -> GroupedTranscript {
        GroupedTranscript(base: _compute(for: messages), structureVersion: structureVersion)
    }
    static func _compute(for messages: [ChatMessage]) -> [MessageGroup] {
        TranscriptGrouping.groups(messages)
    }
}
