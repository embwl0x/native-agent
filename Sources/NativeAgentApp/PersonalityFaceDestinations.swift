import EngineRuntime
import NativeAgentShared
import SwiftUI
// Blueprint: | `PersonalityFaceDestinations.swift` | Personality face links open its existing identity editor and Dreams |

@MainActor
enum PersonalityFaceDestinations {
    static let tabs = [
        ShellTab(key: "personality", title: "Personality"),
        ShellTab(key: "documents", title: "Read or edit identity"),
        ShellTab(key: "dreams", title: "Dreams")
    ]
}
