import Foundation
import Transcripts

/// A message the person sent while a turn was already working (third
/// conversation pass, item 5).
///
/// Before this, every send during an active turn went into the send-next queue
/// and waited for the session to go idle — so "actually, just Tuesday" sat
/// behind a whole tool loop still working from the old request. An offer made
/// here is picked up by the running loop at its next tool boundary, BEFORE the
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
        /// Attempt identity, retained even when commitment is still unresolved.
        /// The queue reconciles it before deciding whether to append on replay.
        public internal(set) var enqueuedRunID: String?

        public init(id: String, text: String) {
            self.id = id
            self.text = text
        }
    }

    /// Bounded so a person holding Return cannot grow an unbounded array behind
    /// a long turn; past this, sends simply stay queued as they always were.
    static let maxPending = 8

    private var pending: [String: [Offer]] = [:]
    private var reserved: [String: [Offer]] = [:]
    private var stranded: [String: [Offer]] = [:]
    /// Offer id → its owner's "the running turn has it now", run once when
    /// the turn reserves it, so the send-next row stays visible until then.
    private var deliveryHandlers: [String: @MainActor @Sendable () -> Void] = [:]
    public typealias Persister = @Sendable (String, String, String) async -> Bool

    struct OpenTurn {
        let token: UUID
        /// How THIS turn's delivered message reaches the transcript, and
        /// whether that write succeeded. Carried on the open turn rather than
        /// held process-wide: one shared persister was overwritten by every
        /// structured turn, so a bot turn starting during a Mac turn stamped
        /// the Mac turn's steering messages as `bot`, and once that bot client
        /// went away its weak capture refused persistence for the Mac turn.
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
        sessionId: String, persist: Persister? = nil
    ) -> UUID? {
        guard !sessionId.isEmpty else { return nil }
        let token = UUID()
        open[sessionId] = OpenTurn(token: token, persist: persist)
        return token
    }

    /// End the session's steerable window. Anything never picked up is held for
    /// `takeStranded`, whose owner puts it back in the ordinary queue.
    public func closeTurn(sessionId: String, token: UUID?) {
        guard let token, open[sessionId]?.token == token else { return }
        open.removeValue(forKey: sessionId)
        if let left = reserved.removeValue(forKey: sessionId) {
            stranded[sessionId, default: []].append(contentsOf: left)
        }
        if let left = pending.removeValue(forKey: sessionId) {
            stranded[sessionId, default: []].append(contentsOf: left)
        }
    }

    /// The single drain point once a turn is over: everything it never took —
    /// already-stranded offers, plus anything still pending — with the window
    /// shut behind it. `closeTurn` runs from a deferred task that can lose the
    /// race with its owner's cleanup; without draining `pending` here too, the
    /// cleanup could find an empty box and the later close would strand an
    /// offer after the only requeue pass, with its queue entry already gone.
    /// The owner puts what comes back at the head of the ordinary queue, so
    /// every offer still either steers the live turn or runs as its own turn.
    public func takeStranded(sessionId: String) -> [Offer] {
        open.removeValue(forKey: sessionId)
        var out = stranded.removeValue(forKey: sessionId) ?? []
        if let left = reserved.removeValue(forKey: sessionId) {
            out.append(contentsOf: left)
        }
        if let left = pending.removeValue(forKey: sessionId) {
            out.append(contentsOf: left)
        }
        for offer in out { deliveryHandlers[offer.id] = nil }
        return out
    }

    /// The person removed this message from the queue before the turn took it.
    public func withdraw(id: String) {
        for key in pending.keys { pending[key]?.removeAll { $0.id == id } }
        for key in stranded.keys { stranded[key]?.removeAll { $0.id == id } }
        deliveryHandlers[id] = nil
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
                      onDelivered: (@MainActor @Sendable () -> Void)? = nil) -> Bool {
        guard open[sessionId] != nil else { return false }
        var queue = pending[sessionId] ?? []
        guard queue.count < Self.maxPending else { return false }
        queue.append(offer)
        pending[sessionId] = queue
        deliveryHandlers[offer.id] = onDelivered
        return true
    }

    /// Called only after the next provider round is admitted. Keep offers
    /// reserved through persistence so a Stop returns even committed rows to
    /// the ordinary queue with their enqueue identity intact.
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
        reserved[sessionId] = queue.map { var offer = $0; offer.enqueuedRunID = UUID().uuidString; return offer }
        for offer in queue {
            if let handler = deliveryHandlers.removeValue(forKey: offer.id) { await handler() }
        }
        for (index, offer) in queue.enumerated() {
            if Task.isCancelled || ChatCancelFlag.isRaised(cancelFlagPath) { return [] }
            guard let runID = reserved[sessionId]?[index].enqueuedRunID else { return [] }
            let committed = await persist(sessionId, offer.text, runID)
            guard open[sessionId]?.token == turn.token else { return [] }
            guard committed else {
                // Keep their order, including rows saved before this failure.
                stranded[sessionId, default: []].append(
                    contentsOf: reserved.removeValue(forKey: sessionId) ?? [])
                return []
            }
        }
        guard !Task.isCancelled, !ChatCancelFlag.isRaised(cancelFlagPath) else { return [] }
        return reserved.removeValue(forKey: sessionId) ?? []
    }

    /// A Stop after the actor hop can still prevent provider construction.
    /// The rows are already saved, so retain their run IDs for queue replay.
    public func returnUndelivered(_ offers: [Offer], sessionId: String) {
        stranded[sessionId, default: []].append(contentsOf: offers)
    }

    /// How a delivered message announces itself in the round. One line, only
    /// when there IS a message — the standing prompt is untouched.
    public static func deliveryText(_ text: String) -> String {
        "[The person sent this just now, while you were working:]\n" + text
    }
}
