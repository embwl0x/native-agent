import Foundation
// Blueprint: | `ChatToolInvocation.swift` | `ChatToolInvocation`: explicit tool-operation state with owner-declared parts |

/// One tool operation's call stack and injected dependencies. Every dispatch
/// holds this value beside its turn, including through profiles that do not
/// inspect its owner's state. It is never turn authority or ambient context.
public struct ChatToolInvocation: Sendable {
    private var parts: [ObjectIdentifier: any Sendable] = [:]

    public init() {}

    package subscript<Part: ToolInvocationPart>(_ part: Part.Type) -> Part.Value {
        get { parts[ObjectIdentifier(part)] as? Part.Value ?? Part.unset }
        set { parts[ObjectIdentifier(part)] = newValue }
    }
}

/// An owner's state on one tool operation, distinct from state on its turn.
package protocol ToolInvocationPart {
    associatedtype Value: Sendable
    static var unset: Value { get }
}
