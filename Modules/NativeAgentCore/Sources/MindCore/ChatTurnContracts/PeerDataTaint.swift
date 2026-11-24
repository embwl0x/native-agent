import Synchronization
import SenseCore
import DeskCore
import Foundation
import NativeAgentCore
import PersistenceCore
// Blueprint: | `PeerDataTaint.swift` | `PeerDataTaint`; `mark`; `elevate`; `steer` |

public final class PeerDataTaint: Sendable {
    private struct State {
        var sources: [String] = []
        var line = ""
        var elevated: [String] = []
    }
    private let state = Mutex(State())

    public init() {}

    public convenience init(dataRoot: URL, restoring sources: [String], elevated: [String] = []) {
        self.init()
        let principals = Array(Set(sources.map { Self.principal(dataRoot, $0) })).sorted()
        state.withLock { $0.sources = principals }
        for peer in elevated { elevate(dataRoot: dataRoot, peer: peer) }
    }

    /// Carry origin peers, bridge identity and elevated peers so later turns and queued steps preserve the same steering.
    public static func carried(turn: Turn, surface: String = "") -> (sources: [String], elevated: [String]) {
        var sources = Array(Set((turn.peerSteering?.checkpointSources ?? []) + abilitySources(turn: turn))).sorted()
        let envelope = TurnEnvelope.current(turn: turn, surface: surface)
        if let peerID = attestedPeerID(turn: turn) {
            sources = Array(Set(sources + ["peer:" + peerID])).sorted()
        } else if sources.isEmpty, PeerTurnEffectPolicy.isPeerBridge(surface: envelope.surface),
                  envelope.agent != "self", envelope.agent?.hasPrefix("bot:") != true {
            sources = ["another agent"]
        }
        return (sources, turn.peerSteering?.elevatedSources ?? [])
    }

    /// Keep empty lists explicit in card payloads.
    public static func carriedRecord(turn: Turn, surface: String = "") -> JSONValue {
        let steer = carried(turn: turn, surface: surface)
        return .object(["sources": .array(steer.sources.map(JSONValue.string)),
                        "elevated": .array(steer.elevated.map(JSONValue.string))])
    }

    /// Unknown card provenance retains the peer floor rather than inventing an unsteered origin.
    public static let unrecorded = "an agent (this card predates its record of who steered it)"

    /// Restore only the complete current record. Missing provenance is not an
    /// unsteered run and cannot be repaired by inventing a principal.
    public static func steer(dataRoot: URL, in record: JSONValue?, scope: String? = nil) throws -> (sources: [String], elevated: [String]) {
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
        let sources = try list("sources"), elevated = try list("elevated")
        return (sources, elevated + (scope == "task" ? sources.filter { !ownerTrusts(dataRoot, $0) && !elevated.contains($0) } : []))
    }

    public func elevate(dataRoot: URL, peer: String) {
        let name = Self.principal(dataRoot, peer.trimmingCharacters(in: .whitespacesAndNewlines))
        guard Self.steers(name) else { return }
        state.withLock { state in
            if !state.elevated.contains(name) { state.elevated.append(name) }
        }
    }

    /// Reading peer words latches nothing; the bridge surface already identifies its initiating peer.
    public func keep(line: String) {
        state.withLock { state in
            let trimmed = line.trimmingCharacters(in: .whitespacesAndNewlines)
            if !trimmed.isEmpty { state.line = trimmed }
        }
    }

    public var lastLine: String {
        return state.withLock { $0.line }
    }

    /// Only the engine can attest user-owned steering; unset means no attestation.
    public static var ownerTrusts: @Sendable (URL, String) -> Bool {
        get { CapabilityLifecycle.ownerTrusts }
        set { CapabilityLifecycle.ownerTrusts = newValue }
    }
    private struct Hooks {
        var name: @Sendable (URL, String) -> String? = { _, _ in nil }
        var principal: @Sendable (URL, String) -> String = { $1 }
        var readTrust: @Sendable (URL, [String]) -> TrustRead = { _, _ in TrustRead(principals: [:], trusted: [], names: [:]) }
    }
    private static let hooks = Mutex(Hooks())

    /// One pass's live trust and contact names, read by the trust owner. Lookups do no I/O; nothing survives into the next pass or authorizes an effect.
    public struct TrustRead: Sendable {
        private let principals: [String: String]
        private let trusted: Set<String>
        private let names: [String: String]
        private let doorNames: [String: String]

        public init(principals: [String: String], trusted: Set<String>, names: [String: String],
                    doorNames: [String: String] = [:]) {
            self.principals = principals; self.trusted = trusted; self.names = names; self.doorNames = doorNames
        }
        public func principal(_ source: String) -> String { principals[source] ?? source }
        public func ownerTrusts(_ source: String) -> Bool {
            let trimmed = source.trimmingCharacters(in: .whitespacesAndNewlines)
            if trimmed == "self" { return trusted.contains("self") }
            let lowered = trimmed.lowercased()
            guard lowered != "self" else { return false }
            return trusted.contains(lowered)
        }
        public func sourceName(_ source: String) -> String? { names[source] }
        public func doorName(_ id: String) -> String? { doorNames[id] }
    }

    public static var readTrust: @Sendable (URL, [String]) -> TrustRead {
        get { hooks.withLock { $0.readTrust } }
        set { hooks.withLock { $0.readTrust = newValue } }
    }

    public static func attestedPeerID(turn: Turn) -> String? {
        guard let envelope = turn.envelope,
              let id = envelope.verifiedUserId, !id.isEmpty else { return nil }
        let agent = envelope.agent?.trimmingCharacters(in: .whitespacesAndNewlines)
        if let agent, agent == "self" || agent.hasPrefix("bot:") { return nil }
        let surface = ConversationSurfaceProfile(envelope.surface)
        if surface.isAgentBridge { return id }
        guard surface.id == "chat", let agent, !agent.isEmpty else { return nil }
        return id
    }

    public static func trustedTurnCandidates(_ turn: Turn) -> [String] {
        let envelope = TurnEnvelope.current(turn: turn, surface: "")
        return [envelope.agent, turn.origin?.agent, attestedPeerID(turn: turn).map { "peer:" + $0 }]
            .compactMap { $0 }
    }

    public static func trustedTurn(_ turn: Turn, trust: () -> TrustRead) -> Bool {
        let candidates = trustedTurnCandidates(turn)
        guard !candidates.isEmpty else { return false }
        if candidates.contains("self") { return true }
        let read = trust()
        return candidates.contains { read.ownerTrusts($0) }
    }

    public static func trustedTurn(_ turn: Turn) -> Bool {
        let candidates = trustedTurnCandidates(turn)
        guard !candidates.isEmpty else { return false }
        if candidates.contains("self") { return true }
        return trustedTurn(turn, trust: { readTrust(turn.dataRoot, candidates) })
    }

    /// The same principals follow ability writes and error text quoted later.
    public static func abilitySources(turn: Turn) -> [String] {
        let origin = turn.origin
        var sources = (turn.peerSteering?.checkpointSources ?? [])
            + (origin?.peerSources ?? []) + (origin?.elevatedPeerSources ?? [])
        let envelope = TurnEnvelope.current(turn: turn, surface: "")
        if turn.originPrincipal.hasPrefix("agent:") || PeerTurnEffectPolicy.isPeerBridge(surface: envelope.surface) {
            let agent = origin?.agent ?? envelope.agent ?? "another agent"
            if agent != "self", !agent.hasPrefix("bot:") {
                sources.append(attestedPeerID(turn: turn).map { "peer:" + $0 }
                    ?? (["agent", "peer"].contains(agent) ? "another agent" : agent))
            }
        }
        return Array(Set(sources.filter(steers))).sorted()
    }

    public static func abilityWriteCheck(turn: Turn) -> String? { abilityWriteFailure(turn: turn)?.message }

    public static var sourceName: @Sendable (URL, String) -> String? {
        get { hooks.withLock { $0.name } }
        set { hooks.withLock { $0.name = newValue } }
    }

    public static func abilityWriteFailure(turn: Turn) -> ToolFailureError? {
        guard turn.personAct == nil else { return nil }
        let answered = Set(turn.peerSteering?.elevatedSources ?? [])
        let candidates = abilitySources(turn: turn).filter { !answered.contains($0) }
        guard !candidates.isEmpty else { return nil }
        let trust = readTrust(turn.dataRoot, candidates)
        let untrusted = candidates.filter { !trust.ownerTrusts($0) }
        guard !untrusted.isEmpty else { return nil }
        let names = untrusted.map { trust.sourceName($0) }
        let tap = names.allSatisfy { $0 != nil }
            ? names.compactMap { $0 }.map { "Trust > Connected agents > " + $0 }.joined(separator: "; ") : nil
        let who = zip(untrusted, names).map { source, name in name.map { "\($0) [\(source)]" } ?? source }.joined(separator: ", ")
        return CapabilityLifecycle.peerRefusal(who, tap: tap)
    }

    /// Only an untrusted initiating agent or wake sender latches steering. Reading web, mail, files or memory does not.
    /// Trusted helpers, schedules and native work use ordinary Trust gates; unrecognized external forms still steer.
    static func steers(_ source: String) -> Bool { !source.isEmpty && source != "self" && !source.hasPrefix("bot:") }

    /// Resolve every attested locator to its contact so aliases share one principal and one grant.
    public static var principal: @Sendable (URL, String) -> String {
        get { hooks.withLock { $0.principal } }
        set { hooks.withLock { $0.principal = newValue } }
    }

    /// A peer the person elevated retains its identity without taint.
    public func mark(dataRoot: URL, peer: String, line: String = "") {
        let trimmed = peer.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        let name = Self.principal(dataRoot, trimmed)
        guard Self.steers(name) else { return }
        keep(line: line)
        state.withLock { state in
            guard !state.sources.contains(name) else { return }
            state.sources.append(name)
        }
    }

    public var elevatedSources: [String] {
        state.withLock { $0.elevated }
    }

    public func isTainted(trust: () -> TrustRead) -> Bool {
        let answered = state.withLock { $0.elevated }
        let unchecked = checkpointSources.filter { !answered.contains($0) }
        guard !unchecked.isEmpty else { return false }
        let read = trust()
        return unchecked.contains { !read.ownerTrusts($0) }
    }

    public func isTainted(dataRoot: URL) -> Bool {
        let answered = state.withLock { $0.elevated }
        let unchecked = checkpointSources.filter { !answered.contains($0) }
        guard !unchecked.isEmpty else { return false }
        let read = Self.readTrust(dataRoot, unchecked)
        return unchecked.contains { !read.ownerTrusts($0) }
    }

    /// Every steering principal survives carry and resume; trust is never saved.
    public var checkpointSources: [String] {
        return state.withLock { Array(Set($0.sources + $0.elevated)).sorted() }
    }

    public func untrustedSources(trust: () -> TrustRead) -> [String] {
        let sources = checkpointSources
        guard !sources.isEmpty else { return [] }
        let read = trust()
        return sources.filter { !read.ownerTrusts($0) }
    }

    public func sourceDescription(trust: () -> TrustRead) -> String {
        untrustedSources(trust: trust).joined(separator: ", ")
    }

    public func sourceDescription(dataRoot: URL) -> String {
        let sources = checkpointSources
        guard !sources.isEmpty else { return "" }
        return sourceDescription(trust: { Self.readTrust(dataRoot, sources) })
    }
}
