import Foundation
// Blueprint: | `WorkPane.swift` | Preference names for body-owned Work pane settings; window owns visibility and selection |

enum WorkPaneState {
    static let openKey = "NativeAgent.workPane.open"
    static let widthKey = "NativeAgent.workPane.width"
    static let sidebarsHiddenKey = "NativeAgent.shell.sidebarsHidden"
}
enum WorkPane {
    static let defaultWidth = 420.0
}
