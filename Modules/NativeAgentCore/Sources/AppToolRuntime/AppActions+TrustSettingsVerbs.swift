import Foundation
// Blueprint: | `AppActions+TrustSettingsVerbs.swift` | The verbs Trust's and Settings' rows call beyond `setting.set` and the existing backup, history and grant verbs: the Mac's own buttons, each the person's lever where it needs the person at the Mac |

extension AppActions {
    /// What the Trust and Settings rows call that no existing verb does. Each runs its Mac handler through `upkeep`
    /// (`AppQuietToolHost.runTrustSettingsUpkeep`). A row that needs the person in the foreground on this Mac (a macOS prompt, a window, a
    /// file chooser, the clipboard) is a lever the agent's call never takes: `asks: false`, since no card can stand in for the person there.
    static var trustSettingsInboxVerbs: [AppAction] {
        get throws {
            let foreground = "it runs in the foreground on this Mac for the person at it"
            return [
                AppAction("trust.refresh_privacy", "trust", "Read macOS grants and the privacy inventory again", tool: "upkeep",
                          input: verb("trust_refresh_privacy"), read: true),
                AppAction("trust.authorize_safe", "trust", "Preserve the damaged Trust policy and authorize Safe", owner: .person(
                              "it rewrites the saved authority every judgment reads; the person does it on Trust", asks: false,
                                  name: "Authorizing Safe after a damaged Trust policy"),
                          tool: "upkeep", input: verb("trust_authorize_safe")),
                AppAction("trust.check_mail", "trust", "Check Mail access on this Mac", owner: .person(
                              "it enters Mail, which can raise macOS's Automation prompt; " + foreground, asks: false, name: "Checking Mail access"),
                          tool: "upkeep", input: verb("trust_check_mail")),
                AppAction("trust.ask_grant", "trust", "Ask macOS for these grants", ["targets:list"], owner: .person(
                              "only the person answers macOS's prompt; " + foreground,
                              instead: "permissions.request raises the person's permission card", asks: false, name: "Answering macOS's permission prompts"),
                          tool: "upkeep", input: verb("trust_ask_grant")),
                AppAction("trust.grant_settings", "trust", "Open System Settings at a grant's pane", ["target"], subject: ["target"], owner: .person(
                              "it opens System Settings; " + foreground, asks: false, name: "Opening System Settings at a permission"),
                          tool: "upkeep", input: verb("trust_grant_settings")),
                AppAction("trust.test_notification", "trust", "Send a Mac control test notification", owner: .person(
                              "it tests Mac control's notification, which can raise macOS's prompt; " + foreground, asks: false,
                                  name: "Sending a Mac control test notification"),
                          tool: "upkeep", input: verb("trust_test_notification")),
                AppAction("trust.workbench", "trust", "Open the Mac control workbench", owner: .person(
                              "it opens a window of freeform Mac commands; " + foreground, asks: false, name: "Opening the Mac control workbench"),
                          tool: "upkeep", input: verb("trust_workbench")),
                AppAction("trust.exclude_app", "trust", "Choose an app to exclude from activity capture and delete its history", owner: .person(
                              "the person chooses the app and confirms the deletion; " + foreground, asks: false,
                                  name: "Excluding an app from activity capture"),
                          irreversible: true, capabilities: ["app_data_write", "safe_read", "tool_call"],
                          tool: "upkeep", input: verb("trust_exclude_app")),
                AppAction("settings.update", "settings", "Open the software update control", owner: .person(
                              "it opens the updater's window to review and install; " + foreground,
                              instead: "app.check_updates reads whether one is out", asks: false, name: "Installing an update"),
                          tool: "upkeep", input: verb("settings_update")),
                AppAction("settings.data_limits", "settings", "Open the data-limits reference", owner: .person(
                              "it opens a document window; " + foreground, asks: false, name: "Opening the data-limits reference"),
                          tool: "upkeep", input: verb("settings_data_limits")),
                AppAction("settings.copy_build_identity", "settings", "Copy the running build identity", owner: .person(
                              "it replaces the clipboard; " + foreground, asks: false, name: "Copying the build identity"),
                          tool: "upkeep", input: verb("settings_copy_build_identity")),
            ]
        }
    }
}
