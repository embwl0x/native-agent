import SwiftUI
import AppKit
import NativeAgentShared
import UserNotifications
// Blueprint: | `NativeAgentFaceApp.swift` | Copied window bootstrap; its only agent owner is the inherited pipe client |

@main
struct NativeAgentFaceApp: App {
    @NSApplicationDelegateAdaptor(FaceAppDelegate.self) private var delegate
    @State private var session = FaceSession.shared
    @State private var appearance = AppearanceController.shared

    var body: some Scene {
        Window("NativeAgent", id: ApplicationLifetime.mainSceneID) {
            Group {
                switch session.client.state {
                case .connecting: Text("Connecting…").padding(32)
                case .connected:
                    MainWindowContent()
                        .environment(session.model)
                        .environment(\.colorScheme, appearance.colorScheme)
                case .failed(let detail):
                    VStack(spacing: 16) {
                        Text(detail).textSelection(.enabled)
                        Button("Close") { NSApp.terminate(nil) }
                    }.padding(32)
                case .closed: Text("My connection closed.").padding(32)
                }
            }
            .frame(minWidth: 820, minHeight: 560)
            .onChange(of: session.model.facePreference(AppearanceController.preferenceKey, as: Bool.self), initial: true) { _, dark in
                if let dark { appearance.setPreferDark(dark) }
            }
            .onChange(of: session.client.state, initial: true) { _, state in
                if state == .connected { FaceReports.shared.connect(session.client) }
            }
        }
        .defaultSize(width: 1280, height: 860)
        .windowStyle(.hiddenTitleBar)
        .commands {
            ChatFocusedCommands()
            ShellViewCommands(appModel: session.model)
            FaceWindowCommands(appModel: session.model)
        }
    }
}

struct FaceWindowCommands: Commands {
    let appModel: AppModel
    @Environment(\.openWindow) private var openWindow
    var body: some Commands {
        // Commands exist from launch whether or not a window does, so the body can always ask for the window.
        let _ = ApplicationLifetime.shared.configureMainWindowOpening { [openWindow] in openWindow(id: ApplicationLifetime.mainSceneID) }
        // Quit ends the body; closing the window leaves it running. The body's exit ends this process through the pipe.
        CommandGroup(replacing: .appTermination) {
            Button("Quit NativeAgent") {
                Task {
                    do { _ = try await appModel.client.act(.quitBody) }
                    catch { NSApp.terminate(nil) }
                }
            }.keyboardShortcut("q", modifiers: .command)
        }
        CommandGroup(replacing: .appSettings) {
            Button("Settings…") { SettingsLink.open(.settings) }.keyboardShortcut(",", modifiers: .command)
        }
        CommandGroup(after: .appInfo) {
            Button("Check for Updates…") {
                appModel.enqueueWindowAction(.updates)
            }
            Button("Refresh status") { appModel.manualRefreshRequest = UUID() }.keyboardShortcut("r", modifiers: .command)
        }
        CommandGroup(after: .windowList) {
            Button("Browser") {
                appModel.enqueueWindowAction(.browser)
            }.keyboardShortcut("b", modifiers: [.command, .option])
        }
        CommandMenu("Navigate") {
            Button("Command palette…") { NotificationCenter.default.post(name: .openCommandPaletteRequest, object: nil) }
                .keyboardShortcut("k", modifiers: .command)
            if let layout = appModel.shellLayout {
                ForEach(NavigateMenuPresentation.entries(layout)) { entry in
                    Button(entry.title) { ApplicationLifetime.shared.request(.sidebar(entry.item)) }
                        .keyboardShortcut(entry.shortcut.map { KeyboardShortcut(KeyEquivalent($0), modifiers: .command) })
                }
            }
            Button("Knowledge graph") { ApplicationLifetime.shared.request(.sidebar(.knowledge)) }
            Button("Approvals") { ApplicationLifetime.shared.request(.activity(.approvals)) }
                .keyboardShortcut("a", modifiers: [.command, .shift])
            Button("Inbox") { ApplicationLifetime.shared.request(.activity(.inbox)) }
                .keyboardShortcut("i", modifiers: [.command, .shift])
        }
    }
}

@MainActor final class FaceAppDelegate: NSObject, NSApplicationDelegate, UNUserNotificationCenterDelegate {
    func applicationDidFinishLaunching(_ notification: Notification) {
        // Opened without the body (a kept Dock icon, Finder): start the body, which opens its own window, and leave.
        guard ProcessInfo.processInfo.environment["NATIVEAGENT_FACE_DATA_ROOT"] != nil else {
            let nova = Bundle.main.bundleURL.deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
            NSWorkspace.shared.openApplication(at: nova, configuration: NSWorkspace.OpenConfiguration()) { _, _ in
                Task { @MainActor in NSApp.terminate(nil) }
            }
            return
        }
        NSApp.setActivationPolicy(.regular)
        UNUserNotificationCenter.current().delegate = self
        // The link starts with this process, never with a window: the body asks for the window over it.
        FaceSession.shared.start()
    }
    /// Closing the window keeps NativeAgent in the Dock, as every Mac app does; Quit is what ends it.
    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { false }

    /// A Dock click with no window open brings the window back.
    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows: Bool) -> Bool {
        guard !hasVisibleWindows else { return true }
        Task {
            do { _ = try await ApplicationLifetime.shared.showWindow(destination: nil) }
            catch {
                let alert = NSAlert()
                alert.messageText = "The NativeAgent window could not open."
                alert.informativeText = error.localizedDescription
                alert.runModal()
            }
        }
        return false
    }

    nonisolated func userNotificationCenter(_ center: UNUserNotificationCenter, didReceive response: UNNotificationResponse) async {
        let content = response.notification.request.content
        var route: [String: String] = [:]
        for (key, value) in content.userInfo {
            if let key = key as? String, let value = value as? String { route[key] = value }
        }
        let value = NotificationResponse(id: response.notification.request.identifier, action: response.actionIdentifier,
            text: (response as? UNTextInputNotificationResponse)?.userText, category: content.categoryIdentifier,
            route: route, title: content.title, body: content.body)
        await FaceReports.shared.submit(.notificationResponse(value))
    }
}

@MainActor @Observable final class FaceSession {
    static let shared = FaceSession()
    let client: PipeFaceClient
    let model: AppModel
    @ObservationIgnored private var router: FaceCallRouter?
    @ObservationIgnored private var started = false
    /// The link to the body lives as long as this process, not as long as a window: closing the window keeps it.
    @ObservationIgnored private var link: Task<Void, Never>?

    init() {
        let client = PipeFaceClient()
        self.client = client
        model = AppModel(client: client)
        ApplicationLifetime.shared.appModel = model
    }
    func start() {
        guard !started else { return }
        started = true
        link = Task { await run() }
    }

    private func run() async {
        let router = FaceCallRouter(client: client, pageImage: { [model] request in
            try await QuietSelfAdminRender.renderPage(request, appModel: model, appliedEpoch: request.epoch, appliedBarrier: request.barrier)
        }, showWindow: { destination in
            try await ApplicationLifetime.shared.showWindow(destination: destination)
        })
        self.router = router
        model.installChatFaceCalls(on: router)
        SettingsFaceCalls.install(on: router, appModel: model)
        MindFaceCalls.install(router: router, client: client)
        ShellFaceCalls.install(on: router, appModel: model)
        ShotgunController.shared.attach(appModel: model)
        ShotgunController.shared.installCalls(on: router, client: client)
        do {
            try await client.openLinkRecord()
            await client.run(link: try await PipeFaceClient.openInheritedPipes(), router: router)
        }
        catch { await client.connectionFailed(error) }
        await FaceReports.shared.disconnect()
    }
}
