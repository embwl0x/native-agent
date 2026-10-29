import AgentWorkspace
import Foundation
import NativeAgentCore
import PersistenceCore
// Blueprint: | `ToolCausalBoundary.swift` | `ToolCausalBoundary` enum; `hasCanonicalMotorOwner`, `motorReference` |

/// Pure edge contract between an immediate tool envelope and the canonical
/// domain owner that can later prove what actually happened. This type owns no
/// lifecycle, authority, or state; it only removes repeated name/key decoding
/// from chat, response evidence, and the app-owned consequence bridge.
public enum ToolCausalBoundary {
    public enum MotorDomain: String, Sendable, Equatable, CaseIterable {
        case workshopExecution = "workshop_execution"
        case browser
        case macControl = "mac_control"
        case agentBridge = "agent_bridge"
    }

    public struct MotorReference: Sendable, Equatable {
        public let domain: MotorDomain
        public let ownerActionID: String
        public let actionIdentity: String

        public init(domain: MotorDomain, ownerActionID: String) {
            self.domain = domain
            self.ownerActionID = ownerActionID
            self.actionIdentity = CausalTransitionEvidence.opaqueIdentity(ownerActionID)
        }
    }

    public static func hasCanonicalMotorOwner(tool rawTool: String) -> Bool {
        binding(for: rawTool) != nil
    }

    public static func motorReference(
        tool rawTool: String,
        output: JSONValue
    ) -> MotorReference? {
        guard case .object(let object) = output else { return nil }
        if case .bool(true)? = object["dryRun"] ?? object["dry_run"] {
            return nil
        }
        return reference(tool: rawTool, object: output)
    }

    private static func reference(tool rawTool: String, object output: JSONValue) -> MotorReference? {
        guard let binding = binding(for: rawTool), case .object(let object) = output else { return nil }
        for key in binding.identityKeys {
            guard case .string(let rawIdentity)? = object[key],
                  let ownerActionID = normalizedIdentity(rawIdentity) else { continue }
            return MotorReference(domain: binding.domain, ownerActionID: ownerActionID)
        }
        return nil
    }

    private static func binding(
        for rawTool: String
    ) -> (domain: MotorDomain, identityKeys: [String])? {
        // A binding requires an actual effect and a canonical owner capable of
        // proving its consequence. Reads and bare cursor movement have no
        // consequence owner.
        switch rawTool.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() {
        case "workshop_submit":
            return (.workshopExecution, ["id"])
        case "browser.open_url", "browser_open_url", "browser.open", "browser_open",
             "browser.navigate", "browser_navigate", "navigate_browser":
            return (.browser, ["runId", "run_id", "id"])
        case "mac_wake", "act", "go":
            return (.macControl, ["operationId", "operation_id"])
        // Builder messages settle asynchronously. The durable bridge job owns
        // the returned message id, which is the exact key used by
        // DelegationStatusProjector and the event-driven outcome loop.
        case "codex_message", "claude_message", "omp_message":
            return (.agentBridge, ["messageId", "message_id"])
        default:
            return nil
        }
    }

    private static func normalizedIdentity(_ raw: String) -> String? {
        let normalized = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !normalized.isEmpty, normalized.utf8.count <= 256 else { return nil }
        return normalized
    }
}
