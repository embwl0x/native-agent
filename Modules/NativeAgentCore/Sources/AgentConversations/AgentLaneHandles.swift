import Foundation
import PersistenceCore

/// Before contacts carried identity, a lane name stood for a host's contacts
/// by vendor (Claude Code and Claude Desktop were "claude", Codex was
/// "codex") on every install. Now nothing does (docs/agent-communication.md,
/// "Every agent is itself"). Once per launch, an install where a lane really
/// had a reader, a message in its inbox read, keeps that lane as an explicit
/// handle on its host's who, with the host's other doors associated to it.
/// Elsewhere the lane name stands for no one. Grants, keys and proofs are the
/// store's to keep; this writes only `handles` and `who`.
public enum AgentLaneHandles {
    /// The who keeps its agent's own name; the person renames it.
    static let lanes: [(lane: String, inbox: String, hosts: [String])] = [
        ("claude", "claude-bridge/claude-inbox.jsonl", ["claude-code", "claude-desktop"]),
        ("codex", "codex-nativeagent-bridge/codex-inbox.jsonl", ["codex", "codex-cli"]),
    ]

    public static func migrate(dataRoot: URL, bridgeConfigRoot: URL? = nil) throws {
        let root = bridgeConfigRoot ?? InstallPaths.current.bridgeConfigRoot(dataRoot: dataRoot)
        let store = AgentPeerStore(dataRoot: dataRoot)
        var peers = try store.list()
        for lane in lanes {
            let doors = lane.hosts.flatMap { host in
                peers.filter { ["mcp", "acp"].contains($0.endpoint.scheme ?? "") && $0.endpoint.host == host && $0.hostWorkspace == nil }
            }
            // Once: a lane already carried was migrated, and a door connected later is its own who.
            guard !peers.contains(where: { $0.handles?.contains(lane.lane) == true }),
                  hadReader(root.appendingPathComponent(lane.inbox)), var first = doors.first(where: { $0.who == nil }) else { continue }
            first.handles = (first.handles ?? []) + [lane.lane]
            let head = try store.upsert(first)
            for var door in doors where door.id != head.id && door.who == nil && (door.handles ?? []).isEmpty {
                door.who = head.id
                try store.upsert(door)
            }
            peers = try store.list()
        }
    }

    /// The lane's reader marked at least one message in its inbox read.
    static func hadReader(_ inbox: URL) -> Bool {
        guard let handle = try? FileHandle(forReadingFrom: inbox) else { return false }
        defer { try? handle.close() }
        while let chunk = try? handle.read(upToCount: 1 << 20), !chunk.isEmpty {
            for line in chunk.split(separator: UInt8(ascii: "\n")) {
                if let row = try? JSONSerialization.jsonObject(with: line) as? [String: Any], row["read"] as? Bool == true { return true }
            }
        }
        return false
    }
}
