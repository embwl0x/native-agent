import Foundation

/// Canonical construction policy for every production chat execution surface.
/// Authority remains with SecurityCenter, TrustCenter, and the gated dispatcher.
public enum NativeAgentAppChatSurfaceProfile: String, CaseIterable, Sendable {
    case mac
    case slack
    case telegram
    case ios
    case bridge
    case background

    /// Scheduled/internal turns may use already-authorized read paths, but they
    /// must not manufacture a new approval request without a user at the trigger.
    public var filesApprovalsByDefault: Bool { self != .background }
}
