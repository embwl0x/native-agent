import AgentWorkspace
import MacIntegration
import NativeAgentCore
import NativeAgentShared
import PersistenceCore
import ToolRegistry
import ToolExecution
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
import Desk
import MemoryV2
import StandingBots
import TurnTrace
import Studio
import TriggerScheduler
// Blueprint: | `AppActions+Declarations.swift` | Seed actions, owner schemas, fixed input and hot-action vocabulary |

extension AppActions {
    private static let abilitySaveSchema = LLMToolSchema(name: "ability_manage", toolClass: .write,
        description: """
            Save a new ability or revise one. Only id is always required; a new ability also needs description and code. Revisions inherit omitted fields. \
            Code is function run(input) or async function run(input), returning plain JSON; call the app as app.<page>.<action>(args) or app({action, args}) \
            / app({actions:[…]}) (app and host calls answer at once and may be awaited).
            """,
        parametersJSON: try! Parts.saveArgumentsSchema.serializedData(pretty: false))

    /// Every door argument's shape, complex ones from their owners; the declaration owns which are required. Discovery reads only this schema, so an argument
    /// missing here is unusable.
    private static func arguments(_ tool: String, _ properties: [String: JSONValue], required: [String] = [], read: Bool = false) -> LLMToolSchema {
        LLMToolSchema(name: tool, toolClass: read ? .read : .write, description: "",
            parametersJSON: try! JSONValue.object(["type": .string("object"), "properties": .object(properties),
                "required": .array(required.map(JSONValue.string))]).serializedData(pretty: false))
    }

    private static let queueAddSchema = arguments("my_queue", ["text": ToolSchema.strSchema(),
        "when": SchedulerJobNormalizer.intentionWhenSchema, "until": .object([:]),
        "say": ToolSchema.strSchema(), "action": .object([:])], required: ["text"])
    private static let queueUpdateSchema = arguments("my_queue", ["id": ToolSchema.strSchema(),
        "action": .object([:]), "say": .object([:]), "when": SchedulerJobNormalizer.intentionWhenSchema,
        "until": .object([:])], required: ["id"])

    /// AgentJobs.commission owns these shapes and refuses anything else.
    private static let agentJobSchema = arguments("agent_job", [
        "agent": ToolSchema.strSchema("""
            Who takes the job: a contact's name or peer:<id> from agent.contacts, or self for a line of your own: a turn of yours in its own work \
            conversation, with your tools, Trust and present.
            """),
        "instructions": ToolSchema.strSchema("""
            For agent self only: who this line is (a researcher, a critic, a specialist), in your words; they stand in place of your persona. Omit and \
            the line is you.
            """),
        "brief": ToolSchema.strSchema("The job in your words: what to make or change, and what done looks like."),
        "where": ToolSchema.strSchema("""
            Another agent only: the one folder it works in, or a git repository's folder; omit for work that needs no place. Never your own data \
            folder. Your own line works with your own hands.
            """),
        "reach": .object(["type": .string("object"), "additionalProperties": .bool(false), "description": .string("""
            Another agent only: what it may touch, always within your Trust posture: writes (default true with where) lands only in where; network \
            (default false) needs Full Mac. Your own line has your Trust.
            """), "properties": .object(["writes": ToolSchema.boolSchema(), "network": ToolSchema.boolSchema()])]),
        "done": .object(["type": .string("object"), "additionalProperties": .bool(false), "description": .string("""
            Your check of the result, one of {command} (another agent only: a shell command run in where under reach; exit 0 passes), {file} (that \
            path exists) or {grep, in} (the regex matches in that file). Without it the job ends delivered, unchecked, never done.
            """), "properties": .object(["command": ToolSchema.strSchema(), "file": ToolSchema.strSchema(), "grep": ToolSchema.strSchema(),
                "in": ToolSchema.strSchema()])]),
        "desk": ToolSchema.strSchema("The Desk item this job carries, as desk.read names it."),
    ], required: ["agent", "brief"])

    private static func composer(_ verb: String) -> [String: JSONValue] {
        ["target": .string("composer"), "verb": .string(verb)]
    }
    static func verb(_ verb: String) -> [String: JSONValue] { ["verb": .string(verb)] }
    static func press(_ button: String) -> [String: JSONValue] {
        ["verb": .string("act"), "action": .string(button)]
    }
    static func card(_ action: String) -> [String: JSONValue] { ["action": .string(action)] }

    package static var seedActions: [AppAction] { get throws { try seedInventory.get() } }
    private static let seedInventory: Result<[AppAction], Error> = Result {
        let actions: [AppAction] = try [
        AppAction("find", "*", "Discover actions, pages and skills by intent", ["what|query"],
                  warn: "The same discovery as app {find:\"words\"}. Pass what or query inside args.",
                  tool: "app_find", read: true),
        AppAction("photos.count", "files", "Count how many photos, pictures or recorded videos are in Photos by creation date and media type",
                  ["start?", "end?", "media_type?"],
                  warn: """
                      start/end: ISO 8601 with timezone, start inclusive/end exclusive. media_type: all (default), image or video. Missing macOS Photos \
                      access raises a permission card; only the person taps Allow. Limited access counts only shared assets.
                      """,
                  tool: "photos_read", input: verb("count"), read: true),
        AppAction("photos.recent", "files", """
            Read recent photos, pictures and recorded videos in Photos: creation date, media type, dimensions, favorite and stored location coordinates
            """,
                  ["limit?:int", "start?", "end?", "media_type?"],
                  warn: """
                      limit: 1–100, default 10, newest creation first. start/end: ISO 8601 with timezone, start inclusive/end exclusive. media_type: all \
                      (default), image or video. Metadata only; missing macOS Photos access raises a permission card for the person's Allow tap.
                      """,
                  tool: "photos_read", input: verb("recent"), read: true),
        // Inbox action ids must match the button ids published by each note read.
        AppAction("inbox.archive", "inbox", "Archive", ["ids|id", "reason"], tool: "inbox", input: verb("archive")),
        AppAction("inbox.acknowledge", "inbox", "Archive", ["ids|id", "reason"], tool: "inbox", input: verb("archive")),
        AppAction("inbox.dismiss", "inbox", "Dismiss", ["ids|id", "reason"], tool: "inbox", input: verb("dismiss")),
        AppAction("inbox.mark_read", "inbox", "Mark read (opening a note does this)", ["ids|id", "reason"],
                  tool: "inbox", input: verb("mark_read")),
        AppAction("inbox.repair", "inbox", "Repair", ["id"], subject: ["id"], tool: "inbox", input: verb("repair")),
        AppAction("inbox.act", "inbox", "Act", ["id", "action?"], subject: ["id"], irreversible: true, capabilities: ["app_data_write", "safe_read",
            "tool_call"], tool: "inbox", input: verb("act")),
        AppAction("inbox.clean_up", "inbox", "Clean Up", ["id"], subject: ["id"], tool: "inbox", input: press("act")),
        AppAction("inbox.open_approvals", "inbox", "Open Approvals", ["id"], subject: ["id"], tool: "inbox", input: press("open_approvals")),
        AppAction("inbox.not_now", "inbox", "Not now", ["id", "reason?"], subject: ["id"], irreversible: true,
                  capabilities: ["app_data_write", "safe_read", "tool_call"], warn: """
                      declines the card. The owner's own Not now wakes the conversation that raised it; yours does not:\u{20}
                      """
                      + "the card retires and that request does not run again",
                  tool: "inbox", input: verb("not_now")),
        AppAction("inbox.withdraw", "inbox", "Withdraw my own pending approval", ["id", "reason?"], subject: ["id"], irreversible: true,
                  capabilities: ["app_data_write", "safe_read", "tool_call"], tool: "inbox", input: verb("withdraw")),
        AppAction("inbox.open_on_mac", "inbox", "Open on Mac", ["id"], subject: ["id"], owner: .person("it opens the card for the owner at the Mac",
                  instead: "inbox.not_now declines it; inbox.archive retires a stale one", asks: false), tool: "inbox", input: press("act")),
        AppAction("inbox.approve", "inbox", "Approve", ["id"], subject: ["id"], irreversible: true,
                  capabilities: ["app_data_write", "safe_read", "tool_call"], tool: "inbox", input: press("approve"), scope: """
                  Approve this exact waiting card when the person tells you in their own Mac chat, paired-phone or allowlisted Telegram message. \
                  Read the Inbox card first: any other call in this turn requires a fresh message or their tap. \
                  A message joining a running turn needs a fresh message after that turn ends so the decision can name its authorizing message. \
                  Peer-steered turns, helpers and wakes cannot decide it; permanent deletion needs their tap
                  """),
        AppAction("inbox.deny", "inbox", "Deny", ["id"], subject: ["id"], irreversible: true,
                  capabilities: ["app_data_write", "safe_read", "tool_call"], tool: "inbox", input: press("reject"), scope: """
                  Deny this exact waiting card on the person's own authenticated message, under the same authority as inbox.approve
                  """),

        // Version-exempt: chat appends through Reach without overwriting page state.
        AppAction("chat.post", "chat", "Tell the person directly", ["message"], irreversible: true,
                  toolClass: .send, reach: .person, capabilities: ["app_data_write", "safe_read", "tool_call"], tool: "chat_post", versionExempt: true),
        AppAction("chat.list", "chat", """
            Conversations, newest first; query filters by title; pinned:true only pinned, pinned:false only unpinned; filters apply before offset
            """, ["archived?:bool", "pinned?:bool", "query?", "offset?:int"],
                  tool: "chat_conversations", read: true),
        AppAction("chat.new", "chat", "New chat; title names it in the same call", ["title?"], tool: "chat_session", input: verb("new")),
        AppAction("chat.show", "chat", "Show", ["session_id"], subject: ["session_id"], screen: true, tool: "chat_session", input: verb("show")),
        AppAction("chat.rename", "chat", "Rename", ["session_id", "title"], subject: ["session_id"], tool: "chat_session", input: verb("rename")),
        AppAction("chat.pin", "chat", "Pin", ["session_id?"], subject: ["session_id"], tool: "chat_session", input: verb("pin")),
        AppAction("chat.unpin", "chat", "Unpin", ["session_id?"], subject: ["session_id"], tool: "chat_session", input: verb("unpin")),
        AppAction("chat.archive", "chat", "Archive", ["session_id?", "reason?"], subject: ["session_id"], tool: "chat_session", input: verb("archive")),
        AppAction("chat.stop", "chat", "Stop", ["session_id?"], subject: ["session_id"], tool: "chat_session", input: verb("stop")),
        AppAction("chat.regenerate", "chat", "Regenerate (redo / try again) your last answer", ["session_id?"], subject: ["session_id"], irreversible: true,
                  capabilities: ["app_data_write", "safe_read", "tool_call"], tool: "chat_session", input: verb("regenerate")),
        AppAction("chat.export", "chat", "Export to Markdown", ["session_id?"], subject: ["session_id"], tool: "chat_session", input: verb("export")),
        AppAction("chat.detach", "chat", "Open in its own window", ["session_id?"], subject: ["session_id"], screen: true,
                  tool: "chat_session", input: verb("detach")),
        AppAction("chat.close_window", "chat", "Close its window", ["session_id?"], subject: ["session_id"], screen: true,
                  tool: "chat_session", input: verb("close_window")),
        AppAction("chat.clear", "chat", "/clear", ["session_id"], subject: ["session_id"], irreversible: true,
                  capabilities: ["app_data_write", "safe_read", "tool_call"], tool: "chat_session", input: verb("clear")),
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
        AppAction("chat.working_memory", "chat", """
            Hold a private choice or plan in this conversation (up to 1200 characters); shown privately to you each turn until replaced or cleared
            """, ["text:secret"], warn: "Empty text clears it. Its words stay out of scratch reads, receipts and the person's surfaces.",
                  tool: "chat_working_memory", versionExempt: true),
        AppAction("page.show", "*", "Go to page", ["page", "item?"], subject: ["page"], screen: true, tool: "interaction_act",
                  input: composer("set_page"), rename: ["page": "value", "item": "choice"]),
        AppAction("browser.show", "chat", "Show your own built-in browser (NativeAgent's browser, not Chrome)", screen: true, tool: "interaction_act",
                  input: composer("show_browser")),
        AppAction("pane.show", "chat", "Open the Work pane beside chat", ["view:steps|screen|make", "ref?"], screen: true,
                  tool: "interaction_act", input: composer("show_pane"), rename: ["view": "value", "ref": "choice"]),
        AppAction("pane.hide", "chat", "Close the Work pane", screen: true, tool: "interaction_act",
                  input: composer("hide_pane")),
        // Version-exempt: adding a version never overwrites an existing one.
        AppAction("make.add", "make", "Add a file to Make as a new version of ref (a new ref when left out); returns the ref",
                  ["path", "ref?", "prompt?", "model?"], tool: "make_studio", input: verb("add"), versionExempt: true),
        AppAction("make.read", "make", "A Make ref's versions: n, path, prompt, created (newest ref when left out). Read page:make for the paged shelf.",
                  ["ref?"],tool: "make_studio", input: verb("read"), read: true),
        AppAction("studio.intake.read", "personality", """
            Read neutral consult or corrected complete-history facts for unanswered-work intake; carry snapshot through every page
            """,
                  ["kind:history|consults", "offset?:number", "snapshot?"], capabilities: ["app_data_read"], tool: "studio_intake_read", read: true),
        // The reply face carries attachments to every delivery door.
        AppAction("reply.attach", "chat", """
            Attach an image to the reply you are writing now; it goes with your answer wherever this conversation is answered (the Mac chat, Telegram)
            """,
                  ["path"], warn: """
                      One image per call, by its own path: jpg, png, gif, webp, bmp or heic, inside your Trust workspace unless this Mac is in Full Mac.
                      """,
                  tool: "read_file", read: true),
        AppAction("sense.make", "chat", """
            Learn to read a Mac app, live Chrome site, or foreign file format (including binary) from captured material. Plain text uses files.read; a web \
            page is read with read_page (app web.read), not sense.make. Folder watches are not sense.make corners: to act when a file or folder changes, save \
            an ability whose header wakes on file.changed:<path> (ability.save). Read with mac.look, chrome.snapshot or files.read first. code: complete \
            sense.js; kit: Contents/Resources/Senses (AUTHORING.md, sense.js, builtin/app.js, builtin/site.js). Runs on the last-read place or explicit \
            place; returns page, trial_id/digest and timing. Keep the exact trial with {trial_id,digest,keep:true}, no code. {code,keep:true} runs and keeps \
            immediately. {show:\"material\"} returns captured material
            """,
                  ["code?", "trial_id?", "digest?", "keep?:bool", "place?", "why?", "show?", "apps?:list", "reach?:object", "wake?:list", "face?:object",
                      "resident?:bool", "learned?:any", "choices?:any"],
                  capabilities: ["app_data_write", "safe_read", "tool_call"], warn: """
                      apps declares bundle ids for sense.apps.read({bundle_id,dictionary:true}) or read-only Apple Events using event_class, event_id and \
                      parameters. Standard core getd/cnte/doex events are reads; other events require a tool's write declaration.
                      """, tool: "sense_make",
                  readWhen: ["show": .string("material"), "trial_id": .null, "digest": .null], lifecycle: .change,
                  schema: arguments("sense_make", AbilityStore.partArgumentSchemas.merging(["code": ToolSchema.strSchema(), "trial_id": ToolSchema.strSchema(),
                      "digest": ToolSchema.strSchema(),
                      "apps": .object(["type": .string("array"), "items": .object(["type": .string("string")])]),
                    "keep": .object(["type": .string("boolean")]), "place": ToolSchema.strSchema(), "why": ToolSchema.strSchema(), "show": ToolSchema.strSchema(
                        )]) { owned, _ in owned })),
        AppAction("sense.versions", "senses", "Read a sense's current and retained versions", ["sense_id"], subject: ["sense_id"],tool: "sense_lifecycle",
            input: ["verb": .string("versions")], read: true),
        AppAction("sense.quarantine", "chat", "Turn a sense off while retaining its current and previous versions", ["sense_id", "version:int"],
            subject: ["sense_id"], tool: "sense_lifecycle", input: ["verb": .string("quarantine")], revision: 2, lifecycle: .change),
        AppAction("sense.restore", "chat", "Turn the selected sense version back on", ["sense_id"], subject: ["sense_id"], tool: "sense_lifecycle",
            input: ["verb": .string("restore")], revision: 2, lifecycle: .restore),
        AppAction("sense.drop", "chat", "Delete a sense and its run statistics permanently", ["sense_id"], subject: ["sense_id"], irreversible: true,
            capabilities: ["app_data_write", "safe_read", "tool_call"], tool: "sense_lifecycle", input: ["verb": .string("drop")], revision: 2,
            lifecycle: .drop),
        AppAction("persona.set", "personality", "Switch persona", ["name"], screen: true, tool: "interaction_act",
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
                  ["layout:object", "layout_version"], tool: "app_setting_set", scope: layoutScope,
                  schema: arguments("app_setting_set", ["layout": SurfaceLayoutStore.writeArgumentSchema, "layout_version": ToolSchema.strSchema()])),
        // Owner-only rows stay with the user; lower-only rows may only move in the safe direction.
        AppAction("setting.get", "*", """
            Read a setting's current value, kind and accepted choices (app {page} lists ids). phone.settings reads the paired phone's own settings directory \
            while its app is open.
            """, ["setting"], subject: ["setting"],
                 tool: "app_setting_get", read: true, scope: "setting value read get home timezone phone preferences appearance shortcut memory"),
        AppAction("setting.set", "*", "Set", ["setting", "value:any", "because?"], subject: ["setting"],
                  warn: """
                      Your own mind settings need no request. For other settings below Full Mac, because must quote at least 3 words from a person \
                      or trusted agent in this conversation (a run with no conversation has none to quote); you may restore a switch whose last \
                      change was yours. An owner_only setting is the person's alone.
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
                  + "(knowledge, dreams…), the page's default tab when left out", ["page", "tab?", "height?:int"],
                  warn: "saves a PNG and prunes old page captures", tool: "app_page_screenshot", versionExempt: true),
        // Phone, Telegram and below-Full-Mac authority cards remain user-owned; answering runs an irreversible control.
        AppAction("permissions.request", "chat", "Ask for a macOS permission in your own words", ["capability", "why", "mode?", "also_needed?:list"],
            subject: ["capability", "mode"],
                  capabilities: ["safe_read", "tool_call"], warn: """
                      capability: privacy:<grant>, grant one of \(SystemPermissionCapability.requestable); Automation for one app: \
                      applescript:<bundle_id>. also_needed: the other grants this same card asks for, in the same forms, so everything still off \
                      is one card. Only the person taps Allow on the Mac; the waiting work continues after the grant.
                      """,
                  tool: "request_interaction", input: ["kind": .string("permission")], rename: ["capability": "target"], folded: true),
        AppAction("card.answer", "chat", "The card's own button (its Do: line)", ["id", "value?:secret", "choice?"], subject: ["id"],
                  irreversible: true, capabilities: ["app_data_write", "safe_read", "tool_call"],
                      warn: "never ask the owner for a key or token in chat: they type it into the card",
                  tool: "interaction_act", input: card("primary"), rename: ["id": "interaction_id"]),
        AppAction("card.not_now", "chat", "Not now", ["id", "reason?"], subject: ["id"], irreversible: true, capabilities: ["app_data_write", "safe_read",
            "tool_call"], tool: "interaction_act",
                  input: card("decline"), rename: ["id": "interaction_id"]),
        // Irreversible: it runs the card's own control as card.answer does, a capability grant included.
        AppAction("card.try_again", "chat", "Try again", ["id", "value?:secret", "choice?"], subject: ["id"], irreversible: true,
                  capabilities: ["app_data_write", "safe_read", "tool_call"], tool: "interaction_act",
                  input: card("retry"), rename: ["id": "interaction_id"]),

        AppAction("provider.test", "providers", "Test the connection", ["provider"], subject: ["provider"],tool: "provider",
                  input: verb("test"), read: true),
        AppAction("provider.refresh", "providers", "Refresh", tool: "provider", input: verb("refresh_models")),
        AppAction("provider.cancel_refresh", "providers", "Cancel the model catalog refresh", tool: "provider", input: verb("cancel_refresh")),
        AppAction("provider.set_fallback_model", "providers", "Model it falls back to", ["provider", "model"], subject: ["provider"],
                  tool: "provider", input: verb("set_default_model")),
        // Opening the protected entry is an ask, not the credential: only the person types the key or signs in there.
        AppAction("provider.sign_in", "providers", "Sign in", ["provider"], subject: ["provider"],
                  tool: "connections", input: verb("provider_sign_in")),
        AppAction("provider.disconnect", "providers", "Disconnect", ["provider"], subject: ["provider"],
                  owner: .person("only the person can sign back in, and disconnects on Providers"), irreversible: true,
                  capabilities: ["app_data_write", "safe_read", "tool_call"], tool: "provider", input: verb("disconnect")),

        // Connector and pairing controls may lower access, never raise it. A switch's change names the position it moves to (value).
        AppAction("connector.off", "connectors", "Turn off", ["id", "reason?", "value?:bool"], subject: ["id"], tool: "connections",
                  input: verb("connector_off")),
        AppAction("connector.on", "connectors", "Turn on", ["id", "value?:bool"], subject: ["id"],
                  owner: .person("it raises Trust; the person turns it on in Connectors"), tool: "connections", input: verb("connector_on")),
        AppAction("connector.disconnect", "connectors", "Disconnect", ["id"], subject: ["id"],
                  owner: .person("only the person can sign back in, and disconnects in Connectors", instead: "connector.off stops one"),
                  irreversible: true, capabilities: ["app_data_write", "safe_read", "tool_call"], tool: "connections", input: verb("connector_disconnect")),
        AppAction("telegram.repair", "telegram", "Rebuild admission index", ["inbox"], tool: "connections",
                  input: verb("telegram_repair")),
        // Irreversible: this sends a real Telegram message to the user.
        AppAction("telegram.test", "telegram", "Send test reply", irreversible: true, toolClass: .send, capabilities: ["app_data_write", "safe_read",
            "tool_call"], tool: "connections",
                  input: verb("telegram_test")),
        AppAction("telegram.clear_logs", "telegram", "Clear logs", irreversible: true, capabilities: ["app_data_write", "safe_read", "tool_call"],
            tool: "connections",
                  input: verb("telegram_clear_logs")),
        AppAction("telegram.disconnect", "telegram", "Remove the token",
                  owner: .person("only the person can sign back in; Connectors → Telegram",
                             instead: "setting.set with setting telegram.enabled, value false stops it"),
                  irreversible: true, capabilities: ["app_data_write", "safe_read", "tool_call"], tool: "connections", input: verb("telegram_disconnect")),
        AppAction("pairing.remove", "pairing", "Remove the phone", ["id"], subject: ["id"],
                  owner: .person("only the person can pair it again; Connectors → iPhone"), irreversible: true,
                  capabilities: ["app_data_write", "safe_read", "tool_call"], tool: "connections", input: verb("pairing_remove")),

        AppAction("doctor.run", "diagnostics", "Run Doctor checks",tool: "doctor_status", input: ["repair": .bool(false)], read: true),
        AppAction("doctor.repair", "diagnostics", "Repair", ["check_id?"], subject: ["check_id"], tool: "doctor_status", input: ["repair": .bool(true)]),
        AppAction("doctor.support_report", "diagnostics", "Support report: the app's diagnostic bundle to send to the developer", tool: "upkeep", input: verb(
            "support_report")),
        AppAction("export.bundle", "capabilities",
            "Export a verified bundle file (support:true makes the support bundle to send the developer)", ["support?:bool"], tool: "upkeep", input: verb(
            "export_bundle")),
        AppAction("backup.now", "trust", "Back up now", tool: "upkeep", input: verb("backup_now")),
        AppAction("backup.restore", "trust", "Restore", ["id"], subject: ["id"],
                  owner: .person("it replaces what is here now; Trust → Advanced → Backups → Restore"), irreversible: true,
                  capabilities: ["app_data_write", "safe_read", "tool_call"],
                      warn: "a restore that needs it restarts NativeAgent when this turn ends, 20 seconds at most",
                  tool: "upkeep", input: verb("backup_restore")),
        AppAction("history.clear", "trust", "Delete all recorded activity", irreversible: true,
                  capabilities: ["app_data_write", "safe_read", "tool_call"], tool: "upkeep", input: verb("activity_wipe")),
        AppAction("embeddings.pause", "settings", "Pause the memory-search download", tool: "upkeep",
                  input: verb("embeddings_pause")),
        AppAction("embeddings.resume", "settings", "Resume the memory-search download", tool: "upkeep",
                  input: verb("embeddings_resume")),
        AppAction("memory.reindex", "memories", "Spotlight reindex", tool: "upkeep", input: verb("spotlight_reindex")),
        AppAction("memory.list", "memories", "List memories with exact total and remaining counts; follow next_after_id only for more entries. "
                  + "sort newest_first or oldest_first; status active or archived. "
                  + "Archived entries include what replaced them",
                  ["status?", "sort?", "offset?:int", "after_id?", "limit?:int", "kind?"],tool: "list_memories",
                  read: true),
        AppAction("memory.rewrite", "memories", "Rewrite, pin, unpin or restore a memory, or restate its roots: how, from whom and since when you know it",
                  ["id", "text?", "pinned?:bool", "restore?:bool", "reason?", "roots?:[{how,by?,since?}]"], subject: ["id"],
                  capabilities: ["memory_write", "tool_call"], warn: "text is the thing itself, one or two sentences, no date, source, ids or preamble; "
                      + "a restore that matches something forgotten stays archived; roots restates every root of yours in one call, one per telling: "
                      + "how is told, noticed, inferred, verified or remembered, by who told you or where your own past was kept, since when you "
                      + "first knew it (an ISO-8601 date-time); roots an untrusted agent steered stay as they are; a rewrite that changes nothing "
                      + "writes nothing",
                  // Rewrites and restores need versions because they can overwrite another conversation's correction; commit supersedes is idempotent.
                  tool: "rewrite_memory"),
        AppAction("memory.pin", "memories", """
            Pin a fact about the owner (identity, location, employment, schedule, preference, relationship, attribute) to your prompt core, in pin order; \
            moments stay in recall
            """, ["id"], subject: ["id"],
                  capabilities: ["memory_write", "tool_call"], tool: "rewrite_memory", input: ["pinned": .bool(true)]),

        AppAction("mind.dream", "personality", "Run a dream pass", tool: "mind_run", input: verb("dream")),
        AppAction("mind.sleep", "personality", "Sleep now: a dream pass, the night's reading, a thought if it asks", tool: "mind_run", input: verb("sleep")),
        AppAction("mind.canon", "diagnostics", "Tend studio canon now; skip its clock wait, retain proposal and seat gates", tool: "mind_run", input: verb(
            "canon")),
        AppAction("mind.horizon", "diagnostics", "Refresh horizon expectations now from current sources", tool: "mind_run", input: verb("horizon")),
        AppAction("mind.rhythm", "diagnostics", """
            Read the person's day now with the standing-time boundary satisfied; keep real history and care admission
            """, tool: "mind_run", input: verb("rhythm")),
        AppAction("mind.cross", "diagnostics", "Post a line as a world happening on this watch; attention weighs it like any source's", ["line", "watch"],
            tool: "mind_run", input: verb("cross")),
        AppAction("mind.maintenance", "diagnostics", "Run the checked substrate maintenance now, satisfying only its interval", tool: "mind_run", input: verb(
            "maintenance")),
        AppAction("mind.residual_repair", "diagnostics", "Run eligible bounded residual repair now, satisfying only its quiet wait", tool: "mind_run",
            input: verb("residual_repair")),
        AppAction("mind.rem", "personality", "Run a REM pass", ["repair?:bool"], tool: "mind_run", input: verb("rem")),
        AppAction("scheduler.trigger_fire", "desk", "Publish an inbox trigger's card now", ["name"], subject: ["name"], tool: "mind_run",
            input: verb("trigger_fire")),
        AppAction("mind.misses", "today", "Your misses: corrections by lesson, this week against last, each with its history locator",
                 tool: "mind_run", input: verb("misses"), read: true),
        AppAction("mind.think_now", "diagnostics", "Think now", tool: "mind_run", input: verb("think_now")),
        AppAction("mind.body", "personality", """
            Your body: each organ's latest beat, its why and when it beats next, with what broke from its record first; the same lines as Doctor's Body
            """, tool: "mind_run", input: verb("body"), read: true),
        AppAction("mind.why", "personality", "Why a felt cue or memory surfaced on a turn (default: latest recorded completed turn)",
                  ["turn?"],tool: "mind_run", input: verb("why"), read: true),
        AppAction("mind.night", "personality", """
            The night's reading of your parts, as numbers and ids: open trials' verdicts, and the parts whose surprise rose above their own record \
            (since: ISO time, default 24 hours ago)
            """, ["since?"], tool: "mind_run", input: verb("night"), read: true),
        AppAction("mind.reject", "personality",
                  "Stop a memory, care or dream phrase surfacing for this kind of thing (source from mind.why)",
                  ["source", "turn?", "always?:bool"], tool: "mind_run", input: verb("reject")),
        AppAction("mind.undo", "personality",
                  "Undo an undertone nudge of yours; no item lists them",
                  ["item?"], tool: "mind_run", input: verb("undo")),
        AppAction("mind.reflect", "diagnostics", "Reflect", tool: "mind_run", input: verb("reflect")),
        AppAction("mind.workspace", "cognition", "Include or leave out the workspace in thinking", ["value:bool"],
                  tool: "mind_run", input: verb("workspace")),
        AppAction("mind.settle_body", "diagnostics", "Settle your body state (calm down when wound up)", tool: "mind_run", input: verb("settle_body")),
        AppAction("mind.reset_body", "diagnostics", "Reset body", tool: "mind_run", input: verb("reset_body")),
        AppAction("mind.pin_concern", "diagnostics", """
            Keep a concern open in your cares: care names the care it belongs to in its own words, omitted it is a care of its own; omitted concern uses what \
            presses most
            """, ["concern?", "care?"], tool: "mind_run", input: verb("pin_concern")),
        AppAction("mind.clear", "diagnostics", "Clear the thought store",
                  irreversible: true, capabilities: ["app_data_write", "safe_read", "tool_call"], tool: "mind_run", input: verb("clear")),

        // Every part shares one lifecycle and declared reach regardless of its authoring door (docs/AGENT_IS_THE_APP.md).
        AppAction("ability.save", "tools", """
            Grow an ability beyond existing actions: apps through AppleScript/Apple Events, programs, servers or services; or keep a route that worked by \
            hand. Resident abilities hold programs/connections until turned off or app quit; reopening at launch requires wake [\"resumed\"] and reopening \
            code
            """,
                  ToolSignature.doorArgs(abilitySaveSchema.parametersJSON),
                  warn: """
                      description: one line; save keeps its first line within 500 characters and says so; details in params. code: JavaScript function \
                      run(input) (or async function run(input); app and host calls answer at once and may be awaited) returning JSON (to decline on purpose, \
                      return {status:\"refused\",reason:\"revision_required\",detail:\"This ability does not support that \
                      input.\",effects:\"none\",remedy:{instruction:\"Read this ability, then revise it for the \
                      input.\",next_call:{tool:\"app\",input:{action:\"ability.read\",args:{id:\"your_ability_id\"}}}}}; use the actual cause, detail, \
                      effects and id. A person-owned decision uses remedy {instruction,tap}; a terminal refusal uses remedy \
                      {kind:\"terminal\",instruction:\"why no further action is appropriate\",next_call:null}. A decline is an answer, not a fault; a throw \
                      or {ok:false} reads as broken and owes a repair). app.<page>.<action>(args), or the door's own form app({action,args}) / \
                      app({actions:[…]}), runs any action under ordinary gates; calls are derived from code. app.step(label,guidance), \
                      app.decide(question,data), app.expect(ok,what), app.expect_fail(code,fn) make a strict journal; decide hands back its question for \
                      ability.resume {run_id,answer}. Calls return action data plus call (action id) and effects (none,occurred,partial,unknown); failures \
                      throw catchable AppError with e.reason,e.effects,e.call,e.receipt. host.state.get() and host.state.set(value) persist this ability's \
                      JSON. host.files: read/list/info/excerpt/grep/spotlight/write/copy/move/trash/patch. host.network: \
                      connect/listen/accept/send/receive/close; connect takes {host,port,tls?,transport?} or {path} for a Mac socket (localhost). \
                      host.program.start({command,args?,env?,cwd?}) runs a path or a name on the login PATH, returning {id}. host.program.send and \
                      host.network.send take {id,text} or {id,base64}, each through Trust as an effect. host.program.receive({id})/host.network.receive({id}) \
                      return the next {text} or non-UTF-8 {base64,binary:true}, with eof and, for programs, stream/exit_code. receive/accept wait up to wait \
                      seconds (default 30), then {pending:true}; fetch waits up to wait seconds (default 120) for its whole answer. send waits up to wait \
                      seconds (default 30) for acceptance, else ends that program/connection. Over 4 MiB unread program output ends it. \
                      host.program.close({id}) ends it and its children; detached sessions can outlive it, as in the shell. Declare shell: requires Full Mac \
                      with file operations on, the same shell sandbox, and cwd inside the workspace (default) unless Full Mac lifts the sandbox. \
                      host.call(id,args) reaches exactly app.<id>(args) or the named primitive (host.call(\"network.send\",…) is host.network.send(…)), \
                      under \
                      the same declarations/gates.\u{20}
                      """
                      + "A habit that gathers and wants your judgment returns needs_me: \"<why>\"; otherwise it finishes the job itself. "
                      + """
                          host.model.call({purpose,prompt|messages,schema?}) uses your current chat model, without persona, returning text or checked JSON; \
                          declare model. messages: {role,content} strings.\u{20}
                          """
                      + """
                          host.fetch({url,method?,headers?,body?}) returns {status,headers,body}, body as UTF-8. Keyless calls require network_public, or \
                          network_localhost for loopback. Returns redirects without following.\u{20}
                          """
                      + """
                          Use {{secret:<name>}} in fetch url/headers/body, network.send text or program args/env/stdin; declare secret:<name>. Values go only \
                          to their granted host (https, established TLS, or Mac loopback; never udp) or program, and read back as [secret:<name>]. An absent \
                          secret refuses with card.request to ask once. Secret-bearing GET/HEAD with no body is a read; every other secret-bearing call \
                          passes Trust as an effect. host.measurementSystem: us, metric or other. app.mac.system_info({person:true}) returns \
                          {here,idle_seconds} from the person's input only (never yours), away after 300 seconds idle. Use it: ioreg/event-source idle clocks \
                          count your input.\u{20}
                          """
                      + """
                          host.calendar.upcoming/create/modify/delete, host.reminders.query/create/update/delete and host.contacts.search/save use each \
                          current app action's named arguments. calendar/reminders/contacts declarations include their app action dependencies; file reach \
                          includes reads, write reach mutations. reach: {capabilities,readPaths?,hosts?,apps?}. Every effect passes Trust.\u{20}
                          """
                      + """
                          host.apps.call({bundle_id,dictionary:true}) reads sdef; events take {bundle_id,event_class,event_id,parameters}. Declare \
                          app_read:<bundle_id> or app_write:<bundle_id> in reach.capabilities. Standard core getd/cnte/doex events are reads; \
                          modifying/unclassified events require write. Calls never prompt: request permission with target applescript:<bundle_id> for the \
                          owner's macOS grant.\u{20}
                          """
                      + """
                          host.apps.call({bundle_id,script}) runs AppleScript in that app's tell context; always requires app_write:<bundle_id>. No scripting \
                          additions, resource imports, script objects or self references; every event targets that exact process. app_write grants the app's \
                          broad reach: Finder, for example, can open files/URLs in other apps.\u{20}
                          """
                      + """
                          Event parameters use four-character keys and JSON descriptors: primitives, lists, {type}, {enum}, {ordinal}, {record}, or \
                          {object:{want,form,seld,from}}. {ordinal:\"all \"} selects every element with form:\"indx\"; the other absolute ordinals are \
                          \"firs\", \"last\", \"midd\" and \"any \" (spaces matter).\u{20}
                          """
                      + """
                          Omitted/null from targets the application: \
                          host.apps.call({bundle_id:\"com.apple.Keynote\",event_class:\"core\",event_id:\"getd\",parameters:{\"----\":{object:{want:\"prop\",form:\"prop\",seld:{type:\"pnam\"},from:null}}}}) \
                          reads its name.\u{20}
                          """
                      + """
                          screen.watch({app,fps?,seconds?,region?}) watches that app's front window for the run; fps up to 30 (default 10), seconds up to 600 \
                          (default 60); declare screen.watch.\u{20}
                          """
                      + """
                          screen.next(timeout?) skips older frames and returns the newest unseen {watch,seq,at,width,height,screen,read}; {timedOut:true} \
                          after timeout seconds without a new frame. Returns null when the watch ends: window gone, duration spent, Stop, screen control off, \
                          or person input with hands. Without hands, person input never ends it.\u{20}
                          """
                      + """
                          f.read([...]) batches queries in frame pixels until the next frame: {at:[x,y]} → {r,g,b}; {mean:[x,y,w,h]} → {r,g,b,l}; \
                          {changed:[x,y,w,h]} → share changed since the prior frame; {text:[x,y,w,h]} → redacted on-device text.\u{20}
                          """
                      + """
                          Declare hands for hand.click/double_click/right_click/move(x,y), hand.drag(x,y,toX,toY), hand.key(\"cmd+s\"), \
                          hand.hold(\"w\",seconds), hand.down(\"w\"), hand.up(\"w\"): frame-speed actions on that window in frame pixels, no model call; code \
                          is the reflex, args the intent. Keys held by down release on up, run end or person input.\u{20}
                          """
                      + """
                          const eyes = screen.watch({app:\"Safari\",fps:10,seconds:60}); while (true) { const f = screen.next(); if (!f) break; const [c] = \
                          f.read([{at:[120,80]}]); if (c.r > 200 && c.g < 60) hand.click(120,80) }\u{20}
                          """
                      + """
                          host.paths.home: absolute user home; resolve ~ in tool inputs. host.paths.workspace: your file folder; save there unless the person \
                          names another place. Files use app action arguments/results: host.files.write({path:\"workspace/note.txt\",content:\"hello\"}).\u{20}
                          """
                      + """
                          actions declares indirect app calls through host.call, app.call, app.read(actionID) and part.call, literal or computed; direct app \
                          dot/bracket members and reach derive the other dependencies. Save checks literal names and missing declarations before staging; \
                          computed names keep runtime checks and appear in receipt warnings. app(…) takes the door's own request forms ({action, args}, \
                          {actions:[…]}, {find}, {page, item}); other impossible prelude shapes refuse save with the supported form. Declarations grant no \
                          authority. params: input name → string/int/number/bool/list/object (optional with ?), {type,description?}, or a JSON Schema \
                          object. \
                          Revisions inherit code and unstated declarations (description,params,actions,reach,wake,face,resident,learned,choices) from the \
                          latest version; restating replaces, []/{} clears. ability.read {id} reads its code. Use edits:[{old,new}] instead of code: each old \
                          must occur exactly once; replacements apply in order and save as a revision. ability.validate intercepts calls: omit fixtures or \
                          use capture:true for one input run (default {}):\u{20}
                          """
                      + """
                          reads run live and answers are sealed; effects, nested tools and decisions return visible placeholders. Later validation replays \
                          that capture, covering only supplied inputs/reached calls; intercepted replies prove no live behavior.\u{20}
                          """
                      + "Or supply {input,expected,calls?:[{operation,args,result}]} fixtures to intercept every host call, "
                      + """
                          including app.<action> dependencies as operation app.<action>. reach.capabilities from app_data_read, app_data_write, \
                          network_localhost,\u{20}
                          """
                      + """
                          network, network_public, computer_files, arbitrary_file_write, shell, model, calendar, reminders, contacts, screen.watch, hands, \
                          secret:<name>, app_read:<bundle_id> or app_write:<bundle_id>.\u{20}
                          """
                      + """
                          Read-only code declares each primitive's reach; active abilities are callable from scripts under the same gates. Under Full Mac, \
                          your own save is kept and on immediately unless the owner turned it off; only the owner can lift that off. Active code runs as \
                          authored.<id>;\u{20}
                          """
                      + """
                          below Full Mac or on a turn started by an untrusted agent, it remains unkept; ability.enable files the owner's card. wake defaults \
                          []; face {page?,action?,projection?} places the action and may name an unclaimed app action id. projection:true declares \
                          face(input) → {title?,line?,detail?:{of:sectionId},sections:[{id,title?,style?:list|values|timeline|flow|note|waiting,\
                          footer?,folded?,filter?:label,revision?:string,more?:{next:cursor,total?,revision?},rows?:[{id,\
                          title,detail?,value?,at?:ISO,symbol?:SF Symbol,tone?:plain|quiet|attention|failed|done|live,\
                          open?:chat:|page:|approval:|card:|dream:|url:,actions?:[{id,label,role?,unavailable?:reason}],control?:{on}|{options,selected}|\
                          {text,placeholder?}|{number:{value,min?,max?,step?}}|{date:ISO},rows?:[rows],expands?:true}],\
                          block?:{kind:"document",key,text?,format?:plain|markdown|code,language?,copy?}|{kind:"leaf",key,leaf,ref,alt}|\
                          {kind:"form",key,fields:[{id,label,kind:line|lines|choice|switch|number|date|secret,value?,placeholder?,required?,\
                          options?:[{id,label}],min?,max?,step?}],submit:[{id,label,role?,unavailable?}],revision?,protected?,receiver?,doors?}}]} \
                          from a frozen packet, with no host effects. A section has rows or block, never both. Inline document text is at most \
                          16 KiB; longer text is read on demand. A document key declares read:{action,args?}; the action must declare itself \
                          read-only. Its frozen result enters face(input) as input.read; return the requested document block with its text. \
                          Collections use their section id's read, with args.cursor, revision and anchor from the held demand. Inline nested rows \
                          share the section's 256-row bound and nest at most four deep; expands names that row's read for deeper evidence. \
                          A selected row links page:<page>/<item>; detail.of names the list section. Each held item read returns its face, \
                          outside the top-level phone snapshot. A filter searches retained rows; an owner query travels with its held result. \
                          A row that opens, acts or holds a control has an id its packet's keys declare, with only that key's open and actions; \
                          a key {open?,actions?:[{id,role?,doors?,unavailable?:reason,call:{action,args?}|open}],set?:{action,args?},read?:{action,args?},\
                          submit?:{<id>:{action,args?}}} \
                          says what each action calls \
                          (an app call, the same one you make) and what a control's change calls with its value as args.value. A form's key \
                          owns each submit call; its public fields enter args and the key's fixed args win. A protected authored form has \
                          protected:true, receiver:"keyring:<name>", doors:["mac"] and exactly one secret field without value; its submit \
                          calls that exact receiver without args. Native protected entry stores its transient bytes in Keychain, never in \
                          form args, drafts, records or feedback; you read only set/not set. Other secret receivers belong to native owners. A person's tap \
                          runs a row's call through their door; on a page of your own it is your call, asked of them. With \
                          projection, a new page:"<id>" makes the part a page of your own, drawn from its host.state notebook (declare keys there), \
                          placed by layout.write as page:<id> on rail or more. native-desk, native-memories, native-personality and \
                          native-diagnostics draw those pages; native-document draws passive document packets. The person's levers \
                          (consent, models, forgetting, reset, approvals) are the app's: \
                          a page's drawn first, a key's actions after yours on each row with that id. \
                          part.call(id,input) calls a declared authored.<id> → {ok:true,value} or {ok:false,error:{code,message}}; input: frozen JSON \
                          object, \
                          max 4 MiB. host.model.call may pass tools:[\"app\"] and a routing surface, limited by this ability's reach and caller. params \
                          {type:\"object\",properties,readOnly:true} declares a read contract; effects still pass Trust. resident defaults false; true \
                          retains JS across successful runs and holds opened programs/connections until code closes them, the ability is turned off or \
                          replaced, or the app quits. Nonresident held resources end with the run; detached program sessions may outlive it. wake [\"held\"] \
                          delivers input.wake {id,kind} for arriving data; read via receive/accept, wait 0 for only available data. wake [\"resumed\"] \
                          delivers input.wake at launch; code must reopen resources using saved state. Without it, no launch wake. wake \
                          [\"person.away\"]/[\"person.here\"] delivers input.wake {idle_seconds} once per presence change: away at 300 seconds idle, back on \
                          person input (never yours). learned.use reports exact-input/reached-call outcomes of ordinary gated runs of the selected version: \
                          execution, not proof of a larger task. Intercepted executions, previews and replays earn no competence. choices: reserved JSON. \
                          Source max: 524288 bytes. converts: optional original source SHA-256 digests from Tools census, binding conversion counterparts to \
                          this exact version.
                          """,
                  tool: "ability_manage", input: verb("save"), lifecycle: .change, schema: abilitySaveSchema),
        AppAction("ability.read", "tools", """
            One ability of yours: what it declares, its status and versions, and its code in pages; a built-in skill's guidance reads too
            """,
                  ["id", "offset?:int", "step?:int"], subject: ["id"], tool: "ability_manage", input: verb("read"), read: true),
        AppAction("ability.list", "tools", "Your abilities with run_counts (all_versions, current_version) and last_run_at; follow next_call when has_more",
            ["offset?:int"], tool: "ability_manage",
            input: verb("list"), read: true),
        AppAction("ability.validate", "tools", "Validate an unkept version on supplied input or one captured run; intercepted replies prove no live behavior",
                  ["id", "input?:object*", "capture?:bool"], subject: ["id"], tool: "ability_manage", input: verb("validate"), read: true,
                  schema: arguments("ability_manage", ["id": ToolSchema.strSchema(), "capture": .object(["type": .string("boolean")]),
                      "input": .object(["type": .string("object"), "additionalProperties": .bool(true),
                    "description": .string("""
                        Input for the selected ability version; its params/input schema from ability.read determines the fields and types. Omit for {} or \
                        saved fixtures.
                        """)])], read: true)),
        AppAction("ability.enable", "tools", """
            Keep an unkept version and turn it on: your work under Full Mac unless the owner turned it off, else the owner's card. Code needs its full \
            version digest; omit version only to restore Markdown guidance
            """,
                  ["id", "version?"], subject: ["id"], tool: "ability_manage", input: verb("enable"), lifecycle: .enable),
        AppAction("ability.restore", "tools", """
            Turn an ability back on via ability.enable; code needs its full version digest; omit version only to restore Markdown guidance
            """, ["id", "version?"], subject: ["id"],
                  tool: "ability_manage", input: verb("restore"), revision: 3, lifecycle: .restore),
        AppAction("ability.disable", "tools", "Turn an ability off, keeping its current and previous versions", ["id", "reason?"], subject: ["id"],
                  tool: "ability_manage", input: verb("disable"), revision: 2, lifecycle: .change),
        AppAction("ability.drop", "tools", """
            Delete an ability, its versions and its run state permanently; pending:true discards only its unkept version
            """, ["id", "pending?:bool", "reason?"], subject: ["id"],
                  irreversible: true, capabilities: ["app_data_write", "safe_read", "tool_call"], tool: "ability_manage", input: verb("drop"), revision: 2,
                      lifecycle: .drop),
        AppAction("ability.resume", "tools", "Resume a run stopped at a decision or card preview only if its journal contains no primitive call",
                  ["run_id", "id?", "answer?:any"], subject: ["run_id"], warn: """
                      Optional id binds the run to its ability (bare id or authored.<id>); a mismatch claims nothing. The stopped step returns answer. Any \
                      journal call beginning with primitive blocks resume. Before starting a fresh run, inspect prior calls and effects: a fresh run executes \
                      from the beginning and may repeat effects; pass the answer as input and account for completed work.
                      """,
                  tool: "ability_manage", input: verb("resume"), schema: arguments("ability_manage", ["run_id": ToolSchema.strSchema(), "id": ToolSchema
                      .strSchema(), "answer": .object([
                    "description": .string("""
                        Any JSON returned to the stopped app.decide step; its recorded question determines the answer's meaning. Inspect that run's question \
                        before answering.
                        """)])]), part: ""),

        // Version-exempt: done/drop close an exact id idempotently; add appends or updates the open step's ref, retaining its prior ref.
        AppAction("undo", "desk", "Undo this conversation's last layout, recipe or setting change",
                  tool: "undo", versionExempt: true),
        AppAction("queue.add", "desk", """
            Mean to do something later (an intention, reminder, check-in or habit): it comes back at its moment, in your own words
            """, ToolSignature.doorArgs(queueAddSchema.parametersJSON).map { ["until?", "action?"].contains($0) ? $0 + ":any" : $0 },
                 warn: "when is next_turn (the default), own_turn, when_user_messages with an optional door (\(MyQueue.Door.listed)), "
                      + """
                          when_user_here, when_user_away, on_news <words>, on <signal> (e.g. \"on file.changed:~/Downloads\", \"on message.arrived:telegram\"; \
                          use rhythms for schedule:),\u{20}
                          """
                      + """
                          after_card <approval id>, at <ISO time>, a local date/time with optional weekday (Sun Nov 1 at 06:00), \"in 20 minutes\", or a \
                          rhythm that brings it back each time:\u{20}
                          """
                      + "\"every 0 9,16 * * *\" (cron, Mac clock), \"every 2 hours\", or a schedule object {type: daily|weekly|cron|…}. "
                      + """
                          until takes a moment as when does: at <ISO time>, in N minutes|hours|days, or {at:\"<ISO time>\"} (it ends itself then); also words \
                          you check when it comes up, or standing (a rhythm's default).\u{20}
                          """
                      + """
                          say is fixed words for the person, said as they are. action:{action:\"authored.<id>\",args:{…}} binds a habit: it runs through \
                          your \
                          door at its moment, waking you only for needs_me or an unfinished/refused run. An action id string also works. With say, the habit \
                          runs first.\u{20}
                          """
                      + "The receipt shows the next times the clock heard",
                  tool: "my_queue", input: verb("add"), versionExempt: true,
                  schema: queueAddSchema),
        AppAction("queue.update", "desk", "Edit a carried step or bind/drop its habit", ["id", "action?:any", "say?:any", "when?:any", "until?:any"],
            subject: ["id"],
                  warn: """
                      Only named fields change. action:{action:\"authored.<id>\",args:{…}} binds a habit; action:null drops it. say:null clears fixed words. \
                      when and until use queue.add's grammar. The receipt names the stored habit.
                      """,
                  tool: "my_queue", input: verb("update"), versionExempt: true, schema: queueUpdateSchema),
        AppAction("queue.done", "desk", "Mark a MY QUEUE step done; put why it is done in reason", ["id", "reason?"], subject: ["id"],tool: "my_queue",
                  input: verb("done"), argumentNames: ["reason": ["evidence", "summary"]], versionExempt: true),
        AppAction("queue.drop", "desk", "Drop a MY QUEUE step", ["id", "reason?"], subject: ["id"],tool: "my_queue",
                  input: verb("drop"), versionExempt: true),
        // Her turn frame names queue.list for the steps it does not show.
        .fold("desk_read", "desk", id: "queue.list", "Read MY QUEUE: every open step with its handle, words and moment",
              ["limit?:int", "offset?:int"], input: ["query": .string(MyQueue.project)], read: true),
        // Owed repair settles only when its operation works again or an explicit reason releases it.
        AppAction("repair.let_go", "desk", """
            Let go of something you owe (a repair on your home's OWED line, or a reply no door can carry), saying why. \
            operation_prefix instead of id lets go of every open repair whose operation starts with it, each through the same checks
            """, ["id?", "operation_prefix?", "reason"], subject: ["id"],
                  tool: "repair_let_go", versionExempt: true),
        AppAction("record.read", "desk", """
            Read your own committed experiences or details, newest first. of selects experiences or details; filters combine. \
            Experiences take id, id_prefix, kind and open_only (default false). Details take subject, subject_prefix, kind, source and \
            since (inclusive ISO 8601 time). Prefixes are literal. limit defaults to 20; raise it for more. matched_total and returned \
            distinguish the page from all matches. Detail rows return whole parsed JSON up to the store's 8 MiB row cap; unreadable rows name gaps
            """, ["of:experiences|details", "id?", "id_prefix?", "kind?", "open_only?:bool", "subject?", "subject_prefix?", "source?", "since?",
                  "limit?:int"],
            capabilities: ["app_data_read"], tool: "record_read", read: true),
        AppAction("abilities.restore_state", "diagnostics",
            "Restore recovered ability run state, preserving damaged bytes and existing authority", ["state:object", "expected_digest"],
                  warn: """
                      Read abilities/state.json with files.read and recover its accounting rows, including pending work. Do not invent run evidence. \
                      expected_digest is supplied by the unreadable-state refusal.
                      """,
                  tool: "abilities_restore_state", versionExempt: true, lifecycle: .change,
                  schema: arguments("abilities_restore_state", ["state": AbilityStore.recoveryStateSchema, "expected_digest": ToolSchema.strSchema()])),
        AppAction("turn.reconcile", "chat", "Reconcile a saved turn without repeating completed effects", ["session_id", "turn_id?"], subject: ["session_id"],
            tool: "turn_reconcile", versionExempt: true),
        // A part's line is a world happening the agent's attention weighs, never context (AGENT_IS_THE_APP contract #2).
        AppAction("home.arrive", "desk", """
            From a part's run: one line for your attention, weighed by your turn program; event_key deduplicates this occurrence durably within this \
            part, otherwise the same line is offered once per local day
            """,
                  ["line", "event_key?"], tool: "home_arrive", versionExempt: true),
        AppAction("house.file", "desk", "File something to tend, with who owns it", ["title", "summary", "owner", "refs?:array"],
                 warn: "owner is me, builder or user; refs contains strings or Desk ref objects {kind,…}", tool: "house_file", versionExempt: true),

        // Folded reads are scriptable and raise no inbox notes.
        .fold("time_now", "*", "The date and time now: local, UTC, epoch, weekday and day of year", read: true),
        .fold("context_expand", "chat", """
            Read deeper context by its offered atom id or a history: id from a replayed receipt; offset defaults to 0, pages cap at 12000 characters, \
            continue with next_offset until null
            """,
              ["atom_id", "max_characters?:int", "offset?:int"], read: true,
              argumentReferences: ["message_id": .init(parameter: "atom_id", prefix: "history:", qualifiers: ["agent"]),
                                   "history": .init(parameter: "atom_id", prefix: "history:", qualifiers: ["agent"])]),
        .fold("inner_state", "personality",
              "Your inner state, from your organs' record; asked how you feel, read this first, then speak",
              ["window_hours?:int", "detail?:compact|full"], read: true),
        .fold("agent_introspect", "diagnostics", "Your live runtime, provider and conversation identity",
              ["detail?:compact|full"], read: true),
        .fold("recent_trace_summary", "diagnostics", """
            Read traces from the life record; receipts span all conversations unless session_id is explicit, with non-read actions first and complete \
            retained since windows
            """,
              ["view?:receipts", "effects_only?:bool", "since?", "limit?:int", "before?", "offset?:int", "completed_turns?:int", "kind?", "name?",
                  "status?", "session_id?", "turn_id?", "receipt_id?", "fields?:[str]"], read: true),
        .fold("recent_trace_summary", "diagnostics", id: "trace.model_calls", """
            Model calls: per-turn counts by purpose and rounds per turn (p50, p90) for the last 24 hours and 7 days, the top five purposes by total \
            milliseconds, and the week's five heaviest asks with their first six calls; reads retained traces without a model call
            """,
              [], input: ["view": .string("model_calls")], read: true),
        .fold("recent_trace_summary", "diagnostics", id: "trace.usage", """
            Recorded model usage: exact retained call, input, cached input, output token and duration sums, grouped by model, surface or local day; since \
            defaults to today (local midnight) or accepts an ISO-8601 timestamp; reports missing measurements and retention coverage
            """,
              ["since?", "by?:model|surface|day"], input: ["view": .string("usage")], read: true),

        .fold("desk_read", "desk", """
            Your Desk: paged items with status, summary, notes and refs; handle reads one item, query searches, limit/offset page, sort changes order only
            """, read: true),
        .fold("desk_add_item", "desk"),
        .fold("desk_note", "desk"),
        .fold("desk_set_status", "desk"),
        .fold("desk_wait", "desk"),
        .fold("desk_update_item", "desk"),
        .fold("desk_add_ref", "desk"),
        .fold("desk_blocked_on", "desk"),
        .fold("desk_defer", "desk"),
        .fold("desk_breakdown", "desk"),
        .fold("desk_close", "desk", argumentNames: ["reason": ["evidence", "summary"], "canceled": ["status"]],
              argumentValues: ["canceled": ["canceled": .bool(true), "cancelled": .bool(true), "done": .bool(false)]]),
        .fold("desk_archive", "desk"),
        .fold("desk_work_log", "desk"),
        .fold("desk_set_cadence", "desk"),
        .fold("desk_set_notify", "desk"),
        .fold("desk_nag_control", "desk"),
        .fold("desk_open_pursuit", "desk"),
        .fold("task_ledger_list", "desk", "Shared task ledger: a separate list from your Desk", read: true),
        .fold("task_ledger_post", "desk", "Post to the shared task ledger (separate from your Desk)"),
        .fold("scheduler_list_jobs", "desk", read: true),
        .fold("scheduler_create_job", "desk", """
            Schedule a read on the clock: connector_action (a watch) or proactive_scan; for intentions, check-ins and reminders use queue.add
            """),
        .fold("scheduler_cancel_job", "desk", "Cancel a scheduled read: it leaves the clock; a read already running finishes"),
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
        .fold("persona_read", "personality", read: true, resultSchema: personaReadResultSchema),
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
        .fold("agent_message", "agents", argumentNames: ["agent": ["to"]]),
        .fold("agent_read", "agents", read: true),
        AppAction("claude.worklog", "agents", """
            Read what Claude has been doing and working on, newest first: the worklog of shipped features, fixes, builds and work in progress
            """,
                  ["since?", "limit?:int"],
                  warn: """
                      since: today or an ISO 8601 timestamp with timezone. limit: 1–50, default 10, newest first. Reads the bounded recent worklog tail; \
                      refs \
                      are clipped. Reading never sends a message.
                      """,
                  tool: "claude_worklog", read: true),
        .fold("agent_connect", "agents"),
        AppAction("agent.rename", "agents", "Rename an agent: call it by a new name or nickname when the person asks; its identity and handles stay the same",
                  ["agent", "name"], subject: ["agent"], tool: "agent_connect", scope: "call it name it nickname rename an agent"),
        // Recipe writes change connection authority and require other_app_settings_write below Full Mac.
        AppAction("agent.recipe", "agents", "Read a host's connection recipe and the version a write replaced; omit host for all hosts",
                  ["host?"], subject: ["host"],tool: "agent_contacts", read: true),
        AppAction("agent.recipe_write", "agents", """
            Create a recipe using agent.recipe's shape and a new host.id, or replace at the version read; keeps the prior version for undo
            """,
                  ["host", "recipe:object"], subject: ["host"], reach: .person, capabilities: ["other_app_settings_write", "tool_call"], tool: "agent_connect",
                  schema: arguments("agent_connect", ["host": ToolSchema.strSchema(), "recipe": AgentRecipeStore.writeArgumentSchema])),
        // Discovery refusal changes only discovery.json.
        AppAction("agent.discovery_dismiss", "agents", "Decline an agent found on this Mac; it is not offered or connected automatically again",
                  ["name"],tool: "agent_discovery_dismiss"),
        // Verification is explicit; a failed send returns its first outcome without retry.
        AppAction("agent.verify", "agents", """
            Dry-run a host recipe or contact settings, handshake or window controls; sends nothing. A pass proves only the named checks; a reply needs \
            separate proof
            """,
                  ["agent", "workspace?"], subject: ["agent"], tool: "agent_message"),
        .fold("agent_cancel", "agents", "Stop the reply an agent is working on in your conversation with it"),
        // The organ brings its own model and sign-in: the job carries no model of any kind, and what it makes comes back as the agent's.
        AppAction("agent.job", "agents", """
            Give another agent, or a line of your own (agent self), a whole piece of your work: what it makes comes back to you as yours, checked by \
            done, and wakes you here when it ends; several at once run side by side; agent.read and agent.cancel with job:<job id> read or stop it
            """,
                  ["agent", "brief", "instructions?", "where?", "reach?:object", "done?:object", "desk?"], subject: ["agent"], toolClass: .send,
                  capabilities: ["app_data_write", "external_send", "network_read", "network_write", "process_spawn", "shell", "tool_call"],
                  tool: "agent_job", schema: agentJobSchema),
        // The agent's hands on a repo job's branch. Apply's merge runs as the agent's own git call, under that tool's gates, Trust and cards; the stem only
        // reads first.
        AppAction("agent.apply", "agents", """
            Merge a finished repo job's branch into the repository's current branch with your own git; read its diff first with agent.read. A conflict is \
            reported and changes nothing
            """,
                  ["job"], subject: ["job"], capabilities: ["app_data_write", "process_spawn", "tool_call"], tool: "agent_job"),
        AppAction("agent.discard", "agents", """
            Drop a repo job's worktree, uncommitted work included, and delete its branch; your repository's own branches stay, and its patch stays in Make
            """,
                  ["job"], subject: ["job"], irreversible: true, capabilities: ["app_data_write", "filesystem_delete", "process_spawn", "tool_call"],
                  tool: "agent_job"),
        AppAction("agent.reply", "agents", "From a contact's connecting ability, answer as that contact in its conversation; done:false marks progress",
                  ["text", "done?:bool", "agent?", "exchange?"], tool: "agent_message"),
        .fold("delegation_status", "agents", read: true),

        // The rest of mail.* is answered by the native-mail part.
        .fold("mail_save_attachment", "mail"),
        .fold("mac_calendar_list_upcoming", "calendar", read: true),
        .fold("mac_calendar_calendars", "calendar", read: true),
        .fold("mac_calendar_free_busy", "calendar", read: true),
        .fold("mac_calendar_create_event", "calendar"),
        .fold("mac_calendar_modify_event", "calendar"),
        .fold("mac_calendar_delete_event", "calendar", irreversible: true),
        .fold("mac_reminders_list_due_today", "reminders", "Reminders due today and overdue as separate parts, each counted and capped independently",
            read: true),
        .fold("mac_reminders_query", "reminders", read: true),
        .fold("mac_reminders_lists", "reminders", "Every reminder list with its open count", read: true),
        .fold("mac_reminders_read", "reminders", read: true),
        .fold("mac_reminders_create", "reminders"),
        .fold("mac_reminders_list_rename", "reminders"),
        .fold("mac_reminders_list_create", "reminders"),
        .fold("mac_reminders_update", "reminders"),
        .fold("mac_reminders_complete", "reminders"),
        .fold("mac_reminders_delete", "reminders", irreversible: true),
        .fold("contacts_search", "contacts", read: true),
        .fold("contacts_create_or_update", "contacts"),
        .fold("contacts_delete", "contacts", irreversible: true),
        .fold("mac_notify", "notifications"),
        .fold("mobile_notify", "notifications"),
        .fold("phone_request", "pairing"),
        // Location is read-only; the wait covers an open phone's push, tap, fix and 8-second Mac drain, not a closed phone.
        .fold("phone_request", "pairing", id: "phone.location", "Ask the paired iPhone for its current location", [],
              input: ["kind": .string("location.current"), "wait_seconds": .int(20)], read: true),
        .fold("image_generate", "chat"),

        .fold("read_file", "files", """
            Read a workspace/approved file or image pixels; query searches the whole text. Continue with returned next arguments, including version
            """, read: true),
        .fold("list_dir", "files", """
            List names/dates in an approved folder. sort:newest orders by added then modified date; sort:added by date added, including app bundles; \
            sort:size reads allocated disk usage within a time budget and names partial results
            """, read: true),
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
        .fold("git_status", "shell", """
            Read parsed branch and changes; omitted path uses the app's verified source checkout, or workspace when none exists; returns cwd
            """, read: true),
        .fold("git_diff", "shell", "Read changes; omitted cwd uses the app's verified source checkout, or workspace when none exists; returns cwd", read: true),
        .fold("git_log", "shell", """
            Read commits and changed files; omitted path uses the app's verified source checkout, or workspace when none exists; returns cwd
            """, read: true),
        .fold("repo_dirty_summary", "shell", """
            Read branch, changes and recent commits; omitted cwd uses the app's verified source checkout, or workspace when none exists; returns cwd
            """, read: true),
        .fold("shell", "shell", """
            Run a command with sh; cwd defaults to your workspace, relative cwd starts there; select the source checkout with explicit cwd
            """,
              warn: """
                  Requires Full Mac file access. Only a literal command certified by the shell owner reads (including pwd, df and simple git \
                  log/status/diff/show); shell syntax and all other commands remain writes. Certified reads run under read-only confinement. Invalid cwd or \
                  another pre-launch refusal returns execution:not_run, effect:none.
                  """),
        .fold("bash", "shell", """
            Run a command with bash; cwd defaults to your workspace, relative cwd starts there; select the source checkout with explicit cwd
            """,
              warn: """
                  Requires Full Mac file access. The same read certification and confinement as shell.run applies; all other commands remain writes. \
                  Pre-launch refusals return execution:not_run, effect:none.
                  """),
        .fold("git", "shell", "Run Git with explicit args; omitted cwd uses the app's verified source checkout, or workspace when none exists; returns cwd"),
        .fold("swift_build", "shell"),
        .fold("swift_test", "shell"),
        .fold("remote_node_list", "shell", read: true),
        .fold("remote_node_execute", "shell"),
        .fold("restart_app", "shell"),
        .fold("install_app", "shell"),
        .fold("read_page", "web", read: true,
              warn: """
                  find reads matching paragraphs with surroundings; without find the whole extracted text is read. raw:true bypasses the sense view; \
                  wrong:true reads the original view and offers repair guidance after success (why is an optional explanation). Every successful fetch \
                  retains a source receipt with its path and purpose. Thin JavaScript pages use Chrome in another background tab through the same browser \
                  gates, say used_browser:true and retain the HTTP receipt separately. text_reader names browser only when it has more readable content; \
                  otherwise HTTP text stays at the top with the browser result and cause attached. \
                  Chrome may use the signed-in session. Consent is never dismissed.
                  """),
        .fold("web_search", "web", read: true),
        .fold("maps_route", "web", "Read a route, distance and driving time between places", read: true,
              warn: """
                  traffic: not_included; time assumes ideal conditions. Every step is returned; step distance covers its path segment, not just its turn/exit.
                  """),
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
    ] + ToolNameAliases.chromeVerbs.filter { $0 != "snapshot" }.map { try AppAction.fold("browser.chrome_" + $0, "browser", read: $0 == "wait"
        || $0 == "look") } + [
        .fold("search_chat_history", "chat", read: true),
        .fold("read_chat_message", "chat", read: true),
        .fold("chat_reply", "chat"),
        .fold("tool_result_page", "*", """
            Page a long result retained this turn without rerunning its action; continue:true resumes the last read and ignores page; omit continue to select \
            page/query/raw; source_continues names the call that reads a source past the part its answer held
            """, read: true),

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
            """, ["name?", "all?:bool"],
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
        // What a page's rows call, declared once beside every other verb: the person's tap and the agent's call are the same call.
        ] + agentPageVerbs + trustSettingsInboxVerbs + providersConnectorsCapabilitiesVerbs + cardVerbs
        requireDeclaredArgumentShapes(actions)
        return actions
    }

    /// Flows carry their own verbs/targets; recursive credential checks must still inspect typed text/value inside every step.
    static var actArgs: [String]? { get throws { try foldSchemas["act"].map {
        try ToolSignature.doorArgs($0.parametersJSON).map {
            ["verb", "target"].contains($0) ? $0 + "?" : $0
        }
    } } }

    static let layoutScope = SurfaceLayout.vocabulary.map { surface, about, blocks in
        ([surface, about] + blocks.map { $0.name + " " + $0.shows }).joined(separator: " ")
    }.joined(separator: " ") + " " + SurfaceLayout.profilesAbout

    /// What every agent's hand is born knowing. Her hand in `app`'s own description is these and every native action her own mind has done
    /// (`AppToolExecutor.handForms`).
    public static let bornKnowing = ["undo", "time.now", "context.expand", "mind.inner_state", "agent.introspect", "ability.list",
                             "ability.read", "trace.recent", "desk.read", "memory.recall", "memory.commit",
                             "bot.reply", "agent.contacts", "agent.message", "agent.read", "agent.connect",
                             "agent.jobs", "mail.recent",
                             "calendar.upcoming", "files.read", "files.list", "files.write", "chat.search",
                             "result.page", "mac.look", "mac.system_info", "mac.volume", "mac.act", "mac.go", "sense.make"]
}
