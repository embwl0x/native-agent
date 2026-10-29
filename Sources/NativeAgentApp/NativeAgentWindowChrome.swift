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
                ApplicationLifetime.shared.configureMainWindowOpening { [openWindow] in
                    openWindow(id: ApplicationLifetime.mainSceneID)
                }
            }
    }
}

// openWindow resolves inside a View hierarchy, outside the MenuBarExtra scene closure.
struct MenuBarOpenButton: View {
    @Environment(\.openWindow) private var openWindow
    var body: some View {
        Button("Open NativeAgent", systemImage: "macwindow") {
            NSApp.activate(ignoringOtherApps: true)
            // The main scene is a single-instance Window (not WindowGroup),
            // so openWindow(id:) reuses the existing one if visible or
            // recreates it if closed — never stacks copies.
            openWindow(id: ApplicationLifetime.mainSceneID)
        }
    }
}
