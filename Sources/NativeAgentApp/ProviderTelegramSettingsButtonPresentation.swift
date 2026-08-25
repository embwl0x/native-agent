import Foundation

/// Truthful feedback for the Provider Settings shortcut to Telegram. A
/// navigation request is not evidence that the Telegram UI is already open,
/// so the copy names the actual coordinator receipt instead.
enum ProviderTelegramSettingsButtonPresentation: Equatable {
    case deliveredToMountedScene
    case queuedForMainScene

    static func presentation(for receipt: NativeAgentNavigationRequestReceipt) -> Self {
        switch receipt {
        case .deliveredToMountedScene:
            .deliveredToMountedScene
        case .queuedForMainScene:
            .queuedForMainScene
        }
    }

    var statusText: String {
        switch self {
        case .deliveredToMountedScene:
            "Telegram settings request delivered to the main window."
        case .queuedForMainScene:
            "Telegram settings will open when the main window is ready."
        }
    }
}
