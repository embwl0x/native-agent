import Foundation
import os
import NativeAgentCore
import PersistenceCore
// Blueprint: | `PeerDataTaint.swift` | `PeerDataTaint` class; `withScope`, `mark` (latches any sender the owner does not trust, recognized or not, but their own `self` and bots), `markConsumed` (latches nothing: a read steers nothing), `elevate` (the person answered the run's card); one restore initializer retains provenance and answers without a read-latch marker; ability write refusal reads current origin principal and live/carried peer steering |

/// Task-local origin steering and the person's answer for one run.
/// Only a turn an untrusted agent starts is steered; reading words latches
/// nothing. Its one card quotes the turn's input, and `elevate` ends the
/// steering. Checkpoints retain both the provenance and the answered set.
public final class PeerDataTaint: @unchecked Sendable {
    private let lock = NSLock()
    private var sources: [String] = []
    private var line = ""
    private var elevated: [String] = []

    public init() {}

    /// Restore this run's provenance and the peers its card already covered.
    public convenience init(restoring sources: [String], elevated: [String] = []) {
        self.init()
        let peers = Array(Set(sources.map(Self.principal))).sorted()
        for peer in peers {
            if Self.ownerTrusts(peer) { self.elevated.append(peer) }
            else { self.sources.append(peer) }
        }
        for peer in elevated { elevate(peer: peer) }
    }

    /// The steer this turn leaves on work it hands to a later one, a card or
    /// a queued step: its origin peers, the peer whose bridge
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

    /// Reading a peer's words steers nothing. What she reads is labelled where it is shown; a turn is
    /// the peer's only when the peer started it (`TurnRequest.bind`), and that
    /// turn's one card covers the rest of it (`elevate`).
    public static func markConsumed(peer: String, line: String = "") {}

    /// The person answered this turn's card: its steering peers act for the
    /// rest of the turn (and the steps it hands on) without another card.
    /// The floor (senses, tools, skills, Trust) still holds.
    public func elevate(peer: String) {
        let name = Self.principal(peer.trimmingCharacters(in: .whitespacesAndNewlines))
        guard Self.steers(name) else { return }
        lock.lock(); defer { lock.unlock() }
        if !elevated.contains(name) { elevated.append(name) }
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

    /// Whether a steer this app attested is the person's own, installed by the engine; unset, nothing is.
    public static var ownerTrusts: @Sendable (String) -> Bool {
        get { CapabilityLifecycle.ownerTrusts }
        set { CapabilityLifecycle.ownerTrusts = newValue }
    }
    private struct Hooks {
        var name: @Sendable (String) -> String? = { _ in nil }
        var principal: @Sendable (String) -> String = { $0 }
    }
    private static let hooks = OSAllocatedUnfairLock(initialState: Hooks())

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
        return Array(Set(sources.filter(steers))).sorted()
    }

    public static var abilityWriteCheck: @Sendable () -> String? {
        let check = abilityWriteFailure
        return { check()?.message }
    }

    public static var sourceName: @Sendable (String) -> String? {
        get { hooks.withLock { $0.name } }
        set { hooks.withLock { $0.name = newValue } }
    }

    public static var abilityWriteFailure: @Sendable () -> ToolFailureError? {
        let peers = abilitySources
        // The person answered this run's card: its peers cap nothing more (one card per command).
        let answered = Set(current?.elevatedSources ?? [])
        return {
            let untrusted = peers.filter { !ownerTrusts($0) && !answered.contains($0) }.sorted()
            guard !untrusted.isEmpty else { return nil }
            let names = untrusted.map { sourceName($0) }
            let tap = names.allSatisfy { $0 != nil }
                ? names.compactMap { $0 }.map { "Trust > Connected agents > " + $0 }.joined(separator: "; ") : nil
            let who = zip(untrusted, names).map { source, name in name.map { "\($0) [\(source)]" } ?? source }.joined(separator: ", ")
            return CapabilityLifecycle.peerRefusal(who, tap: tap)
        }
    }

    /// Only a sender he has not trusted can latch a run: an agent
    /// that starts a turn, or a sender a wake names that is not allowlisted.
    /// Web, mail, files, memory, helpers and scheduled work are never marked;
    /// the Trust mode's own gates are the only other approvals. Her own hands
    /// (`self`, her bots) never steer; any other form does, recognized or
    /// not, since no one the person trusted is unrecognized.
    static func steers(_ source: String) -> Bool { !source.isEmpty && source != "self" && !source.hasPrefix("bot:") }

    /// A latch names a who, never a label: whatever locator the body wrote
    /// (an attested id, a lane, a contact's name) is resolved to the one
    /// contact it names before it is kept, so the same who read under two
    /// labels is one principal and the person's grant on it decides.
    /// Installed by the engine (`PeerTrust`); until then a locator stands.
    public static var principal: @Sendable (String) -> String {
        get { hooks.withLock { $0.principal } }
        set { hooks.withLock { $0.principal = newValue } }
    }

    /// A peer the person elevated retains its identity without taint.
    public func mark(peer: String, line: String = "") {
        let trimmed = peer.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        let name = Self.principal(trimmed)
        guard Self.steers(name) else { return }
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

    public var elevatedSources: [String] {
        lock.withLock { elevated }.filter { !Self.ownerTrusts($0) }
    }

    /// Steered: a source the owner does not trust and the person has not
    /// answered for this run. One card per command: once the
    /// card is answered, nothing in the run is steered any more, the floor
    /// (senses, tools, skills, Trust) included.
    public var isTainted: Bool {
        let answered = lock.withLock { elevated }
        return checkpointSources.contains { !Self.ownerTrusts($0) && !answered.contains($0) }
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
