import Foundation
import NativeAgentCore
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
        let peers = Array(Set(sources.map(Self.principal))).sorted()
        for peer in peers {
            if Self.ownerTrusts(peer) { self.elevated.append(peer) }
            else { self.sources.append(peer) }
        }
        restored = !peers.isEmpty
    }

    /// A steer an earlier turn carried in, not one this turn latched itself.
    /// Set once, before the box is shared.
    public private(set) var restored = false

    /// A later turn under the steer an earlier one carried (`carried`).
    public convenience init(restoring sources: [String], elevated: [String]) {
        self.init(restoring: sources + elevated)
    }

    /// The steer this turn leaves on work it hands to a later one, a card or
    /// a queued step (Wave 2 #8): its latched peers, the peer whose bridge
    /// turn it is (`peerBridge`, which latches nothing of its own), and the
    /// peers the person elevated.
    public static func carried(peerBridge: Bool, peerID: String?) -> (sources: [String], elevated: [String]) {
        var sources = Array(Set((current?.checkpointSources ?? []) + abilitySources)).sorted()
        if peerBridge, let peerID, !peerID.isEmpty { sources = Array(Set(sources + ["peer:" + peerID])).sorted() }
        if sources.isEmpty, peerBridge { sources = ["another agent"] }
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
    public static func markConsumed(peer: String, line: String = "") {
        current?.mark(peer: peer, line: line)
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
    /// User 10-03), installed by the engine; unset, nothing is.
    public static var ownerTrusts: @Sendable (String) -> Bool {
        get { CapabilityLifecycle.ownerTrusts }
        set { CapabilityLifecycle.ownerTrusts = newValue }
    }
    private static let hookLock = NSLock()

    public static var trustedTurn: Bool {
        let turn = TurnEnvelope.current(surface: "")
        return [turn.agent, ChatPersistenceContext.originProvenance?.agent, turn.verifiedUserId.map { "peer:" + $0 }]
            .compactMap { $0 }.contains(where: ownerTrusts)
    }

    /// The same principals follow ability writes and error text quoted later.
    public static var abilitySources: [String] {
        let origin = ChatPersistenceContext.originProvenance
        var sources = (current?.checkpointSources ?? [])
            + (origin?.peerSources ?? []) + (origin?.elevatedPeerSources ?? [])
        let turn = TurnEnvelope.current(surface: "")
        if ChatPersistenceContext.originPrincipal.hasPrefix("agent:") || turn.surface == "agent-bridge" {
            let agent = origin?.agent ?? turn.agent ?? "another agent"
            if agent != "self", !agent.hasPrefix("bot:") {
                sources.append(turn.verifiedUserId.map { "peer:" + $0 }
                    ?? (["agent", "peer"].contains(agent) ? "another agent" : agent))
            }
        }
        return Array(Set(sources.filter { $0 != "self" && !$0.hasPrefix("bot:") && isAgent($0) })).sorted()
    }

    public static var abilityWriteCheck: @Sendable () -> String? {
        let check = abilityWriteFailure
        return { check()?.message }
    }

    public static var sourceName: @Sendable (String) -> String? {
        get { hookLock.withLock { nameHook } }
        set { hookLock.withLock { nameHook = newValue } }
    }
    nonisolated(unsafe) private static var nameHook: @Sendable (String) -> String? = { _ in nil }

    public static var abilityWriteFailure: @Sendable () -> ToolFailureError? {
        let peers = abilitySources
        return {
            let untrusted = peers.filter { !ownerTrusts($0) }.sorted()
            guard !untrusted.isEmpty else { return nil }
            let names = untrusted.map { sourceName($0) }
            let tap = names.allSatisfy { $0 != nil }
                ? names.compactMap { $0 }.map { "Trust > Connected agents > " + $0 }.joined(separator: "; ") : nil
            let who = zip(untrusted, names).map { source, name in name.map { "\($0) [\(source)]" } ?? source }.joined(separator: ", ")
            return CapabilityLifecycle.peerRefusal(who, tap: tap)
        }
    }

    public static var ownerAuthorized: Bool {
        let envelope = ChatToolSessionContext.envelope
        return envelope?.agent == "peer"
            && (envelope?.verifiedUserId.map { ownerTrusts("peer:" + $0) } ?? false)
            && current?.isTainted != true
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
        $0.lowercased().hasPrefix("peer:") || ["another agent", "a remote peer", unrecorded].contains($0.lowercased())
    }

    /// A latch names a who, never a label: whatever locator the body wrote
    /// (an attested id, a lane, a contact's name) is resolved to the one
    /// contact it names before it is kept, so the same who read under two
    /// labels is one principal and the person's grant on it decides.
    /// Installed by the engine (`PeerTrust`); until then a locator stands.
    public static var principal: @Sendable (String) -> String {
        get { hookLock.withLock { principalHook } }
        set { hookLock.withLock { principalHook = newValue } }
    }
    nonisolated(unsafe) private static var principalHook: @Sendable (String) -> String = { $0 }

    /// A peer the person elevated retains its identity without taint.
    public func mark(peer: String, line: String = "") {
        let trimmed = peer.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        let name = Self.principal(trimmed)
        guard Self.isAgent(name) else { return }
        keep(line: line)
        let trusted = Self.ownerTrusts(name)
        lock.lock(); defer { lock.unlock() }
        if trusted {
            if !elevated.contains(name) { elevated.append(name) }
            return
        }
        guard !sources.contains(name) else { return }
        sources.append(name)
    }

    /// Carried elevation is an identity record, not a saved permission grant.
    public static func markElevated(peer: String, line: String = "") {
        current?.markElevated(peer: peer, line: line)
    }

    public func markElevated(peer: String, line: String = "") {
        mark(peer: peer, line: line)
    }

    public var elevatedSources: [String] {
        lock.withLock { elevated }.filter { !Self.ownerTrusts($0) }
    }

    public var isTainted: Bool {
        checkpointSources.contains { !Self.ownerTrusts($0) }
    }

    /// Every steering principal survives carry and resume; trust is never saved.
    public var checkpointSources: [String] {
        lock.lock(); defer { lock.unlock() }
        return Array(Set(sources + elevated)).sorted()
    }

    public var sourceDescription: String {
        checkpointSources.filter { !Self.ownerTrusts($0) }.joined(separator: ", ")
    }
}
