import SwiftUI
// Blueprint: | `NativeAgentWindowChrome.swift` | Menu-bar control opening the independent window process |

struct MenuBarOpenButton: View {
    var body: some View {
        Button("Open NativeAgent", systemImage: "macwindow") {
            AppDelegate.requestFaceWindowIfInstalled()
        }
    }
}
