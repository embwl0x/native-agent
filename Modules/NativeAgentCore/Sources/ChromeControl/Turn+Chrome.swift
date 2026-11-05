import Foundation
import NativeAgentCore
import TrustCenter
// Blueprint: | `Turn+Chrome.swift` | `Turn` part Chrome control owns: the authority origin of its invocation |

private enum ChromeOriginPart: TurnPart { static let unset: SecurityOriginContext? = nil }

extension Turn {
    /// The authority origin of this Chrome invocation.
    public var chromeOrigin: SecurityOriginContext? {
        get { self[ChromeOriginPart.self] }
        set { self[ChromeOriginPart.self] = newValue }
    }
}
