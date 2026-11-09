import Foundation
import NativeAgentShared
import QuartzCore
import UIKit

// Blueprint: | `MobileTranscriptBuilder.swift` | Off-main phone rows and door inputs; Shared press and display feed |

/// Synced rows carry Mac presentation; local rows carry only the phone's known role and words.
struct MobileTranscriptRow: TranscriptRow, Hashable {
    let id: String
    let role: String
    let content: String
    let createdAt: String
    let runId: String?
    let source: String?
    let metadata: ChatMessageMetadata?
    let face: TranscriptRowFace?
    let isLocal: Bool

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
        isLocal = false
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
        isLocal = true
    }

    /// The key the phone keeps a Mac row's message by.
    static func key(_ recordID: String) -> String {
        (UUID(uuidString: recordID) ?? ChatMessage.derivedMessageID(recordID)).uuidString
    }

    /// Merge local messages into the Mac's conversation order without losing non-message rows.
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
struct MobileTranscriptInput: Sendable, Equatable {
    /// The conversation the document belongs to; a new one opens at its end.
    var sessionKey: String
    /// The store's messages: what a row's menu, attachments and live words read.
    var messages: [ChatMessage]
    /// Raw synced records; merging and grouping belong to the press's input drain.
    var records: [ChatMessageRecord]
    /// The reply the running turn streams into; nil when nothing streams here.
    var liveMessageID: UUID?
    /// What the live reply says before its first word.
    var waitingLine: String
    var approvals: [ApprovalRequest]
    /// The owner supplies the finished Inbox face; the press seats its rows beside their conversation matters.
    var inboxFace: PartFaceSnapshot?
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

    var isEmpty: Bool {
        records.isEmpty && messages.isEmpty && !approvals.contains { ConversationApprovals.waitsOnYou($0) }
    }
}

enum MobileTranscriptPreparation {
    private static let log = ModuleLog(category: "MobileTranscriptPress")
    struct Prepared: Sendable {
        var input: TranscriptPressInput<MobileTranscriptRow>
        var attachments: TranscriptAttachmentData
        var messages: [String: ChatMessage]
        var lastAssistantID: String?
    }

    /// The whole conversation through the shared builder, with the phone's physics: earlier history first, each row's send buttons after
    /// it, the decisions still owed after everything, and the live reply's waiting line.
    @concurrent nonisolated
    static func prepare(_ input: MobileTranscriptInput, width: Double, scale: Double, category: String,
                        viewport: Set<String>, openingParagraphs: Int) async -> Prepared {
        let rows = MobileTranscriptRow.rows(records: input.records, messages: input.messages)
        log("press.prepare rows=%ld", rows.count)
        var asked: [String: String] = [:]
        for record in input.records where record.face?.asks == true {
            if let matter = record.askedMatter { asked[MobileTranscriptRow.key(record.id)] = matter }
        }
        let owedMatters = input.approvals.filter { ConversationApprovals.waitsOnYou($0) }.map(\.id)
            .filter { !asked.values.contains($0) }
        for matter in owedMatters { asked[matter] = matter }
        var inbox: [String: PartFace.Row] = [:]
        if let face = input.inboxFace?.drawnFace {
            for row in face.sections.flatMap(\.rows) { inbox[row.id] = row }
        }
        var messages: [String: ChatMessage] = [:]
        for message in input.messages { messages[message.id.uuidString] = message }
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
        let owed = owedMatters.map { matter in
            TranscriptBlock(id: "approval-" + matter, messageID: "approval-" + matter, role: "system",
                            kind: .attachment(.approval(rowID: matter)), source: "", lead: .message, foldGroup: nil)
        }
        let data = TranscriptAttachmentData(messages: messages,
            rowContent: Dictionary(rows.map { ($0.id, $0.content) }, uniquingKeysWith: { _, latest in latest }),
            asked: asked, inbox: inbox)
        let cards = input.cardsAvailable ? messages.compactMapValues { $0.matter.map { [$0] } } : [:]
        let pressed = TranscriptPressInput(
            session: input.sessionKey, presentation: "phone", groups: TranscriptGrouping.groups(rows), exchanges: input.exchanges,
            cards: cards, faceEpoch: "", face: { row in
                if row.isLocal { return .plain(row) }
                if let face = row.face { return face }
                return TranscriptRowFace(seat: .left,
                    words: "Presentation unavailable for Mac row \(row.id). Reopen the conversation to inspect its sync status.\n\n" + row.content,
                    quiet: true, failed: true)
            },
            wanted: { _ in }, render: { block, width, _ in
                try TranscriptRenderer(width: CGFloat(width), category: category).prepared(block)
            },
            door: TranscriptDoor(leading: older, after: after, trailing: owed,
                                 live: input.liveMessageID.map { .init(rowID: $0.uuidString, waiting: input.waitingLine) }),
            liveID: input.liveMessageID?.uuidString,
            liveText: input.liveMessageID.flatMap { messages[$0.uuidString]?.text },
            width: width, scale: scale, viewport: viewport, openingParagraphs: openingParagraphs,
            useCarriedWords: true
        )
        return Prepared(input: pressed, attachments: data, messages: messages,
                        lastAssistantID: input.messages.last { $0.role == .assistant }?.id.uuidString)
    }

    /// A row's button as one quiet paragraph of action words; without a link it reads as the button disabled.
    static func actionBlock(id: String, messageID: String, label: String, link: TranscriptLink?) -> TranscriptBlock {
        do {
            return TranscriptBlock(id: id, messageID: messageID, role: "system",
                                   kind: .reply(runs: [TranscriptRun(text: label, bold: link != nil, link: try link?.url)], ink: .quiet),
                                   source: label, lead: .paragraph, foldGroup: nil)
        } catch {
            let failure = "\(label) unavailable: \(error.localizedDescription)"
            return TranscriptBlock(id: id, messageID: messageID, role: "system",
                                   kind: .reply(runs: [TranscriptRun(text: failure)], ink: .quiet),
                                   source: failure, lead: .paragraph, foldGroup: nil)
        }
    }
}

/// Every phone document uses the Shared press; its feed is applied on the phone's display rhythm.
@MainActor
final class MobileTranscriptPress {
    static let shared = MobileTranscriptPress()
    let press: TranscriptPress<MobileTranscriptRow>
    let face: FaceFeed

    private init() {
        let source = FaceFeedSource()
        let frames = MobileTranscriptFrames()
        press = TranscriptPress(feed: source)
        face = FaceFeed(source: source) { await frames.next() }
    }
}

@MainActor
private final class MobileTranscriptFrames: NSObject {
    private var link: CADisplayLink?
    private var waiters: [CheckedContinuation<Void, Never>] = []

    func next() async {
        await withCheckedContinuation { waiter in
            waiters.append(waiter)
            if link == nil {
                let link = CADisplayLink(target: self, selector: #selector(frame(_:)))
                link.add(to: .main, forMode: .common)
                self.link = link
            }
            link?.isPaused = false
        }
    }

    @objc private func frame(_ sender: CADisplayLink) {
        sender.isPaused = true
        let ready = waiters
        waiters = []
        for waiter in ready { waiter.resume() }
    }
}
