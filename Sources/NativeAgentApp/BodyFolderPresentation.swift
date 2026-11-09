import EngineRuntime
import Connectors
import Foundation
import SchedulerExecution
import NativeAgentCore
import PersistenceCore
import MacControl
import AttentionRouting
import AppKit
import NativeAgentShared
import SwiftUI
// Blueprint: | `BodyFolderPresentation.swift` | Cancellable native shared-folder selection for body presentation calls |

@MainActor enum ConnectorPresentation {
    static func chooseSharedFolder(operation: UUID) async throws -> FaceReply {
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
        let grant = try await resourceGrant(id: operation, folder: folder, writable: writable.state == .on)
        return .folder(.init(label: label.isEmpty ? folder.lastPathComponent : label, resource: grant, writable: writable.state == .on))
    }

    @concurrent nonisolated private static func resourceGrant(id: UUID, folder: URL, writable: Bool) async throws -> ResourceGrant {
        .init(id: id, name: folder.lastPathComponent,
            bookmark: try folder.bookmarkData(), writable: writable)
    }
}
