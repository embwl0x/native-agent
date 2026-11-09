import CognitiveSubstrate
import ChatTurnContracts
import Foundation
import NativeAgentCore
import NativeAgentShared
import PersistenceCore
import Senses
// Blueprint: | `MemoryDataProvenance.swift` | `MemoryDataProvenance` builds a write's root from the stem and reads the steer from roots; `MemoryWriteContext` holds the turn, sense reads and telling |

/// One write's evidence owners and what its writer states. A caller outside any turn says so explicitly; a later database/settlement closure holds
/// these same owners.
public struct MemoryWriteContext: Sendable {
    public let turn: Turn?
    public let senseReads: SenseTurnReads?
    /// What the writer states about this telling; the store adds the time it was written and the principals the stem attests. Nil is a write that
    /// adds no root of its own (an acceptance, a pin, a lifecycle or repair edit); new words with no telling are refused, never guessed.
    public let telling: MemoryRoot.Telling?
    /// Principals behind material the stem itself attests outside a turn.
    let material: [String]?
    let writtenAt: Date

    public init(turn: Turn?, senseReads: SenseTurnReads?, telling: MemoryRoot.Telling?) {
        self.turn = turn
        self.senseReads = senseReads
        self.telling = telling
        self.material = nil
        self.writtenAt = Date()
    }

    /// A write outside any turn whose material the stem attests, such as a night's lesson: through names that material's principals.
    public init(material: [String], telling: MemoryRoot.Telling) {
        self.turn = nil
        self.senseReads = nil
        self.telling = telling
        self.material = material
        self.writtenAt = Date()
    }

    /// The principals the stem attests for this write.
    public var through: [String] { material ?? MemoryDataProvenance.through(turn: turn) }

    /// The one root this write adds, built by the stem whatever the writer states. A write of words that states no telling is refused.
    public func root() throws -> MemoryRoot {
        guard let telling else {
            throw ToolFailureError("""
                These words state no way they came to be known, so nothing was written; a root is never guessed.
                """, effects: .none, owner: "memory store", code: "memory_telling_missing", status: .failed,
                instruction: "The writer states how the words came to be known before saving them.")
        }
        return rooting(telling)
    }

    /// The root one telling becomes in this write: the stem's principals and the write's time, a steering principal's telling when one steered.
    public func rooting(_ telling: MemoryRoot.Telling) -> MemoryRoot {
        MemoryDataProvenance.root(telling, through: through, turnSteers: material == nil, at: writtenAt)
    }

    /// The writer restates the agent's own past, and the stem kept it as stated: remembered, or dated before the write.
    public var restatesOwnPast: Bool {
        guard let telling else { return false }
        let root = rooting(telling)
        return root.how == .remembered || root.at != NativeTimestampFormat.fractionalZulu(writtenAt)
    }

    /// The write's metadata holding exactly its own root; roots the writer supplied are never taken.
    func stamping(_ metadata: JSONValue?) throws -> JSONValue? {
        MemoryRoot.setting([try root()], in: try MemorySenseProvenance.stamping(metadata, reads: senseReads))
    }
}

/// A memory's steer is derived from its roots: the union of their `through`, read against the person's live trust. Reading stays allowed; only later
/// effects use the turn's usual gates.
public enum MemoryDataProvenance {
    public typealias TrustRead = PeerDataTaint.TrustRead
    /// The principal an unreadable record of roots reads as: its words are never read as clean.
    public static let unreadableRoots = "unreadable memory roots"

    /// The person's calendar, the one the age tag reads: a root's date.
    public static var calendar: Calendar { MemoryRoot.calendar(in: .current) }

    public static func presentation(_ text: String, metadata: JSONValue?, trust: PeerDataTaint.TrustRead? = nil) -> String {
        MemoryDisplayText.attributed(text, sources: sources(in: metadata, trust: trust))
    }

    /// One owner read for a whole page, recall, context or export pass; every root and contact name in it sees the same live picture.
    public static func reading(_ metadata: [JSONValue?], principals: [String] = []) -> PeerDataTaint.TrustRead {
        PeerDataTaint.readTrust(metadata.flatMap { recorded(in: $0) } + principals)
    }

    /// The principals the stem attests for a turn: its checkpoint sources and the agent bridge's peer, trusted and card-answered ones included:
    /// the record never depends on trust. A turn with no steering, origin or envelope attests none.
    public static func through(turn: Turn?) -> [String] {
        guard let turn, turn.peerSteering != nil || turn.origin != nil || turn.envelope != nil else { return [] }
        var sources = turn.peerSteering?.checkpointSources ?? []
        if turn.envelope?.surface == "agent-bridge" {
            let peer = turn.envelope?.verifiedUserId.map { "peer:" + $0 } ?? "another agent"
            if !sources.contains(peer) { sources.append(peer) }
        }
        return sources
    }

    /// The principals among these that steer now. Trust is read live, never saved: a door the person trusts steers nothing, and revoking it brings
    /// its recorded steer back.
    public static func steering(_ principals: [String], trust: PeerDataTaint.TrustRead? = nil) -> [String] {
        let trust = trust ?? PeerDataTaint.readTrust(principals)
        return principals.filter { !trust.ownerTrusts(trust.principal($0)) }
    }

    /// Every principal any root records, trusted or not. Unreadable roots read as one principal nobody trusts.
    static func recorded(in metadata: JSONValue?) -> [String] {
        switch MemoryRoot.reading(metadata) {
        case .held(let roots):
            var principals: [String] = []
            for principal in roots.flatMap(\.through) where !principals.contains(principal) { principals.append(principal) }
            return principals
        case .unreadable: return [unreadableRoots]
        }
    }

    /// The principals that steer these words now.
    public static func sources(in metadata: JSONValue?, trust: PeerDataTaint.TrustRead? = nil) -> [String] {
        steering(recorded(in: metadata), trust: trust)
    }

    /// Whether this one root steers its words now.
    public static func steers(_ root: MemoryRoot, trust: PeerDataTaint.TrustRead? = nil) -> Bool { !steering(root.through, trust: trust).isEmpty }

    /// The tool-output projection of a memory's steer, computed from its roots and never stored.
    public static func fields(in metadata: JSONValue?, trust: PeerDataTaint.TrustRead? = nil) -> [String: JSONValue] {
        fields(steeredBy: sources(in: metadata, trust: trust))
    }

    /// The same projection over principals already read as steering.
    public static func fields(steeredBy sources: [String]) -> [String: JSONValue] {
        guard !sources.isEmpty else { return ["peer_sources": .array([])] }
        return ["untrusted_remote_data": .bool(true), "peer_sources": .array(sources.map(JSONValue.string)),
                "agent": .string(sources.joined(separator: ", ")), "source_boundary": .bool(true)]
    }

    /// The root a write adds. Words a turn steered by a principal the person does not trust are that principal's telling, dated when it told
    /// them, whatever the writer states; material the stem attests outside a turn records its principals and steers no telling.
    static func root(_ telling: MemoryRoot.Telling, through: [String], turnSteers: Bool, at written: Date) -> MemoryRoot {
        if turnSteers, let teller = steering(through).first { return told(by: teller, through: through, at: written) }
        let at = NativeTimestampFormat.fractionalZulu(telling.since ?? written)
        return MemoryRoot(how: telling.how, by: telling.by.flatMap(MemoryRoot.validName), at: at,
                          written: NativeTimestampFormat.fractionalZulu(written), through: through)
    }

    /// How a root reads now. A root an agent the person does not trust steers reads as that agent's telling, by its live contact name, whatever
    /// how and by it stores: never as someone else's words or the agent's own past. Material that is no agent (a dream's unattributed material,
    /// untrusted stored content) keeps the root's own words; its steer reads through the memory's "from" mark. A told root naming no teller
    /// reads by the contact of the peer that carried it.
    public static func presented(_ root: MemoryRoot, trust: PeerDataTaint.TrustRead? = nil) -> MemoryRoot {
        let trust = trust ?? PeerDataTaint.readTrust(root.through)
        if let teller = steering(root.through, trust: trust).first(where: { !material.contains($0) }) {
            // A telling an untrusted agent carried is dated when the store wrote it; its stated time stays underneath.
            return MemoryRoot(how: .told, by: tellerName(teller, trust: trust), at: root.written, written: root.written, through: root.through)
        }
        if root.how == .told, root.by == nil, let peer = root.through.first(where: { $0.hasPrefix("peer:") }),
           let name = trust.sourceName(peer).flatMap(MemoryRoot.validName) {
            return MemoryRoot(how: .told, by: name, at: root.at, written: root.written, through: root.through)
        }
        return root
    }

    /// Steering principals that are no agent: they mark words untrusted without being anyone who told them.
    static let material: Set<String> = ["unattributed dream material", "untrusted stored content", unreadableRoots]

    /// A steering principal as a teller: its contact's name, or, when no contact names it, an agent the person does not trust.
    static func tellerName(_ principal: String, trust: PeerDataTaint.TrustRead) -> String {
        let contact = trust.sourceName(principal) ?? trust.sourceName(trust.principal(principal))
        return contact.flatMap(MemoryRoot.validName) ?? "an agent I don't trust"
    }

    /// A principal's telling, dated when it told it: by its contact name, through as attested.
    static func told(by principal: String, through: [String], at written: Date) -> MemoryRoot {
        let name = PeerDataTaint.sourceName(principal) ?? principal
        let stamp = NativeTimestampFormat.fractionalZulu(written)
        return MemoryRoot(how: .told, by: MemoryRoot.validName(name), at: stamp, written: stamp, through: through)
    }

    /// The person told the agent: told, by the person's name from the memory profile, its one owner. An unreadable or unnamed profile leaves by
    /// out and is logged; never another name.
    /// The person's telling when the profile names no one: the root holds the fact; the name is presentation.
    public static let unnamedPerson = "the person"

    public static func toldByPerson(dataRoot: URL) -> MemoryRoot.Telling {
        do {
            guard let name = try MemoryRecallQueryExpansion.names(storeDirectory: dataRoot.appendingPathComponent("memory")).user else {
                nativeLog("Memory root: the person's name is not recorded in the memory profile; the root says told by the person")
                return MemoryRoot.Telling(how: .told, by: unnamedPerson)
            }
            guard let valid = MemoryRoot.validName(name) else {
                nativeLog("Memory root: the person's recorded name is not a root name; the root says told by the person")
                return MemoryRoot.Telling(how: .told, by: unnamedPerson)
            }
            return MemoryRoot.Telling(how: .told, by: valid)
        } catch {
            nativeLog("Memory root: the memory profile could not be read (%@); the root says told by the person", error.localizedDescription)
            return MemoryRoot.Telling(how: .told, by: unnamedPerson)
        }
    }

    /// When the agent first knew it: the earliest root's time; nil when the roots cannot be read.
    public static func firstKnown(_ metadata: JSONValue?, trust: PeerDataTaint.TrustRead? = nil) -> String? {
        guard case .held(let roots) = MemoryRoot.reading(metadata) else { return nil }
        let trust = trust ?? reading([metadata])
        return MemoryRoot.firstKnown(roots.map { presented($0, trust: trust) })?.at
    }

    /// One entry per root, as the page and tool results show them; unreadable roots are one entry saying so.
    public static func rootsJSON(_ metadata: JSONValue?, calendar: Calendar = MemoryDataProvenance.calendar,
                                 trust: PeerDataTaint.TrustRead? = nil) -> JSONValue {
        let trust = trust ?? reading([metadata])
        switch MemoryRoot.reading(metadata) {
        case .held(let roots):
            // Every field reads as the root reads now: a steering root's how and by are its steering agent's telling, as its line says.
            return .array(MemoryRoot.ordered(roots).map { root in
                let shown = presented(root, trust: trust)
                return .object(["line": .string(shown.line(calendar: calendar)), "how": .string(shown.how.rawValue),
                                "by": shown.by.map(JSONValue.string) ?? .null, "at": .string(shown.at), "steered": .bool(steers(root, trust: trust))])
            })
        case .unreadable(let reason):
            return .array([.object(["line": .string("Where this came from can't be read: \(reason)"), "how": .null, "by": .null, "at": .null,
                                    "steered": .bool(true)])])
        }
    }

    /// The short form a recall hit carries: one to three roots, or the earliest, the latest and how many more.
    public static func lead(_ metadata: JSONValue?, calendar: Calendar = MemoryDataProvenance.calendar,
                            trust: PeerDataTaint.TrustRead? = nil) -> String {
        let trust = trust ?? reading([metadata])
        switch MemoryRoot.reading(metadata) {
        case .held(let roots): return MemoryRoot.lead(of: roots.map { presented($0, trust: trust) }, calendar: calendar) ?? ""
        case .unreadable(let reason): return "where this came from can't be read: \(reason)"
        }
    }

    static func author(surface: String, peer: Bool) -> String {
        surface == "studio_wander" ? "app" : peer ? "peer" : "user"
    }

    /// Use the store's evidence and temporal keys so exchange, speaker and supporting words remain canonical.
    public static func sourceMetadata(sessionId: String?, messageId: String?, turnId: String?, at: Date,
                                      speaker: String, words: String?) -> [String: JSONValue] {
        var evidence: [String: JSONValue] = ["speaker": .string(speaker)]
        if let sessionId { evidence["session_id"] = .string(sessionId) }
        if let messageId { evidence["message_id"] = .string(messageId) }
        if let turnId { evidence["turn_id"] = .string(turnId) }
        let words = MemoryTextClip.wordClip((words ?? "").trimmingCharacters(in: .whitespacesAndNewlines), cap: 400)
        if !words.isEmpty { evidence["words"] = .string(words) }
        return ["evidence": .object(evidence), "observed_at": .string(at.ISO8601Format()),
                "valid_from": .string(at.ISO8601Format())]
    }

    /// Stamp the exact kept turn and transcript locator across moments, corrections and committed memories so collapsed repeats retain their own origin.
    public static func turnMetadata(turnId: String?, origin: AfterTurnOrigin?) -> [String: JSONValue] {
        var meta: [String: JSONValue] = [:]
        if let turnId { meta["turn_id"] = .string(turnId) }
        guard let origin else { return meta }
        meta["session_id"] = .string(origin.sessionId)
        if let runId = origin.runId { meta["run_id"] = .string(runId) }
        meta["history"] = .string("history:" + origin.messageId)
        meta["turn_at"] = .string((origin.occurredAt ?? Date()).ISO8601Format())
        return meta
    }

    /// Calendar-day key (local zone) used by the REM evidence owner.
    public static func dayKey(_ instant: Date, calendar: Calendar = .current) -> String {
        let parts = calendar.dateComponents([.year, .month, .day], from: instant)
        return String(format: "%04d-%02d-%02d", parts.year ?? 0, parts.month ?? 0, parts.day ?? 0)
    }

    public static func parseTimestamp(_ raw: String?) -> Date? {
        guard let raw, !raw.isEmpty else { return nil }
        return NativeTimestampFormat.parseISO8601FractionalFirst(raw)
    }

    /// Words only, single-spaced, lowercase: a copied span with a comma added or a period dropped is still the same span.
    static func wordFold(_ text: String) -> String {
        text.lowercased()
            .split { !$0.isLetter && !$0.isNumber }
            .joined(separator: " ")
    }
}

extension MemoryRecord {
    /// When the agent first knew it: the earliest root's time; nil when its roots cannot be read.
    public var firstKnown: String? { MemoryDataProvenance.firstKnown(extras) }
}
