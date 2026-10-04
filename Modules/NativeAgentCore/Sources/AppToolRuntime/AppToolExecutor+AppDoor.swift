import AttentionRouting
import ChatOrchestration
import CryptoKit
import Foundation
import NativeAgentCore
import PersistenceCore
import ToolRegistry
import TrustCenter

/// `app`: NativeAgent as one always-on door, and her only tool.
///
/// `{}` is her home (where she left off) and then the pages, `{page[, item]}`
/// a read with a version and the page's actions, `{action, args}` one action,
/// `{find}` actions by intent, `{item}` a name or ref from home. Every
/// action and read runs in process (`runFolded`), so the `app` call is its
/// one pass through the gates, classified by the action's registry flags,
/// and a block User saved on a retired tool's name
/// still binds what was that tool's (`doorSavedBlock`). This file adds no
/// gate of its own: it refuses only what is User's below Full Mac, a stale
/// version, and arguments the action does not take.
extension AppToolExecutor {
    public static let doorToolNames = ["app"]

    /// Today's Inbox is a sheet, not a rail page, and the rail's word "inbox"
    /// means Notifications; the door's inbox is the notes.
    static let doorInbox = QuietToolPage(
        id: "inbox", title: "Inbox", summary: "Today's Inbox: the notes Today and the Desk count, by id and state.")

    @MainActor var doorPages: [QuietToolPage] { [Self.doorInbox] + presentation.pages }

    /// "current" is the page on User's screen, as the Mac verbs' handoff to
    /// her own window reads it (`ownAppRoute`).
    @MainActor func doorPage(_ raw: String) -> QuietToolPage? {
        let key = raw.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        return switch key {
        case "inbox": Self.doorInbox
        case "current": presentation.currentPage
        // Reads outside the index: the composer's context receipt (item: a
        // conversation id) and the Agent view (item: one of its tabs), which
        // is agent_view so it is never read as agents, her contacts.
        case "context": QuietToolPage(id: key, title: "Context", summary: "")
        case "agent_view": QuietToolPage(id: key, title: "Agent view", summary: "")
        default: presentation.page(named: raw)
        }
    }

    /// Where a receipt sends her to see what is wrong: Doctor's rows, through the door.
    public static let doorDoctor = "Doctor (app {page:\"diagnostics\", item:\"doctor\"})"

    /// The keys app takes. One starting "__" is the chain's own (`__session_id`).
    static let doorKeys: Set<String> = ["page", "item", "action", "args", "preview", "expected_version", "find", "script"]

    static func doorText(_ value: JSONValue?) -> String {
        inputString(value)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
    }

    /// One reading of page and item for the door and for scripts: any item
    /// with no page, or on page home, is one of home's names, which can send
    /// or change something (claude.say, desk.4.done).
    static func opensHomeItem(_ input: [String: JSONValue]) -> Bool {
        guard let item = input["item"], item != .null else { return false }
        let page = doorText(input["page"]).lowercased()
        return page.isEmpty || page == "home"
    }

    /// The marker a script puts on each call it makes (`AppScriptRunner`).
    static let doorScriptKey = "__script"

    /// The door refused before anything ran: nothing happened, and the remedy
    /// names the door call that fixes it.
    static func doorRefusal(_ reason: String, _ detail: String, remedy kind: String, _ instruction: String,
                            next: [String: JSONValue]? = nil, extra: [String: JSONValue] = [:]) -> JSONValue {
        var extra = extra
        extra["effects"] = .string("none")
        extra["remedy"] = .object([
            "kind": .string(kind), "instruction": .string(instruction),
            "next_call": next.map { .object(["tool": .string("app"), "input": .object($0)]) } ?? .null,
        ])
        return failure(reason, detail, extra: extra)
    }

    /// Refusals that are User's or his posture's, from the door or the code
    /// it ran: nothing ran, and retrying changes nothing.
    static let doorFloorReasons: Set<String> = [
        "users_call", "owner_only", "trust_mode_read_only", "trust_mode_unreadable", "users_screen", "user_is_in_it",
        "trust_posture_needs_full_mac", "full_mac_only", "opens_for_user", "blocked_in_trust", "users_ears", "users_draft",
        // A card asked of User on another surface, or whose origin is unknown.
        "not_yours_to_answer", "origin_unverifiable",
        // Needs User himself, Full Mac or not (a browser sign-in).
        "needs_person",
    ]

    /// The items a page reads besides inbox notes: the id, and what reading
    /// it returns.
    static let doorItemReads: [String: [String: String]] = [
        "chat": ["<conversation id>": "the composer as it is, and the latest messages, 8 or args {limit} up to 16, "
                 + "with whether app chat.reply can answer it"],
        "inbox": ["all": "every note newest first, archived and dismissed too, up to 200"],
        "diagnostics": ["doctor": "Doctor's checks, the rows the Doctor tab shows; changes nothing"],
        "telegram": ["status": "the poller's health, config and log freshness; never tokens or ids"],
    ]

    /// A note's buttons (`id: label` from the inbox tool) as the door's own
    /// action ids, so a note and the page speak one vocabulary. View is the
    /// item read itself; a button with no action of its own is `inbox.act`.
    static func doorButtons(_ note: JSONValue) -> JSONValue {
        guard case .object(var row) = note, case .array(let buttons)? = row["actions"] else { return note }
        row["actions"] = .array(buttons.compactMap { button -> JSONValue? in
            let text = inputString(button) ?? ""
            let parts = text.split(separator: ":", maxSplits: 1).map { $0.trimmingCharacters(in: .whitespaces) }
            return noteButton(id: parts[0], label: parts.count > 1 ? parts[1] : parts[0]).map(JSONValue.string)
        })
        return .object(row)
    }

    /// One note button as the door's action: its own action by the words on
    /// it, else `inbox.act` with its id. Nil for view, read and reply.
    public static func noteButton(id raw: String, label: String) -> String? {
        let id = raw.lowercased() == "deny" ? "reject" : raw.lowercased()
        guard !["view", "read", "reply"].contains(id) else { return nil }
        let action = AppActions.all.first { $0.page == "inbox" && $0.label.caseInsensitiveCompare(label) == .orderedSame }
            ?? (["archive", "dismiss", "repair"].contains(id) ? AppActions.action("inbox." + id) : nil)
        guard let action else { return "inbox.act(action: \"\(id)\") \(label)" }
        return action.id + (action.isHis ? " · User's" : "")
    }

    /// The Mac verbs' handoff to her own window (`performMacSelfAppRoute`):
    /// the `act`, `go` or `screen` call was its pass through the gates, so
    /// the door's read or action runs in process inside that call.
    @MainActor
    public func runSelfAppRoute(input: [String: JSONValue], surface: String) async -> JSONValue {
        do { return try await runAppDoor(input: input, surface: surface, inProcess: true) }
        catch { return ChatToolOutcome.failure(error: error, tool: "app") }
    }

    @MainActor
    func runAppDoor(input: [String: JSONValue], surface: String, inProcess: Bool = false) async throws -> JSONValue {
        // A key app does not take fails loudly: a call carrying a result's
        // fields ({"about": …}) is not an index read.
        let stray = input.keys.filter { !Self.doorKeys.contains($0) && !$0.hasPrefix("__") }.sorted()
        if !stray.isEmpty {
            return Self.doorRefusal("unknown_key",
                "app takes no \(stray.joined(separator: ", ")). Its keys are page, item, action, args, preview, "
                + "expected_version, find and script; an action's own arguments go inside args. Nothing was read or done.",
                remedy: "correct_arguments", "Call app again with only those keys; {} lists the pages.",
                next: [:], extra: ["unrecognised": .array(stray.map(JSONValue.string)),
                                   "valid": .array(Self.doorKeys.sorted().map(JSONValue.string))])
        }
        let action = Self.doorText(input["action"])
        if case .string(let script)? = input["script"],
           !script.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            // One call is one thing: the gates and the plan judge it by its
            // action, so a script never rides under one.
            guard action.isEmpty else {
                return Self.doorRefusal("action_and_script",
                    "app takes an action or a script, not both. Nothing was run.", remedy: "correct_arguments",
                    "Call app again with only the action and its args, or only the script.")
            }
            return await doorScript(script, input: input)
        }
        // A name from her screen given as an action (desk.3407.note, as an
        // item's DO list shows it) is an item: refused, with the item call to make.
        if !action.isEmpty, AppActions.action(action) == nil, ToolNameAliases.retiredActions[action.lowercased()] == nil,
           await HerScreen.isName(action, dataRoot: quietHost()?.dataRootOverride ?? PersistenceCore.defaultDataRoot(),
                                  scope: Self.inputString(input["__session_id"]) ?? ChatToolSessionContext.verifiedSessionId ?? "") {
            var next: [String: JSONValue] = ["item": .string(action)]
            if case .object(let args)? = input["args"] { next["args"] = .object(args) }
            return Self.doorRefusal("unknown_action", "\(action) is a name on home, not an action. Nothing was run.",
                remedy: "use_item", "Make next_call: home names go under item.", next: next)
        }
        if !action.isEmpty { return try await doorDo(action, input: input, surface: surface, inProcess: inProcess) }
        let find = Self.doorText(input["find"])
        let page = Self.doorText(input["page"])
        let item = Self.doorText(input["item"])
        // Her home (one-door phase 2 step 7, what was `workspace`): an item
        // with no page is a name or ref from home or one of its rooms; on
        // page home, find searches her work and conversations.
        let homeItem = Self.opensHomeItem(input)
        // A script reads pages; it never opens an item anywhere but a real page.
        if input[Self.doorScriptKey] == .bool(true), input["item"].map({ $0 != .null }) == true,
           homeItem || doorPage(page) == nil {
            return Self.doorRefusal("not_scriptable",
                "A script opens an item only on a real page; a home item can send or change something. Nothing was read or done.",
                remedy: "none", "Open the home item yourself with app {item}, outside the script.")
        }
        // A home item does what its name says at once: there is nothing to
        // preview, and no page version guards it.
        if homeItem, input["preview"] == .bool(true) || !Self.doorText(input["expected_version"]).isEmpty {
            return Self.doorRefusal("item_not_previewable",
                "A home item opens or does what its name says at once; it takes no preview or expected_version. Nothing was read or done.",
                remedy: "correct_arguments",
                "Call app {item} again without preview or expected_version; open its room first to see what it does.")
        }
        if homeItem || page.lowercased() == "home" {
            var call: [String: JSONValue] = [:]
            if !item.isEmpty { call["action"] = .string(item) } else if !find.isEmpty { call["query"] = .string(find) }
            if case .object(let args)? = input["args"] {
                if let stray = args.keys.sorted().first(where: { !["text", "fields"].contains($0) }) {
                    return Self.doorRefusal("unknown_arg",
                        "A home item takes only text and fields in args, not \(stray). Nothing was read or done.",
                        remedy: "correct_arguments", "Call app again with args {text} or {fields}, or none.",
                        extra: ["argument_path": .string("args.\(stray)")])
                }
                for (key, value) in args where value != .null { call[key] = value }
            }
            return await doorHome(call, input: input)
        }
        if !find.isEmpty { return doorFind(find) }
        if page.isEmpty { return await doorIndex(input) }
        guard let resolved = doorPage(page) else {
            return Self.doorRefusal("unknown_page", "No page is called that.", remedy: "read_index",
                "Read {} for the pages; nothing was done.", next: [:],
                extra: ["requested": .string(page), "pages": .array(doorPages.map { .string($0.id) })])
        }
        let result = try await doorRead(page: resolved, item: item)
        guard case .object(var read) = result, read["status"] == .string("ok") else { return result }
        read["version"] = .string(Self.doorVersion(page: resolved.id, item: item, read))
        if item.isEmpty, let items = Self.doorItemReads[resolved.id] {
            read["item_reads"] = .array(items.sorted { $0.key < $1.key }.map { .string("\($0.key): \($0.value)") })
        }
        // A conversation's latest messages and whether chat.reply can answer
        // it, as chat_conversations opened it. Outside the version: her own
        // turn moves them.
        if resolved.id == "chat", case .object(let composer)? = read["item"],
           let id = Self.inputString(composer["conversation"]) {
            if let blocked = await doorSavedBlock("chat_conversations") { read["conversation"] = blocked } else {
                let args: [String: JSONValue] = if case .object(let given)? = input["args"] { given } else { [:] }
                read["conversation"] = await HumanConversationReader.open(sessionID: id,
                    limit: Self.inputString(args["limit"]).flatMap { Int($0) },
                    dataRoot: quietHost()?.dataRootOverride ?? PersistenceCore.defaultDataRoot())
            }
        }
        let hasSettings = if case .array(let rows)? = read["settings"] { !rows.isEmpty } else { false }
        let actions = AppActions.on(page: resolved.id).filter { $0.id != "setting.set" || hasSettings }
        read["actions"] = .array(actions.map { .string($0.line) })
        // A guided action's whole guide, outside the version: it changes only at a release.
        let guides = actions.filter { AppActions.guided.contains($0.id) }
            .compactMap { action in AppActions.about(action).map { (action.id, JSONValue.string($0)) } }
        if !guides.isEmpty { read["guide"] = .object(Dictionary(uniqueKeysWithValues: guides)) }
        return .object(read)
    }

    // MARK: - Reads

    /// Home first: open agent windows, what is in progress, what waits and
    /// what arrived (`home`, which sorts first), then every page.
    @MainActor
    private func doorIndex(_ input: [String: JSONValue]) async -> JSONValue {
        let posture = await Self.freshQuietPosture()
        return .object([
            "home": await doorHome([:], input: input),
            "status": .string("ok"),
            "pages": .array(doorPages.map { page in
                let ids = AppActions.all.filter { $0.page == page.id }.map(\.id)
                return .string("\(page.id): \(page.title). \(page.summary)"
                    + (ids.isEmpty ? "" : " Actions: " + ids.joined(separator: ", ")))
            }),
            "on_every_page": .array(AppActions.all.filter { $0.page == "*" }.map { .string($0.line) }),
            "trust_mode": .string(posture?.name ?? "unreadable"),
            "note": .string("home is where you left off; any name on it opens with item. "
                + "Read a page for what it shows, its version, and each action's args. "
                + (posture?.name == Self.fullMacModeName
                    ? "Full Mac is on: actions marked User's are yours too, and he sees each one you run. "
                    : "User's actions refuse with why and where he does them. ")
                + "preview:true says what an action would do and does nothing."),
        ])
    }

    /// Her home (the workspace): what she left off, and its names and refs as
    /// items. It runs as `workspace`, re-entered under its own name, so its
    /// gate, and every read or send a name runs under that tool's own name,
    /// judge it as they always did.
    @MainActor
    private func doorHome(_ call: [String: JSONValue], input: [String: JSONValue]) async -> JSONValue {
        guard let perform = AppDoorReentry.perform else {
            return Self.doorRefusal("door_unavailable",
                "Home reads only through a chat's tool chain. Nothing was read.", remedy: "none", "Use app from a chat turn.")
        }
        let call = ChatToolSessionInjection.apply(toolName: "workspace", input: call,
                                                  sessionId: Self.inputString(input["__session_id"]))
        do { return Self.foldedResult(try await perform("workspace", call), about: nil) }
        catch { return ChatToolOutcome.failure(error: error, tool: "app") }
    }

    /// User's saved block on a retired tool's name still binds what the door
    /// runs of it. Nil when he has not blocked it.
    @MainActor
    private func doorSavedBlock(_ tool: String) async -> JSONValue? {
        let root = quietHost()?.dataRootOverride ?? PersistenceCore.defaultDataRoot()
        guard let snapshot = try? await SwiftNativeTrustCenter(dataRoot: root).loadAuthorizationSnapshotChecked() else {
            return Self.doorRefusal("trust_mode_unreadable",
                "The saved Trust policy did not read, so nothing was read or done.", remedy: "none",
                "Nothing to retry until Trust reads again; User can check it in Trust.")
        }
        guard SwiftNativeTrustCenter.hasExplicitBlockOverride(tool, overrides: snapshot.userConfiguredAutonomyOverrides)
        else { return nil }
        return Self.doorRefusal("blocked_in_trust",
            "User blocked \(tool) in Trust, and this is \(tool)'s. Nothing was read or done.", remedy: "none",
            "Nothing to retry: unblocking it is User's, in Trust.", extra: ["tool": .string(tool)])
    }

    /// What the page or item shows now, read in process.
    /// Its version hashes only what the person would see change (content,
    /// settings, items), not the accessibility tree.
    @MainActor
    private func doorRead(page: QuietToolPage, item: String) async throws -> JSONValue {
        if page.id == "inbox" {
            if let blocked = await doorSavedBlock("inbox") { return blocked }
            guard let host = quietHost() else { return Self.unattachedFailure() }
            if item.isEmpty || item.lowercased() == "all" {
                let result = await host.inbox(verb: "list", input: item.isEmpty ? [:]
                    : ["filter": .string("all"), "limit": .int(200)])
                guard case .object(let list) = result, list["status"] == .string("ok") else { return result }
                let notes: [JSONValue] = if case .array(let notes)? = list["notes"] { notes } else { [] }
                return .object(["status": .string("ok"), "page": .string("inbox"), "title": .string(page.title),
                                "about": .string(page.summary), "count": list["count"] ?? .null,
                                "needs_you_count": list["needs_you_count"] ?? .null, "items": .array(notes.map(Self.doorButtons))])
            }
            let result = await host.inbox(verb: "read", input: ["id": .string(item)])
            guard case .object(let read) = result, case .array(let notes)? = read["notes"],
                  let note = notes.first else { return result }
            return .object(["status": .string("ok"), "page": .string("inbox"), "item": Self.doorButtons(note)])
        }
        if let tool = ["diagnostics": "doctor_status", "telegram": "telegram_status"][page.id],
           Self.doorItemReads[page.id]?[item.lowercased()] != nil {
            if let blocked = await doorSavedBlock(tool) { return blocked }
            return .object(["status": .string("ok"), "page": .string(page.id), "item": try await healthRead(item.lowercased())])
        }
        if ["context", "agent_view"].contains(page.id) {
            if let blocked = await doorSavedBlock("app_page_read") { return blocked }
            return await runAppPageRead(input: ["page": .string(page.id), (page.id == "agent_view" ? "room" : "session_id"): .string(item)])
        }
        switch (page.id, item.isEmpty) {
        case ("chat", false):
            // The composer's own read.
            if let blocked = await doorSavedBlock("interaction_act") { return blocked }
            let result = await composerRead(sessionId: item)
            guard case .object(let state) = result, state["status"] == .string("ok") else { return result }
            return .object(["status": .string("ok"), "page": .string("chat"), "item": result])
        case (_, false):
            return Self.doorRefusal("no_items",
                "Only inbox (a note id), chat (a conversation id), diagnostics (doctor) and telegram (status) "
                + "read one item.", remedy: "read_page",
                "Read the page without item; nothing was done.", next: ["page": .string(page.id)])
        default:
            if let blocked = await doorSavedBlock("app_page_read") { return blocked }
            let result = await runAppPageRead(input: ["page": .string(page.id)])
            guard case .object(var read) = result, read["status"] == .string("ok"), let host = quietHost() else { return result }
            // Chat also lists the sidebar's conversations, the first page of
            // chat.list. Outside the version: her own turn moves them.
            if page.id == "chat", await doorSavedBlock("chat_conversations") == nil,
               case .object(let list) = await host.runChatSession(verb: "list", input: [:], reachesUser: false) {
                read["conversations"] = list["conversations"]
                read["conversations_next_offset"] = list["next_offset"]
            }
            // Providers also lists each account's id, fallback model and
            // models, as provider.test and provider.set_fallback_model take them.
            if page.id == "providers", await doorSavedBlock("provider") == nil,
               case .object(let list) = await host.provider(verb: "list", input: [:]) {
                read["accounts"] = list["accounts"]
            }
            return .object(read)
        }
    }

    static func doorVersion(page: String, item: String, _ read: [String: JSONValue]) -> String {
        let shown = JSONValue.object(read.filter { ["content", "settings", "items", "item", "count"].contains($0.key) })
        let digest = SHA256.hash(data: (try? shown.serializedData(pretty: false)) ?? Data())
        return (item.isEmpty ? page : page + "/" + item) + "@"
            + digest.prefix(6).map { String(format: "%02x", $0) }.joined()
    }

    /// The version a read of `scope` ("page" or "page/item") would return now.
    @MainActor
    private func doorCurrentVersion(scope: String) async throws -> String? {
        let parts = scope.split(separator: "/", maxSplits: 1).map(String.init)
        guard let page = parts.first.flatMap(doorPage) else { return nil }
        let item = parts.count > 1 ? parts[1] : ""
        guard case .object(let read) = try await doorRead(page: page, item: item),
              read["status"] == .string("ok") else { return nil }
        return Self.doorVersion(page: page.id, item: item, read)
    }

    @MainActor
    private func doorFind(_ query: String) -> JSONValue {
        let asked = AppActions.words(query)
        let titles = Dictionary(doorPages.map { ($0.id, $0.title) }, uniquingKeysWith: { first, _ in first })
        let actions = Self.ranked(asked, titles: titles).prefix(5)
        let pages = doorPages.map { page in
            (page, asked.filter(Set(AppActions.words(page.id + " " + page.title + " " + page.summary)).contains).count)
        }.filter { $0.1 > 0 }.sorted { $0.1 > $1.1 }.prefix(3)
        let root = quietHost()?.dataRootOverride ?? PersistenceCore.defaultDataRoot()
        let skills = AppActions.skills(asked, dataRoot: root).prefix(3)
        let archived = AppActions.archivedTools(asked, dataRoot: root).prefix(2)
        var found: [String: JSONValue] = [
            "status": .string(actions.isEmpty && pages.isEmpty && skills.isEmpty && archived.isEmpty ? "not_found" : "ok"),
            "find": .string(query),
            "actions": .array(actions.map { .object(["page": .string($0.page), "action": .string($0.line)]) }
                + archived.map { .object(["page": .string("diagnostics"), "action": .string($0)]) }),
            "pages": .array(pages.map { .string("\($0.0.id): \($0.0.title). \($0.0.summary)") }),
            "note": .string("Read the page for its version and every action on it; preview:true tries an action first."),
        ]
        if !skills.isEmpty {
            found["skills"] = .array(skills.map { .string("\($0.name): \($0.about)") })
            found["skills_note"] = .string("A skill is guidance, not an action: skill.read {name} reads it before the work it fits.")
        }
        return .object(found)
    }

    /// Actions by how many asked words they carry, registry order on ties.
    static func ranked(_ asked: [String], titles: [String: String]) -> [AppAction] {
        (AppActions.all + AppActions.mcp() + AppActions.authored()).enumerated()
            .map { (offset: $0.offset, action: $0.element,
                    score: AppActions.score($0.element, asked, pageTitle: titles[$0.element.page] ?? ""),
                    named: AppActions.hits(Set(AppActions.words($0.element.id)), asked)) }
            .filter { $0.score > 0 }
            // On a tie, the one whose own id names more of the ask ("save a script skill" finds skill.save).
            .sorted { ($0.score, $0.named, $1.offset) > ($1.score, $1.named, $0.offset) }
            .map(\.action)
    }

    // MARK: - Script

    /// `script`: each `app.*` call re-enters the chain as its own `app` call,
    /// so it passes the gates, User's floor, preview and expected_version
    /// exactly as a single action does (`AppScriptRunner`).
    private func doorScript(_ source: String, input: [String: JSONValue]) async -> JSONValue {
        guard let perform = AppDoorReentry.perform else {
            return Self.doorRefusal("door_unavailable",
                "This call did not come through a chat's tool chain, so it has no gate to pass. Nothing ran.",
                remedy: "none", "Use app from a chat turn.")
        }
        let session = input["__session_id"]
        let preview = input["preview"] == .bool(true)
        return await DoorNotesSnapshot.$current.withValue(DoorNotesSnapshot()) {
            await AppScriptRunner.run(source: source, preview: preview) { call in
                var call = call
                if let session { call["__session_id"] = session }
                do { return try await perform("app", call) } catch { return ChatToolOutcome.failure(error: error, tool: "app") }
            }
        }
    }

    // MARK: - Do

    @MainActor
    private func doorDo(_ id: String, input: [String: JSONValue], surface: String, inProcess: Bool) async throws -> JSONValue {
        guard let action = AppActions.action(id) else {
            // A retired action answers as the call that replaced it (claude.message → claude.say).
            let args: [String: JSONValue] = if case .object(let given)? = input["args"] { given } else { [:] }
            if let old = ToolNameAliases.retiredActions[id.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()] {
                return Self.doorRefusal("retired_action", "That action is retired; nothing was done. "
                    + ToolNameAliases.foldedToolHint(old, input: args),
                    remedy: "use_item", "Make next_call instead.", next: ToolNameAliases.appCall(old, input: args))
            }
            return Self.doorRefusal("unknown_action", "No action is called that. The nearest are in nearest; {} lists them all. "
                + "A name or ref from home (desk.4, claude, mail.find) opens with item, not action.",
                remedy: "find", "Use one of nearest, find it by what you want done, or open a home name with item; nothing was done.",
                next: ["find": .string(id)],
                extra: ["requested": .string(id),
                        "nearest": .array(Self.ranked(AppActions.words(id), titles: [:]).prefix(3).map { .string($0.line) })])
        }
        let root = quietHost()?.dataRootOverride ?? PersistenceCore.defaultDataRoot()
        // User, 10-02: under Full Mac his actions are hers too. The code each
        // runs posts the decided row he sees it by.
        let fullMac = action.isHis ? await Self.freshQuietPosture(dataRoot: root)?.name == Self.fullMacModeName : false
        var receipt: [String: JSONValue] = [
            "action": .string(action.id), "page": .string(action.page), "label": .string(action.label),
            "owner": .string(action.isHis && !fullMac ? "his" : "hers"), "irreversible": .bool(action.irreversible),
        ]
        // What no call can do for him (provider.sign_in: a browser sign-in he
        // completes himself) stays his under Full Mac too.
        if fullMac, action.tool.isEmpty, case .his(let why, _) = action.owner {
            receipt["owner"] = .string("his")
            return Self.doorRefusal("needs_person",
                "Under Full Mac \(action.id) is yours, but it needs User himself: \(why). Nothing was done.",
                remedy: "ask_user", "Ask User to do it at the Mac; nothing to retry until he has.", extra: receipt)
        }
        if !fullMac, case .his(let why, let instead) = action.owner {
            receipt["why"] = .string(why)
            if let instead { receipt["instead"] = .string(instead) }
            if input["preview"] == .bool(true) {
                receipt["status"] = .string("preview")
                receipt["detail"] = .string("Would refuse: that's User's, \(why). Nothing was done.")
                return .object(receipt)
            }
            return Self.doorRefusal("users_call", "That's User's: \(why). Nothing was done.",
                remedy: instead == nil ? "none" : "use_instead",
                instead.map { "Leave it for User, or if it is what you need: \($0)." }
                    ?? "Nothing to retry: it is User's. Leave it for him.",
                extra: receipt)
        }
        // A folded tool's whole description rides what refuses or previews it.
        if let about = AppActions.about(action) { receipt["about"] = .string(about) }
        func badArgs(_ reason: String, _ detail: String, _ path: String) -> JSONValue {
            var extra = receipt
            extra["argument_path"] = .string(path)
            return Self.doorRefusal(reason, detail, remedy: "correct_arguments",
                "Call \(action.id) again with args as its line shows; nothing was done.", extra: extra)
        }
        let args: [String: JSONValue]
        switch input["args"] {
        case .object(let given)?: args = given.filter { $0.value != .null }
        case nil, .null?: args = [:]
        default: return badArgs("invalid_args", "args is an object of the action's arguments by name: \(action.line)", "args")
        }
        let specs = action.argSpecs
        let known = Set(specs.flatMap(\.names))
        // An MCP or authored tool whose schema lists no arguments takes what it is given.
        let open = specs.isEmpty && (ToolNameAliases.mcpAction(action.tool) != nil || ToolNameAliases.authoredTool(action.id) != nil)
        if !open, let stray = args.keys.sorted().first(where: { !known.contains($0) }) {
            return badArgs("unknown_arg", "\(action.id) takes no \(stray): \(action.line)", "args.\(stray)")
        }
        if let missing = specs.first(where: { spec in !spec.optional && !spec.names.contains { args[$0] != nil } }) {
            return badArgs("missing_arg", "\(action.id) needs \(missing.names.joined(separator: " or ")): \(action.line)",
                           "args.\(missing.names[0])")
        }
        // Why she put it away, on the receipt that lands in her transcript.
        // Never under `reason`: that key is the machine refusal code the
        // runner and the floor check classify on.
        if let reason = Self.inputString(args["reason"]) { receipt["reason_given"] = .string(String(reason.prefix(280))) }
        var call: [String: JSONValue] = [:]
        for (key, value) in args { call[action.rename[key] ?? key] = value }
        for (key, value) in action.input { call[key] = value }
        // What runs under it, by the host call's own names: its verb is not
        // the action's (inbox.acknowledge runs archive). A key or token never
        // rides a receipt.
        var shown = MacInjectionArgRedaction.redacted(tool: action.tool, input: call)
        for name in action.secretArgs where shown[action.rename[name] ?? name] != nil {
            shown[action.rename[name] ?? name] = .string("[redacted]")
        }
        receipt["underlying_call"] = .object(["input": .object(shown)])

        let expected = Self.doorText(input["expected_version"])
        let scope = expected.split(separator: "@", maxSplits: 1).first.map(String.init) ?? ""
        if !expected.isEmpty {
            let scopePage = scope.split(separator: "/", maxSplits: 1).first.map(String.init).flatMap(doorPage)?.id
            guard action.page == "*" || scopePage == action.page else {
                receipt["expected_version"] = .string(expected)
                return Self.doorRefusal("wrong_page_version",
                    "That version is from \(scopePage ?? scope), and \(action.id) is on \(action.page). Nothing was done.",
                    remedy: "reread", "Read \(action.page) and pass the version it returns.",
                    next: ["page": .string(action.page)], extra: receipt)
            }
            let current = try await doorCurrentVersion(scope: scope)
            guard current == expected else {
                receipt["expected_version"] = .string(expected)
                receipt["current_version"] = current.map(JSONValue.string) ?? .null
                let parts = scope.split(separator: "/", maxSplits: 1).map { JSONValue.string(String($0)) }
                var read: [String: JSONValue] = ["page": parts.first ?? .string(action.page)]
                if parts.count > 1 { read["item"] = parts[1] }
                return Self.doorRefusal("stale_version", current == nil
                    ? "That version names nothing that reads now. Nothing was done."
                    : "\(scope) changed since that read. Nothing was done.",
                    remedy: "reread", "Read it again, check the action still fits, then pass the new version.",
                    next: read, extra: receipt)
            }
        }
        if let session = input["__session_id"] { call["__session_id"] = session }
        // A skill's run is a strict script run of its own, its preview too.
        if action.id == "skill.run" || action.id == "skill.resume" {
            if let blocked = await doorSavedBlock(action.tool) { return blocked }
            return await doorSkill(action.id, args: args, input: input, surface: surface)
        }
        if input["preview"] == .bool(true) {
            receipt["status"] = .string("preview")
            // The checks the real call makes before it touches anything, read
            // now through the same functions: a preview refuses what it would.
            var refusal: JSONValue?
            // Only where the real call would run: elsewhere it refuses
            // door_unavailable, not a missing window.
            if AppDoorReentry.perform != nil || inProcess {
                refusal = await doorSavedBlock(action.tool)
                if refusal == nil { refusal = await foldedRefusal(action, input: call, surface: surface) }
            }
            guard case .object(let refused)? = refusal, refused["status"] != .string("would") else {
                receipt["would_card"] = .bool(await doorWouldCard(action, call: call, input: input, surface: surface))
                receipt["detail"] = .string("Nothing was done. Without preview this runs with that input, through its own checks.")
                // A lifecycle preview says what the call would leave, in its own words.
                if case .object(let would)? = refusal {
                    receipt.merge(would.filter { !["status", "detail"].contains($0.key) }) { $1 }
                    receipt["detail"] = .string(Self.doorText(would["detail"]) + " Nothing was done.")
                }
                return .object(receipt)
            }
            // A card only User answers, on the glass, says why under reason.
            let glass = refused["status"] == .string("needs_glass")
            let code = glass ? "needs_glass" : Self.doorText(refused["reason"])
            let why = Self.doorText(glass ? refused["reason"] : refused["detail"])
            receipt["would_refuse"] = .string(code)
            for (key, value) in refused where key.hasPrefix("would_") || key == "versions" { receipt[key] = value }
            if glass || Self.doorFloorReasons.contains(code) {
                receipt["owner"] = .string("his")
                receipt["why"] = .string(why)
            }
            receipt["detail"] = .string("Would refuse: \(code). \(why) Nothing was done.")
            return .object(receipt)
        }
        guard AppDoorReentry.perform != nil || inProcess else {
            return Self.doorRefusal("door_unavailable",
                "This call did not come through a chat's tool chain, so it has no gate to pass. Nothing was read or done.",
                remedy: "none", "Use app from a chat turn.")
        }
        // Skills: one step of a script skill reads here; a list does upkeep only with write authority.
        if action.id == "skill.read", args["step"] != nil {
            if let blocked = await doorSavedBlock(action.tool) { return blocked }
            return Self.skillStepRead(Self.doorText(args["name"]), step: args["step"], root: root)
        }
        if action.id == "skill.list", await Self.freshQuietPosture(dataRoot: root)?.changesAllowed == true {
            await Self.skillUpkeep(root: root)
        }
        // A folded tool answers as its direct call did: its own result, its
        // own gates (User's saved level on it among them) and its own card.
        if action.isFold {
            let folded = Self.foldedResult(try await runFolded(action, input: call, surface: surface), about: receipt["about"],
                                           browser: action.tool.hasPrefix("browser."))
            // A versioned write says the version it left, as the app's own buttons do.
            guard !expected.isEmpty, case .object(var fields) = folded,
                  let after = try? await doorCurrentVersion(scope: scope) else { return folded }
            fields["page_version"] = .string(after)
            return .object(fields)
        }
        if case .object(var refusal)? = await doorSavedBlock(action.tool) {
            refusal.merge(receipt) { own, _ in own }
            return .object(refusal)
        }

        // In a script, one call's after is the next one's before: one inbox
        // read per action. A read raises nothing, so none is read around it.
        let snapshot = DoorNotesSnapshot.current
        let watch = !action.read
        let notesBefore = if !watch { [(id: String, title: String)]?.none }
            else if let held = snapshot?.notes { held } else { await doorNotes() }
        let knocksBefore = watch ? AttentionRouter.deliveredKnocks(dataRoot: root) : [:]
        let result = try await runFolded(action, input: call, surface: surface)
        let notesAfter = watch ? await doorNotes() : nil
        if watch { snapshot?.notes = notesAfter }
        let knocksAfter = watch ? AttentionRouter.deliveredKnocks(dataRoot: root) : [:]

        // The receipt's status is the code's own: its status, else whether
        // its result reads as a success, never the door's own ok.
        receipt["status"] = .string(ChatToolOutcome.outputLooksSuccessful(result) ? "ok" : "failed")
        if case .object(let fields) = result {
            if case .string(let status)? = fields["status"] { receipt["status"] = .string(status) }
            if let changed = fields["changed"] { receipt["changed"] = changed }
            if let effects = fields["effects"] { receipt["effects"] = effects }
            // A refusal that is User's, or a card only he answers, is his here
            // too, as its preview says.
            if Self.doorFloorReasons.contains(Self.doorText(fields["reason"])) || fields["status"] == .string("needs_glass") {
                receipt["owner"] = .string("his")
            }
        }
        // The code behind it names its own verb (inbox.acknowledge runs
        // archive; card.answer runs the card's primary); the receipt names the
        // action that was asked for.
        let own = action.isCard ? "action" : "verb"
        if case .object(var fields) = result, fields[own] != nil {
            fields[own] = .string(String(action.id.split(separator: ".").last ?? Substring(action.id)))
            receipt["result"] = .object(fields)
        } else {
            receipt["result"] = result
        }
        if case .object(let fields) = result,
           !ChatToolOutcome.outputLooksSuccessful(result) || ChatToolOutcome.isWaitingOnPerson(result) {
            let reason = Self.doorText(fields["reason"])
            let waiting = Self.doorText(fields["not_run_status"])
            // The refusal's own code on the receipt itself (users_screen, not
            // tool_failed); a sentence stays where it is.
            if !reason.isEmpty, !reason.contains(" ") { receipt["reason"] = .string(reason) }
            if !waiting.isEmpty || Self.doorFloorReasons.contains(reason) {
                receipt["effects"] = .string("none")
                receipt["remedy"] = .object([
                    "kind": .string(waiting == "approval_filed" ? "wait" : "none"),
                    "instruction": .string(waiting == "approval_filed"
                        ? "User has a card for it; it runs if he approves. Don't retry."
                        : "Nothing ran, and retrying changes nothing. Leave it for User."),
                    "next_call": .null,
                ])
            } else {
                receipt["effects"] = fields["effects"] ?? .string("unknown")
                receipt["remedy"] = .object([
                    "kind": .string("inspect"),
                    "instruction": .string("Read \(action.page) to see what took effect, then decide; don't replay it blindly."),
                    "next_call": .object(["tool": .string("app"), "input": .object(["page": .string(action.page)])]),
                ])
            }
        }
        var raised: JSONValue = .string("unreadable: the inbox did not read before and after")
        if let notesBefore, let notesAfter {
            let seen = Set(notesBefore.map(\.id))
            raised = .array(notesAfter.filter { !seen.contains($0.id) }.map { .string("\($0.id): \($0.title)") })
        }
        if watch { receipt["side_effects"] = .object([
            // Cards and approvals the app filed during the call land here too.
            "notes_raised": raised,
            "knocks_delivered": .int(Int64(knocksAfter.filter { knocksBefore[$0.key] != $0.value }.count)),
            "not_observed": .string("A turn a card's answer wakes on its own (one handed back to this call is "
                + "result.continuation), and anything the app does after this call returns."),
        ]) }
        if !expected.isEmpty, let after = try? await doorCurrentVersion(scope: scope) {
            receipt["page_version"] = .string(after)
        }
        receipt["decided_by"] = .string("agent")
        return .object(receipt)
    }

    /// A folded tool's result as she reads it through the door: a call it
    /// points to by a folded name is that tool's app call, its sentences name
    /// folded tools by action id, and a failure that was not User's or a card
    /// carries the tool's whole description. Data fields are left as they are.
    static func foldedResult(_ result: JSONValue, about: JSONValue?, browser: Bool = false) -> JSONValue {
        // A browser page's own text names its next steps by tool (scroll for
        // the rest, snapshot to read again): through the door they are app calls.
        if browser, case .string(let page) = result { return .string(browserSteps(page)) }
        guard case .object(var fields) = ToolNameAliases.appCallPointers(result) else { return result }
        if browser, case .string(let page)? = fields["page"] { fields["page"] = .string(browserSteps(page)) }
        // Only the result's own top-level sentences: anything nested is data,
        // her words among it (a stance's reason, a ledger note).
        for key in ToolNameAliases.foldedProseKeys {
            if case .string(let text)? = fields[key], text.contains(" ") {
                fields[key] = .string(ToolNameAliases.foldedProse(text))
            }
        }
        if let about, !ChatToolOutcome.outputLooksSuccessful(result), !ChatToolOutcome.isWaitingOnPerson(result),
           !doorFloorReasons.contains(doorText(fields["reason"])) {
            fields["about"] = about
        }
        return .object(fields)
    }

    private static let browserTools = ToolNameAliases.foldedTools.filter { $0.key.hasPrefix("browser.") }
        .sorted { $0.key.count > $1.key.count }

    /// `browser.chrome_scroll{delta_y}` in a page's text is `app chrome.scroll{delta_y}`.
    static func browserSteps(_ text: String) -> String {
        browserTools.reduce(text) { $0.replacingOccurrences(of: $1.key, with: "app " + $1.value) }
    }

    /// Every note by id, archived ones too, so a new id is a note the call
    /// raised. Read in process, as part of the action's own receipt. Nil when
    /// the inbox did not read or User blocked it; the receipt says so.
    @MainActor
    private func doorNotes() async -> [(id: String, title: String)]? {
        guard await doorSavedBlock("inbox") == nil, let host = quietHost(),
              case .object(let list) = await host.inbox(verb: "list", input: [
                "filter": .string("all"), "limit": .int(200),
              ]), case .array(let notes)? = list["notes"] else { return nil }
        return notes.compactMap { note in
            guard case .object(let row) = note, case .string(let id)? = row["id"] else { return nil }
            return (id, Self.doorText(row["title"]))
        }
    }
}

/// The inbox as the last action in a script left it, bound around the script
/// so each of its actions reads the inbox once, after itself.
final class DoorNotesSnapshot: @unchecked Sendable {
    @TaskLocal static var current: DoorNotesSnapshot?
    private let lock = NSLock()
    private var held: [(id: String, title: String)]?
    var notes: [(id: String, title: String)]? {
        get { lock.withLock { held } }
        set { lock.withLock { held = newValue } }
    }
}
