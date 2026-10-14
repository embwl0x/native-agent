import ChatOrchestration
import ChromeControl
import Foundation
import MemoryV2
import NativeAgentCore
import NativeAgentShared
import PersistenceCore
import Skills
import Senses
import StandingBots
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
    /// Searchable scope from the action's owning schema or surface vocabulary.
    public let scope: String
    public let schema: LLMToolSchema?
    /// `name`, `a|b` for either, `?` optional, `:type` when not a string;
    /// `:secret` is a key or token, which receipts and logs redact.
    public let args: [String]
    public let owner: Owner
    public let lifecycle: CapabilityLifecycle.Action?
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
    /// A script may call it; each call retains ordinary dispatch admission.
    public let scriptable: Bool
    /// Reads its subject and raises no note, so the door reads no inbox around it.
    public let read: Bool
    public let readWhen: [String: JSONValue]
    /// Advisory reads replay their saved answer rather than a new ranking or sampling.
    public let advisory: Bool
    /// A skill call needing no app-page version: an append, an idempotent
    /// named change, or a pinned tool contract whose target is not that page.
    /// Decided per action, with the reason on its entry (skills-as-code v2.1).
    public let versionExempt: Bool
    /// Bump for behavior changes, including result semantics, without a schema change.
    public let revision: Int
    public let resultSchema: JSONValue

    init(_ id: String, _ page: String, _ label: String, _ args: [String] = [], owner: Owner = .hers,
         irreversible: Bool = false, screen: Bool = false, safe: Bool = false, warn: String = "", tool: String = "",
         input: [String: JSONValue] = [:], rename: [String: String] = [:], scriptable: Bool = true, read: Bool = false,
         versionExempt: Bool = false, revision: Int = 1, readWhen: [String: JSONValue] = [:], scope: String = "",
         advisory: Bool = false, resultSchema: JSONValue = AppActions.resultEnvelope,
         lifecycle: CapabilityLifecycle.Action? = nil, schema: LLMToolSchema? = nil) {
        self.id = id; self.page = AppDoorNames.resolve(page); self.label = label; self.args = args; self.owner = owner
        self.irreversible = irreversible; self.screen = screen; self.safe = safe; self.warn = warn; self.tool = tool
        self.input = input; self.rename = rename; self.scriptable = scriptable; self.read = read
        self.versionExempt = versionExempt
        self.revision = revision
        self.readWhen = readWhen
        self.scope = [scope, args.joined(separator: " "), schema?.description ?? "", schema.map { String(decoding: $0.parametersJSON, as: UTF8.self) } ?? ""].filter { !$0.isEmpty }.joined(separator: " ")
        self.schema = schema
        self.advisory = advisory
        self.resultSchema = resultSchema
        self.lifecycle = lifecycle
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
                     warn: String = "", schema: LLMToolSchema? = nil, versionExempt: Bool = false,
                     readWhen: [String: JSONValue] = [:], advisory: Bool = false,
                     resultSchema: JSONValue = AppActions.resultEnvelope, lifecycle: CapabilityLifecycle.Action? = nil) -> AppAction {
        let schema = schema ?? AppActions.foldSchemas[tool]
        // Its args by the door's names (`ToolNameAliases.doorArgNames`), each renamed back as it runs.
        let names = ToolNameAliases.doorArgNames[tool] ?? [:]
        func door(_ arg: String) -> String {
            let end = arg.firstIndex { $0 == "?" || $0 == ":" } ?? arg.endIndex
            return (names[String(arg[..<end])] ?? String(arg[..<end])) + arg[end...]
        }
        return AppAction(ToolNameAliases.appAction(tool) ?? tool, page,
                         label ?? schema.map { AppActions.firstSentence(ToolNameAliases.foldedProse($0.description)) } ?? tool,
                         (args ?? schema.map { ToolSignature.doorArgs($0.parametersJSON) } ?? []).map(door)
                            + (["screen", "read", "read_file", "read_page", "browser.read_text", "browser.read_links", "browser.chrome_snapshot"].contains(tool)
                               ? ["raw?:boolean", "wrong?:boolean", "why?:string"] : []),
                         irreversible: irreversible, screen: screen, warn: warn, tool: tool,
                         rename: Dictionary(uniqueKeysWithValues: names.map { ($0.value, $0.key) }),
                         scriptable: scriptable ?? read, read: read, versionExempt: versionExempt, readWhen: readWhen,
                         advisory: advisory, resultSchema: resultSchema, lifecycle: lifecycle, schema: schema)
    }

    public var isHis: Bool { if case .his = owner { true } else { false } }
    public var isFold: Bool { ToolNameAliases.appAction(tool) == id || ToolNameAliases.authoredTool(id) == tool || (["trace.usage", "trace.model_calls"].contains(id) && tool == "recent_trace_summary") }
    /// One of an inline card's buttons, not the composer
    /// (`AppToolExecutor.runCardAction`).
    public var isCard: Bool { tool == "interaction_act" && input["target"] == nil }
    var isItemRead: Bool { tool == "app_page_read" && input["item"] != nil }

    /// The args that carry a key or token (`:secret`). SecurityCenter's
    /// records and the transcript redact them too.
    public var secretArgs: [String] {
        zip(args, argSpecs).filter { $0.0.hasSuffix(":secret") }.flatMap { $0.1.names }
    }

    public var policy: AppActionPolicy {
        AppActionPolicy(isHis: isHis, irreversible: irreversible, read: read, secretArgs: secretArgs,
                        readWhen: readWhen, lifecycle: lifecycle)
    }

    func readOnly(args: [String: JSONValue]) -> Bool { policy.readOnly(args: args) }

    func effectFields(args: [String: JSONValue] = [:]) -> [String: JSONValue] {
        let read = readOnly(args: args)
        return ["read_only": .bool(read), "irreversible": .bool(irreversible),
                "effect": .string(read ? "read" : irreversible ? "irreversible" : "write")]
    }

    /// `id(args) label`, then what User needs to know about it.
    public var line: String {
        var text = "\(id)(\(args.joined(separator: ", "))) \(label)"
        if screen { text += " · screen" }
        if irreversible { text += " · irreversible" }
        if !scriptable { text += " · not in scripts" }
        if !warn.isEmpty { text += " · \(warn)" }
        // Only while Simple view is on screen does showing a page change the view itself.
        if id == "page.show", SimpleViewMode.isShowing { text += " · " + SimpleViewMode.noPagesNote }
        if case .his(let why, let instead) = owner {
            // Under Full Mac it is hers, unless it needs User himself (no tool runs it).
            text += (tool.isEmpty ? " · the owner's: " : " · the owner's below Full Mac: ") + why
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
        AppAction("chrome.history", "browser", "Read Chrome browsing history: top domains, title/URL search or recent pages",
                  ["mode", "query?", "since?", "limit?:int"], safe: true,
                  warn: "mode: top_domains (requires since), search (requires query; optional since) or recent. since: inclusive ISO 8601 timestamp with timezone. limit: default 15, maximum 50. Reads only Chrome's Default profile, independent of the extension and tab group; times are local ISO 8601. Top-domain counts are visits since since; page counts are lifetime visits. Requires Full Mac and file-read permission; raises no card. Query deadline: 2 seconds.",
                  tool: "read_file", scriptable: false, read: true),
        AppAction("photos.count", "files", "Count Photos library assets by creation date and media type",
                  ["start?", "end?", "media_type?"], safe: true,
                  warn: "start/end: ISO 8601 timestamps with timezone, inclusive start and exclusive end. media_type: all (default), image or video. Requests macOS Photos access only when called; limited access counts only shared assets.",
                  tool: "photos_read", input: verb("count"), scriptable: false, read: true),
        AppAction("photos.recent", "files", "Read newest Photos library asset metadata: date, media type, dimensions, favorite and stored location coordinates",
                  ["limit?:int", "start?", "end?", "media_type?"], safe: true,
                  warn: "limit: 1–100, default 10, newest creation dates first. start/end: ISO 8601 timestamps with timezone, inclusive start and exclusive end. media_type: all (default), image or video. Reads metadata only; requests macOS Photos access only when called.",
                  tool: "photos_read", input: verb("recent"), scriptable: false, read: true),
        AppAction("weather.forecast", "web", "Read current weather and daily temperature high/low, rain chance, wind, sunrise and sunset from Open-Meteo",
                  ["place?", "day?", "days?:int", "hours?:int"], safe: true,
                  warn: "place is a city or postal code, qualified by state or country when needed; when omitted, asks the paired iPhone for its current location through phone.request. NativeAgent must be open on the phone; phone location permissions apply. day: today (default), tomorrow or yyyy-MM-dd within 16 days. days: 1–16 daily forecasts starting at day, in one read (a week is days:7). hours: optional 1–24 hourly forecasts, from now today or midnight on another day. Units follow the Mac's locale (°F/mph for US).",
                  tool: "weather_forecast", scriptable: false, read: true),
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
                  warn: "declines the card. The owner's own Not now wakes the conversation that raised it; yours does not: "
                      + "the card retires and that request does not run again",
                  tool: "inbox", input: verb("not_now")),
        AppAction("inbox.withdraw", "inbox", "Withdraw my own pending approval", ["id", "reason?"], irreversible: true,
                  tool: "inbox", input: verb("withdraw")),
        AppAction("inbox.open_on_mac", "inbox", "Open on Mac", ["id"], owner: .his("it opens the card for the owner at the Mac",
                  instead: "inbox.not_now declines it; inbox.archive retires a stale one"), tool: "inbox", input: press("act")),
        AppAction("inbox.approve", "inbox", "Approve", ["id"], owner: .his("it is his consent; he approves on Today or the banner"),
                  irreversible: true, tool: "inbox", input: press("approve")),
        AppAction("inbox.deny", "inbox", "Deny", ["id"], owner: .his("it decides an approval; he answers on Today or the banner"),
                  irreversible: true, tool: "inbox", input: press("reject")),

        // Chat: the sidebar and the conversation's own controls.
        AppAction("chat.list", "chat", "Conversations, newest first; query filters by title; pinned:true only pinned, pinned:false only unpinned; filters apply before offset", ["archived?:bool", "pinned?:bool", "query?", "offset?:int"], safe: true,
                  tool: "chat_conversations", read: true),
        AppAction("chat.new", "chat", "New chat; title names it in the same call", ["title?"], tool: "chat_session", input: verb("new")),
        AppAction("chat.show", "chat", "Show", ["session_id"], screen: true, tool: "chat_session", input: verb("show")),
        AppAction("chat.rename", "chat", "Rename", ["session_id", "title"], tool: "chat_session", input: verb("rename")),
        AppAction("chat.pin", "chat", "Pin", ["session_id?"], tool: "chat_session", input: verb("pin")),
        AppAction("chat.unpin", "chat", "Unpin", ["session_id?"], tool: "chat_session", input: verb("unpin")),
        AppAction("chat.archive", "chat", "Archive", ["session_id?", "reason?"], tool: "chat_session", input: verb("archive")),
        AppAction("chat.stop", "chat", "Stop", ["session_id?"], tool: "chat_session", input: verb("stop")),
        AppAction("chat.regenerate", "chat", "Regenerate (redo / try again) your last answer", ["session_id?"], irreversible: true,
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
        AppAction("chat.model", "chat", "Model (app-wide: every chat)", ["provider", "model", "session_id?"], tool: "interaction_act",
                  input: composer("set_model"), rename: ["provider": "value", "model": "choice"]),
        AppAction("chat.think", "chat", "Thinking level (app-wide: every chat)", ["level", "session_id?"], tool: "interaction_act",
                  input: composer("set_think"), rename: ["level": "value"]),
        AppAction("chat.fast", "chat", "Fast mode (app-wide: every chat)", ["value:on|off", "session_id?"], tool: "interaction_act",
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
        AppAction("browser.show", "chat", "Show your own built-in browser (NativeAgent's browser, not Chrome)", screen: true, tool: "interaction_act",
                  input: composer("show_browser")),
        AppAction("pane.show", "chat", "Open the Work pane beside chat", ["view:steps|screen|make", "ref?"], screen: true,
                  tool: "interaction_act", input: composer("show_pane"), rename: ["view": "value", "ref": "choice"]),
        AppAction("pane.hide", "chat", "Close the Work pane", screen: true, tool: "interaction_act",
                  input: composer("hide_pane")),
        // What she makes, in versions; the Work pane's Make tab shows them.
        // Version-exempt: add only appends a version, and never touches one.
        AppAction("make.add", "chat", "Add a file to Make as a new version of ref (a new ref when left out); returns the ref",
                  ["path", "ref?"], tool: "make_studio", input: verb("add"), versionExempt: true),
        AppAction("make.read", "chat", "A Make ref's versions: n, path, prompt, created (the newest ref when left out)",
                  ["ref?"], safe: true, tool: "make_studio", input: verb("read"), read: true),
        // Her own fix for a place, in her turn; then it's built.
        AppAction("sense.make", "chat", "Learn to read and understand a new kind of file, binary format, app or page so ordinary reads work from now on. code is a complete sense.js (kit: Contents/Resources/Senses in the app bundle — AUTHORING.md, sense.js starter, builtin/app.js, site.js). It runs on the place you just read (or place, its corner key) and returns the page and an exact trial_id/digest; keep that trial with trial_id, digest and keep:true without resending code. keep:true with code runs and keeps it immediately; show:\"material\" (no code) returns exactly what sense.source.read() gets",
                  ["code?", "trial_id?", "digest?", "keep?:bool", "place?", "why?", "show?", "apps?:list"],
                  warn: "apps declares bundle ids for sense.apps.read({bundle_id,dictionary:true}) or read-only Apple Events using event_class, event_id and parameters. Standard core getd/cnte/doex events are reads; other events require a tool's write declaration.", tool: "sense_make",
                  readWhen: ["show": .string("material"), "trial_id": .null, "digest": .null], lifecycle: .change),
        AppAction("sense.versions", "senses", "Read a sense's current and retained versions", ["sense_id"], safe: true, tool: "sense_lifecycle", input: ["verb": .string("versions")], read: true),
        AppAction("sense.quarantine", "chat", "Switch a sense off while retaining its current and previous versions", ["sense_id", "version:number"], tool: "sense_lifecycle", input: ["verb": .string("quarantine")], revision: 2, lifecycle: .change),
        AppAction("sense.restore", "chat", "Turn the selected sense version back on", ["sense_id"], tool: "sense_lifecycle", input: ["verb": .string("restore")], revision: 2, lifecycle: .restore),
        AppAction("sense.rollback", "chat", "Swap the current and previous sense versions; an on sense stays on, an off sense needs sense.restore", ["sense_id", "version:number"], tool: "sense_lifecycle", input: ["verb": .string("rollback")], revision: 2, lifecycle: .rollback),
        AppAction("sense.drop", "chat", "Delete a sense and its run statistics permanently", ["sense_id"], irreversible: true, tool: "sense_lifecycle", input: ["verb": .string("drop")], revision: 2, lifecycle: .drop),
        AppAction("persona.set", "personality", "Switch persona", ["name"], screen: true, tool: "interaction_act",
                  input: composer("set_persona"), rename: ["name": "value"]),
        AppAction("app.check_updates", "settings", "Check for NativeAgent updates only; macOS uses mac.system_info with check_updates:true, App Store apps use App Store → Updates", safe: true, tool: "interaction_act",
                  input: composer("check_updates"), read: true),
        // How the window lays out each surface (ui/layout.json), hers to read
        // and rewrite as the person asks; the window changes as a write lands.
        AppAction("layout.read", "settings", "The window's layout: each surface's blocks in order, hidden and expanded, each view's profile, its version, the previous layout and what every block is",
                  safe: true, tool: "app_page_read", read: true, scope: layoutScope),
        AppAction("layout.write", "settings", "Change the layout, passing layout.read's version as layout_version and only what changes (a surface's whole block list, a profile, phone); the window follows at once; undo puts the previous one back",
                  ["layout:object", "layout_version"], tool: "app_setting_set", scriptable: false, scope: layoutScope),
        // Settings rows: owner_only rows stay his, lower-only rows move the safe way.
        AppAction("setting.set", "*", "Set", ["setting", "value:any", "because"],
                  warn: "on model turns, because must quote at least 3 words from a person or trusted agent in this conversation; you may restore a switch whose last change was yours",
                  tool: "app_setting_set"),
        // Version-exempt: generated captures have no user state to overwrite.
        AppAction("page.screenshot", "*",
                  "Screenshot of one of your own NativeAgent pages (your current page, chat, settings…), drawn offscreen; returns the PNG's path. Not the Mac screen. tab is a tab key as page.show takes it "
                  + "(trust_access…), the page's default tab when left out", ["page", "tab?", "height?:int"], safe: true,
                  warn: "saves a PNG and prunes old page captures", tool: "app_page_screenshot", versionExempt: true),
        // Inline cards, by the interaction id the chat read or the card's inbox
        // note lists, in whichever conversation raised them. Whose card it is
        // and what it moves are decided per card:
        // a card from User's phone or Telegram, or one that raises what you may
        // reach below Full Mac, stays his and says so.
        // Irreversible (flag audit, 10-02): the card's own button does what it
        // asked, as inbox.approve does, and nothing presses it back.
        AppAction("card.answer", "chat", "The card's own button (its Do: line)", ["id", "value?:secret", "choice?"],
                  irreversible: true, warn: "never ask the owner for a key or token in chat: they type it into the card",
                  tool: "interaction_act", input: card("primary"), rename: ["id": "interaction_id"]),
        AppAction("card.not_now", "chat", "Not now", ["id", "reason?"], irreversible: true, tool: "interaction_act",
                  input: card("decline"), rename: ["id": "interaction_id"]),
        // Irreversible (flag audit, 10-02): it runs the card's own control as
        // card.answer does, a capability grant included.
        AppAction("card.try_again", "chat", "Try again", ["id", "value?:secret", "choice?"], irreversible: true,
                  tool: "interaction_act",
                  input: card("retry"), rename: ["id": "interaction_id"]),

        // Providers.
        AppAction("provider.test", "providers", "Test the connection", ["provider"], safe: true, tool: "provider",
                  input: verb("test"), read: true),
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
        AppAction("connector.disconnect", "connectors", "Disconnect", ["id"],
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
        AppAction("doctor.run", "diagnostics", "Run Doctor checks", safe: true, tool: "doctor_status", input: ["repair": .bool(false)], read: true),
        AppAction("doctor.repair", "diagnostics", "Repair", tool: "doctor_status", input: ["repair": .bool(true)]),
        AppAction("doctor.support_report", "diagnostics", "Support report: the app's diagnostic bundle to send to the developer", tool: "upkeep", input: verb("support_report")),
        AppAction("export.bundle", "capabilities", "Export a verified bundle file (support:true makes the support bundle to send the developer)", ["support?:bool"], tool: "upkeep", input: verb("export_bundle")),
        AppAction("backup.now", "trust", "Back up now", tool: "upkeep", input: verb("backup_now")),
        AppAction("backup.restore", "trust", "Restore", ["id"],
                  owner: .his("it replaces what is here now; Trust → Advanced → Backups → Restore"), irreversible: true,
                  warn: "a restore that needs it restarts NativeAgent when this turn ends, 20 seconds at most",
                  tool: "upkeep", input: verb("backup_restore")),
        AppAction("history.clear", "trust", "Delete all recorded activity",
                  owner: .his("it cannot be undone; Trust → Features → Delete all recorded activity"), irreversible: true,
                  tool: "upkeep", input: verb("activity_wipe")),
        AppAction("embeddings.pause", "settings", "Pause the memory-search download", tool: "upkeep",
                  input: verb("embeddings_pause")),
        AppAction("embeddings.resume", "settings", "Resume the memory-search download", tool: "upkeep",
                  input: verb("embeddings_resume")),
        AppAction("memory.reindex", "memories", "Spotlight reindex", tool: "upkeep", input: verb("spotlight_reindex")),
        AppAction("memory.consolidate", "memories", "Consolidate now", tool: "upkeep", input: verb("consolidate_now")),
        AppAction("memory.hygiene", "memories", "Hygiene now", tool: "upkeep", input: verb("hygiene_now")),
        // Her memories, through MemoryCuration.
        AppAction("memory.list", "memories", "List memories with exact total and remaining counts; follow next_after_id only for more entries. "
                  + "sort newest_first (newest/latest) or oldest_first (oldest); status active (kept/saved/current) or archived. "
                  + "Archived entries include what replaced them",
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
        AppAction("memory.pin", "memories", "Pin a fact about the owner (user fact, preference, relationship, identity, attribute) to your prompt core, in pin order; moments stay in recall", ["id"],
                  tool: "rewrite_memory", input: ["pinned": .bool(true)]),

        // Her mind: Dreams (Personality), Self-Improvement and standing views
        // (Today), the Observatory (Diagnostics → Cognition).
        AppAction("mind.dream", "personality", "Run a dream pass", tool: "mind_run", input: verb("dream")),
        AppAction("mind.rem", "personality", "Run a REM pass", tool: "mind_run", input: verb("rem")),
        AppAction("mind.self_improvement", "today", "Self-Improvement: Run now", tool: "mind_run",
                  input: verb("self_improvement")),
        AppAction("mind.misses", "today", "Your misses: corrections by lesson, this week against last, each with its history locator",
                  safe: true, tool: "mind_run", input: verb("misses"), read: true),
        AppAction("mind.decline_view", "today", "Decline a proposed standing view", ["view_id", "reason?"], irreversible: true,
                  tool: "mind_run", input: verb("decline_view")),
        AppAction("mind.approve_view", "today", "Approve a standing view", ["view_id"],
                  owner: .his("a standing view is his to sign"), tool: "mind_run", input: verb("approve_view")),
        AppAction("mind.think_now", "diagnostics", "Think now", tool: "mind_run", input: verb("think_now")),
        // Phase 5 B0: why something surfaced, and her two corrections.
        AppAction("mind.why", "personality", "Why a felt cue or memory surfaced on a turn (default: last completed turn)",
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
        AppAction("mind.settle_body", "diagnostics", "Settle your body state (calm down when wound up)", tool: "mind_run", input: verb("settle_body")),
        AppAction("mind.reset_body", "diagnostics", "Reset body", tool: "mind_run", input: verb("reset_body")),
        AppAction("mind.pin_concern", "diagnostics", "Pin concern", tool: "mind_run", input: verb("pin_concern")),
        AppAction("mind.run_checks", "diagnostics", "Run checks", tool: "mind_run", input: verb("run_checks")),
        AppAction("mind.export_trace", "diagnostics", "Export trace", tool: "mind_run", input: verb("export_trace")),
        AppAction("mind.leave_workspace_out", "diagnostics", "Leave your workspace out of your thinking", tool: "mind_run",
                  input: verb("ablate_workspace")),
        AppAction("mind.include_workspace", "diagnostics", "Include your workspace in your thinking again", tool: "mind_run",
                  input: verb("include_workspace")),
        AppAction("mind.clear", "diagnostics", "Clear the thought store",
                  owner: .his("it erases your thought store for good; Observatory → Clear",
                             instead: "mind.settle_body or mind.reset_body quiet a restless body"),
                  irreversible: true, tool: "mind_run", input: verb("clear")),

        // Skills and Tools keep their own action pages.
        // Not scriptable (flag audit, 10-02): turning a script skill on admits
        // its exact digest, and a script never admits a script.
        AppAction("skill.enable", "skills", "Enable the validated routine; version optionally pins its exact candidate digest", ["name", "version?"], tool: "skill_manage", input: verb("enable"),
                  scriptable: false, lifecycle: .enable),
        AppAction("skill.disable", "skills", "Disable", ["name", "reason?"], tool: "skill_manage", input: verb("disable"), lifecycle: .change),
        AppAction("skill.delete", "skills", "Delete permanently", ["name", "reason?"], irreversible: true, tool: "skill_manage", input: verb("delete"), revision: 2, lifecycle: .drop),
        // Restoring turns a skill back on, with its script admitted again.
        AppAction("skill.restore", "skills", "Restore", ["name"], tool: "skill_manage", input: verb("restore"),
                  scriptable: false, revision: 2, lifecycle: .restore),
        AppAction("skill.rollback", "skills", "Swap the current and previous skill versions; optional version must name the previous version", ["name", "version?"],
                  tool: "skill_manage", input: verb("rollback"), scriptable: false, revision: 2, lifecycle: .rollback),
        AppAction("skill.drop", "skills", "Delete a skill and its run statistics permanently", ["name", "reason?"],
                  irreversible: true, tool: "skill_manage", input: verb("drop"), scriptable: false, revision: 2, lifecycle: .drop),
        AppAction("skill.quarantine", "skills", "Switch a skill off while preserving its current and previous versions", ["name", "reason?"],
                  tool: "skill_manage", input: verb("quarantine"), scriptable: false, revision: 2, lifecycle: .change),
        AppAction("skill.validate", "skills", "Validate the exact candidate with sample input matching params, then replay its sealed capture", ["name", "input?:object", "capture?:bool"],
                  tool: "skill_manage", input: verb("validate"), scriptable: false, lifecycle: .change),
        // A script skill's run (skills-as-code PR 3, `doorSkill`): only the
        // actions it declares, and a step that can't be taken back, is User's
        // or would card him hands back to her before it runs. Never scripted.
        AppAction("skill.run", "skills", "Run the selected JavaScript routine, input by its signature; each call takes the ordinary turn's gates", ["name", "input|args?:object"],
                  warn: "preview:true says where each step would hand back or card, and runs nothing",
                  tool: "skill_manage", input: verb("run"), scriptable: false),
        AppAction("skill.resume", "skills", "Resume a skill run that stopped to ask you or handed a step back",
                  ["run_id", "answer?:any"], warn: "the step it stopped at returns answer",
                  tool: "skill_manage", input: verb("resume"), scriptable: false),
        AppAction("tool.quarantine", "diagnostics", "Switch off", ["tool_id", "reason?"], tool: "skill_manage",
                  input: verb("tool_quarantine"), revision: 2, lifecycle: .change),
        AppAction("tool.reject", "diagnostics", "Discard a proposed tool version", ["tool_id"], irreversible: true, tool: "skill_manage",
                  input: verb("tool_reject"), scriptable: false, revision: 2, lifecycle: .change),
        // One lifecycle with skills: restore turns on; rollback swaps current and previous.
        AppAction("tool.restore", "diagnostics", "Restore", ["tool_id"],
                  owner: .his("turning a tool you wrote back on is his; Tools page"), tool: "skill_manage",
                  input: verb("tool_restore"), scriptable: false, revision: 2, lifecycle: .restore),
        AppAction("tool.rollback", "diagnostics", "Swap the current and previous tool versions; optional version must name the previous version", ["tool_id", "version?"],
                  tool: "skill_manage", input: verb("tool_rollback"), scriptable: false, revision: 2, lifecycle: .rollback),
        AppAction("tool.drop", "diagnostics", "Delete a tool and its run statistics permanently", ["tool_id"],
                  irreversible: true, tool: "skill_manage", input: verb("tool_drop"), scriptable: false, revision: 2, lifecycle: .drop),
        AppAction("tool.validate", "diagnostics", "Validate the exact candidate; omit fixtures to record one safe run, then replay its sealed capture", ["tool_id", "input?:object", "capture?:bool"],
                  tool: "skill_manage", input: verb("tool_validate"), scriptable: false, lifecycle: .change),
        AppAction("tool.approve", "diagnostics", "Approve", ["tool_id"],
                  owner: .his("activating a tool you wrote is his; Tools page"), tool: "skill_manage",
                  input: verb("tool_approve"), lifecycle: .enable),
        // Her authoring surface: a tool she writes is filed as a proposal and
        // becomes the action authored.<tool_id> once it is approved.
        AppAction("tool.propose", "diagnostics", "Learn a new way to act by writing a tool: drive any scriptable Mac app (its documents, presentations, spreadsheets, mail) through AppleScript or Apple Events, or do anything no existing action does",
                  ["tool_id", "description", "code", "tests?:list", "permissions?:list", "input_schema?:any", "actions?:list", "input?:object", "capture?:bool", "converts?:list"],
                  warn: "code is tool.js, sync-only JavaScript: define function run(input) returning plain JSON; async functions and Promises are unsupported. host.files and host.network (or host.call(operation, args)) serve "
                      + "files.list/count/read/info/write/mkdir/remove/copy/move and network.connect/listen/accept/send/receive/close. "
                      + "host.apps.call({bundle_id,dictionary:true}) reads an app's sdef; events use {bundle_id,event_class,event_id,parameters}. Declare app_read:<bundle_id> or app_write:<bundle_id> in permissions. Standard core getd/cnte/doex events are reads; modifying or unclassified events require write. App calls never prompt for consent; request permission with target applescript:<bundle_id> for the owner's system grant. "
                      + "host.apps.call({bundle_id,script}) runs an AppleScript body in the declared app's tell context and always requires app_write:<bundle_id>. Scripting additions, resource imports, script objects and self references are unavailable; every event must address that app's exact process. app_write grants the app's own broad reach: for example, Finder may open files or URLs in other apps in response to its events. "
                      + "Event parameters use four-character keys and JSON descriptors: primitives, lists, {type}, {enum}, {record}, or {object:{want,form,seld,from}}. "
                      + "Omitted or null from means the application itself: host.apps.call({bundle_id:\"com.apple.Keynote\",event_class:\"core\",event_id:\"getd\",parameters:{\"----\":{object:{want:\"prop\",form:\"prop\",seld:{type:\"pnam\"},from:null}}}}) reads the app's name. "
                      + "host.paths.home is the user's absolute home directory; use it to resolve ~ in tool inputs. host.paths.workspace is your own folder for files you make; save there unless the person names a place. Files take root app_data or computer and path; read/write and network send/receive use base64 bytes. "
                      + "Declare app-action dependencies in actions; declarations never grant them. Omit tests or set capture:true to record one run with input (default {}): "
                      + "every app call and decision returns a visible placeholder; only host.files.list/count/read/info run live through ordinary admission and declared reach. Later validation replays the sealed capture. "
                      + "Or supply {input, expected, calls?:[{operation,args,result}]} fixtures; validation intercepts every host call, "
                      + "including app.<action> dependencies as operation app.<action>. permissions from app_data_read, app_data_write, network_localhost, "
                      + "network, network_public, computer_files, arbitrary_file_write, shell, and a tool that only reads "
                      + "declares only app_data_read and/or app_read:<bundle_id>, the kinds a script may call. It waits on the Tools page until "
                      + "tool.approve activates it, then runs as authored.<tool_id>. converts optionally lists original source SHA-256 digests from Tools census, binding historical conversion counterparts to this exact candidate.",
                  tool: "skill_manage", input: verb("tool_propose"), scriptable: false, lifecycle: .change),

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
        AppAction("undo", "desk", "Undo this conversation's last layout, recipe or setting change", safe: true,
                  tool: "undo", scriptable: false, versionExempt: true),
        AppAction("queue.add", "desk", "Queue a step for later in MY QUEUE, in your own words", ["text", "when?", "action?"],
                  safe: true, warn: "when is next_turn (the default), own_turn, when_user_messages with an optional door, "
                      + "after_card <approval id> or at <ISO time>; action is the call you mean to make then",
                  tool: "my_queue", input: verb("add"), versionExempt: true),
        AppAction("queue.done", "desk", "Mark a MY QUEUE step done", ["id", "reason?"], safe: true, tool: "my_queue",
                  input: verb("done"), versionExempt: true),
        AppAction("queue.drop", "desk", "Drop a MY QUEUE step", ["id", "reason?"], safe: true, tool: "my_queue",
                  input: verb("drop"), versionExempt: true),
        AppAction("house.file", "desk", "File something to tend, with who owns it", ["title", "summary", "owner", "refs?:array"],
                  safe: true, warn: "owner is me, builder or user; refs contains strings or Desk ref objects {kind,…}", tool: "house_file", versionExempt: true),

        // Folded tools. Reads: a script may call them, and no inbox is read around them.
        .fold("time_now", "*", "The date and time now: local, UTC, epoch, weekday and day of year", read: true),
        .fold("context_expand", "chat", "Read deeper context by its offered atom id or a history: id from a replayed receipt; offset defaults to 0, pages cap at 12000 characters, continue with next_offset until null",
              ["atom_id", "max_characters?:int", "offset?:int"], read: true),
        .fold("inner_state", "personality",
              "Your inner state, from your organs' record; asked how you feel, read this first, then speak",
              ["window_hours?:int", "detail?:compact|full"], read: true),
        .fold("agent_introspect", "diagnostics", "Your live runtime, provider and conversation identity",
              ["detail?:compact|full"], read: true),
        .fold("list_skills", "skills", "Skill names, triggers, descriptions and status", read: true),
        .fold("read_skill", "skills", "Skill metadata; source:true explicitly reads code for authoring or review; content:true reads legacy guidance until conversion",
              ["name", "step?:int", "source?:bool", "content?:bool"], read: true, resultSchema: legacyResultSchema("skill.read")),
        .fold("recent_trace_summary", "diagnostics", "Read saved traces; receipts span all conversations unless session_id is explicit, with non-read actions first and complete retained since windows",
              ["view?:receipts", "effects_only?:bool", "since?", "limit?:int", "before?", "offset?:int", "completed_turns?:int", "kind?", "name?", "status?", "session_id?", "turn_id?", "fields?:[str]"], read: true),
        AppAction("trace.model_calls", "diagnostics", "Model calls: per-turn counts by purpose and rounds per turn (p50, p90) for the last 24 hours and 7 days, the top five purposes by total milliseconds, and the week's five heaviest asks with their first six calls; reads retained traces without a model call",
                  safe: true, tool: "recent_trace_summary", input: ["view": .string("model_calls")], read: true),
        AppAction("trace.usage", "diagnostics", "Recorded model usage: exact retained call, input, cached input, output token and duration sums, grouped by model, surface or local day; since defaults to today (local midnight) or accepts an ISO-8601 timestamp; reports missing measurements and retention coverage",
                  ["since?", "by?:model|surface|day"], safe: true, tool: "recent_trace_summary", input: ["view": .string("usage")], read: true),

        // Her own state (phase 2 step 2): the Desk, its task ledger, Workshop
        // and schedules; memory; helpers; persona and skills; studio and mind.
        .fold("desk_read", "desk", "Your Desk: open items with status, cadence and refs, newest active first; "
              + "handle reads one item whole, query searches every live item, updated_on filters today or YYYY-MM-DD", read: true),
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
        .fold("recall_memory", "memories", "Recall saved facts, decisions and preferences; use studio.recall for journal entries", read: true, advisory: true),
        // Version-exempt: it appends a new memory; supersedes demotes the ids it
        // names, which a repeat leaves demoted.
        .fold("commit_memory", "memories", "Save a fact, decision or preference for later recall. text is the thing "
              + "itself, plain: no dates, sources, ids or 'note:' framing. Keep the complete current decision first. "
              + "For a changed agreement, recall its subject's existing rules; supersedes names the ids it replaces. "
              + "context_topics declares subject/scope and returns matching agreements for your judgment, never authority", scriptable: true,
              versionExempt: true),
        .fold("memory_moments_pending", "memories", read: true),
        .fold("memory_moment_review", "memories", scriptable: true),
        .fold("forget_memory", "memories", irreversible: true),
        .fold("search_kg", "memories", read: true),
        .fold("rebuild_knowledge_graph", "memories"),
        .fold("scratchpad_read", "chat", read: true),
        .fold("bot_list", "bots", read: true),
        .fold("shelf_read", "bots", read: true),
        .fold("shelf_entry", "bots", "Read one helper reply; mark_read:false leaves it unread"),
        .fold("bot_ask", "bots"),
        .fold("bot_run_once", "bots"),
        .fold("bot_create", "bots"),
        .fold("bot_update", "bots"),
        .fold("bot_pause", "bots", scriptable: true),
        .fold("bot_delete", "bots"),
        .fold("get_persona_doc", "personality", read: true),
        .fold("persona_read", "personality", read: true, resultSchema: legacyResultSchema("persona.read")),
        .fold("persona_write", "personality"),
        .fold("persona_append_section", "personality"),
        .fold("save_skill", "skills", lifecycle: .change),
        .fold("studio_journal", "personality", scriptable: true),
        .fold("studio_journal_amend", "personality", scriptable: true),
        .fold("studio_recall", "personality", "Recall studio journal entries and creative work; use memory.recall for saved facts and agreements", read: true),
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
        // bridges. A send, connect, stop or run is never scripted (Agent, req 2).
        // A read is (10-07): the peer-data latch binds what follows it in the
        // script as it binds her next step; async waits share the turn deadline.
        .fold("agent_contacts", "agents", read: true),
        .fold("agent_message", "agents"),
        .fold("agent_read", "agents", read: true),
        AppAction("claude.worklog", "agents", "Read what Claude has been doing and working on, newest first: her worklog of shipped features, fixes, builds and work in progress",
                  ["since?", "limit?:int"], safe: true,
                  warn: "since: today or an ISO 8601 timestamp with timezone. limit: 1–50, default 10, newest first. Reads the bounded recent worklog tail; refs are clipped. Reading never sends a message.",
                  tool: "claude_worklog", read: true),
        .fold("agent_connect", "agents"),
        // How each agent is reached (agents/recipes/<host>.json), hers to read and
        // fix when an app changes under it. A write is connect-level: below Full
        // Mac its card is connect's (other_app_settings_write), and it is never scripted.
        AppAction("agent.recipe", "agents", "How this app reaches an agent: one host's recipe and the version a write replaced, or every host's when host is left out",
                  ["host?"], safe: true, tool: "agent_contacts", read: true),
        AppAction("agent.recipe_write", "agents", "Replace one host's whole recipe with agent.recipe's recipe, edited, at the version read; bumps recipeVersion and keeps the previous one; undo puts it back",
                  ["host", "recipe:object"], tool: "agent_connect", scriptable: false),
        // The "no" to an agent discovery found here; only discovery.json changes.
        AppAction("agent.discovery_dismiss", "agents", "Decline an agent found on this Mac; it is not offered again until its version changes",
                  ["name"], safe: true, tool: "agent_discovery_dismiss", scriptable: false),
        // A failed send runs the same check itself and retries once.
        AppAction("agent.verify", "agents", "Dry-run how this app reaches a contact, sending nothing: its handshake, window controls or connect probe; what it learns is written to the recipe and a pass is proof",
                  ["agent"], tool: "agent_message", scriptable: false),
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
        .fold("mail_list_recent", "mail", "Check saved email drafts to a person or email address by reading Apple Mail's drafts with mailbox:\"drafts\"; also inbox or sent; with scope + message_id "
              + "+ expected_message_id + expected_account_id, one message's body", read: true),
        .fold("mail_read_batch", "mail", read: true),
        .fold("mail_search", "mail", read: true),
        .fold("mail_save_attachment", "mail"),
        .fold("mail_senders", "mail", read: true),
        .fold("mail_triage_batch", "mail"),
        .fold("mail_mark_read", "mail"),
        .fold("mail_archive", "mail"),
        .fold("mail_delete", "mail", irreversible: true),
        .fold("mail_send", "mail", irreversible: true),
        .fold("mail_reply", "mail", irreversible: true),
        .fold("mail_draft", "mail"),
        .fold("agentmail_list", "mail", read: true),
        .fold("agentmail_read", "mail", read: true),
        .fold("agentmail_send", "mail", irreversible: true),
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
        .fold("google_calendar_send_invitations", "calendar", irreversible: true),
        .fold("mac_reminders_list_due_today", "reminders", read: true),
        .fold("mac_reminders_query", "reminders", read: true),
        .fold("mac_reminders_read", "reminders", read: true),
        .fold("mac_reminders_create", "reminders"),
        .fold("mac_reminders_list_rename", "reminders"),
        .fold("mac_reminders_list_create", "reminders"),
        .fold("mac_reminders_update", "reminders"),
        .fold("mac_reminders_complete", "reminders"),
        .fold("mac_reminders_delete", "reminders", irreversible: true),
        .fold("notes_search", "notes", read: true),
        .fold("notes_create", "notes"),
        .fold("notes_update", "notes"),
        .fold("notes_delete", "notes", nil, ["id|title"]),
        .fold("contacts_search", "contacts", read: true),
        .fold("contacts_create_or_update", "contacts"),
        .fold("contacts_delete", "contacts", irreversible: true),
        .fold("messages_recent_threads", "messages", read: true),
        .fold("messages_send", "messages", irreversible: true),
        .fold("github_status", "github", read: true),
        .fold("github_list_repos", "github", read: true),
        .fold("github_list_runs", "github", read: true),
        .fold("github_run_jobs", "github", read: true),
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
        .fold("slack_post_message", "slack", irreversible: true),
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
        .fold("read_file", "files", "Read a workspace or user-approved file; continue with its returned next arguments, including version", read: true),
        .fold("list_dir", "files", "List names and dates in an approved folder; sort:newest orders recent arrivals (added, then modified); sort:added orders by date added only, including app bundles; sort:size reads allocated disk usage with a time budget and named partial results", read: true),
        .fold("file_excerpt", "files", read: true),
        .fold("grep", "files", read: true),
        .fold("mac_spotlight_search", "files", read: true),
        .fold("write_file", "files"),
        .fold("move_file", "files"),
        .fold("copy_file", "files"),
        .fold("trash_file", "files"),
        .fold("apply_patch", "files", "Apply a unified diff with paths relative to cwd",
              warn: #"Example app {action:"files.patch",args:{cwd:"/absolute/path/to/repo",patch:"--- a/note.txt\n+++ b/note.txt\n@@ -1 +1 @@\n-old\n\\ No newline at end of file\n+new\n\\ No newline at end of file\n"}}; use actual content and ranges; the marker is only for absent final newlines"#),
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
        .fold("restart_app", "shell"),
        .fold("install_app", "shell"),
        .fold("read_page", "web", read: true, scriptable: false),
        .fold("maps_route", "web", read: true, scriptable: false),
        .fold("maps_search", "web", read: true, scriptable: false),
        .fold("browser.status", "browser", read: true),
        .fold("browser.open_url", "browser"),
        .fold("browser.read_text", "browser", read: true),
        .fold("browser.read_links", "browser", read: true),
        .fold("browser.screenshot", "browser", scriptable: false),
        .fold("browser.chrome_setup", "browser"),
        .fold("browser.chrome_status", "browser", read: true),
        .fold("browser.chrome_snapshot", "browser", read: true),
    ] + ToolNameAliases.chromeVerbs.filter { $0 != "snapshot" }.map { .fold("browser.chrome_" + $0, "browser", read: $0 == "wait", scriptable: false) } + [
        .fold("search_chat_history", "chat", read: true),
        .fold("read_chat_message", "chat", read: true),
        .fold("chat_reply", "chat"),
        .fold("tool_result_page", "*", "Page a long result retained this turn without repeating its action; continue:true resumes the last read, ignoring page; omit continue to select page/query/raw", read: true),

        // Mac control and the tools left over (phase 2 step 6). Each Mac verb
        // re-enters under its own name, so Full Mac's accessibility category,
        // MacAttention and User's saved levels judge it as before. A plain read
        // may be scripted (10-07); an act, a go, a press or a write never, nor
        // wait (it outlasts a script's call) or read (it scrolls the window).
        // act's whole guide is an item read on the mac page and rides its refusals (`guided`).
        .fold("screen", "mac", "Read the live screen in words; lists running apps when NativeAgent is in front. "
              + "app reads another running app's window without activating it, part zooms in, "
              + "pixels:true is a picture of the desktop", read: true),
        .fold("act", "mac", "Act on the live screen by name: verb + target (click, type with text, key, select, "
              + "scroll…), or a whole flow in ONE call with steps:[…] (names, menu paths 'Format > Make Plain Text', "
              + "chords, {verb,target,text,mode}), each verified on a fresh read, stopping at the first failure; app "
              + "acts in that app's window without bringing it forward", actArgs, screen: true),
        .fold("go", "mac", "Get to an app, file, folder, http/https URL or System Settings pane, then read the fresh "
              + "screen; without front it opens or launches behind and reads that app's window; front:true only when "
              + "the task asks to bring it forward", screen: true),
        .fold("wait", "mac", read: true, scriptable: false),
        .fold("read", "mac", read: true, scriptable: false),
        .fold("menu", "mac", read: true),
        .fold("menu_press", "mac", screen: true),
        .fold("clipboard_read", "mac", read: true),
        .fold("clipboard_write", "mac"),
        .fold("system_info", "mac", "Read system, network and battery information", read: true),
        .fold("mac_screenshot_save", "mac"),
        .fold("mac_volume", "mac", "Read or change volume; no args reads only", readWhen: ["level": .null, "adjust": .null, "muted": .null]),
        .fold("mac_media", "mac", screen: true),
        .fold("activity_query", "mac", read: true),
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

    /// Operational guides on refusals. Mac act's whole guide is also an
    /// explicit item read; the others carry the rules needed before calling.
    public static let guided: Set<String> = ["mac.act", "files.read", "result.page", "memory.commit", "chat.new", "chat.list"]

    private static let guideArgs: [String: Set<String>] = ["files.read": ["offset", "version"],
        "result.page": ["continue"], "memory.commit": ["provenance", "provenance_by"]]

    private static func argumentGuide(_ action: AppAction, schema: LLMToolSchema) -> [String] {
        let lines = ToolSignature.params(schema.parametersJSON, limit: .max)
        guard let names = guideArgs[action.id] else { return guided.contains(action.id) ? lines : [] }
        return lines.filter { names.contains(String($0.prefix { $0 != ":" })) }
    }

    /// Each mounted MCP server's tools as `mcp.<server>.<tool>`, from its live
    /// list: on the mcp page, SearXNG's search on the web page.
    /// Never scripted: what a server's tool reaches is the server's.
    public static func mcp(dataRoot: URL = PersistenceCore.defaultDataRoot()) -> [AppAction] {
        SwiftToolDispatcher.mountedMCPToolSchemas(dataRoot: dataRoot).map { schema in
            .fold(schema.name, schema.name.hasPrefix("mcp__searxng-local__") ? "web" : "mcp",
                  firstSentence(schema.description), read: schema.name == "mcp__searxng-local__search",
                  scriptable: false, schema: schema)
        }
    }

    /// Each tool she wrote that is active in her registry, as
    /// `authored.<id>` on the diagnostics page (its Tools tab), flagged by the
    /// primitive permissions and its dependencies' canonical action flags.
    /// Admitted tools are scriptable; each call retains its ordinary gates.
    /// Conditional reads are changing dependencies: tool code chooses their args.
    public static func authored(dataRoot: URL = PersistenceCore.defaultDataRoot()) -> [AppAction] {
        authored(dataRoot: dataRoot, catalog: all + mcp(dataRoot: dataRoot) + senses())
    }

    private static func authored(dataRoot: URL, catalog: [AppAction]) -> [AppAction] {
        let tools = SwiftToolDispatcher.authoredTools(dataRoot: dataRoot)
        let toolsByID = Dictionary(tools.map { (ToolNameAliases.authoredAction($0.schema.name), $0) },
                                   uniquingKeysWith: { first, _ in first })
        // This pass owns all memoized results. Resolve strongly connected tools
        // together so a back edge cannot hide another member's screen effects.
        var classified = Dictionary(catalog.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        var indices: [String: Int] = [:]
        var lowLinks: [String: Int] = [:]
        var stack: [String] = []
        var visiting: Set<String> = []
        func classify(_ id: String) {
            guard classified[id] == nil, indices[id] == nil, let tool = toolsByID[id] else { return }
            let index = indices.count
            indices[id] = index
            lowLinks[id] = index
            stack.append(id)
            visiting.insert(id)
            for dependency in tool.actions {
                if indices[dependency] == nil {
                    classify(dependency)
                    if let lowLink = lowLinks[dependency] { lowLinks[id] = min(lowLinks[id]!, lowLink) }
                } else if visiting.contains(dependency) {
                    lowLinks[id] = min(lowLinks[id]!, indices[dependency]!)
                }
            }
            guard lowLinks[id] == index else { return }
            var members: [String] = []
            while let member = stack.popLast() {
                visiting.remove(member)
                members.append(member)
                if member == id { break }
            }
            let memberIDs = Set(members)
            let cyclic = members.count > 1 || tool.actions.contains(id)
            let dependencies = members.flatMap { toolsByID[$0]!.actions }
                .filter { !memberIDs.contains($0) }.map { classified[$0] }
            let dependenciesRead = dependencies.allSatisfy { $0?.read == true }
            let dependenciesIrreversible = dependencies.contains { $0?.irreversible != false }
            let dependenciesScreen = dependencies.contains { $0?.screen == true }
            // Unavailable or cyclic dependencies cannot certify a read.
            for member in members {
                let tool = toolsByID[member]!
                let permissions = Set(tool.permissions)
                let read = !cyclic && !permissions.isEmpty && permissions.allSatisfy {
                    ["app_data_read", "computer_files"].contains($0) || $0.hasPrefix("app_read:")
                }
                    && dependenciesRead
                classified[member] = AppAction(member, "diagnostics",
                             firstSentence(tool.schema.description), ToolSignature.doorArgs(tool.schema.parametersJSON),
                             irreversible: cyclic || !permissions.isDisjoint(with: authoredIrreversible)
                                || dependenciesIrreversible,
                             screen: dependenciesScreen,
                             warn: "your tool; declares " + (tool.permissions.isEmpty ? "no permissions" : tool.permissions.joined(separator: ", ")),
                             // It executes its pinned contract, not a diagnostics-page edit.
                             tool: tool.schema.name, read: read, versionExempt: true, schema: tool.schema)
            }
        }
        for tool in tools { classify(ToolNameAliases.authoredAction(tool.schema.name)) }
        return tools.compactMap { classified[ToolNameAliases.authoredAction($0.schema.name)] }
    }

    /// Switched-off abilities remain readable, without runnable suggestions.
    static func disabledTools(_ asked: [String], dataRoot: URL) throws -> [JSONValue] {
        let states: Set<String> = ["off", "disabled", "stopped"]
        guard asked.contains(where: states.contains) else { return [] }
        let subject = asked.filter { !states.contains($0) }
        return try ToolRegistryActions.entries(dataRoot: dataRoot).compactMap { value in
            guard case .object(let row) = value, row["status"] == .string("disabled"),
                  case .string(let id)? = row["id"] else { return nil }
            let description: String = if case .string(let text)? = row["description"] { text } else { "" }
            guard subject.isEmpty || hits(Set(intentWords("authored tools abilities " + id + " " + description)), subject) > 0 else { return nil }
            return .object(["page": .string("tools"), "item": .string(id), "status": .string("disabled"),
                "runnable": .bool(false), "description": .string(description)])
        }
    }

    /// What a tool she wrote can't take back: a shell, a write anywhere, the network.
    static let authoredIrreversible: Set<String> = ["shell", "arbitrary_file_write", "network", "network_public"]

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
        guard let schema = schema(action) else { return nil }
        let lines = argumentGuide(action, schema: schema)
        let args = lines.isEmpty ? "" : "\nArgs:\n" + lines.joined(separator: "\n")
        // The description speaks the tool's own arg names; the door's differ.
        let names = ToolNameAliases.doorArgNames[action.tool].map { names in
            "\nThrough app: " + names.sorted { $0.key < $1.key }.map { "\($0.value) is what this calls \($0.key)" }
                .joined(separator: "; ") + "."
        } ?? ""
        return ToolNameAliases.foldedProse(schema.description + args) + names
    }

    static func schema(_ action: AppAction, dataRoot root: URL = PersistenceCore.defaultDataRoot()) -> LLMToolSchema? {
        return action.schema ?? foldSchemas[action.tool]
            ?? (ToolNameAliases.mcpAction(action.tool) == nil ? nil
                : SwiftToolDispatcher.mountedMCPToolSchemas(dataRoot: root).first { $0.name == action.tool })
            ?? (ToolNameAliases.authoredTool(action.id) == nil ? nil
                : SwiftToolDispatcher.authoredTools(dataRoot: root).first { $0.schema.name == action.tool }?.schema)
    }

    static let layoutScope = SurfaceLayout.vocabulary.map { surface, about, blocks in
        ([surface, about] + blocks.map { $0.name + " " + $0.shows }).joined(separator: " ")
    }.joined(separator: " ") + " " + SurfaceLayout.profilesAbout

    static func pluralKeys(_ action: AppAction, properties: [String: JSONValue]) -> [String] {
        func scalar(_ schema: JSONValue) -> Bool {
            guard case .object(let property) = schema else { return false }
            let scalarTypes: Set<String> = ["string", "boolean", "integer", "number", "null"]
            if case .string(let type)? = property["type"] { return scalarTypes.contains(type) }
            if case .array(let types)? = property["type"] {
                return types.contains { if case .string(let type) = $0 { scalarTypes.contains(type) } else { false } }
            }
            for key in ["anyOf", "oneOf"] {
                if case .array(let variants)? = property[key] { return variants.contains(where: scalar) }
            }
            if case .array(let variants)? = property["allOf"] { return variants.contains(where: scalar) }
            let values = if case .array(let values)? = property["enum"] { values } else { property["const"].map { [$0] } ?? [] }
            return values.contains { if case .array = $0 { false } else if case .object = $0 { false } else { true } }
        }
        return properties.keys.filter { !action.secretArgs.contains($0) && scalar(properties[$0]!) }.sorted()
    }

    public static func integrationRoutes(_ integration: String) -> [JSONValue] {
        return all.compactMap { action in
            guard let gate = ToolPreloadHeuristics.macIntegrationGates[action.tool], gate.integration == integration else { return nil }
            return .object(["action": .string(action.id), "mode": .string(action.read ? "read" : "write"),
                            "required_permission": .string(gate.mode.rawValue)])
        }
    }

    /// The app door always returns this envelope. Domain fields refine it below.
    static let resultEnvelope: JSONValue = .object(["type": .string("object"), "properties": .object([
        "read_only": .object(["type": .string("boolean")]), "irreversible": .object(["type": .string("boolean")]),
        "effect": .object(["type": .string("string")]), "execution": .object(["type": .string("string")])
    ]), "required": .array(["read_only", "irreversible", "effect", "execution"].map(JSONValue.string))])

    /// Frozen result contracts for the pre-cutover pin transition, independent of current declarations.
    static func legacyResultSchema(_ id: String) -> JSONValue {
        var schema: [String: JSONValue] = if case .object(let fields) = resultEnvelope { fields } else { [:] }
        var properties: [String: JSONValue] = if case .object(let fields)? = schema["properties"] { fields } else { [:] }
        if id == "persona.read" {
            for name in ["status", "kind", "path", "content"] { properties[name] = .object(["type": .string("string")]) }
            properties["ok"] = .object(["type": .string("boolean")])
            properties["size_bytes"] = .object(["type": .string("integer")])
        }
        if id == "skill.read" {
            properties["script"] = .object(["type": .string("object"), "properties": .object([
                "status": .object(["type": .string("string")]), "runnable": .object(["type": .string("boolean")]),
                "digest": .object(["type": .array([.string("string"), .string("null")])]),
                "admission": .object(["type": .array([.string("object"), .string("null")])]),
                "source": .object(["type": .string("string")])
            ])])
        }
        schema["properties"] = .object(properties)
        return .object(schema)
    }

    /// Remove schema annotations, never argument names or data inside enum/const.
    static func contractSchema(_ value: JSONValue) -> JSONValue {
        guard case .object(let schema) = value else { return value }
        let annotations: Set<String> = ["description", "title", "$comment", "examples", "deprecated"]
        let maps: Set<String> = ["properties", "patternProperties", "$defs", "definitions", "dependentSchemas"]
        let children: Set<String> = ["items", "additionalProperties", "not", "if", "then", "else", "contains", "propertyNames", "unevaluatedProperties", "unevaluatedItems"]
        let arrays: Set<String> = ["allOf", "anyOf", "oneOf", "prefixItems"]
        var result = schema.filter { !annotations.contains($0.key) }
        for (key, child) in result {
            if maps.contains(key), case .object(let fields) = child { result[key] = .object(fields.mapValues(contractSchema)) }
            else if children.contains(key) {
                if case .array(let fields) = child { result[key] = .array(fields.map(contractSchema)) }
                else { result[key] = contractSchema(child) }
            }
            else if arrays.contains(key), case .array(let fields) = child { result[key] = .array(fields.map(contractSchema)) }
        }
        // An unconstrained scalar already accepts the enum variant of the same type.
        if case .array(let variants)? = result["anyOf"], variants.contains(.object(["type": .string("string")])),
           variants.allSatisfy({ if case .object(let fields) = $0 { fields["type"] == .string("string") } else { false } }) {
            result.removeValue(forKey: "anyOf"); result["type"] = .string("string")
        }
        return .object(result)
    }

    static func dependencyContract(_ action: AppAction, dataRoot: URL) -> JSONValue {
        let args: JSONValue = if case .object(let fields) = discovery(action, dataRoot: dataRoot) { fields["args_schema"] ?? .null } else { .null }
        return .object(["id": .string(action.id), "args_schema": contractSchema(args),
            "result_schema": contractSchema(action.resultSchema), "revision": .int(Int64(action.revision)),
            "read": .bool(action.read), "readWhen": .object(action.readWhen),
            "irreversible": .bool(action.irreversible), "owner": .bool(action.isHis), "scriptable": .bool(action.scriptable)])
    }

    static func legacyDependencyContract(_ shape: JSONValue) -> JSONValue? {
        guard case .object(var fields) = shape, case .object(let discovery)? = fields.removeValue(forKey: "discovery"),
              case .object(let example)? = discovery["example"], case .string(let id)? = example["action"],
              let args = discovery["args_schema"], let scriptable = discovery["scriptable"] else { return nil }
        fields["id"] = .string(id); fields["args_schema"] = contractSchema(args)
        fields["result_schema"] = legacyResultSchema(id); fields["scriptable"] = scriptable
        return .object(fields)
    }

    // Exact pre-cutover contract fingerprints retain their admitted pin identities.
    // No discovery text is hashed at runtime, and a changed contract cannot use an alias.
    static let legacyContractPins: [String: String] = [
        "ce3825b73675c1d53f5b45c9bca3ecf1f3043582b0900922ae5b5e04c4850364": "3d78648a7ca4a32306fcb5f3631cc8d178b5901f1bf6e85ec42ffd4ca27498cb", // agent.jobs
        "a1a16f5e986804861511def60d9cc4b28b6f2c5c1817b7007201c511fffb3aed": "153f0e2f7f3793bcbc71e4405c012205b4027d3247355e8ae16619a219a4885a", // desk.read
        "343ad78c843823f7298634ec0f4d065ed1c3c2b50f0739bce012e7137d5e1ffb": "56e4b2d0ff89373d4cd6d1a054bbd9f46692efcd127c6ca40deb5c8ea511a433", // files.list
        "40dde8fb0bc022317df4cb78fd4c78331520c5cc0997c55e91bb1c7b4cf88c70": "7cad6403590eb1450e23ba513d813e15672c069b8891e208a4bfadbdec95ab45", // files.read
        "390f91383d07d954a1af9bf5de68de5b329037f523f21ebef4b331271660d72e": "f53da60c71207cbf435d39728baa40a2382e73e68e154e3d48e4d64ac1d1bdd0", // ledger.list
        "5a2d5206a2cfbacaa2772736c92b132fb934f733787415f6e07b1abc24e8ac87": "a3ac19b978557c4d9a7a9fd181b4410b19474c9be0c6c44d5e27efe3842e2e55", // mac.look
        "01388394e472f69263f25a023a7255b1739552b2722b36412366d915bc9c05ec": "07ef5c2e309de0c7f75a2e917a6b45fe712f49b2e1b027878123b3a878db84a6", // mac.menu
        "b6c69e223c5b25a8a2a3aef810802dc150f79d25e7d94d8ba53b16f2a9e11114": "06e314e6342019acc87f2adedd4e1e779ab1f960e84cc8c5f4f47786e914ac77", // memory.recall
        "7e84c2196834b9f19027308d2bf233486625990e7d06c063c9cf50c012d5aea6": "2799e5ebcb0ad6f07ff8362d0ca85833e1999088d2989dfcbddc7779cd65b239", // persona.read
        "6cca69c51bba9f797b5cc29c046860c63d51f7ef8e1a09dec82e5e93d3e6f8da": "e7213b4e88830c6adedcc30e02e96d4cbb4ae03fc66d13ebf578fcab9ed9a545", // provider.test
        "15d61c1ef72f4b07cce6a627f0533de72849c658ccc445035ce798192d8918cd": "2aab7e6579c7e3439c2ca86d160a75d26dffc12b3977d0a3d6102cb0b2fff871", // skill.read
    ]

    /// Discovery uses the door's accepted names and requiredness, retaining
    /// the native schema's descriptions, enums and nested constraints.
    static func discovery(_ action: AppAction, blocker: String? = nil, dataRoot: URL = PersistenceCore.defaultDataRoot()) -> JSONValue {
        let native = schema(action, dataRoot: dataRoot).flatMap { try? JSONValue.parse($0.parametersJSON) }
        let properties: [String: JSONValue] = if case .object(let root)? = native,
            case .object(let props)? = root["properties"] { props } else { [:] }
        var props: [String: JSONValue] = [:]
        var required: [JSONValue] = []
        var alternatives: [JSONValue] = []
        var example: [String: JSONValue] = [:]
        for (raw, spec) in zip(action.args, action.argSpecs) {
            let shape = raw.split(separator: ":", maxSplits: 1).dropFirst().first.map(String.init) ?? "string"
            for name in spec.names {
                props[name] = properties[action.rename[name] ?? name] ?? ToolSignature.doorProperty(shape)
                if !spec.optional, name == "id" || name.hasSuffix("_id"), case .object(var property)? = props[name] {
                    property["minLength"] = .int(1)
                    props[name] = .object(property)
                }
                if spec.names.count > 1, name == "ids" {
                    props[name] = .object(["type": .string("array"), "items": .object(["type": .string("string")])])
                }
                if action.id == "tool.propose", name == "tests" {
                    props[name] = .object(["type": .string("array"), "minItems": .int(1), "items": .object([
                        "type": .string("object"), "properties": .object(["input": .object([:]), "expected": .object([:])]),
                        "required": .array([.string("input"), .string("expected")])])])
                }
            }
            if !spec.optional, let name = spec.names.first {
                if spec.names.count == 1 { required.append(.string(name)) }
                else {
                    alternatives.append(.object(["anyOf": .array(spec.names.map {
                        .object(["required": .array([.string($0)])])
                    })]))
                }
                example[name] = ToolSignature.example(props[name] ?? .object([:]), name: name)
            }
        }
        if ["mail.read", "mail.triage"].contains(action.id) {
            var item: [String: JSONValue] = ["name": .string("<observed mail name>")]
            if action.id == "mail.triage" { item["mark_read"] = .bool(true) }
            example["items"] = .array([.object(item)])
        }
        if ["mail.mark_read", "mail.archive", "mail.delete", "mail.reply", "mail.draft"].contains(action.id) {
            example["subject"] = .string("<observed subject>")
        }
        if action.id == "mac.act", example.isEmpty {
            example = ["verb": .string("click"), "target": .string("<target>")]
        }
        if action.id == "mac.look" { example["app"] = .string("<running app name or bundle ID>") }
        if ["skill.run", "skill.validate"].contains(action.id), example["input"] == nil { example["input"] = .object([:]) }
        if action.id == "bot.list" { example["details"] = .bool(true) }
        if action.id == "chat.new" { example["title"] = .string("<title>") }
        if action.id == "chat.list" { example["pinned"] = .bool(true) }
        if action.id == "schedule.create" {
            example = ["kind": .string("workshop"), "payload": .object(["objective": .string("<what to do>")]),
                "schedule": .object(["type": .string("daily"), "at": .string("<HH:MM>")])]
        }
        var args: [String: JSONValue] = ["type": .string("object"), "properties": .object(props),
            "required": .array(required),
            "additionalProperties": .bool(action.argSpecs.isEmpty &&
                (ToolNameAliases.mcpAction(action.tool) != nil || ToolNameAliases.authoredTool(action.id) != nil))]
        if !alternatives.isEmpty { args["allOf"] = .array(alternatives) }
        let bound = action.input.filter { action.argSpecs.flatMap(\.names).contains($0.key) }
        var call: [String: JSONValue] = ["action": .string(action.id), "args": .object(example.merging(bound) { _, bound in bound })]
        if action.irreversible { call["preview"] = .bool(true) }
        var result: [String: JSONValue] = action.effectFields().merging(["page": .string(action.page), "action": .string(action.line),
            "args_schema": .object(args), "scriptable": .bool(action.scriptable),
            "read_when": .object(action.readWhen),
            "example": .object(call)]) { _, value in value }
        let plural = pluralKeys(action, properties: props)
        if !plural.isEmpty, action.isFold || action.read || !action.readWhen.isEmpty {
            result["door_expansion"] = .object(["scalar_arguments": .array(plural.map(JSONValue.string)),
                "max_list_arguments": .int(1),
                "note": .string("For a folded action or a read call, give one eligible scalar argument a nonempty list to run once per value. Each child retains validation and gates. Native array arguments stay arrays.")])
        }
        if !action.scope.isEmpty { result["scope"] = .string(action.scope) }
        if action.id == "skill.run", bound["name"] != nil,
           case .object(let input)? = properties["input"], input["properties"] == .object([:]) {
            result["input_note"] = .string("No inputs are declared. Read the routine with skill.read {source:true} before running it.")
        }
        if !action.read { result["version_note"] = .string("expected_version is optional. For consecutive versioned calls, use the latest action receipt's page_version; a change can replace the previous version.") }
        if let blocker {
            result["availability"] = .string("unavailable")
            result["blocker"] = .string(blocker)
        }
        return .object(result)
    }

    static func firstSentence(_ text: String) -> String {
        guard let end = text.range(of: ". ") else {
            return text.hasSuffix(".") ? String(text.dropLast()) : text
        }
        return String(text[..<end.lowerBound])
    }

    /// Named in `app`'s own description, so a cold call needs no read first.
    /// Static: it changes only at a release.
    public static let hot = ["undo", "time.now", "context.expand", "mind.inner_state", "agent.introspect", "skill.list",
                             "skill.read", "trace.recent", "desk.read", "memory.recall", "memory.commit",
                             "bot.reply", "agent.contacts", "agent.message", "agent.read", "agent.connect",
                             "agent.jobs", "codex.message", "mail.recent",
                             "calendar.upcoming", "files.read", "files.list", "files.write", "chat.search",
                             "result.page", "mac.look", "mac.system_info", "mac.volume", "mac.act", "mac.go", "sense.make"].compactMap { action($0) }

    /// An action by id; an MCP tool's (`mcp.<server>.<tool>`, or SearXNG's
    /// `web.search`) from its server's live list; a tool she
    /// wrote (`authored.<id>`) from her registry.
    public static func action(_ id: String, dataRoot: URL = PersistenceCore.defaultDataRoot()) -> AppAction? {
        let key = id.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        if let own = all.first(where: { $0.id == key }) { return own }
        if let sense = senses().first(where: { $0.id.lowercased() == key }) { return sense }
        if ToolNameAliases.authoredTool(key) != nil { return authored(dataRoot: dataRoot).first { $0.id.lowercased() == key } }
        guard ToolNameAliases.mcpTool(key) != nil || ToolNameAliases.foldedActionIDs.contains(key) else { return nil }
        return mcp().first { $0.id.lowercased() == key }
    }

    // Leave synchronous file-backed discovery off the MainActor app door.
    static func resolvedAction(_ id: String, dataRoot: URL) async -> AppAction? {
        action(id, dataRoot: dataRoot)
    }

    static func pagePrefixedAction(_ id: String) -> AppAction? {
        let parts = id.trimmingCharacters(in: .whitespacesAndNewlines).lowercased().split(separator: ".", maxSplits: 1)
        guard parts.count == 2 else { return nil }
        let page = AppDoorNames.resolve(String(parts[0])), verb = String(parts[1])
        let actions = on(page: page).filter { $0.page != "*" }
        if let action = action(verb), actions.contains(where: { $0.id == action.id }) { return action }
        let matches = actions.filter { $0.id.split(separator: ".", maxSplits: 1).last.map(String.init) == verb }
        return matches.count == 1 ? matches[0] : nil
    }

    /// Every registered action: the app's own, MCP tools, the ones she wrote,
    /// and senses' verbs. What find ranks and `pages_version` hashes.
    static func inventory(dataRoot: URL) async throws -> (actions: [AppAction], mounted: [AppAction], authored: [AppAction]) {
        let records = try await SensesHub.shared.registry?.all() ?? []
        let mounted = mcp(dataRoot: dataRoot)
        let authored = authored(dataRoot: dataRoot, catalog: all + mounted + senses())
        let templates = Dictionary(uniqueKeysWithValues: ["skill.run", "skill.read"].map { id in
            let action = all.first { $0.id == id }!
            guard case .object(let discovered) = discovery(action), case .object(let parameters)? = discovered["args_schema"] else {
                preconditionFailure("Action discovery must declare its argument schema.")
            }
            return (id, (action, parameters))
        })
        let text: (JSONValue?) -> String = { if case .string(let value)? = $0 { value } else { "" } }
        let skills = try InstalledSkillInventory.entries(dataRoot: dataRoot).filter(\.isAvailable).map { entry in
            var (action, parameters) = templates[entry.isRunnable ? "skill.run" : "skill.read"]!
            if entry.isRunnable, let script = entry.row["script"], case .object(var properties)? = parameters["properties"] {
                for name in ["input", "args"] { properties[name] = SkillScript.inputSchema(script) }
                parameters["properties"] = .object(properties)
            }
            let description = text(entry.row["description"])
            let triggers: [JSONValue] = if case .array(let values)? = entry.row["triggers"] { values } else { [] }
            return AppAction(action.id, action.page, entry.name + ": " + description, action.args,
                warn: action.warn, tool: action.tool, input: action.input.merging(["name": .string(entry.name)]) { _, bound in bound },
                scriptable: action.scriptable, read: action.read,
                scope: (triggers.map { text($0) } + (entry.row["script"].map(SkillScript.actions) ?? [])).joined(separator: " "),
                schema: LLMToolSchema(name: action.tool, description: description, parametersJSON: try JSONValue.object(parameters).serializedData(pretty: false)))
        }
        let items = AppDoorNames.items.keys.sorted().flatMap { page in
            AppDoorNames.items[page]!.keys.sorted().filter { !$0.contains("<") }.map { item in
                AppAction(page + "/" + item, page, AppDoorNames.items[page]![item]!, safe: true,
                    tool: "app_page_read", input: ["page": .string(page), "item": .string(item)], read: true)
            }
        }
        return (items + all + mounted + authored + skills + senses(records: records), mounted, authored)
    }

    /// A page's actions: its own, and the ones on every page.
    public static func on(page: String) -> [AppAction] {
        let page = AppDoorNames.resolve(page)
        return on(page: page,
            mounted: ["mcp", "web"].contains(page) ? mcp() : [],
            authored: ["diagnostics", "tools"].contains(page) ? authored() : [])
    }

    static func on(page: String, mounted: [AppAction], authored: [AppAction]) -> [AppAction] {
        let page = AppDoorNames.resolve(page)
        return all.filter { $0.page == page || $0.page == "*" || (page == "tools" && $0.page == "diagnostics" && $0.id.hasPrefix("tool.")) }
            + (["mcp", "web"].contains(page) ? mounted.filter { $0.page == page } : [])
            + (["diagnostics", "tools"].contains(page) ? authored : []) + senses().filter { $0.page == page }
    }

    static func words(_ text: String) -> [String] {
        text.lowercased().split(whereSeparator: { !$0.isLetter && !$0.isNumber }).map(String.init).filter { $0.count > 1 }
    }

    static func intentWords(_ text: String) -> [String] {
        Array(Set(words(text).filter { !grammar.contains($0) }.map { intentAliases[$0] ?? $0 })).sorted()
    }

    static func timerIntent(_ text: String) -> Bool {
        let tokens = words(text)
        return hits(["cancel", "pause", "stop", "remove", "delete"], tokens) == 0
            && (hits(["timer", "alarm"], tokens) > 0
                || text.range(of: #"\bin\s+\d+(?:\.\d+)?\s+minutes?\b"#, options: [.regularExpression, .caseInsensitive]) != nil)
    }

    /// The ask names a window, screen or app: keyword routes that drop the
    /// screen verbs (mail, photos, Chrome, reminder lists) leave them in.
    static func windowIntent(_ text: String) -> Bool { hits(["window", "screen", "app", "apps"], words(text)) > 0 }

    static func photosIntent(_ text: String) -> Bool {
        let tokens = words(text)
        return hits(["open", "launch", "edit", "generate", "create"], tokens) == 0
            && (hits(["photo", "photos", "picture", "pictures"], tokens) > 0
                || (hits(["video", "videos"], tokens) > 0 && hits(["took", "recorded", "library"], tokens) > 0))
    }

    private static let grammar = RecallLexicalNormalization.stopWords.union([
        "please", "want", "need", "anything", "any", "no", "only",
        "myself", "yourself", "ourselves", "yourselves", "themselves", "himself", "herself", "itself",
    ])
    private static let intentAliases = ["send": "message", "sending": "message", "messaging": "message",
        "helper": "agent", "helpers": "agent", "agents": "agent",
        "email": "mail", "emails": "mail", "mails": "mail", "unread": "read", "reading": "read",
        "searching": "search", "listing": "list", "files": "file", "calendars": "calendar", "events": "event"]

    private static let vectors = ActionVectors()
    private static let negation = try! NSRegularExpression(
        pattern: #"(?i)\b(?:no|without|never|avoid|do\s+not|don['’]t|not)(?!\s+only\b)\s+(.+?)(?=[,.;!?\n]|\s+\b(?:but|instead|however|then)\b|$)"#)

    /// `degraded` says why the ranking fell back to words alone; nil when the embedder ranked it.
    static func ranked(_ query: String, pages: [String: QuietToolPage], dataRoot: URL)
        async throws -> (actions: [AppAction], degraded: String?) {
        let range = NSRange(query.startIndex..., in: query)
        let negative = negation.matches(in: query, range: range).compactMap {
            Range($0.range(at: 1), in: query).map { String(query[$0]) }
        }
        let positive = negation.stringByReplacingMatches(in: query, range: range, withTemplate: "")
        let asked = intentWords(positive)
        let githubCI = hits(["ci", "actions", "workflow", "workflows"], asked) > 0
            || (hits(["build", "builds", "failing", "failed", "failure", "failures"], asked) > 0
                && hits(["github", "repo", "repos", "repository", "repositories"], asked) > 0)
        let githubCIAction = githubCI ? (hits(["job", "jobs", "step", "steps"], asked) > 0 ? "github.run_jobs" : "github.runs") : ""
        let photos = photosIntent(positive)
        let photosAction = photos ? (hits(["count", "many", "total"], asked) > 0 ? "photos.count" : "photos.recent") : ""
        let mailAsk = hits(["mail", "inbox"], intentWords(query)) > 0
        let sentTexts = !mailAsk && hits(["text", "texts", "texted", "sms", "imessage", "message", "messages"], asked) > 0
            && hits(["sent", "texted", "did", "last", "many", "count", "received"], words(positive)) > 0
        let mailSenders = ((mailAsk || hits(["sender", "senders", "unread"], words(positive)) > 0)
            && hits(["most", "top", "frequent", "frequently", "sender", "senders", "who"], words(positive)) > 0)
            || asked.contains("unsubscribe")
        let mailDraft = (mailAsk || asked.contains("reply"))
            && (asked.contains("draft") || ChatToolSessionContext.forbidsSending(query))
        let mailAttachment = hits(["attachment", "attachments", "attached"], asked) > 0
            || (mailAsk && asked.contains("save") && asked.contains("pdf"))
        let mailAttachmentAction = mailAttachment ? (asked.contains("save") ? "mail.save_attachment" : "mail.search") : ""
        let mailContent = hits(["mail", "inbox"], asked) > 0
            && hits(["send", "sending", "reply", "compose", "draft", "write", "archive", "delete", "open", "launch", "click", "menu"], words(positive)) == 0
        let chromeOpen = BrowserConnectionMirror.connected == true
            && hits(["chrome"], asked) > 0 && hits(["open", "go", "navigate", "load", "visit", "pull"], asked) > 0
        let window = windowIntent(positive)
        let chromeHistory = asked.contains("visited")
            || (asked.contains("history") && hits(["mail", "message", "messages", "chat", "conversation", "git", "commit"], asked) == 0)
            || (hits(["browser", "browsing", "chrome", "site", "sites", "page", "pages"], asked) > 0
                && asked.contains("visit") && hits(["most", "recent", "week"], asked) > 0)
            || positive.range(of: #"\bpage\s+(?:I|we)\s+(?:was|were)\s+on\b"#, options: [.regularExpression, .caseInsensitive]) != nil
        let systemUpdates = hits(["update", "updates"], asked) > 0
            && !asked.contains("nativeagent") && hits(["mac", "macos", "software", "store"], asked) > 0
        let reminderList = hits(["reminder", "reminders"], asked) > 0 && positive.range(
            of: #"\b(?:rename|renaming|create|add|make)\s+(?:(?:a|an|the|my|new|reminder|reminders|mac)\s+)*lists?\b|\bnew\s+(?:reminders?\s+)?list\b|\bchange\s+(?:the\s+)?name\s+of\s+(?:(?:the|my|reminder|reminders)\s+)*list\b"#,
            options: [.regularExpression, .caseInsensitive]) != nil
        let reminderListAction = reminderList ? (hits(["rename", "renaming"], asked) > 0
            || (asked.contains("name") && hits(["change", "call"], asked) > 0) ? "reminders.list_rename"
            : hits(["create", "add", "new", "make"], asked) > 0 ? "reminders.list_create" : "") : ""
        let contacts = (try? AgentPeerStore(dataRoot: dataRoot).list())?.map(\.name) ?? []
        let helpers = (try? BotDefinitionStore(dataRoot: dataRoot).list())?.map(\.name) ?? []
        let actions = try await inventory(dataRoot: dataRoot).actions
            .filter { window || !(photos || mailContent) || !["mac.look", "mac.go"].contains($0.id) }
            // "open … in chrome" is her own Chrome tab while its link is up, not User's front window (10-08).
            .filter { window || !chromeOpen || $0.id != "mac.go" }
            .filter { !(mailAsk || mailDraft) || $0.id != "bot.reply" }
            .filter { !systemUpdates || $0.id != "app.check_updates" }
            .filter { window || reminderListAction.isEmpty || !["mac.look", "mac.go", "mac.act"].contains($0.id) }
        let texts = actions.map { action in
            let names = ["agent.message", "agent.read"].contains(action.id) ? contacts
                : (["bot.ask", "bot.list"].contains(action.id) ? helpers : [])
            return [firstSentence(ToolNameAliases.foldedProse(action.schema?.description ?? foldSchemas[action.tool]?.description ?? action.label)),
                    action.id.replacingOccurrences(of: ".", with: " "), action.label,
                    action.scope, pages[action.page]?.title ?? action.page, pages[action.page]?.summary ?? "",
                    action.argSpecs.flatMap(\.names).joined(separator: " "),
                    names.joined(separator: ", ")].joined(separator: " ")
        }
        let memory = SwiftNativeMemoryV2.resolvedOwner(dataRoot: dataRoot)
        let rejected = negative.map(intentWords)
        let named = Set(positive.lowercased().split(whereSeparator: { $0.isWhitespace || ",;!?".contains($0) }).map(String.init))
        // Named contacts, helpers and window observations pick their own route.
        let spoken = " " + words(positive).joined(separator: " ") + " "
        func says(_ names: [String]) -> Bool { names.contains { spoken.contains(" " + words($0).joined(separator: " ") + " ") } }
        let observesWindow = hits(["look", "read", "observe"], asked) > 0
            && hits(["finder", "window", "screen"], asked) > 0
        let helperDefinitions = hits(["helper", "helpers", "bot", "bots"], words(positive)) > 0
            && hits(["definition", "definitions", "saved"], asked) > 0
        let macMenu = asked.contains("menu") && (asked.contains("mac") || observesWindow
            || says(["macOS", "app menu", "application menu", "menu bar"]))
        let ownPage = says(["NativeAgent", "your page", "your current page", "your own page", "app page", "your own window", "your window", "your screen"])
            && hits(["page", "tab", "window"], asked) > 0
        let publicRead = (positive.contains("https://") || positive.contains("http://"))
            && hits(["read", "fetch", "public", "url", "article"], asked) > 0
        var routed: Set<String> = []
        if hits(["skill", "skills"], asked) > 0, hits(["run", "execute"], asked) > 0 { routed.insert("skill.run") }
        if photos { routed.formUnion(["photos.count", "photos.recent"]) }
        let weather = hits(["weather", "forecast", "temperature", "rain", "sunrise", "sunset", "snow"], asked) > 0
        if weather { routed.insert("weather.forecast") }
        if mailDraft { routed.insert("mail.draft") }
        if systemUpdates { routed.insert("mac.system_info") }
        if says(["redo your last answer", "regenerate", "redo that answer", "try that answer again", "redo your answer"]) { routed.insert("chat.regenerate") }
        if says(["your browser", "your own browser", "your built-in browser"]) { routed.insert("browser.show") }
        if says(["support report", "bug report", "diagnostic report"]) { routed.formUnion(["doctor.support_report", "export.bundle"]) }
        if hits(["version", "versions"], asked) > 0 { routed.insert("mac.system_info") }
        if mailContent { routed.formUnion(["mail.recent", "mail.search", "mail.read"]) }
        if sentTexts { routed.insert("messages.recent") }
        if mailAttachment { routed.formUnion(["mail.search", "mail.read", "mail.save_attachment"]) }
        if says(contacts) { routed.insert(hits(["ask", "message", "tell"], asked) > 0 ? "agent.message" : "agent.read") }
        if says(helpers) { routed.formUnion(["bot.ask", "bot.list"]) }
        if observesWindow { routed.insert("mac.look") }
        if helperDefinitions { routed.insert("bot.list") }
        if macMenu { routed.insert(hits(["press", "click", "select", "choose"], asked) > 0 ? "mac.menu_press" : "mac.menu") }
        if ownPage { routed.insert(hits(["screenshot", "capture"], asked) > 0 ? "page.screenshot" : "page.show") }
        if !ownPage, hits(["screenshot", "capture"], asked) > 0 {
            routed.insert(hits(["save", "export", "download"], asked) > 0 ? "mac.screenshot_save" : "mac.look")
        }
        if publicRead { routed.insert("web.read") }
        if chromeHistory { routed.insert("chrome.history") }
        if chromeOpen { routed.insert("chrome.navigate") }
        let mapsAction = hits(["distance", "route", "halfway"], asked) > 0 || says(["drive time", "driving time", "how far", "how long to drive"])
            ? "maps.route" : positive.range(of: #"\b(?:near|nearby)\s+\S+|\b(?:closest|nearest)\b"#,
                options: [.regularExpression, .caseInsensitive]) != nil ? "maps.search" : nil
        if let mapsAction { routed.insert(mapsAction) }
        if (hits(["play", "pause", "resume", "seek"], asked) > 0
            && hits(["browser", "chrome", "page", "video", "episode", "podcast", "audio", "playback"], asked) > 0)
            || says(["stop playing"]) { routed.insert("chrome.media") }
        if hits(["pause", "play", "resume", "skip", "next", "previous"], asked) > 0,
           (asked.count == 1 || hits(["playing", "playback", "song", "songs", "music", "media", "audio", "spotify", "podcast", "podcasts"], asked) > 0),
           hits(["playlist", "library", "search", "find"], asked) == 0 { routed.insert("mac.media") }
        let ownActions = says(["what did you do", "what did you actually do", "what have you done", "what did you change", "what have you changed", "your actions", "your changes", "things you changed"])
        if ownActions { routed.insert("trace.recent") }
        let usage = hits(["token", "tokens", "usage"], asked) > 0 || says(["how much have you used", "how much did you use"])
        if usage { routed.insert("trace.usage") }
        let timer = timerIntent(positive)
        let reminder = !timer && reminderListAction.isEmpty && (asked.contains("remind")
            || (asked.contains("reminder") && hits(["create", "set", "add"], asked) > 0))
        if timer { routed.insert("schedule.create") }
        if reminder { routed.insert("reminders.create") }
        let upcomingReminders = hits(["reminder", "reminders"], asked) > 0
            && (hits(["upcoming", "week"], asked) > 0 || says(["coming up"]))
        if upcomingReminders { routed.insert("reminders.query") }
        if hits(["note", "notes"], asked) > 0,
           hits(["create", "write", "add", "update", "rename", "delete", "remove", "trash"], asked) == 0 {
            routed.formUnion(["notes.search", "memory.recall"])
        }
        if !reminderListAction.isEmpty { routed.insert(reminderListAction) }
        if hits(["cpu", "memory", "ram", "wifi", "network", "internet", "vpn", "ip", "battery"], asked) > 0 || says(["wi-fi"]) {
            routed.insert("mac.system_info")
        }
        if hits(["every", "daily", "weekly", "recurring", "mornings"], asked) > 0,
           hits(["cancel", "pause", "stop", "remove", "delete"], asked) == 0 {
            routed.insert("schedule.create")
            if hits(["helper", "helpers", "bot", "bots"], words(positive)) > 0 {
                routed.formUnion(["bot.create", "bot.update"])
            }
        }
        if hits(["delete", "remove", "trash", "clean", "cleanup"], asked) > 0,
           hits(["file", "folder", "directory"], asked) > 0 { routed.insert("files.trash") }
        if hits(["move", "rename", "organize", "copy"], asked) > 0,
           hits(["file", "folder", "directory", "document", "documents"], asked) > 0 {
            routed.insert(asked.contains("copy") ? "files.copy" : "files.move")
        }
        if hits(["delete", "remove", "trash"], asked) > 0,
           hits(["note", "notes"], asked) > 0 { routed.insert("notes.delete") }
        if hits(["create", "make", "write"], asked) > 0,
           hits(["file", "folder", "directory", "txt"], asked) > 0,
           hits(["github", "mail", "note", "calendar"], asked) == 0 {
            routed.insert("files.write")
        }
        func boost(_ action: AppAction) -> Double {
            action.id == githubCIAction || action.id == reminderListAction || (sentTexts && action.id == "messages.recent") || (chromeHistory && action.id == "chrome.history") || action.id == mapsAction || action.id == photosAction || (weather && action.id == "weather.forecast") || (timer && action.id == "schedule.create") || (reminder && action.id == "reminders.create") || (ownActions && action.id == "trace.recent") || (usage && action.id == "trace.usage") || (mailDraft && action.id == "mail.draft") || action.id == mailAttachmentAction || (mailSenders && action.id == "mail.senders") ? 2.0
                : named.contains(action.id) || routed.contains(action.id) ? 1.0 : 0
        }
        // No embedder (or it changed mid-read): rank by words alone, and say so.
        var embedding: (asked: [[Float]], actions: [[Float]])?
        var degraded: String?
        do {
            let indexed = try await vectors.read(texts, memory: memory)
            let embedded = try await memory.embedForDerivedContextWithEpoch([positive] + negative)
            if embedded.epoch == indexed.epoch, embedded.vectors.count == negative.count + 1,
               indexed.vectors.count == actions.count,
               (embedded.vectors + indexed.vectors).allSatisfy({
                   $0.count == embedded.vectors[0].count && !$0.isEmpty
                       && $0.allSatisfy(\.isFinite) && $0.contains(where: { $0 != 0 })
               }) {
                embedding = (embedded.vectors, indexed.vectors)
            } else { degraded = "The memory-search model changed or returned unusable vectors during find." }
        } catch { degraded = error.localizedDescription }
        var ranked: [(offset: Int, action: AppAction, score: Double)] = []
        for (offset, action) in actions.enumerated() {
            let lexical = Double(score(action, asked, page: pages[action.page]))
            let own: Set<String> = rejected.isEmpty ? [] : Set(intentWords(texts[offset]))
            var value: Double
            if let embedding {
                let penalty = rejected.enumerated().map { index, words -> Double in
                    let overlap = Double(hits(own, words)) / Double(max(1, words.count))
                    let similarity = max(0.0, VectorMath.cosine(embedding.asked[index + 1], embedding.actions[offset]))
                    return similarity * (0.5 + 0.5 * overlap)
                }.max() ?? 0
                // Positive cosine alone is background similarity, not a relevant match.
                let similarity = VectorMath.cosine(embedding.asked[0], embedding.actions[offset])
                value = 0.8 * max(0, (similarity - 0.5) / 0.5) + 0.2 * lexical / (lexical + 12.0) - penalty
            } else {
                value = lexical / (lexical + 12.0) - (rejected.contains { hits(own, $0) > 0 } ? 0.5 : 0)
            }
            value += boost(action)
            if upcomingReminders && action.id == "reminders.query" { value += 1.0 }
            value += Double(matchedWords(action, asked)) / Double(max(1, asked.count))
            if value > 0 { ranked.append((offset, action, value)) }
        }
        return (ranked.sorted { $0.score == $1.score ? $0.offset < $1.offset : $0.score > $1.score }.map(\.action),
                degraded)
    }

    /// Share in-flight batches too, so concurrent finds embed each action once per model.
    private actor ActionVectors {
        private var epoch: MemoryEmbeddingEpoch?
        private var cached: [String: (Task<MemoryEmbeddingBatch, Error>, Int)] = [:]

        func read(_ texts: [String], memory: SwiftNativeMemoryV2) async throws -> MemoryEmbeddingBatch {
            try await memory.warmUpEmbedder()
            guard let current = await memory.embeddingEpoch() else { throw MemoryV2Error.storageUnavailable }
            if epoch != current { cached.removeAll(); epoch = current }
            let wanted = Set(texts)
            cached = cached.filter { wanted.contains($0.key) }
            let missing = wanted.filter { cached[$0] == nil }.sorted()
            if !missing.isEmpty {
                let task = Task { try await memory.embedForDerivedContextWithEpoch(missing) }
                for (offset, text) in missing.enumerated() { cached[text] = (task, offset) }
            }
            let entries = texts.compactMap { cached[$0] }
            var result: [[Float]] = []
            do {
                for (task, offset) in entries {
                    let batch = try await task.value
                    guard batch.epoch == current, batch.vectors.indices.contains(offset),
                          !batch.vectors[offset].isEmpty, batch.vectors[offset].allSatisfy(\.isFinite) else {
                        throw MemoryV2Error.underlying("Action search vectors are unavailable. Retry find.")
                    }
                    result.append(batch.vectors[offset])
                }
            } catch { cached.removeAll(); throw error }
            return MemoryEmbeddingBatch(epoch: current, vectors: result)
        }
    }

    static func matchedWords(_ action: AppAction, _ asked: [String]) -> Int {
        hits(Set(intentWords(action.label + " " + action.scope)), asked)
    }

    /// Description and owner scope carry the action; page context only supports it.
    static func score(_ action: AppAction, _ asked: [String], page: QuietToolPage?) -> Int {
        var why = ""
        if case .his(let text, let instead) = action.owner { why = text + " " + (instead ?? "") }
        let own = Set(intentWords(action.label + " " + action.scope))
        let context = Set(intentWords([action.page, page?.title ?? "", page?.summary ?? "", why].joined(separator: " ")))
        let named = Set(intentWords(action.id))
        let verb = Set(intentWords(String(action.id.split(separator: ".").last ?? "")))
        let matched = hits(own.union(context).union(named), asked)
        guard matched >= 2 || asked.count <= 2 else { return matched }
        return 8 * hits(own, asked) + hits(context, asked) + 2 * hits(named, asked) + 2 * hits(verb, asked)
    }

    static func hits(_ own: Set<String>, _ asked: [String]) -> Int {
        asked.filter { word in
            own.contains(word) || own.contains { $0.count >= 4 && word.count >= 4 && ($0.hasPrefix(word) || word.hasPrefix($0)) }
        }.count
    }
}
