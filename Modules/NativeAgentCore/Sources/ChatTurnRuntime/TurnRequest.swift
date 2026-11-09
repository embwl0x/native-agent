import Foundation
import NativeAgentShared
import Transcripts
import CognitiveSubstrate
import Experiences
import NativeAgentCore
import TrustCenter
import TurnTrace
import PersistenceCore
import ProviderRouting
// Blueprint: | `TurnRequest.swift` | `TurnRequest` made a `Turn`; `TurnArrival`; `TurnAdmission`: per-session order, offering waiters to the agent's open turn |

/// What one ingress decides about a turn; `turn(parent:)` makes it the `Turn`. Omitted fields inherit the
/// parent turn's, an explicitly supplied nil clears them: double optionals keep that distinction.
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

    public var envelope: TurnEnvelope??
    public var verifiedSessionID: String??
    public var verifiedChatID: String??
    public var verifiedUserID: String??
    /// The envelope's delivery route: the turn's trace names the same destination and thread. Outer nil inherits; inner nil clears.
    public var replyRoute: ChatToolSessionContext.ReplyRoute??
    public var origin: ChatMessageOrigin??
    /// Use the enqueued row's run identity so it is not appended twice.
    public var pinnedRunID: String??
    public var codexCompletion: CodexCompletionTranscriptBinding??
    /// The exact assistant row a regenerate replaces.
    public var replacementAssistantMessageID: String??
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

    /// Enqueued input adopts its resolved session and run identity without a second user append.
    public func consuming(_ enqueued: EnqueuedUserMessage) -> TurnRequest {
        var turn = self
        turn.sessionID = enqueued.sessionId
        turn.pinnedRunID = enqueued.runId
        turn.suppressUserAppend = true
        return turn
    }

    /// The turn this request starts: every ingress fact is a part of it. An
    /// omitted field keeps `parent`'s value, as a nested turn inherits; a
    /// supplied nil clears it. Peer-started input carries steering from its
    /// first line; elevated peers keep only the ordinary floor gates.
    public func turn(id: String = Turn.mintID(), parent: Turn? = nil) -> Turn {
        let run = (pinnedRunID ?? nil) ?? parent?.run ?? UUID().uuidString
        var turn = parent?.derived(id: id, run: run) ?? Turn(id: id, run: run)
        // The request's own session, nil included: nil means resolve one, never the parent's.
        turn.session = sessionID
        // One envelope from the explicit ingress fields; nested work keeps the enclosing one unless replaced or cleared.
        if let envelope { turn.envelope = envelope }
        else if turn.envelope == nil {
            turn.envelope = TurnEnvelope(surface: surface, verifiedChatId: verifiedChatID ?? nil,
                verifiedUserId: verifiedUserID ?? nil, deliveryRoute: replyRoute ?? nil)
        }
        if verifiedChatID != nil || verifiedUserID != nil, let envelope = turn.envelope {
            turn.envelope = TurnEnvelope(surface: envelope.surface, agent: envelope.agent,
                verifiedChatId: verifiedChatID ?? envelope.verifiedChatId,
                verifiedUserId: verifiedUserID ?? envelope.verifiedUserId,
                commandSignatureVerified: envelope.commandSignatureVerified, deliveryRoute: envelope.deliveryRoute,
                declaredRemote: envelope.declaredRemote, macContinuation: envelope.macContinuation,
                workIdentity: envelope.workIdentity, answerExperienceID: envelope.answerExperienceID)
        }
        if let replyRoute { turn.envelope = turn.envelope.map { $0.withDeliveryRoute(replyRoute) } }
        if let verifiedSessionID { turn.verifiedSessionID = verifiedSessionID }
        if let origin { turn.origin = origin }
        turn.rows.threadKind = threadKind
        turn.rows.ownedSessionID = ownedSessionID
        if let codexCompletion { turn.rows.codexCompletion = codexCompletion }
        if let replacementAssistantMessageID { turn.rows.replacementAssistantMessageID = replacementAssistantMessageID }
        if let queryUserMessage { turn.queryUserMessage = queryUserMessage }
        turn.careWakes = careWakes ?? []
        turn.userText = message
        turn.fileAccess = fileAccess
        if let serviceTier { turn.requestedServiceTier = serviceTier }
        turn.peerSteering = steering(over: turn.peerSteering)
        return turn
    }

    /// Recorded steering, including an empty record, is authoritative; an agent's own words steer as that agent.
    private func steering(over inherited: PeerDataTaint?) -> PeerDataTaint? {
        if case .some(.some(let origin)) = origin, let sources = origin.peerSources {
            let taint = inherited ?? PeerDataTaint()
            // The initiating agent's actual input is the card quote.
            taint.keep(line: message)
            for source in sources { taint.mark(peer: source) }
            for source in origin.elevatedPeerSources ?? [] { taint.elevate(peer: source) }
            return taint
        }
        guard case .some(.some(let origin)) = origin, origin.authored == .agent,
              let agent = origin.agent, agent != "self", !agent.hasPrefix("bot:") else { return inherited }
        let taint = inherited ?? PeerDataTaint()
        if agent != "agent" {
            taint.mark(peer: (envelope ?? nil)?.verifiedUserId.map { "peer:" + $0 } ?? agent, line: message)
        } else if PeerTurnEffectPolicy.isPeerBridge(surface: surface) {
            taint.keep(line: message)
        } else {
            taint.mark(peer: (envelope ?? nil)?.verifiedUserId.map { "peer:" + $0 } ?? "a peer", line: message)
        }
        return taint
    }

    /// Durably append the user row as this request's turn. The row's run is the
    /// request's own pin, never an enclosing turn's.
    public func enqueue(
        on client: SwiftNativeChatOrchestrationClient,
        parent: Turn? = nil,
        mechanicalRow: CognitiveMechanicalRowKind? = nil,
        awaitingConsumption: Bool = true
    ) async throws -> EnqueuedUserMessage {
        var turn = turn(parent: parent)
        turn.run = (pinnedRunID ?? nil) ?? UUID().uuidString
        return try await client.enqueueUserMessage(
            message: message,
            sessionId: sessionID,
            persona: persona,
            surface: surface,
            attachments: attachments,
            mechanicalRow: mechanicalRow,
            awaitingConsumption: awaitingConsumption,
            turn: turn
        )
    }

    /// Run the request as its turn.
    public func chat(
        on client: SwiftNativeChatOrchestrationClient,
        parent: Turn? = nil,
        progress: TurnEventSink? = nil
    ) async throws -> ChatResponse {
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
            progress: progress,
            turn: turn(parent: parent),
            serviceTier: serviceTier ?? nil
        )
    }
}

/// What a door brings into the agent's conversation; admission offers it to the agent's open turn there.
public struct TurnArrival: Sendable {
    public enum Row: Sendable, Equatable {
        /// The turn writes the sender's row.
        case shown
        /// The agent's own continuation writes no row, as a hidden bubble writes none.
        case hidden
        /// The door saved the row before admission; the turn that takes it consumes that row.
        case saved
    }
    public let words: String
    public let attachments: [MultimodalAttachment]
    /// The door's chat surface: the row's source, as its own turn would write it.
    public let surface: String
    public let row: Row

    public init(words: String, attachments: [MultimodalAttachment] = [], surface: String, row: Row) {
        self.words = words
        self.attachments = attachments
        self.surface = surface
        self.row = row
    }
}

extension TurnRequest {
    /// This request as it arrives in the agent's conversation.
    public func arrival(_ row: TurnArrival.Row) -> TurnArrival {
        TurnArrival(words: message, attachments: attachments, surface: surface, row: row)
    }
}

/// Serialize turns per session so replies cannot interleave; durable enqueue and completion deduplication retain their own owners.
public actor TurnAdmission {
    public static let shared = TurnAdmission()

    /// The agent's turn that read an arrival at one of its steps: its run, and the request its door answers.
    public struct Steered: Sendable, Equatable {
        public let sessionID: String
        public let turnID: String
        public let runID: String
        public let requestID: String?
    }

    /// How admission settled an arrival: it ran as its own turn, or the agent's open turn took it.
    public enum Admitted<Value> {
        case ran(Value)
        /// The reading turn's reply answers it, so the door that sent it delivers nothing.
        case steered(Steered)
    }

    public init() {}

    private struct Waiter {
        let id: UUID
        let runID: String?
        let done: ScopedWaiter
    }
    private var active: [String: UUID] = [:]
    private var waiting: [String: [Waiter]] = [:]
    private var capacityWaiters: [UUID: ScopedWaiter] = [:]
    /// Admit restored runs in their recorded order before any newer session work.
    private var backlog: [String: [String]] = [:]
    /// Hold new named-session turns until launch recovery inventories accepted backlog, so new work cannot pass earlier input.
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
                // Close admission synchronously after checking idle so no turn can enter between them.
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

    /// New chats need only root admission; durable arrivals wait for capacity while unsaved full-queue requests refuse.
    /// Restored run identity preserves its ordered backlog position. An arrival that waits is offered to the agent's open turn
    /// in the conversation: read at a step, it is steered; otherwise its own place comes and it runs as its door's turn.
    public func run<T>(dataRoot: URL, sessionID: String?, arrival: TurnArrival, runID: String? = nil, waitForCapacity: Bool = false,
                       isolation: isolated (any Actor)? = #isolation,
                       turn: Turn, operation: (Turn) async throws -> T) async throws -> Admitted<T> {
        // An arrival in any conversation but the agent's own stream is something owed: attention wakes for it.
        if sessionID != Attention.stream { Attention.arrived() }
        var turn = turn
        turn.providerRecovery = ProviderRecovery()
        if arrival.row == .hidden {
            turn.rows.hiddenInput = TurnCheckpoint.HiddenInput(
                origin: try turn.origin.map { try JSONValue.fromEncodable($0) }, attachments: arrival.attachments,
                completion: try turn.rows.codexCompletion.map { try JSONValue.fromEncodable($0) },
                queryUserMessage: turn.queryUserMessage, threadKind: turn.rows.threadKind, ownedSessionID: turn.rows.ownedSessionID,
                questionRunID: turn.rows.questionRunID, verifiedSessionID: turn.verifiedSessionID)
        } else { turn.rows.hiddenInput = nil }
        let id = UUID()
        if let steered = try await admit(dataRoot: dataRoot, sessionID: sessionID, id: id, runID: runID, waitForCapacity: waitForCapacity,
                                         arrival: arrival, turn: turn) {
            return .steered(steered)
        }
        return .ran(try await execute(dataRoot: dataRoot, sessionID: sessionID, id: id, turn: turn, operation: operation))
    }

    /// Work that never joins another turn (a regenerate, a restored run, the agent's wake, a helper's loop) waits only for its own place.
    public func runAlone<T>(dataRoot: URL, sessionID: String?, runID: String? = nil, waitForCapacity: Bool = false,
                            isolation: isolated (any Actor)? = #isolation,
                            turn: Turn, operation: (Turn) async throws -> T) async throws -> T {
        let id = UUID()
        _ = try await admit(dataRoot: dataRoot, sessionID: sessionID, id: id, runID: runID, waitForCapacity: waitForCapacity,
                            arrival: nil, turn: turn)
        return try await execute(dataRoot: dataRoot, sessionID: sessionID, id: id, turn: turn, operation: operation)
    }

    private func admit(dataRoot: URL, sessionID: String?, id: UUID, runID: String?, waitForCapacity: Bool,
                       arrival: TurnArrival?, turn: Turn) async throws -> Steered? {
        guard let sessionID else { return nil }
        do {
            return try await acquire(sessionID, id: id, runID: runID, waitForCapacity: waitForCapacity,
                                     arrival: arrival, turn: turn, dataRoot: dataRoot)
        } catch {
            // A restored run that will not be admitted gives up its place.
            if let runID { withdraw(sessionID: sessionID, runID: runID) }
            throw error
        }
    }

    private func execute<T>(dataRoot: URL, sessionID: String?, id: UUID, isolation: isolated (any Actor)? = #isolation,
                            turn: Turn, operation: (Turn) async throws -> T) async throws -> T {
        do {
            try await enterRoot(rootKey(dataRoot), id: id)
            try Task.checkCancellation()
            // A new session is resolved inside the operation; its own runner
            // closes steering. Only a named session delegates that close here.
            let result: T
            if sessionID != nil { result = try await operation(turn.with(\.admissionToken, id)) }
            else { result = try await operation(turn) }
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

    /// Restore queued and interrupted runs oldest first before admitting new work.
    public func restore(sessionID: String, runs: [String]) {
        sessionRestorationFailures[sessionID] = nil
        let known = backlog[sessionID] ?? []
        let added = known + runs.filter { !known.contains($0) }
        backlog[sessionID] = added.isEmpty ? nil : added
    }

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

    /// Release restored backlog slots for runs known to have ended or not resumed.
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

    private func acquire(_ key: String, id: UUID, runID: String?, waitForCapacity: Bool,
                         arrival: TurnArrival?, turn: Turn, dataRoot: URL) async throws -> Steered? {
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
        // A restored run keeps its recorded place; only a live arrival rides the agent's open turn.
        let rides = runID.map { backlog[key]?.contains($0) != true } ?? true
        while true {
            if arrival != nil, let runID, let steered = await ChatTurnSteering.shared.takeAnswer(sessionId: key, run: runID) {
                admitted(key, runID: runID)
                admitNext(key)
                return steered
            }
            if active[key] == nil, admissible(key, runID: runID) { break }
            let hasCapacity = (waiting[key]?.count ?? 0) < 8 && waiting.values.reduce(0, { $0 + $1.count }) < 32
            guard hasCapacity || waitForCapacity else { throw Full() }
            // Registration and the capacity check share this actor. A release
            // cannot slip between them; cancellation also wakes the subscriber.
            // Its offer is made once, only when it takes a place in line (files are read here, not for every turn).
            let riding = hasCapacity && rides ? arrival.flatMap { ChatTurnSteering.offer($0, turn: turn, dataRoot: dataRoot) } : nil
            let done = riding?.waiter ?? ScopedWaiter()
            if hasCapacity { waiting[key, default: []].append(Waiter(id: id, runID: runID, done: done)) }
            else { capacityWaiters[id] = done }
            // In line, the arrival is also offered to the agent's turn here: being read or its own place, whichever comes first.
            if let riding { await ChatTurnSteering.shared.post(riding, sessionId: key) }
            await done.park()
            if hasCapacity {
                // The steering actor alone decides read versus its own place; a slot handed to a read arrival passes on.
                if let riding, case .taken(let steered) = await ChatTurnSteering.shared.withdraw(sessionId: key, run: riding.turn.run) {
                    if active[key] == id { release(key, id: id) } else { leaveLine(key, id: id) }
                    return steered
                }
                // Restored doors do not offer their input again; the replayed turn's delivered reading still answers them.
                if arrival != nil, let runID, let steered = await ChatTurnSteering.shared.takeAnswer(sessionId: key, run: runID) {
                    admitted(key, runID: runID)
                    if active[key] == id { release(key, id: id) } else { leaveLine(key, id: id) }
                    admitNext(key)
                    return steered
                }
                // A handoff owns the slot even if Stop raced it; run's
                // cancellation check then releases that admitted slot.
                if active[key] == id { return nil }
                leaveLine(key, id: id)
                throw CancellationError()
            }
            capacityWaiters.removeValue(forKey: id)
            try Task.checkCancellation()
        }
        active[key] = id
        admitted(key, runID: runID)
        return nil
    }

    private func leaveLine(_ key: String, id: UUID) {
        guard let index = waiting[key]?.firstIndex(where: { $0.id == id }) else { return }
        waiting[key]?.remove(at: index)
        if waiting[key]?.isEmpty == true { waiting[key] = nil }
        signalCapacity()
    }

    private func release(_ key: String, id: UUID) {
        guard active[key] == id else { return }
        defer { signalCapacity() }
        active.removeValue(forKey: key)
        admitNext(key)
    }

    /// Wait for a restored head to arrive before admitting later work; otherwise choose the oldest idle-session waiter.
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

extension TurnAdmission.Admitted: Sendable where Value: Sendable {}
