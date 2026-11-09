import Foundation
import AppKit
import SwiftUI
import NativeAgentShared
// Blueprint: | `AppConnectorPlatform.swift` | Protected account windows and folder presentation requested by the body |

@MainActor enum ProviderSetupWindow {
    private static var controllers: [String: NSWindowController] = [:]
    static func closeAll() {
        let shown = controllers.values
        controllers.removeAll()
        for controller in shown { controller.close(); controller.contentViewController = nil }
    }
    static func show(provider: String, operation: UUID, appModel: AppModel) async throws -> NSWindow {
        if let window = controllers[provider]?.window, window.isVisible {
            window.makeKeyAndOrderFront(nil)
            NSApp.activate()
            try await RendererProtection.shared.hold(window: window)
            return window
        }
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 600, height: 650),
            styleMask: [.titled, .resizable], backing: .buffered, defer: false)
        window.identifier = NSUserInterfaceItemIdentifier(operation.uuidString)
        window.title = "Account · Protected entry"
        window.isReleasedWhenClosed = false
        window.center()
        window.makeKeyAndOrderFront(nil)
        NSApp.activate()
        do {
            try await RendererProtection.shared.hold(window: window)
            try Task.checkCancellation()
        } catch { window.close(); throw error }
        window.contentViewController = NSHostingController(rootView: ProviderConfigSheet(providerID: provider) {
            window.close()
            window.contentViewController = nil
            controllers[provider] = nil
        }.environment(appModel))
        let controller = NSWindowController(window: window)
        controllers[provider] = controller
        controller.showWindow(nil)
        NSApp.activate()
        return window
    }
}

@MainActor enum GrokSecureSetupWindow {
    private static var controllers: [String: NSWindowController] = [:]
    private static var operations: [String: UUID] = [:]
    static func closeAll() {
        let shown = controllers.values
        controllers.removeAll()
        operations.removeAll()
        for controller in shown { controller.close(); controller.contentViewController = nil }
    }
    static func show(contact: String, operation: UUID, appModel: AppModel) async throws -> NSWindow {
        if let window = controllers[contact]?.window, window.isVisible {
            guard operations[contact] == operation else {
                throw PartCallError(code: "protected_entry_busy", message: "Finish or close the existing routine credential window first.")
            }
            window.makeKeyAndOrderFront(nil)
            NSApp.activate()
            try await RendererProtection.shared.hold(window: window)
            return window
        }
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 520, height: 360),
            styleMask: [.titled, .closable, .resizable], backing: .buffered, defer: false)
        window.title = "Routine credentials"
        window.isReleasedWhenClosed = false
        window.center()
        window.makeKeyAndOrderFront(nil)
        NSApp.activate()
        do {
            try await RendererProtection.shared.hold(window: window)
            try Task.checkCancellation()
        } catch { window.close(); throw error }
        window.contentViewController = NSHostingController(
            rootView: GrokSecureSetupCard(contact: contact, operation: operation).padding(20).environment(appModel))
        let controller = NSWindowController(window: window)
        controllers[contact] = controller
        operations[contact] = operation
        controller.showWindow(nil)
        NSApp.activate()
        return window
    }
}

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
        let grant = try await SettingsFaceCalls.resourceGrant(id: operation, url: folder, writable: writable.state == .on)
        return .folder(.init(label: label.isEmpty ? folder.lastPathComponent : label, resource: grant, writable: writable.state == .on))
    }
}
