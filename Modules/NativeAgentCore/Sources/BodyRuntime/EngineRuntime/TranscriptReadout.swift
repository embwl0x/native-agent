import SenseCore
import Foundation
import Observation
import NativeAgentCore
import NativeAgentShared
import PersistenceCore
import ProviderRouting
import MindCore
import MacNerves
import Darwin
// Blueprint: | `TranscriptReadout.swift` | Transcript/card structures, page-bounded inline mounts and structural message grouping |
extension InlineCards {
    @MainActor
    public static func cardsByRow(
        _ pairs: [(rowID: String, interaction: InlineInteraction)], messages: [ChatMessage],
        sessionID: String, dataRoot: URL, coordinator: InlineInteractionCoordinator
    ) async throws -> (cardsByRow: [String: [TranscriptReadout.Card]], heading: String) {
        var built: [String: [TranscriptReadout.Card]] = [:]
        var collapsed = InlineInteractionCoordinator.collapsedCards(pairs)
        var origins = collapsed.pairs.map { (rowID: $0.rowID, interaction: $0.interaction, sessionID: sessionID) }
        for message in messages {
            if let mirror = message.metadata?.interactionMirror {
                do {
                    if let interaction = try await coordinator.interaction(
                        id: mirror.interactionID, sessionID: mirror.sessionID) {
                        origins.append((message.id, interaction, mirror.sessionID))
                    }
                } catch {
                    origins.append((message.id,
                        InlineInteractionCoordinator.unavailableInteraction(rowID: message.id, error: error), mirror.sessionID))
                }
            }
        }
        for pair in origins {
            let interaction = pair.interaction
            let descriptor = await InlineInteractionCoordinator.descriptor(for: interaction, dataRoot: dataRoot)
            var model = InlineCards.model(interaction, descriptor: descriptor,
                repeatCount: collapsed.counts[interaction.id] ?? 1)
            model.sessionID = pair.sessionID
            model.grantsNow = await coordinator.grantsNow(interaction, control: descriptor)
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
        /// The card's protected entry, only while it has something entered there: a field, a sign-in or full setup, from asking until the
        /// card settles (a sign-in it started runs on in that form, which holds the callback until the browser finishes), or a restart.
        /// Nil otherwise, so a card that collects nothing, or has settled, never holds the chat window's protection. A walking permission
        /// card's restart is its own answer on its row, so it is not drawn twice.
        public var secureFace: SecureCardFace? {
            let entry = model.state == .pending || model.canRetry
            let restart = model.kind == .needsPermission && model.state == .running ? nil : model.restartNote
            let entered = !model.fields.isEmpty || model.signInLabel != nil || model.fullSetupLabel != nil
            guard restart != nil || (entered && (entry || model.state == .running)) else { return nil }
            return SecureCardFace(identity: .init(card: interaction.id, session: sessionID, revision: interaction.revision),
                fields: model.fields.map { .init(id: $0.id, label: $0.label, placeholder: $0.placeholder,
                    helper: $0.helper, secret: $0.isSecret, optional: $0.isOptional) },
                primaryLabel: model.primaryLabel, signInLabel: model.signInLabel, fullSetupLabel: model.fullSetupLabel,
                restartNote: restart, busyNote: model.state == .running ? model.busyNote : nil, acceptsEntry: entry)
        }

        /// The card as it draws in its own conversation, on the Mac and the phone: read from the card itself and whole (why, what it
        /// grants, each option's consequence, how long, what Not now costs; a decided card's outcome), so a card the Inbox no longer holds
        /// still reads. Only its answers come from its Inbox row (`cardAnswers`), the one place a press is bound to its door call; a
        /// decided card has none. No link: the card is already where it would lead.
        public func face(answers inboxRow: PartFace.Row?) -> PartFace.Row {
            var lines: [String?] = interaction.state.isOpen
                ? [model.why, model.grantsNow, model.state == .running ? model.busyNote : nil]
                : [model.outcome, model.outcomeMeta]
            if model.needsAttention {
                lines += model.choices.map { choice in choice.note.map { choice.title + ": " + $0 } }
                lines += model.scopeLines.map { Optional($0) } + [model.persistenceNote, "Not now: " + model.consequence]
            }
            let detail = lines.compactMap { $0?.trimmingCharacters(in: .whitespacesAndNewlines) }.filter { !$0.isEmpty }
            // The card's own form enters the key here; opening another entry for it beside the form is the same answer twice.
            let entry = secureFace != nil
            let answers = model.needsAttention
                ? inboxRow?.cardAnswers?.filter { !(entry && $0.call?.action == "provider.sign_in") } : nil
            return PartFace.Row(id: "interaction:" + interaction.id, title: NativeAppSecretRedactor.redactText(model.title),
                detail: detail.isEmpty ? nil : NativeAppSecretRedactor.redactText(detail.joined(separator: "\n\n")),
                symbol: "hand.raised.fill",
                tone: model.needsAttention ? PartFace.Tone.attention : [.failed, .stopped].contains(model.state) ? .failed : nil,
                actions: answers?.isEmpty == false ? answers : nil)
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
