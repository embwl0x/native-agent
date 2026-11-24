import Foundation
import NativeAgentShared
import PersistenceCore
import Synchronization
// Blueprint: | `OwnerAttentionPolicy.swift` | One owner-attention policy from approvals, Desk waits and inbox choices |

// MARK: - OwnerAttentionPolicy — the ONE answer to "does the agent need User?"

/// Every surface shares canonical consent, owner-wait and inbox-choice evidence.
/// Generic blockage never proves the person must act; memory review belongs to the agent.
public enum OwnerAttentionPolicy {
    private static let genericOwnerNames: Set<String> = ["owner", "user", "human"]

    /// Only pending person approvals require attention, never the agent's own decisions.
    public static func approvalWaits(status: String, agentOwned: Bool) -> Bool {
        !agentOwned && status.lowercased() == "pending"
    }

    public static func canonicalWaitingOn(_ raw: String, dataRoot: URL) -> String {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        return matchesOwner(trimmed, dataRoot: dataRoot) == true ? "owner" : trimmed
    }

    public static func waitsOnOwner(_ item: DeskItem) -> Bool {
        waitsOnOwner(item, dataRoot: PersistenceCore.defaultDataRoot()) == true
    }

    public static func waitsOnOwner(_ item: DeskItem, dataRoot: URL) -> Bool? {
        guard !item.status.isTerminal, let waitingOn = item.waitingOn else { return false }
        return matchesOwner(waitingOn, dataRoot: dataRoot)
    }

    private static func matchesOwner(_ waitingOn: String, dataRoot: URL) -> Bool? {
        let party = waitingOn.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard !party.isEmpty else { return false }
        if genericOwnerNames.contains(party) { return true }
        return OwnerName.shared.matches(party, dataRoot: dataRoot)
    }

    /// Unresolved cards need a real choice beyond reading or filing; informational notices do not wait on the person.
    public static func inboxAsks(pending: Bool, systemLane: Bool, severity: String, linkedApproval: Bool,
                                 actionIDs: [String]) -> Bool {
        guard pending, !systemLane, severity.lowercased() != "info" else { return false }
        return linkedApproval
            || actionIDs.contains { !["view", "read", "archive", "dismiss"].contains($0.lowercased()) }
    }
}

private final class OwnerName: Sendable {
    static let shared = OwnerName()
    private let cached = Mutex<[URL: Set<String>]>([:])

    func matches(_ party: String, dataRoot: URL) -> Bool? {
        let root = dataRoot.standardizedFileURL.resolvingSymlinksInPath()
        return cached.withLock { roots in
            if let names = roots[root] { return names.contains(party) }
            let url = root.appendingPathComponent("memory/profile.json")
            guard let data = try? Data(contentsOf: url),
                  let profile = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let userName = profile["userName"] as? String else { return nil }
            let full = userName.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
            guard let first = full.split(whereSeparator: \.isWhitespace).first else { return nil }
            let names: Set<String> = [full, String(first)]
            roots[root] = names
            return names.contains(party)
        }
    }
}
