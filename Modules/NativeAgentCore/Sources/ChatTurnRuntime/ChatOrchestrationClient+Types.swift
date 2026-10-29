import Foundation
import CryptoKit
import NativeAgentCore
import NativeAgentShared
import PersistenceCore
import PersonaEngine
import MemoryV2
import ProviderRouting
import TrustCenter
import Dispatcher
import MacControl
import SwarmRuns
import MacIntegration
import CognitiveSubstrate
// Blueprint: | `ChatOrchestrationClient+Types.swift` | chat response, progress and enqueue receipt values |

// MARK: - Public types

/// Errors owned by the Swift-native chat client.
public enum ChatOrchestrationError: Error, LocalizedError, Equatable {
    case replyHeldForQuietHours
    case emptyMessage
    case underlying(String)
    case helperModelChoice(sessionID: String, reason: String, message: String)

    public var errorDescription: String? {
        switch self {
        case .replyHeldForQuietHours: return "Reply held for quiet hours."
        case .emptyMessage:
            return "chat: message body must contain non-whitespace content"
        case .underlying(let message):
            return "chat: \(message)"
        case .helperModelChoice(_, _, let message):
            return message
        }
    }
}

/// Shared chat-turn output, transcript messages, attachments and execution metadata.
public struct ChatResponse: Sendable, Codable, Equatable {
    public var runId: String
    public var model: String
    public var requestedModel: String?
    public var reasoningEffort: String?
    public var output: String
    public var sessionId: String?
    public var personaFingerprint: String?
    public var contextFingerprint: String?
    public var message: ChatMessage?
    public var messages: [ChatMessage]?
    public var attachments: [MultimodalAttachment]?
    /// Exact direct provider calls for callers whose engine owns the full
    /// turn. Nil means the path did not produce authoritative accounting.
    public var providerCallCount: Int?
    public var runtimeStatus: String? = nil
    public var terminalState: TurnEngineResult.TerminalState? = nil
    public var statusDetail: String? = nil
    /// The approval a bot turn stopped on, when `runtimeStatus` says it is
    /// waiting for one. The approval record stays canonical about whether it
    /// still is.
    public var pendingApprovalID: String? = nil
    /// Leading characters of `output` that are pre-tool working commentary
    /// (see `TurnEngineResult.workingCommentaryCharacters`).
    public var workingCommentaryCharacters: Int? = nil

    /// The final answer at the recorded boundary, including an empty suffix.
    /// An absent boundary keeps the whole reply; an invalid one yields no answer.
    public static func answerOnly(_ reply: String, workingCommentaryCharacters: Int?) -> String {
        guard let cut = workingCommentaryCharacters else { return reply }
        guard cut >= 0, cut <= reply.count else { return "" }
        return String(reply.dropFirst(cut)).trimmingCharacters(in: .whitespacesAndNewlines)
    }

    public init(
        runId: String,
        model: String,
        requestedModel: String? = nil,
        reasoningEffort: String? = nil,
        output: String,
        sessionId: String? = nil,
        personaFingerprint: String? = nil,
        contextFingerprint: String? = nil,
        message: ChatMessage? = nil,
        messages: [ChatMessage]? = nil,
        attachments: [MultimodalAttachment]? = nil,
        providerCallCount: Int? = nil,
        terminalState: TurnEngineResult.TerminalState? = nil
    ) {
        self.runId = runId
        self.model = model
        self.requestedModel = requestedModel
        self.reasoningEffort = reasoningEffort
        self.output = output
        self.sessionId = sessionId
        self.personaFingerprint = personaFingerprint
        self.contextFingerprint = contextFingerprint
        self.message = message
        self.messages = messages
        self.attachments = attachments
        self.providerCallCount = providerCallCount
        self.terminalState = terminalState
    }
}

extension ChatMessage: Equatable {
    public static func == (lhs: ChatMessage, rhs: ChatMessage) -> Bool {
        return lhs.role == rhs.role
            && lhs.content == rhs.content
            && lhs.timestamp == rhs.timestamp
    }
}

public typealias MultimodalAttachment = NativeAgentShared.MultimodalAttachment

public typealias TurnEventSink = @Sendable (TurnStreamEvent) async -> Void

/// Receipt for an ack-on-enqueue user append: the message row is durably in
/// the session transcript, independent of any turn that later consumes it.
public struct EnqueuedUserMessage: Sendable {
    /// The checked canonical session the row landed in. Callers must create and
    /// retain a new session identity before enqueueing; persistence never mints
    /// one from a missing value.
    public let sessionId: String
    /// The runId stamped on the enqueued user row.
    public let runId: String

    public init(sessionId: String, runId: String) {
        self.sessionId = sessionId
        self.runId = runId
    }
}
