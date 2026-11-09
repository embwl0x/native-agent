import Foundation
import NativeAgentCore
import NativeAgentShared
import os
import AgentWorkspace
import Desk
import Transcripts
import TurnTrace
// Blueprint: | `ChatTurnSteering.swift` | Open turns and waiting arrivals; joined-message evidence prevents guessed approval attribution |

/// Offer readable input to the generating round and its next boundary; never cancel or rewind an executing action.
/// Persist before delivery, then let the next admitted provider round read it.
/// An offer no turn reads stays with its arrival, which runs as its own door's turn when admission reaches it.
public actor ChatTurnSteering {
    public static let shared = ChatTurnSteering()

    /// An arrival waiting in admission, offered to whichever turn of the agent's in the conversation reaches a step first.
    public struct Offer: Sendable {
        public let arrival: TurnArrival
        /// The door's own turn: its run names the row; its envelope, origin and taint say who sent it.
        public let turn: Turn
        /// What the reading turn appends to its conversation.
        public let reading: [LLMContentBlock]
        /// The arrival's place in admission's line: being read wakes it too.
        let waiter = ScopedWaiter()
        /// A stopped round already saved its row, so no turn writes it again.
        var saved = false
        /// Its admission already took it as read while a round carried it, so close drops it.
        var settled = false
    }

    /// Who answers a waiting arrival, decided once on this actor.
    enum Withdrawal { case taken(TurnAdmission.Steered), withdrawn }

    /// The offer an arrival makes while it waits.
    nonisolated static func offer(_ arrival: TurnArrival, turn: Turn, dataRoot: URL) -> Offer? {
        let input: SwiftNativeChatOrchestrationClient.TurnAttachmentInput
        // An arrival the agent's turn cannot read runs alone, where its own door reports why.
        do {
            input = try SwiftNativeChatOrchestrationClient.turnAttachmentInput(
                message: arrival.words, attachments: arrival.attachments, dataRoot: dataRoot, runId: turn.run)
        } catch { return nil }
        let text = arrival.row == .hidden ? input.userMessage : deliveryText(input.userMessage, turn: turn)
        return Offer(arrival: arrival, turn: turn, reading: [.text(text)] + input.imageBlocks)
    }

    private var pending: [String: [Offer]] = [:]
    private struct Pending: Sendable {
        let boundary: Bool
        let person: Bool
    }
    nonisolated private static let pendingSessions = OSAllocatedUnfairLock<[String: Pending]>(initialState: [:])
    nonisolated public static func hasPending(_ sessionId: String) -> Bool {
        pendingSessions.withLock { $0[sessionId]?.boundary == true }
    }
    /// Only the person's readable, untainted words withdraw a proposal that has not started.
    nonisolated public static func hasPersonWaiting(_ sessionId: String) -> Bool {
        pendingSessions.withLock { $0[sessionId]?.person == true }
    }
    /// Async callers read the owner without taking the dispatch snapshot's lock on their actor.
    public func personWaiting(in sessionId: String) -> Bool {
        guard let turn = open[sessionId] else { return false }
        return pending[sessionId]?.contains {
            turn.takes($0) && $0.turn.originPrincipal == "person" && $0.turn.peerSteering?.isTainted != true
        } == true
    }
    /// Only an offer the open turn can read asks a running ability to hand back at its next step; reserved arrivals await their answer.
    private func syncPendingFlag(_ sessionId: String) {
        let readable = open[sessionId].map { turn in pending[sessionId]?.filter(turn.takes) ?? [] } ?? []
        let person = personWaiting(in: sessionId)
        let boundary = !readable.isEmpty
        Self.pendingSessions.withLock {
            if boundary || person { $0[sessionId] = Pending(boundary: boundary, person: person) }
            else { $0.removeValue(forKey: sessionId) }
        }
    }
    private var reserved: [String: [Offer]] = [:]
    /// Replay owns these readings before their doors return to admission.
    private var replayed: [String: Set<String>] = [:]

    func restoreReadings(_ runs: Set<String>, sessionId: String) {
        guard !runs.isEmpty else { return }
        replayed[sessionId] = runs
        open[sessionId]?.hasJoinedMessage = true
        let waiting = pending[sessionId] ?? []
        reserved[sessionId, default: []] += waiting.filter { runs.contains($0.turn.run) }
        pending[sessionId] = waiting.filter { !runs.contains($0.turn.run) }
        syncPendingFlag(sessionId)
    }

    func markReplayedDelivered(_ runs: Set<String>, sessionId: String) -> Bool {
        guard let turn = open[sessionId] else { return false }
        for run in runs { answered[run] = turn.steered(sessionId) }
        for offer in reserved[sessionId] ?? [] where runs.contains(offer.turn.run) { offer.waiter.resume() }
        reserved[sessionId]?.removeAll { runs.contains($0.turn.run) }
        if reserved[sessionId]?.isEmpty == true { reserved[sessionId] = nil }
        syncPendingFlag(sessionId)
        return true
    }
    private struct Listener {
        let token: UUID
        let edge: AsyncStream<Offer>.Continuation
    }
    private var listeners: [String: [UUID: Listener]] = [:]

    /// Subscribe and inspect waiting offers in the same actor turn, closing the read/subscribe gap.
    func arrivals(sessionId: String) -> AsyncStream<Offer> {
        let (stream, edge) = AsyncStream<Offer>.makeStream()
        guard let turn = open[sessionId] else { edge.finish(); return stream }
        let id = UUID()
        listeners[sessionId, default: [:]][id] = Listener(token: turn.token, edge: edge)
        edge.onTermination = { _ in Task { await self.removeListener(sessionId: sessionId, id: id) } }
        for offer in pending[sessionId] ?? [] where turn.takes(offer) { edge.yield(offer) }
        return stream
    }

    private func removeListener(sessionId: String, id: UUID) {
        listeners[sessionId]?.removeValue(forKey: id)
        if listeners[sessionId]?.isEmpty == true { listeners[sessionId] = nil }
    }

    /// A withdrawn or already-read offer cannot cut a later round from a buffered signal.
    func canHear(_ offer: Offer, sessionId: String, run: String) -> Bool {
        guard let turn = open[sessionId], turn.run == run, turn.takes(offer) else { return false }
        return pending[sessionId]?.contains { $0.turn.run == offer.turn.run } == true
    }
    /// Arrivals a delivered round answered, until their admission collects the answer.
    private var answered: [String: TurnAdmission.Steered] = [:]
    func takeAnswer(sessionId: String, run: String) -> TurnAdmission.Steered? {
        guard answered[run]?.sessionID == sessionId else { return nil }
        return answered.removeValue(forKey: run)
    }
    public typealias Persister = @Sendable (String, Offer) async -> Bool

    struct OpenTurn {
        let token: UUID
        let turnId: String
        let run: String
        let dataRoot: URL
        let door: ChatToolSessionContext.ReplyRoute?
        /// This turn's persister cannot be replaced by another door.
        let persist: Persister?
        let helper: Bool
        /// Who started this turn and the peers already steering it.
        let principal: String
        let sources: Set<String>
        let fileAccess: ICloudChatFileAccessPolicy.Ceiling
        /// A joined arrival keeps its own row and door; the opener cannot stand for its authority.
        var hasJoinedMessage = false
        /// Arrivals whose row this turn could not save run alone, so they are not offered to its later rounds.
        var unsaved: Set<String> = []

        /// The arrival's answer is this turn's: its run, and the request its door correlates it with.
        func steered(_ sessionId: String) -> TurnAdmission.Steered {
            TurnAdmission.Steered(sessionID: sessionId, turnID: turnId, runID: run, requestID: door?.correlationId)
        }

        /// The person's and the agent's own untainted words join any turn of the agent's. Anything an agent or peer said joins only a turn that same sender
        /// started under the same steering, so it never rides past the floor its own turn would meet; refused, it runs alone under that floor.
        func takes(_ offer: Offer) -> Bool {
            guard persist != nil, !helper, !unsaved.contains(offer.turn.run) else { return false }
            let from = offer.turn, carried = Set(from.peerSteering?.checkpointSources ?? [])
            // Every arrival keeps its file ceiling, regardless of who sent it.
            guard fileAccess.holds(from.fileAccessCeiling) else { return false }
            if ["person", "self"].contains(from.originPrincipal), from.peerSteering?.isTainted != true { return true }
            return from.originPrincipal == principal && carried.isSubset(of: sources)
        }
    }

    /// Token-match close against the open window so detached cleanup cannot close a newer turn.
    private var open: [String: OpenTurn] = [:]
    private var lastTurnActivityAt: [String: Date] = [:]
    /// Free-time owners read the actual open windows; transcript events cannot mirror turns because some messages are consumed without a turn.
    nonisolated private static let openRoots = OSAllocatedUnfairLock<[String: OpenRoot]>(initialState: [:])
    nonisolated private static let idleListeners = OSAllocatedUnfairLock<[UUID: IdleListener]>(initialState: [:])
    private struct OpenRoot: Sendable { let root: String; let helper: Bool }
    private struct IdleListener: Sendable { let root: String; let edge: AsyncStream<Void>.Continuation }
    private init() {}

    nonisolated private static func rootKey(_ dataRoot: URL) -> String {
        dataRoot.standardizedFileURL.resolvingSymlinksInPath().path
    }

    /// Signal the last window closing, since completion events may arrive while the turn still appears busy.
    nonisolated public static func idleEdges(dataRoot: URL) -> AsyncStream<Void> {
        let (stream, edge) = AsyncStream<Void>.makeStream(bufferingPolicy: .bufferingNewest(1))
        let id = UUID()
        idleListeners.withLock { $0[id] = IdleListener(root: rootKey(dataRoot), edge: edge) }
        edge.onTermination = { _ in ChatTurnSteering.idleListeners.withLock { _ = $0.removeValue(forKey: id) } }
        return stream
    }

    /// Register every turn so inline-card resume sees the same open window.
    /// Only a successful durable write permits delivery; unresolved attempts retain identity for queue reconciliation.
    @discardableResult
    public func openTurn(
        sessionId: String, turnId: String, dataRoot: URL, door: ChatToolSessionContext.ReplyRoute? = nil,
        persist: Persister? = nil,
        turn: Turn
    ) throws -> UUID? {
        guard !sessionId.isEmpty else { return nil }
        let helper = try SessionConversation.checkedIsHelper(sessionId, dataRoot: dataRoot)
        let token = turn.admissionToken ?? UUID()
        var opened = OpenTurn(token: token, turnId: turnId, run: turn.run, dataRoot: dataRoot, door: door, persist: persist,
                                   helper: helper, principal: turn.originPrincipal, sources: Set(turn.peerSteering?.checkpointSources ?? []),
                                   fileAccess: turn.fileAccessCeiling)
        if let held = open[sessionId], held.turnId == turnId, held.run == turn.run, Self.rootKey(held.dataRoot) == Self.rootKey(dataRoot) {
            opened.hasJoinedMessage = held.hasJoinedMessage
        }
        open[sessionId] = opened
        Self.openRoots.withLock { $0[sessionId] = OpenRoot(root: Self.rootKey(dataRoot), helper: helper) }
        noteTurnActivity(for: dataRoot, at: Date())
        AgentOpened.shared.began(sessionId)
        syncPendingFlag(sessionId)
        return token
    }

    /// Close only this turn; offers its rounds read but never answered wait again, their rows saved.
    public func closeTurn(sessionId: String, token: UUID?) async {
        guard let token, let turn = open[sessionId], turn.token == token else { return }
        noteTurnActivity(for: turn.dataRoot, at: Date())
        open.removeValue(forKey: sessionId)
        replayed[sessionId] = nil
        if let held = listeners.removeValue(forKey: sessionId) { for listener in held.values { listener.edge.finish() } }
        Self.openRoots.withLock { _ = $0.removeValue(forKey: sessionId) }
        AgentOpened.shared.ended(sessionId, dataRoot: turn.dataRoot)
        if let unanswered = reserved.removeValue(forKey: sessionId)?.filter({ !$0.settled }), !unanswered.isEmpty {
            pending[sessionId] = unanswered + (pending[sessionId] ?? [])
        }
        syncPendingFlag(sessionId)
        guard !Self.hasOpenResidentTurn(dataRoot: turn.dataRoot) else { return }
        let root = Self.rootKey(turn.dataRoot)
        for listener in Self.idleListeners.withLock({ Array($0.values) }) where listener.root == root {
            listener.edge.yield()
        }
    }

    /// Card resume must check the open window so it cannot start a second narrator on the same transcript.
    public func isTurnOpen(sessionId: String) -> Bool {
        open[sessionId] != nil
    }

    /// A card can hand back only to the exact act that raised it.
    public func isTurnOpen(sessionId: String, turnID: String) -> Bool {
        open[sessionId]?.turnId == turnID
    }

    /// The run identifies the opener only while this exact open turn has read no other arrival.
    public func canAttributeApprovalToOpeningMessage(sessionId: String, turn: Turn, dataRoot: URL) -> Bool {
        guard let held = open[sessionId], held.turnId == turn.id, held.run == turn.run,
              Self.rootKey(held.dataRoot) == Self.rootKey(dataRoot) else { return false }
        return !held.hasJoinedMessage
    }

    /// Whether a turn of the agent's is open in this root; helper-owned loops are independent (classified when the turn opens).
    /// `besides`: the session asking — a run started from a turn is not held by that same turn.
    nonisolated public static func hasOpenResidentTurn(dataRoot: URL, besides session: String? = nil) -> Bool {
        let root = rootKey(dataRoot)
        return openRoots.withLock { $0.contains { $0.key != session && $0.value.root == root && !$0.value.helper } }
    }

    /// The agent's live lines: every conversation of the agent's with an open turn in this root, helpers excluded.
    nonisolated public static func liveSessions(dataRoot: URL) -> [String] {
        let root = rootKey(dataRoot)
        return openRoots.withLock { $0.filter { $0.value.root == root && !$0.value.helper }.map(\.key).sorted() }
    }

    public func noteTurnActivity(for dataRoot: URL, at: Date) {
        let key = dataRoot.standardizedFileURL.path
        lastTurnActivityAt[key] = max(lastTurnActivityAt[key] ?? at, at)
    }

    public func turnActivityOrSeed(for dataRoot: URL, at: Date) -> Date {
        let key = dataRoot.standardizedFileURL.path
        if let known = lastTurnActivityAt[key] { return known }
        lastTurnActivityAt[key] = at
        return at
    }

    /// Admission posts an arrival that waits; a turn of the agent's in its conversation may read it at its next step.
    func post(_ offer: Offer, sessionId: String) {
        if answered[offer.turn.run] != nil { offer.waiter.resume(); return }
        if replayed[sessionId]?.contains(offer.turn.run) == true {
            reserved[sessionId, default: []].append(offer)
            return
        }
        pending[sessionId, default: []].append(offer)
        syncPendingFlag(sessionId)
        if let turn = open[sessionId], turn.takes(offer), let held = listeners[sessionId] {
            for listener in held.values where listener.token == turn.token { listener.edge.yield(offer) }
        }
    }

    /// The arrival woke (read, its own place, or its own cancellation): taken once a round answered it or carries it now, else withdrawn
    /// for good. Drains run on this same actor, so neither can slip between the other.
    func withdraw(sessionId: String, run: String) -> Withdrawal {
        if let steered = takeAnswer(sessionId: sessionId, run: run) { return .taken(steered) }
        if let turn = open[sessionId], let index = reserved[sessionId]?.firstIndex(where: { $0.turn.run == run }) {
            reserved[sessionId]?[index].settled = true
            if let offer = reserved[sessionId]?[index] { Self.retireCheckpoint(of: offer, sessionId: sessionId, dataRoot: turn.dataRoot) }
            return .taken(turn.steered(sessionId))
        }
        pending[sessionId]?.removeAll { $0.turn.run == run }
        if pending[sessionId]?.isEmpty == true { pending[sessionId] = nil }
        syncPendingFlag(sessionId)
        return .withdrawn
    }

    /// Reserve what this turn can read and save each row before delivery; Stop or failure leaves them waiting with their saved rows.
    public func drain(sessionId: String, cancelFlagPath: URL? = nil) async throws -> [Offer] {
        guard !Task.isCancelled, !ChatCancelFlag.isRaised(cancelFlagPath),
              let turn = open[sessionId], let persist = turn.persist,
              let waiting = pending[sessionId] else {
            return []
        }
        let taken = waiting.filter(turn.takes)
        guard !taken.isEmpty else { return [] }
        let requiresPersistence = personWaiting(in: sessionId)
        let runs = Set(taken.map(\.turn.run))
        pending[sessionId] = waiting.filter { !runs.contains($0.turn.run) }
        // Reserve before saving so a withdrawal and the write cannot race.
        reserved[sessionId, default: []] += taken
        syncPendingFlag(sessionId)
        for offer in taken where !offer.saved {
            if Task.isCancelled || ChatCancelFlag.isRaised(cancelFlagPath) { return [] }
            let committed = await persist(sessionId, offer)
            guard open[sessionId]?.token == turn.token else { return [] }
            guard committed else {
                // Keep their order, including rows saved before this failure.
                open[sessionId]?.unsaved.insert(offer.turn.run)
                let failed = reserved[sessionId]?.filter { runs.contains($0.turn.run) } ?? []
                reserved[sessionId]?.removeAll { runs.contains($0.turn.run) }
                if reserved[sessionId]?.isEmpty == true { reserved[sessionId] = nil }
                pending[sessionId] = failed + (pending[sessionId] ?? [])
                syncPendingFlag(sessionId)
                if requiresPersistence {
                    throw ChatOrchestrationError.underlying("Arrival \(offer.turn.run) could not be saved for this turn; "
                        + "its door retains it. Proposed calls did not start. Inspect the arrival persistence failure before continuing.")
                }
                return []
            }
            if let index = reserved[sessionId]?.firstIndex(where: { $0.turn.run == offer.turn.run }) { reserved[sessionId]?[index].saved = true }
        }
        guard !Task.isCancelled, !ChatCancelFlag.isRaised(cancelFlagPath),
              let heldOffers = reserved[sessionId], !heldOffers.isEmpty,
              var held = open[sessionId], held.token == turn.token else { return [] }
        if !held.hasJoinedMessage {
            held.hasJoinedMessage = true
            open[sessionId] = held
        }
        return heldOffers.filter { runs.contains($0.turn.run) }
    }

    /// Delivered means a provider round carrying the offers produced output: this turn answers each arrival.
    public func markDelivered(_ offers: [Offer], sessionId: String) -> Bool {
        guard let turn = open[sessionId] else { return false }
        for offer in offers {
            guard let index = reserved[sessionId]?.firstIndex(where: { $0.turn.run == offer.turn.run }) else { continue }
            // An arrival whose admission already took it holds no answer slot.
            if reserved[sessionId]?.remove(at: index).settled == false {
                answered[offer.turn.run] = turn.steered(sessionId)
                Self.retireCheckpoint(of: offer, sessionId: sessionId, dataRoot: turn.dataRoot)
            }
            offer.waiter.resume()
        }
        if reserved[sessionId]?.isEmpty == true { reserved[sessionId] = nil }
        syncPendingFlag(sessionId)
        return true
    }

    /// A read arrival's own saved checkpoint no longer stands for an unanswered message; one left behind would resume it at relaunch.
    nonisolated private static func retireCheckpoint(of offer: Offer, sessionId: String, dataRoot: URL) {
        do { try TurnCheckpoint.read(dataRoot: dataRoot, sessionId: sessionId, turnId: offer.turn.id)?.remove(dataRoot: dataRoot) }
        catch { nativeLog("[steering] arrival %@ checkpoint not retired: %@", offer.turn.id, error.localizedDescription) }
    }

    /// Shown words say who sent them and through which door, since any door's arrival joins the agent's turn.
    nonisolated static func deliveryText(_ text: String, turn: Turn) -> String {
        let who = turn.origin?.authored == .agent ? turn.origin?.agent ?? "An agent" : "The person"
        let door = turn.arrivalSurface(authorizing: turn.envelope?.surface ?? "chat")
        return "[\(who) sent this just now from \(door), while you were working:]\n" + text
    }
}
