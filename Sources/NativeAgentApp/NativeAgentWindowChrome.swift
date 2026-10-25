import Foundation
import SwiftUI
// Blueprint: | `NativeAgentWindowChrome.swift` | `MainWindowContent`, `MenuBarOpenButton`; main-window content and menu-bar opening |

// Wraps ContentView so the main window draws the shell's chrome behind it.
// Restart App is a worded item in the menu bar's NativeAgent menu
// (NativeAgentApp.swift), reachable even when this window is closed.
struct MainWindowContent: View {
    @Environment(\.openWindow) private var openWindow

    var body: some View {
        ContentView()
            .background { ShellWindowChrome() }
            .onAppear {
                NativeAgentAppCoordinator.shared.configureMainWindowOpening { [openWindow] in
                    openWindow(id: NativeAgentAppCoordinator.mainSceneID)
                }
            }
    }
}

// PATCH-2026-05-07: app-owned runtime helper button that opens the main
// window via @Environment(\.openWindow). Lives outside the MenuBarExtra
// closure because MenuBarExtra is a Scene, not a View — environment
// values for openWindow only resolve inside an actual view hierarchy.
struct MenuBarOpenButton: View {
    @Environment(\.openWindow) private var openWindow
    var body: some View {
        Button("Open NativeAgent", systemImage: "macwindow") {
            NSApp.activate(ignoringOtherApps: true)
            // The main scene is a single-instance Window (not WindowGroup),
            // so openWindow(id:) reuses the existing one if visible or
            // recreates it if closed — never stacks copies.
            openWindow(id: NativeAgentAppCoordinator.mainSceneID)
        }
    }
}
