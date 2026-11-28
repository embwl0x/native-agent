import AppKit
import NativeAgentShared
// Blueprint: | `FaceComposerFocus.swift` | Accessibility identifiers for mounted native composers |

@MainActor
enum FaceComposerFocus {
    static func identifier(session: String, active: Bool = true) -> String {
        (active ? "face.composer." : "face.inactive-composer.") + session
    }
}
