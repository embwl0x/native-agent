import Foundation
import os
import AgentWorkspace
import Desk
import Transcripts
import TurnTrace
// Blueprint: | `ChatTurnSteering.swift` | `ChatTurnSteering` actor; open turns and turn-activity clock; atomic resident claim/reservation under the common free-time law; person admission opens immediately |

/// Messages sent during work are offered to the running turn in that conversation on the same door.
/// Each stays queued until taken or run as its own turn; Steer manually offers a queued message again.
///
/// An offer made here is picked up by the running loop at its next tool boundary, BEFORE the
/// model chooses another action, and delivered as ordinary text in that round's
/// tool_result turn. The model reads it and decides whether it corrects or
/// extends the task: no steering toggle, no keyword classifier, nothing added
/// to any prompt when there is no offer.
///
/// SAFE BOUNDARY ONLY. Nothing here cancels or rewinds an executing action —
/// its receipt and outcome land exactly as they would have.
///
/// LOSSLESS. An offer that is never picked up (the turn finished first) is
/// returned by `close` to its owner, which leaves it queued to run as an
/// ordinary turn. Every offer therefore either steers the live turn or runs as
/// its own turn — never both, never neither.
public actor ChatTurnSteering {
    public static let shared = ChatTurnSteering()

    public struct Offer: Sendable, Equatable {
        /// The queued-turn id the offer came from, so its owner can drop the
        /// queue entry once the running turn has taken it.
        public let id: String
        public let text: String
        public let envelope: TurnEnvelope
        public let origin: ChatMessageOrigin?
        /// Attempt identity, retained even when commitment is still unresolved.
        /// The queue reconciles it before deciding whether to append on replay.
        public internal(set) var enqueuedRunID: String?
        public internal(set) var receivingTurnID: String?

        /// `runID`: the run its queued turn would write it under, so either one writes it once.
        public init(id: String, text: String, envelope: TurnEnvelope, origin: ChatMessageOrigin?, runID: String? = nil) {
            self.id = id
            self.text = text
            self.envelope = envelope
            self.origin = origin
            self.enqueuedRunID = runID
        }
    }

    /// Bounded so a person holding Return cannot grow an unbounded array behind
    /// a long turn; past this, sends simply stay queued as they always were.
    static let maxPending = 8

    private var pending: [String: [Offer]] = [:]
    /// Sessions with pending, drainable offers; streaming replies check without an actor hop.
    nonisolated private static let pendingSessions = OSAllocatedUnfairLock<Set<String>>(initialState: [])
    nonisolated public static func hasPending(_ sessionId: String) -> Bool {
        pendingSessions.withLock { $0.contains(sessionId) }
    }
    /// Unsettled reservations suppress the flag because drain cannot yet consume the offer.
    private func syncPendingFlag(_ sessionId: String) {
        let waiting = reserved[sessionId] == nil && pending[sessionId]?.isEmpty == false
        Self.pendingSessions.withLock { if waiting { $0.insert(sessionId) } else { $0.remove(sessionId) } }
    }
    private var reserved: [String: [Offer]] = [:]
    private var delivered: [String: [Offer]] = [:]
    private var stranded: [String: [Offer]] = [:]
    /// Queue owner: reserve the attempt (false), then retire it at settlement (true).
    private var deliveryHandlers: [String: @MainActor @Sendable (Offer, Bool) async -> Bool] = [:]
    private var returnHandlers: [UUID: [String: @MainActor @Sendable (Offer) async -> Void]] = [:]
    public typealias Persister = @Sendable (String, Offer) async -> Bool

    struct OpenTurn {
        let token: UUID
        let turnId: String
        let dataRoot: URL
        /// Where its reply goes; nil for the Mac's own conversation.
        let door: ChatToolSessionContext.ReplyRoute?
        /// This turn's persister cannot be replaced by another door.
        let persist: Persister?
    }

    /// sessionId → the turn whose window is open. A token, not a flag: the
    /// close runs in a detached task, and without it a just-finished turn's
    /// close could shut the window of the NEXT turn that already opened.
    private var open: [String: OpenTurn] = [:]
    private var lastTurnActivityAt: [String: Date] = [:]
    private init() {}

    /// Every turn registers its session so inline-card resume can check isTurnOpen before starting another.
    ///
    /// `persist` is how THIS turn writes a delivered message to the transcript.
    /// True proves the row is on disk; false leaves the attempt unresolved and
    /// must not deliver it — the queue reconciles its identity before replay.
    @discardableResult
    public func openTurn(
        sessionId: String, turnId: String, dataRoot: URL, door: ChatToolSessionContext.ReplyRoute? = nil,
        persist: Persister? = nil
    ) -> UUID? {
        guard !sessionId.isEmpty else { return nil }
        let token = TurnAdmission.token ?? UUID()
        open[sessionId] = OpenTurn(token: token, turnId: turnId, dataRoot: dataRoot, door: door, persist: persist)
        noteTurnActivity(for: dataRoot, at: Date())
        HerOpened.shared.began(sessionId)
        return token
    }

    /// Close only this turn, returning unused offers before admission passes on.
    public func closeTurn(sessionId: String, token: UUID?) async {
        guard let token, let turn = open[sessionId], turn.token == token else { return }
        noteTurnActivity(for: turn.dataRoot, at: Date())
        open.removeValue(forKey: sessionId)
        ResidentWake.shared.turnEnded(dataRoot: turn.dataRoot)
        HerOpened.shared.ended(sessionId, dataRoot: turn.dataRoot)
        for offer in delivered.removeValue(forKey: sessionId) ?? [] {
            if let handler = deliveryHandlers.removeValue(forKey: offer.id) { _ = await handler(offer, true) }
        }
        let handlers = returnHandlers.removeValue(forKey: token) ?? [:]
        let offers = (stranded.removeValue(forKey: sessionId) ?? [])
            + (reserved.removeValue(forKey: sessionId) ?? [])
            + (pending.removeValue(forKey: sessionId) ?? [])
        syncPendingFlag(sessionId)
        for offer in offers.reversed() {
            deliveryHandlers[offer.id] = nil
            if let handler = handlers[offer.id] { await handler(offer) }
        }
    }

    /// The person removed this message from the queue before the turn took it.
    public func withdraw(id: String) {
        for key in pending.keys { pending[key]?.removeAll { $0.id == id }; syncPendingFlag(key) }
        for key in stranded.keys { stranded[key]?.removeAll { $0.id == id } }
        deliveryHandlers[id] = nil
        for token in returnHandlers.keys { returnHandlers[token]?[id] = nil }
    }

    /// Whether a turn is narrating this session RIGHT NOW.
    ///
    /// Asked by the inline-card resume before it starts anything: a settled
    /// card whose continuation starts a second turn puts two turns on one
    /// transcript at once, which is how a decline answered mid-turn narrated
    /// over the turn that raised it.
    public func isTurnOpen(sessionId: String) -> Bool {
        open[sessionId] != nil
    }

    /// Her resident wake waits for an open resident turn; helper-owned
    /// loops are independent. Read the same session rows as every other door.
    public func hasOpenResidentTurn(dataRoot: URL) -> Bool {
        let root = dataRoot.standardizedFileURL.resolvingSymlinksInPath()
        let sessions = try? SessionConversation(dataRoot: dataRoot)
        return open.contains { session, turn in
            turn.dataRoot.standardizedFileURL.resolvingSymlinksInPath() == root
                && sessions?.isHelper(session) != true
        }
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

    package func residentWakeIsFree(dataRoot: URL, nextFreeAt: @Sendable (Date, Date) -> Date?) -> Bool {
        if hasOpenResidentTurn(dataRoot: dataRoot) {
            ResidentWake.shared.wait(dataRoot: dataRoot, until: nil)
            return false
        }
        let now = Date()
        if let due = nextFreeAt(now, turnActivityOrSeed(for: dataRoot, at: now)) {
            ResidentWake.shared.wait(dataRoot: dataRoot, until: due)
            return false
        }
        return true
    }

    /// Desk revision, freedom, ledger claim and turn reservation share this critical section.
    package func claimResidentWake(dataRoot: URL, items: [ResidentWake.Item], deskRevision: UInt64,
                                   nextFreeAt: @Sendable (Date, Date) -> Date?)
        -> (text: String, items: [ResidentWake.Item])? {
        guard let token = TurnAdmission.token,
              deskRevision == SwiftNativeDeskStore.currentRevision,
              residentWakeIsFree(dataRoot: dataRoot, nextFreeAt: nextFreeAt),
              let wake = ResidentWake.shared.claim(dataRoot: dataRoot, prepared: items) else { return nil }
        open[ResidentWake.session] = OpenTurn(token: token, turnId: TurnTraceContext.turnId ?? token.uuidString,
                                            dataRoot: dataRoot, door: nil, persist: nil)
        noteTurnActivity(for: dataRoot, at: Date())
        return wake
    }

    /// Offer a message to the session's running turn. `false` means it was not
    /// taken (no open turn, or the pending bound is reached) and the caller
    /// keeps it queued.
    public func offer(_ offer: Offer, sessionId: String,
                      onDelivered: (@MainActor @Sendable (Offer, Bool) async -> Bool)? = nil,
                      onReturned: (@MainActor @Sendable (Offer) async -> Void)? = nil) -> Bool {
        let door = offer.envelope.deliveryRoute
        guard let turn = open[sessionId], turn.door?.surface == door?.surface,
              turn.door?.destinationId == door?.destinationId, turn.door?.threadId == door?.threadId else { return false }
        var queue = pending[sessionId] ?? []
        guard queue.count < Self.maxPending, !queue.contains(where: { $0.id == offer.id }) else { return false }
        queue.append(offer)
        pending[sessionId] = queue
        syncPendingFlag(sessionId)
        deliveryHandlers[offer.id] = onDelivered
        returnHandlers[turn.token, default: [:]][offer.id] = onReturned
        return true
    }

    /// Called only after the next provider round is admitted. Offers stay
    /// reserved until a provider round reads them (`markDelivered`), so a Stop
    /// or a failed turn returns even committed rows to the ordinary queue with
    /// their enqueue identity intact.
    public func drain(sessionId: String, cancelFlagPath: URL? = nil) async -> [Offer] {
        guard !Task.isCancelled, !ChatCancelFlag.isRaised(cancelFlagPath),
              reserved[sessionId] == nil,
              let turn = open[sessionId],
              let queue = pending.removeValue(forKey: sessionId), !queue.isEmpty else {
            return []
        }
        syncPendingFlag(sessionId)
        // The person really did send this message, so the transcript records it
        // as their message, in the order they sent it — before the reply the
        // running turn is still composing. PERSIST FIRST: a message the model
        // answers but the transcript never got is gone from the queue AND
        // absent after reload, so a failed write un-delivers the offer — it is
        // stranded instead, and its owner re-queues it as an ordinary turn.
        guard let persist = turn.persist else {
            stranded[sessionId, default: []].append(contentsOf: queue)
            return []
        }
        // Each gets its attempt identity now, then leaves the visible queue
        // before the save: from here only this turn or cleanup owns it, so a
        // remove or Send next can't race the write.
        reserved[sessionId] = queue.map {
            var offer = $0
            offer.enqueuedRunID = offer.enqueuedRunID ?? UUID().uuidString
            return offer
        }
        var gone: Set<String> = []
        for offer in reserved[sessionId] ?? [] {
            // No claim left (removed while reserving): the queue let it go, so the turn does too.
            guard let handler = deliveryHandlers[offer.id] else { gone.insert(offer.id); continue }
            if await handler(offer, false) == false {
                gone.insert(offer.id)
                deliveryHandlers[offer.id] = nil
            }
        }
        reserved[sessionId]?.removeAll { gone.contains($0.id) }
        let taken = reserved[sessionId] ?? []
        guard !taken.isEmpty else {
            if reserved[sessionId]?.isEmpty == true { reserved[sessionId] = nil }
            syncPendingFlag(sessionId)
            return []
        }
        for index in taken.indices {
            if Task.isCancelled || ChatCancelFlag.isRaised(cancelFlagPath) { return [] }
            guard let savedOffer = reserved[sessionId]?[index], savedOffer.enqueuedRunID != nil else { return [] }
            let committed = await persist(sessionId, savedOffer)
            guard open[sessionId]?.token == turn.token else { return [] }
            guard committed else {
                // Keep their order, including rows saved before this failure.
                stranded[sessionId, default: []].append(
                    contentsOf: reserved.removeValue(forKey: sessionId) ?? [])
                syncPendingFlag(sessionId)
                return []
            }
        }
        guard !Task.isCancelled, !ChatCancelFlag.isRaised(cancelFlagPath) else { return [] }
        return reserved[sessionId] ?? []
    }

    /// Delivered means a provider round carrying the offers produced output.
    /// Only then does the turn's close retire them from the queue.
    public func markDelivered(_ offers: [Offer], sessionId: String) async -> Bool {
        guard let turn = open[sessionId] else { return false }
        for var offer in offers {
            offer.receivingTurnID = turn.turnId
            guard let handler = deliveryHandlers[offer.id], await handler(offer, false),
                  open[sessionId]?.token == turn.token,
                  let index = reserved[sessionId]?.firstIndex(where: { $0.id == offer.id }) else { return false }
            reserved[sessionId]?.remove(at: index)
            delivered[sessionId, default: []].append(offer)
        }
        if reserved[sessionId]?.isEmpty == true { reserved[sessionId] = nil }
        syncPendingFlag(sessionId)
        return true
    }

    /// How a delivered message announces itself in the round. One line, only
    /// when there IS a message — the standing prompt is untouched.
    public static func deliveryText(_ text: String) -> String {
        "[The person sent this just now, while you were working:]\n" + text
    }
}
