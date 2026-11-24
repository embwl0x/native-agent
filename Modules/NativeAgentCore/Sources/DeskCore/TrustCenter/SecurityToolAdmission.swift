import Foundation
import NativeAgentCore
import PersistenceCore

// Blueprint: | `SecurityToolAdmission.swift` | Exact-call consent carried from the approval membrane to the app dispatcher |

/// An admitted invocation carries its owner's decision, never authority for a nested or changed call.
public struct SecurityToolAdmission: ~Copyable, Sendable {
    private let envelope: SecurityToolEnvelope
    package let input: [String: JSONValue]
    package let turn: Turn
    package let surface: String
    package let tool: String

    package init(envelope: SecurityToolEnvelope, tool: String, input: [String: JSONValue], surface: String, turn: Turn) {
        self.envelope = envelope
        self.tool = tool
        self.input = input
        self.surface = surface
        self.turn = turn
    }

    package func decision(for normalized: [String: JSONValue]) throws -> SecurityToolEnvelope {
        guard input == normalized else {
            throw ToolFailureError("The consent decision belongs to a different call. This call did not run.", effects: .none,
                owner: "tool admission", code: "tool_admission_mismatch", instruction: "Submit the changed call through its originating app door.")
        }
        return envelope
    }
}
