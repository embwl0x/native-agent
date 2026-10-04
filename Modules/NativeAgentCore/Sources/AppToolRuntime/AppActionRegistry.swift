import ChatOrchestration
import Foundation
import NativeAgentCore
import PersistenceCore
import Skills
import ToolRegistry
import TrustCenter

/// One button of NativeAgent's, as the `app` door offers it.
///
/// The id's last word is the button's own word, and a word means one thing on
/// every page: archive puts away, show brings forward on User's screen, clear
/// erases, approve is his below Full Mac. Each runs in process through `runFolded`,
/// so the door's call is its one pass through the gates.
public struct AppAction: Sendable {
    public enum Owner: Sendable {
        case hers
        /// Why it is User's and where he does it, and the action of hers that
        /// does the safe part instead, when there is one.
        case his(String, instead: String? = nil)
    }

    public let id: String
    /// Where User's own button is; "*" is every page.
    public let page: String
    /// The button's words.
    public let label: String
    /// `name`, `a|b` for either, `?` optional, `:type` when not a string;
    /// `:secret` is a key or token, which receipts and logs redact.
    public let args: [String]
    public let owner: Owner
    /// Cannot be taken back once done, even when it is hers.
    public let irreversible: Bool
    /// Moves User's screen or makes a sound.
    public let screen: Bool
    /// Runs in Safe too: it changes nothing Safe keeps still.
    public let safe: Bool
    /// What she must know before doing it, shown on its line.
    public let warn: String
    /// The code it runs (`runFolded`), and the input that picks the verb.
    /// The name is the retired tool's, which is also the Trust key a level
    /// User saved on that tool binds it by (`appActionOldTools`, `doorSavedBlock`).
    public let tool: String
    public let input: [String: JSONValue]
    /// Door arg name → the host call's own input key, where the two differ.
    public let rename: [String: String]
    /// A script may call it. The app's own buttons may; a folded tool may
    /// not unless its entry says so (reads and app state only), so a script
    /// never loops an outward effect.
    public let scriptable: Bool
    /// Changes nothing and raises no note, so the door reads no inbox around it.
    public let read: Bool
    /// A write a skill may make without a version from its own read: it only
    /// appends, or it sets one named thing so a second call lands the same
    /// state, and either way it cannot overwrite a change it never read.
    /// Decided per action, with the reason on its entry (skills-as-code v2.1).
    public let versionExempt: Bool
    /// Bump it when the action's behavior changes without its shape changing (a skill's pin reads it).
    public let revision: Int

    init(_ id: String, _ page: String, _ label: String, _ args: [String] = [], owner: Owner = .hers,
         irreversible: Bool = false, screen: Bool = false, safe: Bool = false, warn: String = "", tool: String = "",
         input: [String: JSONValue] = [:], rename: [String: String] = [:], scriptable: Bool = true, read: Bool = false,
         versionExempt: Bool = false, revision: Int = 1) {
        self.id = id; self.page = page; self.label = label; self.args = args; self.owner = owner
        self.irreversible = irreversible; self.screen = screen; self.safe = safe; self.warn = warn; self.tool = tool
        self.input = input; self.rename = rename; self.scriptable = scriptable; self.read = read
        self.versionExempt = versionExempt
        self.revision = revision
    }

    /// A folded tool as an action (`ToolNameAliases.foldedTools` names its
    /// id). It runs as itself: the door re-enters under the tool's own name,
    /// so that call's gates, Trust key, cards and result are the ones that apply.
    /// Args and label left out are the tool's own: every argument its schema
    /// takes, and its description's first sentence. A read may be scripted
    /// unless its entry says not (one that reaches the network); a write only
    /// when its entry says so (app state, never an outward effect).
    static func fold(_ tool: String, _ page: String, _ label: String? = nil, _ args: [String]? = nil,
                     read: Bool = false, scriptable: Bool? = nil, irreversible: Bool = false, screen: Bool = false,
                     warn: String = "", schema: LLMToolSchema? = nil, versionExempt: Bool = false) -> AppAction {
        let schema = schema ?? AppActions.foldSchemas[tool]
        return AppAction(ToolNameAliases.appAction(tool) ?? tool, page,
                         label ?? schema.map { AppActions.firstSentence(ToolNameAliases.foldedProse($0.description)) } ?? tool,
                         args ?? schema.map { ToolSignature.doorArgs($0.parametersJSON) } ?? [],
                         irreversible: irreversible, screen: screen, warn: warn, tool: tool,
                         scriptable: scriptable ?? read, read: read, versionExempt: versionExempt)
    }

    public var isHis: Bool { if case .his = owner { true } else { false } }
    public var isFold: Bool { ToolNameAliases.appAction(tool) == id || ToolNameAliases.authoredTool(id) == tool }
    /// One of an inline card's buttons, not the composer
    /// (`AppToolExecutor.runCardAction`).
    public var isCard: Bool { tool == "interaction_act" && input["target"] == nil }

    /// The args that carry a key or token (`:secret`). SecurityCenter's
    /// records and the transcript redact them too.
    public var secretArgs: [String] {
        zip(args, argSpecs).filter { $0.0.hasSuffix(":secret") }.flatMap { $0.1.names }
    }

    public var policy: AppActionPolicy {
        AppActionPolicy(isHis: isHis, irreversible: irreversible, read: read, secretArgs: secretArgs)
    }

    /// `id(args) label`, then what User needs to know about it.
    public var line: String {
        var text = "\(id)(\(args.joined(separator: ", "))) \(label)"
        if screen { text += " · screen" }
        if irreversible { text += " · irreversible" }
        if !warn.isEmpty { text += " · \(warn)" }
        if case .his(let why, let instead) = owner {
            // Under Full Mac it is hers, unless it needs User himself (no tool runs it).
            text += (tool.isEmpty ? " · User's: " : " · User's below Full Mac: ") + why
                + (instead.map { ". Instead: \($0)" } ?? "")
        }
        return text
    }

    /// `line` for `app`'s own description: a long argument list is cut to
    /// its required args and "…"; a page read lists them all.
    public var hotLine: String {
        guard args.count > 4 else { return line }
        let required = zip(args, argSpecs).filter { !$0.1.optional }.map(\.0)
        return line.replacingOccurrences(of: "(\(args.joined(separator: ", ")))",
                                          with: "(\((required + ["…"]).joined(separator: ", ")))")
    }

    /// Each arg's accepted names, and whether it may be left out.
    var argSpecs: [(names: [String], optional: Bool)] {
        args.map { raw in
            let head = raw.split(separator: ":", maxSplits: 1).first.map(String.init) ?? raw
            return (head.trimmingCharacters(in: CharacterSet(charactersIn: "?")).split(separator: "|").map(String.init),
                    head.hasSuffix("?"))
        }
    }
}

public enum AppActions {
    private static func composer(_ verb: String) -> [String: JSONValue] {
        ["target": .string("composer"), "verb": .string(verb)]
    }
    private static func verb(_ verb: String) -> [String: JSONValue] { ["verb": .string(verb)] }
    /// A note's own button, pressed through the inbox's act.
    private static func press(_ button: String) -> [String: JSONValue] {
        ["verb": .string("act"), "action": .string(button)]
    }
    private static func queue(_ action: String) -> [String: JSONValue] {
        ["verb": .string("queue"), "action": .string(action)]
    }
    /// An inline card's own button.
    private static func card(_ action: String) -> [String: JSONValue] { ["action": .string(action)] }
    private static func decision(_ decision: String) -> [String: JSONValue] { ["decision": .string(decision)] }

    /// Every button, and the settings rows behind `setting.set`. User's are
    /// his entries here. A `reason?` on a put-away action rides its receipt,
    /// so there is a record of why.
    public static let all: [AppAction] = [
        // Today's Inbox: the notes Today and the Desk count. Each id is the
        // word on the note's button; a note read lists its buttons as these ids.
        AppAction("inbox.archive", "inbox", "Archive", ["ids|id", "reason"], tool: "inbox", input: verb("archive")),
        AppAction("inbox.acknowledge", "inbox", "Acknowledge", ["ids|id", "reason"], tool: "inbox", input: verb("archive")),
        AppAction("inbox.dismiss", "inbox", "Dismiss", ["ids|id", "reason"], tool: "inbox", input: verb("dismiss")),
        AppAction("inbox.mark_read", "inbox", "Mark read (opening a note does this)", ["ids|id", "reason"],
                  tool: "inbox", input: verb("mark_read")),
        AppAction("inbox.repair", "inbox", "Repair", ["id"], tool: "inbox", input: verb("repair")),
        AppAction("inbox.act", "inbox", "Act", ["id", "action?"], irreversible: true, tool: "inbox", input: verb("act")),
        AppAction("inbox.clean_up", "inbox", "Clean Up", ["id"], tool: "inbox", input: press("act")),
        AppAction("inbox.open_approvals", "inbox", "Open Approvals", ["id"], tool: "inbox", input: press("open_approvals")),
        AppAction("inbox.not_now", "inbox", "Not now", ["id", "reason?"], irreversible: true,
                  warn: "declines the card. User's own Not now wakes the conversation that raised it; yours does not: "
                      + "the card retires and that request does not run again",
                  tool: "inbox", input: verb("not_now")),
        AppAction("inbox.withdraw", "inbox", "Withdraw my own pending approval", ["id", "reason?"], irreversible: true,
                  tool: "inbox", input: verb("withdraw")),
        AppAction("inbox.open_on_mac", "inbox", "Open on Mac", ["id"], owner: .his("it opens the card for User at the Mac",
                  instead: "inbox.not_now declines it; inbox.archive retires a stale one"), tool: "inbox", input: press("act")),
        AppAction("inbox.approve", "inbox", "Approve", ["id"], owner: .his("it is his consent; he approves on Today or the banner"),
                  irreversible: true, tool: "inbox", input: press("approve")),
        AppAction("inbox.deny", "inbox", "Deny", ["id"], owner: .his("it decides an approval; he answers on Today or the banner"),
                  irreversible: true, tool: "inbox", input: press("reject")),

        // Chat: the sidebar and the conversation's own controls.
        AppAction("chat.list", "chat", "Conversations, newest first", ["archived?:bool", "offset?:int"], safe: true,
                  tool: "chat_conversations", read: true),
        AppAction("chat.new", "chat", "New chat", ["title?"], tool: "chat_session", input: verb("new")),
        AppAction("chat.show", "chat", "Show", ["session_id"], screen: true, tool: "chat_session", input: verb("show")),
        AppAction("chat.rename", "chat", "Rename", ["session_id", "title"], tool: "chat_session", input: verb("rename")),
        AppAction("chat.pin", "chat", "Pin", ["session_id?"], tool: "chat_session", input: verb("pin")),
        AppAction("chat.unpin", "chat", "Unpin", ["session_id?"], tool: "chat_session", input: verb("unpin")),
        AppAction("chat.archive", "chat", "Archive", ["session_id?", "reason?"], tool: "chat_session", input: verb("archive")),
        AppAction("chat.stop", "chat", "Stop", ["session_id?"], tool: "chat_session", input: verb("stop")),
        AppAction("chat.regenerate", "chat", "Regenerate", ["session_id?"], irreversible: true,
                  tool: "chat_session", input: verb("regenerate")),
        AppAction("chat.steer", "chat", "Steer (queue)", ["turn_id", "session_id?"], tool: "chat_session",
                  input: queue("steer")),
        AppAction("chat.send_next", "chat", "Send next (queue)", ["turn_id?", "session_id?"], tool: "chat_session",
                  input: queue("send_next")),
        // Irreversible (flag audit, 10-02): the queued message is dropped from
        // memory, and nothing keeps User's words to bring back.
        AppAction("chat.remove", "chat", "Remove (queue)", ["turn_id", "session_id?", "reason?"], irreversible: true,
                  tool: "chat_session", input: queue("remove")),
        AppAction("chat.compact", "chat", "Compact now", ["session_id?"], tool: "chat_session", input: verb("compact_now")),
        AppAction("chat.export", "chat", "Export to Markdown", ["session_id?"], tool: "chat_session", input: verb("export")),
        AppAction("chat.detach", "chat", "Open in its own window", ["session_id?"], screen: true,
                  tool: "chat_session", input: verb("detach")),
        AppAction("chat.close_window", "chat", "Close its window", ["session_id?"], screen: true,
                  tool: "chat_session", input: verb("close_window")),
        AppAction("chat.clear", "chat", "/clear", ["session_id"],
                  owner: .his("it loses the messages for good; he types /clear in it"), irreversible: true,
                  tool: "chat_session", input: verb("clear")),
        // The composer.
        AppAction("chat.draft", "chat", "Draft", ["value", "session_id?", "attachments?:list"],
                  tool: "interaction_act", input: composer("set_draft")),
        AppAction("chat.send", "chat", "Send", ["value?", "session_id?", "attachments?:list"], irreversible: true,
                  tool: "interaction_act", input: composer("send")),
        AppAction("chat.model", "chat", "Model", ["provider", "model", "session_id?"], tool: "interaction_act",
                  input: composer("set_model"), rename: ["provider": "value", "model": "choice"]),
        AppAction("chat.think", "chat", "Thinking", ["level", "session_id?"], tool: "interaction_act",
                  input: composer("set_think"), rename: ["level": "value"]),
        AppAction("chat.fast", "chat", "Fast", ["value:on|off", "session_id?"], tool: "interaction_act",
                  input: composer("set_fast")),
        AppAction("chat.open_card", "chat", "Open the composer's card", ["card:model|think|trust|context"], screen: true,
                  tool: "interaction_act", input: composer("open_card"), rename: ["card": "value"]),
        AppAction("chat.close_card", "chat", "Close the composer's card", screen: true,
                  tool: "interaction_act", input: composer("close_card")),
        AppAction("chat.speak", "chat", "Read aloud", ["value"], screen: true, tool: "interaction_act",
                  input: composer("speak")),
        AppAction("chat.scratch", "chat", "Scratch", ["key", "value", "session_id?"], tool: "interaction_act",
                  input: composer("write_scratch"), rename: ["key": "choice"]),
        AppAction("page.show", "*", "Go to page", ["page", "item?"], screen: true, tool: "interaction_act",
                  input: composer("set_page"), rename: ["page": "value", "item": "choice"]),
        AppAction("browser.show", "chat", "Show the browser", screen: true, tool: "interaction_act",
                  input: composer("show_browser")),
        AppAction("persona.set", "personality", "Switch persona", ["name"], screen: true, tool: "interaction_act",
                  input: composer("set_persona"), rename: ["name": "value"]),
        AppAction("app.check_updates", "settings", "Check for Updates", safe: true, tool: "interaction_act",
                  input: composer("check_updates")),
        // Settings rows: owner_only rows stay his, lower-only rows move the safe way.
        AppAction("setting.set", "*", "Set", ["setting", "value:any"], tool: "app_setting_set"),
        AppAction("page.screenshot", "*", "Screenshot, drawn offscreen", ["page", "height?:int"], safe: true,
                  tool: "app_page_screenshot", read: true),
        // Inline cards, by the interaction id the chat read or the card's inbox
        // note lists, in whichever conversation raised them. Whose card it is
        // and what it moves are decided per card:
        // a card from User's phone or Telegram, or one that raises what you may
        // reach below Full Mac, stays his and says so.
        // Irreversible (flag audit, 10-02): the card's own button does what it
        // asked, as inbox.approve does, and nothing presses it back.
        AppAction("card.answer", "chat", "The card's own button (its Do: line)", ["id", "value?:secret", "choice?"],
                  irreversible: true, warn: "never ask User for a key or token in chat: he types it into the card",
                  tool: "interaction_act", input: card("primary"), rename: ["id": "interaction_id"]),
        AppAction("card.not_now", "chat", "Not now", ["id", "reason?"], irreversible: true, tool: "interaction_act",
                  input: card("decline"), rename: ["id": "interaction_id"]),
        // Irreversible (flag audit, 10-02): it runs the card's own control as
        // card.answer does, a capability grant included.
        AppAction("card.try_again", "chat", "Try again", ["id", "value?:secret", "choice?"], irreversible: true,
                  tool: "interaction_act",
                  input: card("retry"), rename: ["id": "interaction_id"]),

        // Providers.
        // Version-exempt: a test changes nothing, so it has no target to version.
        AppAction("provider.test", "providers", "Test the connection", ["provider"], safe: true, tool: "provider",
                  input: verb("test"), versionExempt: true),
        AppAction("provider.refresh", "providers", "Refresh", tool: "provider", input: verb("refresh_models")),
        AppAction("provider.set_fallback_model", "providers", "Model it falls back to", ["provider", "model"],
                  tool: "provider", input: verb("set_default_model")),
        AppAction("provider.sign_in", "providers", "Sign in",
                  owner: .his("he signs in through the browser window Providers → Sign in opens, or pastes the key there")),
        AppAction("provider.disconnect", "providers", "Disconnect", ["provider"],
                  owner: .his("only he can sign back in; he disconnects on Providers"), irreversible: true,
                  tool: "provider", input: verb("disconnect")),

        // Connectors, Telegram, MCP and the paired phone: down, never up.
        AppAction("connector.off", "connectors", "Turn off", ["id", "reason?"], tool: "connections", input: verb("connector_off")),
        AppAction("connector.on", "connectors", "Turn on", ["id"], owner: .his("it raises Trust; he turns it on in Connectors"),
                  tool: "connections", input: verb("connector_on")),
        AppAction("connector.disconnect", "connectors", "Disconnect",
                  owner: .his("only he can sign back in; he disconnects in Connectors", instead: "connector.off stops one"),
                  irreversible: true, tool: "connections", input: verb("connector_disconnect")),
        // Irreversible (flag audit, 10-02): a real message to User's Telegram.
        AppAction("telegram.test", "telegram", "Send test reply", irreversible: true, tool: "connections",
                  input: verb("telegram_test")),
        AppAction("telegram.clear_logs", "telegram", "Clear logs", irreversible: true, tool: "connections",
                  input: verb("telegram_clear_logs")),
        AppAction("telegram.disconnect", "telegram", "Remove the token",
                  owner: .his("only he can sign back in; Connectors → Telegram",
                             instead: "setting.set with setting telegram.enabled, value false stops it"),
                  irreversible: true, tool: "connections", input: verb("telegram_disconnect")),
        AppAction("pairing.remove", "pairing", "Remove the phone", ["id"],
                  owner: .his("only he can pair it again; Connectors → iPhone"), irreversible: true,
                  tool: "connections", input: verb("pairing_remove")),
        AppAction("mcp.warm", "mcp", "Warm", ["server_id"], tool: "connections", input: verb("mcp_warm")),
        AppAction("mcp.restart", "mcp", "Restart", ["server_id"], tool: "connections", input: verb("mcp_restart")),
        AppAction("mcp.refresh", "mcp", "Refresh", ["server_id"], tool: "connections", input: verb("mcp_refresh")),
        AppAction("mcp.revoke_consent", "mcp", "Revoke", ["id"],
                  owner: .his("consent is his; he revokes it in Connectors → MCP"), irreversible: true,
                  tool: "connections", input: verb("mcp_revoke_consent")),

        // Upkeep buttons, on the pages that carry them.
        AppAction("doctor.repair", "diagnostics", "Repair", tool: "doctor_status", input: ["repair": .bool(true)]),
        AppAction("doctor.support_report", "diagnostics", "Support report", tool: "upkeep", input: verb("support_report")),
        AppAction("export.bundle", "capabilities", "Export", ["support?:bool"], tool: "upkeep", input: verb("export_bundle")),
        AppAction("backup.now", "trust", "Back up now", tool: "upkeep", input: verb("backup_now")),
        AppAction("backup.restore", "trust", "Restore", ["id"],
                  owner: .his("it replaces what is here now; Trust → Backups → Restore"), irreversible: true,
                  warn: "a restore that needs it restarts NativeAgent when this turn ends, 20 seconds at most",
                  tool: "upkeep", input: verb("backup_restore")),
        AppAction("history.clear", "trust", "Delete all recorded activity",
                  owner: .his("it cannot be undone; Trust → Delete all recorded activity"), irreversible: true,
                  tool: "upkeep", input: verb("activity_wipe")),
        AppAction("embeddings.pause", "settings", "Pause the memory-search download", tool: "upkeep",
                  input: verb("embeddings_pause")),
        AppAction("embeddings.resume", "settings", "Resume the memory-search download", tool: "upkeep",
                  input: verb("embeddings_resume")),
        AppAction("embeddings.release", "settings", "Release now", tool: "upkeep", input: verb("embeddings_release")),
        AppAction("memory.reindex", "memories", "Spotlight reindex", tool: "upkeep", input: verb("spotlight_reindex")),
        AppAction("memory.consolidate", "memories", "Consolidate now", tool: "upkeep", input: verb("consolidate_now")),
        AppAction("memory.hygiene", "memories", "Hygiene now", tool: "upkeep", input: verb("hygiene_now")),
        // Her memories, through MemoryCuration.
        AppAction("memory.list", "memories", "Your memories in pages, newest first (sort oldest_first for the other way); "
                  + "follow next_after_id while remaining is above 0. status archived: the ones a merge, a newer fact or "
                  + "a correction retired, each with what replaced it",
                  ["status?", "sort?", "offset?:int", "after_id?", "limit?:int", "kind?"], safe: true, tool: "list_memories",
                  read: true),
        AppAction("memory.rewrite", "memories", "Rewrite, pin, unpin or restore a memory",
                  ["id", "text?", "pinned?:bool", "restore?:bool", "reason?"],
                  warn: "text is the thing itself, one or two sentences, no date, source, ids or preamble; "
                      + "a restore that matches something forgotten stays archived",
                  // Not version-exempt: a text rewrite or a restore can overwrite
                  // another conversation's correction. The supersede demotion
                  // is memory.commit's supersedes, which is.
                  tool: "rewrite_memory"),
        AppAction("memory.pin", "memories", "Pin a memory to your prompt core, in pin order", ["id"],
                  tool: "rewrite_memory", input: ["pinned": .bool(true)]),

        // Her mind: Dreams (Personality), Self-Improvement and standing views
        // (Today), the Observatory (Diagnostics → Cognition).
        AppAction("mind.dream", "personality", "Run a dream pass", tool: "mind_run", input: verb("dream")),
        AppAction("mind.rem", "personality", "Run a REM pass", tool: "mind_run", input: verb("rem")),
        AppAction("mind.self_improvement", "today", "Self-Improvement: Run now", tool: "mind_run",
                  input: verb("self_improvement")),
        AppAction("mind.decline_view", "today", "Decline a proposed standing view", ["view_id", "reason?"], irreversible: true,
                  tool: "mind_run", input: verb("decline_view")),
        AppAction("mind.approve_view", "today", "Approve a standing view", ["view_id"],
                  owner: .his("a standing view is his to sign"), tool: "mind_run", input: verb("approve_view")),
        AppAction("mind.think_now", "diagnostics", "Think now", tool: "mind_run", input: verb("think_now")),
        // Phase 5 B0: why something surfaced, and her two corrections.
        AppAction("mind.why", "personality", "Why a felt cue or memory surfaced on a turn (default: the last one)",
                  ["turn?"], safe: true, tool: "mind_run", input: verb("why"), read: true),
        AppAction("mind.reject", "personality",
                  "Stop a memory, view, thought or dream phrase surfacing for this kind of thing (source from mind.why)",
                  ["source", "turn?", "always?:bool"], tool: "mind_run", input: verb("reject")),
        AppAction("mind.undo", "personality",
                  "Undo one update of yours (a view, a thought, an undertone nudge); no item lists them",
                  ["item?"], tool: "mind_run", input: verb("undo")),
        // Phase 5 D1: her seat revises her own opinion, with the evidence.
        AppAction("mind.revise", "personality",
                  "Revise one of your opinions: what you think now and the evidence or argument that changed it",
                  ["view_id", "view", "evidence", "unless?"], tool: "mind_run", input: verb("revise")),
        AppAction("mind.reflect", "diagnostics", "Reflect", tool: "mind_run", input: verb("reflect")),
        AppAction("mind.settle_body", "diagnostics", "Settle body", tool: "mind_run", input: verb("settle_body")),
        AppAction("mind.reset_body", "diagnostics", "Reset body", tool: "mind_run", input: verb("reset_body")),
        AppAction("mind.pin_concern", "diagnostics", "Pin concern", tool: "mind_run", input: verb("pin_concern")),
        AppAction("mind.run_checks", "diagnostics", "Run checks", tool: "mind_run", input: verb("run_checks")),
        AppAction("mind.export_trace", "diagnostics", "Export trace", tool: "mind_run", input: verb("export_trace")),
        AppAction("mind.leave_workspace_out", "diagnostics", "Leave workspace out", tool: "mind_run",
                  input: verb("ablate_workspace")),
        AppAction("mind.include_workspace", "diagnostics", "Include workspace", tool: "mind_run",
                  input: verb("include_workspace")),
        AppAction("mind.clear", "diagnostics", "Clear the thought store",
                  owner: .his("it erases your thought store for good; Observatory → Clear",
                             instead: "mind.settle_body or mind.reset_body quiet a restless body"),
                  irreversible: true, tool: "mind_run", input: verb("clear")),

        // Skills and Tools (Diagnostics tabs).
        // Not scriptable (flag audit, 10-02): turning a script skill on admits
        // its exact digest, and a script never admits a script.
        AppAction("skill.enable", "diagnostics", "Enable", ["name"], tool: "skill_manage", input: verb("enable"),
                  scriptable: false),
        AppAction("skill.disable", "diagnostics", "Disable", ["name", "reason?"], tool: "skill_manage", input: verb("disable")),
        AppAction("skill.delete", "diagnostics", "Delete (to the trash)", ["name", "reason?"], tool: "skill_manage", input: verb("delete")),
        // An archived one comes back on, its script admitted again.
        AppAction("skill.restore", "diagnostics", "Restore", ["name"], tool: "skill_manage", input: verb("restore"),
                  scriptable: false),
        AppAction("skill.rollback", "diagnostics", "Roll back to the script it had before (lands drafted)", ["name"],
                  tool: "skill_manage", input: verb("rollback"), scriptable: false),
        // A script skill's run (skills-as-code PR 3, `doorSkill`): only the
        // actions it declares, and a step that can't be taken back, is User's
        // or would card him hands back to her before it runs. Never scripted.
        AppAction("skill.run", "diagnostics", "Run a script skill, args by the params its signature shows", ["name", "args?:object"],
                  warn: "preview:true says where each step would hand back or card, and runs nothing",
                  tool: "skill_manage", input: verb("run"), scriptable: false),
        AppAction("skill.resume", "diagnostics", "Resume a skill run that stopped to ask you or handed a step back",
                  ["run_id", "answer?:any"], warn: "the step it stopped at returns answer",
                  tool: "skill_manage", input: verb("resume"), scriptable: false),
        AppAction("tool.quarantine", "diagnostics", "Quarantine", ["tool_id", "reason?"], tool: "skill_manage",
                  input: verb("tool_quarantine")),
        AppAction("tool.auto_run_off", "diagnostics", "Auto-run off", ["tool_id", "reason?"], tool: "skill_manage",
                  input: verb("tool_auto_run_off")),
        // One lifecycle with skills (`CapabilityLifecycle`): an archived tool
        // comes back active; rollback proposes the version before, drafted.
        AppAction("tool.restore", "diagnostics", "Restore", ["tool_id"],
                  owner: .his("turning a tool you wrote back on is his; Tools page"), tool: "skill_manage",
                  input: verb("tool_restore"), scriptable: false),
        AppAction("tool.rollback", "diagnostics", "Roll back to the version before (lands proposed)", ["tool_id"],
                  tool: "skill_manage", input: verb("tool_rollback"), scriptable: false),
        AppAction("tool.approve", "diagnostics", "Approve", ["tool_id"],
                  owner: .his("activating a tool you wrote is his; Tools page"), tool: "skill_manage",
                  input: verb("tool_approve")),
        AppAction("tool.auto_run_on", "diagnostics", "Auto-run on", ["tool_id"],
                  owner: .his("letting a tool you wrote run on its own is his; Tools page"),
                  tool: "skill_manage", input: verb("tool_auto_run_on")),
        // Her authoring surface: a tool she writes is filed as a proposal and
        // becomes the action authored.<tool_id> once it is approved.
        AppAction("tool.propose", "diagnostics", "Write a tool",
                  ["tool_id", "description", "code", "tests:list", "permissions?:list", "input_schema?:any"],
                  warn: "code is tool.swift, Swift: its input JSON on stdin, its result JSON on stdout; tests is at least "
                      + "one {input, expected} case; permissions from app_data_read, app_data_write, network_localhost, "
                      + "network, network_public, computer_files, arbitrary_file_write, shell, and a tool that only reads "
                      + "declares app_data_read alone, the one kind a script may call. It waits on the Tools page until "
                      + "tool.approve activates it, then runs as authored.<tool_id>",
                  tool: "skill_manage", input: verb("tool_propose"), scriptable: false),

        // The Desk.
        AppAction("desk.deny", "desk", "Deny", ["id", "reason?"], irreversible: true, safe: true, tool: "workshop_reject"),
        AppAction("desk.approve", "desk", "Approve", ["id"], owner: .his("approving a waiting step is his; the Desk"),
                  tool: "workshop_reject", input: decision("approve")),

        // MY QUEUE (Wave 2 #7): steps she means to do later, kept on her Desk
        // until she marks each done or dropped.
        // Version-exempt: done and drop close the one step their id names, and
        // a second close finds it no longer open and changes nothing.
        // add (decided 10-02, PR 4): it appends, a new step, or a newer step
        // ref on the open step with the same words (MyQueue.add keeps the old
        // ref, newest wins), and the same call again changes nothing.
        AppAction("queue.add", "desk", "Queue a step for later in MY QUEUE, in your own words", ["text", "when?", "action?"],
                  safe: true, warn: "when is next_turn (the default), own_turn, when_user_messages with an optional door, "
                      + "after_card <approval id> or at <ISO time>; action is the call you mean to make then",
                  tool: "my_queue", input: verb("add"), versionExempt: true),
        AppAction("queue.done", "desk", "Mark a MY QUEUE step done", ["id", "reason?"], safe: true, tool: "my_queue",
                  input: verb("done"), versionExempt: true),
        AppAction("queue.drop", "desk", "Drop a MY QUEUE step", ["id", "reason?"], safe: true, tool: "my_queue",
                  input: verb("drop"), versionExempt: true),

        // Folded tools. Reads: a script may call them, and no inbox is read around them.
        .fold("time_now", "*", "The date and time now: local, UTC, epoch, weekday and day of year", read: true),
        .fold("context_expand", "chat", "Read deeper context by its offered atom id or a history: id from a replayed receipt; offset defaults to 0, pages cap at 12000 characters, continue with next_offset until null",
              ["atom_id", "max_characters?:int", "offset?:int"], read: true),
        .fold("inner_state", "personality",
              "Your inner state, from your organs' record; asked how you feel, read this first, then speak",
              ["window_hours?:int", "detail?:compact|full"], read: true),
        .fold("agent_introspect", "diagnostics", "Your live runtime, provider and conversation identity",
              ["detail?:compact|full"], read: true),
        .fold("list_skills", "diagnostics", "Skill names, triggers, descriptions and status", read: true),
        .fold("read_skill", "diagnostics", "One skill's body by name, when its triggers match this work; step reads one step of a script skill",
              ["name", "step?:int"], read: true),
        .fold("recent_trace_summary", "diagnostics", "Recent turn traces; turn_id + fields reads secret-redacted values (8 KiB cap)",
              ["limit?:int", "kind?", "status?", "session_id?", "turn_id?", "fields?:[str]"], read: true),

        // Her own state (phase 2 step 2): the Desk, its task ledger, Workshop
        // and schedules; memory; helpers; persona and skills; studio and mind.
        .fold("desk_read", "desk", "Your Desk: open items with status, cadence and refs, newest active first; "
              + "handle reads one item whole, query searches every live item", read: true),
        .fold("desk_add_item", "desk", scriptable: true),
        .fold("desk_note", "desk", scriptable: true),
        .fold("desk_set_status", "desk", scriptable: true),
        .fold("desk_update_item", "desk", scriptable: true),
        .fold("desk_add_ref", "desk", scriptable: true),
        .fold("desk_blocked_on", "desk", scriptable: true),
        .fold("desk_defer", "desk", scriptable: true),
        .fold("desk_breakdown", "desk", scriptable: true),
        .fold("desk_close", "desk", scriptable: true),
        .fold("desk_archive", "desk", scriptable: true),
        .fold("desk_work_log", "desk", scriptable: true),
        .fold("desk_set_cadence", "desk", scriptable: true),
        .fold("desk_set_notify", "desk"),
        .fold("desk_nag_control", "desk"),
        .fold("desk_open_pursuit", "desk"),
        .fold("task_ledger_list", "desk", read: true),
        .fold("task_ledger_post", "desk"),
        .fold("workshop_status", "desk", read: true),
        .fold("workshop_submit", "desk"),
        .fold("scheduler_list_jobs", "desk", read: true),
        .fold("scheduler_create_job", "desk"),
        .fold("scheduler_update_job", "desk"),
        .fold("scheduler_pause_job", "desk", scriptable: true),
        .fold("scheduler_resume_job", "desk"),
        .fold("scheduler_cancel_job", "desk", scriptable: true),
        .fold("scheduler_delete_job", "desk", scriptable: true),
        .fold("recall_memory", "memories", read: true),
        // Version-exempt: it appends a new memory; supersedes demotes the ids it
        // names, which a repeat leaves demoted.
        .fold("commit_memory", "memories", "Save a fact, decision or preference for later recall. text is the thing "
              + "itself, plain: no dates, sources, ids or 'note:' framing; supersedes names memory ids this replaces", scriptable: true,
              versionExempt: true),
        .fold("memory_moments_pending", "memories", read: true),
        .fold("memory_moment_review", "memories", scriptable: true),
        .fold("forget_memory", "memories", irreversible: true),
        .fold("search_kg", "memories", read: true),
        .fold("rebuild_knowledge_graph", "memories"),
        .fold("scratchpad_read", "chat", read: true),
        .fold("bot_list", "bots", read: true),
        .fold("shelf_read", "bots", read: true),
        .fold("shelf_entry", "bots"),
        .fold("bot_ask", "bots"),
        .fold("bot_run_once", "bots"),
        .fold("bot_create", "bots"),
        .fold("bot_update", "bots"),
        .fold("bot_pause", "bots", scriptable: true),
        .fold("bot_delete", "bots"),
        .fold("get_persona_doc", "personality", read: true),
        .fold("persona_read", "personality", read: true),
        .fold("persona_write", "personality"),
        .fold("persona_append_section", "personality"),
        .fold("save_skill", "diagnostics"),
        .fold("studio_journal", "personality", scriptable: true),
        .fold("studio_journal_amend", "personality", scriptable: true),
        .fold("studio_recall", "personality", read: true),
        .fold("studio_consult", "personality", scriptable: true),
        .fold("studio_consult_read", "personality", read: true),
        .fold("studio_shelf_read", "personality", read: true),
        .fold("studio_shelf_set", "personality", scriptable: true),
        .fold("studio_canon", "personality", read: true),
        .fold("studio_canon_resolve", "personality"),
        .fold("dream_diary_read", "personality", read: true),
        .fold("hold_view", "today"),
        .fold("release_view", "today"),

        // Agents (phase 2 step 3): contacts, conversations and the coding
        // bridges. A send, connect, stop or run is never scripted (Agent, req 2),
        // and an agent's words come back through her own step.
        .fold("agent_contacts", "agents", read: true),
        .fold("agent_message", "agents"),
        .fold("agent_read", "agents"),
        .fold("agent_connect", "agents"),
        .fold("agent_cancel", "agents", "Stop the reply an agent is working on in your conversation with it"),
        .fold("delegation_status", "agents", read: true),
        .fold("agent_swarm", "agents", "Run temporary workers on an objective; reasoning_effort sets the run's Think level or each worker's; defaults to Work thinking (providers.work_thinking)"),
        .fold("codex_message", "agents"),
        .fold("invoke_codex", "agents"),
        .fold("omp_message", "agents"),

        // Integrations (phase 2 step 4): each Mac app and connector is a page.
        // Reads may be scripted; a send, post, invite, notification or any
        // change to User's mail, calendar, reminders, notes, contacts or
        // repositories is always her own step (Agent, req 2).
        .fold("mail_list_recent", "mail", "Apple Mail's inbox or sent mailbox; with scope + message_id "
              + "+ expected_message_id, one message's body", read: true),
        .fold("mail_read_batch", "mail", read: true),
        .fold("mail_search", "mail", read: true),
        .fold("mail_triage_batch", "mail"),
        .fold("mail_mark_read", "mail"),
        .fold("mail_archive", "mail"),
        .fold("mail_delete", "mail", irreversible: true),
        .fold("mail_send", "mail"),
        .fold("mail_reply", "mail"),
        .fold("agentmail_list", "mail", read: true),
        .fold("agentmail_read", "mail", read: true),
        .fold("agentmail_send", "mail"),
        .fold("gmail_status", "mail", read: true),
        .fold("gmail_search", "mail", read: true),
        .fold("gmail_read", "mail", read: true),
        .fold("mac_calendar_list_upcoming", "calendar", read: true),
        .fold("mac_calendar_calendars", "calendar", read: true),
        .fold("mac_calendar_free_busy", "calendar", read: true),
        .fold("mac_calendar_create_event", "calendar"),
        .fold("mac_calendar_modify_event", "calendar"),
        .fold("mac_calendar_delete_event", "calendar", irreversible: true),
        .fold("google_calendar_status", "calendar", read: true),
        .fold("google_calendar_list", "calendar", read: true),
        .fold("google_calendar_calendars", "calendar", read: true),
        .fold("google_calendar_free_busy", "calendar", read: true),
        .fold("google_calendar_read", "calendar", read: true),
        .fold("google_calendar_send_invitations", "calendar"),
        .fold("mac_reminders_list_due_today", "reminders", read: true),
        .fold("mac_reminders_query", "reminders", read: true),
        .fold("mac_reminders_read", "reminders", read: true),
        .fold("mac_reminders_create", "reminders"),
        .fold("mac_reminders_update", "reminders"),
        .fold("mac_reminders_complete", "reminders"),
        .fold("mac_reminders_delete", "reminders", irreversible: true),
        .fold("notes_search", "notes", read: true),
        .fold("notes_create", "notes"),
        .fold("notes_update", "notes"),
        .fold("contacts_search", "contacts", read: true),
        .fold("contacts_create_or_update", "contacts"),
        .fold("contacts_delete", "contacts", irreversible: true),
        .fold("messages_recent_threads", "messages", read: true),
        .fold("messages_send", "messages"),
        .fold("github_status", "github", read: true),
        .fold("github_list_repos", "github", read: true),
        .fold("github_list_notifications", "github", read: true),
        .fold("github_get_repository", "github", read: true),
        .fold("github_read_repository_content", "github", read: true),
        .fold("github_list_commits", "github", read: true),
        .fold("github_list_issues", "github", read: true),
        .fold("github_search", "github", read: true),
        .fold("github_list_pull_requests", "github", read: true),
        .fold("github_get_issue", "github", read: true),
        .fold("github_get_pull_request", "github", read: true),
        .fold("github_pull_request_files", "github", read: true),
        .fold("github_pull_request_activity", "github", read: true),
        .fold("github_discover_tracking", "github"),
        .fold("github_project_digest", "github"),
        .fold("github_mutate", "github"),
        .fold("github_set_repo_visibility", "github"),
        .fold("slack_status", "slack", read: true),
        .fold("slack_list_channels", "slack", read: true),
        .fold("slack_search_messages", "slack", read: true),
        .fold("slack_post_message", "slack"),
        .fold("notion_status", "notion", read: true),
        .fold("notion_search", "notion", read: true),
        .fold("notion_read_page", "notion", read: true),
        .fold("x_status", "x", read: true),
        .fold("x_me", "x", read: true),
        .fold("x_search", "x", read: true),
        .fold("x_timeline", "x", read: true),
        .fold("x_user_tweets", "x", read: true),
        .fold("market_status", "markets", read: true),
        .fold("market_watchlists", "markets", read: true),
        .fold("market_quote", "markets", read: true),
        .fold("tradingview_watchlist", "markets", read: true),
        .fold("mac_notify", "notifications"),
        .fold("mobile_notify", "notifications"),
        .fold("phone_request", "pairing"),
        .fold("image_generate", "chat"),

        // Files, shell, the web, the browser, chat search and results (phase
        // 2 step 5). Reads of files, git, chat and her own results may be
        // scripted; a write, a patch, a command, a build, an install, anything
        // that reaches the network, a browser step or a reply never (Agent,
        // req 2). Each MCP server's tools are generated from its live list
        // (`mcp`), SearXNG's on the web page.
        .fold("read_file", "files", "Read a workspace or user-approved file", read: true),
        .fold("list_dir", "files", "List a bounded page of names in a workspace or user-approved folder", read: true),
        .fold("file_excerpt", "files", read: true),
        .fold("grep", "files", read: true),
        .fold("mac_spotlight_search", "files", read: true),
        .fold("write_file", "files"),
        .fold("apply_patch", "files"),
        .fold("git_status", "shell", read: true),
        .fold("git_diff", "shell", read: true),
        .fold("git_log", "shell", read: true),
        .fold("repo_dirty_summary", "shell", read: true),
        .fold("shell", "shell"),
        .fold("bash", "shell"),
        .fold("git", "shell"),
        .fold("swift_build", "shell"),
        .fold("swift_test", "shell"),
        .fold("remote_node_list", "shell", read: true),
        .fold("remote_node_execute", "shell"),
        .fold("evolution_status", "shell", read: true),
        .fold("evolution_propose", "shell"),
        .fold("evolution_withdraw", "shell"),
        .fold("self_install", "shell"),
        .fold("restart_app", "shell"),
        .fold("install_app", "shell"),
        .fold("read_page", "web", read: true, scriptable: false),
        .fold("browser.status", "browser", read: true),
        .fold("browser.open_url", "browser"),
        .fold("browser.read_text", "browser", read: true),
        .fold("browser.read_links", "browser", read: true),
        .fold("browser.screenshot", "browser", read: true, scriptable: false),
        .fold("browser.chrome_setup", "browser"),
        .fold("browser.chrome_status", "browser", read: true),
        .fold("browser.chrome_snapshot", "browser", read: true),
    ] + ToolNameAliases.chromeVerbs.filter { $0 != "snapshot" }.map { .fold("browser.chrome_" + $0, "browser") } + [
        .fold("search_chat_history", "chat", read: true),
        .fold("read_chat_message", "chat", read: true),
        .fold("chat_reply", "chat"),
        .fold("tool_result_page", "*", read: true),

        // Mac control and the tools left over (phase 2 step 6). Each Mac verb
        // re-enters under its own name, so Full Mac's accessibility category,
        // MacAttention and User's saved levels judge it as before; none is
        // ever scripted, reads included. act's whole guide is the mac page's
        // read and rides its refusals (`guided`).
        .fold("screen", "mac", "Look at the live screen now, in words: the app, where you are, numbered rows, its "
              + "controls and what it says; app reads another running app's window without activating it, part zooms "
              + "in, pixels:true is a picture of the desktop", read: true, scriptable: false),
        .fold("act", "mac", "Act on the live screen by name: verb + target (click, type with text, key, select, "
              + "scroll…), or a whole flow in ONE call with steps:[…] (names, menu paths 'Format > Make Plain Text', "
              + "chords, {verb,target,text,mode}), each verified on a fresh read, stopping at the first failure; app "
              + "acts in that app's window without bringing it forward", actArgs, screen: true,
              warn: "the mac page's read has its whole guide"),
        .fold("go", "mac", "Get to an app, file, folder, http/https URL or System Settings pane, then read the fresh "
              + "screen; front:true only when the task asks to open or switch on the screen", screen: true),
        .fold("wait", "mac", read: true, scriptable: false),
        .fold("read", "mac", read: true, scriptable: false),
        .fold("menu", "mac", read: true, scriptable: false),
        .fold("menu_press", "mac", screen: true),
        .fold("clipboard_read", "mac", read: true, scriptable: false),
        .fold("clipboard_write", "mac"),
        .fold("system_info", "mac", read: true, scriptable: false),
        .fold("activity_query", "mac", read: true, scriptable: false),
        .fold("music_now_playing", "music", read: true),
        .fold("music_search_library", "music", read: true),
        .fold("music_list_library", "music", read: true),
        .fold("music_list_playlists", "music", read: true),
        .fold("music_control", "music", screen: true),
        .fold("context_lookup", "capabilities", read: true),
        .fold("request_interaction", "chat"),
        .fold("artifact_find", "chat", read: true),
        .fold("work_context", "desk", read: true),
    ]

    /// act's arguments as its schema has them, but verb and target may be left
    /// out (a flow's steps carry their own), and what it types is secret.
    static let actArgs = foldSchemas["act"].map {
        ToolSignature.doorArgs($0.parametersJSON).map {
            ["verb", "target"].contains($0) ? $0 + "?" : $0 == "text?" ? "text?:secret" : $0
        }
    }

    /// Actions whose whole guide (description and every argument) is their
    /// page's read and rides each refusal: act, whose schema carried 9 KB of it.
    public static let guided: Set<String> = ["mac.act"]

    /// Each mounted MCP server's tools as `mcp.<server>.<tool>`, from its live
    /// list: on the mcp page, SearXNG's search and fetch on the web page.
    /// Never scripted: what a server's tool reaches is the server's.
    public static func mcp(dataRoot: URL = PersistenceCore.defaultDataRoot()) -> [AppAction] {
        SwiftToolDispatcher.mountedMCPToolSchemas(dataRoot: dataRoot).map { schema in
            .fold(schema.name, schema.name.hasPrefix("mcp__searxng-local__") ? "web" : "mcp",
                  firstSentence(schema.description), schema: schema)
        }
    }

    /// Each tool she wrote that is active in her registry, as
    /// `authored.<id>` on the diagnostics page (its Tools tab), flagged by the
    /// permissions it declares: only app_data_read may be called from a script.
    /// Declared, not enforced, so none counts as a read: its effects always
    /// show in a script's receipt. One that reaches past the Mac or runs a shell or
    /// writes anywhere can't be taken back.
    public static func authored(dataRoot: URL = PersistenceCore.defaultDataRoot()) -> [AppAction] {
        SwiftToolDispatcher.authoredTools(dataRoot: dataRoot).map { tool in
            let read = !tool.permissions.isEmpty && Set(tool.permissions).isSubset(of: ["app_data_read"])
            return AppAction(ToolNameAliases.authoredAction(tool.schema.name), "diagnostics",
                             firstSentence(tool.schema.description), ToolSignature.doorArgs(tool.schema.parametersJSON),
                             irreversible: !Set(tool.permissions).isDisjoint(with: authoredIrreversible),
                             warn: "your tool; declares " + (tool.permissions.isEmpty ? "no permissions" : tool.permissions.joined(separator: ", ")),
                             tool: tool.schema.name, scriptable: read, read: false)
        }
    }

    /// Her archived tools an ask names, each as its action line would read, marked archived.
    static func archivedTools(_ asked: [String], dataRoot: URL = PersistenceCore.defaultDataRoot()) -> [String] {
        ToolRegistryActions.archived(dataRoot: dataRoot).filter { hits(Set(words($0.id + " " + $0.about)), asked) > 0 }
            .map { "\(ToolNameAliases.authoredAction($0.id)) (archived): \(firstSentence($0.about))" }
    }

    /// What a tool she wrote can't take back: a shell, a write anywhere, the network.
    static let authoredIrreversible: Set<String> = ["shell", "arbitrary_file_write", "network", "network_public"]

    /// Her installed skills an ask names, best first. A skill is guidance she
    /// reads, not an action, so find offers each by the skill.read that loads it.
    /// An archived one is found too, marked archived (`CapabilityLifecycle`).
    static func skills(_ asked: [String], dataRoot: URL = PersistenceCore.defaultDataRoot()) -> [(name: String, about: String)] {
        InstalledSkillInventory.list(dataRoot: dataRoot).compactMap { row -> (name: String, about: String, score: Int)? in
            guard case .object(let skill) = row, case .string(let name)? = skill["name"] else { return nil }
            let text = { (value: JSONValue?) -> String in if case .string(let s)? = value { s } else { "" } }
            let archived = skill["status"] == .string(CapabilityLifecycle.archived)
            guard InstalledSkillInventory.isAvailable(skill) || archived else { return nil }
            let triggers = if case .array(let list)? = skill["triggers"] { list.map { text($0) } } else { [String]() }
            // Every skill is a skill: that word alone matches none of them.
            let score = hits(Set(words(([name, text(skill["description"])] + triggers).joined(separator: " "))),
                             asked.filter { !["skill", "skills"].contains($0) })
            return score > 0 ? (name, (archived ? "(archived) " : "") + text(skill["description"]), score) : nil
        }.enumerated().sorted { $0.element.score != $1.element.score ? $0.element.score > $1.element.score : $0.offset < $1.offset }
            .map { ($0.element.name, $0.element.about) }
    }

    /// The folded tools' own schemas, built once: a fold's args and label are
    /// its tool's, and its whole description answers a call that went wrong.
    static let foldSchemas: [String: LLMToolSchema] = Dictionary(
        BuiltInToolSchemaFactory(requestedNames: Set(ToolNameAliases.foldedTools.keys)).schemas(
            includeFullMacFileTools: true, includeFullMacSystemTools: true,
            includeFullMacAccessibilityReadTools: true, includeFullMacAccessibilityInjectionTools: true,
            includeActivityQueryTool: true
        ).map { ($0.name, $0) } + AppToolExecutor.appToolSchemas(includeDoor: false).map { ($0.name, $0) },
        uniquingKeysWith: { first, _ in first })

    /// A folded tool's whole description, its old tool names read as action
    /// ids; an MCP tool's from its server's live list. A guided action's
    /// carries every argument's own words too.
    public static func about(_ action: AppAction) -> String? {
        guard action.isFold else { return nil }
        let root = PersistenceCore.defaultDataRoot()
        let schema = foldSchemas[action.tool]
            ?? (ToolNameAliases.mcpAction(action.tool) == nil ? nil
                : SwiftToolDispatcher.mountedMCPToolSchemas(dataRoot: root).first { $0.name == action.tool })
            ?? (ToolNameAliases.authoredTool(action.id) == nil ? nil
                : SwiftToolDispatcher.authoredTools(dataRoot: root).first { $0.schema.name == action.tool }?.schema)
        guard let schema else { return nil }
        let args = guided.contains(action.id)
            ? "\nArgs:\n" + ToolSignature.params(schema.parametersJSON, limit: .max).joined(separator: "\n") : ""
        return ToolNameAliases.foldedProse(schema.description + args)
    }

    static func firstSentence(_ text: String) -> String {
        guard let end = text.range(of: ". ") else {
            return text.hasSuffix(".") ? String(text.dropLast()) : text
        }
        return String(text[..<end.lowerBound])
    }

    /// Named in `app`'s own description, so a cold call needs no read first.
    /// Static: it changes only at a release.
    public static let hot = ["time.now", "context.expand", "mind.inner_state", "agent.introspect", "skill.list",
                             "skill.read", "trace.recent", "desk.read", "memory.recall", "memory.commit",
                             "bot.reply", "agent.contacts", "agent.message", "agent.read", "agent.connect",
                             "agent.jobs", "codex.message", "mail.recent",
                             "calendar.upcoming", "files.read", "files.list", "files.write", "chat.search",
                             "result.page", "mac.look", "mac.act", "mac.go"].compactMap(action)

    /// An action by id; an MCP tool's (`mcp.<server>.<tool>`, or SearXNG's
    /// `web.search` and `web.fetch`) from its server's live list; a tool she
    /// wrote (`authored.<id>`) from her registry.
    public static func action(_ id: String) -> AppAction? {
        let key = id.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        if let own = all.first(where: { $0.id == key }) { return own }
        if ToolNameAliases.authoredTool(key) != nil { return authored().first { $0.id.lowercased() == key } }
        guard ToolNameAliases.mcpTool(key) != nil || ToolNameAliases.foldedActionIDs.contains(key) else { return nil }
        return mcp().first { $0.id.lowercased() == key }
    }

    /// The actions a page read lists: its own, and the ones on every page.
    public static func on(page: String) -> [AppAction] {
        all.filter { $0.page == page || $0.page == "*" } + (["mcp", "web"].contains(page) ? mcp().filter { $0.page == page } : [])
            + (page == "diagnostics" ? authored() : [])
    }

    static func words(_ text: String) -> [String] {
        text.lowercased().split(whereSeparator: { !$0.isLetter && !$0.isNumber }).map(String.init).filter { $0.count > 1 }
    }

    /// How many of the asked words an action carries, in its id, label, page
    /// or why. A word matches its own stem ("archiving" finds archive).
    static func score(_ action: AppAction, _ asked: [String], pageTitle: String) -> Int {
        var why = ""
        if case .his(let text, let instead) = action.owner { why = text + " " + (instead ?? "") }
        return hits(Set(words([action.id, action.label, action.page, pageTitle, why].joined(separator: " "))), asked)
    }

    static func hits(_ own: Set<String>, _ asked: [String]) -> Int {
        asked.filter { word in
            own.contains(word) || own.contains { $0.count >= 4 && word.count >= 4 && ($0.hasPrefix(word) || word.hasPrefix($0)) }
        }.count
    }
}
