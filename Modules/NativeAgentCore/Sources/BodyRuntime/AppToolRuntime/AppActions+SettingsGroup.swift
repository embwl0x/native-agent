import MacNerves
import NativeAgentCore
import NativeAgentShared
import PersistenceCore
import DeskCore
import SenseCore
import Foundation
import ProviderRouting
import MindCore
// Blueprint: | `AppActions+SettingsGroup.swift` | Settings action declarations |

extension AppActions {
    static func settingsGroup() -> [AppAction] {
        [
        AppAction("persona.set", "personality", "Switch persona", [.required("name")], screen: true, tool: "interaction_act",
                  input: composer("set_persona"), rename: ["name": "value"]),
        AppAction("app.check_updates", "settings", """
            Check for NativeAgent updates only; macOS uses mac.system_info with check_updates:true, App Store apps use App Store → Updates
            """,tool: "interaction_act",
                  input: composer("check_updates"), read: true),
        // Window layout reads the same ui/layout.json that these writes update.
        AppAction("layout.read", "settings", """
            The window's layout: each surface's blocks in order, hidden and expanded, each view's profile, its version, the previous layout and what every \
            block is
            """,
                 tool: "app_page_read", read: true, scope: layoutScope),
        AppAction("layout.write", "settings", """
            Change the layout, passing layout.read's version as layout_version and only what changes (a surface's whole block list, a profile, phone); the \
            window follows at once; undo puts the previous one back
            """,
                  [.required("layout", .fromOwner), .required("layout_version")], tool: "app_setting_set", scope: layoutScope,
                  schema: arguments("app_setting_set", ["layout": SurfaceLayoutStore.writeArgumentSchema, "layout_version": ToolSchema.strSchema()])),
        // Owner-only rows stay with the user; lower-only rows may only move in the safe direction.
        AppAction("setting.get", "*", """
            Read a setting's current value, kind and accepted choices (app {page} lists ids). phone.settings reads the paired phone's own settings directory \
            while its app is open.
            """, [.required("setting")], subject: ["setting"],
                 tool: "app_setting_get", read: true, scope: "setting value read get home timezone phone preferences appearance shortcut memory"),
        AppAction("setting.set", "*", "Set", [.required("setting"), .required("value", .any), .optional("because")], subject: ["setting"],
                  warn: """
                      Your own mind settings need no request. In a turn the person started, what they asked is the request: every change runs \
                      on it as theirs, owner_only settings and widenings (Full Mac included) too, at any posture but Safe. In any other turn below \
                      Full Mac, because quotes at least 3 words from a person or trusted agent in this conversation (a run with no conversation has \
                      none to quote), and you may restore a switch whose last change was yours; a widening or an owner_only change asks the person \
                      on a card.
                      """,
                  tool: "app_setting_set", schema: arguments("app_setting_set", ["setting": ToolSchema.strSchema(), "because": ToolSchema.strSchema(),
                      "value": .object([
                    "description": .string("""
                        Type is this setting's kind; read setting.get {setting} for its current value, kind and accepted values before setting it.
                        """)])])),
        // Version-exempt: generated captures have no user state to overwrite.
        AppAction("page.screenshot", "*",
                  """
                      Screenshot of one of your own NativeAgent pages (your current page, chat, settings…), drawn offscreen; returns the PNG's path. Not the \
                      Mac screen. tab is a tab key as page.show takes it\u{20}
                      """
                  + "(knowledge, dreams…), the page's default tab when left out. item opens one Desk item in the picture as page.show does "
                  + "(desk.4 or its handle; board lets the open item go); the window stays on its page", [.required("page"), .optional("tab"), .optional("height", .integer), .optional("item")],
                  warn: "saves a PNG and prunes old page captures", tool: "app_page_screenshot", versionExempt: true),
        // Phone, Telegram and below-Full-Mac authority cards remain user-owned; answering runs an irreversible control.
        AppAction("permissions.request", "chat", "Ask for a macOS permission in your own words", [.required("capability"), .required("why"), .optional("mode"), .optional("also_needed", .list)],
            subject: ["capability", "mode"],
                  capabilities: [.safeRead, .toolCall], warn: """
                      capability: privacy:<grant>, grant one of \(SystemPermissionCapability.requestable); Automation for one app: \
                      applescript:<bundle_id>. also_needed: the other grants this same card asks for, in the same forms, so everything still off \
                      is one card. Only the person taps Allow on the Mac; the waiting work continues after the grant.
                      """,
                  tool: "request_interaction", input: ["kind": .string("permission")], rename: ["capability": "target"], folded: true),
        AppAction("card.answer", "chat", "The card's own button (its Do: line)", [.required("id"), .optional("value", .secret), .optional("choice")], subject: ["id"],
                  irreversible: true, capabilities: [.appDataWrite, .safeRead, .toolCall],
                      warn: "never ask the owner for a key or token in chat: they type it into the card",
                  tool: "interaction_act", input: card("primary"), rename: ["id": "interaction_id"]),
        AppAction("card.not_now", "chat", "Not now", [.required("id"), .optional("reason")], subject: ["id"], irreversible: true, capabilities: [.appDataWrite, .safeRead,
            .toolCall], tool: "interaction_act",
                  input: card("decline"), rename: ["id": "interaction_id"]),
        // Irreversible: it runs the card's own control as card.answer does, a capability grant included.
        AppAction("card.try_again", "chat", "Try again", [.required("id"), .optional("value", .secret), .optional("choice")], subject: ["id"], irreversible: true,
                  capabilities: [.appDataWrite, .safeRead, .toolCall], tool: "interaction_act",
                  input: card("retry"), rename: ["id": "interaction_id"]),

        AppAction("provider.test", "providers", "Test the connection", [.required("provider")], subject: ["provider"],tool: "provider",
                  input: verb("test"), read: true),
        AppAction("provider.refresh", "providers", "Refresh", tool: "provider", input: verb("refresh_models")),
        AppAction("provider.cancel_refresh", "providers", "Cancel the model catalog refresh", tool: "provider", input: verb("cancel_refresh")),
        AppAction("provider.set_fallback_model", "providers", "Model it falls back to", [.required("provider"), .required("model")], subject: ["provider"],
                  tool: "provider", input: verb("set_default_model")),
        // Opening the protected entry is an ask, not the credential: only the person types the key or signs in there.
        AppAction("provider.sign_in", "providers", "Sign in", [.required("provider")], subject: ["provider"],
                  tool: "connections", input: verb("provider_sign_in")),
        AppAction("provider.disconnect", "providers", "Disconnect", [.required("provider")], subject: ["provider"],
                  owner: .person("only the person can sign back in, and disconnects on Providers", name: "Disconnecting an AI account"), irreversible: true,
                  capabilities: [.appDataWrite, .safeRead, .toolCall], tool: "provider", input: verb("disconnect")),

        // Connector and pairing controls may lower access, never raise it. A switch's change names the position it moves to (value).
        AppAction("connector.off", "connectors", "Turn off", [.required("id"), .optional("reason"), .optional("value", .boolean)], subject: ["id"], tool: "connections",
                  input: verb("connector_off")),
        AppAction("connector.on", "connectors", "Turn on", [.required("id"), .optional("value", .boolean)], subject: ["id"],
                  owner: .person("it raises Trust; the person turns it on in Connectors",
                      name: "Turning a connector on"), tool: "connections", input: verb("connector_on")),
        AppAction("connector.disconnect", "connectors", "Disconnect", [.required("id")], subject: ["id"],
                  owner: .person("only the person can sign back in, and disconnects in Connectors", instead: "connector.off stops one",
                      name: "Disconnecting a connected account"),
                  irreversible: true, capabilities: [.appDataWrite, .safeRead, .toolCall], tool: "connections", input: verb("connector_disconnect")),
        AppAction("telegram.repair", "telegram", "Rebuild admission index", [.required("inbox")], tool: "connections",
                  input: verb("telegram_repair")),
        // Irreversible: this sends a real Telegram message to the user.
        AppAction("telegram.test", "telegram", "Send test reply", irreversible: true, toolClass: .send, capabilities: [.appDataWrite, .safeRead,
            .toolCall], tool: "connections",
                  input: verb("telegram_test")),
        AppAction("telegram.clear_logs", "telegram", "Clear logs", irreversible: true, capabilities: [.appDataWrite, .safeRead, .toolCall],
            tool: "connections",
                  input: verb("telegram_clear_logs")),
        AppAction("telegram.disconnect", "telegram", "Remove the token",
                  owner: .person("only the person can sign back in; Connectors → Telegram",
                             instead: "setting.set with setting telegram.enabled, value false stops it", name: "Removing the Telegram bot token"),
                  irreversible: true, capabilities: [.appDataWrite, .safeRead, .toolCall], tool: "connections", input: verb("telegram_disconnect")),
        AppAction("pairing.remove", "pairing", "Remove the phone", [.required("id")], subject: ["id"],
                  owner: .person("only the person can pair it again; Connectors → iPhone", name: "Removing a paired iPhone"), irreversible: true,
                  capabilities: [.appDataWrite, .safeRead, .toolCall], tool: "connections", input: verb("pairing_remove")),

        AppAction("doctor.run", "diagnostics", "Run Doctor checks",tool: "doctor_status", input: ["repair": .bool(false)], read: true),
        AppAction("doctor.repair", "diagnostics", "Repair", [.optional("check_id")], subject: ["check_id"], tool: "doctor_status", input: ["repair": .bool(true)]),
        AppAction("doctor.support_report", "diagnostics", "Support report: the app's diagnostic bundle to send to the developer", tool: "upkeep", input: verb(
            "support_report")),
        AppAction("export.bundle", "capabilities",
            "Export a verified bundle file (support:true makes the support bundle to send the developer)", [.optional("support", .boolean)], tool: "upkeep", input: verb(
            "export_bundle")),
        AppAction("backup.now", "trust", "Back up now", tool: "upkeep", input: verb("backup_now")),
        AppAction("backup.restore", "trust", "Restore", [.required("id")], subject: ["id"],
                  owner: .person("it replaces what is here now; Trust → Advanced → Backups → Restore", name: "Restoring a backup"), irreversible: true,
                  capabilities: [.appDataWrite, .safeRead, .toolCall],
                      warn: "a restore that needs it restarts NativeAgent when this turn ends, 20 seconds at most",
                  tool: "upkeep", input: verb("backup_restore")),
        ]
    }
}
