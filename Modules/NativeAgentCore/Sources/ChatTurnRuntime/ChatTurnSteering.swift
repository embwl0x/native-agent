import Foundation
import Transcripts

/// A queued message the person chose to Steer into the turn already working
/// (third conversation pass, item 5; a choice, not automatic, since User
/// 2026-10-04 — a send while she works waits in the queue until he steers it).
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

        public init(id: String, text: String, envelope: TurnEnvelope, origin: ChatMessageOrigin?) {
            self.id = id
            self.text = text
            self.envelope = envelope
            self.origin = origin
        }
    }

    /// Bounded so a person holding Return cannot grow an unbounded array behind
    /// a long turn; past this, sends simply stay queued as they always were.
    static let maxPending = 8

    private var pending: [String: [Offer]] = [:]
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
        /// This turn's persister cannot be replaced by another door.
        let persist: Persister?
    }

    /// sessionId → the turn whose window is open. A token, not a flag: the
    /// close runs in a detached task, and without it a just-finished turn's
    /// close could shut the window of the NEXT turn that already opened.
    private var open: [String: OpenTurn] = [:]
    private init() {}

    /// Mark a session as running a turn. EVERY turn calls this — Mac stream,
    /// bridge/Telegram/Slack, bot turns — because `isTurnOpen` is
    /// what the inline-card resume asks before starting anything, and a lane
    /// that never registered read as idle and started a parallel turn on a
    /// session that was already narrating (2026-09-14, session 644D65F1).
    ///
    /// `persist` is how THIS turn writes a delivered message to the transcript.
    /// True proves the row is on disk; false leaves the attempt unresolved and
    /// must not deliver it — the queue reconciles its identity before replay.
    @discardableResult
    public func openTurn(
        sessionId: String, turnId: String, persist: Persister? = nil
    ) -> UUID? {
        guard !sessionId.isEmpty else { return nil }
        let token = TurnAdmission.token ?? UUID()
        open[sessionId] = OpenTurn(token: token, turnId: turnId, persist: persist)
        return token
    }

    /// Close only this turn, returning unused offers before admission passes on.
    public func closeTurn(sessionId: String, token: UUID?) async {
        guard let token, open[sessionId]?.token == token else { return }
        open.removeValue(forKey: sessionId)
        for offer in delivered.removeValue(forKey: sessionId) ?? [] {
            if let handler = deliveryHandlers.removeValue(forKey: offer.id) { _ = await handler(offer, true) }
        }
        let handlers = returnHandlers.removeValue(forKey: token) ?? [:]
        let offers = (stranded.removeValue(forKey: sessionId) ?? [])
            + (reserved.removeValue(forKey: sessionId) ?? [])
            + (pending.removeValue(forKey: sessionId) ?? [])
        for offer in offers.reversed() {
            deliveryHandlers[offer.id] = nil
            if let handler = handlers[offer.id] { await handler(offer) }
        }
    }

    /// The person removed this message from the queue before the turn took it.
    public func withdraw(id: String) {
        for key in pending.keys { pending[key]?.removeAll { $0.id == id } }
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

    /// Whether any session not starting with `prefix` is running a turn: her
    /// resident wake waits for a live one rather than starting a second.
    public func hasOpenTurn(excludingPrefix prefix: String) -> Bool {
        open.keys.contains { !$0.hasPrefix(prefix) }
    }

    /// Offer a message to the session's running turn. `false` means it was not
    /// taken (no open turn, or the pending bound is reached) and the caller
    /// keeps it queued.
    public func offer(_ offer: Offer, sessionId: String,
                      onDelivered: (@MainActor @Sendable (Offer, Bool) async -> Bool)? = nil,
                      onReturned: (@MainActor @Sendable (Offer) async -> Void)? = nil) -> Bool {
        guard let turn = open[sessionId] else { return false }
        var queue = pending[sessionId] ?? []
        guard queue.count < Self.maxPending, !queue.contains(where: { $0.id == offer.id }) else { return false }
        queue.append(offer)
        pending[sessionId] = queue
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
            offer.enqueuedRunID = UUID().uuidString
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
        return true
    }

    /// How a delivered message announces itself in the round. One line, only
    /// when there IS a message — the standing prompt is untouched.
    public static func deliveryText(_ text: String) -> String {
        "[The person sent this just now, while you were working:]\n" + text
    }
}
