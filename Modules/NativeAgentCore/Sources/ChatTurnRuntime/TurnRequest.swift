import Foundation
import NativeAgentShared
import Transcripts
import CognitiveSubstrate
import NativeAgentCore
import TrustCenter
import TurnTrace
// Blueprint: | `TurnRequest.swift` | `TurnRequest`: shared turn binding; `TurnAdmission`: per-session serialization, root-scoped resident reload exclusion, bounded admission queues and release/cancellation capacity signals for durable arrivals |

enum TurnRelevanceContext {
    @TaskLocal static var queryUserMessage: String?
}

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
    /// Transport-authored relevance payload; never extracted from message text.
    public var queryUserMessage: String??
    public var sessionID: String?
    public var model: String
    public var reasoningEffort: String
    /// Request restriction; the shared turn owner also applies the saved choice.
    public var fileAccess: String
    public var attachments: [MultimodalAttachment]
    public var persona: String?
    /// The tool-authorization surface. Not provenance: see `origin`.
    public var surface: String
    public var threadKind: ChatThreadKind?
    public var ownedSessionID: String?
    /// Claimed care arrivals for this resident wake, cleared on other turns.
    public var careWakes: [CognitiveCareWake]?
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
    /// trace names the same destination and thread. Outer nil inherits; inner nil clears.
    public var replyRoute: ChatToolSessionContext.ReplyRoute??
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
        serviceTier: String?? = nil,
        queryUserMessage: String?? = nil,
        threadKind: ChatThreadKind? = nil,
        ownedSessionID: String? = nil,
        careWakes: [CognitiveCareWake]? = nil
    ) {
        self.message = message
        self.careWakes = careWakes
        self.queryUserMessage = queryUserMessage
        self.sessionID = sessionID
        self.model = model
        self.reasoningEffort = reasoningEffort
        self.fileAccess = fileAccess
        self.attachments = attachments
        self.persona = persona
        self.surface = surface
        self.threadKind = threadKind
        self.ownedSessionID = ownedSessionID
        self.suppressUserAppend = suppressUserAppend
        self.envelope = envelope
        self.verifiedSessionID = verifiedSessionID
        self.verifiedChatID = verifiedChatID
        self.verifiedUserID = verifiedUserID
        self.replyRoute = replyRoute.map { Optional($0) }
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
    /// A turn an agent's words start is peer-steered from its first line:
    /// a named lane latches the taint
    /// with its line. The generic peer lane unelevated is the peer's by its
    /// surface and keeps its line; elevated, it marks the peer as elevated,
    /// so only the floor acts card.
    public func bind<T>(isolation: isolated (any Actor)? = #isolation,
                        _ operation: () async throws -> T) async rethrows -> T {
        if case .some(.some(let origin)) = origin, let sources = origin.peerSources {
            let taint = PeerDataTaint.current ?? PeerDataTaint()
            // The turn's input is the agent's words: the card quotes them.
            taint.keep(line: message)
            for source in sources { taint.mark(peer: source) }
            for source in origin.elevatedPeerSources ?? [] { taint.elevate(peer: source) }
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
            taint.mark(peer: (envelope ?? nil)?.verifiedUserId.map { "peer:" + $0 } ?? agent, line: message)
        } else if PeerTurnEffectPolicy.isPeerBridge(surface: surface) {
            taint.keep(line: message)
        } else {
            taint.mark(peer: (envelope ?? nil)?.verifiedUserId.map { "peer:" + $0 } ?? "a peer", line: message)
        }
        return try await Self.bound(PeerDataTaint.$current, taint) { try await bindContext(operation) }
    }

    func bindContext<T>(isolation: isolated (any Actor)? = #isolation,
                        _ operation: () async throws -> T) async rethrows -> T {
        // The request is the ingress owner. It supplies one current envelope
        // from its explicit transport fields before any downstream reader runs.
        // Nested work inherits its caller's bound envelope unless it explicitly replaces/clears it.
        let requestEnvelope: TurnEnvelope?
        if let envelope { requestEnvelope = envelope }
        else if let inherited = ChatToolSessionContext.envelope { requestEnvelope = inherited }
        else {
            requestEnvelope = TurnEnvelope(surface: surface,
                verifiedChatId: verifiedChatID ?? nil, verifiedUserId: verifiedUserID ?? nil,
                deliveryRoute: replyRoute ?? nil)
        }
        return try await Self.bound(ChatPersistenceContext.$threadKind, .some(threadKind)) {
        try await Self.bound(ChatPersistenceContext.$ownedSessionID, .some(ownedSessionID)) {
        try await AfterTurnSource.$careWakes.withValue(careWakes ?? []) {
        try await Self.bound(ChatToolSessionContext.$envelope, .some(requestEnvelope)) {
            try await Self.bound(ChatToolSessionContext.$verifiedSessionId, verifiedSessionID) {
                try await Self.bound(ChatToolSessionContext.$verifiedChatId, .some(requestEnvelope?.verifiedChatId)) {
                    try await Self.bound(ChatToolSessionContext.$verifiedUserId, .some(requestEnvelope?.verifiedUserId)) {
                        try await Self.bound(ChatToolSessionContext.$commandSignatureVerified, .some(requestEnvelope?.commandSignatureVerified)) {
                        try await Self.bound(ChatPersistenceContext.$originProvenance, origin) {
                            try await Self.bound(ChatPersistenceContext.$pinnedTurnRunID, pinnedRunID) {
                                try await Self.bound(ChatPersistenceContext.$codexCompletionBinding, codexCompletion) {
                                    try await Self.bound(ChatPersistenceContext.$replacementAssistantMessageID, replacementAssistantMessageID) {
                                        try await Self.bound(LLMCallContext.$serviceTier, serviceTier) {
                                            try await Self.bound(TurnRelevanceContext.$queryUserMessage, queryUserMessage) {
                                                return try await ChatToolSessionContext.withReplyRoute(replyRoute ?? requestEnvelope?.deliveryRoute, operation: operation)
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
        }
        }
        }
        }
    }

    /// Durably append the user row under this request's bindings.
    public func enqueue(
        on client: SwiftNativeChatOrchestrationClient,
        mechanicalRow: CognitiveMechanicalRowKind? = nil,
        awaitingConsumption: Bool = true
    ) async throws -> EnqueuedUserMessage {
        // The row's run is this request's own pin, never one inherited from an
        // enclosing turn: a door that registered Stop at admission pins it here.
        try await bind { try await ChatPersistenceContext.$pinnedTurnRunID.withValue(pinnedRunID ?? nil) {
            try await client.enqueueUserMessage(
                message: message,
                sessionId: sessionID,
                persona: persona,
                surface: surface,
                attachments: attachments,
                mechanicalRow: mechanicalRow,
                awaitingConsumption: awaitingConsumption
            )
        } }
    }

    /// Run the turn under this request's bindings.
    public func chat(
        on client: SwiftNativeChatOrchestrationClient,
        progress: TurnEventSink? = nil
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
    @TaskLocal public static var token: UUID?

    public init() {}

    private struct Waiter {
        let id: UUID
        let runID: String?
        let done: ScopedWaiter
    }
    private var active: [String: UUID] = [:]
    private var waiting: [String: [Waiter]] = [:]
    private var capacityWaiters: [UUID: ScopedWaiter] = [:]
    /// The runs a restart left in a session, in the order they were said:
    /// each is admitted before any other turn there, one after another.
    private var backlog: [String: [String]] = [:]
    /// Until launch recovery has inventoried accepted contact/builder tasks
    /// (`restorationComplete`), a new turn in a named session waits here:
    /// nothing new is admitted there ahead of what was already said.
    private var restoring = true
    private var restorationFailure: String?
    private var sessionRestorationFailures: [String: String] = [:]
    private var heldWhileRestoring: [UUID: ScopedWaiter] = [:]
    private var executingRoots: [UUID: String] = [:]
    private var residentTransitions: Set<String> = []
    private var heldForResidentTransition: [String: [UUID: ScopedWaiter]] = [:]
    private var pendingResidentRefreshes: [String: (URL, @MainActor @Sendable () async -> Void)] = [:]
    private var inFlightObserver: NSObjectProtocol?

    private nonisolated func rootKey(_ dataRoot: URL) -> String {
        dataRoot.standardizedFileURL.resolvingSymlinksInPath().path
    }

    /// Publication and reload are one transition, excluded from every door's
    /// executing turn. Stop registrations also cover turns still entering admission.
    /// A busy root retains the latest request until the real owners release it.
    public func refreshResidentWhenIdle(
        dataRoot: URL, operation: @escaping @MainActor @Sendable () async -> Void
    ) async {
        if inFlightObserver == nil {
            inFlightObserver = NotificationCenter.default.addObserver(
                forName: ChatCancelFlag.inFlightDidChange, object: nil, queue: nil
            ) { [weak self] _ in
                Task { await self?.drainResidentRefreshes() }
            }
        }
        pendingResidentRefreshes[rootKey(dataRoot)] = (dataRoot, operation)
        await drainResidentRefreshes()
    }

    private func drainResidentRefreshes() async {
        for root in pendingResidentRefreshes.keys.sorted() {
            while !residentTransitions.contains(root),
                  !executingRoots.values.contains(root),
                  let (dataRoot, operation) = pendingResidentRefreshes[root],
                  ChatCancelFlag.inFlightTurns(dataRoot: dataRoot).isEmpty {
                // No suspension between the idle check and closing admission.
                residentTransitions.insert(root)
                pendingResidentRefreshes.removeValue(forKey: root)
                await operation()
                residentTransitions.remove(root)
                let held = heldForResidentTransition.removeValue(forKey: root) ?? [:]
                for waiter in held.values { waiter.resume() }
            }
        }
    }

    private func enterRoot(_ root: String, id: UUID) async throws {
        while residentTransitions.contains(root) {
            let waiter = ScopedWaiter()
            heldForResidentTransition[root, default: [:]][id] = waiter
            await waiter.park()
            heldForResidentTransition[root]?[id] = nil
            try Task.checkCancellation()
        }
        try Task.checkCancellation()
        executingRoots[id] = root
    }

    private func leaveRoot(id: UUID) async {
        executingRoots.removeValue(forKey: id)
        await drainResidentRefreshes()
    }

    public struct Full: LocalizedError {
        public var errorDescription: String? { "This chat has too many waiting turns. No new turn was started." }
    }
    public struct RestorationUnavailable: LocalizedError {
        public let detail: String
        public var errorDescription: String? { detail }
    }

    /// Nil session = a new chat nobody else can be in; only root admission applies.
    /// Durable arrivals wait for queue capacity; unsaved requests still fail full.
    /// `runID` names the run, so a restored backlog admits it in its place.
    public func run<T>(dataRoot: URL, sessionID: String?, runID: String? = nil, waitForCapacity: Bool = false, isolation: isolated (any Actor)? = #isolation,
                       operation: () async throws -> T) async throws -> T {
        let id = UUID()
        do {
            if let sessionID { try await acquire(sessionID, id: id, runID: runID, waitForCapacity: waitForCapacity) }
        }
        catch {
            // A restored run that will not be admitted gives up its place.
            if let sessionID, let runID { await withdraw(sessionID: sessionID, runID: runID) }
            throw error
        }
        do {
            try await enterRoot(rootKey(dataRoot), id: id)
            try Task.checkCancellation()
            // A new session is resolved inside the operation; its own runner
            // closes steering. Only a named session delegates that close here.
            let result: T
            if sessionID != nil { result = try await Self.$token.withValue(id, operation: operation) }
            else { result = try await operation() }
            if let sessionID { await ChatTurnSteering.shared.closeTurn(sessionId: sessionID, token: id) }
            if let sessionID { await release(sessionID, id: id) }
            await leaveRoot(id: id)
            return result
        } catch {
            if let sessionID { await ChatTurnSteering.shared.closeTurn(sessionId: sessionID, token: id) }
            if let sessionID { await release(sessionID, id: id) }
            await leaveRoot(id: id)
            throw error
        }
    }

    /// At launch, before anything new is admitted there: the runs a restart
    /// left queued or interrupted in this session, oldest first.
    public func restore(sessionID: String, runs: [String]) {
        sessionRestorationFailures[sessionID] = nil
        let known = backlog[sessionID] ?? []
        let added = known + runs.filter { !known.contains($0) }
        backlog[sessionID] = added.isEmpty ? nil : added
    }

    /// The launch recovery has restored every contact conversation's backlog.
    public func restorationComplete() {
        restoring = false
        restorationFailure = nil
        let held = heldWhileRestoring.values
        heldWhileRestoring.removeAll()
        for continuation in held { continuation.resume() }
    }

    /// Failure is an explicit refusal, never an endless restoration wait.
    /// A conversation read failure affects only that conversation; a failed
    /// task-store read prevents proving any contact backlog complete.
    public func restorationFailed(_ detail: String, sessionID: String? = nil) {
        if let sessionID { sessionRestorationFailures[sessionID] = detail }
        else { restorationFailure = detail }
        let held = heldWhileRestoring.values
        heldWhileRestoring.removeAll()
        for continuation in held { continuation.resume() }
    }

    /// A restored run that will not come (it ended, or was never resumed).
    public func withdraw(sessionID: String, runID: String) {
        guard var runs = backlog[sessionID], let index = runs.firstIndex(of: runID) else { return }
        runs.remove(at: index)
        backlog[sessionID] = runs.isEmpty ? nil : runs
        admitNext(sessionID)
    }

    private func admissible(_ key: String, runID: String?) -> Bool {
        guard let head = backlog[key]?.first else { return true }
        return head == runID
    }

    private func admitted(_ key: String, runID: String?) {
        guard let runID, backlog[key]?.first == runID else { return }
        backlog[key]?.removeFirst()
        if backlog[key]?.isEmpty == true { backlog.removeValue(forKey: key) }
    }

    private func acquire(_ key: String, id: UUID, runID: String?, waitForCapacity: Bool) async throws {
        try Task.checkCancellation()
        if let detail = sessionRestorationFailures[key] { throw RestorationUnavailable(detail: detail) }
        while restoring, !(runID.map { backlog[key]?.contains($0) == true } ?? false) {
            if let detail = restorationFailure { throw RestorationUnavailable(detail: detail) }
            if let detail = sessionRestorationFailures[key] { throw RestorationUnavailable(detail: detail) }
            let done = ScopedWaiter()
            heldWhileRestoring[id] = done
            await done.park()
            heldWhileRestoring.removeValue(forKey: id)
            try Task.checkCancellation()
        }
        if let detail = sessionRestorationFailures[key] { throw RestorationUnavailable(detail: detail) }
        try Task.checkCancellation()
        while active[key] != nil || !admissible(key, runID: runID) {
            let hasCapacity = (waiting[key]?.count ?? 0) < 8 && waiting.values.reduce(0, { $0 + $1.count }) < 32
            guard hasCapacity || waitForCapacity else { throw Full() }
            // Registration and the capacity check share this actor. A release
            // cannot slip between them; cancellation also wakes the subscriber.
            let done = ScopedWaiter()
            if hasCapacity { waiting[key, default: []].append(Waiter(id: id, runID: runID, done: done)) }
            else { capacityWaiters[id] = done }
            await done.park()
            if hasCapacity {
                // A handoff owns the slot even if Stop raced it; run's
                // cancellation check then releases that admitted slot.
                if active[key] == id { return }
                if let index = waiting[key]?.firstIndex(where: { $0.id == id }) {
                    waiting[key]?.remove(at: index)
                    if waiting[key]?.isEmpty == true { waiting[key] = nil }
                    signalCapacity()
                }
                throw CancellationError()
            }
            capacityWaiters.removeValue(forKey: id)
            try Task.checkCancellation()
        }
        active[key] = id
        admitted(key, runID: runID)
    }

    private func release(_ key: String, id: UUID) {
        guard active[key] == id else { return }
        defer { signalCapacity() }
        active.removeValue(forKey: key)
        admitNext(key)
    }

    /// The next turn in an idle session: the restored backlog's head when it
    /// is waiting (none while it has yet to arrive), else the oldest waiter.
    private func admitNext(_ key: String) {
        guard active[key] == nil, var queue = waiting[key], !queue.isEmpty else { return }
        let index: Int
        if let head = backlog[key]?.first {
            guard let found = queue.firstIndex(where: { $0.runID == head }) else { return }
            index = found
        } else { index = 0 }
        let next = queue.remove(at: index)
        waiting[key] = queue.isEmpty ? nil : queue
        active[key] = next.id
        admitted(key, runID: next.runID)
        next.done.resume()
    }

    private func signalCapacity() {
        let subscribers = capacityWaiters.values
        capacityWaiters.removeAll()
        for continuation in subscribers { continuation.resume() }
    }
}
