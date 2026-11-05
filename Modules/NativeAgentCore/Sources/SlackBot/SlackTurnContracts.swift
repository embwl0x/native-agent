import Foundation
import ChatTurnRuntime
import NativeAgentCore
// Blueprint: | `SlackTurnContracts.swift` | `SlackInboundFile` struct |

struct SlackInboundFile: Sendable, Codable, Equatable {
    let downloadURL: String
    let mimeType: String
    let name: String?
    let byteSize: Int?
}


struct SlackInboundMessage: Sendable, Codable, Equatable {
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
    let attachments: [ChatTurnRuntime.MultimodalAttachment]
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
        attachments: [ChatTurnRuntime.MultimodalAttachment] = [],
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

    enum CodingKeys: String, CodingKey {
        case eventId, teamId, channelId, userId, eventType, text, ts, threadTs
        case channelType, isDirectMessage, files, opensReplyThread
    }

    init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        eventId = try values.decode(String.self, forKey: .eventId)
        teamId = try values.decode(String.self, forKey: .teamId)
        channelId = try values.decode(String.self, forKey: .channelId)
        userId = try values.decode(String.self, forKey: .userId)
        eventType = try values.decode(String.self, forKey: .eventType)
        text = try values.decode(String.self, forKey: .text)
        ts = try values.decode(String.self, forKey: .ts)
        threadTs = try values.decodeIfPresent(String.self, forKey: .threadTs)
        channelType = try values.decodeIfPresent(String.self, forKey: .channelType)
        isDirectMessage = try values.decode(Bool.self, forKey: .isDirectMessage)
        files = try values.decode([SlackInboundFile].self, forKey: .files)
        opensReplyThread = try values.decode(Bool.self, forKey: .opensReplyThread)
        attachments = []
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

    /// The ts to thread an in-turn notice under when the message is not itself in a thread: its own ts, which opens a thread on that message.
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
    var attachments: [ChatTurnRuntime.MultimodalAttachment]
    /// The agent's turn in progress read this message: that turn's reply in the thread answers it, so nothing of its own is posted.
    var readBy: String?

    init(
        text: String,
        attachments: [ChatTurnRuntime.MultimodalAttachment] = [],
        readBy: String? = nil
    ) {
        self.text = text
        self.attachments = attachments
        self.readBy = readBy
    }
}


/// Visible prose and notices share the turn's progress lane.
typealias SlackChatProgressSink = @Sendable (TurnStreamEvent) async -> Void

/// Wakes standing bots on a message the runner accepted. The host owns the bot router and the autonomy switch it admits runs under.
public typealias SlackBotEventIntake = @Sendable (_ channelId: String, _ text: String, _ userId: String, _ eventId: String) async throws -> Void

typealias SlackProgressChat = @Sendable (
    _ message: SlackInboundMessage,
    _ sessionId: String,
    _ handler: SlackHandler
) async throws -> SlackSocketModeReply

/// One accepted handler's turn and injected receipt-settlement dependency.
public typealias SlackAfterHandling = @Sendable (@escaping @Sendable () async -> Void) async -> Void

public struct SlackHandler: Sendable {
    public let turn: Turn
    public let deferAfterHandling: SlackAfterHandling?
    public init(turn: Turn, deferAfterHandling: SlackAfterHandling?) {
        self.turn = turn
        self.deferAfterHandling = deferAfterHandling
    }
}
