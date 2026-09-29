import Foundation

/// Request-scoped transcript intent. Regenerate/retry callers provide the
/// assistant row they mean to replace without widening every provider/tool-loop
/// protocol. Only the final successful assistant append opts into consuming it;
/// user rows, partial recovery rows, and persisted failures remain append-only.
public enum ChatPersistenceContext {
    @TaskLocal public static var replacementAssistantMessageID: String?
    @TaskLocal public static var codexCompletionBinding: CodexCompletionTranscriptBinding?
    /// Ack-on-enqueue (2026-07-25): the runId `enqueueUserMessage` stamped on
    /// the pre-appended user row. A turn that runs with
    /// `suppressUserAppend: true` adopts this as ITS runId, so the history
    /// builder's `excludeHistoryRunId` drops the pre-appended row exactly as
    /// it drops the normal path's own append — without it the current message
    /// enters the prompt twice (once from history, once as the live turn).
    /// Honored ONLY on suppressed-append turns: a nested full-chat dispatch
    /// inside the same task tree uses suppressUserAppend:false and must mint
    /// its own runId rather than inherit this one.
    @TaskLocal public static var pinnedTurnRunID: String?
    /// Session provenance (658.14): the ORIGIN of an inbound message, on its
    /// own channel. Deliberately NOT the `surface` parameter — `surface` is
    /// also the tool-authorization surface (the claude/codex bridges run with
    /// `surface: "chat"` on purpose, per User's 2026-06-13 call that the bridge
    /// gets the same tool surface as chat), so retagging it to carry origin
    /// would silently change what the bridge is allowed to do. Stamped onto
    /// the USER row's metadata only; assistant rows are always hers.
    @TaskLocal public static var originProvenance: ChatMessageOrigin?
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
    /// Item 8 (2026-09-02). The lane's own statement that the AGENT composed
    /// this text, rather than the bridge carrying the human's words through it.
    ///
    /// `surface` and `agent` describe the ROUTE, and a route cannot answer the
    /// question the affect layer has to ask. Claude relaying "User says: ship
    /// it" arrives on the same surface, from the same agent, as Claude saying
    /// something herself — and only one of those is another person moving her.
    /// Nil means unstated, which is read as the human: the honest default when
    /// nobody has claimed authorship, and the same direction the render
    /// allowlist fails in.
    ///
    /// Set ONLY by a lane that knows it is transcribing its own agent's output.
    /// A future forwarding lane must leave it nil.
    public let authored: ChatMessageAuthorship?
    /// The Claude inbox message this row answers, when the sender named one.
    public var replyTo: String? = nil

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

    public init(
        deliveryId: String,
        requestDigest: String,
        model: String,
        reasoningEffort: String?
    ) {
        self.deliveryId = deliveryId
        self.requestDigest = requestDigest
        self.model = model
        self.reasoningEffort = reasoningEffort
    }
}
