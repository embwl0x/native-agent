import Foundation
import NativeAgentCore
import PersistenceCore
import TurnTrace
import MacControl

// MARK: - Per-turn tool session context

/// Carries the per-turn verified session id down the tool-dispatch chain so
/// inner app-side dispatchers can reconstruct the SAME security origin (and
/// thus the same trust resolution) that the authoritative `AutonomyGatedDispatcher`
/// already computed.
///
/// Why this exists: `ToolDispatchClient.dispatch(tool:input:surface:)` threads
/// only the surface, not the session. `AutonomyGatedDispatcher` captures the
/// verified session id at construction (per-turn) and is the authoritative
/// security gate. But `AppChatToolDispatcher` (app target) sits BELOW it and is
/// constructed once per client — with no session, its own `evaluateTool` call
/// hardcoded `sessionId: nil`, so for a TRUSTED remote surface (allowlisted
/// Telegram) it could not resolve the chatId, failed the allowlist match, and
/// FALSE-BLOCKED an invoke the authoritative gate had already approved
/// (security/audit.jsonl 2026-06-09 19:24, surface=telegram, sessionId nil).
///
/// `AutonomyGatedDispatcher` binds this TaskLocal around its `inner.dispatch`
/// call, so any downstream dispatcher reads the real session and resolves trust
/// identically. Nil when no gated chain is in play (e.g. read-only catalog
/// refresh), which is correct — those paths carry no remote session.
public enum ChatToolSessionContext {
    public struct ReplyRoute: Sendable, Equatable {
        public let surface: String
        public let destinationId: String?
        public let threadId: String?
        public let sourceKey: String?
        public let replyTo: String?
        public let correlationId: String?

        public init(
            surface: String,
            destinationId: String? = nil,
            threadId: String? = nil,
            sourceKey: String? = nil,
            replyTo: String? = nil,
            correlationId: String? = nil
        ) {
            self.surface = surface
            self.destinationId = destinationId
            self.threadId = threadId
            self.sourceKey = sourceKey
            self.replyTo = replyTo
            self.correlationId = correlationId
        }

        /// Whether this route ends at a surface that can DRAW an inline card.
        ///
        /// Only the Mac and iPhone chat UIs render the card; the Mac's own
        /// in-process turn carries no route at all, which is why a nil route is
        /// treated as the UI (see `rendersInlineCards(_:)` below). Every other
        /// route — Telegram, Slack, the bridge — is text and nothing else, and
        /// a card sent there must be said in prose or it arrives as silence.
        ///
        /// It keys on the ROUTE, never on `surface:` as passed to `chat(…)`:
        /// the Claude bridge deliberately calls in as surface "chat" and
        /// carries its real destination only here.
        public var rendersInlineCards: Bool {
            switch surface.lowercased() {
            case "chat", "mac", "app", "ios", "iphone", "ipad", "icloud": true
            default: false
            }
        }
    }

    /// The turn's route, answered for the ABSENT case too: a Mac chat turn runs
    /// in-process and binds no route, and it is the one surface that has always
    /// been able to draw the card.
    public static func rendersInlineCards(_ route: ReplyRoute?) -> Bool {
        route?.rendersInlineCards ?? true
    }

    /// True while the turn is being consumed as a STREAM by a chat UI.
    ///
    /// Bound by the stream facade, which is what the Mac and iPhone chat views
    /// consume. Telegram, Slack and the bridge all call the non-streaming
    /// `chat(…)` and read `ChatResponse.output`, so they never see this set —
    /// which is a structural fact about how they consume a turn, not a string
    /// anyone can spell wrong.
    @TaskLocal public static var replyStreamRendersCards: Bool = false

    /// Whether this turn's only way to say something is TEXT.
    ///
    /// Both signals must agree before prose is withheld: the turn is being
    /// streamed to a UI, AND the route ends at a surface that draws cards. The
    /// belt and braces are deliberate — the Claude bridge calls in as surface
    /// "chat" and may carry no route at all, and getting this wrong in that
    /// direction is exactly the silence this guards against.
    public static var replyIsTextOnly: Bool {
        !(replyStreamRendersCards && rendersInlineCards(replyRoute))
    }

    /// The per-turn envelope. See `TurnEnvelope` below — this is the ONE
    /// value a new surface adapter fills in, and every field below is its
    /// projection. Bound by the transport around its `chat()` call.
    ///
    /// Nil for turns whose surface predates the envelope; the individual
    /// task-locals below remain the authority in that case, so an adapter can
    /// migrate without a flag day.
    @TaskLocal public static var envelope: TurnEnvelope?

    @TaskLocal public static var verifiedSessionId: String?

    /// The current request only; history and tool results never populate this.
    @TaskLocal public static var userText: String?

    public static func forbidsSending(_ text: String) -> Bool {
        text.range(of: #"(?i)\b(?:don['’]t\s+send|do\s+not\s+send|just\s+draft|save\s+as\s+draft|not\s+yet)\b"#,
                   options: .regularExpression) != nil
    }

    /// Nil rejects the quote; otherwise says whether this restores her last switch change.
    @TaskLocal public static var settingRequestEvidence: (@Sendable (String, JSONValue, JSONValue, String) async -> Bool?)?

    /// The filing turn's file access, bound by the gate while it files a card
    /// so the card's follow-up runs with the same hands (Wave 2 #8).
    @TaskLocal public static var fileAccess: String?

    /// The transport-verified remote chat identifier (e.g. Telegram chatId),
    /// set by the remote transport around its `chat()` call. Trust resolution
    /// for Telegram matches the allowlist on this id. We carry it explicitly
    /// because the chatId is NOT always recoverable from the session id string:
    /// the legacy session form is `telegram:<chatId>`, but a `/new` session is a
    /// bare UUID. Without this, an allowlisted Telegram chat on a UUID session
    /// derives `chatId=nil` in BOTH gates and high-risk invokes false-block.
    /// Nil for local/Mac surfaces (no remote id) and for iOS (trust is
    /// policy-based, not id-based) — both correct.
    @TaskLocal public static var verifiedChatId: String?

    /// The transport-verified remote USER identifier (e.g. Slack user id),
    /// set by the remote transport around its `chat()` call. Trust resolution
    /// for Slack can match the user allowlist on this id — without it the
    /// origin builders set userId=nil and a user-only allowlisted sender
    /// transport-accepts but stays high-risk-untrusted (gpt-5.5 review
    /// 2026-07-21). Nil where no per-user trust root exists.
    @TaskLocal public static var verifiedUserId: String?

    /// True when the inbound remote transport has already verified provenance
    /// for this turn. Socket Mode Slack events arrive over a preauthenticated
    /// WebSocket rather than per-event signed HTTP requests; the transport binds
    /// this after it has opened the app-token socket.
    @TaskLocal public static var commandSignatureVerified: Bool?

    /// Immutable return route for work that finishes after the originating
    /// turn has ended. Async agent bridges persist this with their job rather
    /// than trying to rediscover a Telegram chat, Slack thread, or iOS device
    /// from mutable current-surface state at completion time.
    @TaskLocal public static var replyRoute: ReplyRoute?

    /// Bind the turn's return route AND mirror its delivery identity onto the
    /// turn-trace context in one call, so the rows this turn writes name the
    /// conversation it came from.
    ///
    /// 2026-09-13: the trace row was the only record of where Agent last was,
    /// and it carried surface and session but never destination or thread — so
    /// a knock that could have gone back to the Telegram topic or Slack thread
    /// it came from always fell back to the phone. Binding both together is
    /// what keeps a surface from setting one and forgetting the other.
    public static func withReplyRoute<T>(
        _ route: ReplyRoute,
        operation: () async throws -> T
    ) async rethrows -> T {
        try await $replyRoute.withValue(route) {
            try await TurnTraceContext.$destinationId.withValue(route.destinationId) {
                try await TurnTraceContext.$threadId.withValue(route.threadId) {
                    try await operation()
                }
            }
        }
    }
}


// MARK: - TurnEnvelope (the per-turn surface contract)

/// EVERYTHING one turn's surface identity consists of, in one value.
///
/// # How to add a surface
///
/// NativeAgent is built so a new messaging surface — Signal, WhatsApp, a
/// device, anything — can be connected later. This type is the contract that
/// makes that a small job. A new adapter does exactly three things and touches
/// nothing outside itself:
///
/// 1. **Bind identity.** Build a `TurnEnvelope` naming its `surface` and the
///    identifiers its transport ACTUALLY VERIFIED — `verifiedChatId` (the
///    conversation) and/or `verifiedUserId` (the person) — and bind it around
///    its `chat()` call with `ChatToolSessionContext.$envelope.withValue(_:)`.
///    Whatever the transport could not verify stays nil. Nil is honest and
///    fails closed; a guess is neither.
/// 2. **Provide a delivery route.** Fill `deliveryRoute` so a completion that
///    lands after the originating loop has moved on still knows where to go.
///    `replyRoute` is this envelope's delivery projection, so every existing
///    `ChatToolSessionContext.replyRoute` consumer keeps working unchanged.
/// 3. **Publish an anchor**, if the surface is a direct conversation with the
///    human rather than a shared room — see `ConversationAnchor` in
///    PersistenceCore. That is a one-line call and it is surface-agnostic:
///    the Mac and the phone consume the anchor without knowing which surface
///    published it.
///
/// There is no fourth step. In particular an adapter must NOT encode identity
/// into the session id and expect a gate to parse it back out. Five sites used
/// to do that (plan §1.2); all five are deleted. The session id is a storage
/// key — path-safe, opaque, and evidence of nothing.
///
/// # Two invariants this type exists to hold
///
/// **A tool call's authority comes from the CURRENT turn's envelope, never
/// from any envelope in history.** History rows are prose plus provenance
/// labels; they grant nothing. A Mac-authored (local, trusted) turn can sit
/// three rows above a remote allowlist-gated turn in the same transcript, and
/// the remote turn is still assessed alone.
///
/// **Surface never widens.** `isRemote` is derived from the surface profile
/// and can be ADDED to an unknown surface but never SUBTRACTED from a
/// known-remote one. That rule is enforced generically in
/// `SecurityCenter.assessOrigin` against `ConversationSurfaceProfile`, so it
/// covers a surface added tomorrow exactly as it covers the ones here today.
public struct TurnEnvelope: Sendable, Equatable {
    /// The immutable return route for work that finishes after the
    /// originating turn has ended. Kept as its own value because it is the
    /// half of the envelope that must be DURABLE on the message row.
    public typealias DeliveryRoute = ChatToolSessionContext.ReplyRoute

    /// Raw surface name, as the adapter calls itself ("telegram", "slack",
    /// "signal", "chat"). Normalization to a canonical profile happens at the
    /// trust boundary, not here — this field records what the adapter said.
    public let surface: String
    /// Bridge lane, when the turn arrived through an agent bridge
    /// ("claude", "codex"). Generalizes the existing `metadata.origin.agent`.
    public let agent: String?
    /// The conversation identifier the TRANSPORT verified. Nil when the
    /// transport has no such notion (a local window) or could not verify one.
    public let verifiedChatId: String?
    /// The person identifier the TRANSPORT verified. Nil as above.
    public let verifiedUserId: String?
    /// True when the inbound transport has already verified provenance for
    /// this turn by its own scheme (a signed request, a preauthenticated
    /// socket). Nil means "no such scheme", which is not the same as false.
    public let commandSignatureVerified: Bool?
    /// Where this turn's reply goes, and nowhere else.
    public let deliveryRoute: DeliveryRoute?
    /// Explicit remoteness for a surface the profile does not know yet. It can
    /// only ADD remoteness — see the widening invariant above.
    public let declaredRemote: Bool?
    /// Request-time AX evidence, process-local and never restored from history.
    public let macContinuation: MacWorkContinuation?

    public init(
        surface: String,
        agent: String? = nil,
        verifiedChatId: String? = nil,
        verifiedUserId: String? = nil,
        commandSignatureVerified: Bool? = nil,
        deliveryRoute: DeliveryRoute? = nil,
        declaredRemote: Bool? = nil,
        macContinuation: MacWorkContinuation? = nil
    ) {
        self.surface = surface
        self.agent = agent
        self.verifiedChatId = Self.cleaned(verifiedChatId)
        self.verifiedUserId = Self.cleaned(verifiedUserId)
        self.commandSignatureVerified = commandSignatureVerified
        self.deliveryRoute = deliveryRoute
        self.declaredRemote = declaredRemote
        self.macContinuation = macContinuation
    }

    public func withMacContinuation(_ continuation: MacWorkContinuation) -> TurnEnvelope {
        TurnEnvelope(surface: surface, agent: agent, verifiedChatId: verifiedChatId,
            verifiedUserId: verifiedUserId, commandSignatureVerified: commandSignatureVerified,
            deliveryRoute: deliveryRoute, declaredRemote: declaredRemote, macContinuation: continuation)
    }

    /// The delivery projection. `ReplyRoute` predates the envelope and has
    /// many consumers; keeping it as a projection rather than replacing it is
    /// what lets Phase 1 land without touching them.
    ///
    /// Falls back to a route carrying just the surface so a caller that bound
    /// an envelope but no explicit route still gets an honest surface tag.
    public var replyRoute: DeliveryRoute {
        deliveryRoute ?? DeliveryRoute(surface: surface)
    }

    /// The durable shape written to `metadata.envelope` on every message row.
    ///
    /// `trusted` is NOT included and must never be: a persisted trust verdict
    /// would be exactly the "authority from history" this type forbids. The
    /// row records WHO and WHERE, and the gate re-decides every turn.
    public func persistedMetadata() -> JSONValue {
        var object: [String: JSONValue] = ["surface": .string(surface)]
        func put(_ key: String, _ value: String?) {
            guard let value, !value.isEmpty else { return }
            object[key] = .string(value)
        }
        put("agent", Self.cleaned(agent))
        put("chatId", verifiedChatId)
        put("userId", verifiedUserId)
        put("destinationId", Self.cleaned(deliveryRoute?.destinationId))
        put("threadId", Self.cleaned(deliveryRoute?.threadId))
        put("sourceKey", Self.cleaned(deliveryRoute?.sourceKey))
        put("replyTo", Self.cleaned(deliveryRoute?.replyTo))
        put("correlationId", Self.cleaned(deliveryRoute?.correlationId))
        return .object(object)
    }

    /// Rebuild an envelope from a persisted row. Provenance only — the result
    /// is a LABEL for a reader, never an authorization for a tool call.
    public static func fromPersistedMetadata(_ value: JSONValue?) -> TurnEnvelope? {
        guard case .object(let object)? = value else { return nil }
        func read(_ key: String) -> String? {
            guard case .string(let string)? = object[key] else { return nil }
            return cleaned(string)
        }
        guard let surface = read("surface") else { return nil }
        let route = ChatToolSessionContext.ReplyRoute(
            surface: surface,
            destinationId: read("destinationId"),
            threadId: read("threadId"),
            sourceKey: read("sourceKey"),
            replyTo: read("replyTo"),
            correlationId: read("correlationId")
        )
        return TurnEnvelope(
            surface: surface,
            agent: read("agent"),
            verifiedChatId: read("chatId"),
            verifiedUserId: read("userId"),
            deliveryRoute: route
        )
    }

    /// Assemble the envelope for the turn in flight.
    ///
    /// Prefers an explicitly bound envelope; otherwise composes one from the
    /// individual `ChatToolSessionContext` task-locals the pre-envelope
    /// adapters already bind. That fallback is what makes Phase 1 additive:
    /// nothing has to migrate on the same day.
    public static func current(surface: String) -> TurnEnvelope {
        if let bound = ChatToolSessionContext.envelope {
            return bound
        }
        return TurnEnvelope(
            surface: surface,
            verifiedChatId: ChatToolSessionContext.verifiedChatId,
            verifiedUserId: ChatToolSessionContext.verifiedUserId,
            commandSignatureVerified: ChatToolSessionContext.commandSignatureVerified,
            deliveryRoute: ChatToolSessionContext.replyRoute
        )
    }

    private static func cleaned(_ value: String?) -> String? {
        guard let trimmed = value?.trimmingCharacters(in: .whitespacesAndNewlines),
              !trimmed.isEmpty else { return nil }
        return trimmed
    }
}

/// Exact, single-dispatch evidence that a human already approved the persisted
/// chat-tool request being replayed. This is deliberately not a general
/// autonomy override: it only prevents `PersonaWriteGuard` from asking the
/// same confirmation question twice when every approved payload and verified
/// origin field still matches. SecurityCenter, file access, and the tool's own
/// effect-time validation continue to run normally.
///
/// W2/W3-FIX-R2 1 — THIS TYPE CARRIES NO AUTHORITY OF ITS OWN. It is a public
/// value type with a public init (the post-approval executor lives in the app
/// target and has to be able to build one), so `matches` proves only that the
/// CALLER's fields agree with the CALLER's call. For an injection tool that is
/// not enough and never was: the dispatcher now takes this struct as a POINTER
/// to an approval record and asks `InjectionApprovalVerifying` whether that
/// record exists, is resolved-approved, is for this tool + surface + body, and
/// is unspent — before the floor exemption and before the mint. A forged
/// struct with a made-up id gets no exemption and mints nothing.
public struct ApprovedChatToolReplay: Sendable, Equatable {
    public let approvalID: String
    public let tool: String
    public let surface: String
    public let input: [String: JSONValue]
    public let verifiedSessionID: String?
    public let verifiedChatID: String?
    public let verifiedUserID: String?

    public init(
        approvalID: String,
        tool: String,
        surface: String,
        input: [String: JSONValue],
        verifiedSessionID: String?,
        verifiedChatID: String?,
        verifiedUserID: String?
    ) {
        self.approvalID = approvalID
        self.tool = tool
        self.surface = surface
        self.input = input
        self.verifiedSessionID = verifiedSessionID
        self.verifiedChatID = verifiedChatID
        self.verifiedUserID = verifiedUserID
    }


}

/// Per-turn runtime facts the tool loop binds so in-process tools can report
/// what's actually generating the current turn. `agent_introspect` reads this
/// to answer "which model/provider is running me right now" accurately — the
/// live turn model can differ from the surface's configured model (a per-turn
/// override), and the surface lets it resolve the real active provider. Nil
/// when a tool runs outside a chat turn (e.g. a direct dispatch), in which case
/// introspect falls back to the configured model.
public enum ChatTurnRuntimeContext {
    public struct Active: Sendable {
        public let model: String
        public let surface: String
        public let personaID: String?
        /// Exact provider/auth transport admitted for this turn. Keep this
        /// separate from model-family inference: API key, OAuth-direct,
        /// OpenRouter, and Codex may expose overlapping model names.
        public let providerID: String?
        public init(
            model: String,
            surface: String,
            personaID: String? = nil,
            providerID: String? = nil
        ) {
            self.model = model
            self.surface = surface
            self.personaID = personaID
            self.providerID = providerID
        }
    }
    @TaskLocal public static var current: Active?
}
