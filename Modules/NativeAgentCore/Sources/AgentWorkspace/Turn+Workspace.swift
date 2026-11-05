import Foundation
import NativeAgentCore
// Blueprint: | `Turn+Workspace.swift` | `Turn` part the workspace owns: the turn's screen-preview sink |

private enum ScreenPreviewPart: TurnPart { static let unset: (@Sendable (MacScreenPreviewUpdate) async -> Void)? = nil }

extension Turn {
    /// Where this turn's screen previews are published.
    public var screenPreview: (@Sendable (MacScreenPreviewUpdate) async -> Void)? {
        get { self[ScreenPreviewPart.self] }
        set { self[ScreenPreviewPart.self] = newValue }
    }
}
