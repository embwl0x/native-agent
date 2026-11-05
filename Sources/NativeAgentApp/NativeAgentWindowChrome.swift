import Foundation
import SwiftUI
// Blueprint: | `NativeAgentWindowChrome.swift` | `MainWindowContent`, `MenuBarOpenButton`; main-window content and menu-bar opening |

// Draw shell chrome behind content so the window has one continuous ground.
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

// openWindow needs a View hierarchy, outside the MenuBarExtra scene closure.
struct MenuBarOpenButton: View {
    @Environment(\.openWindow) private var openWindow
    var body: some View {
        Button("Open NativeAgent", systemImage: "macwindow") {
            NSApp.activate()
            // The single-instance Window reuses the visible window instead of stacking copies.
            openWindow(id: ApplicationLifetime.mainSceneID)
        }
    }
}
