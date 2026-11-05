import Experiences
import Foundation
import NativeAgentCore
import NativeAgentShared
import PersistenceCore
import TrustCenter
// Blueprint: | `UnattendedWork.swift` | `UnattendedWork.allowed`: the one admission for work the agent does while nobody is watching |

/// Work the agent starts on its own (part wakes, reflection, self-improvement, resumed turns) needs saved autonomy or a checked Full Mac grant.
/// Partial or damaged policy fails closed and owes its repair.
public enum UnattendedWork {
    public static func allowed(dataRoot: URL) async -> Bool {
        guard let policy = await checkedPolicy(dataRoot: dataRoot) else { return false }
        if case .bool(true) = policy["enableAutonomy"] ?? .null { return true }
        if policy["permissionLevel"] == .string("full_mac_os") { return true }
        return await SwiftNativeSecurityCenter(dataRoot: dataRoot)
            .fullMacYoloAuthority(origin: SecurityOriginContext(surface: "autonomy", source: "unattended_work", isRemote: false), turn: nil)
            .admitted
    }

    /// A boolean admission carries no cause, so an unreadable policy is owed as a repair rather than read as a disabled setting.
    private static func checkedPolicy(dataRoot: URL) async -> [String: JSONValue]? {
        let operation = "unattended_work.trust_policy"
        do {
            let policy = try await SwiftNativeTrustCenter(dataRoot: dataRoot).loadTrustPolicyChecked()
            RepairOwed.settle(dataRoot, operation: operation, evidence: .init(source: "trust/policy.json", id: operation))
            return policy
        } catch {
            RepairOwed.owe(dataRoot, id: operation, kind: .run, operation: operation,
                owner: "trust/policy.json", words: "Unattended work cannot read Trust authority: \(error.localizedDescription)",
                lever: "Preserve the policy bytes and repair the reported cause. No unattended work was admitted by this read.")
            return nil
        }
    }
}
