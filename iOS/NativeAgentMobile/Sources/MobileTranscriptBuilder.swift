import Foundation
import NativeAgentShared

// Blueprint: | `MobileTranscriptBuilder.swift` | The phone's door onto the shared transcript builder: the Mac's rows with their faces, the phone's own rows, and the phone's physics (earlier history, send buttons, decisions still owed, the live reply) |

/// One row of the conversation as the phone holds it: a row the Mac sent, with the face the Mac read for it, or a row only the phone has
/// yet (a send in flight, the streaming reply), read plainly. Its id is the key the phone's messages are kept by.
struct MobileTranscriptRow: TranscriptRow, Hashable {
    let id: String
    let role: String
    let content: String
    let createdAt: String
    let runId: String?
    let source: String?
    let metadata: ChatMessageMetadata?
    let face: TranscriptRowFace?

    /// A row the Mac sent. Its words are the phone's message's when it holds one (a whole message loaded, a card's empty text).
    init(_ record: ChatMessageRecord, message: ChatMessage?) {
        id = message?.id.uuidString ?? Self.key(record.id)
        role = record.role
        content = message?.text ?? record.content
        createdAt = record.createdAt
        runId = record.runId
        source = record.source
        metadata = record.metadata
        face = record.face
    }

    /// A row only the phone has: its attachments carry their kinds so the builder places them.
    init(_ message: ChatMessage) {
        id = message.id.uuidString
        role = message.role.rawValue
        content = message.text
        createdAt = ""
        runId = message.runId
        source = nil
        if message.attachments.isEmpty {
            metadata = nil
        } else {
            var metadata = ChatMessageMetadata()
            metadata.attachments = message.attachments.map {
                PersistedAttachment(id: $0.id, type: $0.type, mime: $0.mime ?? "", name: $0.name, byteSize: Int64($0.byteSize ?? 0))
            }
            self.metadata = metadata
        }
        face = nil
    }

    /// The key the phone keeps a Mac row's message by.
    static func key(_ recordID: String) -> String {
        (UUID(uuidString: recordID) ?? ChatMessage.derivedMessageID(recordID)).uuidString
    }

    /// The conversation in the Mac's order. Each message the store shows sits where the store holds it; the rows the phone's messages
    /// leave out (tool runs, asks) sit before the message they precede in the Mac's rows; rows after the last message the Mac sent sit
    /// before the phone's own rows that follow it.
    static func rows(records: [ChatMessageRecord], messages: [ChatMessage]) -> [MobileTranscriptRow] {
        var recordAt: [String: Int] = [:]
        for (index, record) in records.enumerated() where recordAt[key(record.id)] == nil { recordAt[key(record.id)] = index }
        let lastSent = messages.lastIndex { recordAt[$0.id.uuidString] != nil }
        var out: [MobileTranscriptRow] = []
        out.reserveCapacity(records.count + messages.count)
        var next = 0
        func flush(to end: Int) {
            while next < end {
                let record = records[next]
                if record.role != "user", record.role != "assistant", record.interactionJSON == nil {
                    out.append(MobileTranscriptRow(record, message: nil))
                }
                next += 1
            }
        }
        for (position, message) in messages.enumerated() {
            if let at = recordAt[message.id.uuidString] {
                if at >= next { flush(to: at); next = at + 1 }
                out.append(MobileTranscriptRow(records[at], message: message))
            } else {
                if lastSent.map({ position > $0 }) ?? true { flush(to: records.count) }
                out.append(MobileTranscriptRow(message))
            }
        }
        flush(to: records.count)
        return out
    }
}

/// What the conversation shows, as the thread reads it from the store and the sync engine.
struct MobileTranscriptInput {
    /// The conversation the document belongs to; a new one opens at its end.
    var sessionKey: String
    /// The store's messages: what a row's menu, attachments and live words read.
    var messages: [ChatMessage]
    /// The conversation's rows in order (`MobileTranscriptRow.rows`).
    var rows: [MobileTranscriptRow]
    /// The reply the running turn streams into; nil when nothing streams here.
    var liveMessageID: UUID?
    /// What the live reply says before its first word.
    var waitingLine: String
    /// Approvals by the row that asks for them, and by their own id for the decisions still owed that no row here asks for.
    var approvals: [String: ApprovalRequest]
    /// Decisions still owed with no row here asking: after everything.
    var tailApprovals: [ApprovalRequest]
    /// This conversation's mirrored cards, by inbox item id.
    var inboxCards: [String: InboxItemRecord]
    var exchanges: [OtherRoomExchange]
    /// Cards draw only while the transcript reads cleanly.
    var cardsAvailable: Bool
    var canLoadOlder: Bool
    var isLoadingHistory: Bool
    /// Replies whose request expired unread: "Send now" starts it again.
    var expired: Set<UUID>
    /// A failed queued send by the placeholder row it fills: "Retry send" sends that queued id now.
    var retries: [UUID: UUID]
    /// Sending and switching hold every send button.
    var sendsEnabled: Bool

    var isEmpty: Bool { rows.isEmpty && tailApprovals.isEmpty }
}

extension TranscriptDocument {
    /// The whole conversation through the shared builder, with the phone's physics: earlier history first, each row's send buttons after
    /// it, the decisions still owed after everything, and the live reply's waiting line.
    @MainActor
    static func build(_ input: MobileTranscriptInput, cache: TranscriptBuildCache<MobileTranscriptRow>) -> TranscriptDocument {
        var messages: [String: ChatMessage] = [:]
        for message in input.messages { messages[message.id.uuidString] = message }
        var rows: [String: MobileTranscriptRow] = [:]
        for row in input.rows { rows[row.id] = row }
        var after: [String: [TranscriptBlock]] = [:]
        for message in input.messages {
            let id = message.id.uuidString
            // An expired request starts again only on this explicit send.
            if input.expired.contains(message.id) {
                after[id, default: []].append(actionBlock(id: "\(id)@send-now", messageID: id, label: "Send now",
                                                          link: input.sendsEnabled ? .sendNow(message.id) : nil))
            }
            if message.text.hasSuffix(ChatStore.snapshotTruncationMarker) {
                after[id, default: []].append(actionBlock(id: "\(id)@whole", messageID: id, label: "Show the whole message",
                                                          link: input.isLoadingHistory ? nil : .wholeMessage(message.id)))
            }
            if !message.isStreaming, let queued = input.retries[message.id] {
                after[id, default: []].append(actionBlock(id: "\(id)@retry", messageID: id, label: "Retry send",
                                                          link: input.sendsEnabled ? .retrySend(queued) : nil))
            }
        }
        let older = input.canLoadOlder ? [actionBlock(id: "older", messageID: "older",
                                                      label: input.isLoadingHistory ? "Loading earlier messages…" : "Load earlier messages",
                                                      link: input.isLoadingHistory ? nil : .olderHistory)] : []
        let owed = input.tailApprovals.map { approval in
            TranscriptBlock(id: "approval-" + approval.id, messageID: "approval-" + approval.id, role: "system",
                            kind: .attachment(.approval(rowID: approval.id)), source: "", lead: .message, foldGroup: nil)
        }
        let thread = TranscriptThread(
            groups: TranscriptGrouping.groups(input.rows), exchanges: input.exchanges,
            face: { $0.face ?? .plain($0) },
            cards: { rowID in
                guard input.cardsAvailable else { return [] }
                if let message = messages[rowID], let card = message.interaction, message.interactionDescriptor != nil,
                   message.interactionSessionID != nil {
                    return [card.id]
                }
                if let mirror = rows[rowID]?.metadata?.interactionMirror, input.inboxCards["interaction:" + mirror.interactionID] != nil {
                    return ["interaction:" + mirror.interactionID]
                }
                return []
            },
            door: TranscriptDoor(leading: older, after: after, trailing: owed,
                                 live: input.liveMessageID.map { .init(rowID: $0.uuidString, waiting: input.waitingLine) })
        )
        return TranscriptBuilder.build(thread, cache: cache)
    }

    /// A row's button as one quiet paragraph of action words; without a link it reads as the button disabled.
    static func actionBlock(id: String, messageID: String, label: String, link: TranscriptLink?) -> TranscriptBlock {
        TranscriptBlock(id: id, messageID: messageID, role: "system",
                        kind: .reply(runs: [TranscriptRun(text: label, bold: link != nil, link: link?.url)], ink: .quiet),
                        source: label, lead: .paragraph, foldGroup: nil)
    }
}
