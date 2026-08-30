import Foundation

/// Canonical construction policy for every production chat execution surface.
/// Authority remains with SecurityCenter, TrustCenter, and the gated dispatcher.
enum NativeAgentAppChatSurfaceProfile: String, CaseIterable, Sendable {
    case mac
    case slack
    case telegram
    case ios
    case bridge
    case background

    var includesEvolutionBridge: Bool {
        switch self {
        case .mac, .bridge: true
        case .slack, .telegram, .ios, .background: false
        }
    }

    /// No-human-at-trigger execution cannot reach third-party MCP effects.
    /// Native tools still pass through their ordinary TrustCenter/autonomy gates.
    var deniesExternalMCP: Bool {
        switch self {
        case .bridge, .background: true
        case .mac, .slack, .telegram, .ios: false
        }
    }

    /// Scheduled/internal turns may use already-authorized read paths, but they
    /// must not manufacture a new approval request without a user at the trigger.
    var filesApprovalsByDefault: Bool { self != .background }

    /// Tool-loop budget override. Bridge turns are Claude↔Agent delegation
    /// marathons (dispatch, audit, merge, restart in one turn) — 60 kept
    /// exhausting mid-pipeline and dropping tail steps (User, 2026-08-27).
    /// Other surfaces keep their ToolLoopBudget defaults.
    var toolLoopMaxIterations: Int? { self == .bridge ? 180 : nil }

    /// Whole-turn wall-clock budget override (seconds). The bridge runs
    /// delegation marathons under surface "chat", whose interactive 180s
    /// ceiling (A6, 2026-08-27) cut a healthy 24-dispatch codex fan-out at
    /// 188s the day it shipped. Unattended tier for the bridge only.
    var turnWallClockSeconds: TimeInterval? { self == .bridge ? 3_900 : nil }
}
