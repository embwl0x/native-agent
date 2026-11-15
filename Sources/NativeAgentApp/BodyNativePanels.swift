import AppKit
// Blueprint: | `BodyNativePanels.swift` | Cancellable body-native panels and questions; once its run loop runs the body never runs modal |

/// Once its run loop runs, the body asks through these, never through `runModal`: an app-modal session started from a main-actor job
/// freezes every main-actor owner until it is answered, and macOS refuses Quit while it is open, so an unseen question holds the body.
/// A question these show never holds Quit either: Quit ends the question with the body.
@MainActor enum FaceNativePanel {
    static func choose(_ panel: NSSavePanel) async throws -> NSApplication.ModalResponse {
        panel.preventsApplicationTerminationWhenModal = false
        return try await withTaskCancellationHandler {
            try Task.checkCancellation()
            let result = await panel.begin()
            try Task.checkCancellation()
            return result
        } onCancel: { Task { @MainActor in panel.cancel(nil) } }
    }

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
