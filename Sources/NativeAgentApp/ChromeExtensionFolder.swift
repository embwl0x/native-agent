import Foundation
import AppKit
import PersistenceCore

/// The Chrome extension ships inside the app bundle, and Chrome's "Load
/// unpacked" picker cannot browse into an app bundle: a person on a fresh
/// install could not find the folder at all. So the app keeps a plain copy in
/// the home folder, where every file picker starts, and points people at that.
///
/// The manifest carries a fixed `key`, so the extension keeps the same identity
/// wherever it is loaded from and the native messaging host still accepts it.
enum ChromeExtensionFolder {
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
                ? "Extension folder ready. In Chrome, turn on Developer mode, choose Load unpacked and select \(folder.path). Then check Chrome connection status. No permissions were changed."
                : "Extension folder ready at \(folder.path), but Chrome could not open its extensions page. Open chrome://extensions to load it. No permissions were changed.")
    }
    static let requiredFiles = ["manifest.json", "src/background.js", "src/page-agent.js", "src/user-touch.js"]

    static var bundled: URL? {
        Bundle.main.resourceURL?.appendingPathComponent("NativeAgentChrome", isDirectory: true)
    }

    static var visible: URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(InstallPaths.current.name("NativeAgent") + " Chrome Extension", isDirectory: true)
    }

    static func isComplete(_ folder: URL) -> Bool {
        requiredFiles.allSatisfy { FileManager.default.isReadableFile(atPath: folder.appendingPathComponent($0).path) }
    }

    /// Copies the bundled extension to the visible folder when it is missing or
    /// differs from this build's. Returns the folder to show, or nil when this
    /// copy of the app has no complete extension inside it.
    @discardableResult
    static func prepare() -> URL? {
        guard let bundled, isComplete(bundled) else { return nil }
        let fm = FileManager.default
        let destination = visible
        if isComplete(destination), fm.contentsEqual(atPath: bundled.path, andPath: destination.path) { return destination }
        let staging = destination.deletingLastPathComponent()
            .appendingPathComponent("." + destination.lastPathComponent + ".incoming-" + UUID().uuidString, isDirectory: true)
        do {
            try fm.copyItem(at: bundled, to: staging)
            if fm.fileExists(atPath: destination.path) {
                _ = try fm.replaceItemAt(destination, withItemAt: staging)
            } else {
                try fm.moveItem(at: staging, to: destination)
            }
            return destination
        } catch {
            try? fm.removeItem(at: staging)
            NSLog("[chrome] Could not prepare the visible extension folder: %@", error.localizedDescription)
            // The bundled folder still works through Go to Folder.
            return bundled
        }
    }

    /// At launch: only refresh a copy the person already set up, so an app
    /// update reaches Chrome. Never creates the folder unasked.
    static func refreshIfPresent() {
        guard FileManager.default.fileExists(atPath: visible.path) else { return }
        prepare()
    }
}
