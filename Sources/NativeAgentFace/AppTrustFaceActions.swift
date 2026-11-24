import Foundation
import AppKit
import SwiftUI
import NativeAgentShared
import UniformTypeIdentifiers
// Blueprint: | `AppTrustFaceActions.swift` | Native Trust workbench and confirmed app-exclusion picker |

@MainActor enum TrustPresentation {
    static func showWorkbench(appModel: AppModel) {
        TrustFaceWindows.show("workbench", title: "Mac control workbench", content: TrustFaceWorkbench().environment(appModel))
    }
    static func chooseActivityExclusion(operation: UUID) async throws -> FaceReply {
        let panel = NSOpenPanel()
        panel.identifier = NSUserInterfaceItemIdentifier(operation.uuidString)
        panel.title = "Choose an app to exclude"
        panel.prompt = "Choose App"
        panel.directoryURL = URL(fileURLWithPath: "/Applications")
        panel.allowedContentTypes = [.application]
        panel.allowsMultipleSelection = false
        guard try await FaceNativePanel.choose(panel) == .OK else { return .cancelled }
        try Task.checkCancellation()
        guard let url = panel.url, let id = await bundleIdentifier(at: url) else {
            throw PartCallError(code: "app_identity_unavailable", message: "The chosen app has no readable bundle identity.")
        }
        let alert = NSAlert()
        alert.messageText = "Exclude this app and delete what was recorded?"
        alert.informativeText = "Everything recorded for \(id) is deleted for good, including the recovery log. Future recording skips it."
        alert.addButton(withTitle: "Exclude and delete")
        alert.addButton(withTitle: "Cancel")
        guard try await FaceNativePanel.confirm(alert) == .alertFirstButtonReturn else { return .cancelled }
        return .exclusion(.init(bundleID: id, confirmed: true))
    }

    @concurrent nonisolated private static func bundleIdentifier(at url: URL) async -> String? {
        Bundle(url: url)?.bundleIdentifier
    }
}

struct SkillBuildRequest: NotificationCenter.MainActorMessage {
    typealias Subject = NSObject
    let starter: String
}

private struct TrustFaceWorkbench: View {
    @Environment(AppModel.self) private var appModel

    var body: some View {
        ScrollView {
            if let effective = appModel.face.slot(.settings).select("trust.workbenchPolicy", as: SettingsFace.self, {
                $0?.trust.effectiveMacControlPolicy
            }) {
                MacControlWorkbenchView(policy: effective).padding(24)
            } else {
                Text("Mac control policy is unavailable. Read Trust again.").padding(24)
            }
        }
    }
}

/// Windows retain native presentation; their buttons send acts to the body.
@MainActor enum TrustFaceWindows {
    static var controllers: [String: NSWindowController] = [:]
    private static var frames: [String: WindowFrame] = [:]
    private static var closeObservers: [String: NSObjectProtocol] = [:]

    static func closeAll() {
        for observer in closeObservers.values { NotificationCenter.default.removeObserver(observer) }
        closeObservers.removeAll()
        for frame in frames.values { frame.end() }
        frames.removeAll()
        let shown = controllers.values
        controllers.removeAll()
        for controller in shown {
            controller.close()
            controller.window?.contentViewController = nil
            controller.window?.contentView = nil
        }
    }

    static func show<Content: View>(_ id: String, title: String, frame: (name: String, minimum: NSSize)? = nil, content: Content) {
        if let controller = controllers[id], controller.window?.isVisible == true {
            controller.showWindow(nil)
            controller.window?.makeKeyAndOrderFront(nil)
            return
        }
        if let priorObserver = closeObservers.removeValue(forKey: id) { NotificationCenter.default.removeObserver(priorObserver) }
        frames.removeValue(forKey: id)?.end()
        if let priorController = controllers.removeValue(forKey: id) {
            priorController.close()
            priorController.window?.contentViewController = nil
            priorController.window?.contentView = nil
        }
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 760, height: 640),
            styleMask: [.titled, .closable, .resizable], backing: .buffered, defer: false)
        window.title = title
        var placed = false
        if let frame {
            let host = NSHostingView(rootView: content)
            host.sizingOptions = []
            let surface = NSView()
            window.contentView = surface
            host.frame = surface.bounds
            host.autoresizingMask = [.width, .height]
            surface.addSubview(host)
            let kept = WindowFrame(window, name: frame.name)
            frames[id] = kept
            let size = window.contentRect(forFrameRect: window.frame).size
            placed = kept.restored && size.width >= frame.minimum.width && size.height >= frame.minimum.height
            window.contentMinSize = frame.minimum
            if !placed { window.setContentSize(NSSize(width: 900, height: 700)) }
        } else {
            window.contentViewController = NSHostingController(rootView: content)
        }
        if !placed { window.center() }
        let controller = NSWindowController(window: window)
        controllers[id] = controller
        let target = ObjectIdentifier(window)
        closeObservers[id] = NotificationCenter.default.addObserver(
            forName: NSWindow.willCloseNotification, object: window, queue: .main
        ) { _ in
            Task { @MainActor in
                guard let current = controllers[id],
                      let closing = current.window,
                      ObjectIdentifier(closing) == target else { return }
                if let observer = closeObservers.removeValue(forKey: id) { NotificationCenter.default.removeObserver(observer) }
                frames.removeValue(forKey: id)?.end()
                closing.contentViewController = nil
                closing.contentView = nil
                controllers.removeValue(forKey: id)
            }
        }
        controller.showWindow(nil)
        window.makeKeyAndOrderFront(nil)
    }
}
