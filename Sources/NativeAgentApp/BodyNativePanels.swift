import AppKit
// Blueprint: | `BodyNativePanels.swift` | Cancellable body-native folder and exclusion panels |

@MainActor enum FaceNativePanel {
    static func choose(_ panel: NSSavePanel) async throws -> NSApplication.ModalResponse {
        try await withTaskCancellationHandler {
            try Task.checkCancellation()
            let result = await panel.begin()
            try Task.checkCancellation()
            return result
        } onCancel: { Task { @MainActor in panel.cancel(nil) } }
    }

    static func confirm(_ alert: NSAlert) async throws -> NSApplication.ModalResponse {
        let host: NSWindow?
        let parent: NSWindow
        if let current = NSApp.keyWindow { parent = current; host = nil }
        else {
            parent = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 440, height: 120),
                styleMask: [.titled], backing: .buffered, defer: false)
            parent.isReleasedWhenClosed = false
            parent.title = "NativeAgent"
            parent.center()
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
