import Foundation

/// Typed Settings destinations keep a Settings link from relying on an
/// incidental view closure. Each destination owns its own availability and
/// eventual operational evidence; this route only promises to open that UI.
enum SlimSettingsNavigationDestination: Hashable, Sendable {
    case pairDevice
    case telegram

    enum Content: Hashable, Sendable {
        case macPairing
        case telegramSettings
    }

    var content: Content {
        switch self {
        case .pairDevice:
            .macPairing
        case .telegram:
            .telegramSettings
        }
    }
}

enum SlimSettingsPairDeviceLink {
    static let title = "Pair iPhone / iPad"
    static let systemImage = "iphone.and.arrow.right.outward"
    static let accessibilityHint = "Opens secure device pairing setup. A device is not paired until it scans or receives the pairing key."
    static let destination: SlimSettingsNavigationDestination = .pairDevice
}
