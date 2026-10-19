import Foundation
import PersistenceCore

/// Who each saved contact is (docs/agent-communication.md, "Every agent is
/// itself"): its own who, or the who it is explicitly associated with
/// (`who`). A who is known by its first handle, else by `peer:<id>`. Nothing
/// else makes two contacts one: no product, vendor, host or lane name.
public struct AgentContactIdentity: Sendable {
    public let aliases: [String: String]
    public let doors: [String: String]
    let peers: [[String: String]]

    public init(dataRoot: URL) {
        let peers = (try? Data(contentsOf: dataRoot.appendingPathComponent("agents/peers.json")))
            .flatMap { try? JSONSerialization.jsonObject(with: $0) as? [[String: Any]] } ?? []
        self.init(peers: peers.map { $0.compactMapValues { $0 as? String } },
                  handles: Dictionary(peers.compactMap { peer in
                      (peer["id"] as? String).map { ($0, (peer["handles"] as? [String]) ?? []) }
                  }, uniquingKeysWith: { first, _ in first }))
    }

    init(peers: [[String: String]], handles: [String: [String]] = [:]) {
        self.peers = peers
        let byID = Dictionary(peers.compactMap { peer in peer["id"].map { ($0, peer) } }, uniquingKeysWith: { first, _ in first })
        // An association to a contact that no longer exists is no association.
        func who(_ id: String) -> String { byID[id]?["who"].flatMap { byID[$0] == nil ? nil : $0 } ?? id }
        func key(_ who: String) -> String { handles[who]?.first?.lowercased() ?? "peer:" + who }
        var aliases: [String: String] = [:], doors: [String: String] = [:]
        for (id, peer) in byID {
            let whoID = who(id), name = key(whoID)
            if name != "peer:" + id { aliases["peer:" + id] = name }
            if whoID == id { for handle in handles[id] ?? [] { aliases[handle.lowercased()] = name } }
            guard name != "peer:" + id, let url = peer["endpoint"].flatMap(URL.init(string:)) else { continue }
            doors["peer:" + id] = (peer["name"] ?? url.host ?? "") + (url.scheme == "acp" ? " (ACP)" : " (MCP)")
        }
        self.aliases = aliases; self.doors = doors
    }

    public func canonical(_ agent: String) -> String { aliases[agent] ?? agent }
    public func members(_ agent: String) -> [String] {
        let brain = canonical(agent)
        return Array(Set([agent] + aliases.keys.filter { aliases[$0] == brain })).sorted()
    }
    public func owners(_ owner: String) -> [String] {
        members(aliases["peer:" + owner] == nil ? owner : "peer:" + owner).map {
            $0.hasPrefix("peer:") ? String($0.dropFirst(5)) : $0
        }
    }
}

/// Cheap local observations, never transport authority or proof a model will answer.
public struct AgentLocalHealth: Codable, Sendable, Equatable {
    private var observedStatus: String?
    private var observedDetail: String
    private var presence: String? = nil
    private var presenceWords: String? = nil
    private var presenceAt: Date? = nil
    public var presenceStatus: String? {
        presence == "recent_activity" && Date().timeIntervalSince(presenceAt ?? .distantPast) >= 600 ? "waiting" : presence
    }
    public var presenceDetail: String? {
        presence == "recent_activity" && presenceStatus == "waiting" ? "No recent activity from Claude's bridge." : presenceWords
    }
    private var installed: Bool? = nil
    private var authenticationRequired: Bool? = nil
    private var availability: String {
        guard let installed else { return "unchecked" }
        if !installed { return "unavailable" }
        if authenticationRequired == true, !authenticated { return "signed_out" }
        return lastGoodAt == nil ? "installed" : "ready"
    }
    public var status: String {
        get { presenceStatus ?? replyStatus }
        set { observedStatus = newValue }
    }
    public var replyStatus: String { observedStatus ?? availability }
    public var replyDetail: String {
        observedDetail.isEmpty ? (availability == "installed" ? "Installed; no reply proven yet" : availability == "ready" ? "Ready" : "") : observedDetail
    }
    public var detail: String {
        get { presenceDetail ?? replyDetail }
        set { observedDetail = newValue }
    }
    public var checkedAt: Date
    public var authenticated: Bool
    public var failureOperation: String?
    public var brokenSince: Date?
    public var lastGoodAt: Date?
    public var repairAttemptedAt: Date?
    public var repairDetail: String?
    public var repairFor: String?

    private enum CodingKeys: String, CodingKey {
        case observedStatus = "status", observedDetail = "detail"
        case installed, authenticationRequired, checkedAt, authenticated, failureOperation, brokenSince, lastGoodAt, repairAttemptedAt, repairDetail, repairFor
    }

    public init(status: String, detail: String, checkedAt: Date, authenticated: Bool) {
        self.observedStatus = status; self.observedDetail = detail; self.checkedAt = checkedAt; self.authenticated = authenticated
    }

    public mutating func present(_ presence: Self) {
        self.presence = presence.status
        presenceWords = presence.detail
        presenceAt = presence.checkedAt
    }

    public mutating func retainReplyEvidence() {
        guard !sticky, let observedStatus, observedStatus != "unknown" else { return }
        installed = ["ready", "installed", "signed_out"].contains(observedStatus) ? true : observedStatus == "unavailable" ? false : nil
        authenticationRequired = observedStatus == "signed_out" || authenticated
        if !["signed_out", "unavailable"].contains(observedStatus) { observedDetail = "" }
        self.observedStatus = nil
    }

    public static func url(_ root: URL) -> URL { root.appendingPathComponent("agents/local-health.json") }
    public static func read(_ root: URL) -> [String: Self] {
        do { return try checkedRead(root) }
        catch { return ["local-health": Self(status: "unknown", detail: "agents/local-health.json is unreadable; saved observations are unavailable.", checkedAt: Date(), authenticated: false)] }
    }
    public static func checkedRead(_ root: URL) throws -> [String: Self] {
        do {
            return try JSONDecoder().decode([String: Self].self, from: Data(contentsOf: url(root)))
        } catch let error as CocoaError where error.code == .fileReadNoSuchFile { return [:] }
    }
    /// Said until a newer observation replaces it, not only while fresh.
    public var sticky: Bool { brokenSince != nil || ["unverified", "interrupted", "no_reply_by_deadline"].contains(observedStatus ?? "") }
    public var current: Bool { presenceStatus != nil || sticky || Date().timeIntervalSince(checkedAt) < 600 }
    public var word: String? {
        guard current else { return nil }
        let text = status.replacingOccurrences(of: "_", with: " ")
        return text.prefix(1).uppercased() + text.dropFirst()
    }
    public var problemWord: String? {
        guard problem != nil else { return nil }
        let text = (observedStatus ?? availability).replacingOccurrences(of: "_", with: " ")
        return text.prefix(1).uppercased() + text.dropFirst()
    }
    /// A reply path that is broken, as Doctor and the body report count it. An
    /// unverified one (its app, program or recipe changed since the proof) is
    /// not: the next send proves it again.
    public var isBroken: Bool { problem != nil && ["broken", "signed_out", "unavailable"].contains(observedStatus ?? availability) }
    /// Presence words, overlaid live at every read: a state, never a problem.
    public static let presenceStatuses: Set<String> = ["recent_activity", "waiting", "inbound_only"]
    public var problem: String? {
        current && !(["ready", "installed", "live", "unchecked"] + Self.presenceStatuses).contains(observedStatus ?? availability)
            ? observedDetail + (repairDetail.map { " " + $0 } ?? "") : nil
    }

    public var projection: JSONValue {
        let iso = ISO8601DateFormatter()
        return .object(["status": .string(replyStatus), "detail": .string(problem ?? replyDetail),
            "since": brokenSince.map { .string(iso.string(from: $0)) } ?? .null,
            "last_good": lastGoodAt.map { .string(iso.string(from: $0)) } ?? .null,
            "repair_at": repairAttemptedAt.map { .string(iso.string(from: $0)) } ?? .null,
            "repair": repairDetail.map(JSONValue.string) ?? .null])
    }

    /// Auth recovery clears only an auth error, not an unrelated execution failure.
    public func resolves(_ record: AgentConversationRecord) -> Bool {
        guard current, authenticated, checkedAt >= record.updatedAt, record.phase == "attention" else { return false }
        return Self.authenticationFailure(record.receipt)
    }
    public static func authenticationFailure(_ receipt: JSONValue?) -> Bool {
        func matches(_ text: String) -> Bool {
            ["failed to authenticate", "oauth session expired", "not logged in", "signed out", "authentication_required"]
                .contains { text.lowercased().contains($0) }
        }
        if case .string(let text)? = receipt { return matches(text) }
        guard case .object(var fields)? = receipt else { return false }
        if case .array(let jobs)? = fields["jobs"], jobs.count == 1, case .object(let job) = jobs[0] { fields = job }
        if fields["needs_authentication"] == .bool(true) { return true }
        return ["execution_error", "error", "detail", "agent_reply_text", "agent_reply_text_head"].contains { key in
            if case .string(let text)? = fields[key] { return matches(text) }
            return false
        }
    }

    public static func nextRefresh(_ root: URL, now: Date) -> Date {
        let observations = read(root).values
        let last = observations.filter { !$0.sticky }.map(\.checkedAt).min()
            ?? (observations.isEmpty ? .distantPast : now)
        return max(now.addingTimeInterval(30), last.addingTimeInterval(300))
    }
}

/// An agent discovery found on this Mac and offered once (agents/discovery.json,
/// by candidate id). Declines and disconnects hold across program updates.
/// Discovery and disconnect share its file lock; a connection ends the offer.
public struct AgentDiscoveryOffer: Codable, Sendable, Equatable {
    public var name: String
    public var version: String?
    public var offeredAt: Date?
    public var declinedAt: Date?
    public var connectedAt: Date?

    public init(name: String) { self.name = name }

    public static func url(_ root: URL) -> URL { root.appendingPathComponent("agents/discovery.json") }
    /// Empty only when the file is missing; nil when it is there but does not
    /// read, so a damaged file is never written over.
    public static func read(_ root: URL) -> [String: Self]? {
        guard FileManager.default.fileExists(atPath: url(root).path) else { return [:] }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return (try? Data(contentsOf: url(root))).flatMap { try? decoder.decode([String: Self].self, from: $0) }
    }
    public static func write(_ offers: [String: Self], _ root: URL) throws {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.sortedKeys, .prettyPrinted]
        try SwiftNativePersistenceCore.writeDataAtomicDurable(encoder.encode(offers), to: url(root))
    }

    /// Open: offered, and neither declined nor connected since.
    public var open: Bool { offeredAt != nil && declinedAt == nil && connectedAt == nil }
    /// Home's PEOPLE line. An `app:` id is an app no recipe knows: nothing to connect.
    public static func line(id: String, name: String) -> String {
        id.hasPrefix("app:") ? "Found \(name) (no recipe yet) — want me to look?" : "Found \(name) — connect?"
    }
}

/// Exact replies fetched through a pull door. Old fetches without evidence stay unknown.
public enum ContactReplyReads {
    public struct Read: Codable, Sendable {
        public let session: String
        public let request: String
        public let run: String
        public let at: Date
    }
    private static let lock = NSLock()
    public static func url(_ root: URL) -> URL { root.appendingPathComponent("agents/reply-reads.json") }
    public static func read(_ root: URL) -> [Read] {
        guard let data = try? Data(contentsOf: url(root)) else { return [] }
        return (try? JSONDecoder().decode([Read].self, from: data)) ?? []
    }
    public static func record(dataRoot: URL, session: String, request: String, run: String) {
        guard !session.isEmpty, !request.isEmpty, !run.isEmpty else { return }
        lock.withLock {
            do {
                let file = url(dataRoot)
                var rows = FileManager.default.fileExists(atPath: file.path)
                    ? try JSONDecoder().decode([Read].self, from: Data(contentsOf: file)) : []
                guard !rows.contains(where: { $0.session == session && $0.request == request && $0.run == run }) else { return }
                rows.append(Read(session: session, request: request, run: run, at: Date()))
                try SwiftNativePersistenceCore.writeDataAtomicDurable(JSONEncoder().encode(Array(rows.suffix(2048))), to: file)
            } catch { nativeLog("ContactReplyReads: could not retain fetch: %@", error.localizedDescription) }
        }
    }
}
