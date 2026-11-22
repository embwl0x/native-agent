import Foundation
// Blueprint: | `ChatToolInvocation.swift` | `ChatToolInvocation`: explicit tool-operation state with owner-declared parts |

/// One tool operation's call stack and injected dependencies. Every dispatch
/// holds this value beside its turn, including through profiles that do not
/// inspect its owner's state. It is never turn authority or ambient context.
public struct ChatToolInvocation: Sendable {
    private var parts: [ObjectIdentifier: any Sendable] = [:]

    public init() {}

    /// Report the durable ID to this dispatch's response owner before beginning follow-up work.
    package var reportCommittedID: (@Sendable (_ tool: String, _ id: String) -> Void)? {
        get { self[CommittedIDPart.self] }
        set { self[CommittedIDPart.self] = newValue }
    }

    package subscript<Part: ToolInvocationPart>(_ part: Part.Type) -> Part.Value {
        get { parts[ObjectIdentifier(part)] as? Part.Value ?? Part.unset }
        set { parts[ObjectIdentifier(part)] = newValue }
    }
}

private enum CommittedIDPart: ToolInvocationPart {
    static let unset: (@Sendable (String, String) -> Void)? = nil
}

/// An owner's state on one tool operation, distinct from state on its turn.
package protocol ToolInvocationPart {
    associatedtype Value: Sendable
    static var unset: Value { get }
}
