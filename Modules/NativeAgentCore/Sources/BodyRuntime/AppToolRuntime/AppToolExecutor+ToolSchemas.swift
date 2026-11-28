import Synchronization
import SenseCore
import Foundation
import NativeAgentCore
import NativeAgentShared
import os
import PersistenceCore
// Blueprint: | `AppToolExecutor+ToolSchemas.swift` | `AppToolExecutor`, `appToolSchemas`, `modelSchemas`; the agent's hand, drawn again only when it can change |

extension AppToolExecutor {
    /// The fold registry reads non-door schemas here; drawing the door must not re-enter that registry.
    public static func appToolSchemas(includeDoor: Bool = true) -> [LLMToolSchema] {
        includeDoor ? Hand.door() + nonDoorSchemas : nonDoorSchemas
    }

    /// What a turn's collection offers the model: these tools with the door as the agent's hand is now. The registered descriptors keep the first
    /// drawing, as a registered descriptor must; the model reads this.
    public var modelSchemas: [LLMToolSchema] {
        Self.appToolSchemas().filter { Self.buckets[$0.name] != nil }.sorted { $0.name < $1.name }
    }

    private static let nonDoorSchemas = makeAppToolSchemas(includeDoor: false)

    enum Hand {
        final class Abilities: Sendable {
            let changed: Set<String>
            init(_ changed: Set<String> = []) { self.changed = changed }
        }
        struct Drawn: Sendable {
            let from: Set<String>
            let forms: [String: String]
            let door: [LLMToolSchema]
        }
        struct State: Sendable {
            var drawn: Drawn?
            var abilities = Abilities()
            var knownAuthored = Set<String>()
            var confirmedAppendix: [String] = []
            var current: (done: Set<String>, door: [LLMToolSchema])?
        }
        static let state = Mutex(State())
        static let hearing: Bool = {
            let root = AbilityStore(dataRoot: PersistenceCore.defaultDataRoot()).root
            _ = NotificationCenter.default.addObserver(forName: AbilityStore.DidChange.name, object: nil, queue: nil) { event in
                guard let path = event.object as? String else { return }
                let url = URL(fileURLWithPath: path)
                guard url.path == root.path || url.deletingLastPathComponent().path == root.path else { return }
                Hand.state.withLock { state in
                    var changed = state.abilities.changed
                    if url.path != root.path { changed.insert(url.lastPathComponent) }
                    state.abilities = Abilities(changed)
                    state.current = nil
                }
            }
            return true
        }()

        static func door() -> [LLMToolSchema] {
            _ = hearing
            var gaps: [String: JSONValue] = [:]
            let done: Set<String>
            do { done = try TurnTracePersistLane().doneVerbs() } catch {
                done = []
                gaps["record"] = .string(error.localizedDescription)
            }
            let (drawn, abilities, current) = state.withLock { ($0.drawn, $0.abilities, $0.current) }
            if let current, current.done == done, gaps.isEmpty { return current.door }
            var authored = Set<String>(), edited = Set<String>()
            let forms: [String: String]?
            do {
                let inventory = try AppActions.checkedInventory(dataRoot: PersistenceCore.defaultDataRoot(), turn: nil)
                authored = Set(inventory.authored.map(\.id))
                if drawn != nil {
                    edited = Set(inventory.authored.filter { abilities.changed.contains($0.tool) }.map(\.id))
                }
                let verbs = done.union(drawn?.from ?? []).union(edited)
                forms = AppToolExecutor.handForms(verbs, in: inventory.actions, gaps: &gaps)
            } catch {
                gaps["catalog"] = .string(error.localizedDescription)
                forms = nil
            }
            if !gaps.isEmpty {
                let at = Date()
                TurnTraceBus.fire(TurnTraceEvent(kind: "app.hand", title: "The agent's hand", status: "partial", payload: .object(gaps),
                    createdAt: NativeTimestampFormat.plainZulu(at), ts: at, turn: nil))
            }
            let gapLines = gaps.sorted { $0.key < $1.key }.map { "Hand gap (\($0.key)): \($0.value.foundationObject)" }
            return state.withLock { [authored, edited, gaps] state in
                let drew: Drawn
                if let first = state.drawn {
                    drew = first
                } else {
                    let hand = forms ?? [:]
                    let door = AppToolExecutor.makeAppToolSchemas(includeDoor: true, hand: hand.sorted { $0.key < $1.key }.map(\.value))
                    drew = Drawn(from: done, forms: hand, door: door)
                    if forms != nil { state.drawn = drew }
                }
                if let forms, state.abilities === abilities {
                    let extra = forms.sorted { $0.key < $1.key }.compactMap { id, form in
                        drew.forms[id] != form || edited.contains(id) ? form : nil
                    }
                    let removed = state.knownAuthored.subtracting(authored).sorted()
                    state.confirmedAppendix = [extra.isEmpty ? "" : "Current forms:\n" + extra.joined(separator: "; ") + ".",
                        removed.isEmpty ? "" : "Removed or disabled: " + removed.joined(separator: ", ") + "."].filter { !$0.isEmpty }
                }
                state.knownAuthored.formUnion(authored)
                let appendix = (state.confirmedAppendix + gapLines).joined(separator: "\n")
                let door = drew.door.map {
                    var schema = $0
                    schema.volatileCatalogAppendix = appendix
                    return schema
                }
                if forms != nil, state.abilities === abilities, gaps.isEmpty { state.current = (done, door) }
                return door
            }
        }
    }

    static func handForms(_ done: Set<String>, in inventory: [AppAction], gaps: inout [String: JSONValue]) -> [String: String] {
        var seen = Set<String>()
        var forms: [String: String] = [:]
        for id in Set(AppActions.bornKnowing).union(done).sorted() {
            // `x` and `authored.x` are one ability: it enters once, as the action the agent calls.
            guard let action = AppActions.action(id, in: inventory), seen.insert(action.id).inserted else { continue }
            do {
                forms[action.id] = try action.arguments.projection(action).form.get()
            } catch { gaps[action.id] = .string(error.localizedDescription) }
        }
        return forms
    }

    private static func makeAppToolSchemas(includeDoor: Bool, hand: [String] = []) -> [LLMToolSchema] {
        let fieldsSchema = ToolSchema.obj([("type", .array([.string("object"), .string("string")])),
            ("additionalProperties", .object(["type": .array([.string("string"), .string("number"), .string("boolean")])])),
            ("description", .string("""
                Fields by shown label/row: {\"Email\":\"a@b.com\",\"Country\":\"Canada\",\"Remember me\":true} or \"Email: a@b.com; Country: Canada\".
                """))])
        let submitSchema = ToolSchema.obj([("type", .array([.string("string"), .string("boolean")])),
            ("description", .string("After fill: button label/row to click, or true for Enter in the last field."))])
        let snapshotDefault = "Optional; defaults to this tab's last-read page."

        let door: [LLMToolSchema] = !includeDoor ? [] : [
            // Pages and actions travel in results to bound prompt mass; only the agent's hand (`Hand`, what the agent has done) enters the door description.
            LLMToolSchema(
                name: "app",
                toolClass: .read, capabilities: [.appDataWrite, .safeRead, .toolCall],
                description: """
                    NativeAgent itself, worked in process: your home, its pages, settings and buttons, and everything you can do. Nothing comes forward on the \
                    owner's screen unless an action says screen. {} is your home first, where you left off (open agent windows, work in progress, what waits \
                    and what arrived, each with a name like desk.4, mail or an agent's name), then a line per page and the action ids that work on every \
                    page. item alone opens a name or ref from home or one of its rooms; its text or fields go in args. page (+item) reads one: what it shows, \
                    its settings, its version, and its actions as id(args) label; the owner's ones say why and where they do them. action + args does one; \
                    the receipt says what changed and what else the app did. preview:true performs no proposed effects: native preflight reports checks, \
                    would_card and approver; authored previews admit the ability and run reads that leave no usage or read marks. Writes stay previewed. Resume preview only inspects stopped work; script \
                    previews describe only calls reached. expected_version refuses if the page changed since that read. find takes words (\"disconnect \
                    telegram\") and returns matching pages and actions, one line each as id(args) label; an action id named in the words (\"mail.search\") \
                    returns its args_schema and example. script runs a JavaScript function body that finishes a task in one call; app.* calls return \
                    synchronously and top-level await is not supported: app.<page>.<action>(args) for any action, as app.inbox.archive({ids, reason}), plus \
                    app.read(page, item) (a home item opens only outside a script), app.find(words) and app.log(text); return what you want back. Each call \
                    passes the turn's gates and gets its own ledger row. A call needing approval waits for the card: approved returns its real result. A call \
                    that fails or is declined throws AppError (reason, receipt), which code can catch and continue. A shell or bash command that ran has \
                    answered: exit_code, stdout, stderr and timed_out come back as data whatever the exit code; it throws only when the command didn't run. \
                    card.request waits and returns the person's answer. Full Mac writes need no approval card. Owner-only or blocked calls still stop at that \
                    line; earlier calls stay done.\u{20}
                    """
                    + "Permitted reads need no permission: do them. mac.go opens apps, files and folders; content readers only read. "
                    + """
                        One action uses app {action:\"files.read\",args:{path:\"README.md\"}}. Put its arguments inside args; page selects a reader, not an \
                        action id. find always discovers actions, including with page:\"home\"; use work.context {query} or chat.search {query} for saved \
                        work and history. These are yours to call straight, in the form this build takes them, * marking a required argument; \
                        find is for anything not here:\u{20}
                        """ + hand.joined(separator: "; ") + ".",
                parametersJSON: ToolSchema.params(
                    properties: [
                        ("page", ToolSchema.strSchema("""
                            A page id from {}, such as inbox, chat or providers. A person's message that begins \"About <page> (page:…):\" was \
                            sent from that page, about it.
                            """)),
                        ("item", ToolSchema.strSchema("""
                            With page: one thing on it, a note id on inbox or a conversation id on chat; actions reads full action signatures when the page \
                            returns a compact catalog. Alone: a name or ref from home or its rooms (desk.4, mail.N, an agent's name), with args {text, \
                            conversation?, expects_reply?} for an agent message; named fields use an action's args.
                            """)),
                        ("action", ToolSchema.strSchema("An action id from a read, such as inbox.archive.")),
                        ("args", DoorFieldDescriptor.openObject("args", reason: "The selected action owns its fields.",
                            description: """
                                          The action's arguments by name, as its id(args) line shows; for a home item, text or fields. For a read or a folded \
                                          action, a list where it takes one value (handle:[…]) runs it once per value; any other change takes actions:[…].
                                          """, values: .implicit).schema),
                        ("actions", ToolSchema.obj([("type", .string("array")), ("items", DoorFieldDescriptor.openObject("actions", reason: "Each step is a door call.", values: .implicit).schema), ("maxItems", .int(Int64(
                            AppScriptRunner.actionLimit))),
                                         ("description", .string("""
                                             Many calls in one, in order: each {action, args}, {page[, item]} or {item}, so several pages or items are one \
                                             call, and a whole deed you already know is one call. Each reports itself with its own receipt. Nothing is built \
                                             on a surprise, and nothing the person asked for waits on a step they did not: a step the gate refuses or files on \
                                             a card is reported in its place and the steps after it still run, while after a step that fails, waits in place \
                                             on the person, or does not come back as you said, later changes do not run and later reads still do; the result \
                                             names that step, what was there, and what did not run. A step may \
                                             add expect, what must come back, as a shape laid over its result: text is met by containing it, a number or \
                                             true/false by equality, null by nothing being there (missing, null or empty), {exactly: v} by the whole value, {not: shape} by the shape \
                                             not being met; a bare string is looked for in what came back, never in your own arguments. An argument value \
                                             {found: "2.rows.0.id"} takes that value from step 2's result (steps count from 1; or name a step with as: "list" \
                                             and write list.rows.0.id); a value that is not there stops the deed at that step. {only: "2.rows.id"} is found that \
                                             stops unless a list on its path holds exactly one; expect {count: N} is a list's length when the result has no count of its own. cleanup: true marks a step that \
                                             puts back what the deed moved; it can run past a stopped deed step, not after the person stops the turn. \
                                             preview and expected_version beside it apply to each, a write's new version passing to the next on its page. \
                                             then_say beside it carries your closing words. To compute \
                                             on a result or glue text, use script.
                                             """))])),
                        ("expect", ToolSchema.obj([
                            ("description", .string("With action and then_say: the expected result shape, as for a step in actions.")),
                            ("anyOf", .array(["object", "string", "number", "boolean", "null"].map { .object(["type": .string($0)]) }
                                + [.object(["type": .string("array"), "items": .object([:])])])),
                        ])),
                        ("then_say", ToolSchema.strSchema("""
                            When the result only needs reporting, give the action an expect and put your answer here, with {slots} filled from the \
                            result using with (step 1). For actions, give each step its own expect. If the expectations hold and the deed can close, \
                            the turn finishes in one pass. Leave the answer open when you need to interpret the result.
                            """)),
                        ("with", DoorFieldDescriptor.openObject("with", reason: "The selected action owns its fields.",
                            description: """
                                          With then_say: fills its {name} slots, each name: {found: "<step>.<path>"} or {only: …} taking a short value (a number, \
                                          true/false or one line of text) from what came back.
                                          """, values: .implicit).schema),
                        ("preview", ToolSchema.boolSchema("""
                            With action or script: report proposed effects without performing them; authored reads run live, resume only inspects. Native \
                            preflight reports checks, would_card and approver. Script previews describe only calls reached.
                            """)),
                        ("expected_version", ToolSchema.strSchema("""
                            With action: the version a read returned. Refused, with nothing done, if that page changed since. It hashes what the page shows, \
                            so a page changed and changed back has its old version again.
                            """)),
                        ("because", ToolSchema.strSchema("""
                            With action: for setting.set in a turn the person did not start, the request it answers, quoted (three words or more) from \
                            a person or trusted agent in this conversation. In a turn the person started nothing is needed: what they asked decides \
                            every change that is theirs (a lever, a widening, an owner_only setting), with no card; in any other turn those ask them.
                            """)),
                        ("find", ToolSchema.strSchema("""
                            What you want done, in words. Discovers actions on every page, including home, one line each as id(args) label, with the best \
                            match's example. Name an action's id in the words for its args_schema and example. Each action found may carry gave_back: the \
                            shapes its results had the last times you called it, keyed by the arguments you gave (keys and types only, merged over from_calls \
                            calls: key? was not always there, a|b is a type that varied). Search history explicitly with \
                            work.context or chat.search.
                            """)),
                        // OwnedProgram.seconds / ProgramProgressWindow own this renewable stall window.
                        ("script", ToolSchema.strSchema("""
                            JavaScript function body: app.* calls return synchronously; top-level await is not supported. No direct network or file APIs; use \
                            eligible app actions. Up to 512 KB, 50 actions and 100 reads. A 60-second no-progress window renews after each non-state host \
                            reply; time waiting on host calls does not count.
                            """)),
                    ],
                    required: []
                )
            ),
        ]
        if includeDoor { return door }
        return [
            LLMToolSchema(
                name: "chat_reply",
                toolClass: .send, capabilities: [.externalSend, .toolCall],
                description: """
                    Reply to an exact opened human conversation's saved destination; the chat read binds its conversation/latest message. Creates no user \
                    turn or foreground-chat change. Answer your active conversation normally. Never automatically resend uncertain delivery.
                    """,
                parametersJSON: ToolSchema.params(properties: [
                    ("conversation_session_id", ToolSchema.strSchema("Exact conversation id from app {page:\"chat\", item}.")),
                    ("last_message_id", ToolSchema.strSchema("Exact last_message_id from the opened conversation; changed conversations must be read again.")),
                    ("text", ToolSchema.strSchema("The assistant reply, up to 16000 characters."))
                ], required: ["conversation_session_id", "last_message_id", "text"])
            ),
            LLMToolSchema(
                name: "browser.status",
                toolClass: .read,
                description: "Return visible NativeAgent Browser status and recent browser run receipts.",
                parametersJSON: ToolSchema.params(properties: [], required: [])
            ),
            LLMToolSchema(
                name: "browser.open_url",
                toolClass: .read, capabilities: [.networkRead, .toolCall],
                description: "Open an http/https URL in the visible NativeAgent Browser and record a browser run receipt.",
                parametersJSON: ToolSchema.params(
                    properties: [
                        ("url", ToolSchema.strSchema("HTTP or HTTPS URL to open.")),
                        ("capture_source", ToolSchema.boolSchema("After navigation, capture visible page text to a source receipt. Defaults false.")),
                        ("capture_screenshot", ToolSchema.boolSchema("After navigation, capture a PNG screenshot receipt. Defaults false.")),
                        ("dry_run", ToolSchema.boolSchema("If true, only record a dry-run browser receipt. Defaults false.")),
                    ],
                    required: ["url"]
                )
            ),
            LLMToolSchema(
                name: "browser.read_text",
                toolClass: .read,
                description: "Read visible page text from the current NativeAgent Browser page and persist a source receipt. Current page must be http/https.",
                parametersJSON: ToolSchema.params(
                    properties: [
                        ("dry_run", ToolSchema.boolSchema("If true, record a dry-run receipt without reading the page. Defaults false.")),
                    ] + ToolSchema.senseViewProperties,
                    required: []
                )
            ),
            LLMToolSchema(
                name: "browser.read_links",
                toolClass: .read,
                description: "Read links from the current NativeAgent Browser page and persist a link-source receipt. Current page must be http/https.",
                parametersJSON: ToolSchema.params(
                    properties: [
                        ("dry_run", ToolSchema.boolSchema("If true, record a dry-run receipt without reading links. Defaults false.")),
                    ] + ToolSchema.senseViewProperties,
                    required: []
                )
            ),
            LLMToolSchema(
                name: "browser.screenshot",
                toolClass: .read,
                description: """
                    Capture a PNG screenshot from the current NativeAgent Browser page and persist a screenshot receipt. Current page must be http/https.
                    """,
                parametersJSON: ToolSchema.params(
                    properties: [
                        ("dry_run", ToolSchema.boolSchema("If true, record a dry-run receipt without capturing an image. Defaults false.")),
                    ],
                    required: []
                )
            ),
            LLMToolSchema(
                name: "browser.chrome_status",
                toolClass: .read,
                description: """
                    Whether the Chrome extension is connected and which tabs are yours in the NativeAgent group. released lists the last eight tabs that \
                    stopped being yours in this app run, with their reason, time and URL.
                    """,
                parametersJSON: ToolSchema.params(properties: [], required: [])
            ),
            LLMToolSchema(
                name: "browser.chrome_reload_extension",
                toolClass: .write, capabilities: [.safeRead, .toolCall],
                description: "Reload the connected Chrome extension quietly. Your NativeAgent group tabs stay open. Returns the reconnect receipt or failure.",
                parametersJSON: ToolSchema.params(properties: [("dry_run", ToolSchema.boolSchema(
                    "Describe current connection without reloading the extension."))], required: [])
            ),
            LLMToolSchema(
                name: "browser.chrome_setup",
                toolClass: .write, capabilities: [.axInjection, .outsideAppDataWrite, .toolCall],
                description: """
                    Set up Chrome with your Mac controls and verify the extension connected. Opens Chrome in front, turns on Developer mode and loads the \
                    bundled extension. Existing Trust and macOS grants apply.
                    """,
                parametersJSON: ToolSchema.params(properties: [("dry_run", ToolSchema.boolSchema(
                    "Describe current connection without preparing files or opening apps."))], required: [])
            ),
            LLMToolSchema(
                name: "browser.chrome_close_tab",
                toolClass: .write, capabilities: [.appDataWrite, .toolCall],
                description: """
                    Explicitly close one of your NativeAgent group tabs. Omit tab_id for this conversation's tab. The person's tabs cannot be closed.
                    """,
                parametersJSON: ToolSchema.params(properties: [
                    ("tab_id", ToolSchema.nullable(ToolSchema.intSchema("Omit for this chat's tab, or name one of your NativeAgent group tabs."))),
                    ("expected_user_sequence", ToolSchema.nullable(ToolSchema.intSchema(
                        "Optional observed user sequence; omit to use the current page's sequence."))),
                ], required: [])
            ),
            LLMToolSchema(
                name: "browser.chrome_look",
                toolClass: .read,
                description: """
                    Look at one of your NativeAgent group tabs: the picture Chrome renders of it now, without activating or moving it. Internal pages return \
                    one line with their title, URL and no-reader reason (read_mode none), without a picture attempt. Omit tab_id for this conversation's tab. \
                    The person's tabs cannot be looked at.
                    """,
                parametersJSON: ToolSchema.params(properties: [
                    ("tab_id", ToolSchema.nullable(ToolSchema.intSchema("Omit for this chat's tab, or name one of your NativeAgent group tabs."))),
                ], required: [])
            ),
            LLMToolSchema(
                name: "browser.chrome_navigate",
                toolClass: .read, capabilities: [.networkRead, .toolCall],
                description: """
                    Open/read a URL in this conversation's last tab if it is still in the NativeAgent group; otherwise open a new tab there. The owner's tabs \
                    are never used. Chrome's exact document and landed URL identify arrival, including internal pages and PDFs. Returns main content \
                    as numbered rows, or the displayed picture with a no-DOM note for PDFs/pages without DOM access; PDF text remains unavailable \
                    from this picture reader. Internal pages return one title/URL/no-reader line with read_mode none. Unsupported schemes such as \
                    javascript: and data: refuse \
                    before any tab changes. new_tab:true opens another inactive tab in your group, leaving the person's focus alone; omit tab_id. Reads \
                    wait for readable main content. Stop cancels the wait. url back/forward moves through this tab's history. \
                    fields + submit fills/sends a form in this call.
                    """,
                parametersJSON: ToolSchema.params(
                    properties: [
                        ("tab_id", ToolSchema.nullable(ToolSchema.intSchema("Omit for this chat's tab, or name one of your NativeAgent group tabs."))),
                        ("expected_user_sequence", ToolSchema.nullable(ToolSchema.intSchema("Optional; omit."))),
                        ("url", ToolSchema.strSchema("HTTP(S) destination, or back / forward to go through this tab's history like the Back button.")),
                        ("new_tab", ToolSchema.boolSchema("Open another background tab in your NativeAgent group. Omit tab_id; requires a destination URL.")),
                        ("find", ToolSchema.strSchema("Start the returned read at the first element containing this text, ignoring case.")),
                        ("fields", fieldsSchema),
                        ("submit", submitSchema),
                        ("scope", ToolSchema.enumStringSchema(["main_content", "page"],
                            "Returned page: main_content (default) or page to include the site's nav.")),
                    ] + ToolSchema.senseViewProperties,
                    required: ["url"]
                )
            ),
            LLMToolSchema(
                name: "browser.chrome_snapshot",
                toolClass: .read,
                description: """
                    Read when main content arrives; Stop cancels the wait. Read in order, including inline links. \
                    Main content precedes sidebars; every frame's content precedes overlays. Pagination supplies has_more and next; partial names an unread \
                    part and its cause. Consent is never dismissed. Images/charts are named in place with size; \
                    chrome.look shows the picture. Internal pages \
                    return one title/URL/no-reader line with read_mode none. Other pages and PDFs without DOM access return the displayed picture with \
                    read_mode picture and an explicit reason; PDF text remains unavailable from this picture reader. DOM reads carry url, title, snapshot_id, \
                    version, captured_at, bytes and has_more; act with node_id (row number as a string or label). Read folded sections with the supplied more \
                    address; scrolling remains an action. scope page adds site nav.
                    """,
                parametersJSON: ToolSchema.params(
                    properties: [
                        ("tab_id", ToolSchema.nullable(ToolSchema.intSchema("Omit for this chat's tab, or name one of your NativeAgent group tabs."))),
                        ("expected_user_sequence", ToolSchema.nullable(ToolSchema.intSchema("Optional user-sequence proof from the Chrome reader."))),
                        ("max_nodes", ToolSchema.intSchema("Maximum rows, 1 through 2000; default 400.")),
                        ("max_text_chars", ToolSchema.intSchema(
                            "Maximum readable text characters, 1 through 200000; default 32000. Transport stays bounded to 1000000 UTF-8 bytes.")),
                        ("find", ToolSchema.strSchema("Start at the first element containing this text, ignoring case. Omit more; an unobserved match is limited to the rendered material walked.")),
                        ("scope", ToolSchema.enumStringSchema(["page", "main_content"], """
                            Rendered page or main_content: declared main regions, else article bodies, else the document body, excluding navigation. Reports \
                            when no main/article region was declared; scope page includes navigation.
                            """)),
                        ("more", ToolSchema.strSchema("""
                            The supplied More address (the more string in next); names its own tab and document, so tab_id need not be repeated. Continues \
                            the rendered content without scrolling and follows an unchanged content anchor when layout moves.
                            """)),
                    ] + ToolSchema.senseViewProperties,
                    required: []
                )
            ),
            LLMToolSchema(
                name: "browser.chrome_click",
                toolClass: .write, capabilities: [.browserInteraction, .toolCall],
                description: """
                    Click one row of the current Chrome page with node_id: a row number as a string (\"73\") or its label (\"Sign in\"). Waits for any \
                    navigation it starts and returns the fresh page; no snapshot call needed.
                    """,
                parametersJSON: ToolSchema.params(
                    properties: [
                        ("tab_id", ToolSchema.nullable(ToolSchema.intSchema("Omit for this chat's tab, or name one of your NativeAgent group tabs."))),
                        ("expected_user_sequence", ToolSchema.nullable(ToolSchema.intSchema("Optional; omit."))),
                        ("snapshot_id", ToolSchema.strSchema(snapshotDefault)),
                        ("node_id", ToolSchema.strSchema("Row number from the page, or the row's label.")),
                    ],
                    required: ["node_id"]
                )
            ),
            LLMToolSchema(
                name: "browser.chrome_media",
                toolClass: .write, capabilities: [.safeRead, .toolCall],
                description: """
                    Play, pause or seek the first audio/video in your Chrome tab, and only that player. Reports paused state, current time and whether the \
                    player confirmed it: playback advancing, the pause holding, the seek landing.Resume uses play; stop-playing uses pause.
                    """,
                parametersJSON: ToolSchema.params(properties: [
                    ("tab_id", ToolSchema.nullable(ToolSchema.intSchema("Omit for this chat's tab, or name one of your NativeAgent group tabs."))),
                    ("expected_user_sequence", ToolSchema.nullable(ToolSchema.intSchema(
                        "Optional observed user sequence; omit to use the current tab's sequence."))),
                    ("operation", ToolSchema.enumStringSchema(["play", "pause", "seek"], "Media operation.")),
                    ("seconds", .object(["type": .string("number"), "minimum": .int(0), "description": .string(
                        "Nonnegative playback position in seconds; required for seek.")])),
                ], required: ["operation"])
            ),
            LLMToolSchema(
                name: "browser.chrome_scroll",
                toolClass: .read,
                description: """
                    Move a Chrome page or scrollable row by delta_y pixels. Returns newly visible rows, distance moved and remaining below; explicitly \
                    reports no movement.
                    """,
                parametersJSON: ToolSchema.params(
                    properties: [
                        ("tab_id", ToolSchema.nullable(ToolSchema.intSchema("Omit for this chat's tab, or name one of your NativeAgent group tabs."))),
                        ("expected_user_sequence", ToolSchema.nullable(ToolSchema.intSchema("Optional; omit."))),
                        ("snapshot_id", ToolSchema.strSchema("""
                            Snapshot id when targeting a node. For page scrolling omit both optional IDs or supply both as empty strings.
                            """)),
                        ("target_node_id", ToolSchema.strSchema("Optional scrollable node id. Node scrolling requires both exact IDs from a fresh snapshot.")),
                        ("delta_x", ToolSchema.intSchema("Horizontal scroll delta.")),
                        ("delta_y", ToolSchema.intSchema("Vertical scroll delta.")),
                    ],
                    required: ["delta_y"]
                )
            ),
            LLMToolSchema(
                name: "browser.chrome_fill",
                toolClass: .write, capabilities: [.browserInteraction, .toolCall],
                description: """
                    Fill the current Chrome form: fields {label or row: value} sets text boxes/selects/checkboxes in page order, then submit clicks a button \
                    (true presses Enter). Finds all fields before typing. For one row use node_id + value. Returns filled fields and, on success, a fresh \
                    page. A stale or failed attempt stops without retry; read the tab again before continuing and do not repeat fields already sent.
                    """,
                parametersJSON: ToolSchema.params(
                    properties: [
                        ("tab_id", ToolSchema.nullable(ToolSchema.intSchema("Omit for this chat's tab, or name one of your NativeAgent group tabs."))),
                        ("expected_user_sequence", ToolSchema.nullable(ToolSchema.intSchema("Optional; omit."))),
                        ("fields", fieldsSchema),
                        ("submit", submitSchema),
                        ("snapshot_id", ToolSchema.strSchema(snapshotDefault)),
                        ("node_id", ToolSchema.strSchema("One editable row: its number or label.")),
                        ("value", ToolSchema.strSchema("Replacement text for node_id, at most 50000 characters.")),
                    ],
                    required: []
                )
            ),
            LLMToolSchema(
                name: "browser.chrome_type",
                toolClass: .write, capabilities: [.browserInteraction, .toolCall],
                description: """
                    Append text to a sequential text-editing row (number or label) through Chrome's trusted input, up to 20 s. Returns acknowledged input \
                    progress, the actual field readback and the fresh page. Assess changed-by-page text before continuing; never automatically replay \
                    uncertain input. Atomic date/time/color/range/file controls use fill.
                    """,
                parametersJSON: ToolSchema.params(
                    properties: [
                        ("tab_id", ToolSchema.nullable(ToolSchema.intSchema("Omit for this chat's tab, or name one of your NativeAgent group tabs."))),
                        ("expected_user_sequence", ToolSchema.nullable(ToolSchema.intSchema("Optional; omit."))),
                        ("snapshot_id", ToolSchema.strSchema(snapshotDefault)),
                        ("node_id", ToolSchema.strSchema("Editable row: its number or label.")),
                        ("text", ToolSchema.strSchema("Text to append, at most 50000 characters.")),
                        ("delay_ms", ToolSchema.intSchema("Optional delay between characters, 0 through 250 milliseconds.")),
                    ],
                    required: ["node_id", "text"]
                )
            ),
            LLMToolSchema(
                name: "browser.chrome_select",
                toolClass: .write, capabilities: [.browserInteraction, .toolCall],
                description: "Choose options in a select row by value or label (shown as label=value, * selected). Returns the fresh page.",
                parametersJSON: ToolSchema.params(
                    properties: [
                        ("tab_id", ToolSchema.nullable(ToolSchema.intSchema("Omit for this chat's tab, or name one of your NativeAgent group tabs."))),
                        ("expected_user_sequence", ToolSchema.nullable(ToolSchema.intSchema("Optional; omit."))),
                        ("snapshot_id", ToolSchema.strSchema(snapshotDefault)),
                        ("node_id", ToolSchema.strSchema("Select row: its number or label.")),
                        ("values", ActionDescriptor.stringArraySchema(
                            "Option values or labels; single-select rows take exactly one.", minItems: 1, maxItems: 100)),
                    ],
                    required: ["node_id", "values"]
                )
            ),
            LLMToolSchema(
                name: "browser.chrome_keypress",
                toolClass: .write, capabilities: [.browserInteraction, .toolCall],
                description: """
                    Press a key or chord in a row (number or label): Enter, Tab, Escape, arrows, a single character like j or /. To move down the page use \
                    browser.chrome_scroll; to go back, browser.chrome_navigate{url:\"back\"}. Verified by what changed; returns the fresh page.
                    """,
                parametersJSON: ToolSchema.params(
                    properties: [
                        ("tab_id", ToolSchema.nullable(ToolSchema.intSchema("Omit for this chat's tab, or name one of your NativeAgent group tabs."))),
                        ("expected_user_sequence", ToolSchema.nullable(ToolSchema.intSchema("Optional; omit."))),
                        ("snapshot_id", ToolSchema.strSchema(snapshotDefault)),
                        ("node_id", ToolSchema.strSchema("Row to press in: its number or label.")),
                        ("key", ToolSchema.strSchema("""
                            Enter, Tab, Shift+Tab, Escape, ArrowDown/Up/Left/Right, Home, End, PageUp, PageDown, Backspace, Delete, Space, Control+A, Meta+A, \
                            or one character (j, k, /).
                            """)),
                    ],
                    required: ["node_id", "key"]
                )
            ),
            LLMToolSchema(
                name: "browser.chrome_set_checked",
                toolClass: .write, capabilities: [.browserInteraction, .toolCall],
                description: "Set a checkbox, radio or switch row on or off (idempotent). Returns the fresh page.",
                parametersJSON: ToolSchema.params(
                    properties: [
                        ("tab_id", ToolSchema.nullable(ToolSchema.intSchema("Omit for this chat's tab, or name one of your NativeAgent group tabs."))),
                        ("expected_user_sequence", ToolSchema.nullable(ToolSchema.intSchema("Optional; omit."))),
                        ("snapshot_id", ToolSchema.strSchema(snapshotDefault)),
                        ("node_id", ToolSchema.strSchema("Checkable row: its number or label.")),
                        ("checked", ToolSchema.boolSchema("Exact checked state to apply.")),
                    ],
                    required: ["node_id", "checked"]
                )
            ),
            LLMToolSchema(
                name: "browser.chrome_double_click",
                toolClass: .write, capabilities: [.browserInteraction, .toolCall],
                description: "Double-click a row (number or label). Verified by what changed; returns the fresh page.",
                parametersJSON: ToolSchema.params(
                    properties: [
                        ("tab_id", ToolSchema.nullable(ToolSchema.intSchema("Omit for this chat's tab, or name one of your NativeAgent group tabs."))),
                        ("expected_user_sequence", ToolSchema.nullable(ToolSchema.intSchema("Optional; omit."))),
                        ("snapshot_id", ToolSchema.strSchema(snapshotDefault)),
                        ("node_id", ToolSchema.strSchema("Row: its number or label.")),
                    ],
                    required: ["node_id"]
                )
            ),
            LLMToolSchema(
                name: "browser.chrome_drag",
                toolClass: .write,
                description: """
                    Drag a drag-advertising node onto a drop-advertising node in one exact fresh Chrome snapshot/frame. Uses synthetic HTML events and page \
                    DataTransfer handlers without activating the tab. Target must accept dragover. dropDispatched does not prove success; check returned \
                    page. No OS/file dragging or pointer-only canvas gestures. Never automatically retry unknown outcomes.
                    """,
                parametersJSON: ToolSchema.params(
                    properties: [
                        ("tab_id", ToolSchema.nullable(ToolSchema.intSchema("Omit for this chat's tab, or name one of your NativeAgent group tabs."))),
                        ("expected_user_sequence", ToolSchema.nullable(ToolSchema.intSchema("Optional; omit."))),
                        ("snapshot_id", ToolSchema.strSchema("Fresh snapshot containing both endpoints.")),
                        ("node_id", ToolSchema.strSchema("Source row number or label advertising drag.")),
                        ("target_node_id", ToolSchema.strSchema("Target row number or label advertising drop; acceptance is checked during the operation.")),
                    ],
                    required: ["snapshot_id", "node_id", "target_node_id"]
                )
            ),
            LLMToolSchema(
                name: "browser.chrome_wait",
                toolClass: .read,
                description: """
                    Wait up to 10 s for the tab to settle or a row to become visible/hidden/enabled/disabled. Returns the page as it reads when the wait \
                    ends. Rarely needed: acts already wait for navigation.
                    """,
                parametersJSON: ToolSchema.params(
                    properties: [
                        ("tab_id", ToolSchema.nullable(ToolSchema.intSchema("Omit for this chat's tab, or name one of your NativeAgent group tabs."))),
                        ("expected_user_sequence", ToolSchema.nullable(ToolSchema.intSchema("Optional; omit."))),
                        ("condition", ToolSchema.enumStringSchema(["element_state", "navigation_settled"], "Wait condition.")),
                        ("snapshot_id", ToolSchema.strSchema("Exact current snapshot id for element_state.")),
                        ("node_id", ToolSchema.strSchema("Row number or label that advertised wait for element_state.")),
                        ("state", ToolSchema.enumStringSchema(["visible", "hidden", "enabled", "disabled"], "Required element state.")),
                        ("timeout_ms", ToolSchema.intSchema("Bounded timeout from 100 through 10000 milliseconds. Defaults 5000.")),
                        ("settle_ms", ToolSchema.intSchema(
                            "Required content quiet interval, 0 through 2000 milliseconds (minimum 350); ad/whole-DOM churn does not reset it.")),
                    ],
                    required: ["condition"]
                )
            ),
        ]
    }
}
