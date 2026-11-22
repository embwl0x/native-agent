#if os(macOS)
import AppKit
import Foundation
// Blueprint: | `NativePanelPresentation.swift` | macOS shared-folder picker, bookmark grants and cancellable save-panel presentation |

@MainActor public enum ConnectorPresentation {
    public static func chooseSharedFolder(operation: UUID) async throws -> FaceReply {
        let panel = NSOpenPanel()
        panel.title = "Share a folder"
        panel.prompt = "Share Folder"
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.allowsMultipleSelection = false
        panel.canCreateDirectories = false
        panel.resolvesAliases = false
        let name = NSTextField(string: "")
        name.placeholderString = "Folder name (leave blank to use its name)"
        name.setAccessibilityLabel("Shared folder name")
        let writable = NSButton(checkboxWithTitle: "Let me write to it", target: nil, action: nil)
        let accessory = NSStackView(views: [name, writable])
        accessory.orientation = .vertical
        accessory.alignment = .leading
        accessory.spacing = 8
        accessory.frame = NSRect(x: 0, y: 0, width: 360, height: 64)
        name.widthAnchor.constraint(equalToConstant: 360).isActive = true
        panel.accessoryView = accessory
        guard try await FaceNativePanel.choose(panel) == .OK else { return .cancelled }
        try Task.checkCancellation()
        guard let folder = panel.url else {
            throw PartCallError(code: "folder_unavailable", message: "The picker did not return a folder.")
        }
        let label = name.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
        let grant = try await FaceNativePanel.resourceGrant(id: operation, url: folder, writable: writable.state == .on)
        return .folder(.init(label: label.isEmpty ? folder.lastPathComponent : label, resource: grant, writable: writable.state == .on))
    }
}

@MainActor public enum FaceNativePanel {
    public static func choose(_ panel: NSSavePanel) async throws -> NSApplication.ModalResponse {
        // A question never holds Quit: the person can always quit the app while it is open.
        panel.preventsApplicationTerminationWhenModal = false
        return try await withTaskCancellationHandler {
            try Task.checkCancellation()
            let result = await panel.begin()
            try Task.checkCancellation()
            return result
        } onCancel: { Task { @MainActor in panel.cancel(nil) } }
    }

    @concurrent nonisolated public static func resourceGrant(id: UUID, url: URL, writable: Bool) async throws -> ResourceGrant {
        .init(id: id, name: url.lastPathComponent, bookmark: try url.bookmarkData(), writable: writable)
    }
}
#endif
