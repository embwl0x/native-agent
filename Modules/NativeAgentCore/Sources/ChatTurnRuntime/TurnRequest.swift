import Foundation
import CognitiveSubstrate
import NativeAgentCore
import TrustCenter

/// Everything one ingress decides about a turn, in one value: what was said,
/// where it goes, who sent it, and the per-turn facts the engine reads from
/// task-locals. An ingress fills this in and hands it to the binder; it never
/// builds its own nest of `withValue` calls.
///
/// A binding field is doubly optional so a request binds exactly what its
/// ingress said: left out, it stays UNBOUND (the caller's value is inherited);
/// given an optional, it is bound to that value — nil included, which clears
/// an inherited one, as an explicit `withValue(nil)` does.
public struct TurnRequest: Sendable {
    public var message: String
    public var sessionID: String?
    public var model: String
    public var reasoningEffort: String
    public var fileAccess: String
    public var attachments: [MultimodalAttachment]
    public var persona: String?
    /// The tool-authorization surface. Not provenance: see `origin`.
    public var surface: String
    public var suppressUserAppend: Bool

    /// `ChatToolSessionContext.envelope`: authoritative surface identity.
    public var envelope: TurnEnvelope??
    /// `ChatToolSessionContext.verifiedSessionId`.
    public var verifiedSessionID: String??
    /// `ChatToolSessionContext.verifiedChatId`.
    public var verifiedChatID: String??
    /// `ChatToolSessionContext.verifiedUserId`.
    public var verifiedUserID: String??
    /// Bound through `ChatToolSessionContext.withReplyRoute`, so the turn
    /// trace names the same destination and thread. Nil = unbound.
    public var replyRoute: ChatToolSessionContext.ReplyRoute?
    /// `ChatPersistenceContext.originProvenance`, stamped on the user row.
    public var origin: ChatMessageOrigin??
    /// `ChatPersistenceContext.pinnedTurnRunID`: the enqueued row's run.
    public var pinnedRunID: String??
    /// `ChatPersistenceContext.codexCompletionBinding`.
    public var codexCompletion: CodexCompletionTranscriptBinding??
    /// `ChatPersistenceContext.replacementAssistantMessageID`: the reply a
    /// regenerate replaces.
    public var replacementAssistantMessageID: String??
    /// `LLMCallContext.serviceTier`.
    public var serviceTier: String??

    public init(
        message: String,
        sessionID: String?,
        model: String = "",
        reasoningEffort: String = "",
        fileAccess: String = "auto",
        attachments: [MultimodalAttachment] = [],
        persona: String? = nil,
        surface: String,
        suppressUserAppend: Bool = false,
        envelope: TurnEnvelope?? = nil,
        verifiedSessionID: String?? = nil,
        verifiedChatID: String?? = nil,
        verifiedUserID: String?? = nil,
        replyRoute: ChatToolSessionContext.ReplyRoute? = nil,
        origin: ChatMessageOrigin?? = nil,
        pinnedRunID: String?? = nil,
        codexCompletion: CodexCompletionTranscriptBinding?? = nil,
        replacementAssistantMessageID: String?? = nil,
        serviceTier: String?? = nil
    ) {
        self.message = message
        self.sessionID = sessionID
        self.model = model
        self.reasoningEffort = reasoningEffort
        self.fileAccess = fileAccess
        self.attachments = attachments
        self.persona = persona
        self.surface = surface
        self.suppressUserAppend = suppressUserAppend
        self.envelope = envelope
        self.verifiedSessionID = verifiedSessionID
        self.verifiedChatID = verifiedChatID
        self.verifiedUserID = verifiedUserID
        self.replyRoute = replyRoute
        self.origin = origin
        self.pinnedRunID = pinnedRunID
        self.codexCompletion = codexCompletion
        self.replacementAssistantMessageID = replacementAssistantMessageID
        self.serviceTier = serviceTier
    }

    /// The turn that consumes an enqueued user row: same request, on the
    /// row's resolved session, adopting its run id, without a second append.
    public func consuming(_ enqueued: EnqueuedUserMessage) -> TurnRequest {
        var turn = self
        turn.sessionID = enqueued.sessionId
        turn.pinnedRunID = enqueued.runId
        turn.suppressUserAppend = true
        return turn
    }

    /// The binder: this request's task-locals, bound in one place with the
    /// async overload for the whole of `operation`. Anything `operation`
    /// spawns inherits them for its life.
    ///
    /// A turn an agent's words start is peer-steered from its first line
    /// (Agent, 10-02): a named lane (Claude, Codex, OMP) latches the taint
    /// with its line. The generic peer lane unelevated is the peer's by its
    /// surface and keeps its line; elevated, it marks the peer as elevated,
    /// so only the floor acts card.
    public func bind<T>(isolation: isolated (any Actor)? = #isolation,
                        _ operation: () async throws -> T) async rethrows -> T {
        if case .some(.some(let origin)) = origin, let sources = origin.peerSources {
            let taint = PeerDataTaint.current ?? PeerDataTaint()
            for source in sources { taint.mark(peer: source, attested: false) }
            for source in origin.elevatedPeerSources ?? [] { taint.markElevated(peer: source, attested: false) }
            // Recorded steering, including an empty record, is authoritative.
            return try await Self.bound(PeerDataTaint.$current, taint) {
                try await bindContext(operation)
            }
        }
        guard case .some(.some(let origin)) = origin, origin.authored == .agent,
              let agent = origin.agent, agent != "self", !agent.hasPrefix("bot:") else {
            return try await bindContext(operation)
        }
        let taint = PeerDataTaint.current ?? PeerDataTaint()
        if agent != "agent" {
            taint.mark(peer: agent, line: message)
        } else if PeerTurnEffectPolicy.isPeerBridge(surface: surface) {
            taint.keep(line: message)
        } else {
            taint.markElevated(peer: (envelope ?? nil)?.verifiedUserId.map { "peer:" + $0 } ?? "a peer", line: message)
        }
        return try await Self.bound(PeerDataTaint.$current, taint) { try await bindContext(operation) }
    }

    private func bindContext<T>(isolation: isolated (any Actor)? = #isolation,
                               _ operation: () async throws -> T) async rethrows -> T {
        try await Self.bound(ChatToolSessionContext.$envelope, envelope) {
            try await Self.bound(ChatToolSessionContext.$verifiedSessionId, verifiedSessionID) {
                try await Self.bound(ChatToolSessionContext.$verifiedChatId, verifiedChatID) {
                    try await Self.bound(ChatToolSessionContext.$verifiedUserId, verifiedUserID) {
                        try await Self.bound(ChatPersistenceContext.$originProvenance, origin) {
                            try await Self.bound(ChatPersistenceContext.$pinnedTurnRunID, pinnedRunID) {
                                try await Self.bound(ChatPersistenceContext.$codexCompletionBinding, codexCompletion) {
                                    try await Self.bound(ChatPersistenceContext.$replacementAssistantMessageID, replacementAssistantMessageID) {
                                        try await Self.bound(LLMCallContext.$serviceTier, serviceTier) {
                                            guard let replyRoute else { return try await operation() }
                                            return try await ChatToolSessionContext.withReplyRoute(replyRoute, operation: operation)
                                        }
                                    }
                                }
                            }
                        }
                    }
                }
            }
        }
    }

    /// Durably append the user row under this request's bindings.
    public func enqueue(
        on client: any ChatOrchestrationClient,
        mechanicalRow: CognitiveMechanicalRowKind? = nil
    ) async throws -> EnqueuedUserMessage {
        try await bind {
            try await client.enqueueUserMessage(
                message: message,
                sessionId: sessionID,
                persona: persona,
                surface: surface,
                attachments: attachments,
                mechanicalRow: mechanicalRow
            )
        }
    }

    /// Run the turn under this request's bindings.
    public func chat(
        on client: any ChatOrchestrationClient,
        progress: ChatOrchestrationProgressHandler? = nil
    ) async throws -> ChatResponse {
        try await bind {
            try await client.chat(
                message: message,
                sessionId: sessionID,
                model: model,
                reasoningEffort: reasoningEffort,
                fileAccess: fileAccess,
                attachments: attachments,
                persona: persona,
                surface: surface,
                suppressUserAppend: suppressUserAppend,
                progress: progress
            )
        }
    }

    private static func bound<V: Sendable, T>(
        _ local: TaskLocal<V?>,
        _ value: V??,
        isolation: isolated (any Actor)? = #isolation,
        _ operation: () async throws -> T
    ) async rethrows -> T {
        guard let value else { return try await operation() }
        return try await local.withValue(value, operation: operation)
    }
}

/// One turn at a time per session, for every ingress that admits through it.
/// A turn waits here until the one before it in the same session has finished,
/// so two replies never interleave in one transcript. Durable enqueue and
/// completion deduplication keep their own owners.
public actor TurnAdmission {
    public static let shared = TurnAdmission()

    public init() {}

    private struct Waiter {
        let id: UUID
        let continuation: CheckedContinuation<Void, Error>
    }
    private var active: [String: UUID] = [:]
    private var waiting: [String: [Waiter]] = [:]

    public struct Full: LocalizedError {
        public var errorDescription: String? { "This chat has too many waiting turns. No new turn was started." }
    }

    /// Nil session = a new chat nobody else can be in; runs at once.
    public func run<T>(sessionID: String?, isolation: isolated (any Actor)? = #isolation,
                       operation: () async throws -> T) async throws -> T {
        guard let sessionID else { return try await operation() }
        let id = UUID()
        try await acquire(sessionID, id: id)
        do {
            try Task.checkCancellation()
            let result = try await operation()
            await release(sessionID, id: id)
            return result
        } catch {
            await release(sessionID, id: id)
            throw error
        }
    }

    private func acquire(_ key: String, id: UUID) async throws {
        try Task.checkCancellation()
        if active[key] == nil {
            active[key] = id
            return
        }
        guard (waiting[key]?.count ?? 0) < 8,
              waiting.values.reduce(0, { $0 + $1.count }) < 32 else { throw Full() }
        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
                if Task.isCancelled {
                    continuation.resume(throwing: CancellationError())
                } else {
                    waiting[key, default: []].append(Waiter(id: id, continuation: continuation))
                }
            }
        } onCancel: {
            Task { await self.cancel(key, id: id) }
        }
    }

    private func cancel(_ key: String, id: UUID) {
        guard let index = waiting[key]?.firstIndex(where: { $0.id == id }),
              let waiter = waiting[key]?.remove(at: index) else { return }
        if waiting[key]?.isEmpty == true { waiting.removeValue(forKey: key) }
        waiter.continuation.resume(throwing: CancellationError())
    }

    private func release(_ key: String, id: UUID) {
        guard active[key] == id else { return }
        active.removeValue(forKey: key)
        guard var queue = waiting.removeValue(forKey: key), !queue.isEmpty else { return }
        let next = queue.removeFirst()
        if !queue.isEmpty { waiting[key] = queue }
        active[key] = next.id
        next.continuation.resume()
    }
}
