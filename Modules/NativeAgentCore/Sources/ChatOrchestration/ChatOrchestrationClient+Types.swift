import Foundation
import CryptoKit
import NativeAgentCore
import PersistenceCore
import PersonaEngine
import MemoryV2
import MCPDispatcher
import ProviderRouting
import TrustCenter
import KnowledgeGraph
import XConnector
import Dispatcher
import MacControl
import SwarmRuns
import MacIntegration

// MARK: - Public types

/// Errors owned by the current Swift-native chat client. This type formerly
/// lived in the retired protocol compatibility shell even though production
/// client paths were its only remaining consumers.
public enum ChatOrchestrationError: Error, LocalizedError, Equatable {
    case emptyMessage
    case badAttachments(detail: String)
    case invalidResponse(status: Int)
    case underlying(String)

    public var errorDescription: String? {
        switch self {
        case .emptyMessage:
            return "chat: message body must contain non-whitespace content"
        case .badAttachments(let detail):
            return "chat: bad attachments — \(detail)"
        case .invalidResponse(let status):
            return "chat: runtime returned unexpected status \(status)"
        case .underlying(let message):
            return "chat: \(message)"
        }
    }
}

/// Mirrors `ChatResponse` in NativeAgentApp/NativeClient.swift (which lives
/// outside this package). Defined here so the SwiftNative path returns the
/// same shape the app-side caller already expects.
public struct ChatResponse: Sendable, Codable, Equatable {
    public var runId: String
    public var model: String
    public var requestedModel: String?
    public var reasoningEffort: String?
    public var output: String
    public var sessionId: String?
    public var personaFingerprint: String?
    public var contextFingerprint: String?
    // Mirror NativeClient.ChatResponse (Sources/NativeAgentApp/NativeClient.swift L3315).
    public var message: ChatMessage?
    public var messages: [ChatMessage]?
    public var attachments: [MultimodalAttachment]?
    /// Exact direct provider calls for callers whose engine owns the full
    /// turn. Nil means the path did not produce authoritative accounting.
    public var providerCallCount: Int?

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
        providerCallCount: Int? = nil
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
    }
}

extension ChatMessage: Equatable {
    public static func == (lhs: ChatMessage, rhs: ChatMessage) -> Bool {
        return lhs.role == rhs.role
            && lhs.content == rhs.content
            && lhs.timestamp == rhs.timestamp
    }
}

/// Mirrors `MultimodalAttachment` in NativeAgentShared (which this package
/// cannot import — would cycle the dep graph). Same field shape on the wire.
public struct MultimodalAttachment: Sendable, Codable, Equatable {
    public var id: String
    public var type: String
    public var base64: String
    public var mime: String
    public var name: String?
    public var byteSize: Int
    /// Local filesystem path for app-generated output artifacts. Input
    /// attachments keep this nil and carry bytes in `base64`.
    public var path: String?

    public init(
        id: String = UUID().uuidString,
        type: String,
        base64: String,
        mime: String,
        name: String? = nil,
        byteSize: Int = 0,
        path: String? = nil
    ) {
        self.id = id
        self.type = type
        self.base64 = base64
        self.mime = mime
        self.name = name
        self.byteSize = byteSize
        self.path = path
    }
}

public typealias ChatOrchestrationProgressHandler = @Sendable (TurnStreamEvent) async -> Void

/// Receipt for an ack-on-enqueue user append: the message row is durably in
/// the session transcript, independent of any turn that later consumes it.
public struct EnqueuedUserMessage: Sendable {
    /// The resolved session the row landed in (minted when the caller passed nil).
    public let sessionId: String
    /// The runId stamped on the enqueued user row.
    public let runId: String

    public init(sessionId: String, runId: String) {
        self.sessionId = sessionId
        self.runId = runId
    }
}

// MARK: - Protocol

public protocol ChatOrchestrationClient: Sendable {
    /// Ack-on-enqueue (wake-delivery-classification, 2026-07-25): durably
    /// append a user message to the session transcript and return as soon as
    /// the row is on disk. The caller then runs the turn separately with
    /// `suppressUserAppend: true`. This exists so transport-level delivery
    /// acknowledgements can be decoupled from turn completion — a delivery
    /// ack must never block on the very turn the delivery started.
    func enqueueUserMessage(
        message: String,
        sessionId: String?,
        persona: String?,
        surface: String
    ) async throws -> EnqueuedUserMessage

    /// Non-streaming chat turn.
    func chat(
        message: String,
        sessionId: String?,
        model: String,
        reasoningEffort: String,
        fileAccess: String,
        attachments: [MultimodalAttachment],
        suppressUserAppend: Bool
    ) async throws -> ChatResponse

    // Wave 16 cutover overloads (2026-06-01): accept a `persona` parameter so
    // the Mac UI's per-chat persona pick (UserDefaults["chatPersona"]) can be
    // forwarded into the chat turn. The SwiftNative impl currently SHORT-CIRCUITS
    // this — the compiled persona is baked per-surface and we do NOT merge a
    // caller-supplied persona on top of it (that lived in persona_runtime.py
    // and didn't survive the cutover). The persona value is RECORDED into the
    // persisted assistant turn's `metadata.persona` for future consolidation
    // and downstream filters, but it does NOT change which persona the LLM
    // sees on this turn.
    // PersonaCompiler.loadProfile() is the source-of-truth for the active
    // persona in the SwiftNative path. Default-persona users see no
    // regression.
    func chat(
        message: String,
        sessionId: String?,
        model: String,
        reasoningEffort: String,
        fileAccess: String,
        attachments: [MultimodalAttachment],
        persona: String?,
        suppressUserAppend: Bool
    ) async throws -> ChatResponse

    // F4: surface-bearing overload — callers on non-chat surfaces (Telegram,
    // Workshop executions, dream, ...) thread their identifier through so
    // computeModelPreferences can pick the right per-surface model and so the
    // persisted turn carries the surface label. Default trampoline below maps
    // `surface=="chat"` back onto the no-surface overload so existing call
    // sites keep compiling.
    func chat(
        message: String,
        sessionId: String?,
        model: String,
        reasoningEffort: String,
        fileAccess: String,
        attachments: [MultimodalAttachment],
        persona: String?,
        surface: String,
        suppressUserAppend: Bool
    ) async throws -> ChatResponse

    func chat(
        message: String,
        sessionId: String?,
        model: String,
        reasoningEffort: String,
        fileAccess: String,
        attachments: [MultimodalAttachment],
        persona: String?,
        surface: String,
        suppressUserAppend: Bool,
        progress: ChatOrchestrationProgressHandler?
    ) async throws -> ChatResponse

    func chatStream(
        message: String,
        sessionId: String?,
        model: String,
        reasoningEffort: String,
        fileAccess: String,
        attachments: [MultimodalAttachment],
        persona: String?,
        surface: String,
        suppressUserAppend: Bool
    ) -> AsyncThrowingStream<TurnStreamEvent, Error>
}

// Legacy-shape chatStream defaults. The pre-Wave-16 call shapes (no persona;
// persona but no surface) forward UP to the single surface-bearing requirement
// with `surface == "chat"`, so existing call sites and `any
// ChatOrchestrationClient` callers keep compiling while a conformer implements
// only the widest overload. The intermediate persona-drop / surface-drop
// trampolines the protocol used to carry added no logic beyond these defaults
// and were removed. The `chat(...)` family keeps every shape as an explicit
// requirement — its sole concrete witness implements all of them directly, so
// no protocol-level chat default is exercised.
extension ChatOrchestrationClient {
    public func chatStream(
        message: String,
        sessionId: String?,
        model: String,
        reasoningEffort: String,
        fileAccess: String,
        attachments: [MultimodalAttachment],
        suppressUserAppend: Bool
    ) -> AsyncThrowingStream<TurnStreamEvent, Error> {
        return chatStream(
            message: message,
            sessionId: sessionId,
            model: model,
            reasoningEffort: reasoningEffort,
            fileAccess: fileAccess,
            attachments: attachments,
            persona: nil,
            surface: "chat",
            suppressUserAppend: suppressUserAppend
        )
    }

    public func chatStream(
        message: String,
        sessionId: String?,
        model: String,
        reasoningEffort: String,
        fileAccess: String,
        attachments: [MultimodalAttachment],
        persona: String?,
        suppressUserAppend: Bool
    ) -> AsyncThrowingStream<TurnStreamEvent, Error> {
        return chatStream(
            message: message,
            sessionId: sessionId,
            model: model,
            reasoningEffort: reasoningEffort,
            fileAccess: fileAccess,
            attachments: attachments,
            persona: persona,
            surface: "chat",
            suppressUserAppend: suppressUserAppend
        )
    }
}
