import Foundation
import SwiftUI
// Blueprint: | `NativeAgentWindowChrome.swift` | `MainWindowContent`; main-window content and opening |

// Draw shell chrome behind content so the window has one continuous ground.
struct MainWindowContent: View {
    @Environment(\.openWindow) private var openWindow

    var body: some View {
        ContentView()
            .macFaceStyle()
            .background { ShellWindowChrome() }
            .onAppear {
                ApplicationLifetime.shared.configureMainWindowOpening { [openWindow] in
                    openWindow(id: ApplicationLifetime.mainSceneID)
                }
            }
    }
}
