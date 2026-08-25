import Foundation

/// The Settings-scene route for Telegram. Keeping this typed makes the
/// integration link participate in the same destination table as pairing,
/// rather than relying on an incidental view closure that can silently drift.
enum SlimSettingsTelegramLink {
    struct Presentation: Equatable, Sendable {
        let title: String
        let systemImage: String
        let accessibilityHint: String
        let destination: SlimSettingsNavigationDestination
    }

    static let presentation = Presentation(
        title: "Telegram",
        systemImage: "paperplane",
        accessibilityHint: "Opens Telegram settings and shows the current bot configuration status.",
        destination: .telegram
    )

    static var title: String { presentation.title }
    static var systemImage: String { presentation.systemImage }
    static var accessibilityHint: String { presentation.accessibilityHint }
    static var destination: SlimSettingsNavigationDestination { presentation.destination }
}
