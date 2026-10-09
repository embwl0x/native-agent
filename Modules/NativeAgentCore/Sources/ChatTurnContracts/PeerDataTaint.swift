import Foundation
import PersistenceCore

/// TASK-LOCAL PROVENANCE FOR A PEER'S WORDS.
///
/// `agent_message` / `agent_read` already label their result
/// `untrusted_remote_data: true` — but that label rode back into the ordinary
/// tool loop as prose, where the model is free to act on it. A remote agent's
/// reply is DATA, and the one thing data must never be is the authority for
/// the next tool call.
///
/// So the label is bound to the TURN instead of to a string. The moment a turn
/// consumes a peer result, this box latches; from then until the turn ends,
/// `PeerDataTaintDispatcher` refuses the effect classes a peer could otherwise
/// have talked the model into: local effects, durable memory/persona writes,
/// disclosure reads, and external sends. The refusal says why, so the model
/// relays the peer's request to the person instead of executing it.
///
/// The scope is exactly one turn: a task-local reference box, latched at most
/// once, discarded when the turn's task tree ends. That IS the "until the next
/// authenticated human turn" boundary — the next human turn starts with a
/// fresh box. A durable successor of the same task restores its latched sources.
public final class PeerDataTaint: @unchecked Sendable {
    private let lock = NSLock()
    private var sources: [String] = []
    private var line = ""
    private var elevated: [String] = []

    public init() {}

    public convenience init(restoring sources: [String]) {
        self.init()
        // These peers already latched. Persisted labels do not attest identity,
        // and a later trust change must not clear the original steer.
        self.sources = Array(sources.filter { Self.isAgent($0) && !Self.ownerTrusts($0) }.prefix(8))
        restored = !self.sources.isEmpty
    }

    /// A steer an earlier turn carried in, not one this turn latched itself.
    /// Set once, before the box is shared.
    public private(set) var restored = false

    /// A later turn under the steer an earlier one carried (`carried`).
    public convenience init(restoring sources: [String], elevated: [String]) {
        self.init(restoring: sources)
        self.elevated = Array(elevated.filter { Self.isAgent($0) && !Self.ownerTrusts($0) }.prefix(8))
    }

    /// The steer this turn leaves on work it hands to a later one, a card or
    /// a queued step (Wave 2 #8): its latched peers, the peer whose bridge
    /// turn it is (`peerBridge`, which latches nothing of its own), and the
    /// peers the person elevated.
    public static func carried(peerBridge: Bool, peerID: String?) -> (sources: [String], elevated: [String]) {
        var sources = current?.checkpointSources ?? []
        if sources.isEmpty, peerBridge { sources = [peerID.map { "peer:" + $0 } ?? "another agent"] }
        return (sources, current?.elevatedSources ?? [])
    }

    /// `carried` as a card keeps it in its payload, empty lists included: a
    /// card with no record at all predates this and restores `unrecorded`.
    public static func carriedRecord(peerBridge: Bool, peerID: String?) -> JSONValue {
        let steer = carried(peerBridge: peerBridge, peerID: peerID)
        return .object(["sources": .array(steer.sources.map(JSONValue.string)),
                        "elevated": .array(steer.elevated.map(JSONValue.string))])
    }

    /// The steer of a card filed before cards kept one: who steered it is
    /// unknown, so its follow-up is held to the peer floor.
    public static let unrecorded = "an agent (this card predates its record of who steered it)"

    /// The sources and elevated peers a `carriedRecord` holds; no record at all is `unrecorded`.
    public static func steer(in record: JSONValue?) -> (sources: [String], elevated: [String]) {
        guard case .object(let fields)? = record else { return ([unrecorded], []) }
        func list(_ key: String) -> [String] {
            guard case .array(let items)? = fields[key] else { return [] }
            return items.compactMap { if case .string(let text) = $0 { text } else { nil } }
        }
        return (list("sources"), list("elevated"))
    }

    @TaskLocal public static var current: PeerDataTaint?

    /// Run `operation` under a fresh taint scope, unless one is already bound
    /// (a nested loop must not silently launder its parent's taint).
    public static func withScope<T>(
        isolation: isolated (any Actor)? = #isolation,
        operation: () async throws -> T
    ) async rethrows -> T {
        if current != nil { return try await operation() }
        return try await $current.withValue(PeerDataTaint(), operation: operation, isolation: isolation)
    }

    /// Latch: this turn has now read a remote peer's words. `line` is the
    /// newest of them, kept so the person's card can quote it.
    public static func markConsumed(peer: String, line: String = "", attested: Bool = true) {
        current?.mark(peer: peer, line: line, attested: attested)
    }

    /// The peer's words without latching a source: a bridge turn is the
    /// peer's by its surface already.
    public func keep(line: String) {
        lock.lock(); defer { lock.unlock() }
        let trimmed = line.trimmingCharacters(in: .whitespacesAndNewlines)
        if !trimmed.isEmpty { self.line = trimmed }
    }

    public var lastLine: String {
        lock.lock(); defer { lock.unlock() }
        return line
    }

    /// Whether a steer this app attested is the person's own (`PeerTrust`,
    /// User 10-03), installed by the engine; unset, nothing is. Judged when the
    /// latch happens: switching a peer off holds from its next latch on.
    public static var ownerTrusts: @Sendable (String) -> Bool {
        get { hookLock.withLock { hook } }
        set { hookLock.withLock { hook = newValue } }
    }
    private static let hookLock = NSLock()
    nonisolated(unsafe) private static var hook: @Sendable (String) -> Bool = { _ in false }

    public static var trustedTurn: Bool {
        let turn = TurnEnvelope.current(surface: "")
        return [turn.agent, ChatPersistenceContext.originProvenance?.agent, turn.verifiedUserId.map { "peer:" + $0 }]
            .compactMap { $0 }.contains(where: ownerTrusts)
    }

    /// User 10-08: only an agent bridge he has not trusted can latch a turn.
    /// Web, mail, files, memory, helpers, wakes and scheduled work never do;
    /// the Trust mode's own gates are the only other approvals. Installed by
    /// the engine (`PeerTrust`); until then only a peer handle counts.
    public static var isAgent: @Sendable (String) -> Bool {
        get { hookLock.withLock { agentHook } }
        set { hookLock.withLock { agentHook = newValue } }
    }
    nonisolated(unsafe) private static var agentHook: @Sendable (String) -> Bool = {
        $0.lowercased().hasPrefix("peer:") || $0.lowercased() == "another agent" // an unidentified bridge peer stays untrusted
    }

    /// A peer the person elevated latches nothing: its steer is his own. Only
    /// an `attested` identity (the turn's own lane or envelope, provenance this
    /// app stored) can be; a label a tool result supplies never is.
    public func mark(peer: String, line: String = "", attested: Bool = true) {
        let trimmed = peer.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        let name = trimmed
        if Self.ownerTrusts(name) { return } // User 10-08: a trusted agent never cards, however it is named
        guard Self.isAgent(name) else { return }
        keep(line: line)
        lock.lock(); defer { lock.unlock() }
        guard !sources.contains(name), sources.count < 8 else { return }
        sources.append(name)
    }

    /// A peer the person elevated steered this turn: it does not taint, but
    /// the three floor acts still card (Agent, 10-02: "every peer").
    public static func markElevated(peer: String, line: String = "", attested: Bool = true) {
        current?.markElevated(peer: peer, line: line, attested: attested)
    }

    public func markElevated(peer: String, line: String = "", attested: Bool = true) {
        let name = peer.trimmingCharacters(in: .whitespacesAndNewlines)
        if Self.ownerTrusts(name) { return } // User 10-08: a trusted agent never cards, however it is named
        guard Self.isAgent(name) else { return }
        keep(line: line)
        lock.lock(); defer { lock.unlock() }
        guard !name.isEmpty, !elevated.contains(name), elevated.count < 8 else { return }
        elevated.append(name)
    }

    public var elevatedSources: [String] {
        lock.lock(); defer { lock.unlock() }
        return elevated
    }

    public var isTainted: Bool {
        lock.lock(); defer { lock.unlock() }
        return !sources.isEmpty
    }

    public var checkpointSources: [String] {
        lock.lock(); defer { lock.unlock() }
        return sources
    }

    public var sourceDescription: String {
        lock.lock(); defer { lock.unlock() }
        return sources.joined(separator: ", ")
    }
}
