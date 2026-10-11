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

    /// No-human-at-trigger execution cannot reach third-party MCP effects.
    /// Native tools still pass through their ordinary TrustCenter/autonomy gates.
    public var deniesExternalMCP: Bool {
        switch self {
        case .bridge, .background: true
        case .mac, .slack, .telegram, .ios: false
        }
    }

    /// Scheduled/internal turns may use already-authorized read paths, but they
    /// must not manufacture a new approval request without a user at the trigger.
    public var filesApprovalsByDefault: Bool { self != .background }
}
