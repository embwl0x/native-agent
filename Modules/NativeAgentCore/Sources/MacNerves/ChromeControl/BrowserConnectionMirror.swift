import Foundation
import Synchronization

// Blueprint: | `BrowserConnectionMirror.swift` | `BrowserConnectionMirror`; Synchronous home reads; nil is unobserved. |

/// Home reads the runtime's last publication without tool dispatch; nil means unobserved.
public enum BrowserConnectionMirror {
    private static let value = Mutex<Bool?>(nil)

    public struct DidChange: NotificationCenter.AsyncMessage {
        public typealias Subject = NSObject
    }
    public static func set(connected: Bool) {
        let changed = value.withLock { previous in
            guard previous != connected else { return false }
            previous = connected
            return true
        }
        if changed { NotificationCenter.default.post(DidChange()) }
    }
    public static var connected: Bool? { value.withLock { $0 } }
}
