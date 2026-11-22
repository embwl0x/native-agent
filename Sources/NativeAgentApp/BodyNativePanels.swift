import AppKit
import NativeAgentShared
// Blueprint: | `BodyNativePanels.swift` | Cancellable body-native confirmation sheets; once its run loop runs the body never runs modal |

/// Once its run loop runs, the body asks through sheets, never through `runModal`: an app-modal session started from a main-actor job
/// freezes every main-actor owner until it is answered, and macOS refuses Quit while it is open, so an unseen question holds the body.
/// Quit ends the question with the body.
@MainActor extension FaceNativePanel {
    static func confirm(_ alert: NSAlert) async throws -> NSApplication.ModalResponse {
        alert.window.preventsApplicationTerminationWhenModal = false
        let host: NSWindow?
        let parent: NSWindow
        if let current = NSApp.keyWindow { parent = current; host = nil }
        else {
            parent = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 440, height: 120),
                styleMask: [.titled], backing: .buffered, defer: false)
            parent.isReleasedWhenClosed = false
            parent.title = "NativeAgent"
            parent.center()
            // The body has no window of its own, so it comes forward with the question it hosts.
            NSApp.activate()
            parent.makeKeyAndOrderFront(nil)
            host = parent
        }
        defer { host?.close() }
        return try await withTaskCancellationHandler {
            try Task.checkCancellation()
            let response = await alert.beginSheetModal(for: parent)
            try Task.checkCancellation()
            return response
        } onCancel: { Task { @MainActor in parent.endSheet(alert.window, returnCode: .cancel) } }
    }
}
