import Foundation
// Blueprint: | `HeldHandle.swift` | `HeldHandle`: a Core Foundation or AppKit handle held under a Mutex by the thread that owns it |

/// A run loop, its source or timer, an event tap, an input thread or an observer token, kept in a Mutex's state. The handle is used only by the
/// thread that owns it (or through the thread-safe CF calls that wake it); the Mutex orders who holds it. Swift cannot see that, so the handle crosses
/// as this value.
// Retains CF handles and Foundation observer tokens across their callbacks.
public struct HeldHandle<Value>: @unchecked Sendable {
    public let value: Value
    public init(_ value: Value) { self.value = value }
}
