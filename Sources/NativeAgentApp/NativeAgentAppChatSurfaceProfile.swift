/// Canonical construction policy for every production conversation surface.
/// Authority remains with SecurityCenter, TrustCenter, and the gated dispatcher.
enum NativeAgentAppChatSurfaceProfile: String, CaseIterable, Sendable {
    case mac
    case slack
    case telegram
    case ios
    case bridge

    var includesEvolutionBridge: Bool {
        switch self {
        case .mac, .bridge: true
        case .slack, .telegram, .ios: false
        }
    }

    var deniesExternalMCP: Bool { self == .bridge }
}
