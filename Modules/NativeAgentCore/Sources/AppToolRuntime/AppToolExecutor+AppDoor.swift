import AttentionRouting
import ChatOrchestration
import CryptoKit
import Foundation
import MacIntegration
import NativeAgentCore
import PersistenceCore
import ToolRegistry
import TrustCenter
import Senses
import Skills

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
        case "chrome": presentation.page(named: "browser")
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

    /// A read-only action named as a page or item just runs: there is
    /// nothing to undo, so a refusal only costs a turn (10-08). Anything
    /// that changes something still comes back as the corrected call.
    func runCorrectedRead(_ correction: JSONValue, input: [String: JSONValue], surface: String, inProcess: Bool) async throws -> JSONValue {
        guard case .object(let fields) = correction, case .object(let remedy)? = fields["remedy"],
              case .object(let next)? = remedy["next_call"], case .object(var call)? = next["input"],
              call["preview"] == nil, case .string(let id)? = call["action"], let action = AppActions.action(id) else { return correction }
        // {item:"memory.recall", find:"words"}: the find text is the query it lacks (10-09).
        let takesQuery = action.argSpecs.flatMap(\.names).contains("query")
        if takesQuery, call["args"] == nil || call["args"] == .object([:]), case .string(let words)? = input["find"],
           !words.trimmingCharacters(in: .whitespaces).isEmpty {
            call["args"] = .object(["query": .string(words)])
        }
        // {"chat.search": "words"}: a bare string is the action's query when it takes one.
        if case .string(let text)? = call["args"] {
            guard action.argSpecs.flatMap(\.names).contains("query") else { return correction }
            call["args"] = .object(["query": .string(text)])
        }
        guard call["args"] == nil || { if case .object = call["args"] { return true } else { return false } }(),
              action.readOnly(args: { if case .object(let args)? = call["args"] { return args } else { return [:] } }()) else { return correction }
        for (key, value) in input where key.hasPrefix("__") { call[key] = value }
        var value = try await runAppDoor(input: call, surface: surface, inProcess: inProcess)
        if case .object(var result) = value {
            result["argument_notes"] = .array([.string("Ran as {action:\"\(id)\"}; it is an action, not a page or item.")])
            value = .object(result)
        }
        return value
    }

    static func doorActionCorrection(_ name: String, input: [String: JSONValue]) -> JSONValue? {
        let key = name.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        let args = if case .object(let args)? = input["args"] { args } else { [String: JSONValue]() }
        let call = (AppActions.action(key) ?? AppActions.pagePrefixedAction(key)).map { ["action": JSONValue.string($0.id), "args": input["args"] ?? .object(args)] }
            ?? ToolNameAliases.appCall(ToolNameAliases.retiredActions[key] ?? ToolNameAliases.canonical(key), input: args)
        guard var call else { return nil }
        for key in ["preview", "expected_version"] { if let value = input[key] { call[key] = value } }
        return doorRefusal("action_route", "Use the corrected app call. Nothing ran.",
            remedy: "correct_route", "Make next_call instead.", next: call)
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
        "inbox": ["all": "compact notes newest first, archived and dismissed too, up to 200; read a note id for details and actions"],
        "desk": ["<exact title or handle>": "the matching Desk record; duplicate titles require the exact desk number"],
        "diagnostics": ["doctor": "Doctor's last report; run doctor.run for fresh checks"],
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
        return action.id + (action.isHis ? " · the owner's" : "")
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
    func runAppDoor(input rawInput: [String: JSONValue], surface: String, inProcess: Bool = false) async throws -> JSONValue {
        var input = rawInput
        let action = Self.doorText(input["action"])
        var corrections: [String] = []
        let names = Set(AppActions.action(action)?.argSpecs.flatMap(\.names) ?? [])
        for key in ["status", "ok", "effects", "execution", "read_only", "irreversible", "argument_notes"]
        where !names.contains(key) && input.removeValue(forKey: key) != nil {
            corrections.append("Ignored result-only key \(key).")
        }
        if AppActions.action(action) == nil, let query = ToolNameAliases.appFindQuery(input) {
            input["find"] = .string(query)
            input.removeValue(forKey: "action"); input.removeValue(forKey: "args")
            corrections.append("Treated free-text action as {find}; discovery only, nothing ran.")
        }
        if !corrections.isEmpty {
            var value = try await runAppDoor(input: input, surface: surface, inProcess: inProcess)
            if case .object(var fields) = value {
                let notes = if case .array(let notes)? = fields["argument_notes"] { notes } else { [JSONValue]() }
                fields["argument_notes"] = .array(corrections.map(JSONValue.string) + notes)
                value = .object(fields)
            }
            return value
        }
        let given: [String: JSONValue]? = switch input["args"] {
        case .object(let args)?: args
        case nil, .null?: [:]
        default: nil
        }
        if let target = AppActions.action(action), var args = given {
            let secrets = Set(MacInjectionArgRedaction.appDoorSecretKeys(input))
            func movable(_ key: String, _ value: JSONValue?) -> Bool {
                !secrets.contains(key) && Set(key.lowercased().split(separator: "_")).isDisjoint(with: ["key", "token", "secret", "password", "credential"])
                    && AppScriptRunner.secretPath(.object([key: value ?? .string("")])) == nil
            }
            let names = Set(target.argSpecs.flatMap(\.names)).filter { movable($0, nil) }
            let discovery = if case .object(let fields) = AppActions.discovery(target) { fields } else { [String: JSONValue]() }
            let properties: [String: JSONValue] = if case .object(let schema)? = discovery["args_schema"],
                case .object(let properties)? = schema["properties"] { properties } else { [:] }
            for key in input.keys.sorted() where names.contains(key) && !Self.doorKeys.contains(key) {
                guard movable(key, input[key]) else { continue }
                guard args[key] == nil || args[key] == .null || args[key] == input[key] else {
                    let example = if case .object(let call)? = discovery["example"] { call } else { [String: JSONValue]() }
                    return Self.doorRefusal("unknown_key", "Conflicting \(key) and args.\(key). Nothing ran.",
                        remedy: "correct_arguments", "Put the intended value only in args.\(key).",
                        next: example)
                }
                args[key] = input.removeValue(forKey: key)
                corrections.append("\(key) belongs in args.\(key).")
            }
            for key in args.keys.sorted() {
                guard movable(key, args[key]), let supplied = args[key] else { continue }
                var name = ToolNameAliases.argumentName(key, tool: target.isFold ? target.tool : target.id, input: args, known: names)
                var value = supplied
                if name == nil, properties[key] == nil {
                    let matches = properties.compactMap { name, schema -> (String, JSONValue)? in
                        guard case .object(let fields) = schema else { return nil }
                        let variants = if case .array(let variants)? = fields["anyOf"] { variants } else { [JSONValue]() }
                        let values = ([schema] + variants).flatMap { if case .object(let fields) = $0, case .array(let values)? = fields["enum"] { values } else { [JSONValue]() } }
                        guard let match = values.first(where: { candidate in
                            if case .string(let a) = supplied, case .string(let b) = candidate { return a.caseInsensitiveCompare(b) == .orderedSame }
                            return supplied == candidate
                        }) else { return nil }
                        return (name, match)
                    }
                    if matches.count == 1 { name = matches[0].0; value = matches[0].1 }
                }
                guard let name, names.contains(name), args[name] == nil || args[name] == .null || args[name] == value else { continue }
                args.removeValue(forKey: key)
                args[name] = value
                corrections.append("Use args.\(name), not args.\(key).")
            }
            if target.id == "agent.message", let supported = AgentConversationRouting.supportedOptions(agent: Self.doorText(args["agent"]).lowercased()),
               case .object(let options)? = properties["options"],
               case .object(let fields)? = options["properties"] {
                var supplied = if case .object(let given)? = args["options"] { given } else { [String: JSONValue]() }
                let required = if case .array(let names)? = options["required"] { names } else { [JSONValue]() }
                for key in fields.keys.sorted() where !supported.contains(key) && !required.contains(.string(key)) {
                    let values = [input.removeValue(forKey: key), args.removeValue(forKey: key), supplied.removeValue(forKey: key)]
                    if values.contains(where: { $0 != nil && $0 != .null }) {
                        corrections.append("Dropped \(key); \(Self.doorText(args["agent"])) does not support it.")
                    }
                }
                if case .object? = args["options"] { args["options"] = .object(supplied) }
            }
            input["args"] = .object(args)
        }
        // A page's own item named alone (doctor) opens on its page, unless home already uses that name.
        if Self.doorText(input["page"]).isEmpty, case .string(let named)? = input["item"] {
            let owners = Self.doorItemReads.filter { $0.value[named.lowercased()] != nil }.map(\.key)
            if owners.count == 1, !(await HerScreen.isName(named, dataRoot: quietHost()?.dataRootOverride ?? PersistenceCore.defaultDataRoot(),
                    scope: Self.inputString(input["__session_id"]) ?? ChatToolSessionContext.verifiedSessionId ?? "")) {
                input["page"] = .string(owners[0])
            }
        }
        // Other keys app does not take still fail loudly.
        let stray = input.keys.filter { !Self.doorKeys.contains($0) && !$0.hasPrefix("__") }.sorted()
        if !stray.isEmpty {
            if stray.count == 1, action.isEmpty,
               let correction = Self.doorActionCorrection(stray[0], input: input.merging(["args": input[stray[0]]!]) { _, value in value }) {
                return try await runCorrectedRead(correction, input: input, surface: surface, inProcess: inProcess)
            }
            return Self.doorRefusal("unknown_key",
                "app takes no \(stray.joined(separator: ", ")). Its keys are page, item, action, args, preview, "
                + "expected_version, find and script; an action's own arguments go inside args. Nothing was read or done.",
                remedy: "correct_arguments", "Call app again with only those keys; {} lists the pages.",
                next: [:], extra: ["unrecognised": .array(stray.map(JSONValue.string)),
                                   "valid": .array(Self.doorKeys.sorted().map(JSONValue.string))])
        }
        if let value = input["script"], value != .null, value != .string("") {
            // One call is one thing: the gates and the plan judge it by its
            // action, so a script never rides under one.
            guard action.isEmpty else {
                return Self.doorRefusal("action_and_script",
                    "app takes an action or a script, not both. Nothing was run.", remedy: "correct_arguments",
                    "Call app again with only the action and its args, or only the script.")
            }
            guard case .string(let script) = value else {
                return Self.doorRefusal("invalid_script", "script must be a JavaScript function body. Nothing was run.",
                    remedy: "correct_arguments", "Use script:\"return [app.files.list({path:'docs'}), app.desk.read({})];\".")
            }
            return Self.previewApproval(await doorScript(script, input: input), preview: input["preview"] == .bool(true))
        }
        // A name from her screen given as an action (desk.3407.note, as an
        // item's DO list shows it) is that item: it opens as one.
        if !action.isEmpty, AppActions.action(action) == nil, ToolNameAliases.retiredActions[action.lowercased()] == nil,
           input[Self.doorScriptKey] != .bool(true),
           await HerScreen.isName(action, dataRoot: quietHost()?.dataRootOverride ?? PersistenceCore.defaultDataRoot(),
                                  scope: Self.inputString(input["__session_id"]) ?? ChatToolSessionContext.verifiedSessionId ?? "") {
            var item = input.filter { !["action", "page", "item"].contains($0.key) }
            item["item"] = .string(action)
            return try await runAppDoor(input: item, surface: surface, inProcess: inProcess)
        }
        if !action.isEmpty {
            var value = try await doorDo(action, input: input, surface: surface, inProcess: inProcess)
            if !corrections.isEmpty, case .object(var fields) = value {
                fields["argument_notes"] = .array(corrections.map(JSONValue.string))
                value = .object(fields)
            }
            if let action = AppActions.action(action), case .object(var fields) = value {
                let args: [String: JSONValue] = if case .object(let args)? = input["args"] { args } else { [:] }
                fields.merge(action.effectFields(args: args)) { _, value in value }
                if fields["execution"] == nil { fields["execution"] = .string("not_run") }
                value = .object(fields)
            }
            return Self.previewApproval(value, preview: input["preview"] == .bool(true))
        }
        let find = Self.doorText(input["find"])
        let page = Self.doorText(input["page"])
        var item = Self.doorText(input["item"])
        if !page.isEmpty, doorPage(page) == nil, let correction = Self.doorActionCorrection(page, input: input) {
            return try await runCorrectedRead(correction, input: input, surface: surface, inProcess: inProcess)
        }
        if !item.isEmpty, let correction = Self.doorActionCorrection(item, input: input) {
            return try await runCorrectedRead(correction, input: input, surface: surface, inProcess: inProcess)
        }
        if !item.isEmpty, Self.doorItemReads[doorPage(page)?.id ?? ""] == nil {
            let name = item.hasPrefix("skill:") ? String(item.dropFirst(6)).trimmingCharacters(in: .whitespaces) : item
            if case .object(let skill)? = InstalledSkillInventory.list(dataRoot: quietHost()?.dataRootOverride ?? PersistenceCore.defaultDataRoot())
                .first(where: { if case .object(let row) = $0 { Self.doorText(row["name"]).caseInsensitiveCompare(name) == .orderedSame } else { false } }) {
                var args = given ?? [:]
                args["name"] = skill["name"]
                return Self.doorRefusal("skill_route", "That names a skill. Nothing ran.", remedy: "read_skill",
                    "Make next_call to read its body.", next: ["action": .string("skill.read"), "args": .object(args)])
            }
        }
        // Her home (one-door phase 2 step 7, what was `workspace`): an item
        // with no page is a name or ref from home or one of its rooms.
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
            if item.lowercased().hasSuffix(".say") {
                var args = given ?? [:]
                args["agent"] = .string(String(item.dropLast(4)))
                return Self.doorRefusal("item_not_previewable",
                    "Use agent.message to preview an agent message. Nothing was sent.",
                    remedy: "correct_route", "Make next_call with the message text and preview:true.",
                    next: ["action": .string("agent.message"), "args": .object(args), "preview": .bool(true)])
            }
            return Self.doorRefusal("item_not_previewable",
                "A home item opens or does what its name says at once; it takes no preview or expected_version. Nothing was read or done.",
                remedy: "correct_arguments",
                "Call app {item} again without preview or expected_version; open its room first to see what it does.")
        }
        if !find.isEmpty && !homeItem { return try await doorFind(find) }
        if homeItem || page.lowercased() == "home" {
            var call: [String: JSONValue] = [:]
            if !item.isEmpty { call["action"] = .string(item) } else if !find.isEmpty { call["query"] = .string(find) }
            if case .object(let args)? = input["args"] {
                if let stray = args.keys.sorted().first(where: { !["text", "fields", "conversation", "expects_reply"].contains($0) }) {
                    return Self.doorRefusal("unknown_arg",
                        "A home item takes text, fields, or an agent conversation label and expects_reply in args, not \(stray). Nothing was read or done.",
                        remedy: "correct_arguments", "Call app again with args {text, conversation?, expects_reply?} for an agent message, {fields} for a form, or none.",
                        extra: ["argument_path": .string("args.\(stray)")])
                }
                for (key, value) in args where value != .null { call[key] = value }
            }
            return await doorHome(call, input: input)
        }
        if page.isEmpty { return await doorIndex(input) }
        if let corner = SenseCorner(key: page), let result = try await doorSenseRead(corner: corner, item: item, input: input) {
            return result
        }
        guard let resolved = doorPage(page) else {
            if await HerScreen.isName(page, dataRoot: quietHost()?.dataRootOverride ?? PersistenceCore.defaultDataRoot(),
                                      scope: Self.inputString(input["__session_id"]) ?? ChatToolSessionContext.verifiedSessionId ?? "") {
                return Self.doorRefusal("home_item", "That is a home item.", remedy: "open_item",
                    "Open it with item instead of page.", next: ["item": .string(page)])
            }
            return Self.doorRefusal("unknown_page", "No page is called that.", remedy: "read_index",
                "Read {} for the pages; nothing was done.", next: [:],
                extra: ["requested": .string(page), "pages": .array(doorPages.map { .string($0.id) })])
        }
        switch input["args"] {
        case .object(let args)?:
            let acceptsLimit = resolved.id == "chat" && !item.isEmpty && !item.hasPrefix("guide:")
            if let stray = args.keys.sorted().first(where: { !acceptsLimit || $0 != "limit" }) {
                return Self.doorRefusal("unknown_arg", "A \(resolved.id) page read takes no args.\(stray). Nothing was read.",
                    remedy: "correct_arguments", "Read the page without that argument. To select a target, use an action with args; find returns its signature.",
                    extra: ["argument_path": .string("args.\(stray)")])
            }
            if let limit = args["limit"], limit != .null,
               let problem = Self.doorTypeProblem(limit, schema: .object(["type": .string("integer")]), path: "args.limit") {
                return Self.doorRefusal("bad_input", "\(problem.path) must be \(problem.type). Nothing was read.",
                    remedy: "correct_arguments", "Pass an integer limit for this conversation read.",
                    extra: ["argument_path": .string(problem.path)])
            }
        case nil, .null?: break
        default:
            return Self.doorRefusal("invalid_args", "Page args must be an object. Nothing was read.",
                remedy: "correct_arguments", "Omit args, or pass only arguments this page read accepts.",
                extra: ["argument_path": .string("args")])
        }
        let catalog = item == "actions"
        // A conversation named by its exact title, when exactly one has it.
        if resolved.id == "chat", !item.isEmpty, !catalog, !item.hasPrefix("guide:"),
           let rows = try? HumanConversationIndex.rows(dataRoot: quietHost()?.dataRootOverride ?? PersistenceCore.defaultDataRoot()),
           !rows.contains(where: { HumanConversationIndex.string($0["id"]) == item }) {
            let named = rows.filter { HumanConversationIndex.string($0["title"])?.caseInsensitiveCompare(item) == .orderedSame }
            if named.count == 1, let id = HumanConversationIndex.string(named[0]["id"]) { item = id }
        }
        if resolved.id == "desk", !item.isEmpty, !catalog, !item.hasPrefix("guide:") {
            return try await doorDo("desk.read", input: ["args": .object(["handle": .string(item)])],
                                    surface: surface, inProcess: inProcess)
        }
        let result = try await doorRead(page: resolved, item: catalog ? "" : item)
        guard case .object(var read) = result, read["status"] == .string("ok") else { return result }
        read["version"] = .string(Self.doorVersion(page: resolved.id, item: catalog ? "" : item, read))
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
        // "This chat" is where the request came from, which is not always the
        // conversation on screen (a bridge, phone or Telegram turn).
        if resolved.id == "chat", item.isEmpty, let asking = ChatToolSessionContext.verifiedSessionId, !asking.isEmpty {
            let onScreen: String? = if case .object(let composer)? = read["item"] { Self.inputString(composer["conversation"]) } else { nil }
            if onScreen != asking {
                read["this_conversation"] = .object(["session_id": .string(asking),
                    "note": .string("The conversation this request came from. \"This chat\" means this one; omit session_id or pass this id. Other conversations here are what the owner has on screen.")])
            }
        }
        let hasSettings = if case .array(let rows)? = read["settings"] { !rows.isEmpty } else { false }
        let unready = AgentWorkspaceReadiness.unreadyTools(dataRoot: quietHost()?.dataRootOverride ?? PersistenceCore.defaultDataRoot())
        let actions = Self.doorPageActions(resolved.id, hasSettings: hasSettings)
        let compact = actions.count > 12 && !catalog
        read["actions"] = .array(actions.map { .string(compact
            ? $0.id + (unready[$0.tool].map { " (unavailable: " + $0 + ")" } ?? "")
            : Self.doorActionLine($0, unready: unready)) })
        if compact { read["actions_read"] = .object(["page": .string(resolved.id), "item": .string("actions")]) }
        // One example teaches the preview shape; the action lines name the rest.
        read["preview_examples"] = .array(actions.filter { $0.irreversible && $0.page != "*" }.prefix(1).compactMap {
            if case .object(let discovery) = AppActions.discovery($0) { discovery["example"] } else { nil }
        })
        // The complete Mac act guide is an explicit read on this same page;
        // other actions' argument rules ride find's args_schema and refusals.
        let guides = actions.filter { $0.id == "mac.act" }
        if !guides.isEmpty {
            read["guide_reads"] = .object(Dictionary(uniqueKeysWithValues: guides.map {
                ($0.id, .object(["page": .string(resolved.id), "item": .string("guide:" + $0.id)]))
            }))
            read["guide_note"] = .string(guides.map {
                "Only before \($0.id) actions, read app {page:\"\(resolved.id)\", item:\"guide:\($0.id)\"}. Plain reads (mac.look, mac.system_info, mac.volume with no args) need no guide."
            }.joined(separator: " "))
        }
        return .object(read)
    }

    // MARK: - Reads

    private static func doorPageActions(_ page: String, hasSettings: Bool) -> [AppAction] {
        AppActions.on(page: page).filter { $0.id != "setting.set" || hasSettings }
    }

    private static func doorActionLine(_ action: AppAction, unready: [String: String]) -> String {
        action.line + (unready[action.tool].map { " Unavailable: " + $0 } ?? "")
    }

    /// Home first: open agent windows, what is in progress, what waits and
    /// what arrived (`home`, which sorts first), then every page.
    @MainActor
    private func doorIndex(_ input: [String: JSONValue]) async -> JSONValue {
        let posture = await Self.freshQuietPosture()
        let unready = AgentWorkspaceReadiness.unreadyTools(dataRoot: quietHost()?.dataRootOverride ?? PersistenceCore.defaultDataRoot())
        return .object([
            "home": await doorHome([:], input: input),
            "status": .string("ok"),
            "pages": .array(doorPages.map { page in
                let hasSettings = !QuietSettings.settings(forPage: page.id, host: quietHost()).isEmpty
                let ids = Self.doorPageActions(page.id, hasSettings: hasSettings)
                    .filter { $0.page != "*" }.map {
                        $0.id + (unready[$0.tool].map { " (unavailable: " + $0 + ")" } ?? "")
                    }
                return .string("\(page.id): \(page.title). \(page.summary)"
                    + (ids.isEmpty ? "" : " Actions: " + ids.joined(separator: ", ")))
            }),
            "on_every_page": .array(AppActions.all.filter { $0.page == "*" }.map {
                .string(Self.doorActionLine($0, unready: unready))
            }),
            "trust_mode": .string(posture?.name ?? "unreadable"),
            "note": .string("home is where you left off; any name on it opens with item. "
                + "Read a page for what it shows, its version, and each action's args. "
                + (posture?.name == Self.fullMacModeName
                    ? "Full Mac is on: actions marked the owner's below Full Mac are yours too, and the owner sees each one you run. Actions needing the owner in person remain theirs. "
                    : "The owner's actions refuse with why and where they do them. ")
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
                "Nothing to retry until Trust reads again; the owner can check it in Trust.")
        }
        guard SwiftNativeTrustCenter.hasExplicitBlockOverride(tool, overrides: snapshot.userConfiguredAutonomyOverrides)
        else { return nil }
        return Self.doorRefusal("blocked_in_trust",
            "The owner blocked \(tool) in Trust, and this is \(tool)'s. Nothing was read or done.", remedy: "none",
            "Nothing to retry: unblocking it is the owner's, in Trust.", extra: ["tool": .string(tool)])
    }

    /// What the page or item shows now, read in process.
    /// Its version hashes only what the person would see change (content,
    /// settings, items), not the accessibility tree.
    @MainActor
    private func doorRead(page: QuietToolPage, item: String) async throws -> JSONValue {
        if item.hasPrefix("guide:"),
           let action = AppActions.on(page: page.id).first(where: { "guide:" + $0.id == item && AppActions.guided.contains($0.id) }),
           let guide = AppActions.about(action) {
            return .object(["status": .string("ok"), "page": .string(page.id), "item": .string(item),
                            "guide": .object([action.id: .string(guide)])])
        }
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
                                "shown": list["shown"] ?? .null, "needs_you_count": list["needs_you_count"] ?? .null,
                                "items": .array(notes.map { note in
                                    guard case .object(let row) = note else { return note }
                                    let title = String(Self.doorText(row["title"]).split(whereSeparator: \.isWhitespace).joined(separator: " ").prefix(120))
                                    return .string("\(Self.doorText(row["id"])) | kind=\(Self.doorText(row["source"])) | \(title) | unread=\(row["status"] == .string("unread")) | needs-you=\(row["needs_you"] == .bool(true))")
                                })])
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
            if page.id == "diagnostics", await doorSavedBlock("skill_manage") == nil {
                do {
                    read["stopped_run_ids"] = .array(try SkillRunStore.waitingIDs(root: host.dataRootOverride ?? PersistenceCore.defaultDataRoot()).map(JSONValue.string))
                    read["resume_note"] = .string("stopped_run_ids are saved targets for skill.resume; an empty list means none. Resume rechecks the seal, skill and replayed reads.")
                } catch { read["resume_note"] = .string("Stopped runs unavailable: \(error.localizedDescription)") }
            }
            return .object(read)
        }
    }

    static func doorVersion(page: String, item: String, _ read: [String: JSONValue]) -> String {
        var fields = read.filter { ["content", "settings", "items", "item", "count"].contains($0.key) }
        if page == "chat", !item.isEmpty, case .object(let composer)? = fields["item"] {
            // Turn progress and context usage do not edit the draft.
            fields["item"] = .object(composer.filter { ["conversation", "draft", "attachments", "provider", "model", "think", "fast", "persona"].contains($0.key) })
        }
        let shown = JSONValue.object(fields)
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
    private func doorFind(_ query: String) async throws -> JSONValue {
        let asked = AppActions.intentWords(query)
        let photosRead = AppActions.photosIntent(query)
        let root = quietHost()?.dataRootOverride ?? PersistenceCore.defaultDataRoot()
        let permissions = try? await MacIntegrationPermissionStore(dataRoot: root).readinessChecked()
        let titles = Dictionary(doorPages.map { ($0.id, $0.title) }, uniquingKeysWith: { first, _ in first })
        var senses: [SenseRecord] = []
        var sensesError: String?
        do { senses = try await SensesHub.shared.registry?.all() ?? [] }
        catch { sensesError = error.localizedDescription }
        let active = Set(senses.filter { $0.status == .on }.map(\.id))
        let unready = AgentWorkspaceReadiness.unreadyTools(dataRoot: root)
        let (ranked, degraded) = await AppActions.ranked(query, titles: titles, dataRoot: root)
        let actions = ranked.prefix(5)
        let pages = doorPages.map { page in
            (page, AppActions.hits(Set(AppActions.intentWords(page.id + " " + page.title + " " + page.summary)), asked))
        }.filter { $0.1 > 0 }.sorted { $0.1 > $1.1 }.prefix(3)
        let skills = AppActions.skills(asked, dataRoot: root).prefix(3)
        let archived = AppActions.archivedTools(asked, dataRoot: root).prefix(2)
        let reads: [JSONValue] = ["crews", "delegations", "workshop", "tasks", "helper"].filter { word in
            AppActions.words(query).contains { $0 == word || $0 == word + "s" } }.map {
            switch $0 {
            case "helper": .object(["action": .string("bot.list"), "args": .object(["details": .bool(true)])])
            case "workshop": .object(["action": .string("workshop.status"), "args": .object([:])])
            case "tasks": .object(["action": .string("ledger.list"), "args": .object(["include_done": .bool(true)])])
            default: .object(["item": .string($0)])
            }
        }
        var found: [String: JSONValue] = [
            "status": .string(actions.isEmpty && pages.isEmpty && skills.isEmpty && archived.isEmpty && reads.isEmpty ? "not_found" : "ok"),
            "find": .string(query),
            "matched_actions": .int(Int64(ranked.count)), "shown_actions": .int(Int64(actions.count)),
            "actions": .array(actions.map { action in
                let permissionBlocker = ToolPreloadHeuristics.macIntegrationGates[action.tool].flatMap {
                    permissions?.refusal(integration: $0.integration, mode: $0.mode)
                }
                let blocker = permissionBlocker ?? (action.tool == "sense_act" ? sensesError : nil)
                    ?? (action.tool == "sense_act" && !active.contains(Self.doorText(action.input["sense_id"]))
                        ? "This sense is off; turn it on from its page." : unready[action.tool])
                var discovered = AppActions.discovery(action, blocker: blocker)
                if action.id == "schedule.create", AppActions.timerIntent(query), case .object(var fields) = discovered {
                    fields["example"] = .object(["action": .string("schedule.create"), "args": .object([
                        "kind": .string("notify"), "payload": .object(["message": .string("Timer finished.")]),
                        "in_minutes": .int(10)])])
                    discovered = .object(fields)
                }
                return discovered
            }
                + archived.map { .object(["page": .string("diagnostics"), "action": .string($0)]) }),
            "pages": .array(pages.map { .string("\($0.0.id): \($0.0.title). \($0.0.summary)") }),
            "read_next": .array(reads),
            "note": .string("find discovers actions, including on home. Search saved work and conversations explicitly with work.context {query}, or chat.search {query}. Reversible actions run directly; irreversible examples include preview:true to report checks without running. Example values in <angle brackets> must be replaced with your values."),
        ]
        if let degraded { found["ranking_degraded"] = .string("Ranked by words only: " + degraded) }
        if let sensesError { found["senses_error"] = .string(sensesError) }
        let words = AppActions.words(query)
        if AppActions.hits(["mail", "inbox"], asked) > 0, !AppActions.windowIntent(query) {
            found["mail_read_note"] = .string("For Mail content, use mail.recent, mail.search or mail.read directly; do not use mac.look or mac.go on Mail.")
        }
        if AppActions.hits(["mail"], asked) > 0,
           AppActions.hits(["create", "compose", "draft", "send", "reply", "save"], asked) > 0,
           let refusal = permissions?.refusal(integration: MacIntegrationID.mail, mode: .write) {
            found["mail_write_note"] = .string(refusal)
        }
        if photosRead {
            found["photos_note"] = .string("Use photos.count for library counts and photos.recent for newest asset metadata; both accept creation-date and media-type filters. Photos access is requested only when called. These actions read metadata, not image contents.")
        }
        if AppActions.timerIntent(query) {
            found["timer_note"] = .string("Use schedule.create with kind notify, payload.message and in_minutes for a one-time timer; schedule:'in 10 minutes' also works. No Clock app or time.now read is needed. For an alarm at a specific time, supply that datetime as schedule.")
        }
        let information = ["what", "whats", "who", "when", "where", "why", "how"].contains(words.first ?? "")
            || AppActions.hits(["weather", "forecast", "temperature", "news", "price"], asked) > 0
        if words.contains("near") && words.contains("me") {
            found["location_note"] = .string("This Mac has no current location reader. The owner's location is unknown; a timezone does not identify their city. Ask for a city or use phone.request {kind:\"location.current\"} if they want to share their phone's location; an expired request is not a location.")
        }
        // "my …" with no strong local action (battery, IP, volume have one) is a personal fact to look up.
        let strongLocal = ranked.contains(where: { !$0.id.hasPrefix("web.") && AppActions.score($0, asked, pageTitle: titles[$0.page] ?? "") >= 8 })
        if words.contains("my"), information || words.first == "my", !strongLocal, !photosRead, actions.first?.id != "weather.forecast" {
            found["next_call"] = .object(["action": .string("work.context"), "args": .object(["query": .string(query)])])
            found["next_note"] = .string("Mail, Messages and Notes can hold personal facts. Start with work.context for saved work, conversations and recent Mail sender/subject matches; open an observed mail.N to read its body. If needed, search Messages or Notes directly before asking the person.")
        } else if information, !photosRead, actions.first?.id != "weather.forecast", !ranked.contains(where: {
            !$0.id.hasPrefix("web.") && AppActions.score($0, asked, pageTitle: titles[$0.page] ?? "") >= 8
        }) {
            found["next_call"] = .object(["action": .string("web.search"), "args": .object(["query": .string(query)])])
            found["read_with"] = .object(["action": .string("web.read"),
                "args": .object(["url": .string("<URL from search result>")])])
            found["next_note"] = .string("No strong local action matches this information question. Search the web, then read a result URL with web.read.")
        }
        if !skills.isEmpty {
            found["skills"] = .array(skills.map { .object(["name": .string($0.name), "about": .string($0.about),
                "next_call": .object(["action": .string("skill.read"), "args": .object(["name": .string($0.name)])])]) })
            found["skills_note"] = .string("Read a matching skill with skill.read {name}; guidance is followed directly, and an admitted active script skill can run with skill.run.")
        }
        let corners = senses.filter { record in
            record.status == .on && AppActions.intentWords(record.corner.key + " " + record.id + " " + record.verbs.joined(separator: " "))
                .contains { word in asked.contains(word) }
        }.prefix(3)
        if !corners.isEmpty {
            found["status"] = .string("ok")
            found["corners"] = .array(corners.map { .string($0.corner.key + ": " + $0.verbs.joined(separator: ", ")) })
        }
        return .object(found)
    }

    // MARK: - Script

    /// Every preview says who would receive a card, including refusals that
    /// stop before card filing and script previews of the calls reached.
    static func previewApproval(_ value: JSONValue, preview: Bool) -> JSONValue {
        guard preview, case .object(var fields) = value else { return value }
        fields["execution"] = .string("preview")
        fields["effects"] = .string("none")
        if fields["would_card"] == nil { fields["would_card"] = .bool(false) }
        fields["approver"] = fields["would_card"] == .bool(true) ? .string("owner") : .null
        return .object(fields)
    }

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
        if id.lowercased() == "find", !Self.doorText(input["find"]).isEmpty {
            return Self.doorRefusal("action_route", "find is an app key, not an action. Nothing ran.",
                remedy: "correct_route", "Make next_call to discover matching actions.",
                next: ["find": input["find"]!])
        }
        guard let action = AppActions.action(id) else {
            let qualified = Self.doorText(input["page"]) + "." + id
            if let correction = Self.doorActionCorrection(qualified, input: input) { return correction }
            if let correction = Self.doorActionCorrection(id, input: input) { return correction }
            return Self.doorRefusal("unknown_action", "No action is called that. The nearest are in nearest; {} lists them all. "
                + "A name or ref from home (desk.4, mail.find, an agent's name) opens with item, not action.",
                remedy: "find", "Use one of nearest, find it by what you want done, or open a home name with item; nothing was done.",
                next: ["find": .string(id)],
                extra: ["requested": .string(id),
                        "nearest": .array(await AppActions.ranked(id, titles: [:],
                            dataRoot: quietHost()?.dataRootOverride ?? PersistenceCore.defaultDataRoot())
                            .actions.prefix(3).map { .string($0.line) })])
        }
        let root = quietHost()?.dataRootOverride ?? PersistenceCore.defaultDataRoot()
        // User, 10-02: under Full Mac his actions are hers too. The code each
        // runs posts the decided row he sees it by.
        let fullMac = action.isHis ? await Self.freshQuietPosture(dataRoot: root)?.name == Self.fullMacModeName : false
        var receipt: [String: JSONValue] = [
            "action": .string(action.id), "page": .string(action.page), "label": .string(action.label),
            "owner": .string(action.isHis && !fullMac ? "his" : "hers"), "execution": .string("not_run"),
        ]
        // A folded tool's whole description rides what refuses or previews it.
        if let about = AppActions.about(action) { receipt["about"] = .string(about) }
        func badArgs(_ reason: String, _ detail: String, _ path: String) -> JSONValue {
            var extra = receipt
            extra["argument_path"] = .string(path)
            var example = if case .object(let discovery) = AppActions.discovery(action),
                case .object(let call)? = discovery["example"] { call } else { [String: JSONValue]() }
            if input["preview"] == .bool(true) { example["preview"] = .bool(true) }
            if let version = input["expected_version"] { example["expected_version"] = version }
            return Self.doorRefusal(reason, detail, remedy: "correct_arguments",
                "Use this call shape with your intended values. Nothing ran.", next: example, extra: extra)
        }
        let args: [String: JSONValue]
        switch input["args"] {
        case .object(let given)?:
            if case .object(let discovery) = AppActions.discovery(action), let schema = discovery["args_schema"] {
                args = ToolArguments.normalized(given, schema: schema)
            } else { args = given.filter { $0.value != .null } }
        case nil, .null?: args = [:]
        default: return badArgs("invalid_args", "args is an object of the action's arguments by name: \(action.line)", "args")
        }
        let read = action.readOnly(args: args)
        let specs = action.argSpecs
        let known = Set(specs.flatMap(\.names))
        // An MCP or authored tool whose schema lists no arguments takes what it is given.
        let open = specs.isEmpty && (ToolNameAliases.mcpAction(action.tool) != nil || ToolNameAliases.authoredTool(action.id) != nil)
        if !open, let stray = args.keys.sorted().first(where: { !known.contains($0) }) {
            return badArgs("unknown_arg", "\(action.id) takes no \(stray): \(action.line)", "args.\(stray)")
        }
        // Setting request evidence has its own refusal and applies only to model turns.
        let validationArgs = action.id == "setting.set" ? args.merging(["because": .string("")]) { _, check in check } : args
        if let missing = specs.first(where: { spec in !spec.optional && !spec.names.contains { validationArgs[$0] != nil } }) {
            return badArgs("missing_arg", "\(action.id) needs \(missing.names.joined(separator: " or ")): \(action.line)",
                           "args.\(missing.names[0])")
        }
        if case .object(let discovery) = AppActions.discovery(action), let schema = discovery["args_schema"],
           let problem = Self.doorTypeProblem(.object(validationArgs), schema: schema, path: "args") {
            return badArgs("bad_input", "\(problem.path) must be \(problem.type): \(action.line)", problem.path)
        }
        // Validate before an owner-only preview can claim a callable target.
        if fullMac, action.tool.isEmpty, case .his(let why, _) = action.owner {
            receipt["owner"] = .string("his")
            return Self.doorRefusal("needs_person",
                "Under Full Mac \(action.id) is yours, but it needs the owner in person: \(why). Nothing was done.",
                remedy: "ask_user", "Ask the owner to do it at the Mac; nothing to retry until they have.", extra: receipt)
        }
        if !fullMac, case .his(let why, let instead) = action.owner {
            receipt["why"] = .string(why)
            if let instead { receipt["instead"] = .string(instead) }
            if input["preview"] == .bool(true) {
                receipt["status"] = .string("preview")
                receipt["checks_not_run"] = .array([.string("Target, policy preflight and execution checks: this action belongs to the owner.")])
                receipt["detail"] = .string("Would refuse: that's the owner's, \(why). Nothing was done.")
                return .object(receipt)
            }
            return Self.doorRefusal("users_call", "That's the owner's: \(why). Nothing was done.",
                remedy: instead == nil ? "none" : "use_instead",
                instead.map { "Leave it for the owner, or if it is what you need: \($0)." }
                    ?? "Nothing to retry: it is the owner's. Leave it for them.",
                extra: receipt)
        }
        // Why she put it away, on the receipt that lands in her transcript.
        // Never under `reason`: that key is the machine refusal code the
        // runner and the floor check classify on.
        if let reason = Self.inputString(args["reason"]) { receipt["reason_given"] = .string(String(reason.prefix(280))) }
        var call: [String: JSONValue] = [:]
        for (key, value) in args { call[action.rename[key] ?? key] = value }
        for (key, value) in action.input { call[key] = value }
        if action.id == "mac.look", args["__sense_screen_frame"] != nil {
            let cursor = args.filter { ["app", "__sense_screen_frame", "__sense_text_offset"].contains($0.key) }
            call["__sense_address"] = .string(try JSONValue.object(cursor).serialize(pretty: false))
        }
        // What runs under it, by the host call's own names: its verb is not
        // the action's (inbox.acknowledge runs archive). A key or token never
        // rides a receipt.
        var shown = MacInjectionArgRedaction.redacted(tool: action.tool, input: call)
        for name in action.secretArgs where shown[action.rename[name] ?? name] != nil {
            shown[action.rename[name] ?? name] = .string("[redacted]")
        }
        receipt["underlying_call"] = .object(["input": .object(shown)])

        let expected = Self.doorText(input["expected_version"])
        let scope = expected.split(separator: "@", maxSplits: 1).first.map(String.init) ?? action.page
        let returnsVersion = !read && (!expected.isEmpty || action.page == "chat")
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
        if let address = input["__sense_address"] { call["__sense_address"] = address }
        // A skill's run is a strict script run of its own, its preview too.
        if action.id == "skill.run" || action.id == "skill.resume" {
            if let blocked = await doorSavedBlock(action.tool) { return blocked }
            return Self.actionResult(await doorSkill(action.id, args: args, input: input, surface: surface), action: action, args: args)
        }
        guard AppDoorReentry.perform != nil || inProcess else {
            return Self.doorRefusal("door_unavailable",
                "This call did not come through a chat's tool chain, so it has no gate to pass. Nothing was read or done.",
                remedy: "none", "Use app from a chat turn.")
        }
        if input["preview"] == .bool(true) {
            receipt["status"] = .string("preview")
            receipt["checks_not_run"] = .array([
                "Live target existence, identity and eligibility unless explicitly checked below",
                "Connector authentication and macOS permission prompts",
                "File contents and sense views unless explicitly checked below",
                "Action-internal approval, execution, delivery and effect verification",
            ].map(JSONValue.string))
            receipt["preview_scope"] = .string(action.id == "backup.restore"
                ? "public_arguments_policy_and_backup_target" : ["read_file", "list_dir", "file_excerpt"].contains(action.tool)
                    ? "public_arguments_policy_and_local_file_target" : "public_arguments_and_available_policy_checks")
            // The checks the real call makes before it touches anything, read
            // now through the same functions: a preview refuses what it would.
            var refusal: JSONValue?
            // Only where the real call would run: elsewhere it refuses
            // door_unavailable, not a missing window.
            refusal = await doorSavedBlock(action.tool)
            if refusal == nil { refusal = await foldedRefusal(action, input: call, surface: surface) }
            if let refused = refusal {
                refusal = Self.foldedResult(ChatToolOutcome.normalizedFailure(refused, tool: action.tool), about: nil, tool: action.tool)
            }
            guard case .object(let refused)? = refusal, refused["status"] != .string("would") else {
                receipt["would_card"] = .bool(await doorWouldCard(action, call: call, input: input, surface: surface))
                receipt["detail"] = .string("Arguments and available preflight checks passed. See checks_not_run; this does not prove the action can run. Nothing was done.")
                // A lifecycle preview says what the call would leave, in its own words.
                if case .object(let would)? = refusal {
                    receipt.merge(would.filter { !["status", "detail"].contains($0.key) }) { $1 }
                    receipt["detail"] = .string(Self.doorText(would["detail"]) + " Nothing was done.")
                }
                return .object(receipt)
            }
            // A card only User answers, on the glass, says why under reason.
            let glass = refused["status"] == .string("needs_glass")
            let failureCode = Self.doorText(refused["failure_code"])
            let code = glass ? "needs_glass" : failureCode.isEmpty ? Self.doorText(refused["reason"]) : failureCode
            let why = glass ? Self.doorText(refused["reason"]) : ["detail", "message", "reason"]
                .map { Self.doorText(refused[$0]) }.first { !$0.isEmpty } ?? ""
            receipt["would_refuse"] = .string(code)
            for (key, value) in refused where key.hasPrefix("would_") || ["versions", "tools", "argument_path", "backups", "remedy"].contains(key) { receipt[key] = value }
            if glass || Self.doorFloorReasons.contains(code) {
                receipt["owner"] = .string("his")
                receipt["why"] = .string(why)
            }
            receipt["detail"] = .string("Would refuse: \(code). \(why) Nothing was done.")
            return .object(receipt)
        }
        // Skills: one step of a script skill reads here; a list does upkeep only with write authority.
        if action.id == "skill.read", args["step"] != nil {
            if let blocked = await doorSavedBlock(action.tool) { return blocked }
            return Self.actionResult(Self.skillStepRead(Self.doorText(args["name"]), step: args["step"], root: root), action: action, args: args)
        }
        if action.id == "skill.list", await Self.freshQuietPosture(dataRoot: root)?.changesAllowed == true {
            await Self.skillUpkeep(root: root)
        }
        // A folded tool answers as its direct call did: its own result, its
        // own gates (User's saved level on it among them) and its own card.
        if action.isFold || action.id == "chat.list" {
            let result = Self.foldedResult(try await runFolded(action, input: call, surface: surface), about: receipt["about"],
                                          browser: action.tool.hasPrefix("browser."), tool: action.tool)
            let folded = Self.actionResult(result, action: action, args: args)
            // A versioned write says the version it left, as the app's own buttons do.
            guard returnsVersion, case .object(var fields) = folded,
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
        let watch = !read
        let notesBefore = if !watch { [(id: String, title: String)]?.none }
            else if let held = snapshot?.notes { held } else { await doorNotes() }
        let knocksBefore = watch ? AttentionRouter.deliveredKnocks(dataRoot: root) : [:]
        let result = Self.actionResult(try await runFolded(action, input: call, surface: surface), action: action, args: args)
        let notesAfter = watch ? await doorNotes() : nil
        if watch { snapshot?.notes = notesAfter }
        let knocksAfter = watch ? AttentionRouter.deliveredKnocks(dataRoot: root) : [:]

        // The receipt's status is the code's own: its status, else whether
        // its result reads as a success, never the door's own ok.
        receipt["status"] = .string(ChatToolOutcome.outputLooksSuccessful(result) ? "ok" : "failed")
        if case .object(let fields) = result {
            receipt["execution"] = fields["execution"]
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
                        ? "The owner has a card for it; it runs if they approve. Don't retry."
                        : "Nothing ran, and retrying changes nothing. Leave it for the owner."),
                    "next_call": .null,
                ])
            } else {
                receipt["effects"] = fields["effects"] ?? .string(read ? "none" : "unknown")
                receipt["remedy"] = fields["remedy"] ?? .object([
                    "kind": .string("inspect"),
                    "instruction": .string(read
                        ? "Nothing changed. Resolve the reported prerequisite before reading again."
                        : "Read \(action.page) to see what took effect, then decide; don't replay it blindly."),
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
        if returnsVersion, let after = try? await doorCurrentVersion(scope: scope) {
            receipt["page_version"] = .string(after)
        }
        if watch { receipt["decided_by"] = .string("agent") }
        return .object(receipt)
    }

    /// Validate the same public schema discovery returns, before renaming any arguments.
    private static func doorTypeProblem(_ value: JSONValue, schema: JSONValue, path: String) -> (path: String, type: String)? {
        guard case .object(let fields) = schema else { return nil }
        if case .array(let variants)? = fields["allOf"] {
            for variant in variants {
                if let problem = doorTypeProblem(value, schema: variant, path: path) { return problem }
            }
        }
        for key in ["anyOf", "oneOf"] {
            if case .array(let variants)? = fields[key] {
                let problems = variants.compactMap { doorTypeProblem(value, schema: $0, path: path) }
                if problems.count == variants.count { return (path, problems.map(\.type).joined(separator: " or ")) }
                if key == "oneOf", variants.count - problems.count != 1 { return (path, "exactly one accepted alternative") }
            }
        }
        if let forbidden = fields["not"], doorTypeProblem(value, schema: forbidden, path: path) == nil {
            return (path, "outside the forbidden combination")
        }
        if let constant = fields["const"], value != constant { return (path, "\(constant)") }
        if case .array(let values)? = fields["enum"], !values.contains(value) {
            return (path, values.map { doorText($0) }.joined(separator: " or "))
        }
        let types: [String]
        switch fields["type"] {
        case .string(let type)?: types = [type]
        case .array(let list)?: types = list.compactMap { if case .string(let type) = $0 { type } else { nil } }
        default: types = []
        }
        func matches(_ type: String) -> Bool {
            switch (type, value) {
            case ("string", .string), ("boolean", .bool), ("object", .object), ("array", .array),
                 ("null", .null), ("number", .int), ("number", .double), ("integer", .int): return true
            case ("integer", .double(let number)): return Int64(exactly: number) != nil
            default: return false
            }
        }
        if !types.isEmpty, !types.contains(where: matches) { return (path, types.joined(separator: " or ")) }
        if case .string(let text) = value, case .int(let minimum)? = fields["minLength"], text.count < minimum {
            return (path, "at least \(minimum) characters")
        }
        if case .object(let object) = value {
            if case .array(let required)? = fields["required"],
               let missing = required.map({ doorText($0) }).first(where: { object[$0] == nil }) {
                return (path + "." + missing, "present")
            }
            let properties: [String: JSONValue] = if case .object(let props)? = fields["properties"] { props } else { [:] }
            if fields["additionalProperties"] == .bool(false), let unknown = object.keys.sorted().first(where: { properties[$0] == nil }) {
                return (path + "." + unknown, "an accepted argument")
            }
            for name in object.keys.sorted() {
                if let property = properties[name], let problem = doorTypeProblem(object[name]!, schema: property, path: path + "." + name) {
                    return problem
                }
            }
        }
        if case .array(let list) = value {
            if case .int(let minimum)? = fields["minItems"], list.count < minimum { return (path, "at least \(minimum) items") }
            if case .int(let maximum)? = fields["maxItems"], list.count > maximum { return (path, "at most \(maximum) items") }
            if let items = fields["items"] {
                for (index, item) in list.enumerated() {
                    if let problem = doorTypeProblem(item, schema: items, path: "\(path)[\(index)]") { return problem }
                }
            }
        }
        return nil
    }

    /// The registry's read contract supplies the evidence missing from a
    /// generic failure envelope. Preserve an explicitly uncertain mutation.
    private static func actionResult(_ result: JSONValue, action: AppAction, args: [String: JSONValue]) -> JSONValue {
        var fields: [String: JSONValue] = if case .object(let fields) = result { fields } else { ["result": result] }
        fields.merge(action.effectFields(args: args)) { _, value in value }
        let status = doorText(fields["status"])
        fields[fields["execution"] == nil ? "execution" : "dispatch_execution"] = .string(args["dry_run"] == .bool(true) || args["dryRun"] == .bool(true)
            || fields["dry_run"] == .bool(true) || fields["dryRun"] == .bool(true)
            || ["preview", "dry_run"].contains(status) ? "preview"
            : fields["not_run_status"] != nil || status == "not_run" || ChatToolOutcome.neverRan(result)
                || ChatToolOutcome.isWaitingOnPerson(result) ? "not_run"
            : ChatToolOutcome.outputLooksSuccessful(result) ? "executed" : "attempted")
        guard action.readOnly(args: args), !ChatToolOutcome.outputLooksSuccessful(result),
              !ChatToolOutcome.isWaitingOnPerson(result), !ChatToolOutcome.wasCancelled(result),
              !InlineInteractionNeed.isWaiting(result),
              fields["effects_unknown"] != .bool(true),
              fields["effects"] == nil || fields["effects"] == .string("unknown") || fields["effects"] == .string("none") else { return .object(fields) }
        fields["effects"] = .string("none")
        fields["outcome"] = .string("unmet")
        if fields["remedy"] == nil { fields["remedy"] = .object([
            "kind": .string("inspect"),
            "instruction": .string("Nothing changed. Resolve the reported prerequisite before reading again."),
            "next_call": .null,
        ]) }
        return .object(fields)
    }

    /// A folded tool's result as she reads it through the door: a call it
    /// points to by a folded name is that tool's app call, its sentences name
    /// folded tools by action id, its next page's args are the door's names,
    /// and a failure that was not User's or a card carries the tool's whole
    /// description. Data fields are left as they are.
    static func foldedResult(_ result: JSONValue, about: JSONValue?, browser: Bool = false, tool: String = "") -> JSONValue {
        // A browser page's own text names its next steps by tool (scroll for
        // the rest, snapshot to read again): through the door they are app calls.
        if browser, case .string(let page) = result { return .string(browserSteps(page)) }
        guard case .object(var fields) = ToolNameAliases.appCallPointers(result) else { return result }
        if browser, case .string(let page)? = fields["page"] { fields["page"] = .string(browserSteps(page)) }
        if browser, case .string(let note)? = fields["readback_note"] { fields["readback_note"] = .string(browserSteps(note)) }
        if case .object(let next)? = fields["next"] { fields["next"] = .object(ToolNameAliases.doorArgs(tool, next)) }
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
