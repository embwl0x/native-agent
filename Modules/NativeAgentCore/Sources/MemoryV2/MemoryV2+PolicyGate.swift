// Reread saved authority at each use so settings take effect on the next turn. Missing keys share TrustCenter defaults; saved damage stays unavailable. Keep
// the reader in MemoryV2 so every consuming module shares it.

import Foundation
import NativeAgentCore
import PersistenceCore
import TrustCenter
// Blueprint: | `MemoryV2+PolicyGate.swift` | `MemoryPolicyGate`: checked saved memory authority |

public enum MemoryPolicyGate {

    /// Synchronous memory readers use TrustCenter's checked snapshot; the typed policy owns missing-field defaults.
    private static func policy(dataRoot: URL?) throws -> TrustMemoryPolicy {
        let root = dataRoot ?? PersistenceCore.defaultDataRoot()
        let snapshot = try SwiftNativeTrustCenter(dataRoot: root).loadAuthorizationSnapshotChecked()
        return try TrustPolicy(policyObject: snapshot.policy).memoryPolicy ?? TrustMemoryPolicy()
    }

    public static func knowledgeGraphEnabled(dataRoot: URL? = nil) throws -> Bool {
        try policy(dataRoot: dataRoot).knowledge_graph_enabled
    }

    /// A disabled mind setting and unreadable storage remain different outcomes.
    public static func knowledgeGraphFailure(dataRoot: URL) -> ToolFailureError? {
        do {
            if try knowledgeGraphEnabled(dataRoot: dataRoot) { return nil }
        } catch let failure as ToolFailureError { return failure }
        catch {
            return ToolFailureError("Memory settings could not be read: \(error.localizedDescription)", effects: .none,
                owner: "trust/policy.json", code: "trust_policy_unavailable",
                instruction: "Repair the saved policy, preserving its bytes.", recovery: .repair)
        }
        return ToolFailureError(knowledgeGraphOffMessage, effects: .none,
            owner: "Knowledge graph",
            nextCall: ToolFailureError.call("app", ["action": .string("setting.set"),
                "args": .object(["setting": .string("memories.knowledge_graph"), "value": .bool(true)])]),
            tap: "Settings ▸ Memory ▸ Knowledge graph",
            code: "knowledge_graph_disabled", status: .refused,
            instruction: "Enable your Knowledge graph in Settings or through setting.set.")
    }

    public static func crossSessionRecallEnabled(dataRoot: URL? = nil) throws -> Bool {
        try policy(dataRoot: dataRoot).cross_session_recall
    }

    /// Trusted facts are accepted immediately; untrusted facts wait for review.
    public static func adaptivePromotionEnabled(dataRoot: URL? = nil) throws -> Bool {
        try policy(dataRoot: dataRoot).adaptive_promotion
    }

    /// Share the disabled-graph reason across tools, rebuilds and readers.
    public static let knowledgeGraphOffMessage =
        "The knowledge graph is off. Enable Settings ▸ Memory ▸ Knowledge graph to build or read it."
}
