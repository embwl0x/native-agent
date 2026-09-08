import Foundation
import ChatOrchestration

struct SlackInboundFile: Sendable, Equatable {
    let downloadURL: String
    let mimeType: String
    let name: String?
    let byteSize: Int?
}


struct SlackInboundMessage: Sendable, Equatable {
    let eventId: String
    let teamId: String
    let channelId: String
    let userId: String
    let eventType: String
    let text: String
    let ts: String
    let threadTs: String?
    let channelType: String?
    let isDirectMessage: Bool
    let files: [SlackInboundFile]
    let attachments: [ChatOrchestration.MultimodalAttachment]
    let opensReplyThread: Bool

    init(
        eventId: String,
        teamId: String,
        channelId: String,
        userId: String,
        eventType: String,
        text: String,
        ts: String,
        threadTs: String?,
        channelType: String?,
        isDirectMessage: Bool,
        files: [SlackInboundFile] = [],
        attachments: [ChatOrchestration.MultimodalAttachment] = [],
        opensReplyThread: Bool = true
    ) {
        self.eventId = eventId
        self.teamId = teamId
        self.channelId = channelId
        self.userId = userId
        self.eventType = eventType
        self.text = text
        self.ts = ts
        self.threadTs = threadTs
        self.channelType = channelType
        self.isDirectMessage = isDirectMessage
        self.files = files
        self.attachments = attachments
        self.opensReplyThread = opensReplyThread
    }

    var sessionKey: String {
        if let threadTs = normalizedThreadTs {
            return "thread:\(teamId):\(channelId):\(threadTs)"
        }
        return "conversation:\(teamId):\(channelId)"
    }

    var replyThreadTs: String? {
        normalizedThreadTs ?? (opensReplyThread && !isDirectMessage ? threadAnchorTs : nil)
    }

    /// The ts to thread an in-turn notice under when the message is not itself
    /// in a thread: its own ts, which opens a thread on that message.
    var threadAnchorTs: String? {
        let trimmed = ts.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }

    var normalizedThreadTs: String? {
        guard let threadTs else { return nil }
        let trimmed = threadTs.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }
}

struct SlackSocketModeReply: Sendable, Equatable {
    var text: String
    var attachments: [ChatOrchestration.MultimodalAttachment]

    init(
        text: String,
        attachments: [ChatOrchestration.MultimodalAttachment] = []
    ) {
        self.text = text
        self.attachments = attachments
    }
}


/// 2026-09-06: in-turn notices (provider reconnect, context compaction).
/// Slack had no progress lane at all — the loop supplied no callback and waited
/// for the whole reply — so a turn that spent minutes reconnecting to the
/// provider or trimming its context looked hung on Slack while Telegram, the
/// Mac card and iOS all showed it. `kind` is the notice kind
/// (`provider_retry`, `context_compaction`).
typealias SlackChatProgressSink = @Sendable (_ kind: String, _ text: String) async -> Void

typealias SlackSocketModeChatHandler = @Sendable (SlackInboundMessage) async throws -> SlackSocketModeReply

/// 2026-09-06: the sink rides a SECOND handler, not a second parameter on the
/// existing one. A Swift closure type cannot give a parameter a default, so
/// widening `SlackSocketModeChatHandler` broke every one-argument caller. This
/// one defaults to nil and the plain handler stays exactly as it was.
typealias SlackSocketModeProgressChatHandler = @Sendable (
    _ message: SlackInboundMessage,
    _ progress: @escaping SlackChatProgressSink
) async throws -> SlackSocketModeReply
