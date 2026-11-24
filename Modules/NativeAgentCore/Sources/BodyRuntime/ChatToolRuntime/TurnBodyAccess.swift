import MindCore
import Foundation
import NativeAgentCore
import PersistenceCore
import SenseCore

// Blueprint: | `TurnBodyAccess.swift` | Session and peer gates shared by turn reach and explicit body expansion |

private enum BodyFieldInvocationPart: ToolInvocationPart {
    static let unset: BodyField? = nil
}

extension ChatToolInvocation {
    var bodyField: BodyField? {
        get { self[BodyFieldInvocationPart.self] }
        set { self[BodyFieldInvocationPart.self] = newValue }
    }
}

package enum TurnBodyAccess {
    package static let withheld: JSONValue = .object(["status": .string("withheld")])
    package static func unavailable(_ cause: String) -> JSONValue {
        .object(["status": .string("unavailable"), "cause": .string(cause)])
    }

    package static func read(_ body: BodyField?, root: URL, turn: Turn, session: String?, joint: String? = nil) async -> JSONValue {
        guard turn.steeringStamp().isEmpty, let session else { return withheld }
        do {
            guard try !SessionConversation.checkedIsHelper(session, dataRoot: root) else { return withheld }
            guard let body else { return unavailable("The Mac body field is closed.") }
            let result = await body.read(root, turn: turn, session: session, joint: joint)
            return turn.steeringStamp().isEmpty ? result : withheld
        } catch { return unavailable(error.localizedDescription) }
    }
}
