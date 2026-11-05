import ApprovalInbox
import Foundation
import NativeAgentCore
import PersistenceCore
import Privacy
import ToolRegistry
import TrustCenter
// Blueprint: | `ApprovalCardPresentation.swift` | Scope comes from approved arguments, never prose. |

public struct ApprovalCardPresentation: Sendable {
    public let primaryLabel: String
    public let scopeLines: [String]

    public init(record: ApprovalRecord) {
        guard let replay = ApprovalExecution.chatToolApprovalReplay(from: record) else {
            primaryLabel = record.action == "agent.acp.connect" ? "Connect" : "Go ahead"
            scopeLines = []
            return
        }
        let call = ToolNameAliases.ranCall(replay.toolName, input: replay.input)
        let tool = ToolNameAliases.canonical(call.tool)
        let effect: ToolClass
        // A saved card's presentation holds no running turn; it cannot borrow the viewer's authority.
        do { effect = try PermissionLaw.toolClass(tool, input: call.input, turn: nil) }
        catch {
            primaryLabel = "Unavailable"
            scopeLines = ["""
                This action's effect could not be read: \(error.localizedDescription). Repair the action catalog and reopen this card before \
                approving it.
                """]
            return
        }
        if tool == "agent_connect", call.input["disconnect"] != .bool(true) {
            primaryLabel = "Connect"
        } else {
            primaryLabel = effect == .send ? "Send it" : "Go ahead"
        }
        // Only known send contracts name recipients. Other tools, missing arguments and reply targets that require a service read stay unnamed.
        let fields: [(String, String)] = switch tool {
        case "mail_send": [("to", "To"), ("cc", "Cc"), ("bcc", "Bcc")]
        case "messages_send": call.input["thread_id"] == nil
            ? [("to", "To")] : [("expected_participants", "Participants")]
        case "agent_message": [("agent", "Agent")]
        default: []
        }
        scopeLines = effect == .send ? fields.compactMap { key, label in
            guard let value = call.input[key], let text = Self.recipientText(value) else { return nil }
            return "\(label): \(text)"
        } : []
    }

    private static func recipientText(_ value: JSONValue) -> String? {
        let text: String
        switch value {
        case .string(let raw): text = raw
        case .array(let values):
            let strings = values.compactMap { value -> String? in
                guard case .string(let text) = value else { return nil }
                return text
            }
            guard strings.count == values.count else { return nil }
            text = strings.joined(separator: ", ")
        default: return nil
        }
        let redacted = NativeAppSecretRedactor.redactText(text)
            .components(separatedBy: .whitespacesAndNewlines).filter { !$0.isEmpty }.joined(separator: " ")
        return redacted.isEmpty ? nil : String(redacted.prefix(160))
    }
}
