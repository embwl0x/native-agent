import Foundation
import AppKit
import SwiftUI
import NativeAgentShared
// Blueprint: | `AppConnectorPlatform.swift` | Protected account windows requested by the body |

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
    static func closeAll() {
        let shown = controllers.values
        controllers.removeAll()
        for controller in shown { controller.close(); controller.contentViewController = nil }
    }
    static func close(contact: String) {
        guard let controller = controllers.removeValue(forKey: contact) else { return }
        controller.close()
        controller.contentViewController = nil
    }
    /// A window already open for this contact is brought forward and reused, whichever press opened it: an open window is never a refusal.
    static func show(contact: String, operation: UUID, appModel: AppModel) async throws -> NSWindow {
        if let window = controllers[contact]?.window, window.isVisible {
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
        controller.showWindow(nil)
        NSApp.activate()
        return window
    }
}
