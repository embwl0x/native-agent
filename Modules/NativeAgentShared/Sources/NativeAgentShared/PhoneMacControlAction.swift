// Blueprint: | `PhoneMacControlAction.swift` | Executable phone Mac-control methods and native paths shared by mobile senders and Mac dispatch; preserves the volume wire envelope |

/// Route support, independent of Trust admission. Only methods with a native
/// executor belong here; saving a policy switch cannot supply an executor.
public enum PhoneMacControlAction: String, Sendable {
    case appleScript = "runAppleScript"
    case spotlight = "runSpotlight"
    case focusApp, quitApp, keystroke
    case click = "clickAt"
    case volume = "system"
    case readFile, writeFile, listDirectory, moveFile, trashFile
    case notification = "notify"
    case shell = "runShell"

    public var path: String {
        let action: String = switch self {
        case .appleScript: "applescript"
        case .spotlight: "spotlight"
        case .focusApp: "focus_app"
        case .quitApp: "quit_app"
        case .keystroke: "keystroke"
        case .click: "click"
        case .volume: "volume"
        case .readFile: "file/read"
        case .writeFile: "file/write"
        case .listDirectory: "file/list"
        case .moveFile: "file/move"
        case .trashFile: "file/trash"
        case .notification: "notify"
        case .shell: "shell"
        }
        return "/v1/mac_control/\(action)"
    }

    public static func resolve(_ payload: [String: String]) -> Self? {
        guard let action = Self(rawValue: payload["method"] ?? ""),
              action != .volume || payload["action"] == "volume" else { return nil }
        return action
    }

    public func payload(_ arguments: [String: String]) -> [String: String] {
        var payload = arguments
        payload["method"] = rawValue
        // Keep queued envelopes and older paired Macs wire-compatible.
        if self == .volume { payload["action"] = "volume" }
        return payload
    }
}
