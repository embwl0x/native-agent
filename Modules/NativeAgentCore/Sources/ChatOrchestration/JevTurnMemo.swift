import Foundation

/// The little the advisory lanes need to remember inside one turn: what was
/// asked, what was said just before it, how many tool-call checks have been
/// spent, and which warnings have already been given.
///
/// Bounded on purpose. A turn that never reaches its end (a crash, a cancel)
/// leaves at most `maxTurns` entries behind, and the oldest is dropped.
actor JevTurnMemo {
    static let shared = JevTurnMemo()

    /// After this many tool-call checks the lane goes silent for the turn, so
    /// a long tool loop cannot turn into a long run of calls.
    static let toolCallBudget = 8
    private static let maxTurns = 16

    struct Turn: Sendable {
        var message: String
        var recent: [String]
        var sessionID: String
        var toolCallsSpent: Int = 0
        /// Warnings already given this turn, so the same one is never repeated.
        var warningsGiven: Set<String> = []
    }

    private var turns: [String: Turn] = [:]
    private var order: [String] = []

    func open(turnID: String, message: String, recent: [String], sessionID: String) {
        turns[turnID] = Turn(message: message, recent: recent, sessionID: sessionID)
        order.append(turnID)
        while order.count > Self.maxTurns, let oldest = order.first {
            order.removeFirst()
            turns[oldest] = nil
        }
    }

    func turn(_ turnID: String) -> Turn? { turns[turnID] }

    func close(turnID: String) {
        turns[turnID] = nil
        order.removeAll { $0 == turnID }
    }

    /// Claim one tool-call check. Returns the turn's remembered ask when there
    /// is budget left, nil once the budget is spent.
    func claimToolCall(turnID: String) -> Turn? {
        guard var turn = turns[turnID], turn.toolCallsSpent < Self.toolCallBudget else { return nil }
        turn.toolCallsSpent += 1
        turns[turnID] = turn
        return turn
    }

    /// Record a warning and say whether it is new. A repeat is dropped.
    func claimWarning(turnID: String, key: String) -> Bool {
        guard var turn = turns[turnID] else { return true }
        guard !turn.warningsGiven.contains(key) else { return false }
        turn.warningsGiven.insert(key)
        turns[turnID] = turn
        return true
    }
}
