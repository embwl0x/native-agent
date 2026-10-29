import AgentWorkspace
import MacIntegration
import NativeAgentCore
import NativeAgentShared
import PersistenceCore
import ToolRegistry
import AgentConversations
import AuthoredCapabilities
import ChatToolRuntime
import Foundation
import PersonaEngine
import Senses
import MultimodalTTS
import ChatSessionWork
import Cognition
import Context
import AttentionRouting
import ProviderRouting
import DeviceSync
import TrustCenter
import ChatTurnContracts
import ChromeControl
import MemoryV2
import StandingBots
import TurnTrace
import Studio
// Blueprint: | `AppActions+Declarations.swift` | AppActions seed declarations, fixed input, layout vocabulary and hot actions in their catalog order |

extension AppActions {
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

    static let seedActions: [AppAction] = [
        AppAction("chrome.history", "browser", "Read visited sites and browsing history in Chrome (the whole Default profile, every tab and window, not just her own tab): most visited domains, title/URL search or recent pages",
                  ["mode?", "query?", "since?", "limit?:int"],
                  warn: "mode: recent (default when omitted), top_domains (since required) or search (query required, since optional). since: inclusive ISO 8601 with timezone. limit: default 15, max 50. Chrome Default profile only, independent of extension/tab group; local ISO 8601 times. Domain counts: visits since since; page counts: lifetime visits. Requires Full Mac and file-read permission; no card. Deadline: 2 seconds.",
                  tool: "read_file", read: true),
        AppAction("photos.count", "files", "Count how many photos, pictures or recorded videos are in Photos by creation date and media type",
                  ["start?", "end?", "media_type?"],
                  warn: "start/end: ISO 8601 with timezone, start inclusive/end exclusive. media_type: all (default), image or video. Requests macOS Photos access on call; limited access counts only shared assets.",
                  tool: "photos_read", input: verb("count"), read: true),
        AppAction("photos.recent", "files", "Read recent photos, pictures and recorded videos in Photos: creation date, media type, dimensions, favorite and stored location coordinates",
                  ["limit?:int", "start?", "end?", "media_type?"],
                  warn: "limit: 1–100, default 10, newest creation first. start/end: ISO 8601 with timezone, start inclusive/end exclusive. media_type: all (default), image or video. Metadata only; requests macOS Photos access on call.",
                  tool: "photos_read", input: verb("recent"), read: true),
        // Today's Inbox: the notes Today and the Desk count. Each id is the word on the note's button; a note read lists its buttons as
        // these ids.
        AppAction("inbox.archive", "inbox", "Archive", ["ids|id", "reason"], tool: "inbox", input: verb("archive")),
        AppAction("inbox.acknowledge", "inbox", "Archive", ["ids|id", "reason"], tool: "inbox", input: verb("archive")),
        AppAction("inbox.dismiss", "inbox", "Dismiss", ["ids|id", "reason"], tool: "inbox", input: verb("dismiss")),
        AppAction("inbox.mark_read", "inbox", "Mark read (opening a note does this)", ["ids|id", "reason"],
                  tool: "inbox", input: verb("mark_read")),
        AppAction("inbox.repair", "inbox", "Repair", ["id"], tool: "inbox", input: verb("repair")),
        AppAction("inbox.act", "inbox", "Act", ["id", "action?"], irreversible: true, capabilities: ["app_data_write", "safe_read", "tool_call"], tool: "inbox", input: verb("act")),
        AppAction("inbox.clean_up", "inbox", "Clean Up", ["id"], tool: "inbox", input: press("act")),
        AppAction("inbox.open_approvals", "inbox", "Open Approvals", ["id"], tool: "inbox", input: press("open_approvals")),
        AppAction("inbox.not_now", "inbox", "Not now", ["id", "reason?"], irreversible: true,
                  capabilities: ["app_data_write", "safe_read", "tool_call"], warn: "declines the card. The owner's own Not now wakes the conversation that raised it; yours does not: "
                      + "the card retires and that request does not run again",
                  tool: "inbox", input: verb("not_now")),
        AppAction("inbox.withdraw", "inbox", "Withdraw my own pending approval", ["id", "reason?"], irreversible: true,
                  capabilities: ["app_data_write", "safe_read", "tool_call"], tool: "inbox", input: verb("withdraw")),
        AppAction("inbox.open_on_mac", "inbox", "Open on Mac", ["id"], owner: .his("it opens the card for the owner at the Mac",
                  instead: "inbox.not_now declines it; inbox.archive retires a stale one"), tool: "inbox", input: press("act")),
        AppAction("inbox.approve", "inbox", "Approve", ["id"], owner: .his("it is his consent; he approves on Today or the banner"),
                  irreversible: true, capabilities: ["app_data_write", "safe_read", "tool_call"], tool: "inbox", input: press("approve")),
        AppAction("inbox.deny", "inbox", "Deny", ["id"], owner: .his("it decides an approval; he answers on Today or the banner"),
                  irreversible: true, capabilities: ["app_data_write", "safe_read", "tool_call"], tool: "inbox", input: press("reject")),

        // Chat: the sidebar and the conversation's own controls. An idempotent append through Reach's owner, independent of a page version.
        AppAction("chat.post", "chat", "Tell the person directly", ["message"], irreversible: true,
                  toolClass: .send, reach: .his, capabilities: ["app_data_write", "safe_read", "tool_call"], tool: "chat_post", versionExempt: true),
        AppAction("chat.list", "chat", "Conversations, newest first; query filters by title; pinned:true only pinned, pinned:false only unpinned; filters apply before offset", ["archived?:bool", "pinned?:bool", "query?", "offset?:int"],
                  tool: "chat_conversations", read: true),
        AppAction("chat.new", "chat", "New chat; title names it in the same call", ["title?"], tool: "chat_session", input: verb("new")),
        AppAction("chat.show", "chat", "Show", ["session_id"], screen: true, tool: "chat_session", input: verb("show")),
        AppAction("chat.rename", "chat", "Rename", ["session_id", "title"], tool: "chat_session", input: verb("rename")),
        AppAction("chat.pin", "chat", "Pin", ["session_id?"], tool: "chat_session", input: verb("pin")),
        AppAction("chat.unpin", "chat", "Unpin", ["session_id?"], tool: "chat_session", input: verb("unpin")),
        AppAction("chat.archive", "chat", "Archive", ["session_id?", "reason?"], tool: "chat_session", input: verb("archive")),
        AppAction("chat.stop", "chat", "Stop", ["session_id?"], tool: "chat_session", input: verb("stop")),
        AppAction("chat.regenerate", "chat", "Regenerate (redo / try again) your last answer", ["session_id?"], irreversible: true,
                  capabilities: ["app_data_write", "safe_read", "tool_call"], tool: "chat_session", input: verb("regenerate")),
        AppAction("chat.steer", "chat", "Steer (queue)", ["turn_id", "session_id?"], tool: "chat_session",
                  input: queue("steer")),
        AppAction("chat.send_next", "chat", "Send next (queue)", ["turn_id?", "session_id?"], tool: "chat_session",
                  input: queue("send_next")),
        // Irreversible: the queued message is dropped from memory, and nothing keeps User's words to bring back.
        AppAction("chat.remove", "chat", "Remove (queue)", ["turn_id", "session_id?", "reason?"], irreversible: true,
                  capabilities: ["app_data_write", "safe_read", "tool_call"], tool: "chat_session", input: queue("remove")),
        AppAction("chat.compact", "chat", "Compact now", ["session_id?"], tool: "chat_session", input: verb("compact_now")),
        AppAction("chat.export", "chat", "Export to Markdown", ["session_id?"], tool: "chat_session", input: verb("export")),
        AppAction("chat.detach", "chat", "Open in its own window", ["session_id?"], screen: true,
                  tool: "chat_session", input: verb("detach")),
        AppAction("chat.close_window", "chat", "Close its window", ["session_id?"], screen: true,
                  tool: "chat_session", input: verb("close_window")),
        AppAction("chat.clear", "chat", "/clear", ["session_id"], irreversible: true,
                  capabilities: ["app_data_write", "safe_read", "tool_call"], tool: "chat_session", input: verb("clear")),
        // The composer.
        AppAction("chat.draft", "chat", "Draft", ["value", "session_id?", "attachments?:list"],
                  tool: "interaction_act", input: composer("set_draft")),
        AppAction("chat.send", "chat", "Send", ["value?", "session_id?", "attachments?:list"], irreversible: true,
                  toolClass: .send, capabilities: ["app_data_write", "safe_read", "tool_call"], tool: "interaction_act", input: composer("send")),
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
        // What she makes, in versions; the Work pane's Make tab shows them. Version-exempt: add only appends a version, and never touches
        // one.
        AppAction("make.add", "chat", "Add a file to Make as a new version of ref (a new ref when left out); returns the ref",
                  ["path", "ref?", "prompt?", "model?"], tool: "make_studio", input: verb("add"), versionExempt: true),
        AppAction("make.read", "chat", "A Make ref's versions: n, path, prompt, created (the newest ref when left out)",
                  ["ref?"],tool: "make_studio", input: verb("read"), read: true),
        AppAction("studio.intake.read", "personality", "Read neutral consult or corrected complete-history facts for unanswered-work intake; carry snapshot through every page",
                  ["kind:history|consults", "offset?:number", "snapshot?"], capabilities: ["app_data_read"], tool: "studio_intake_read", read: true),
        // What goes with her answer, by her hand: the reply's face carries it to every door.
        AppAction("reply.attach", "chat", "Attach an image to the reply you are writing now; it goes with your answer wherever this conversation is answered (the Mac chat, Telegram)",
                  ["path"], warn: "One image per call, by its own path: jpg, png, gif, webp, bmp or heic, inside your Trust workspace unless this Mac is in Full Mac.",
                  tool: "read_file", read: true),
        // Her own fix for a place, in her turn; then it's built.
        AppAction("sense.make", "chat", "Learn to read a Mac app, live Chrome site, or foreign file format (including binary) from captured material. Plain text uses files.read; a web page is read with read_page (app web.read), not sense.make. Folder watches are not sense.make corners: to act when a file or folder changes, save an ability whose header wakes on file.changed:<path> (ability.save). Read with mac.look, chrome.snapshot or files.read first. code: complete sense.js; kit: Contents/Resources/Senses (AUTHORING.md, sense.js, builtin/app.js, builtin/site.js). Runs on the last-read place or explicit place; returns page, trial_id/digest and timing. Keep the exact trial with {trial_id,digest,keep:true}, no code. {code,keep:true} runs and keeps immediately. {show:\"material\"} returns captured material",
                  ["code?", "trial_id?", "digest?", "keep?:bool", "place?", "why?", "show?", "apps?:list", "reach?:object", "wake?:list", "face?:object", "resident?:bool", "learned?:any", "choices?:any"],
                  capabilities: ["app_data_write", "safe_read", "tool_call"], warn: "apps declares bundle ids for sense.apps.read({bundle_id,dictionary:true}) or read-only Apple Events using event_class, event_id and parameters. Standard core getd/cnte/doex events are reads; other events require a tool's write declaration.", tool: "sense_make",
                  readWhen: ["show": .string("material"), "trial_id": .null, "digest": .null], lifecycle: .change),
        AppAction("sense.versions", "senses", "Read a sense's current and retained versions", ["sense_id"],tool: "sense_lifecycle", input: ["verb": .string("versions")], read: true),
        AppAction("sense.quarantine", "chat", "Turn a sense off while retaining its current and previous versions", ["sense_id", "version:int"], tool: "sense_lifecycle", input: ["verb": .string("quarantine")], revision: 2, lifecycle: .change),
        AppAction("sense.restore", "chat", "Turn the selected sense version back on", ["sense_id"], tool: "sense_lifecycle", input: ["verb": .string("restore")], revision: 2, lifecycle: .restore),
        AppAction("sense.rollback", "chat", "Swap the current and previous sense versions; an on sense stays on, an off sense needs sense.restore", ["sense_id", "version:int"], tool: "sense_lifecycle", input: ["verb": .string("rollback")], revision: 2, lifecycle: .rollback),
        AppAction("sense.drop", "chat", "Delete a sense and its run statistics permanently", ["sense_id"], irreversible: true, capabilities: ["app_data_write", "safe_read", "tool_call"], tool: "sense_lifecycle", input: ["verb": .string("drop")], revision: 2, lifecycle: .drop),
        AppAction("persona.set", "personality", "Switch persona", ["name"], screen: true, tool: "interaction_act",
                  input: composer("set_persona"), rename: ["name": "value"]),
        AppAction("app.check_updates", "settings", "Check for NativeAgent updates only; macOS uses mac.system_info with check_updates:true, App Store apps use App Store → Updates",tool: "interaction_act",
                  input: composer("check_updates"), read: true),
        // How the window lays out each surface (ui/layout.json), hers to read and rewrite as the person asks; the window changes as a write
        // lands.
        AppAction("layout.read", "settings", "The window's layout: each surface's blocks in order, hidden and expanded, each view's profile, its version, the previous layout and what every block is",
                 tool: "app_page_read", read: true, scope: layoutScope),
        AppAction("layout.write", "settings", "Change the layout, passing layout.read's version as layout_version and only what changes (a surface's whole block list, a profile, phone); the window follows at once; undo puts the previous one back",
                  ["layout:object", "layout_version"], tool: "app_setting_set", scope: layoutScope),
        // Settings rows: owner_only rows stay his, lower-only rows move the safe way.
        AppAction("setting.get", "*", "Read one setting's current value by its id (the page read app {page} lists them)", ["setting"],
                 tool: "app_setting_get", read: true, scope: "setting value read get home timezone"),
        AppAction("setting.set", "*", "Set", ["setting", "value:any", "because"],
                  warn: "on model turns, because must quote at least 3 words from a person or trusted agent in this conversation; you may restore a switch whose last change was yours",
                  tool: "app_setting_set"),
        // Version-exempt: generated captures have no user state to overwrite.
        AppAction("page.screenshot", "*",
                  "Screenshot of one of your own NativeAgent pages (your current page, chat, settings…), drawn offscreen; returns the PNG's path. Not the Mac screen. tab is a tab key as page.show takes it "
                  + "(trust_access…), the page's default tab when left out", ["page", "tab?", "height?:int"],
                  warn: "saves a PNG and prunes old page captures", tool: "app_page_screenshot", versionExempt: true),
        // Inline cards, by the interaction id the chat read or the card's inbox note lists, in whichever conversation raised them. Whose
        // card it is and what it moves are decided per card: a card from User's phone or Telegram, or one that raises what you may reach
        // below Full Mac, stays his and says so. Irreversible: the card's own button does what it asked, as inbox.approve does, and nothing
        // presses it back.
        AppAction("permissions.request", "chat", "Ask for a macOS permission in your own words", ["capability", "why", "mode?"],
                  capabilities: ["safe_read", "tool_call"], warn: "capability: \(SystemPermissionCapability.requestable); Automation: applescript:<bundle_id>. Only the person taps Allow on the Mac; the waiting work continues after the grant.",
                  tool: "request_interaction", input: ["kind": .string("permission")], folded: true),
        AppAction("card.answer", "chat", "The card's own button (its Do: line)", ["id", "value?:secret", "choice?"],
                  irreversible: true, capabilities: ["app_data_write", "safe_read", "tool_call"], warn: "never ask the owner for a key or token in chat: they type it into the card",
                  tool: "interaction_act", input: card("primary"), rename: ["id": "interaction_id"]),
        AppAction("card.not_now", "chat", "Not now", ["id", "reason?"], irreversible: true, capabilities: ["app_data_write", "safe_read", "tool_call"], tool: "interaction_act",
                  input: card("decline"), rename: ["id": "interaction_id"]),
        // Irreversible: it runs the card's own control as card.answer does, a capability grant included.
        AppAction("card.try_again", "chat", "Try again", ["id", "value?:secret", "choice?"], irreversible: true,
                  capabilities: ["app_data_write", "safe_read", "tool_call"], tool: "interaction_act",
                  input: card("retry"), rename: ["id": "interaction_id"]),

        // Providers.
        AppAction("provider.test", "providers", "Test the connection", ["provider"],tool: "provider",
                  input: verb("test"), read: true),
        AppAction("provider.refresh", "providers", "Refresh", tool: "provider", input: verb("refresh_models")),
        AppAction("provider.set_fallback_model", "providers", "Model it falls back to", ["provider", "model"],
                  tool: "provider", input: verb("set_default_model")),
        AppAction("provider.sign_in", "providers", "Sign in",
                  owner: .his("he signs in through the browser window Providers → Sign in opens, or pastes the key there")),
        AppAction("provider.disconnect", "providers", "Disconnect", ["provider"],
                  owner: .his("only he can sign back in; he disconnects on Providers"), irreversible: true,
                  capabilities: ["app_data_write", "safe_read", "tool_call"], tool: "provider", input: verb("disconnect")),

        // Connectors, Telegram and the paired phone: down, never up.
        AppAction("connector.off", "connectors", "Turn off", ["id", "reason?"], tool: "connections", input: verb("connector_off")),
        AppAction("connector.on", "connectors", "Turn on", ["id"], owner: .his("it raises Trust; he turns it on in Connectors"),
                  tool: "connections", input: verb("connector_on")),
        AppAction("connector.disconnect", "connectors", "Disconnect", ["id"],
                  owner: .his("only he can sign back in; he disconnects in Connectors", instead: "connector.off stops one"),
                  irreversible: true, capabilities: ["app_data_write", "safe_read", "tool_call"], tool: "connections", input: verb("connector_disconnect")),
        AppAction("telegram.repair", "telegram", "Rebuild admission index", ["inbox"], tool: "connections",
                  input: verb("telegram_repair")),
        // Irreversible: a real message to User's Telegram.
        AppAction("telegram.test", "telegram", "Send test reply", irreversible: true, toolClass: .send, capabilities: ["app_data_write", "safe_read", "tool_call"], tool: "connections",
                  input: verb("telegram_test")),
        AppAction("telegram.clear_logs", "telegram", "Clear logs", irreversible: true, capabilities: ["app_data_write", "safe_read", "tool_call"], tool: "connections",
                  input: verb("telegram_clear_logs")),
        AppAction("telegram.disconnect", "telegram", "Remove the token",
                  owner: .his("only he can sign back in; Connectors → Telegram",
                             instead: "setting.set with setting telegram.enabled, value false stops it"),
                  irreversible: true, capabilities: ["app_data_write", "safe_read", "tool_call"], tool: "connections", input: verb("telegram_disconnect")),
        AppAction("pairing.remove", "pairing", "Remove the phone", ["id"],
                  owner: .his("only he can pair it again; Connectors → iPhone"), irreversible: true,
                  capabilities: ["app_data_write", "safe_read", "tool_call"], tool: "connections", input: verb("pairing_remove")),

        // Upkeep buttons, on the pages that carry them.
        AppAction("doctor.run", "diagnostics", "Run Doctor checks",tool: "doctor_status", input: ["repair": .bool(false)], read: true),
        AppAction("doctor.repair", "diagnostics", "Repair", ["check_id?"], tool: "doctor_status", input: ["repair": .bool(true)]),
        AppAction("doctor.support_report", "diagnostics", "Support report: the app's diagnostic bundle to send to the developer", tool: "upkeep", input: verb("support_report")),
        AppAction("export.bundle", "capabilities", "Export a verified bundle file (support:true makes the support bundle to send the developer)", ["support?:bool"], tool: "upkeep", input: verb("export_bundle")),
        AppAction("backup.now", "trust", "Back up now", tool: "upkeep", input: verb("backup_now")),
        AppAction("backup.restore", "trust", "Restore", ["id"],
                  owner: .his("it replaces what is here now; Trust → Advanced → Backups → Restore"), irreversible: true,
                  capabilities: ["app_data_write", "safe_read", "tool_call"], warn: "a restore that needs it restarts NativeAgent when this turn ends, 20 seconds at most",
                  tool: "upkeep", input: verb("backup_restore")),
        AppAction("history.clear", "trust", "Delete all recorded activity", irreversible: true,
                  capabilities: ["app_data_write", "safe_read", "tool_call"], tool: "upkeep", input: verb("activity_wipe")),
        AppAction("embeddings.pause", "settings", "Pause the memory-search download", tool: "upkeep",
                  input: verb("embeddings_pause")),
        AppAction("embeddings.resume", "settings", "Resume the memory-search download", tool: "upkeep",
                  input: verb("embeddings_resume")),
        AppAction("memory.reindex", "memories", "Spotlight reindex", tool: "upkeep", input: verb("spotlight_reindex")),
        // Her memories, through MemoryCuration.
        AppAction("memory.list", "memories", "List memories with exact total and remaining counts; follow next_after_id only for more entries. "
                  + "sort newest_first (newest/latest) or oldest_first (oldest); status active (kept/saved/current) or archived. "
                  + "Archived entries include what replaced them",
                  ["status?", "sort?", "offset?:int", "after_id?", "limit?:int", "kind?"],tool: "list_memories",
                  read: true),
        AppAction("memory.rewrite", "memories", "Rewrite, pin, unpin or restore a memory",
                  ["id", "text?", "pinned?:bool", "restore?:bool", "reason?"],
                  capabilities: ["memory_write", "tool_call"], warn: "text is the thing itself, one or two sentences, no date, source, ids or preamble; "
                      + "a restore that matches something forgotten stays archived",
                  // Not version-exempt: a text rewrite or a restore can overwrite another conversation's correction. The supersede demotion
                  // is memory.commit's supersedes, which is.
                  tool: "rewrite_memory"),
        AppAction("memory.pin", "memories", "Pin a fact about the owner (identity, location, employment, schedule, preference, relationship, attribute) to your prompt core, in pin order; moments stay in recall", ["id"],
                  capabilities: ["memory_write", "tool_call"], tool: "rewrite_memory", input: ["pinned": .bool(true)]),

        // Her mind: Dreams (Personality), Self-Improvement (Today), her current mind state and body controls.
        AppAction("mind.dream", "personality", "Run a dream pass", tool: "mind_run", input: verb("dream")),
        AppAction("mind.rem", "personality", "Run a REM pass", ["repair?:bool"], tool: "mind_run", input: verb("rem")),
        AppAction("scheduler.trigger_fire", "desk", "Reconcile a claimed trigger", ["surface", "name", "occurrence?"], tool: "mind_run", input: verb("trigger_fire")),
        AppAction("mind.self_improvement", "today", "Self-Improvement: Run now", tool: "mind_run",
                  input: verb("self_improvement")),
        AppAction("mind.misses", "today", "Your misses: corrections by lesson, this week against last, each with its history locator",
                 tool: "mind_run", input: verb("misses"), read: true),
        AppAction("mind.think_now", "diagnostics", "Think now", tool: "mind_run", input: verb("think_now")),
        // Phase 5 B0: why something surfaced, and her two corrections.
        AppAction("mind.why", "personality", "Why a felt cue or memory surfaced on a turn (default: last completed turn)",
                  ["turn?"],tool: "mind_run", input: verb("why"), read: true),
        AppAction("mind.reject", "personality",
                  "Stop a memory, care or dream phrase surfacing for this kind of thing (source from mind.why)",
                  ["source", "turn?", "always?:bool"], tool: "mind_run", input: verb("reject")),
        AppAction("mind.undo", "personality",
                  "Undo an undertone nudge of yours; no item lists them",
                  ["item?"], tool: "mind_run", input: verb("undo")),
        AppAction("mind.reflect", "diagnostics", "Reflect", tool: "mind_run", input: verb("reflect")),
        AppAction("mind.settle_body", "diagnostics", "Settle your body state (calm down when wound up)", tool: "mind_run", input: verb("settle_body")),
        AppAction("mind.reset_body", "diagnostics", "Reset body", tool: "mind_run", input: verb("reset_body")),
        AppAction("mind.pin_concern", "diagnostics", "Keep a concern open in your cares: care names the care it belongs to in its own words, omitted it is a care of its own; omitted concern uses what presses most", ["concern?", "care?"], tool: "mind_run", input: verb("pin_concern")),
        AppAction("mind.clear", "diagnostics", "Clear the thought store",
                  irreversible: true, capabilities: ["app_data_write", "safe_read", "tool_call"], tool: "mind_run", input: verb("clear")),

        // Her parts (docs/AGENT_IS_THE_APP.md): what a part can do is what it declares, never which door made it. One save, one keep, one
        // run (authored.<id>), one read, one lifecycle; ability_manage runs them all.
        AppAction("ability.save", "tools", "Grow an ability beyond existing actions: apps through AppleScript/Apple Events, programs, servers or services; or keep a route that worked by hand. Resident abilities hold programs/connections until turned off or app quit; reopening at launch requires wake [\"resumed\"] and reopening code",
                  ["id", "description?", "code?", "edits?:list", "params?:any", "actions?:list", "fixtures?:list", "name?", "triggers?:list", "converts?:list", "create_only?:bool", "reach?:object", "wake?:list", "face?:object", "resident?:bool", "learned?:any", "choices?:any", "input_schema?:any", "permissions?:list"],
                  warn: "description: one line, at most 500 characters; details in params. code: sync-only JavaScript function run(input) returning JSON (to decline on purpose, return {status:\"refused\",reason:\"revision_required\",detail:\"This ability does not support that input.\",effects:\"none\",remedy:{instruction:\"Read this ability, then revise it for the input.\",next_call:{tool:\"app\",input:{action:\"ability.read\",args:{id:\"your_ability_id\"}}}}}; use the actual cause, detail, effects and id. A person-owned decision uses remedy {instruction,tap}; a terminal refusal uses remedy {kind:\"terminal\",instruction:\"why no further action is appropriate\",next_call:null}. A decline is an answer, not a fault; a throw or {ok:false} reads as broken and owes a repair); save refuses async, await or Promise outside strings/comments before execution. app.<page>.<action>(args) runs any action under ordinary gates; calls are derived from code. app.step(label,guidance), app.decide(question,data), app.expect(ok,what), app.expect_fail(code,fn) make a strict journal; decide hands back its question for ability.resume {run_id,answer}. Calls return action data plus call (action id) and effects (none,occurred,partial,unknown); failures throw catchable AppError with e.reason,e.effects,e.call,e.receipt. host.state.get() and host.state.set(value) persist this ability's JSON. host.files: read/list/info/excerpt/grep/spotlight/write/copy/move/trash/patch. host.network: connect/listen/accept/send/receive/close; connect takes {host,port,tls?,transport?} or {path} for a Mac socket (localhost). host.program.start({command,args?,env?,cwd?}) runs a path or a name on the login PATH, returning {id}. host.program.send and host.network.send take {id,text} or {id,base64}, each through Trust as an effect. host.program.receive({id})/host.network.receive({id}) return the next {text} or non-UTF-8 {base64,binary:true}, with eof and, for programs, stream/exit_code. receive/accept wait up to wait seconds (default 30), then {pending:true}; fetch waits up to wait seconds (default 120) for its whole answer. send waits up to wait seconds (default 30) for acceptance, else ends that program/connection. Over 4 MiB unread program output ends it. host.program.close({id}) ends it and its children; detached sessions can outlive it, as in the shell. Declare shell: requires Full Mac with file operations on, the same shell sandbox, and cwd inside the workspace (default) unless Full Mac lifts the sandbox. host.call(id,args) reaches exactly app.<id>(args) or the named primitive (host.call(\"network.send\",…) is host.network.send(…)), under the same declarations/gates. "
                      + "host.model.call({purpose,prompt|messages,schema?}) uses your current chat model, without persona, returning text or checked JSON; declare model. messages: {role,content} strings. "
                      + "host.fetch({url,method?,headers?,body?}) returns {status,headers,body}, body as UTF-8. Keyless calls require network_public, or network_localhost for loopback. Returns redirects without following. "
                      + "Use {{secret:<name>}} in fetch url/headers/body, network.send text or program args/env/stdin; declare secret:<name>. Values go only to their granted host (https, established TLS, or Mac loopback; never udp) or program, and read back as [secret:<name>]. An absent secret refuses with card.request to ask once. Secret-bearing GET/HEAD with no body is a read; every other secret-bearing call passes Trust as an effect. host.measurementSystem: us, metric or other. app.mac.system_info({person:true}) returns {here,idle_seconds} from the person's input only (never yours), away after 300 seconds idle. Use it: ioreg/event-source idle clocks count your input. "
                      + "host.calendar.list/search/create/update/delete map to calendar.upcoming/upcoming/create/modify/delete; host.reminders.list/search/create/update/delete to reminders.query/query/create/update/delete; host.contacts.search/read/create/update to contacts.search/search/save/save, using each app action's named arguments. calendar/reminders/contacts declarations include their app action dependencies; file reach includes reads, write reach mutations. reach: {capabilities,readPaths?,hosts?,apps?}; legacy permissions: capabilities list. Every effect passes Trust. "
                      + "host.apps.call({bundle_id,dictionary:true}) reads sdef; events take {bundle_id,event_class,event_id,parameters}. Declare app_read:<bundle_id> or app_write:<bundle_id> in reach.capabilities. Standard core getd/cnte/doex events are reads; modifying/unclassified events require write. Calls never prompt: request permission with target applescript:<bundle_id> for the owner's macOS grant. "
                      + "host.apps.call({bundle_id,script}) runs AppleScript in that app's tell context; always requires app_write:<bundle_id>. No scripting additions, resource imports, script objects or self references; every event targets that exact process. app_write grants the app's broad reach: Finder, for example, can open files/URLs in other apps. "
                      + "Event parameters use four-character keys and JSON descriptors: primitives, lists, {type}, {enum}, {record}, or {object:{want,form,seld,from}}. "
                      + "Omitted/null from targets the application: host.apps.call({bundle_id:\"com.apple.Keynote\",event_class:\"core\",event_id:\"getd\",parameters:{\"----\":{object:{want:\"prop\",form:\"prop\",seld:{type:\"pnam\"},from:null}}}}) reads its name. "
                      + "screen.watch({app,fps?,seconds?,region?}) watches that app's front window for the run; fps up to 30 (default 10), seconds up to 600 (default 60); declare screen.watch. "
                      + "screen.next(timeout?) skips older frames and returns the newest unseen {watch,seq,at,width,height,screen,read}; {timedOut:true} after timeout seconds without a new frame. Returns null when the watch ends: window gone, duration spent, Stop, screen control off, or person input with hands. Without hands, person input never ends it. "
                      + "f.read([...]) batches queries in frame pixels until the next frame: {at:[x,y]} → {r,g,b}; {mean:[x,y,w,h]} → {r,g,b,l}; {changed:[x,y,w,h]} → share changed since the prior frame; {text:[x,y,w,h]} → redacted on-device text. "
                      + "Declare hands for hand.click/double_click/right_click/move(x,y), hand.drag(x,y,toX,toY), hand.key(\"cmd+s\"), hand.hold(\"w\",seconds), hand.down(\"w\"), hand.up(\"w\"): frame-speed actions on that window in frame pixels, no model call; code is the reflex, args the intent. Keys held by down release on up, run end or person input. "
                      + "const eyes = screen.watch({app:\"Safari\",fps:10,seconds:60}); while (true) { const f = screen.next(); if (!f) break; const [c] = f.read([{at:[120,80]}]); if (c.r > 200 && c.g < 60) hand.click(120,80) } "
                      + "host.paths.home: absolute user home; resolve ~ in tool inputs. host.paths.workspace: your file folder; save there unless the person names another place. Files use app action arguments/results: host.files.write({path:\"workspace/note.txt\",content:\"hello\"}). "
                      + "actions lists only app actions reached dynamically through host.call; declarations grant no authority. params: input name → string/int/number/bool/list/object (optional with ?), {type,description?}, or a JSON Schema object. Revisions inherit code and unstated declarations (description,params,actions,reach,wake,face,resident,learned,choices) from the latest version; restating replaces, []/{} clears. ability.read {id} reads its code. Use edits:[{old,new}] instead of code: each old must occur exactly once; replacements apply in order and save as a revision. ability.validate intercepts calls: omit fixtures or use capture:true for one input run (default {}): "
                      + "reads run live and answers are sealed; effects, nested tools and decisions return visible placeholders. Later validation replays that capture, covering only supplied inputs/reached calls; intercepted replies prove no live behavior. "
                      + "Or supply {input,expected,calls?:[{operation,args,result}]} fixtures to intercept every host call, "
                      + "including app.<action> dependencies as operation app.<action>. reach.capabilities from app_data_read, app_data_write, network_localhost, "
                      + "network, network_public, computer_files, arbitrary_file_write, shell, model, calendar, reminders, contacts, screen.watch, hands, secret:<name>, app_read:<bundle_id> or app_write:<bundle_id>. "
                      + "Read-only code declares each primitive's reach; active abilities are callable from scripts under the same gates. Under Full Mac, your own save is kept and on immediately unless the owner turned it off; only the owner can lift that off. Active code runs as authored.<id>; "
                      + "below Full Mac or on a turn started by an untrusted agent, it remains unkept; ability.enable files the owner's card. wake defaults []; face {page?,action?,projection?} places the action and may name an unclaimed app action id. projection:true declares face(input) → {sections:[{id,title?,rows:[{id,title,detail?,value?}]}]} from frozen native sources, with no host effects/state. part.call(id,input) calls a declared authored.<id> → {ok:true,value} or {ok:false,error:{code,message}}; input: frozen JSON object, max 4 MiB. host.model.call may pass tools:[\"app\"] and a routing surface, limited by this ability's reach and caller. params {type:\"object\",properties,readOnly:true} declares a read contract; effects still pass Trust. resident defaults false; true retains JS across successful runs and holds opened programs/connections until code closes them, the ability is turned off or replaced, or the app quits. Nonresident held resources end with the run; detached program sessions may outlive it. wake [\"held\"] delivers input.wake {id,kind} for arriving data; read via receive/accept, wait 0 for only available data. wake [\"resumed\"] delivers input.wake at launch; code must reopen resources using saved state. Without it, no launch wake. wake [\"person.away\"]/[\"person.here\"] delivers input.wake {idle_seconds} once per presence change: away at 300 seconds idle, back on person input (never yours). learned.use reports exact-input/reached-call outcomes of ordinary gated runs of the selected version: execution, not proof of a larger task. Intercepted executions, previews and replays earn no competence. choices: reserved JSON. Source max: 524288 bytes. converts: optional original source SHA-256 digests from Tools census, binding conversion counterparts to this exact version.",
                  tool: "ability_manage", input: verb("save"), lifecycle: .change),
        AppAction("ability.read", "tools", "One ability of yours: what it declares, its status and versions, and its code in pages; a built-in skill's guidance reads too",
                  ["id", "offset?:int", "step?:int"], tool: "ability_manage", input: verb("read"), read: true),
        AppAction("ability.list", "tools", "Your abilities with runs and last_run_at; follow next_call when has_more", ["offset?:int"], tool: "ability_manage", input: verb("list"), read: true),
        AppAction("ability.validate", "tools", "Validate an unkept version on supplied input or one captured run; intercepted replies prove no live behavior",
                  ["id", "input?:object", "capture?:bool"], tool: "ability_manage", input: verb("validate"), read: true),
        AppAction("ability.enable", "tools", "Keep an unkept version and turn it on: your work under Full Mac unless the owner turned it off, else the owner's card. Code needs its full version digest; omit version only to restore Markdown guidance",
                  ["id", "version?"], tool: "ability_manage", input: verb("enable"), lifecycle: .enable),
        AppAction("ability.restore", "tools", "Turn an ability back on via ability.enable; code needs its full version digest; omit version only to restore Markdown guidance", ["id", "version?"],
                  tool: "ability_manage", input: verb("restore"), revision: 3, lifecycle: .restore),
        AppAction("ability.disable", "tools", "Turn an ability off, keeping its current and previous versions", ["id", "reason?"],
                  tool: "ability_manage", input: verb("disable"), revision: 2, lifecycle: .change),
        AppAction("ability.rollback", "tools", "Swap an ability's current and previous versions; optional version must name the previous version", ["id", "version?"],
                  tool: "ability_manage", input: verb("rollback"), revision: 2, lifecycle: .rollback),
        AppAction("ability.drop", "tools", "Delete an ability, its versions and its run state permanently; pending:true discards only its unkept version", ["id", "pending?:bool", "reason?"],
                  irreversible: true, capabilities: ["app_data_write", "safe_read", "tool_call"], tool: "ability_manage", input: verb("drop"), revision: 2, lifecycle: .drop),
        AppAction("ability.resume", "tools", "Resume a run stopped at a decision or card preview only if its journal contains no primitive call",
                  ["run_id", "id?", "answer?:any"], warn: "Optional id binds the run to its ability (bare id or authored.<id>); a mismatch claims nothing. The stopped step returns answer. Any journal call beginning with primitive blocks resume. Before starting a fresh run, inspect prior calls and effects: a fresh run executes from the beginning and may repeat effects; pass the answer as input and account for completed work.",
                  tool: "ability_manage", input: verb("resume"), part: ""),

        // The Desk.
        AppAction("desk.deny", "desk", "Deny", ["id", "reason?"], irreversible: true,capabilities: ["safe_read", "tool_call", "workshop_write"], tool: "workshop_reject"),
        AppAction("desk.approve", "desk", "Approve", ["id"], owner: .his("approving a waiting step is his; the Desk"),
                  tool: "workshop_reject", input: decision("approve")),

        // MY QUEUE: steps she means to do later, kept on her Desk until she marks each done or dropped. Version-exempt: done and drop close
        // the one step their id names, and a second close finds it no longer open and changes nothing. add: it appends, a new step, or a
        // newer step ref on the open step with the same words (MyQueue.add keeps the old ref, newest wins), and the same call again changes
        // nothing.
        AppAction("undo", "desk", "Undo this conversation's last layout, recipe or setting change",
                  tool: "undo", versionExempt: true),
        AppAction("queue.add", "desk", "Queue a step for later in MY QUEUE, in your own words", ["text", "when?", "action?"],
                 warn: "when is next_turn (the default), own_turn, when_user_messages with an optional door, "
                      + "after_card <approval id> or at <ISO time>; action is the call you mean to make then",
                  tool: "my_queue", input: verb("add"), versionExempt: true),
        AppAction("queue.done", "desk", "Mark a MY QUEUE step done", ["id", "reason?"],tool: "my_queue",
                  input: verb("done"), versionExempt: true),
        AppAction("queue.drop", "desk", "Drop a MY QUEUE step", ["id", "reason?"],tool: "my_queue",
                  input: verb("drop"), versionExempt: true),
        // a repair she owes settles when that operation works again, or here, with why.
        AppAction("repair.let_go", "desk", "Let go of something you owe (a repair on your home's OWED line, or a reply no door can carry), saying why", ["id", "reason"],
                  tool: "repair_let_go", versionExempt: true),
        AppAction("abilities.restore_state", "diagnostics", "Restore recovered ability run state, preserving damaged bytes and existing authority", ["state:object", "expected_digest"],
                  warn: "Read abilities/state.json with files.read and recover its accounting rows, including pending work. Do not invent run evidence. expected_digest is supplied by the unreadable-state refusal.",
                  tool: "abilities_restore_state", versionExempt: true, lifecycle: .change),
        AppAction("turn.reconcile", "chat", "Reconcile a saved turn without repeating completed effects", ["session_id", "turn_id?"], tool: "turn_reconcile", versionExempt: true),
        AppAction("home.accept", "desk", "Accept kept arrivals", ["id?"], tool: "arrival_accept", versionExempt: true),
        // A part's one way to her between turns (AGENT_IS_THE_APP contract #2): an arrival, never her context.
        AppAction("home.arrive", "desk", "From a part's run: one line on your home; event_key deduplicates this occurrence durably within this part, otherwise the same line is offered once per local day",
                  ["line", "event_key?"],tool: "resident_wake", versionExempt: true),
        AppAction("house.file", "desk", "File something to tend, with who owns it", ["title", "summary", "owner", "refs?:array"],
                 warn: "owner is me, builder or user; refs contains strings or Desk ref objects {kind,…}", tool: "house_file", versionExempt: true),

        // Folded tools. Reads: a script may call them, and no inbox is read around them.
        .fold("time_now", "*", "The date and time now: local, UTC, epoch, weekday and day of year", read: true),
        .fold("context_expand", "chat", "Read deeper context by its offered atom id or a history: id from a replayed receipt; offset defaults to 0, pages cap at 12000 characters, continue with next_offset until null",
              ["atom_id", "max_characters?:int", "offset?:int"], read: true),
        .fold("inner_state", "personality",
              "Your inner state, from your organs' record; asked how you feel, read this first, then speak",
              ["window_hours?:int", "detail?:compact|full"], read: true),
        .fold("agent_introspect", "diagnostics", "Your live runtime, provider and conversation identity",
              ["detail?:compact|full"], read: true),
        .fold("recent_trace_summary", "diagnostics", "Read saved traces; receipts span all conversations unless session_id is explicit, with non-read actions first and complete retained since windows",
              ["view?:receipts", "trace?", "effects_only?:bool", "since?", "limit?:int", "before?", "offset?:int", "completed_turns?:int", "kind?", "name?", "status?", "session_id?", "turn_id?", "receipt_id?", "fields?:[str]"], read: true),
        .fold("recent_trace_summary", "diagnostics", id: "trace.model_calls", "Model calls: per-turn counts by purpose and rounds per turn (p50, p90) for the last 24 hours and 7 days, the top five purposes by total milliseconds, and the week's five heaviest asks with their first six calls; reads retained traces without a model call",
              [], input: ["view": .string("model_calls")], read: true),
        .fold("recent_trace_summary", "diagnostics", id: "trace.usage", "Recorded model usage: exact retained call, input, cached input, output token and duration sums, grouped by model, surface or local day; since defaults to today (local midnight) or accepts an ISO-8601 timestamp; reports missing measurements and retention coverage",
              ["since?", "by?:model|surface|day"], input: ["view": .string("usage")], read: true),

        // Her own state: the Desk, its task ledger, Workshop and schedules; memory; helpers; persona and skills; studio and mind.
        .fold("desk_read", "desk", "Your Desk: paged items with status, summary, notes and refs; handle reads one item, query searches, limit/offset page, sort changes order only", read: true),
        .fold("desk_add_item", "desk"),
        .fold("desk_note", "desk"),
        .fold("desk_set_status", "desk"),
        .fold("desk_wait", "desk"),
        .fold("desk_update_item", "desk"),
        .fold("desk_add_ref", "desk"),
        .fold("desk_blocked_on", "desk"),
        .fold("desk_defer", "desk"),
        .fold("desk_breakdown", "desk"),
        .fold("desk_close", "desk"),
        .fold("desk_archive", "desk"),
        .fold("desk_work_log", "desk"),
        .fold("desk_set_cadence", "desk"),
        .fold("desk_set_notify", "desk"),
        .fold("desk_nag_control", "desk"),
        .fold("desk_open_pursuit", "desk"),
        .fold("task_ledger_list", "desk", "Shared task ledger: a separate list from your Desk", read: true),
        .fold("task_ledger_post", "desk", "Post to the shared task ledger (separate from your Desk)"),
        .fold("workshop_status", "desk", read: true),
        .fold("workshop_submit", "desk"),
        .fold("scheduler_list_jobs", "desk", read: true),
        .fold("scheduler_create_job", "desk", "Schedule a task, timer or alarm once or on a recurring daily or weekly cadence"),
        .fold("scheduler_update_job", "desk"),
        .fold("scheduler_pause_job", "desk"),
        .fold("scheduler_resume_job", "desk"),
        .fold("scheduler_cancel_job", "desk", "Cancel future runs; keep history and allow schedule.resume; running work continues"),
        .fold("scheduler_cancel_job", "desk", id: "schedule.delete"),
        .fold("recall_memory", "memories", "Recall saved facts, decisions and preferences; use studio.recall for journal entries", read: true, advisory: true),
        // Version-exempt: it appends a new memory; supersedes demotes the ids it names, which a repeat leaves demoted.
        .fold("commit_memory", "memories", versionExempt: true),
        .fold("memory_proposals_pending", "memories", read: true),
        .fold("memory_proposal_review", "memories"),
        .fold("forget_memory", "memories", irreversible: true),
        .fold("search_kg", "memories", read: true),
        .fold("rebuild_knowledge_graph", "memories"),
        .fold("scratchpad_read", "chat", read: true),
        .fold("bot_list", "bots", read: true),
        .fold("shelf_read", "bots", "Saved replies, newest first; sort:oldest_unread selects unread oldest first; page with offset or cursor", read: true),
        .fold("shelf_entry", "bots", "Read one helper reply; mark_read:false leaves it unread"),
        .fold("bot_ask", "bots"),
        .fold("bot_run_once", "bots", "Run a helper by id; its outcome and bot.reply reference return to the asking conversation"),
        .fold("bot_create", "bots"),
        .fold("bot_update", "bots"),
        .fold("bot_pause", "bots", "Pause or resume scheduled/event work by id; a manual helper has no schedule to pause"),
        .fold("bot_delete", "bots", "Delete a helper by id; keep its conversation, replies and owned run settlement"),
        .fold("get_persona_doc", "personality", read: true),
        .fold("persona_read", "personality", read: true, resultSchema: legacyResultSchema("persona.read")),
        .fold("persona_write", "personality"),
        .fold("persona_append_section", "personality"),
        .fold("studio_journal", "personality"),
        .fold("studio_journal_amend", "personality"),
        .fold("studio_recall", "personality", "Recall studio journal entries and creative work; use memory.recall for saved facts and agreements", read: true),
        .fold("studio_consult", "personality"),
        .fold("studio_consult_read", "personality", read: true),
        .fold("studio_shelf_read", "personality", read: true),
        .fold("studio_shelf_set", "personality"),
        .fold("studio_canon", "personality", read: true),
        .fold("studio_canon_resolve", "personality"),
        .fold("dream_diary_read", "personality", read: true),

        // The peer-data latch binds subsequent scripted calls as it does a turn.
        .fold("agent_contacts", "agents", read: true),
        // The send schema owns wait_seconds and the live/async receipt contract.
        .fold("agent_message", "agents"),
        .fold("claude_message", "agents", id: "claude.say"),
        .fold("agent_read", "agents", read: true),
        AppAction("claude.worklog", "agents", "Read what Claude has been doing and working on, newest first: her worklog of shipped features, fixes, builds and work in progress",
                  ["since?", "limit?:int"],
                  warn: "since: today or an ISO 8601 timestamp with timezone. limit: 1–50, default 10, newest first. Reads the bounded recent worklog tail; refs are clipped. Reading never sends a message.",
                  tool: "claude_worklog", read: true),
        .fold("agent_connect", "agents"),
        AppAction("agent.rename", "agents", "Rename an agent: call it by a new name or nickname when the person asks; its identity and handles stay the same",
                  ["agent", "name"], tool: "agent_connect", scope: "call it name it nickname rename an agent"),
        // How each agent is reached (agents/recipes/<host>.json), hers to read and fix when an app changes under it. A write is
        // connect-level: below Full Mac its card is connect's (other_app_settings_write).
        AppAction("agent.recipe", "agents", "Read a host's connection recipe and the version a write replaced; omit host for all hosts",
                  ["host?"],tool: "agent_contacts", read: true),
        AppAction("agent.recipe_write", "agents", "Create a recipe using agent.recipe's shape and a new host.id, or replace at the version read; keeps the prior version for undo",
                  ["host", "recipe:object"], reach: .his, capabilities: ["other_app_settings_write", "tool_call"], tool: "agent_connect"),
        // The "no" to an agent discovery found here; only discovery.json changes.
        AppAction("agent.discovery_dismiss", "agents", "Decline an agent found on this Mac; it is not offered or connected automatically again",
                  ["name"],tool: "agent_discovery_dismiss"),
        // A failed send runs the same check itself and retries once.
        AppAction("agent.verify", "agents", "Dry-run a host recipe or contact settings, handshake or window controls; sends nothing. A pass proves only the named checks; a reply needs separate proof",
                  ["agent", "workspace?"], tool: "agent_message"),
        .fold("agent_cancel", "agents", "Stop the reply an agent is working on in your conversation with it"),
        // The answer of a contact reached through one of her abilities, from that ability's code.
        AppAction("agent.reply", "agents", "From a contact's connecting ability, answer as that contact in its conversation; done:false marks progress",
                  ["text", "done?:bool", "agent?", "exchange?"], tool: "agent_message"),
        .fold("delegation_status", "agents", read: true),
        .fold("agent_swarm", "agents", "Run temporary workers on an objective; reasoning_effort sets Think for the run or each worker, defaulting to Work thinking (providers.work_thinking)"),
        .fold("codex_message", "agents"),
        .fold("invoke_codex", "agents"),
        .fold("omp_message", "agents"),

        // Each Mac app and connector is a page.
        .fold("mail_list_recent", "mail", "Read Apple Mail drafts to a person/address with mailbox:\"drafts\"; also inbox or sent. Read one body with scope + message_id "
              + "+ expected_message_id + expected_account_id", read: true),
        .fold("mail_read_batch", "mail", read: true),
        .fold("mail_search", "mail", read: true),
        .fold("mail_save_attachment", "mail"),
        .fold("mail_senders", "mail", "Read top and most frequent email senders and unread counts to identify unsubscribe candidates", read: true),
        .fold("mail_triage_batch", "mail"),
        .fold("mail_mark_read", "mail"),
        .fold("mail_archive", "mail"),
        .fold("mail_delete", "mail", irreversible: true),
        .fold("mail_send", "mail", irreversible: true),
        .fold("mail_reply", "mail", irreversible: true),
        .fold("mail_draft", "mail", "Compose an email draft or draft a reply without sending it"),
        .fold("mac_calendar_list_upcoming", "calendar", read: true),
        .fold("mac_calendar_calendars", "calendar", read: true),
        .fold("mac_calendar_free_busy", "calendar", read: true),
        .fold("mac_calendar_create_event", "calendar"),
        .fold("mac_calendar_modify_event", "calendar"),
        .fold("mac_calendar_delete_event", "calendar", irreversible: true),
        .fold("mac_reminders_list_due_today", "reminders", "Reminders due today and overdue as separate parts, each counted and capped independently", read: true),
        .fold("mac_reminders_query", "reminders", read: true),
        .fold("mac_reminders_lists", "reminders", "Every reminder list with its open count", read: true),
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
        .fold("messages_recent_threads", "messages", "List Messages threads with selected fields, latest-unread filtering and a since window; or read sent, received and exact conversation history", read: true),
        .fold("messages_send", "messages", irreversible: true),
        .fold("mac_notify", "notifications"),
        .fold("mobile_notify", "notifications"),
        .fold("phone_request", "pairing"),
        // Reading where the paired iPhone is changes nothing: a read of its own, so a part that only looks (weather) stays a read. Its wait
        // is a phone that is open: a push, the person's tap, a fix and the Mac's 8-second drain while the request is out; not a minute for
        // one that is not.
        .fold("phone_request", "pairing", id: "phone.location", "Ask the paired iPhone for its current location", [],
              input: ["kind": .string("location.current"), "wait_seconds": .int(20)], read: true),
        .fold("image_generate", "chat"),

        .fold("read_file", "files", "Read a workspace/approved file or image pixels; query searches the whole text. Continue with returned next arguments, including version", read: true),
        .fold("list_dir", "files", "List names/dates in an approved folder. sort:newest orders by added then modified date; sort:added by date added, including app bundles; sort:size reads allocated disk usage within a time budget and names partial results", read: true),
        .fold("file_info", "files", "Read name, directory/regular flags, size and modified date without following the final symbolic link", read: true),
        .fold("file_excerpt", "files", read: true),
        .fold("grep", "files", read: true),
        .fold("mac_spotlight_search", "files", read: true),
        .fold("write_file", "files"),
        .fold("move_file", "files"),
        .fold("copy_file", "files"),
        .fold("trash_file", "files"),
        .fold("apply_patch", "files", "Apply a unified diff with paths relative to cwd",
              warn: #"Example app {action:"files.patch",args:{cwd:"/absolute/path/to/repo",patch:"--- a/note.txt\n+++ b/note.txt\n@@ -1 +1 @@\n-old\n\\ No newline at end of file\n+new\n\\ No newline at end of file\n"}}; supply actual content/ranges; the marker is only for missing final newlines"#),
        .fold("git_status", "shell", "Read parsed branch and changes; omitted path uses the app's verified source checkout, or workspace when none exists; returns cwd", read: true),
        .fold("git_diff", "shell", "Read changes; omitted cwd uses the app's verified source checkout, or workspace when none exists; returns cwd", read: true),
        .fold("git_log", "shell", "Read commits and changed files; omitted path uses the app's verified source checkout, or workspace when none exists; returns cwd", read: true),
        .fold("repo_dirty_summary", "shell", "Read branch, changes and recent commits; omitted cwd uses the app's verified source checkout, or workspace when none exists; returns cwd", read: true),
        .fold("shell", "shell", "Run a command with sh; cwd defaults to your workspace, relative cwd starts there; select the source checkout with explicit cwd",
              warn: "Requires Full Mac file access. Only a literal command certified by the shell owner reads (including pwd, df and simple git log/status/diff/show); shell syntax and all other commands remain writes. Certified reads run under read-only confinement. Invalid cwd or another pre-launch refusal returns execution:not_run, effect:none."),
        .fold("bash", "shell", "Run a command with bash; cwd defaults to your workspace, relative cwd starts there; select the source checkout with explicit cwd",
              warn: "Requires Full Mac file access. The same read certification and confinement as shell.run applies; all other commands remain writes. Pre-launch refusals return execution:not_run, effect:none."),
        .fold("git", "shell", "Run Git with explicit args; omitted cwd uses the app's verified source checkout, or workspace when none exists; returns cwd"),
        .fold("swift_build", "shell"),
        .fold("swift_test", "shell"),
        .fold("remote_node_list", "shell", read: true),
        .fold("remote_node_execute", "shell"),
        .fold("restart_app", "shell"),
        .fold("install_app", "shell"),
        .fold("read_page", "web", read: true,
              warn: "find reads matching paragraphs with surroundings; without find the whole extracted text is read. raw:true bypasses the sense view; wrong:true reads the original view and offers repair guidance after success (why is an optional explanation). Every successful fetch retains a source receipt with its path and purpose."),
        .fold("web_search", "web", read: true),
        .fold("maps_route", "web", "Read a route, distance and driving time between places", read: true,
              warn: "traffic: not_included; time assumes ideal conditions. Every step is returned; step distance covers its path segment, not just its turn/exit."),
        .fold("maps_search", "web", "Find nearby places and addresses in Maps", read: true,
              warn: "near is optional when query includes near/in/around plus a place, for example coffee near Tampa airport; the result says what was split."),
        .fold("browser.status", "browser", read: true),
        .fold("browser.open_url", "browser"),
        .fold("browser.read_text", "browser", read: true),
        .fold("browser.read_links", "browser", read: true),
        .fold("browser.screenshot", "browser"),
        .fold("browser.chrome_setup", "browser"),
        .fold("browser.chrome_status", "browser", read: true),
        .fold("browser.chrome_snapshot", "browser", read: true),
    ] + ToolNameAliases.chromeVerbs.filter { $0 != "snapshot" }.map { .fold("browser.chrome_" + $0, "browser", read: $0 == "wait" || $0 == "look") } + [
        .fold("search_chat_history", "chat", read: true),
        .fold("read_chat_message", "chat", read: true),
        .fold("chat_reply", "chat"),
        .fold("tool_result_page", "*", "Page a long result retained this turn without rerunning its action; continue:true resumes the last read and ignores page; omit continue to select page/query/raw", read: true),

        // Mac control and folded tools. Each Mac verb re-enters under its own name, so Full Mac's accessibility category, MacAttention and
        // User's saved levels judge it as before. act's whole guide is an item read on the mac page (`guided`); its refusals point to it.
        .fold("screen", "mac", "Read the live screen as words; lists running apps when NativeAgent is frontmost. "
              + "app reads a running app's window without activation; part zooms in; "
              + "pixels:true is a picture of the desktop", read: true),
        .fold("act", "mac", "Act by name with verb + target (click, type with text, key, select, scroll…), or one flow "
              + "with steps:[…]: names, menu paths ('Format > Make Plain Text'), chords or {verb,target,text,mode}. "
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
        .fold("system_info", "mac", "Read system, network, battery and named Data/System volume capacity; disk is Data, system_disk is the sealed System volume", read: true),
        AppAction("mac.apps", "mac", "List installed apps or check one by name; returns name, bundle ID, path, version and scriptability", ["name?", "all?:bool"],
                 tool: "mac_apps", read: true, scope: "installed apps applications what apps do I have; name: optional substring filter"),
        .fold("mac_screenshot_save", "mac"),
        .fold("mac_location", "mac", "Where this Mac is", read: true),
        .fold("mac_volume", "mac", "Read or change volume; no args reads only", readWhen: ["level": .null, "adjust": .null, "muted": .null]),
        .fold("mac_media", "mac", "Control Now Playing across Music, Spotify, browsers and podcasts: play/pause toggle, next or previous", screen: true),
        .fold("activity_query", "mac", read: true),
        .fold("music_now_playing", "music", "Playing, paused or stopped, with first-observed time and current track", read: true),
        .fold("music_search_library", "music", "Search library tracks with count, total and has_more", read: true),
        .fold("music_list_library", "music", "Page library tracks; sort title/artist/added and filter artist/album/genre", read: true),
        .fold("music_list_playlists", "music", "Page playlists labeled owner, smart or library with count and total", read: true),
        .fold("music_control", "music", "Play, pause, stop or skip; play takes seconds (1–30) and stops itself", screen: true),
        .fold("context_lookup", "capabilities", read: true),
        .fold("request_interaction", "chat"),
        .fold("artifact_find", "chat", read: true),
        .fold("work_context", "desk", read: true),
    ]

    /// act's arguments as its schema has them, but verb and target may be left out (a flow's steps carry their own). The recursive
    /// credential detector judges typed text, including text/value inside flow steps.
    static let actArgs = foldSchemas["act"].map {
        ToolSignature.doorArgs($0.parametersJSON).map {
            ["verb", "target"].contains($0) ? $0 + "?" : $0
        }
    }

    static let layoutScope = SurfaceLayout.vocabulary.map { surface, about, blocks in
        ([surface, about] + blocks.map { $0.name + " " + $0.shows }).joined(separator: " ")
    }.joined(separator: " ") + " " + SurfaceLayout.profilesAbout

    /// Named in `app`'s own description, so a cold call needs no read first. Static: it changes only at a release.
    public static let hot = ["undo", "time.now", "context.expand", "mind.inner_state", "agent.introspect", "ability.list",
                             "ability.read", "trace.recent", "desk.read", "memory.recall", "memory.commit",
                             "bot.reply", "agent.contacts", "agent.message", "agent.read", "agent.connect",
                             "agent.jobs", "mail.recent",
                             "calendar.upcoming", "files.read", "files.list", "files.write", "chat.search",
                             "result.page", "mac.look", "mac.system_info", "mac.volume", "mac.act", "mac.go", "sense.make"].compactMap { action($0) }
}
