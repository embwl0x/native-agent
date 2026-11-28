import Foundation
import NativeAgentCore
import NativeAgentShared
import PersistenceCore
import SenseCore
// Blueprint: | `MemoryDataProvenance.swift` | `MemoryWriteContext` builds roots from tellings and attested tellers; `MemoryDataProvenance` reads steering and presents each root |

/// One write's evidence owners and what its writer states. A caller outside any turn says so explicitly; a later database/settlement closure holds
/// these same owners.
public struct MemoryWriteContext: Sendable {
    public let turn: Turn?
    public let senseReads: SenseTurnReads?
    /// What the writer states about this telling; the store adds the time it was written and the principals the stem attests. Nil is a write that
    /// adds no root of its own (an acceptance, a pin, a lifecycle or repair edit); new words with no telling are refused, never guessed.
    public let telling: MemoryRoot.Telling?
    public let lifecycle: String?
    /// Principals behind material the stem itself attests outside a turn.
    let material: [String]?
    private let tellers: [String]?
    let writtenAt: Date

    public init(turn: Turn?, senseReads: SenseTurnReads?, telling: MemoryRoot.Telling?, lifecycle: String? = nil) {
        self.init(turn: turn, senseReads: senseReads, telling: telling, lifecycle: lifecycle, tellers: nil)
    }

    package init(turn: Turn?, senseReads: SenseTurnReads?, telling: MemoryRoot.Telling?, lifecycle: String? = nil, tellers: [String]?) {
        self.turn = turn
        self.senseReads = senseReads
        self.telling = telling
        self.lifecycle = lifecycle
        self.material = nil
        self.tellers = tellers
        self.writtenAt = Date()
    }

    /// A write outside any turn whose material the stem attests, such as a night's lesson: through names that material's principals.
    public init(material: [String], telling: MemoryRoot.Telling, lifecycle: String? = nil) {
        self.turn = nil
        self.senseReads = nil
        self.telling = telling
        self.lifecycle = lifecycle
        self.material = material
        self.tellers = nil
        self.writtenAt = Date()
    }

    /// The principals the stem attests for this write.
    public var through: [String] { material ?? MemoryDataProvenance.through(turn: turn) }

    /// A live turn's words: the steer a principal puts on them is today's. Material the stem attests (an archive, a night's lesson) carries its
    /// own dates.
    var turnSteers: Bool { material == nil }

    /// The one root this write adds, built by the stem whatever the writer states. A write of words that states no telling is refused.
    public func root(dataRoot: URL) throws -> MemoryRoot {
        guard let telling else {
            throw ToolFailureError("""
                These words state no way they came to be known, so nothing was written; a root is never guessed.
                """, effects: .none, owner: "memory store", code: "memory_telling_missing", status: .failed,
                instruction: "The writer states how the words came to be known before saving them.")
        }
        return rooting(telling, dataRoot: dataRoot)
    }

    /// The root one telling becomes in this write: the stem's principals and the write's time, a steering principal's telling when one steered.
    public func rooting(_ telling: MemoryRoot.Telling, dataRoot: URL) -> MemoryRoot {
        let through = self.through
        if telling.how == .told, let teller = telling.by, tellers?.contains(teller) == true, through.contains(teller) {
            return attestedRoot(teller, through: through, trust: PeerDataTaint.readTrust(dataRoot, through))
        }
        return MemoryDataProvenance.root(telling, through: through, turnSteers: material == nil, at: writtenAt, dataRoot: dataRoot)
    }

    /// The writer restates the agent's own past, and the stem kept it as stated: remembered, or dated before the write.
    public func restatesOwnPast(dataRoot: URL) -> Bool {
        guard let telling else { return false }
        let root = rooting(telling, dataRoot: dataRoot)
        return root.how == .remembered || root.at != NativeTimestampFormat.fractionalZulu(writtenAt)
    }

    func stamping(_ metadata: JSONValue?, dataRoot: URL) throws -> JSONValue? {
        let roots: [MemoryRoot]
        if let tellers {
            let through = self.through
            guard !tellers.isEmpty, tellers.allSatisfy({ through.contains($0) }) else {
                throw ToolFailureError("Every teller must be attested by this ask.", effects: .none,
                    code: "memory_teller_steered", status: .refused)
            }
            let trust = PeerDataTaint.readTrust(dataRoot, through)
            roots = tellers.map { attestedRoot($0, through: through, trust: trust) }
        } else {
            roots = [try root(dataRoot: dataRoot)]
        }
        return MemoryRoot.setting(roots, in: try MemorySenseProvenance.stamping(metadata, reads: senseReads))
    }

    private func attestedRoot(_ teller: String, through: [String], trust: PeerDataTaint.TrustRead) -> MemoryRoot {
        let stamp = NativeTimestampFormat.fractionalZulu(writtenAt)
        return MemoryRoot(how: .told, by: MemoryDataProvenance.attestedTellerName(teller, trust: trust), at: stamp,
                          written: stamp, through: through, teller: teller)
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

    public static func presentation(_ text: String, metadata: JSONValue?, trust: PeerDataTaint.TrustRead) -> String {
        MemoryDisplayText.attributed(text, sources: sources(in: metadata, trust: trust))
    }

    /// One owner read for a whole page, recall, context or export pass; every root and contact name in it sees the same live picture.
    public static func reading(dataRoot: URL, _ metadata: [JSONValue?], principals: [String] = []) -> PeerDataTaint.TrustRead {
        PeerDataTaint.readTrust(dataRoot, metadata.flatMap { recorded(in: $0) } + principals)
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
    public static func steering(_ principals: [String], trust: PeerDataTaint.TrustRead) -> [String] {
        return principals.filter { !trust.ownerTrusts(trust.principal($0)) }
    }

    public static func steering(_ principals: [String], dataRoot: URL) -> [String] {
        steering(principals, trust: PeerDataTaint.readTrust(dataRoot, principals))
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
    public static func sources(in metadata: JSONValue?, trust: PeerDataTaint.TrustRead) -> [String] {
        steering(recorded(in: metadata), trust: trust)
    }

    static func sources(in metadata: JSONValue?, dataRoot: URL) -> [String] {
        steering(recorded(in: metadata), dataRoot: dataRoot)
    }

    /// Whether this one root steers its words now.
    public static func steers(_ root: MemoryRoot, trust: PeerDataTaint.TrustRead) -> Bool { !steering(root.through, trust: trust).isEmpty }

    /// The tool-output projection of a memory's steer, computed from its roots and never stored.
    public static func fields(in metadata: JSONValue?, trust: PeerDataTaint.TrustRead) -> [String: JSONValue] {
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
    static func root(_ telling: MemoryRoot.Telling, through: [String], turnSteers: Bool, at written: Date, dataRoot: URL) -> MemoryRoot {
        if turnSteers, let teller = steering(through, dataRoot: dataRoot).first {
            return told(by: teller, through: through, at: written, dataRoot: dataRoot)
        }
        let at = NativeTimestampFormat.fractionalZulu(telling.since ?? written)
        return MemoryRoot(how: telling.how, by: telling.by.flatMap(MemoryRoot.validName), at: at,
                          written: NativeTimestampFormat.fractionalZulu(written), through: through)
    }

    public static func presented(_ root: MemoryRoot, trust: PeerDataTaint.TrustRead) -> MemoryRoot {
        if let teller = root.teller {
            let name = attestedTellerName(teller, trust: trust) ?? root.by
            return MemoryRoot(how: .told, by: name, at: root.at, written: root.written, through: root.through, teller: teller)
        }
        if let teller = steering(root.through, trust: trust).first(where: { !material.contains($0) }) {
            // A telling an untrusted agent carried reads as that agent's, at the time the root records: a live turn's root is dated when it was
            // told, an attested record's when it was.
            return MemoryRoot(how: .told, by: tellerName(teller, trust: trust), at: root.at, written: root.written, through: root.through)
        }
        if root.how == .told, root.by == nil, let peer = root.through.first(where: { $0.hasPrefix("peer:") }),
           let name = trust.sourceName(peer).flatMap(MemoryRoot.validName) {
            return MemoryRoot(how: .told, by: name, at: root.at, written: root.written, through: root.through)
        }
        return root
    }

    fileprivate static func attestedTellerName(_ teller: String, trust: PeerDataTaint.TrustRead) -> String? {
        guard teller.hasPrefix("peer:") else { return nil }
        return trust.doorName(String(teller.dropFirst(5))).flatMap(MemoryRoot.validName)
    }

    /// Steering principals that are no agent: they mark words untrusted without being anyone who told them.
    static let material: Set<String> = ["unattributed dream material", "untrusted stored content", unreadableRoots]

    /// A steering principal as a teller: its contact's name, or, when no contact names it, an agent the person does not trust.
    static func tellerName(_ principal: String, trust: PeerDataTaint.TrustRead) -> String {
        let contact = trust.sourceName(principal) ?? trust.sourceName(trust.principal(principal))
        return contact.flatMap(MemoryRoot.validName) ?? "an agent I don't trust"
    }

    /// A principal's telling, dated when it told it: by its contact name, through as attested.
    static func told(by principal: String, through: [String], at written: Date, dataRoot: URL) -> MemoryRoot {
        let name = PeerDataTaint.sourceName(dataRoot, principal) ?? principal
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
    public static func firstKnown(_ metadata: JSONValue?, trust: PeerDataTaint.TrustRead) -> String? {
        guard case .held(let roots) = MemoryRoot.reading(metadata) else { return nil }
        return MemoryRoot.firstKnown(roots.map { presented($0, trust: trust) })?.at
    }

    /// One entry per root, as the page and tool results show them; unreadable roots are one entry saying so.
    public static func rootsJSON(_ metadata: JSONValue?, calendar: Calendar = MemoryDataProvenance.calendar,
                                 trust: PeerDataTaint.TrustRead) -> JSONValue {
        switch MemoryRoot.reading(metadata) {
        case .held(let roots):
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
                            trust: PeerDataTaint.TrustRead) -> String {
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
        NativeTimestampFormat.calendarDay(instant, calendar: calendar)
    }
}
