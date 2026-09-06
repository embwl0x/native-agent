import Foundation

/// Typed Settings destinations keep a Settings link from relying on an
/// incidental view closure. Each destination owns its own availability and
/// eventual operational evidence; this route only promises to open that UI.
enum SlimSettingsNavigationDestination: Hashable, Sendable {
    case pairDevice
    case telegram
    /// ui-simplify 2026-09-02 (Lane A): the setup pages and the old Advanced
    /// tree moved off the sidebar and behind ONE door in Settings. The route
    /// carries the same `SidebarItem` the sidebar used, so a page has exactly
    /// one identity whether it is reached from here, from ⌘K, or from a deep
    /// link — and the destination renders the same view it always did.
    case advanced(SidebarItem)

    enum Content: Hashable, Sendable {
        case macPairing
        case telegramSettings
        case advancedPage(SidebarItem)
    }

    var content: Content {
        switch self {
        case .pairDevice:
            .macPairing
        case .telegram:
            .telegramSettings
        case .advanced(let item):
            .advancedPage(item)
        }
    }
}

enum SlimSettingsPairDeviceLink {
    static let title = "Pair iPhone / iPad"
    static let systemImage = "iphone.and.arrow.right.outward"
    static let accessibilityHint = "Opens secure device pairing setup. A device is not paired until it scans or receives the pairing key."
    static let destination: SlimSettingsNavigationDestination = .pairDevice
}
