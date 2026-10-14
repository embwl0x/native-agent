import Foundation
import AppKit
import ChromeControl
import PersistenceCore

typealias ChromeExtensionFolder = ChromeControl.ChromeExtensionFolder

/// The Chrome extension ships inside the app bundle, and Chrome's "Load
/// unpacked" picker cannot browse into an app bundle: a person on a fresh
/// install could not find the folder at all. So the app keeps a plain copy in
/// the home folder, where every file picker starts, and points people at that.
///
/// The manifest carries a fixed `key`, so the extension keeps the same identity
/// wherever it is loaded from and the native messaging host still accepts it.
extension ChromeExtensionFolder {
    struct SetupResult: Sendable {
        let folder: URL?
        let extensionsPageOpened: Bool
        let message: String
    }

    /// Shared by Trust and conversational setup. Preparation is not installation:
    /// Chrome still owns accepting an unpacked extension and its permissions.
    @MainActor
    static func setUp() async -> SetupResult {
        guard let folder = prepare() else {
            return SetupResult(folder: nil, extensionsPageOpened: false,
                message: "This app is missing complete Chrome extension files. Install a release that includes the extension.")
        }
        NSWorkspace.shared.activateFileViewerSelecting([folder])
        guard let chrome = NSWorkspace.shared.urlForApplication(withBundleIdentifier: "com.google.Chrome"),
              let extensions = URL(string: "chrome://extensions") else {
            return SetupResult(folder: folder, extensionsPageOpened: false,
                message: "Google Chrome was not found. The extension folder is ready at \(folder.path).")
        }
        let opened: Bool = await withCheckedContinuation { continuation in
            NSWorkspace.shared.open([extensions], withApplicationAt: chrome,
                configuration: NSWorkspace.OpenConfiguration()) { _, error in
                continuation.resume(returning: error == nil)
            }
        }
        return SetupResult(folder: folder, extensionsPageOpened: opened,
            message: opened
                ? "Extension folder ready. Turn on Chrome's Developer mode, choose Load unpacked and select \(folder.path). Then check Chrome connection status. No permissions were changed."
                : "Extension folder ready at \(folder.path), but Chrome could not open its extensions page. Open chrome://extensions to load it. No permissions were changed.")
    }
}
