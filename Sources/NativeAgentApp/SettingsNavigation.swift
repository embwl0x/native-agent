import BodyRuntime
import Foundation
import SwiftUI
import NativeAgentShared
// Blueprint: | `SettingsNavigation.swift` | Body navigation requests opening the renderer's canonical Settings pages |

/// Open a page and its tab. Simple and Advanced show it in place; any other view shows no pages, so the link opens Advanced first.
@MainActor
enum SettingsLink {
    static func open(_ item: SidebarItem, tab: String? = nil) {
        // The window opens the page and its tab; her body keeps no window state of its own.
        var destination = NativeAgentNavigationDestination.sidebar(item).faceDestination
        destination?.item = tab
        AppDelegate.requestFaceWindowIfInstalled(destination: destination)
    }
}
