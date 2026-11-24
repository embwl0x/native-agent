import MacNerves
import NativeAgentCore
import NativeAgentShared
import PersistenceCore
import DeskCore
import SenseCore
import Foundation
import ProviderRouting
import MindCore
// Blueprint: | `AppActions+MacGroup.swift` | Mac action declarations |

extension AppActions {
    static func macGroup() throws -> [AppAction] {
        try [
        // Each Mac verb re-enters its own gate so accessibility, MacAttention and saved levels still apply; mac/guided owns the act guide.
        .fold("screen", "mac", "Read the live screen as words; lists running apps when NativeAgent is frontmost. "
              + "app reads a running app's window without activation; part zooms in; "
              + "pixels:true is a picture of the desktop", read: true),
        .fold("act", "mac", "Act by name with verb + target (click, type with text, key, select, scroll…), or one flow "
              + "with steps:[…]: names, menu paths ('Format > Make Plain Text'), chords or {verb,target,text,mode}; "
              + "steps can carry holding and button, including image points with at/from. "
              + "Each step verifies on a fresh read; first failure stops the flow. app names the window: "
              + "act in front if frontmost, otherwise where it sits (brought forward while "
              + "Shotgun is up)", actArgs, screen: true),
        .fold("go", "mac", "Open an app, file, folder, http/https URL or System Settings pane, then read a fresh "
              + "screen. Without front it opens/launches behind (in front while Shotgun is up) and reads that "
              + "app's window; use front:true only when asked to bring it forward", screen: true),
        .fold("wait", "mac", read: true),
        .fold("read", "mac", read: true),
        .fold("menu", "mac", read: true),
        .fold("menu_press", "mac", screen: true),
        .fold("clipboard_read", "mac", read: true),
        .fold("clipboard_write", "mac"),
        .fold("system_info", "mac", """
            Read system, network, battery and named Data/System volume capacity; disk is Data, system_disk is the sealed System volume
            """, read: true),
        AppAction("mac.apps", "mac", """
            List installed apps or check one by name; returns name, bundle ID, path, version and scriptability
            """, [.optional("name"), .optional("all", .boolean)],
                 tool: "mac_apps", read: true, scope: "installed apps applications what apps do I have; name: optional substring filter"),
        .fold("mac_screenshot_save", "mac"),
        .fold("mac_location", "mac", "Where this Mac is", read: true),
        .fold("mac_volume", "mac", "Read or change volume; no args reads only", readWhen: ["level": .null, "adjust": .null, "muted": .null]),
        .fold("mac_media", "mac", "Control Now Playing across Music, Spotify, browsers and podcasts: play/pause toggle, next or previous", screen: true),
        .fold("activity_query", "mac", read: true),
        .fold("context_lookup", "capabilities", read: true),
        .fold("request_interaction", "chat"),
        .fold("artifact_find", "chat", read: true),
        .fold("work_context", "desk", read: true),
        ]
    }
}
