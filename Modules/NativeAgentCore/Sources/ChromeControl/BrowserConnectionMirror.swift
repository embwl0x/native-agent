import Foundation
import os

// Blueprint: | `BrowserConnectionMirror.swift` | `BrowserConnectionMirror`: last runtime-published Chrome connection state for synchronous home reads; nil remains unobserved |

/// The Chrome link's connection as the app's runtime last published it, so a
/// reader (the agent's home screen) can say it without dispatching a tool.
/// Nil until the runtime has said anything.
public enum BrowserConnectionMirror {
    private static let value = OSAllocatedUnfairLock<Bool?>(initialState: nil)

    public static func set(connected: Bool) { value.withLock { $0 = connected } }
    public static var connected: Bool? { value.withLock { $0 } }
}
