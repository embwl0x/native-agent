import Foundation
import PersistenceCore

public enum ChromeExtensionFolder {
    public static let requiredFiles = ["manifest.json", "src/background.js", "src/page-agent.js", "src/user-touch.js"]

    public static var bundled: URL? {
        Bundle.main.resourceURL?.appendingPathComponent("NativeAgentChrome", isDirectory: true)
    }

    public static var visible: URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(InstallPaths.current.name("NativeAgent") + " Chrome Extension", isDirectory: true)
    }

    public static func isComplete(_ folder: URL) -> Bool {
        requiredFiles.allSatisfy { FileManager.default.isReadableFile(atPath: folder.appendingPathComponent($0).path) }
    }

    /// Copies the bundled extension to the visible folder when it is missing or
    /// differs from this build's. Returns the folder to show, or nil when this
    /// copy of the app has no complete extension inside it.
    @discardableResult
    public static func prepare() -> URL? {
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
            nativeLog("[chrome] Could not prepare the visible extension folder: %@", error.localizedDescription)
            // The bundled folder still works through Go to Folder.
            return bundled
        }
    }

    /// At launch: only refresh a copy the person already set up, so an app
    /// update reaches Chrome. Never creates the folder unasked. Both shipped
    /// installs share this folder, so only Chrome's registered host refreshes it.
    public static func refreshIfPresent() {
        guard FileManager.default.fileExists(atPath: visible.path),
              ChromeNativeHostRegistration.ownsOrUnclaimed() else { return }
        prepare()
    }
}
