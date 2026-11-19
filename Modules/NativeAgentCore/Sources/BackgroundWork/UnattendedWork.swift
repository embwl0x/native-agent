import Experiences
import Foundation
import NativeAgentCore
import NativeAgentShared
import PersistenceCore
import TrustCenter
// Blueprint: | `UnattendedWork.swift` | `UnattendedWork.allowed`: the one admission for work the agent does while nobody is watching |

/// Work the agent starts on its own (part wakes, reflection, resumed turns) needs saved autonomy or a checked Full Mac grant.
/// Partial or damaged policy fails closed and owes its repair.
public enum UnattendedWork {
    public static func allowed(dataRoot: URL) async -> Bool {
        await refusal(dataRoot: dataRoot) == nil
    }

    /// The deciding read supplies its receipt; callers must not interpret every denial as Autonomy being off.
    public static func refusal(dataRoot: URL) async -> JSONValue? {
        let operation = "unattended_work.trust_policy"
        do {
            let snapshot = try SwiftNativeTrustCenter(dataRoot: dataRoot).loadAuthorizationSnapshotChecked()
            let policy = snapshot.policy
            RepairOwed.settle(dataRoot, operation: operation, evidence: .init(source: "trust/policy.json", id: operation))
            if case .bool(true) = policy["enableAutonomy"] ?? .null { return nil }
            if policy["permissionLevel"] == .string("full_mac_os") { return nil }
            let authority = await SwiftNativeSecurityCenter(dataRoot: dataRoot)
                .fullMacYoloAuthority(origin: SecurityOriginContext(surface: "autonomy", source: "unattended_work", isRemote: false),
                    snapshot: snapshot, turn: nil)
            if authority.admitted { return nil }
            return .object(["status": .string("refused"), "reason": .string("autonomy_off"),
                "checker": .string("unattended_work"), "effects": .string("none"),
                "detail": .string("Unattended work did not run: Autonomy is off."),
                "remedy": Repair.why(owner: "Autonomy", tap: "Trust > Autonomy",
                    instruction: "Only the person can turn Autonomy on.")])
        } catch {
            RepairOwed.owe(dataRoot, id: operation, kind: .run, operation: operation,
                owner: "trust/policy.json", words: "Unattended work cannot read Trust authority: \(error.localizedDescription)",
                lever: "Preserve the policy bytes and repair the reported cause. No unattended work was admitted by this read.")
            let failure = error as? ToolFailureError ?? SwiftNativeTrustCenter.policyUnavailable(error.localizedDescription)
            var evidence = failure.failureEvidence(defaultCode: "trust_policy_unavailable")
            evidence["checker"] = .string("unattended_work")
            evidence["detail"] = .string(error.localizedDescription)
            return .object(evidence)
        }
    }
}
