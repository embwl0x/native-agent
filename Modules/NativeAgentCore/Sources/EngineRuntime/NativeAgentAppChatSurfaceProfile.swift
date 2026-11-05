import Foundation
// Blueprint: | `NativeAgentAppChatSurfaceProfile.swift` | `NativeAgentAppChatSurfaceProfile` enum |

/// Share construction policy across production surfaces; SecurityCenter, TrustCenter and the gated dispatcher retain authority.
public enum NativeAgentAppChatSurfaceProfile: String, CaseIterable, Sendable {
    case mac
    case slack
    case telegram
    case ios
    case bridge
    case background

    /// Internal turns cannot manufacture approval requests without a user at the trigger.
    public var filesApprovalsByDefault: Bool { self != .background }
}
