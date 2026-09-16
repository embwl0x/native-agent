import Foundation

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

        public init(id: String, text: String) {
            self.id = id
            self.text = text
        }
    }

    /// Bounded so a person holding Return cannot grow an unbounded array behind
    /// a long turn; past this, sends simply stay queued as they always were.
    static let maxPending = 8

    private var pending: [String: [Offer]] = [:]
    private var stranded: [String: [Offer]] = [:]
    public typealias Persister = @Sendable (String, String) async -> Bool

    struct OpenTurn {
        let token: UUID
        /// How THIS turn's delivered message reaches the transcript, and
        /// whether that write succeeded. Carried on the open turn rather than
        /// held process-wide: one shared persister was overwritten by every
        /// structured turn, so a bot turn starting during a Mac turn stamped
        /// the Mac turn's steering messages as `bot`, and once that bot client
        /// went away its weak capture refused persistence for the Mac turn.
        let persist: Persister?
        /// Whether this lane's tool loop has a drain point. Only the structured
        /// loop does (`ChatOrchestration+ToolLoop`). The text-compat loop does
        /// not, so a message offered to it would sit in `pending` until the
        /// turn ended instead of steering it — worse than staying queued. Such
        /// a lane still registers here, because "a turn is running on this
        /// session" is a fact every lane owes the inline-card resume.
        let steerable: Bool
    }

    /// sessionId → the turn whose window is open. A token, not a flag: the
    /// close runs in a detached task, and without it a just-finished turn's
    /// close could shut the window of the NEXT turn that already opened.
    private var open: [String: OpenTurn] = [:]
    private init() {}

    /// Mark a session as running a turn. EVERY lane calls this — Mac stream,
    /// text-compat (bridge/Telegram/Slack), bot turns — because `isTurnOpen` is
    /// what the inline-card resume asks before starting anything, and a lane
    /// that never registered read as idle and started a parallel turn on a
    /// session that was already narrating (2026-09-14, session 644D65F1).
    ///
    /// `steerable: false` says "running, but nothing here drains offers", so
    /// the window is visible to `isTurnOpen` and closed to `offer`.
    ///
    /// `persist` is how THIS turn writes a delivered message to the transcript.
    /// `false` from it means the row is NOT on disk, and an unwritten message
    /// must not be delivered — it would steer the turn and then be absent after
    /// reload, having already left the queue.
    @discardableResult
    public func openTurn(
        sessionId: String, steerable: Bool = true, persist: Persister? = nil
    ) -> UUID? {
        guard !sessionId.isEmpty else { return nil }
        let token = UUID()
        open[sessionId] = OpenTurn(token: token, persist: persist, steerable: steerable)
        return token
    }

    /// End the session's steerable window. Anything never picked up is held for
    /// `takeStranded`, whose owner puts it back in the ordinary queue.
    public func closeTurn(sessionId: String, token: UUID?) {
        guard let token, open[sessionId]?.token == token else { return }
        open.removeValue(forKey: sessionId)
        guard let left = pending.removeValue(forKey: sessionId), !left.isEmpty else { return }
        stranded[sessionId, default: []].append(contentsOf: left)
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
        if let left = pending.removeValue(forKey: sessionId) {
            out.append(contentsOf: left)
        }
        return out
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

    /// Offer a message to the session's running turn. `false` means it was not
    /// taken (no open turn, or the pending bound is reached) and the caller
    /// keeps it queued.
    public func offer(_ offer: Offer, sessionId: String) -> Bool {
        guard open[sessionId]?.steerable == true else { return false }
        var queue = pending[sessionId] ?? []
        guard queue.count < Self.maxPending else { return false }
        queue.append(offer)
        pending[sessionId] = queue
        return true
    }

    /// Take everything offered so far. Called at a tool boundary, so the common
    /// case is an empty array and one actor hop.
    public func drain(sessionId: String) async -> [Offer] {
        guard let queue = pending.removeValue(forKey: sessionId), !queue.isEmpty else {
            return []
        }
        // The person really did send this message, so the transcript records it
        // as their message, in the order they sent it — before the reply the
        // running turn is still composing. PERSIST FIRST: a message the model
        // answers but the transcript never got is gone from the queue AND
        // absent after reload, so a failed write un-delivers the offer — it is
        // stranded instead, and its owner re-queues it as an ordinary turn.
        guard let persist = open[sessionId]?.persist else {
            stranded[sessionId, default: []].append(contentsOf: queue)
            return []
        }
        var delivered: [Offer] = []
        for (index, offer) in queue.enumerated() {
            guard await persist(sessionId, offer.text) else {
                // Their order is their order: once one is held back, the ones
                // behind it go with it rather than arriving ahead of it.
                stranded[sessionId, default: []].append(contentsOf: queue[index...])
                break
            }
            delivered.append(offer)
        }
        return delivered
    }

    /// How a delivered message announces itself in the round. One line, only
    /// when there IS a message — the standing prompt is untouched.
    public static func deliveryText(_ text: String) -> String {
        "[The person sent this just now, while you were working:]\n" + text
    }
}
