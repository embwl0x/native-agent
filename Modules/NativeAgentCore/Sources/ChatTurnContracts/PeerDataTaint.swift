import Foundation
import os
import NativeAgentCore
import PersistenceCore
// Blueprint: | `PeerDataTaint.swift` | `PeerDataTaint`; `mark`; `markConsumed`; `elevate`; `steer` |

/// Only an untrusted agent starting a turn steers it; reading words latches nothing. One card covers the run.
/// Checkpoints retain provenance and the answered set so continuation preserves that decision.
public final class PeerDataTaint: @unchecked Sendable {
    private let lock = NSLock()
    private var sources: [String] = []
    private var line = ""
    private var elevated: [String] = []

    public init() {}

    public convenience init(restoring sources: [String], elevated: [String] = []) {
        self.init()
        let peers = Array(Set(sources.map(Self.principal))).sorted()
        for peer in peers {
            if Self.ownerTrusts(peer) { self.elevated.append(peer) }
            else { self.sources.append(peer) }
        }
        for peer in elevated { elevate(peer: peer) }
    }

    /// Carry origin peers, bridge identity and elevated peers so later turns and queued steps preserve the same steering.
    public static func carried(turn: Turn, peerBridge: Bool, peerID: String?) -> (sources: [String], elevated: [String]) {
        var sources = Array(Set((turn.peerSteering?.checkpointSources ?? []) + abilitySources(turn: turn))).sorted()
        if peerBridge, let peerID, !peerID.isEmpty { sources = Array(Set(sources + ["peer:" + peerID])).sorted() }
        if sources.isEmpty, peerBridge { sources = ["another agent"] }
        return (sources, turn.peerSteering?.elevatedSources ?? [])
    }

    /// Keep empty lists explicit in card payloads.
    public static func carriedRecord(turn: Turn, peerBridge: Bool, peerID: String?) -> JSONValue {
        let steer = carried(turn: turn, peerBridge: peerBridge, peerID: peerID)
        return .object(["sources": .array(steer.sources.map(JSONValue.string)),
                        "elevated": .array(steer.elevated.map(JSONValue.string))])
    }

    /// Unknown card provenance retains the peer floor rather than inventing an unsteered origin.
    public static let unrecorded = "an agent (this card predates its record of who steered it)"

    /// Restore only the complete current record. Missing provenance is not an
    /// unsteered run and cannot be repaired by inventing a principal.
    public static func steer(in record: JSONValue?) throws -> (sources: [String], elevated: [String]) {
        func invalid(_ detail: String) -> ToolFailureError {
            ToolFailureError("Carried steering is unavailable: \(detail). The continuation was not restored.", effects: .none,
                owner: "Carried run provenance", code: "steering_record_invalid",
                instruction: "Preserve the saved request and repair its recorded provenance before continuing.")
        }
        guard case .object(let fields)? = record else { throw invalid("missing or non-object record") }
        func list(_ key: String) throws -> [String] {
            guard case .array(let items)? = fields[key] else { throw invalid("\(key) must be an array") }
            return try items.map { item in
                guard case .string(let text) = item, !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
                    throw invalid("\(key) must contain nonempty principal strings")
                }
                return text
            }
        }
        return (try list("sources"), try list("elevated"))
    }

    /// Reading grants no steering. Only a peer-started turn latches provenance, and one elevation covers that turn.
    public static func markConsumed(peer: String, line: String = "") {}

    /// The card's answer elevates steering peers for the turn and handed-on steps; senses, tools, skills and Trust still apply.
    public func elevate(peer: String) {
        let name = Self.principal(peer.trimmingCharacters(in: .whitespacesAndNewlines))
        guard Self.steers(name) else { return }
        lock.lock(); defer { lock.unlock() }
        if !elevated.contains(name) { elevated.append(name) }
    }

    /// Reading peer words latches nothing; the bridge surface already identifies its initiating peer.
    public func keep(line: String) {
        lock.lock(); defer { lock.unlock() }
        let trimmed = line.trimmingCharacters(in: .whitespacesAndNewlines)
        if !trimmed.isEmpty { self.line = trimmed }
    }

    public var lastLine: String {
        lock.lock(); defer { lock.unlock() }
        return line
    }

    /// Only the engine can attest user-owned steering; unset means no attestation.
    public static var ownerTrusts: @Sendable (String) -> Bool {
        get { CapabilityLifecycle.ownerTrusts }
        set { CapabilityLifecycle.ownerTrusts = newValue }
    }
    private struct Hooks {
        var name: @Sendable (String) -> String? = { _ in nil }
        var principal: @Sendable (String) -> String = { $0 }
    }
    private static let hooks = OSAllocatedUnfairLock(initialState: Hooks())

    public static func trustedTurn(_ turn: Turn) -> Bool {
        let envelope = TurnEnvelope.current(turn: turn, surface: "")
        return [envelope.agent, turn.origin?.agent, envelope.verifiedUserId.map { "peer:" + $0 }]
            .compactMap { $0 }.contains(where: ownerTrusts)
    }

    /// The same principals follow ability writes and error text quoted later.
    public static func abilitySources(turn: Turn) -> [String] {
        let origin = turn.origin
        var sources = (turn.peerSteering?.checkpointSources ?? [])
            + (origin?.peerSources ?? []) + (origin?.elevatedPeerSources ?? [])
        let envelope = TurnEnvelope.current(turn: turn, surface: "")
        if turn.originPrincipal.hasPrefix("agent:") || envelope.surface == "agent-bridge" {
            let agent = origin?.agent ?? envelope.agent ?? "another agent"
            if agent != "self", !agent.hasPrefix("bot:") {
                sources.append(envelope.verifiedUserId.map { "peer:" + $0 }
                    ?? (["agent", "peer"].contains(agent) ? "another agent" : agent))
            }
        }
        return Array(Set(sources.filter(steers))).sorted()
    }

    public static func abilityWriteCheck(turn: Turn) -> String? { abilityWriteFailure(turn: turn)?.message }

    public static var sourceName: @Sendable (String) -> String? {
        get { hooks.withLock { $0.name } }
        set { hooks.withLock { $0.name = newValue } }
    }

    public static func abilityWriteFailure(turn: Turn) -> ToolFailureError? {
        let peers = abilitySources(turn: turn)
        // One answered card covers the run, so its peers impose no further cap.
        let answered = Set(turn.peerSteering?.elevatedSources ?? [])
        do {
            let untrusted = peers.filter { !ownerTrusts($0) && !answered.contains($0) }.sorted()
            guard !untrusted.isEmpty else { return nil }
            let names = untrusted.map { sourceName($0) }
            let tap = names.allSatisfy { $0 != nil }
                ? names.compactMap { $0 }.map { "Trust > Connected agents > " + $0 }.joined(separator: "; ") : nil
            let who = zip(untrusted, names).map { source, name in name.map { "\($0) [\(source)]" } ?? source }.joined(separator: ", ")
            return CapabilityLifecycle.peerRefusal(who, tap: tap)
        }
    }

    /// Only an untrusted initiating agent or wake sender latches steering. Reading web, mail, files or memory does not.
    /// Trusted helpers, schedules and native work use ordinary Trust gates; unrecognized external forms still steer.
    static func steers(_ source: String) -> Bool { !source.isEmpty && source != "self" && !source.hasPrefix("bot:") }

    /// Resolve every attested locator to its contact so aliases share one principal and one grant.
    /// The engine installs the resolver; until then retain the locator.
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

    /// Untrusted, unanswered principals steer a run. One answered card removes steering for the whole run, including its floor.
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
