import AgentWorkspace
import AuthoredCapabilities
import ChatTurnContracts
import ChatToolRuntime
import AgentConversations
import ChromeControl
import Foundation
import MacIntegration
import MemoryV2
import NativeAgentCore
import NativeAgentShared
import PersistenceCore
import PersonaEngine
import Senses
import StandingBots
import ToolRegistry
import TrustCenter
import TurnTrace
// Blueprint: | `AppActionRegistry.swift` | App action definitions and registry (`AppAction`, `AppActions`); dependency contracts omit the retired scriptability field; authored action lookup; one schema-aware semantic/lexical ranking for declared page items, built-ins, admitted tools, enabled skills and current senses, with shared retrieval stop words, a semantic relevance floor and model-epoch action vectors; explicitly requested retired tools are labeled read-only records; file Trash, recurring tasks and named contacts route to their owners; their own parts ranked and rendered from one inventory for the turn glance (`parts`), acknowledging only shown fresh parts; a receipt's `effect` names a run of their part as `part`; chat.post exposes the existing proactive speech seam |

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
    /// Complete search and catalog-version input, including schema words.
    public let scope: String
    /// Model-facing scope; the schema is returned separately.
    let returnedScope: String
    public let schema: LLMToolSchema?
    public let partAction: Bool
    /// The part of hers it runs, by name: a skill, a sense ("" for a door that
    /// runs whichever part it is given). What it does is the part's, not her hand's.
    let part: String?
    /// This row declares a direct call to its tool, including fixed input.
    public let folded: Bool
    /// `name`, `a|b` for either, `?` optional, `:type` when not a string;
    /// `:secret` is a key or token, which receipts and logs redact.
    public let args: [String]
    public let owner: Owner
    public let lifecycle: CapabilityLifecycle.Action?
    /// Cannot be taken back once done, even when it is hers.
    public let irreversible: Bool
    /// What it is when it does not read: a write, a send, or destructive (no way back).
    public let toolClass: ToolClass
    /// Moves User's screen or makes a sound.
    public let screen: Bool
    /// What she must know before doing it, shown on its line.
    public let warn: String
    /// The code it runs (`runFolded`), and the input that picks the verb.
    public let tool: String
    public let input: [String: JSONValue]
    /// Door arg name → the host call's own input key, where the two differ.
    public let rename: [String: String]
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
    public let reach: ToolReach
    public let capabilities: Set<String>
    public let resultSchema: JSONValue

    init(_ id: String, _ page: String, _ label: String, _ args: [String] = [], owner: Owner = .hers,
         irreversible: Bool = false, toolClass: ToolClass? = nil, reach: ToolReach = .hers, capabilities: Set<String>? = nil,
         screen: Bool = false, warn: String = "", tool: String = "",
         input: [String: JSONValue] = [:], rename: [String: String] = [:], read: Bool = false,
         versionExempt: Bool = false, revision: Int = 1, readWhen: [String: JSONValue] = [:], scope: String = "",
         advisory: Bool = false, resultSchema: JSONValue = AppActions.resultEnvelope,
         lifecycle: CapabilityLifecycle.Action? = nil, schema: LLMToolSchema? = nil, partAction: Bool = false,
         part: String? = nil, folded: Bool = false) {
        // A door action is a read when it says read:, else a write; it writes the app's own data unless it says otherwise.
        let toolClass = toolClass ?? (read ? .read : .write)
        self.id = id; self.page = AppDoorNames.resolve(page); self.label = label; self.args = args; self.owner = owner
        self.irreversible = irreversible; self.toolClass = toolClass; self.screen = screen; self.warn = warn; self.tool = tool
        self.input = input; self.rename = rename; self.read = read
        self.versionExempt = versionExempt
        self.revision = revision
        self.readWhen = readWhen
        self.returnedScope = [scope, schema.map { ToolNameAliases.foldedProse(AppActions.argumentProse($0.description, tool: tool)) } ?? ""].filter { !$0.isEmpty }.joined(separator: " ")
        self.scope = [scope, args.joined(separator: " "), schema?.description ?? "", schema.map { String(decoding: $0.parametersJSON, as: UTF8.self) } ?? ""].filter { !$0.isEmpty }.joined(separator: " ")
        self.schema = schema
        self.partAction = partAction
        self.part = part
        self.folded = folded
        self.advisory = advisory
        self.resultSchema = resultSchema
        self.lifecycle = lifecycle
        self.reach = reach
        self.capabilities = capabilities ?? (toolClass == .read ? toolClass.baseCapabilities : toolClass.baseCapabilities.union(["app_data_write"]))
    }

    /// A folded tool as an action (`ToolNameAliases.foldedTools` names its
    /// default id; a specialization declares its own id and fixed input).
    /// It runs as itself: the door re-enters under the tool's own name,
    /// so that call's gates, Trust key, cards and result are the ones that apply.
    /// Args and label left out are the tool's own: every argument its schema
    /// takes, and its description's first sentence. A script may call every
    /// action; each call retains its own gates.
    static func fold(_ tool: String, _ page: String, id: String? = nil, _ label: String? = nil, _ args: [String]? = nil,
                     input: [String: JSONValue] = [:], read: Bool = false,
                     irreversible: Bool = false, toolClass: ToolClass? = nil, reach: ToolReach = .hers, capabilities: Set<String> = ["safe_read", "tool_call"], screen: Bool = false,
                     warn: String = "", schema: LLMToolSchema? = nil, versionExempt: Bool = false,
                     readWhen: [String: JSONValue] = [:], advisory: Bool = false,
                     resultSchema: JSONValue = AppActions.resultEnvelope, lifecycle: CapabilityLifecycle.Action? = nil) -> AppAction {
        // A fold is a read when it says read:, else a write; it carries the door's own capabilities unless it says otherwise.
        let toolClass = toolClass ?? (read ? .read : .write)
        let schema = schema ?? AppActions.foldSchemas[tool]
        // Its args by the door's names (`ToolNameAliases.doorArgNames`), each renamed back as it runs.
        let names = ToolNameAliases.doorArgNames[tool] ?? [:]
        func door(_ arg: String) -> String {
            let end = arg.firstIndex { $0 == "?" || $0 == ":" } ?? arg.endIndex
            return (names[String(arg[..<end])] ?? String(arg[..<end])) + arg[end...]
        }
        return AppAction(id ?? ToolNameAliases.appAction(tool) ?? tool, page,
                         label ?? schema.map { AppActions.firstSentence(ToolNameAliases.foldedProse($0.description)) } ?? tool,
                         (args ?? schema.map { ToolSignature.doorArgs($0.parametersJSON) } ?? []).map(door)
                            + (["screen", "read", "read_file", "read_page", "browser.read_text", "browser.read_links", "browser.chrome_snapshot"].contains(tool)
                               ? ["raw?:bool", "wrong?:bool", "why?"] : []),
                         irreversible: irreversible, toolClass: toolClass, reach: reach, capabilities: capabilities,
                         screen: screen, warn: warn, tool: tool, input: input,
                         rename: Dictionary(uniqueKeysWithValues: names.map { ($0.value, $0.key) }),
                         read: read, versionExempt: versionExempt, readWhen: readWhen,
                         advisory: advisory, resultSchema: resultSchema, lifecycle: lifecycle, schema: schema, folded: true)
    }

    public var isHis: Bool { if case .his = owner { true } else { false } }
    /// What running it is: a read, a folded tool's declared class, or its own.
    var reaches: ToolClass { read ? .read : folded ? schema?.toolClass ?? toolClass : toolClass }
    /// A row declares whether it runs as its tool; parts retain their own identity.
    public var isFold: Bool { folded || authored }
    /// A tool she wrote, by its own name or as a part's action: a program, not a native call.
    public var authored: Bool { partAction || ToolNameAliases.authoredTool(id) == tool }
    /// One of an inline card's buttons, not the composer
    /// (`AppToolExecutor.runCardAction`).
    public var isCard: Bool { tool == "interaction_act" && input["target"] == nil }
    var isItemRead: Bool { tool == "app_page_read" && input["item"] != nil }

    /// Declared credential args (`:secret`). SecurityCenter's records and the
    /// transcript redact them; typed text is redacted at the injection boundary.
    public var secretArgs: [String] {
        zip(args, argSpecs).filter { $0.0.hasSuffix(":secret") }.flatMap { $0.1.names }
    }

    public var binding: AppActionBinding {
        AppActionBinding(isHis: isHis, irreversible: irreversible, read: read, secretArgs: secretArgs,
                         readWhen: readWhen, lifecycle: lifecycle,
                         tool: tool, fixedInput: input, rename: rename, folded: isFold,
                         descriptor: schema.map { ToolDescriptor(schema: $0, bucket:
                             SwiftToolDispatcher.catalogBucket(forRegisteredToolNamed: tool) ?? AppToolExecutor.buckets[tool] ?? .unclassified) },
                         toolClass: toolClass, reach: reach, capabilities: capabilities)
    }

    func readOnly(args: [String: JSONValue]) -> Bool { binding.readOnly(args: args) }

    /// `effect` is "part" for a call that ran one of her parts (a tool she
    /// wrote, a part's action, a skill's run): her turn tells hand work by it.
    /// A part's run that reports its calls is irreversible only if one of them
    /// was; the declaration's prior is for gating, not for what happened.
    func effectFields(args: [String: JSONValue] = [:], result: [String: JSONValue] = [:]) -> [String: JSONValue] {
        let read = readOnly(args: args)
        var irreversible = irreversible
        if part != nil || authored, case .array(let calls)? = result["calls"] {
            irreversible = calls.contains { if case .object(let call) = $0 { call["irreversible"] == .bool(true) } else { false } }
        }
        return ["read_only": .bool(read), "irreversible": .bool(irreversible),
                "effect": .string(part != nil || authored ? "part" : read ? "read" : irreversible ? "irreversible" : "write")]
    }

    /// `id(args) label`, then what User needs to know about it.
    public var line: String {
        var text = "\(id)(\(args.joined(separator: ", "))) \(label)"
        if screen { text += " · screen" }
        if irreversible { text += " · irreversible" }
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
    public static var all: [AppAction] { available(dataRoot: PersistenceCore.defaultDataRoot()) }

    private static func available(dataRoot: URL) -> [AppAction] {
        let peers = (try? AgentPeerStore(dataRoot: dataRoot).list()) ?? []
        return seedActions.compactMap { action in
            guard let handle = ToolNameAliases.agentHandle(action.tool) ?? (action.tool == "claude_worklog" ? "claude" : nil) else { return action }
            guard let who = peers.first(where: { ($0.handles ?? []).contains(handle) }),
                  AgentConversationDelivery.lane(for: "peer:" + who.id, dataRoot: dataRoot) != nil else { return nil }
            if action.read {
                return AppAction(action.id, action.page, "Read \(who.name)'s worklog, newest first", action.args,
                    toolClass: action.toolClass, reach: action.reach, capabilities: action.capabilities, warn: action.warn, tool: action.tool, read: true)
            }
            return AppAction(action.id, action.page, "Message \(who.name)",
                ["text", "conversation?", "new_conversation?:bool", "expects_reply?:bool", "options?:object"],
                toolClass: action.toolClass, reach: action.reach, capabilities: action.capabilities, tool: "agent_message", input: ["agent": .string(handle)], schema: foldSchemas["agent_message"],
                folded: true)
        }
    }

    private static let seedActions: [AppAction] = [
        AppAction("chrome.history", "browser", "Read Chrome history: top domains, title/URL search or recent pages",
                  ["mode", "query?", "since?", "limit?:int"],
                  warn: "mode: top_domains (since required), search (query required, since optional) or recent. since: inclusive ISO 8601 with timezone. limit: default 15, max 50. Chrome Default profile only, independent of extension/tab group; local ISO 8601 times. Domain counts: visits since since; page counts: lifetime visits. Requires Full Mac and file-read permission; no card. Deadline: 2 seconds.",
                  tool: "read_file", read: true),
        AppAction("photos.count", "files", "Count Photos assets by creation date and media type",
                  ["start?", "end?", "media_type?"],
                  warn: "start/end: ISO 8601 with timezone, start inclusive/end exclusive. media_type: all (default), image or video. Requests macOS Photos access on call; limited access counts only shared assets.",
                  tool: "photos_read", input: verb("count"), read: true),
        AppAction("photos.recent", "files", "Read newest Photos metadata: creation date, media type, dimensions, favorite and stored location coordinates",
                  ["limit?:int", "start?", "end?", "media_type?"],
                  warn: "limit: 1–100, default 10, newest creation first. start/end: ISO 8601 with timezone, start inclusive/end exclusive. media_type: all (default), image or video. Metadata only; requests macOS Photos access on call.",
                  tool: "photos_read", input: verb("recent"), read: true),
        // Today's Inbox: the notes Today and the Desk count. Each id is the
        // word on the note's button; a note read lists its buttons as these ids.
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

        // Chat: the sidebar and the conversation's own controls.
        // An idempotent append through Reach's owner, independent of a page version.
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
        // Irreversible (flag audit, 10-02): the queued message is dropped from
        // memory, and nothing keeps User's words to bring back.
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
        // What she makes, in versions; the Work pane's Make tab shows them.
        // Version-exempt: add only appends a version, and never touches one.
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
        AppAction("sense.make", "chat", "Learn to read a file format (including binary), app or page so ordinary reads work. code: complete sense.js; kit: Contents/Resources/Senses in the app bundle (AUTHORING.md, starter sense.js, builtin/app.js, builtin/site.js). Runs on the last-read place or place corner key; returns its page and trial_id/digest. Keep that exact trial with {trial_id,digest,keep:true}, no code. {code,keep:true} runs and keeps immediately. {show:\"material\"}, no code, returns sense.source.read() exactly",
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
        // How the window lays out each surface (ui/layout.json), hers to read
        // and rewrite as the person asks; the window changes as a write lands.
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
        // Inline cards, by the interaction id the chat read or the card's inbox
        // note lists, in whichever conversation raised them. Whose card it is
        // and what it moves are decided per card:
        // a card from User's phone or Telegram, or one that raises what you may
        // reach below Full Mac, stays his and says so.
        // Irreversible (flag audit, 10-02): the card's own button does what it
        // asked, as inbox.approve does, and nothing presses it back.
        AppAction("permissions.request", "chat", "Ask for a macOS permission in your own words", ["capability", "why", "mode?"],
                  capabilities: ["safe_read", "tool_call"], warn: "capability: \(SystemPermissionCapability.requestable); Automation: applescript:<bundle_id>. Only the person taps Allow on the Mac; the waiting work continues after the grant.",
                  tool: "request_interaction", input: ["kind": .string("permission")], folded: true),
        AppAction("card.answer", "chat", "The card's own button (its Do: line)", ["id", "value?:secret", "choice?"],
                  irreversible: true, capabilities: ["app_data_write", "safe_read", "tool_call"], warn: "never ask the owner for a key or token in chat: they type it into the card",
                  tool: "interaction_act", input: card("primary"), rename: ["id": "interaction_id"]),
        AppAction("card.not_now", "chat", "Not now", ["id", "reason?"], irreversible: true, capabilities: ["app_data_write", "safe_read", "tool_call"], tool: "interaction_act",
                  input: card("decline"), rename: ["id": "interaction_id"]),
        // Irreversible (flag audit, 10-02): it runs the card's own control as
        // card.answer does, a capability grant included.
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
        // Irreversible (flag audit, 10-02): a real message to User's Telegram.
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
        AppAction("memory.consolidate", "memories", "Consolidate now", tool: "upkeep", input: verb("consolidate_now")),
        AppAction("memory.hygiene", "memories", "Hygiene now", tool: "upkeep", input: verb("hygiene_now")),
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
                  // Not version-exempt: a text rewrite or a restore can overwrite
                  // another conversation's correction. The supersede demotion
                  // is memory.commit's supersedes, which is.
                  tool: "rewrite_memory"),
        AppAction("memory.pin", "memories", "Pin a fact about the owner (user fact, preference, relationship, identity, attribute) to your prompt core, in pin order; moments stay in recall", ["id"],
                  capabilities: ["memory_write", "tool_call"], tool: "rewrite_memory", input: ["pinned": .bool(true)]),

        // Her mind: Dreams (Personality), Self-Improvement (Today),
        // the Observatory (Diagnostics → Cognition).
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
        AppAction("mind.pin_concern", "diagnostics", "Keep a concern open in your cares; omitted concern uses what presses most", ["concern?"], tool: "mind_run", input: verb("pin_concern")),
        AppAction("mind.run_checks", "diagnostics", "Run checks", tool: "mind_run", input: verb("run_checks")),
        AppAction("mind.export_trace", "diagnostics", "Export trace", tool: "mind_run", input: verb("export_trace")),
        AppAction("mind.leave_workspace_out", "diagnostics", "Leave your workspace out of your thinking", tool: "mind_run",
                  input: verb("ablate_workspace")),
        AppAction("mind.include_workspace", "diagnostics", "Include your workspace in your thinking again", tool: "mind_run",
                  input: verb("include_workspace")),
        AppAction("mind.clear", "diagnostics", "Clear the thought store",
                  irreversible: true, capabilities: ["app_data_write", "safe_read", "tool_call"], tool: "mind_run", input: verb("clear")),

        // Her parts (docs/AGENT_IS_THE_APP.md): what a part can do is what it
        // declares, never which door made it. One save, one keep, one run
        // (authored.<id>), one read, one lifecycle; ability_manage runs them all.
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
        AppAction("ability.list", "tools", "Your abilities, one row each, and the built-in guidance to read", tool: "ability_manage", input: verb("list"), read: true),
        AppAction("ability.validate", "tools", "Validate an unkept version on supplied input or one captured run; intercepted replies prove no live behavior",
                  ["id", "input?:object", "capture?:bool"], tool: "ability_manage", input: verb("validate"), lifecycle: .change),
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
                  ["run_id", "answer?:any"], warn: "The stopped step returns answer. Any journal call beginning with primitive blocks resume. Before starting a fresh run, inspect prior calls and effects: a fresh run executes from the beginning and may repeat effects; pass the answer as input and account for completed work.",
                  tool: "ability_manage", input: verb("resume"), part: ""),

        // The Desk.
        AppAction("desk.deny", "desk", "Deny", ["id", "reason?"], irreversible: true,capabilities: ["safe_read", "tool_call", "workshop_write"], tool: "workshop_reject"),
        AppAction("desk.approve", "desk", "Approve", ["id"], owner: .his("approving a waiting step is his; the Desk"),
                  tool: "workshop_reject", input: decision("approve")),

        // MY QUEUE (Wave 2 #7): steps she means to do later, kept on her Desk
        // until she marks each done or dropped.
        // Version-exempt: done and drop close the one step their id names, and
        // a second close finds it no longer open and changes nothing.
        // add (decided 10-02, PR 4): it appends, a new step, or a newer step
        // ref on the open step with the same words (MyQueue.add keeps the old
        // ref, newest wins), and the same call again changes nothing.
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
        // User 10-18: a repair she owes settles when that operation works again, or here, with why.
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

        // Her own state (phase 2 step 2): the Desk, its task ledger, Workshop
        // and schedules; memory; helpers; persona and skills; studio and mind.
        .fold("desk_read", "desk", "Your Desk: open items with status, cadence and refs, newest active first; "
              + "handle reads one item whole, query searches every live item, updated_on filters today or YYYY-MM-DD", read: true),
        .fold("desk_add_item", "desk"),
        .fold("desk_note", "desk"),
        .fold("desk_set_status", "desk"),
        .fold("desk_set_status", "desk", id: "desk.wait", "Wait until the named Desk items or experiences settle", ["handle", "on:any", "why?"],
              input: ["wait": .bool(true)]),
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
        .fold("task_ledger_list", "desk", read: true),
        .fold("task_ledger_post", "desk"),
        .fold("workshop_status", "desk", read: true),
        .fold("workshop_submit", "desk"),
        .fold("scheduler_list_jobs", "desk", read: true),
        .fold("scheduler_create_job", "desk"),
        .fold("scheduler_update_job", "desk"),
        .fold("scheduler_pause_job", "desk"),
        .fold("scheduler_resume_job", "desk"),
        .fold("scheduler_cancel_job", "desk", "Cancel future runs; keep history and allow schedule.resume; running work continues"),
        .fold("scheduler_delete_job", "desk", "Cancel future runs; keep history and allow schedule.resume; running work continues"),
        .fold("recall_memory", "memories", "Recall saved facts, decisions and preferences; use studio.recall for journal entries", read: true, advisory: true),
        // Version-exempt: it appends a new memory; supersedes demotes the ids it
        // names, which a repeat leaves demoted.
        .fold("commit_memory", "memories", "Save a fact, decision or preference for later recall. text is the thing "
              + "itself, plain: no dates, sources, ids or 'note:' framing. Keep the complete current decision first. "
              + "For a changed agreement, recall its subject's existing rules; supersedes names the ids it replaces. "
              + "context_topics declares subject/scope and returns matching agreements for your judgment, never authority",
              versionExempt: true),
        .fold("memory_moments_pending", "memories", read: true),
        .fold("memory_moment_review", "memories"),
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
        .fold("bot_pause", "bots"),
        .fold("bot_delete", "bots"),
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
        // How each agent is reached (agents/recipes/<host>.json), hers to read and
        // fix when an app changes under it. A write is connect-level: below Full
        // Mac its card is connect's (other_app_settings_write).
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
        .fold("mail_senders", "mail", read: true),
        .fold("mail_triage_batch", "mail"),
        .fold("mail_mark_read", "mail"),
        .fold("mail_archive", "mail"),
        .fold("mail_delete", "mail", irreversible: true),
        .fold("mail_send", "mail", irreversible: true),
        .fold("mail_reply", "mail", irreversible: true),
        .fold("mail_draft", "mail"),
        .fold("mac_calendar_list_upcoming", "calendar", read: true),
        .fold("mac_calendar_calendars", "calendar", read: true),
        .fold("mac_calendar_free_busy", "calendar", read: true),
        .fold("mac_calendar_create_event", "calendar"),
        .fold("mac_calendar_modify_event", "calendar"),
        .fold("mac_calendar_delete_event", "calendar", irreversible: true),
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
        .fold("mac_notify", "notifications"),
        .fold("mobile_notify", "notifications"),
        .fold("phone_request", "pairing"),
        // Reading where the paired iPhone is changes nothing: a read of its own,
        // so a part that only looks (weather) stays a read. Its wait is a phone
        // that is open: a push, the person's tap, a fix and the Mac's 8-second
        // drain while the request is out; not a minute for one that is not.
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
        .fold("read_page", "web", read: true),
        .fold("web_search", "web", read: true),
        .fold("maps_route", "web", read: true),
        .fold("maps_search", "web", read: true),
        .fold("browser.status", "browser", read: true),
        .fold("browser.open_url", "browser"),
        .fold("browser.read_text", "browser", read: true),
        .fold("browser.read_links", "browser", read: true),
        .fold("browser.screenshot", "browser"),
        .fold("browser.chrome_setup", "browser"),
        .fold("browser.chrome_status", "browser", read: true),
        .fold("browser.chrome_snapshot", "browser", read: true),
    ] + ToolNameAliases.chromeVerbs.filter { $0 != "snapshot" }.map { .fold("browser.chrome_" + $0, "browser", read: $0 == "wait") } + [
        .fold("search_chat_history", "chat", read: true),
        .fold("read_chat_message", "chat", read: true),
        .fold("chat_reply", "chat"),
        .fold("tool_result_page", "*", "Page a long result retained this turn without rerunning its action; continue:true resumes the last read and ignores page; omit continue to select page/query/raw", read: true),

        // Mac control and the tools left over (phase 2 step 6). Each Mac verb
        // re-enters under its own name, so Full Mac's accessibility category,
        // MacAttention and User's saved levels judge it as before.
        // act's whole guide is an item read on the mac page (`guided`); its refusals point to it.
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
        .fold("system_info", "mac", "Read system, network and battery information", read: true),
        AppAction("mac.apps", "mac", "List installed apps or check one by name; returns name, bundle ID, path, version and scriptability", ["name?", "all?:bool"],
                 tool: "mac_apps", read: true, scope: "installed apps applications what apps do I have; name: optional substring filter"),
        .fold("mac_screenshot_save", "mac"),
        .fold("mac_location", "mac", "Where this Mac is", read: true),
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
    /// out (a flow's steps carry their own). The recursive credential detector
    /// judges typed text, including text/value inside flow steps.
    static let actArgs = foldSchemas["act"].map {
        ToolSignature.doorArgs($0.parametersJSON).map {
            ["verb", "target"].contains($0) ? $0 + "?" : $0
        }
    }

    /// Guides that carry their arguments' own words. Every folded action's
    /// guide is an item read (guide:<id>) its refusals point to.
    public static let guided: Set<String> = ["mac.act", "files.read", "result.page", "memory.commit", "chat.new", "chat.list"]

    private static let guideArgs: [String: Set<String>] = ["files.read": ["offset", "version"],
        "result.page": ["continue"], "memory.commit": ["provenance", "provenance_by"]]

    private static func argumentGuide(_ action: AppAction, schema: LLMToolSchema) -> [String] {
        let lines = ToolSignature.params(schema.parametersJSON, limit: .max)
        guard let names = guideArgs[action.id] else { return guided.contains(action.id) ? lines : [] }
        return lines.filter { names.contains(String($0.prefix { $0 != ":" })) }
    }

    /// Each tool she wrote that is active in her registry, as
    /// `authored.<id>` on its face page (diagnostics by default), flagged by the
    /// dependencies' canonical action flags, or its schema without dependencies.
    /// Admitted tools are scriptable; each call retains its ordinary gates.
    /// Conditional reads are changing dependencies: tool code chooses their args.
    public static func authored(dataRoot: URL = PersistenceCore.defaultDataRoot()) -> [AppAction] {
        authored(dataRoot: dataRoot, catalog: all + senses(), tools: SwiftToolDispatcher.authoredTools(dataRoot: dataRoot))
    }

    private static func authored(dataRoot: URL, catalog: [AppAction],
                                 tools: [(schema: LLMToolSchema, permissions: [String], actions: [String], page: String?, action: String?)]) -> [AppAction] {
        let tools = tools.filter { tool in
            tool.action.map { id in !catalog.contains { $0.id == id } } ?? true
        }
        let toolsByID = Dictionary(tools.map { ($0.action ?? ToolNameAliases.authoredAction($0.schema.name), $0) },
                                   uniquingKeysWith: { first, _ in first })
        // This pass owns all memoized results. Resolve strongly connected tools
        // together so a back edge cannot hide another member's screen effects.
        var classified = Dictionary(catalog.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        let dependenciesByID = toolsByID.mapValues { tool in
            tool.actions.map { dependency in
                let key = dependency.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
                if classified[key] != nil || toolsByID[key] != nil { return key }
                // An older door classifies as the one form's door that answers it;
                // skill.run is a part's run, as ability.resume is.
                if let alias = AppToolExecutor.partAlias(key, [:], root: dataRoot) {
                    let target = alias.id == "authored." ? "ability.resume" : alias.id
                    if classified[target] != nil || toolsByID[target] != nil { return target }
                }
                return toolsByID.first { ToolNameAliases.authoredTool(key) == $0.value.schema.name }?.key ?? key
            }
        }
        var indices: [String: Int] = [:]
        var lowLinks: [String: Int] = [:]
        var stack: [String] = []
        var visiting: Set<String> = []
        func classify(_ id: String) {
            guard classified[id] == nil, indices[id] == nil, toolsByID[id] != nil else { return }
            let index = indices.count
            indices[id] = index
            lowLinks[id] = index
            stack.append(id)
            visiting.insert(id)
            for dependency in dependenciesByID[id]! {
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
            let cyclic = members.count > 1 || dependenciesByID[id]!.contains(id)
            let dependencies = members.flatMap { dependenciesByID[$0]! }
                .filter { !memberIDs.contains($0) }.map { classified[$0] }
            let dependenciesRead = dependencies.allSatisfy { $0?.read == true }
            let dependenciesIrreversible = dependencies.contains { $0?.irreversible == true }
            let dependenciesScreen = dependencies.contains { $0?.screen == true }
            let authoredIrreversible = members.contains {
                !Set(toolsByID[$0]!.permissions).isDisjoint(with: ["shell", "arbitrary_file_write"])
            }
            // A part is the most any call or permission it declares reaches.
            let reach = (dependencies.map { $0?.reaches ?? .write }
                + members.flatMap { toolsByID[$0]!.permissions }.map(PermissionLaw.permissionClass)).max() ?? .read
            // Its reach to User's side from the same manifest: what it declares
            // beyond her own data and model, or a dependency that changes his
            // side (a missing one, a part that does, a folded tool outside her
            // core); a read dependency changes nothing.
            let reachesHim = dependencies.contains { dependency in
                guard let dependency else { return true }
                if dependency.read { return false }
                if dependency.authored { return dependency.reach == .his }
                guard dependency.isFold else { return false }
                return ![.core, .alwaysOn, .browser].contains(dependency.binding.descriptor?.bucket ?? .unclassified)
            } || PermissionLaw.reach(ofPermissions: members.flatMap { toolsByID[$0]!.permissions }) == .his
            // Unavailable or cyclic dependencies cannot certify a read.
            for member in members {
                let tool = toolsByID[member]!
                let declaredRead = if case .object(let schema)? = try? JSONValue.parse(tool.schema.parametersJSON) { schema["readOnly"] == .bool(true) } else { false }
                let read = !cyclic && !authoredIrreversible && (dependenciesByID[member]!.isEmpty ? declaredRead : dependenciesRead)
                let schema = LLMToolSchema(name: tool.schema.name, toolClass: reach, reach: reachesHim ? .his : .hers,
                    capabilities: tool.schema.capabilities, description: tool.schema.description,
                    parametersJSON: tool.schema.parametersJSON, deferLoading: tool.schema.deferLoading)
                classified[member] = AppAction(member, tool.page ?? "diagnostics",
                             firstSentence(tool.schema.description), ToolSignature.doorArgs(tool.schema.parametersJSON),
                             irreversible: cyclic || dependenciesIrreversible || authoredIrreversible,
                             toolClass: reach, reach: reachesHim ? .his : .hers,
                             capabilities: ["safe_read", "tool_call"], screen: dependenciesScreen,
                             warn: "Resolved class: \(reach); reach: \(reachesHim ? "his" : "hers") (includes action dependencies). Declared primitives: "
                                + (tool.permissions.isEmpty ? "none" : tool.permissions.joined(separator: ", "))
                                + "; actions: " + (tool.actions.isEmpty ? "none" : tool.actions.joined(separator: ", ")),
                             // It executes its pinned contract, not a diagnostics-page edit.
                             tool: tool.schema.name, read: read, versionExempt: true, schema: schema, partAction: tool.action != nil,
                             folded: false)
            }
        }
        for id in toolsByID.keys { classify(id) }
        return toolsByID.keys.sorted().compactMap { classified[$0] }
    }

    /// Switched-off abilities remain readable, without runnable suggestions.
    static func disabledTools(_ asked: [String], dataRoot: URL) throws -> [JSONValue] {
        let states: Set<String> = ["off", "disabled", "stopped"]
        guard asked.contains(where: states.contains) else { return [] }
        let subject = asked.filter { !states.contains($0) }
        guard case .array(let rows) = try AbilityStore(dataRoot: dataRoot).registry(kind: .part) else { return [] }
        return rows.compactMap { value in
            guard case .object(let row) = value, row["status"] == .string("disabled"),
                  case .string(let id)? = row["id"] else { return nil }
            let description: String = if case .string(let text)? = row["description"] { text } else { "" }
            guard subject.isEmpty || hits(Set(intentWords("authored tools abilities " + id + " " + description)), subject) > 0 else { return nil }
            return .object(["page": .string("tools"), "item": .string(id), "status": .string("disabled"),
                "runnable": .bool(false), "description": .string(description)])
        }
    }

    /// The folded tools' own schemas, built once: a fold's args and label are
    /// its tool's, and its whole description answers a call that went wrong.
    static let foldSchemas: [String: LLMToolSchema] = Dictionary(uniqueKeysWithValues:
        SwiftToolDispatcher.nativeToolDescriptors.values.filter { ToolNameAliases.foldedTools[$0.name] != nil }
            .map { ($0.name, $0.schema) } + AppToolExecutor.appToolSchemas(includeDoor: false).map { ($0.name, $0) })

    /// Project parameter references once, using the door's accepted names.
    /// Common words such as "by name" or "a path" retain their prose meaning.
    static func argumentProse(_ text: String, tool: String) -> String {
        if let names = ToolNameAliases.doorArgNames[tool] {
            let words = try! NSRegularExpression(pattern: #"\b[a-z][a-z0-9_]*\b"#)
            let result = NSMutableString(string: text)
            for match in words.matches(in: text, range: NSRange(text.startIndex..., in: text)).reversed() {
                let range = Range(match.range, in: text)!
                let key = String(text[range])
                if let name = names[key] {
                    let before = text[..<range.lowerBound], after = text[range.upperBound...]
                    let quoted = (before.last == "\"" && after.first == "\"")
                        || (before.last == "`" && after.first == "`")
                    let argument = quoted || after.hasPrefix(":") || after.hasPrefix("=")
                        || after.hasPrefix(" only (") || after.hasPrefix(" peer:")
                    if !["name", "path"].contains(key) || argument {
                        result.replaceCharacters(in: match.range, with: name)
                    }
                }
            }
            return result as String
        }
        return text
    }

    /// A folded tool's whole description, its old tool names read as action
    /// ids. A guided action's
    /// carries every argument's own words too.
    public static func about(_ action: AppAction) -> String? {
        guard action.isFold else { return nil }
        guard let schema = schema(action) else { return nil }
        let lines = argumentGuide(action, schema: schema)
        let args = lines.isEmpty ? "" : "\nArgs:\n" + lines.joined(separator: "\n")
        return ToolNameAliases.foldedProse(argumentProse(schema.description + args, tool: action.tool))
    }

    static func schema(_ action: AppAction, dataRoot root: URL = PersistenceCore.defaultDataRoot()) -> LLMToolSchema? {
        return action.binding.descriptor?.schema ?? foldSchemas[action.tool]
            ?? (!action.partAction && ToolNameAliases.authoredTool(action.id) == nil ? nil
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
        // An argument whose schema takes a list is never fanned out: a list
        // there is one value, well-formed or not, so a malformed one is refused
        // whole by the door's validation instead of running element by element
        // (10-17, menu_press path ["File > Close", 7] pressed File > Close first).
        func takesList(_ schema: JSONValue) -> Bool {
            guard case .object(let property) = schema else { return false }
            if property["type"] == .string("array") { return true }
            if case .array(let types)? = property["type"], types.contains(.string("array")) { return true }
            for key in ["anyOf", "oneOf", "allOf"] {
                if case .array(let variants)? = property[key], variants.contains(where: takesList) { return true }
            }
            return false
        }
        return properties.keys.filter { !action.secretArgs.contains($0) && scalar(properties[$0]!) && !takesList(properties[$0]!) }.sorted()
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
            "irreversible": .bool(action.irreversible), "owner": .bool(action.isHis)])
    }

    /// The current contract still accepts every call the saved one did: all
    /// else equal, each saved argument kept with its schema, nothing newly
    /// required. A new optional argument fits; a removed, retyped or newly
    /// required one does not.
    static func acceptsEveryCall(_ current: JSONValue, of saved: JSONValue) -> Bool {
        guard case .object(var now) = current, case .object(var was) = saved,
              case .object(var nowArgs)? = now.removeValue(forKey: "args_schema"),
              case .object(var wasArgs)? = was.removeValue(forKey: "args_schema") else { return false }
        // Saved contracts can predate unconditional script callability.
        was.removeValue(forKey: "scriptable")
        guard now == was,
              case .object(let nowProperties)? = nowArgs.removeValue(forKey: "properties"),
              case .object(let wasProperties)? = wasArgs.removeValue(forKey: "properties"),
              case .array(let nowRequired)? = nowArgs.removeValue(forKey: "required"),
              case .array(let wasRequired)? = wasArgs.removeValue(forKey: "required"), nowArgs == wasArgs else { return false }
        return wasProperties.allSatisfy { nowProperties[$0.key] == $0.value } && nowRequired.allSatisfy(wasRequired.contains)
    }

    static func legacyDependencyContract(_ shape: JSONValue) -> JSONValue? {
        guard case .object(var fields) = shape, case .object(let discovery)? = fields.removeValue(forKey: "discovery"),
              case .object(let example)? = discovery["example"], case .string(let id)? = example["action"],
              let args = discovery["args_schema"] else { return nil }
        fields["id"] = .string(id); fields["args_schema"] = contractSchema(args)
        fields["result_schema"] = legacyResultSchema(id)
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
        "880715d531def25bd807f3ba673f786ecfa2c39b379cfe40229adba45ed41d9e": "07ef5c2e309de0c7f75a2e917a6b45fe712f49b2e1b027878123b3a878db84a6", // mac.menu, find added (accepts every earlier call)
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
                if action.id == "ability.save", name == "fixtures" {
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
        if action.id == "ability.validate", example["input"] == nil { example["input"] = .object([:]) }
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
                (action.partAction || ToolNameAliases.authoredTool(action.id) != nil))]
        if !alternatives.isEmpty { args["allOf"] = .array(alternatives) }
        let bound = action.input.filter { action.argSpecs.flatMap(\.names).contains($0.key) }
        var call: [String: JSONValue] = ["action": .string(action.id), "args": .object(example.merging(bound) { _, bound in bound })]
        if action.irreversible { call["preview"] = .bool(true) }
        var result: [String: JSONValue] = action.effectFields().merging(["page": .string(action.page), "action": .string(action.line),
            "args_schema": .object(args),
            "read_when": .object(action.readWhen),
            "example": .object(call)]) { _, value in value }
        let plural = pluralKeys(action, properties: props)
        if !plural.isEmpty, action.isFold || action.read || !action.readWhen.isEmpty {
            result["door_expansion"] = .object(["scalar_arguments": .array(plural.map(JSONValue.string)),
                "max_list_arguments": .int(1),
                "note": .string("For a folded action or read call, one eligible scalar may be a nonempty list: runs once per value with each child's validation and gates. Native array arguments stay arrays.")])
        }
        if !action.returnedScope.isEmpty { result["scope"] = .string(action.returnedScope) }
        if !action.read { result["version_note"] = .string("expected_version is optional. Chain versioned calls with the latest receipt's page_version; a change can replace the prior version.") }
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
    public static let hot = ["undo", "time.now", "context.expand", "mind.inner_state", "agent.introspect", "ability.list",
                             "ability.read", "trace.recent", "desk.read", "memory.recall", "memory.commit",
                             "bot.reply", "agent.contacts", "agent.message", "agent.read", "agent.connect",
                             "agent.jobs", "mail.recent",
                             "calendar.upcoming", "files.read", "files.list", "files.write", "chat.search",
                             "result.page", "mac.look", "mac.system_info", "mac.volume", "mac.act", "mac.go", "sense.make"].compactMap { action($0) }

    /// An action by id; a tool she
    /// wrote (`authored.<id>`) from her registry.
    public static func action(_ id: String, dataRoot: URL = PersistenceCore.defaultDataRoot()) -> AppAction? {
        let key = id.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        if let own = available(dataRoot: dataRoot).first(where: { $0.id == key }) { return own }
        if let handle = ToolNameAliases.agentHandle(key),
           let alias = available(dataRoot: dataRoot).first(where: { $0.id.split(separator: ".").first.map(String.init) == handle && $0.tool == "agent_message" }) { return alias }
        if let sense = senses().first(where: { $0.id.lowercased() == key }) { return sense }
        return authored(dataRoot: dataRoot).first(where: { $0.id.lowercased() == key || ToolNameAliases.authoredTool(key) == $0.tool })
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

    /// Every registered action: the app's own, the ones she wrote, and
    /// senses' verbs. What find ranks and `pages_version` hashes.
    static func inventory(dataRoot: URL) async throws -> (actions: [AppAction], authored: [AppAction]) {
        let records = try await SensesHub.shared.registry?.all() ?? []
        let authored = authored(dataRoot: dataRoot, catalog: all + senses(),
            tools: try SwiftToolDispatcher.checkedAuthoredTools(dataRoot: dataRoot).get())
        // The persona's built-in guidance, each found as the ability.read that opens it.
        let read = all.first { $0.id == "ability.read" }!
        let text: (JSONValue?) -> String = { if case .string(let value)? = $0 { value } else { "" } }
        let skills = try InstalledSkillInventory.entries(dataRoot: dataRoot).map { entry in
            AppAction(read.id, "skills", entry.name + ": " + text(entry.row["description"]), read.args,
                tool: read.tool, input: read.input.merging(["id": .string(entry.id)]) { _, bound in bound }, read: true)
        }
        let items = AppDoorNames.items.keys.sorted().flatMap { page in
            AppDoorNames.items[page]!.keys.sorted().filter { !$0.contains("<") }.map { item in
                AppAction(page + "/" + item, page, AppDoorNames.items[page]![item]!,
                    tool: "app_page_read", input: ["page": .string(page), "item": .string(item)], read: true)
            }
        }
        return (items + available(dataRoot: dataRoot) + authored + skills + senses(records: records), authored)
    }

    /// A page's actions: its own, and the ones on every page.
    public static func on(page: String) -> [AppAction] {
        let page = AppDoorNames.resolve(page)
        return on(page: page, authored: authored())
    }

    static func on(page: String, authored: [AppAction]) -> [AppAction] {
        let page = AppDoorNames.resolve(page)
        return all.filter { $0.page == page || $0.page == "*" }
            + authored.filter { $0.page == page || page == "tools" } + senses().filter { $0.page == page }
    }

    /// The action ids the words name as they stand ("mac.menu_press").
    static func named(_ text: String) -> Set<String> {
        Set(text.lowercased().split(whereSeparator: { $0.isWhitespace || ",;!?()".contains($0) }).map(String.init))
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

    private static let negation = try! NSRegularExpression(
        pattern: #"(?i)\b(?:no|without|never|avoid|do\s+not|don['’]t|not)(?!\s+only\b)\s+(.+?)(?=[,.;!?\n]|\s+\b(?:but|instead|however|then)\b|$)"#)

    /// `degraded` says why the ranking fell back to words alone; nil when the embedder ranked it.
    static func ranked(_ query: String, pages: [String: QuietToolPage], dataRoot: URL, memory: SwiftNativeMemoryV2,
                       inventory snapshot: (actions: [AppAction], authored: [AppAction])? = nil)
        async throws -> (actions: [AppAction], degraded: String?) {
        let range = NSRange(query.startIndex..., in: query)
        let negative = negation.matches(in: query, range: range).compactMap {
            Range($0.range(at: 1), in: query).map { String(query[$0]) }
        }
        let positive = negation.stringByReplacingMatches(in: query, range: range, withTemplate: "")
        let asked = intentWords(positive)
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
        let checked: (actions: [AppAction], authored: [AppAction])
        if let snapshot { checked = snapshot } else { checked = try await inventory(dataRoot: dataRoot) }
        let actions = checked.actions
            .filter { window || !(photos || mailContent) || !["mac.look", "mac.go"].contains($0.id) }
            // "open … in chrome" is her own Chrome tab while its link is up, not User's front window (10-08).
            .filter { window || !chromeOpen || $0.id != "mac.go" }
            .filter { !(mailAsk || mailDraft) || $0.id != "bot.reply" }
            .filter { !systemUpdates || $0.id != "app.check_updates" }
            .filter { window || reminderListAction.isEmpty || !["mac.look", "mac.go", "mac.act"].contains($0.id) }
        let texts = actionTexts(actions, pages: pages, contacts: contacts, helpers: helpers)
        let rejected = negative.map(intentWords)
        let named = named(positive)
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
        if hits(["ability", "abilities", "skill", "skills", "part", "parts"], asked) > 0, hits(["run", "execute"], asked) > 0 { routed.insert("ability.list") }
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
            action.id == reminderListAction || (sentTexts && action.id == "messages.recent") || (chromeHistory && action.id == "chrome.history") || action.id == mapsAction || action.id == photosAction || (weather && action.id == "weather.forecast") || (timer && action.id == "schedule.create") || (reminder && action.id == "reminders.create") || (ownActions && action.id == "trace.recent") || (usage && action.id == "trace.usage") || (mailDraft && action.id == "mail.draft") || action.id == mailAttachmentAction || (mailSenders && action.id == "mail.senders") ? 2.0
                : named.contains(action.id) || routed.contains(action.id) ? 1.0 : 0
        }
        // No embedder (or it changed mid-read): rank by words alone, and say so.
        func rankingFailure(_ detail: String) -> String {
            AgentWorkspacePorts.readFailure(ToolFailureError(detail, effects: .none, code: "action_ranking_unavailable"),
                reason: "action_ranking_unavailable", remedy: Repair.reconcile(
                    instruction: "Use the lexical matches. Read settings for memory search model status and repair the reported model or action-index fault before relying on semantic ranking.",
                    nextCall: .object(["tool": .string("app"), "input": .object(["page": .string("settings")])])))
        }
        var embedding: (asked: [[Float]], actions: [[Float]])?
        var degraded: String?
        do {
            let indexed = try await memory.indexedActionVectors(texts)
            let embedded = try await memory.embedForDerivedContextWithEpoch([positive] + negative)
            if embedded.epoch == indexed.epoch, embedded.vectors.count == negative.count + 1,
               indexed.vectors.count == actions.count,
               (embedded.vectors + indexed.vectors).allSatisfy({
                   $0.count == embedded.vectors[0].count && !$0.isEmpty
                       && $0.allSatisfy(\.isFinite) && $0.contains(where: { $0 != 0 })
               }) {
                embedding = (embedded.vectors, indexed.vectors)
            } else {
                await memory.requestActionIndexUpdate()
                degraded = rankingFailure("Action-index and query epochs differ or vectors are unusable. An index update was requested.")
            }
        } catch { degraded = rankingFailure(error.localizedDescription) }
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
            value += Double(hits(ownWords(action), asked)) / Double(max(1, asked.count))
            if value > 0 { ranked.append((offset, action, value)) }
        }
        return (ranked.sorted { $0.score == $1.score ? $0.offset < $1.offset : $0.score > $1.score }.map(\.action),
                degraded)
    }

    /// The same exact text feeds launch/change indexing and query ranking.
    static func actionTexts(_ actions: [AppAction], pages: [String: QuietToolPage],
                            contacts: [String], helpers: [String]) -> [String] {
        actions.map { action in
            let names = ["agent.message", "agent.read"].contains(action.id) ? contacts
                : (["bot.ask", "bot.list"].contains(action.id) ? helpers : [])
            return [firstSentence(ToolNameAliases.foldedProse(action.schema?.description ?? foldSchemas[action.tool]?.description ?? action.label)),
                    action.id.replacingOccurrences(of: ".", with: " "), action.label,
                    action.scope, pages[action.page]?.title ?? action.page, pages[action.page]?.summary ?? "",
                    action.argSpecs.flatMap(\.names).joined(separator: " "),
                    names.joined(separator: ", ")].joined(separator: " ")
        }
    }

    /// The actions find matches, best first, each id once; item reads are its read_next.
    static func matchedActions(_ ranked: [AppAction]) -> [AppAction] {
        var seen = Set<String>()
        return ranked.filter { !$0.isItemRead && seen.insert($0.id).inserted }
    }

    /// Her own parts, one line each, newly kept first and then the rest,
    /// each group ordered by find's ranking for `message`, within
    /// a small budget: her body in front of her at the start of every turn.
    static func parts(_ message: String, pages: [String: QuietToolPage], dataRoot: URL, memory: SwiftNativeMemoryV2) async -> String {
        /// What she calls to run it: its own action.
        func call(_ action: AppAction) -> String? { action.authored ? action.id : nil }
        do {
            let snapshot = try await inventory(dataRoot: dataRoot)
            let own = snapshot.actions.compactMap { action in call(action).map { ($0, action) } }
            if own.isEmpty {
                return try AbilityStore(dataRoot: dataRoot).files(kind: .part).isEmpty
                    ? "Your abilities: no saved abilities."
                    : "Your abilities: none callable. Read ability.list for saved versions and their status."
            }
            let (ranked, degraded) = try await ranked(message, pages: pages, dataRoot: dataRoot, memory: memory, inventory: snapshot)
            let rank = Dictionary(ranked.compactMap(call).enumerated().map { ($1, $0) }, uniquingKeysWith: { first, _ in first })
            let kept = try keptParts(dataRoot)
            func fresh(_ action: AppAction) -> KeptPart? { kept[action.tool] }
            let ordered = own.enumerated().sorted {
                (fresh($0.element.1) == nil ? 1 : 0, rank[$0.element.0] ?? .max, $0.offset)
                    < (fresh($1.element.1) == nil ? 1 : 0, rank[$1.element.0] ?? .max, $1.offset)
            }.map(\.element)
            /// Its line: how to run it, and, when every line has room, how to read its code.
            func line(_ call: String, _ action: AppAction, reads: Bool) -> String {
                return "- " + (fresh(action).map { $0.mark + ": " } ?? "") + call + (reads ? " (read: ability.read " + action.tool + ")" : "")
                    + " — " + String(firstSentence(action.schema?.description ?? action.label).prefix(100))
            }
            var text = "Your abilities, newly kept first; best match within each group:" + (degraded.map { " Ranked by words only: " + $0 } ?? "")
            let reads = ordered.reduce(text.count) { $0 + 1 + line($1.0, $1.1, reads: true).count } <= 900
            let lines = ordered.map { (fresh($0.1), line($0.0, $0.1, reads: reads)) }
            var shown: [KeptPart] = []
            for (count, (part, line)) in lines.enumerated() {
                if text.count + line.count > 900 { text += "\n+\(lines.count - count) more (find)"; break }
                text += "\n" + line
                if let part { shown.append(part) }
            }
            // Only what this fact carried counts as shown; a part cut off stays new.
            do { try acknowledge(shown, dataRoot) }
            catch {
                let state = AbilityStore(dataRoot: dataRoot).root.appendingPathComponent("state.json")
                let failure = ToolFailureError("The abilities above were read, but saving their shown markers failed: \(error.localizedDescription) Some markers may already be saved; entries may appear new again.",
                    effects: .unknown, code: "ability_shown_write_failed")
                text += "\n" + AgentWorkspacePorts.readFailure(failure, reason: "ability_shown_write_failed",
                    remedy: Repair.remedy(owner: state.path,
                        nextCall: nil, tap: nil,
                        instruction: ToolFailureError.fileRepairInstruction(state,
                            shape: "It holds ability run accounting. Preserve all run evidence and keptAfter stamps. Reconcile shown markers only from retained turn evidence; never invent markers, reset accounting or change ability authority.")
                            + " Inspect and repair the shown-marker write failure, preserving run accounting and any markers already saved."))
            }
            return text
        } catch {
            return "Your abilities could not be read: " + AgentWorkspacePorts.readFailure(error,
                reason: "ability_inventory_unavailable", remedy: Repair.remedy(owner: "ability inventory",
                    nextCall: .object(["tool": .string("app"), "input": .object(["action": .string("ability.list")])]),
                    tap: nil, instruction: "Read ability.list for the affected source and its repair; preserve saved versions and owner authority."))
        }
    }

    /// A part her private moment after a turn kept or revised: its file, the
    /// stamp read, and how her parts fact marks it.
    struct KeptPart { let id: String; let stamp: [String: JSONValue]; let mark: String }

    /// The kept parts by name, each new until a later turn of hers has started
    /// with it shown once.
    static func keptParts(_ dataRoot: URL) throws -> [String: KeptPart] {
        let store = AbilityStore(dataRoot: dataRoot), states = try store.states()
        let turn = TurnTraceContext.turnId
        let clock = DateFormatter()
        clock.dateStyle = .none; clock.timeStyle = .short
        var kept: [String: KeptPart] = [:]
        for file in try store.files(kind: .part) {
            guard case .object(let state)? = states[file.id], case .object(let stamp)? = state["keptAfter"],
                  case .string(let keptTurn)? = stamp["turn"], keptTurn != turn,
                  case .string(let iso)? = stamp["at"], let at = ISO8601DateFormatter().date(from: iso) else { continue }
            if case .string(let shown)? = stamp["shown"], shown != turn { continue }
            kept[file.id] = KeptPart(id: file.id, stamp: stamp, mark: "new — kept after your turn at " + clock.string(from: at))
        }
        return kept
    }

    /// This turn has shown these: each is marked only while its stamp is the
    /// one read, so a keep that landed since stays new.
    static func acknowledge(_ parts: [KeptPart], _ dataRoot: URL) throws {
        guard let turn = TurnTraceContext.turnId else { return }
        let store = AbilityStore(dataRoot: dataRoot)
        for part in parts where part.stamp["shown"] == nil {
            try store.updateState(id: part.id) { fields in
                guard case .object(let live)? = fields["keptAfter"], live["turn"] == part.stamp["turn"], live["at"] == part.stamp["at"],
                      live["shown"] == nil else { return }
                fields["keptAfter"] = .object(live.merging(["shown": .string(turn)]) { $1 })
            }
        }
    }

    static func matchedWords(_ action: AppAction, _ asked: [String]) -> Int {
        hits(Set(intentWords(action.label + " " + action.scope)), asked)
    }

    /// An action's own words: its name (page and verb) and its label.
    static func ownWords(_ action: AppAction) -> Set<String> { Set(intentWords(action.id + " " + action.label)) }

    /// Its own name, label and verb carry the action; its description,
    /// arguments and page are incidental words that only support a match.
    static func score(_ action: AppAction, _ asked: [String], page: QuietToolPage?) -> Int {
        var why = ""
        if case .his(let text, let instead) = action.owner { why = text + " " + (instead ?? "") }
        let own = ownWords(action)
        let context = Set(intentWords([action.scope, action.page, page?.title ?? "", page?.summary ?? "", why].joined(separator: " ")))
        let verb = Set(intentWords(String(action.id.split(separator: ".").last ?? "")))
        let matched = hits(own.union(context), asked)
        guard matched >= 2 || asked.count <= 2 else { return matched }
        return 8 * hits(own, asked) + hits(context, asked) + 2 * hits(verb, asked)
    }

    /// A word is said when the ask has it or a longer form of it
    /// ("screenshots", "deleted"), never a fragment of it: "text" is not
    /// "texted", "attach" is not "attachment".
    static func hits(_ own: Set<String>, _ asked: [String]) -> Int {
        asked.filter { word in own.contains { word == $0 || ($0.count >= 4 && word.hasPrefix($0)) } }.count
    }
}
