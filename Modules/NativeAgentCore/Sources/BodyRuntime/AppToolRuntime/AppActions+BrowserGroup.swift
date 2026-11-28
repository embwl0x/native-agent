import DeskCore
import MacNerves
import NativeAgentCore
import NativeAgentShared
import PersistenceCore
import SenseCore
import Foundation
import ProviderRouting
import MindCore
// Blueprint: | `AppActions+BrowserGroup.swift` | Browser action declarations |

extension AppActions {
    static func browserGroup() throws -> [AppAction] {
        try [
        .fold("browser.status", "browser", read: true),
        .fold("browser.open_url", "browser"),
        .fold("browser.read_text", "browser", read: true),
        .fold("browser.read_links", "browser", read: true),
        .fold("browser.screenshot", "browser"),
        .fold("browser.chrome_setup", "browser"),
        .fold("browser.chrome_status", "browser", read: true),
        .fold("browser.chrome_snapshot", "browser", read: true),
    ] + ToolNameAliases.chromeVerbs.filter { $0 != "snapshot" }.map { try AppAction.fold("browser.chrome_" + $0, "browser", read: $0 == "wait"
        || $0 == "look") }
    }
}
