import Foundation

// Blueprint: | `HomePath.swift` | `HomePath.expand`: expands only the current user's home shorthand, leaving named-user paths unchanged |

/// Expand only the current user's home shorthand; leave named users untouched.
public enum HomePath {
    public static func expand(
        _ path: String,
        homeDirectory: URL = FileManager.default.homeDirectoryForCurrentUser
    ) -> String {
        if path == "~" { return homeDirectory.path }
        if path.hasPrefix("~/") {
            return homeDirectory.appendingPathComponent(String(path.dropFirst(2))).path
        }
        return path
    }
}
