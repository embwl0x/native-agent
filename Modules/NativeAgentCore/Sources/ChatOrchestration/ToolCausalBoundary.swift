import Foundation
import NativeAgentCore
import PersistenceCore

/// Pure edge contract between an immediate tool envelope and the canonical
/// domain owner that can later prove what actually happened. This type owns no
/// lifecycle, authority, or state; it only removes repeated name/key decoding
/// from chat, response evidence, and the app-owned consequence bridge.
public enum ToolCausalBoundary {
    public enum MotorDomain: String, Sendable, Equatable, CaseIterable {
        case workshopExecution = "workshop_execution"
        case browser
        case macControl = "mac_control"
        case externalSend = "external_send"
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

    /// Used when a domain owner may have durably recorded an operation before
    /// its client throws and therefore no result envelope is available.
    public static func motorReference(
        tool rawTool: String,
        ownerActionID rawOwnerActionID: String
    ) -> MotorReference? {
        guard let binding = binding(for: rawTool),
              let ownerActionID = normalizedIdentity(rawOwnerActionID) else { return nil }
        return MotorReference(domain: binding.domain, ownerActionID: ownerActionID)
    }

    /// External MCP results are transport evidence, never self-certifying
    /// evidence that an external effect settled. NativeAgent's compatibility
    /// MCP server is excluded because it has no external transport/effect.
    public static func isExternalProtocolTool(_ rawTool: String) -> Bool {
        let normalized = rawTool.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard normalized.hasPrefix("mcp__") else { return false }
        let remainder = normalized.dropFirst("mcp__".count)
        guard let separator = remainder.range(of: "__") else { return false }
        return remainder[..<separator.lowerBound] != "nativeagent-internal"
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
        switch rawTool.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() {
        case "workshop_submit":
            return (.workshopExecution, ["id"])
        case "browser.open_url", "browser_open_url", "browser.open", "browser_open",
             "browser.navigate", "browser_navigate", "navigate_browser":
            return (.browser, ["runId", "run_id", "id"])
        case "mac_focus_app", "mac_quit_app":
            return (.macControl, ["operationId", "operation_id"])
        case "external_send", "slack_post_message", "agentmail_send":
            return (.externalSend, ["approvalId", "approval_id"])
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
