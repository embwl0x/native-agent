import Foundation
// Blueprint: | `ShotgunShortcut.swift` | Shared Shotgun keyboard shortcut cases, storage key and display titles |

public enum ShotgunShortcut: String, CaseIterable, Identifiable, Sendable {
    case optionSpace = "option-space"
    case controlOptionSpace = "control-option-space"
    case shiftCommandSpace = "shift-command-space"
    case off

    public static let storageKey = "NativeAgent.shotgun.shortcut"
    public var id: String { rawValue }

    public var title: String {
        switch self {
        case .optionSpace: "⌥Space"
        case .controlOptionSpace: "⌃⌥Space"
        case .shiftCommandSpace: "⇧⌘Space"
        case .off: "Off"
        }
    }
}
