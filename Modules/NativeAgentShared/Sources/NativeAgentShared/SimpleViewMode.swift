import Foundation
// Blueprint: | `SimpleViewMode.swift` | Canonical view preference key and offered window modes |

public enum SimpleViewMode {
    public static let key = "nativeagent.viewMode"
    public static let simple = "simple"
    public static let advanced = "advanced"
    public static let agent = "agent"
    public static let choices = [simple, advanced, agent]
}
