import Foundation
import PersistenceCore

/// Presentation identity only. Routes, credentials and original sessions stay separate.
public struct AgentContactIdentity: Sendable {
    public let aliases: [String: String]
    public let doors: [String: String]

    public init(dataRoot: URL) {
        var aliases = ["claude": "claude", "codex": "codex"]
        var doors = ["claude": "Claude CLI", "codex": "Codex bridge"]
        if let data = try? Data(contentsOf: dataRoot.appendingPathComponent("agents/peers.json")),
           let peers = try? JSONSerialization.jsonObject(with: data) as? [[String: Any]] {
            for peer in peers {
                guard let id = peer["id"] as? String, let endpoint = peer["endpoint"] as? String,
                      let url = URL(string: endpoint), ["mcp", "acp"].contains(url.scheme ?? "") else { continue }
                let brain: String?
                switch url.host {
                case "claude-desktop", "claude-code": brain = "claude"
                case "codex", "codex-cli": brain = "codex"
                default: brain = nil
                }
                if let brain {
                    aliases["peer:" + id] = brain
                    doors["peer:" + id] = (peer["name"] as? String ?? url.host ?? "") + (url.scheme == "acp" ? " (ACP)" : " (MCP)")
                }
            }
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
    public var status: String
    public var detail: String
    public var checkedAt: Date
    public var authenticated: Bool
    public var failureOperation: String?
    public var brokenSince: Date?
    public var lastGoodAt: Date?
    public var repairAttemptedAt: Date?
    public var repairDetail: String?
    public var repairFor: String?

    public init(status: String, detail: String, checkedAt: Date, authenticated: Bool) {
        self.status = status; self.detail = detail; self.checkedAt = checkedAt; self.authenticated = authenticated
    }

    public static func url(_ root: URL) -> URL { root.appendingPathComponent("agents/local-health.json") }
    public static func read(_ root: URL) -> [String: Self] {
        guard let data = try? Data(contentsOf: url(root)) else { return [:] }
        return (try? JSONDecoder().decode([String: Self].self, from: data)) ?? [:]
    }
    public var current: Bool { brokenSince != nil || status == "unverified" || Date().timeIntervalSince(checkedAt) < 600 }
    public var word: String? {
        guard current else { return nil }
        let text = status.replacingOccurrences(of: "_", with: " ")
        return text.prefix(1).uppercased() + text.dropFirst()
    }
    public var problem: String? {
        current && !["ready", "live", "unchecked"].contains(status)
            ? detail + (repairDetail.map { " " + $0 } ?? "") : nil
    }

    public var projection: JSONValue {
        let iso = ISO8601DateFormatter()
        return .object(["status": .string(status), "detail": .string(problem ?? detail),
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
        let last = observations.filter { $0.brokenSince == nil && $0.status != "unverified" }.map(\.checkedAt).min()
            ?? (observations.isEmpty ? .distantPast : now)
        return max(now.addingTimeInterval(30), last.addingTimeInterval(300))
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
