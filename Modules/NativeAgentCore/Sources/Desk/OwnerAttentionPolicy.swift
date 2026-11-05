import NativeAgentShared
import Transcripts
import Foundation
import PersistenceCore
// Blueprint: | `OwnerAttentionPolicy.swift` | One owner-attention policy from approvals, Desk waits and inbox choices |

// MARK: - OwnerAttentionPolicy — the ONE answer to "does the agent need User?"

/// Every surface shares canonical consent, owner-wait and inbox-choice evidence.
/// Generic blockage never proves the person must act; memory review belongs to the agent.
public enum OwnerAttentionPolicy {
    /// Only pending person approvals require attention, never the agent's own decisions.
    public static func approvalWaits(status: String, agentOwned: Bool) -> Bool {
        !agentOwned && status.lowercased() == "pending"
    }

    /// Match an explicit owner prefix or first name on nonterminal waits; another agent's wait is insufficient.
    public static func waitsOnOwner(_ item: DeskItem) -> Bool {
        guard !item.status.isTerminal, let waitingOn = item.waitingOn else { return false }
        let party = String(waitingOn.trimmingCharacters(in: .whitespacesAndNewlines).lowercased().prefix { $0.isLetter })
        guard !party.isEmpty else { return false }
        return ["owner", "user", "human"].contains(party) || party == OwnerName.shared.first()
    }

    /// Unresolved cards need a real choice beyond reading or filing; informational notices do not wait on the person.
    public static func inboxAsks(pending: Bool, systemLane: Bool, severity: String, linkedApproval: Bool,
                                 actionIDs: [String]) -> Bool {
        guard pending, !systemLane, severity.lowercased() != "info" else { return false }
        return linkedApproval
            || actionIDs.contains { !["view", "read", "archive", "dismiss"].contains($0.lowercased()) }
    }
}

/// Cache the onboarding first name for owner-prefix matching; renames take effect after relaunch.
private final class OwnerName: @unchecked Sendable {
    static let shared = OwnerName()
    private let lock = NSLock()
    private var name: String?

    func first() -> String? {
        lock.lock()
        defer { lock.unlock() }
        if let name { return name }
        let url = PersistenceCore.defaultDataRoot().appendingPathComponent("memory/profile.json")
        guard let data = try? Data(contentsOf: url),
              let profile = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let full = profile["userName"] as? String else { return nil }
        let first = String(full.trimmingCharacters(in: .whitespacesAndNewlines).lowercased().prefix { $0.isLetter })
        guard !first.isEmpty else { return nil }
        name = first
        return first
    }
}
