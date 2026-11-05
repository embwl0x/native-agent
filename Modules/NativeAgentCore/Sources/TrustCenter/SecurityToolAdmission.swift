import Foundation
import NativeAgentCore
import PersistenceCore

// Blueprint: | `SecurityToolAdmission.swift` | Exact-call consent carried from the approval membrane to the app dispatcher |

/// An admitted invocation carries its owner's decision, never authority for a nested or changed call.
package struct SecurityToolAdmission: Sendable {
    package let envelope: SecurityToolEnvelope
    private let input: [String: JSONValue]
    private let turnID: String
    private let sessionID: String?
    private let surface: String
    private let tool: String

    package init(envelope: SecurityToolEnvelope, tool: String, input: [String: JSONValue], surface: String, turn: Turn, sessionID: String?) {
        self.envelope = envelope
        self.tool = tool
        self.input = input
        self.surface = surface
        self.turnID = turn.id
        self.sessionID = sessionID
    }

    package func decision(tool: String, input: [String: JSONValue], surface: String, turn: Turn, sessionID: String?) throws -> SecurityToolEnvelope {
        guard self.tool == tool, self.input == input, self.surface == surface,
              turnID == turn.id, self.sessionID == sessionID else {
            throw ToolFailureError("The consent decision belongs to a different call. This call did not run.", effects: .none,
                owner: "tool admission", code: "tool_admission_mismatch", instruction: "Submit the changed call through its originating app door.")
        }
        return envelope
    }
}

private enum SecurityAdmissionPart: ToolInvocationPart { static let unset: SecurityToolAdmission? = nil }

package extension ChatToolInvocation {
    var securityAdmission: SecurityToolAdmission? {
        get { self[SecurityAdmissionPart.self] }
        set { self[SecurityAdmissionPart.self] = newValue }
    }
}
