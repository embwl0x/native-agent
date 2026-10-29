import NativeAgentShared
import Transcripts
import Foundation
import PersistenceCore
// Blueprint: | `OwnerAttentionPolicy.swift` | One owner-attention policy from approvals, Desk waits and inbox choices |

// MARK: - OwnerAttentionPolicy — the ONE answer to "does she need User?"

/// Every surface that answers "does she need me?" answers it from HERE.  The definition, stated once. Waiting on him:   - an approval parked at a consent boundary (`approvalWaits`);   - a Desk row whose `waitingOn` names him
/// (`waitsOnOwner`);   - an inbox card that asks him to choose (`inboxAsks`);   - an execution stopped at an approval step with no approval of its own. Memories stay on the Memories page for her review and never wait on him.
/// `WorkOverviewRead` applies these once and every Mac and phone surface reads its Needs you: the Desk, Today, the widget, the Simple card, Living Status, the phone. Her home applies the same rules to the same owners. Blocked = everything
/// else that can't move: CI, a provider, a sibling item, a verification run. Real, worth showing, NOT his to clear.
public enum OwnerAttentionPolicy {
    /// A person's approval waits while pending; the agent's own decisions do not.
    public static func approvalWaits(status: String, agentOwned: Bool) -> Bool {
        !agentOwned && status.lowercased() == "pending"
    }

    /// A nonterminal row whose `waitingOn` starts with the owner: "owner", "user", "human" or his first name. "User: approve the DDL" and "User to unlock the Mac" wait on him; "Claude provenance reply" does not.
    public static func waitsOnOwner(_ item: DeskItem) -> Bool {
        guard !item.status.isTerminal, let waitingOn = item.waitingOn else { return false }
        let party = String(waitingOn.trimmingCharacters(in: .whitespacesAndNewlines).lowercased().prefix { $0.isLetter })
        guard !party.isEmpty else { return false }
        return ["owner", "user", "human"].contains(party) || party == OwnerName.shared.first()
    }

    /// A card asks him while unresolved (reading is not resolving), is not a system-health notice, and offers a choice: a linked approval, or an action beyond reading and filing it. A note that only tells him something (severity info, e.g.
    /// what she decided as boss) never waits.
    public static func inboxAsks(pending: Bool, systemLane: Bool, severity: String, linkedApproval: Bool,
                                 actionIDs: [String]) -> Bool {
        guard pending, !systemLane, severity.lowercased() != "info" else { return false }
        return linkedApproval
            || actionIDs.contains { !["view", "read", "archive", "dismiss"].contains($0.lowercased()) }
    }
}

/// The owner's first name, lowercased, from onboarding's `userName` in `memory/profile.json` under the process data root. Kept once read; a rename shows after relaunch.
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
