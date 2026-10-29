import Foundation
import NativeAgentShared
import TurnTrace
// Blueprint: | `ChatPersistenceContext.swift` | Request-scoped transcript intent, declared conversation kind and exact session owner; exact assistant/question replacement identities, provenance and imported-message bindings |

/// Request-scoped transcript intent. Regenerate/retry callers provide the
/// assistant row they mean to replace without widening every provider/tool-loop
/// protocol. Only the final successful assistant append opts into consuming it;
/// user rows, partial recovery rows, and persisted failures remain append-only.
public enum ChatPersistenceContext {
    /// The creating ingress declares what its session is; continuations keep
    /// an existing row's kind regardless of the surface carrying this message.
    @TaskLocal public static var threadKind: ChatThreadKind?
    /// Exact session owned by the declaring ingress. A borrowed/requested
    /// conversation keeps its existing classification.
    @TaskLocal public static var ownedSessionID: String?
    @TaskLocal public static var replacementAssistantMessageID: String?
    /// Regenerate names the existing question too: context metadata updates
    /// that exact row, and history excludes the turn being replaced.
    @TaskLocal public static var replacementUserMessageID: String?
    @TaskLocal public static var codexCompletionBinding: CodexCompletionTranscriptBinding?
    /// Suppressed-append turns reuse the enqueued row's run ID to exclude it from history; full-chat turns mint their own.
    @TaskLocal public static var pinnedTurnRunID: String?
    /// The id the Mac already shows for this turn's user row: the core saves the
    /// row under it, so the optimistic row and the durable one are one row.
    @TaskLocal public static var pinnedUserMessageID: String?
    /// Inbound origin is stamped only on user rows, independently of the tool-authorization surface.
    @TaskLocal public static var originProvenance: ChatMessageOrigin?
    /// The originating principal, independent of the turn's door or carried steering.
    public static var originPrincipal: String {
        if let origin = originProvenance, origin.authored != .agent { return "person" }
        if let agent = originProvenance?.agent ?? ChatToolSessionContext.envelope?.agent {
            return agent == "self" ? "self" : "agent:" + agent
        }
        return originProvenance?.authored == .agent ? "agent:unknown" : "person"
    }
    /// A room import keeps its source timestamp instead of the enqueue time.
    @TaskLocal public static var importedMessageCreatedAt: String?
}

/// Where an inbound chat message actually came from, recorded out-of-band so a
/// reader does not have to trust an in-band `[from: ...]` prefix that both the
/// human and the untrusted payload can type verbatim.
public struct ChatMessageOrigin: Sendable, Equatable, Codable {
    /// Transport the message arrived on, e.g. "claude-bridge", "codex-bridge".
    public let surface: String
    /// Server-selected bridge lane, e.g. "claude", "codex". This records the
    /// authenticated request route; the bridge's shared bearer does not provide
    /// a separate cryptographic attestation of the calling process. Nil when
    /// the lane is unattributed.
    public let agent: String?
    /// Only a lane transcribing its own agent's output sets authorship; forwarding leaves nil, interpreted as human.
    public let authored: ChatMessageAuthorship?
    /// The Claude inbox message this row answers, when the sender named one.
    public var replyTo: String? = nil
    /// Peer steering carried into a successor, independent of its reply route.
    public var peerSources: [String]? = nil
    public var elevatedPeerSources: [String]? = nil

    public init(
        surface: String,
        agent: String? = nil,
        authored: ChatMessageAuthorship? = nil,
        replyTo: String? = nil
    ) {
        self.surface = surface
        self.agent = agent
        self.authored = authored
        self.replyTo = replyTo
    }
}

/// Who composed the text on an out-of-band-origin row. Deliberately a closed
/// two-case enum rather than a free string: this is a trust input, and the one
/// value that grants anything (`agent`) must not be spellable by accident.
public enum ChatMessageAuthorship: String, Sendable, Equatable, Codable {
    /// The agent named by `origin.agent` wrote these words itself.
    case agent
    /// The lane carried a human's words. Same route, different speaker.
    case human
}

/// Request-scoped identity stamped on the canonical assistant row before the
/// bridge receives its `ChatResponse`. It lets the existing completion owner
/// recover a response after a crash between transcript append and lifecycle
/// cache commit without starting Agent a second time.
public struct CodexCompletionTranscriptBinding: Sendable, Equatable {
    public let deliveryId: String
    public let requestDigest: String
    public let model: String
    public let reasoningEffort: String?
    /// Nonterminal delegation notices retain recovery identity without settling work.
    public let isTerminalCompletion: Bool

    public init(
        deliveryId: String,
        requestDigest: String,
        model: String,
        reasoningEffort: String?,
        isTerminalCompletion: Bool = true
    ) {
        self.deliveryId = deliveryId
        self.requestDigest = requestDigest
        self.model = model
        self.reasoningEffort = reasoningEffort
        self.isTerminalCompletion = isTerminalCompletion
    }
}
