import Experiences
import AgentWorkspace
import Agents
import TurnTrace
import AuthoredCapabilities
import AttentionRouting
import ChatTurnContracts
import ChatToolRuntime
import AgentConversations
import ChatToolParsing
import CryptoKit
import Foundation
import Privacy

private extension JSONValue {
    var objectValue: [String: JSONValue]? { if case .object(let fields) = self { fields } else { nil } }
    var arrayValue: [JSONValue]? { if case .array(let values) = self { values } else { nil } }
}
import MacIntegration
import NativeAgentCore
import NativeAgentShared
import PersistenceCore
import ToolRegistry
import ToolExecution
import TrustCenter
import Senses
import PersonaEngine
import Desk
// Blueprint: | `AppToolExecutor+AppDoor.swift` | The `app` schema and home/page/item/find/action/actions/script dispatch; self-window `visible` resolves through the mounted presentation before ordinary page lookup; compact expandable action catalogs, read-only conversion census and preserved domain execution receipts; owns version recovery, including sense.versions; generic failures and wrong or absent version scopes use action discovery, never registry scopes as page ids; `undo` re-enters the receipted layout, recipe or setting action's gates and restores through that owner; page action lists and guides use the same originating data root as their rows, including all face-page parts on Tools |

/// `app`: NativeAgent as one always-on door, and her only tool.
///
/// `{}` is her home (where she left off) and then the pages, `{page[, item]}`
/// a read with a version and the page's actions, `{action, args}` one action,
/// `{actions}` many, `{find}` actions by intent, `{item}` a name or ref from home. Every
/// folded action re-enters the complete gate chain under its underlying
/// tool name (`runFolded`); the `app` gate first classifies the registry action.
/// This file adds no gate of its own: it refuses only what is User's below Full Mac, a stale
/// version, and arguments the action does not take.
extension AppToolExecutor {
    public static let doorToolNames = ["app"]

    /// Today's Inbox is a sheet, not a rail page, and the rail's word "inbox"
    /// means Notifications; the door's inbox is the notes.
    static let doorInbox = QuietToolPage.inbox

    @MainActor var doorPages: [QuietToolPage] { [Self.doorInbox] + presentation.pages }
    @MainActor var doorPageIndex: [String: QuietToolPage] { Dictionary(doorPages.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first }) }

    /// "current" is the visible Advanced sidebar page; self-window reads
    /// resolve "visible" through the mounted presentation before page lookup.
    @MainActor func doorPage(_ raw: String) -> QuietToolPage? {
        let key = AppDoorNames.resolve(raw)
        if key == "inbox" { return Self.doorInbox }
        if key == "current" { return presentation.currentPage }
        // Reads outside the index: the composer's context receipt (item: a
        // conversation id) and the Agent view (item: one of its tabs), which
        // is agent_view so it is never read as agents, her contacts.
        return QuietToolPage.unindexed.first { $0.id == key } ?? presentation.page(named: key)
    }

    /// Where a receipt sends her to see what is wrong: Doctor's rows, through the door.
    public static let doorDoctor = "Doctor (app {page:\"diagnostics\", item:\"doctor\"})"

    /// The keys app takes. One starting "__" is the chain's own (`__session_id`).
    static let doorKeys: Set<String> = ["page", "item", "action", "args", "actions", "preview", "expected_version", "find", "script"]

    static func doorText(_ value: JSONValue?) -> String {
        inputString(value)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
    }

    /// One reading of page and item for the door and for scripts: any item
    /// with no page, or on page home, is one of home's names, which can send
    /// or change something (claude.say, desk.4.done).
    static func opensHomeItem(_ input: [String: JSONValue]) -> Bool {
        guard !doorText(input["item"]).isEmpty else { return false }
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
        extra["remedy"] = .object([
            "kind": .string(kind), "instruction": .string(instruction),
            "next_call": next.map { .object(["tool": .string("app"), "input": .object($0)]) } ?? .null,
        ])
        return failure(reason, detail, extra: extra)
    }

    /// The producer supplies the resource, cause and recovery; typed owner evidence survives intact.
    static func ownedFailure(_ error: Error, code: String, owner: String, instruction: String,
                             next: [String: JSONValue], effects: ToolFailureError.Effects) -> JSONValue {
        if error is CancellationError { return ChatToolOutcome.failure(error: error, tool: "app", effects: effects) }
        let producer = ChatToolOutcome.failure(error: ToolFailureError(error.localizedDescription, effects: effects,
            owner: owner, nextCall: ToolFailureError.call("app", next), code: code, instruction: instruction,
            recovery: effects == .unknown ? .reconcile : .inspect), tool: "app")
        if error is ToolFailureError || error is SenseFailure {
            var failure = ChatToolOutcome.failure(error: error, tool: "app", effects: effects).objectValue ?? [:]
            if failure["status"] != .string("cancelled"), failure["remedy"] == nil || failure["remedy"] == .null {
                failure["remedy"] = producer.objectValue?["remedy"]
            }
            return .object(failure)
        }
        return producer
    }

    /// An owned no at the door (User 10-18): what decided it, and her door call
    /// that changes it, or the person's exact control where the law gives it to him.
    static func doorRefusal(_ reason: String, _ detail: String, owner: String, next: [String: JSONValue]? = nil,
                            tap: String? = nil, extra: [String: JSONValue] = [:]) -> JSONValue {
        var extra = extra
        extra["remedy"] = Repair.remedy(owner: owner,
            nextCall: next.map { .object(["tool": .string("app"), "input": .object($0)]) }, tap: tap)
        return failure(reason, detail, extra: extra)
    }

    /// Let go of a repair she owes, saying why: the only settlement besides
    /// the operation working again.
    @MainActor
    func runRepairLetGo(input: [String: JSONValue]) async -> JSONValue {
        let id = (Self.inputString(input["id"]) ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        let reason = (Self.inputString(input["reason"]) ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        guard !id.isEmpty, !reason.isEmpty else {
            return Self.doorRefusal("invalid_args", "Pass id (from an OWED line on your home) and reason. Nothing was let go.",
                remedy: "correct_arguments", "Call repair.let_go with id and reason.")
        }
        let root = quietHost()?.dataRootOverride ?? PersistenceCore.defaultDataRoot()
        let store = ExperienceStore.at(root)
        do {
            await store.drained()
            let owed = try await store.experience(id)
            // A reply she owes a who is let go by its owner, so its delivery and
            // the experience agree; the Desk line asking for it then settles.
            if let owed, owed.owes["deliver"]?.phase.isSettled == false,
               owed.evidence.contains(where: { $0.source == "codex-completion-lifecycle" }) {
                try await CodexCompletionLifecycle.letGoReplies(deliveryIDs: [id], outcome: reason, dataRoot: root,
                    configRoot: InstallPaths.current.bridgeConfigRoot(dataRoot: root))
                return .object(["status": .string("ok"), "id": .string(id), "let_go": .string(reason), "effects": .string("occurred")])
            }
            if let owed, owed.owes["decide"]?.phase.isSettled == false {
                return Self.doorRefusal("person_decides", "\(id) waits on the person's decision; it is theirs to answer, not yours to let go. Nothing was let go.",
                    remedy: "none", "Wait on it with desk.wait, or ask the person.")
            }
            guard let owed, owed.owes["repair"]?.phase.isSettled == false else {
                return Self.doorRefusal("not_owed", "Nothing open that you owe has id \(id). Nothing was let go.",
                    remedy: "inspect", "Read the OWED lines on your home for the ids still owed.", next: ["page": .string("home")])
            }
            try await store.append([.claim(.init(claim: "let go: " + reason, evidence: [])),
                                    .letGo(key: "repair", reason: .abandoned)], to: id)
            return .object(["status": .string("ok"), "id": .string(id), "let_go": .string(reason), "effects": .string("occurred")])
        } catch {
            return Self.doorRefusal("unreadable", "The experience store could not be read or written: \(error.localizedDescription) Nothing was let go.",
                owner: "experiences/experiences.sqlite", next: ["action": .string("doctor.run")])
        }
    }

    @MainActor func runBackgroundRepair(tool: String, input: [String: JSONValue]) async -> JSONValue {
        let root = quietHost()?.dataRootOverride ?? securityCenter.dataRoot
        do {
            let detail: String
            switch tool {
            case "turn_reconcile":
                try await AbandonedTurnReconciliationHook.reconcile(dataRoot: root,
                    sessionId: Self.doorText(input["session_id"]), turnId: Self.doorText(input["turn_id"]))
                detail = "The saved turn was reconciled."
            default:
                detail = try ResidentWake.shared.accept(dataRoot: root, id: Self.inputString(input["id"]))
            }
            return .object(["status": .string("ok"), "detail": .string(detail)])
        } catch { return ChatToolOutcome.failure(error: error) }
    }

    /// A read-only action named as a page or item just runs: there is
    /// nothing to undo, so a refusal only costs a turn (10-08). Anything
    /// that changes something still comes back as the corrected call.
    func runCorrectedRead(_ correction: JSONValue, input: [String: JSONValue], surface: String, inProcess: Bool) async throws -> JSONValue {
        // Inside a part a read never becomes an action here: its host already ran
        // the one correction a part may make, a declared read, through its declarations.
        if let part = SkillRunContext.partID, part != "app-script" { return correction }
        guard case .object(let fields) = correction, case .object(let remedy)? = fields["remedy"],
              case .object(let next)? = remedy["next_call"], case .object(var call)? = next["input"],
              call["preview"] != .bool(true), case .string(let id)? = call["action"], let action = AppActions.action(id) else { return correction }
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
        var value = AgentWorkspace.resolvedRead(try await runAppDoor(input: call, surface: surface, inProcess: inProcess), as: id)
        if case .object(var result) = value {
            result["argument_notes"] = .array([.string("Ran as {action:\"\(id)\"}; it is an action, not a page or item.")])
            result["resolved"] = .string(id)
            value = .object(result)
        }
        return value
    }

    static func doorActionCorrection(_ name: String, input: [String: JSONValue]) async -> JSONValue? {
        let key = name.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        let args = if case .object(let args)? = input["args"] { args } else { [String: JSONValue]() }
        let call = (AppActions.action(key) ?? AppActions.pagePrefixedAction(key)).map { ["action": JSONValue.string($0.id), "args": input["args"] ?? .object(args)] }
            ?? ToolNameAliases.appCall(ToolNameAliases.retiredActions[key] ?? ToolNameAliases.canonical(key), input: args)
        guard var call else { return nil }
        for key in ["preview", "expected_version"] { if let value = input[key] { call[key] = value } }
        TurnTraceBus.fireFromContext(kind: "shim.fired", payload: .object(["id": .string("T16"), "site": .string("AppToolExecutor+AppDoor.swift:doorActionCorrection")]))
        return doorRefusal("action_route", "Use the corrected app call. Nothing ran.",
            remedy: "correct_route", "Make next_call instead.", next: call,
            extra: ["resolved": call["action"] ?? .null])
    }

    /// Refusals that are User's or his posture's, from the door or the code
    /// it ran: nothing ran, and retrying changes nothing.
    static let doorFloorReasons: Set<String> = [
        "owners_call", "owner_only", "trust_mode_read_only", "trust_mode_unreadable", "owners_screen", "owner_is_in_it",
        "trust_posture_needs_full_mac", "full_mac_only", "opens_for_owner", "owners_ears", "owners_draft",
        // A card asked of User on another surface, or whose origin is unknown.
        "not_yours_to_answer", "origin_unverifiable",
        // Needs User himself, Full Mac or not (a browser sign-in).
        "needs_person",
    ]

    /// The items a page reads besides inbox notes: the id, and what reading
    /// it returns.
    static let doorItemReads = AppDoorNames.items

    /// Every page's reader answers a name it does not have with status
    /// not_found; an item read says it one way on every page: the page, the
    /// name, and the read that shows what is there. Other failures keep their own why.
    static func doorItemRead(_ result: JSONValue, page: QuietToolPage, item: String) -> JSONValue {
        guard !item.isEmpty, case .object(let fields) = result, fields["status"] == .string("not_found") else { return result }
        return doorRefusal("unknown_item", "Nothing named \(item) is on the \(page.title) page now; app {page:\"\(page.id)\"} lists what is.",
            remedy: "read_page", "Read the page without item; nothing was done.", next: ["page": .string(page.id)])
    }

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
        if AppDoorNames.resolve(Self.doorText(input["page"])) == "visible", input["action"] == nil {
            guard let visible = presentation.visiblePageInput else { return Self.unattachedFailure() }
            input.merge(visible) { _, visible in visible }
        }
        // Approval replay carries the same receipt, not only the task-local guard.
        if let saved = input.removeValue(forKey: "__undo_receipt") {
            let root = quietHost()?.dataRootOverride ?? PersistenceCore.defaultDataRoot()
            let session = ChatToolSessionContext.verifiedSessionId ?? Self.inputString(input["__session_id"]) ?? ""
            guard !session.isEmpty, case .object(let receipt) = saved, receipt["action"] == input["action"],
                  saved == (await AgentWorkspaceNavigation.shared.undoReceipt(dataRoot: root, scope: session)) else {
                return Self.failure("stale_undo", "That undo receipt is no longer this conversation's last change. Nothing was written.")
            }
            let result = try await Self.$undoReceipt.withValue(saved) {
                try await runAppDoor(input: input, surface: surface, inProcess: inProcess)
            }
            if input["preview"] != .bool(true), ChatToolOutcome.outputLooksSuccessful(result), !ChatToolOutcome.isWaitingOnPerson(result) {
                await AgentWorkspaceNavigation.shared.clearUndo(saved, dataRoot: root, scope: session)
            }
            return result
        }
        if case .string? = input["item"], Self.doorText(input["item"]).isEmpty { input.removeValue(forKey: "item") }
        let root = quietHost()?.dataRootOverride ?? PersistenceCore.defaultDataRoot()
        let scope = Self.inputString(input["__session_id"]) ?? ChatToolSessionContext.verifiedSessionId ?? ""
        if Self.doorText(input["page"]).isEmpty, !Self.doorText(input["item"]).isEmpty,
           input[Self.doorScriptKey] != .bool(true), !scope.isEmpty,
           let page = await AgentWorkspaceNavigation.shared.lastDoorPage(dataRoot: root, scope: scope),
           ["tools", "skills"].contains(page) {
            let item = Self.doorText(input["item"])
            let known = page == "tools" ? try Parts(root: root).row(item, kind: nil) != nil
                : try InstalledSkillInventory.match(item, in: InstalledSkillInventory.entries(dataRoot: root)) != nil
            if known || item.lowercased() == "census" { input["page"] = .string(page) }
        }
        let requestedPage = Self.doorText(input["page"])
        let canonicalPage = AppDoorNames.resolve(requestedPage)
        let pageParts = canonicalPage.split(separator: "/", maxSplits: 1).map(String.init)
        if !requestedPage.isEmpty, requestedPage != canonicalPage || pageParts.count == 2 {
            input["page"] = .string(pageParts[0])
            if pageParts.count == 2 { input["item"] = .string(pageParts[1]) }
            let result = try await runAppDoor(input: input, surface: surface, inProcess: inProcess)
            return AgentWorkspace.resolvedRead(result, as: canonicalPage)
        }
        if Self.doorText(input["action"]).isEmpty, Self.doorText(input["item"]).isEmpty,
           AppDoorNames.homeItems.contains(canonicalPage) || canonicalPage == "app" {
            if canonicalPage == "app" { input.removeValue(forKey: "page") } else {
                input["page"] = .string("home")
                input["item"] = .string(canonicalPage)
            }
            return AgentWorkspace.resolvedRead(try await runAppDoor(input: input, surface: surface, inProcess: inProcess),
                                     as: canonicalPage == "app" ? "home" : "home." + canonicalPage)
        }
        let action = Self.doorText(input["action"])
        let resolvedAction = await AppActions.resolvedAction(action, dataRoot: root)
        var corrections: [String] = []
        let given: [String: JSONValue]? = switch input["args"] {
        case .object(let args)?: args
        case nil, .null?: [:]
        default: nil
        }
        if let target = resolvedAction, var args = given {
            let secrets = Set(MacInjectionArgRedaction.appDoorSecretKeys(input))
            func movable(_ key: String, _ value: JSONValue?) -> Bool {
                // A bare key names what is looked up (a setting's id); api_key and its kin name a secret.
                let words = key.lowercased().split(separator: "_")
                return !secrets.contains(key) && Set(words).isDisjoint(with: ["token", "secret", "password", "credential"])
                    && (words.count == 1 || !words.contains("key"))
                    && NativeAgentSecretRedactor.secretPath(.object([key: value ?? .string("")])) == nil
            }
            let names = Set(target.argSpecs.flatMap(\.names)).filter { movable($0, nil) }
            let discovery = if case .object(let fields) = AppActions.discovery(target) { fields } else { [String: JSONValue]() }
            let properties: [String: JSONValue] = if case .object(let schema)? = discovery["args_schema"],
                case .object(let properties)? = schema["properties"] { properties } else { [:] }
            for key in args.keys.sorted() {
                guard movable(key, args[key]), let supplied = args[key] else { continue }
                let correction = ToolNameAliases.argumentName(key, tool: target.isFold ? target.tool : target.id, input: args, known: names)
                var name = correction?.name
                var shimID = correction?.shimID
                var value = supplied
                if let name, name.contains(".") {
                    let corrected = ToolNameAliases.doorArgs(target.isFold ? target.tool : target.id, args, reportShim: true)
                    if corrected != args {
                        args = corrected
                        corrections.append("Use args.\(name), not args.\(key).")
                    }
                    continue
                }
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
                    if matches.count == 1 { name = matches[0].0; value = matches[0].1; shimID = "T11" }
                }
                if name == nil, properties[key] == nil, let schema = discovery["args_schema"] {
                    name = Self.doorMeantArg(supplied, of: target, given: args, schema: schema)
                    if name != nil { shimID = "T12" }
                }
                guard let name, names.contains(name), args[name] == nil || args[name] == .null || args[name] == value else { continue }
                args.removeValue(forKey: key)
                args[name] = value
                if let shimID {
                    TurnTraceBus.fireFromContext(kind: "shim.fired", payload: .object(["id": .string(shimID), "site": .string("AppToolExecutor+AppDoor.swift:runAppDoor")]))
                }
                corrections.append("Use args.\(name), not args.\(key).")
            }
            input["args"] = .object(args)
        }
        // A bare item names its unique owner; ambiguity is explicit, including a home room.
        if Self.doorText(input["page"]).isEmpty, case .string? = input["item"], !Self.doorText(input["item"]).isEmpty {
            let named = Self.doorText(input["item"])
            let root = quietHost()?.dataRootOverride ?? PersistenceCore.defaultDataRoot()
            let scope = Self.inputString(input["__session_id"]) ?? ChatToolSessionContext.verifiedSessionId ?? ""
            var owners = Dictionary(uniqueKeysWithValues: Self.doorItemReads.filter {
                $0.value[named.lowercased()] != nil
            }.map { ($0.key, named.lowercased()) })
            let skillName = named.hasPrefix("skill:") ? String(named.dropFirst(6)).trimmingCharacters(in: .whitespaces) : named
            if let skill = InstalledSkillInventory.match(skillName, in: try InstalledSkillInventory.entries(dataRoot: root)) {
                owners["skills"] = skill.id
            }
            if let host = quietHost() {
                if let refusal = await host.inboxFence(verb: "read", input: ["id": .string(named)]) {
                    guard case .object(let fields) = refusal, fields["reason"] == .string("unknown_id") else { return refusal }
                } else { owners["inbox"] = named }
            }
            if let desk = try await SwiftToolDispatcher.deskMatches(named,
                in: SwiftNativeDeskStore(dataRoot: root).liveState()).first {
                owners["desk"] = desk.handle
            }
            let conversations = try HumanConversationIndex.rows(dataRoot: root)
            let ids = conversations.filter { HumanConversationIndex.string($0["id"])?.caseInsensitiveCompare(named) == .orderedSame }
            let conversationID = !ids.isEmpty
            let matches = conversationID ? ids : conversations.filter { HumanConversationIndex.string($0["title"])?.caseInsensitiveCompare(named) == .orderedSame }
            guard matches.count <= 1 else {
                return Self.doorRefusal("ambiguous_item", "More than one conversation has that name.",
                    remedy: "choose_item", "Read chat.list, then use an exact conversation id.", next: ["action": .string("chat.list")])
            }
            if let row = matches.first { owners["chat"] = HumanConversationIndex.string(row["id"]) }
            if !owners.isEmpty, !conversationID, !(owners["desk"] != nil && named.lowercased().hasPrefix("desk.")),
               await HerScreen.classify(named, dataRoot: root, scope: scope) != .unknown {
                owners["home"] = named
            }
            if owners.count > 1 {
                return Self.doorRefusal("ambiguous_item", "More than one page owns that item.",
                    remedy: "choose_page", "Read it with one of the listed pages and the same item.",
                    extra: ["pages": .array(owners.keys.sorted().map(JSONValue.string))])
            }
            if owners.count == 1, let (page, item) = owners.first {
                input["page"] = .string(page)
                input["item"] = .string(item)
                return AgentWorkspace.resolvedRead(try await runAppDoor(input: input, surface: surface, inProcess: inProcess),
                                         as: page + "." + item)
            }
            if let page = doorPage(named) {
                input["page"] = .string(page.id)
                input.removeValue(forKey: "item")
                return AgentWorkspace.resolvedRead(try await runAppDoor(input: input, surface: surface, inProcess: inProcess), as: page.id)
            }
        }
        // Other keys app does not take still fail loudly.
        let stray = input.keys.filter { !Self.doorKeys.contains($0) && !$0.hasPrefix("__") }.sorted()
        if !stray.isEmpty {
            if stray.count == 1, action.isEmpty,
               let correction = await Self.doorActionCorrection(stray[0], input: input.merging(["args": input[stray[0]]!]) { _, value in value }) {
                return try await runCorrectedRead(correction, input: input, surface: surface, inProcess: inProcess)
            }
            return Self.doorRefusal("unknown_key",
                "app takes no \(stray.joined(separator: ", ")). Its keys are page, item, action, args, actions, preview, "
                + "expected_version, find and script; an action's own arguments go inside args. Nothing was read or done.",
                remedy: "correct_arguments", "Call app again with only those keys; {} lists the pages.",
                next: [:], extra: ["unrecognised": .array(stray.map(JSONValue.string)),
                                   "valid": .array(Self.doorKeys.sorted().map(JSONValue.string))])
        }
        // Strict providers represent omitted optional fields with null.
        if let entries = input["actions"], entries != .null {
            let beside = input.filter { $0.key != "actions" && $0.value != .null }
            guard case .array(let list) = entries,
                  beside.keys.allSatisfy({ $0.hasPrefix("__") || ["preview", "expected_version"].contains($0) }) else {
                return Self.doorRefusal("invalid_actions",
                    "actions is a list of app calls ({action, args}, {page}, {item}) and takes only preview and expected_version beside it. Nothing was run.",
                    remedy: "correct_arguments", "Move the other keys into the entries.")
            }
            return try await doorMany(list, base: beside)
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
        if !action.isEmpty, resolvedAction == nil, ToolNameAliases.retiredActions[action.lowercased()] == nil,
           input[Self.doorScriptKey] != .bool(true),
           await HerScreen.classify(action, dataRoot: quietHost()?.dataRootOverride ?? PersistenceCore.defaultDataRoot(),
                                    scope: Self.inputString(input["__session_id"]) ?? ChatToolSessionContext.verifiedSessionId ?? "") != .unknown {
            var item = input.filter { !["action", "page", "item"].contains($0.key) }
            item["item"] = .string(action)
            return try await runAppDoor(input: item, surface: surface, inProcess: inProcess)
        }
        // desk.archive {handle:[…]} runs once per handle. Only where this call
        // was judged a read or is a folded tool's, whose own gate judges each
        // value; any other action is judged with its args, so a list waits for actions.
        if let target = resolvedAction, case .object(let args)? = input["args"],
           target.isFold || target.readOnly(args: args), let (key, values) = Self.doorPlural(target, args) {
            TurnTraceBus.fireFromContext(kind: "shim.fired", payload: .object(["id": .string("T17"), "site": .string("AppToolExecutor+AppDoor.swift:runAppDoor")]))
            return try await doorMany(values.map { .object(["args": .object(args.merging([key: $0]) { $1 })]) },
                                      base: input.filter { $0.key != "args" })
        }
        if !action.isEmpty {
            var value = try await doorDo(action, input: input, surface: surface, inProcess: inProcess)
            if !corrections.isEmpty, case .object(var fields) = value {
                fields["argument_notes"] = .array(corrections.map(JSONValue.string))
                value = .object(fields)
            }
            if let action = await AppActions.resolvedAction(action, dataRoot: root), case .object(var fields) = value {
                let args: [String: JSONValue] = if case .object(let args)? = input["args"] { args } else { [:] }
                fields.merge(action.effectFields(args: args, result: fields)) { _, value in value }
                if fields["execution"] == nil { fields["execution"] = .string("not_run") }
                value = .object(fields)
            }
            return Self.previewApproval(value, preview: input["preview"] == .bool(true))
        }
        let find = Self.doorText(input["find"])
        let page = Self.doorText(input["page"])
        var item = Self.doorText(input["item"])
        if !page.isEmpty, item.isEmpty, doorPage(page) == nil, let correction = await Self.doorActionCorrection(page, input: input) {
            return try await runCorrectedRead(correction, input: input, surface: surface, inProcess: inProcess)
        }
        // A guide names its action, and the action its page: guide:<id> reads with or without page.
        if page.isEmpty, item.hasPrefix("guide:"),
           let named = await AppActions.resolvedAction(String(item.dropFirst("guide:".count)), dataRoot: root), named.page != "*" {
            var call = input
            call["page"] = .string(named.page)
            call["item"] = .string("guide:" + named.id)
            return try await runAppDoor(input: call, surface: surface, inProcess: inProcess)
        }
        if page.isEmpty, !item.isEmpty, let correction = await Self.doorActionCorrection(item, input: input) {
            return try await runCorrectedRead(correction, input: input, surface: surface, inProcess: inProcess)
        }
        // Her home (one-door phase 2 step 7, what was `workspace`): an item
        // with no page is a name or ref from home or one of its rooms.
        let homeItem = Self.opensHomeItem(input)
        // A script reads pages; it never opens an item anywhere but a real page.
        if input[Self.doorScriptKey] == .bool(true), input["item"].map({ $0 != .null }) == true,
           homeItem || doorPage(page) == nil {
            return Self.doorRefusal("action_required",
                "A script opens an item only on a real page; a home item can send or change something. Nothing was read or done.",
                remedy: "none", "Call the item's named action through app instead.")
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
            if input[Self.doorScriptKey] != .bool(true), !scope.isEmpty {
                try await AgentWorkspaceNavigation.shared.rememberDoorPage(nil, dataRoot: root, scope: scope)
            }
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
        if page.isEmpty {
            if input[Self.doorScriptKey] != .bool(true), !scope.isEmpty {
                try await AgentWorkspaceNavigation.shared.rememberDoorPage(nil, dataRoot: root, scope: scope)
            }
            return try await doorIndex(input)
        }
        if let corner = SenseCorner(key: page), let result = try await doorSenseRead(corner: corner, item: item, input: input) {
            return result
        }
        guard let resolved = doorPage(page) else {
            let root = quietHost()?.dataRootOverride ?? PersistenceCore.defaultDataRoot()
            let scope = Self.inputString(input["__session_id"]) ?? ChatToolSessionContext.verifiedSessionId ?? ""
            let kind = await HerScreen.classify(page, dataRoot: root, scope: scope)
            if kind != .unknown {
                // A page read may open a room or record, never invoke its effect verbs.
                let name = item.isEmpty ? page : item
                let itemKind = item.isEmpty ? kind : await HerScreen.classify(item, dataRoot: root, scope: scope)
                if kind == .read, itemKind == .read {
                    var call = input
                    call["page"] = .string("home")
                    call["item"] = .string(name)
                    return AgentWorkspace.resolvedRead(try await runAppDoor(input: call, surface: surface, inProcess: inProcess),
                                             as: "home." + name)
                }
                return Self.doorRefusal("item_action", "That home name acts; a page only reads.", remedy: "open_item",
                    "Use item to invoke it explicitly.", next: ["item": .string(name)])
            }
            return Self.doorRefusal("unknown_page", "No page is called that.", remedy: "read_index",
                "Read {} for the pages; nothing was done.", next: [:],
                extra: ["requested": .string(page), "pages": .array(doorPages.map { .string($0.id) })])
        }
        switch input["args"] {
        case .object(let args)?:
            let acceptsLimit = resolved.id == "chat" && !item.isEmpty && !item.hasPrefix("guide:")
            if let stray = args.keys.sorted().first(where: { !acceptsLimit || $0 != "limit" }) {
                return Self.doorRefusal("unknown_arg", "A \(resolved.id) page read does not accept args.\(stray). Nothing was read.",
                    remedy: "correct_arguments", acceptsLimit ? "Remove that argument; this conversation read accepts only args.limit (integer)."
                        : "Read the page without args. Use find for action arguments.",
                    next: ["page": .string(resolved.id), "item": .string(item),
                           "args": .object(args.filter { acceptsLimit && $0.key == "limit" })],
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
            return Self.doorItemRead(try await doorDo("desk.read", input: ["args": .object(["handle": .string(item), "structured": .bool(true)])],
                                                      surface: surface, inProcess: inProcess), page: resolved, item: item)
        }
        let result = Self.doorItemRead(try await doorRead(page: resolved, item: catalog ? "" : item), page: resolved, item: catalog ? "" : item)
        guard case .object(var read) = result, read["status"] == .string("ok") else { return result }
        if resolved.id == "tools", item != "census" {
            read["stopped_run_ids"] = .array(try PartRunStore.waitingIDs(root: root).map(JSONValue.string))
            read["resume_note"] = .string("stopped_run_ids are saved targets for ability.resume; an empty list means none. Resume rechecks the seal, the ability and replayed reads.")
        }
        if input[Self.doorScriptKey] != .bool(true), !scope.isEmpty {
            try await AgentWorkspaceNavigation.shared.rememberDoorPage(resolved.id, dataRoot: root, scope: scope)
        }
        if page != resolved.id { read["resolved"] = .string(resolved.id) }
        read["version"] = read["version"] ?? .string(Self.doorVersion(page: resolved.id, item: catalog ? "" : item, read))
        if item.isEmpty, let items = Self.doorItemReads[resolved.id] {
            read["item_reads"] = .array(items.sorted { $0.key < $1.key }.map { .string("\($0.key): \($0.value)") })
        }
        // A conversation's latest messages and whether chat.reply can answer
        // it, as chat_conversations opened it. Outside the version: her own
        // turn moves them.
        if resolved.id == "chat", case .object(let composer)? = read["item"],
           let id = Self.inputString(composer["conversation"]) {
            let args: [String: JSONValue] = if case .object(let given)? = input["args"] { given } else { [:] }
            read["conversation"] = await HumanConversationReader.open(sessionID: id,
                limit: Self.inputString(args["limit"]).flatMap { Int($0) },
                dataRoot: quietHost()?.dataRootOverride ?? PersistenceCore.defaultDataRoot())
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
        let actions = await Self.doorPageActions(resolved.id, hasSettings: hasSettings, dataRoot: root)
        // Over 8 reads compact, as over 12 did with the four every-page actions.
        let compact = actions.count > 8 && !catalog
        read["actions"] = .array(actions.map { .string(compact ? $0.id : $0.line) })
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

    /// The page's own actions; the ones on every page are named once, on `{}`,
    /// except setting.set where the page has settings to set.
    private static func doorPageActions(_ page: String, hasSettings: Bool, dataRoot: URL) async -> [AppAction] {
        AppActions.on(page: page, authored: AppActions.authored(dataRoot: dataRoot))
            .filter { $0.page != "*" || ($0.id == "setting.set" && hasSettings) }
    }

    /// Home first: open agent windows, what is in progress, what waits and
    /// what arrived (`home`, which sorts first), then a line per page. A page
    /// read lists its actions.
    @MainActor
    private func doorIndex(_ input: [String: JSONValue]) async throws -> JSONValue {
        let posture = await Self.freshQuietPosture()
        let root = quietHost()?.dataRootOverride ?? PersistenceCore.defaultDataRoot()
        let everyPage = AppActions.all.filter { $0.page == "*" }.map(\.id)
        // pages_version: the lines and every registered action (senses'
        // corners included), so a changed index tells from a repeat.
        let inventory = try await AppActions.inventory(dataRoot: root)
        var shape = inventory.actions.map { $0.page + "/" + $0.id + "/" + $0.scope }.sorted()
        var pages: [JSONValue] = []
        for page in doorPages {
            // The title only when it says more than the id ("inbox: Inbox." is dead weight — Agent 10-10).
            let title = page.title.lowercased() == page.id.lowercased() ? "" : "\(page.title). "
            let line = "\(page.id): \(title)\(page.summary)"
            shape.append(line)
            pages.append(.string(line))
        }
        let home = await doorHome([:], input: input)
        guard ChatToolOutcome.outputLooksSuccessful(home) else { return home }
        return .object([
            "home": home,
            "status": .string("ok"),
            "pages": .array(pages),
            "pages_version": .string(SHA256.hash(data: Data(shape.joined(separator: "\n").utf8))
                .prefix(6).map { String(format: "%02x", $0) }.joined()),
            "on_every_page": .string(everyPage.joined(separator: ", ") + ": on any page; find gives their args."),
            "trust_mode": .string(posture?.name ?? "unreadable"),
            "note": .string("Read a page for action ids; item:\"actions\" gives signatures, find gives args_schema and examples. "
                + (posture?.name == Self.fullMacModeName
                    ? "Under Full Mac, owner actions are yours too; the owner sees each run. In-person controls still need them. "
                    : "Owner actions refuse with their cause and control. ")
                + "preview:true checks without running. "
                + "Batch: actions:[{action,args},{page},{item}], or args.handle:[…] "
                + "where a scalar is accepted; each runs and reports in order."),
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
                "Home reads only through a chat's tool chain. Nothing was read.",
                remedy: "correct_arguments", "Call app from a chat turn's tool chain; this caller cannot bind a chat by supplying a session id.")
        }
        let call = ChatToolSessionInjection.apply(toolName: "workspace", input: call,
                                                  sessionId: Self.inputString(input["__session_id"]))
        do { return Self.foldedResult(try await perform("workspace", call), guide: nil) }
        catch { return ChatToolOutcome.failure(error: error, tool: "app") }
    }

    private static func doorAbilityCensus(root: URL) async throws -> JSONValue {
        let abilities = AbilityStore(dataRoot: root)
        let programs = OwnedProgramStore(root: abilities.root)
        let senses = FileSenseRegistry(dataRoot: root)
        let files = try abilities.files()
        let host = AppScriptRunner.Host(call: { _ in .null }, dataRoot: root)
        let key = try SwiftNativeManifestSigner(dataRoot: root).existingSigningKey()
        var rows: [[String: JSONValue]] = []
        for identity in files {
            for slot in AbilityStore.Slot.allCases {
                guard let file = try abilities.read(id: identity.id, slot: slot) else { continue }
                let descriptor = file.metadata["candidate"]?.objectValue ?? [:]
                let manifest = descriptor["manifest"]?.objectValue ?? [:]
                var record = file.record ?? manifest["record"]?.objectValue ?? manifest
                if var script = record["script"]?.objectValue { script["source"] = .string(file.body); record["script"] = .object(script) }
                let native = record["language"] == .string("native")
                let guidance = file.pathExtension == "md"
                let digest = doorText(descriptor["program"]?.objectValue?["version"])
                let status = doorText(record["status"])
                var blocks: [JSONValue] = []
                var validated = native || guidance, admitted = native || guidance, sourceChecked = false
                if file.kind == .sense, !native, descriptor.isEmpty {
                    do {
                        record["uses"] = record["uses"] ?? .int(0); record["corrections"] = record["corrections"] ?? .int(0)
                        let sense = try JSONDecoder().decode(SenseRecord.self, from: JSONValue.object(record).serializedData(pretty: false))
                        let sources = try senses.sourceFiles(sense)
                        guard let entry = sense.entry, sources[entry] == Data(file.body.utf8) else {
                            throw ToolFailureError("The migrated sense's selected source does not match its ability file.", effects: .none,
                                owner: file.id, nextCall: ToolFailureError.call("app", ["action": .string("sense.versions"),
                                    "args": .object(["sense_id": .string(file.id)])]), code: "sense_source_mismatch",
                                instruction: "Read this sense's versions and correct its selected source before conversion.", recovery: .inspect)
                        }
                        validated = true; admitted = true; sourceChecked = true
                    } catch { blocks.append(ownedFailure(error, code: "census_evidence_unreadable", owner: file.id,
                        instruction: "Read this ability's retained source and resolve the reported evidence failure before conversion.",
                        next: ["action": .string("ability.read"), "args": .object(["id": .string(file.id)])], effects: .none)) }
                } else if !native && !guidance && file.kind != .turn {
                    do {
                        guard !digest.isEmpty, let key else {
                            throw ToolFailureError("The exact JS version has no sealed validation proof.", effects: .none, owner: file.id,
                                nextCall: ToolFailureError.call("app", ["action": .string("ability.read"), "args": .object(["id": .string(file.id)])]),
                                code: "validation_proof_missing", instruction: "Read the exact source, then save and validate that version before conversion.", recovery: .inspect)
                        }
                        let candidate = try programs.load(id: file.id, digest: digest)
                        _ = try programs.proof(candidate, key: key)
                        guard candidate.program.dependencies.allSatisfy({ host.dependencyMatches($0, candidate.dependencyShapes.objectValue?[$0]) }) else {
                            throw ToolFailureError("An app-action dependency is unavailable or changed; save it against its current shape.", effects: .none,
                                owner: file.id, nextCall: ToolFailureError.call("app", ["action": .string("ability.read"), "args": .object(["id": .string(file.id)])]),
                                code: "dependency_changed", instruction: "Read the ability's dependencies; save its code against their current shapes.", recovery: .inspect)
                        }
                        validated = true
                        if slot != .next {
                            if file.kind == .part {
                                if status == "active" {
                                    try await OwnedProgramInvocation.$host.withValue(host) {
                                        try await Parts(root: root).checkAdmission(candidate, row: record)
                                    }
                                    admitted = true
                                }
                            } else {
                                let sense = try FileSenseRegistry.record(candidate)
                                admitted = record["candidateDigest"] == .string(candidate.digest) && record["version"] == .int(Int64(sense.version))
                            }
                            if ["active", "on"].contains(status), !admitted {
                                blocks.append(doorRefusal("version_not_admitted", "The selected JS version is not admitted.",
                                    remedy: "inspect", "Read this exact version before enabling it; do not admit different code.",
                                    next: ["action": .string(file.kind == .sense ? "sense.versions" : "ability.read"),
                                           "args": .object([file.kind == .sense ? "sense_id" : "id": .string(file.id)])]))
                            }
                        }
                    } catch { blocks.append(ownedFailure(error, code: "census_evidence_unreadable", owner: file.id,
                        instruction: "Read this ability's retained source and resolve the reported evidence failure before conversion.",
                        next: ["action": .string("ability.read"), "args": .object(["id": .string(file.id)])], effects: .none)) }
                }
                let version = record["codeFingerprint"] ?? record["candidateDigest"] ?? record["version"] ?? .null
                rows.append(["kind": .string(file.kind.rawValue), "id": .string(file.id),
                    "name": record["name"] ?? .string(file.id),
                    "role": .string(slot == .current ? "registered" : slot == .previous ? "rollback" : "proposed"),
                    "language": .string(native ? "native" : guidance ? "guidance" : record["language"] == .string("swift") ? "Swift" : "JS"), "status": .string(status),
                    "source": .string(try abilities.path(id: file.id, slot: slot, pathExtension: file.pathExtension).path),
                    "source_digest": .string(file.bodyDigest), "selected_version": version,
                    "pending_version": slot == .next ? .string(digest) : .null,
                    // Her turn is run by the stem every turn; it has no admission of its own.
                    "validation": .string(file.kind == .turn ? "run_by_stem" : sourceChecked ? "source_checked"
                        : admitted && validated ? "accepted" : validated ? "validated" : "unvalidated"),
                    "counterpart": validated && !digest.isEmpty ? .object(["id": .string(file.id), "version": .string(digest),
                        "status": .string(admitted ? "accepted" : "validated")]) : .null,
                    "unavailable": .array(slot == .previous ? blocks : []),
                    "blocks_cutover": .array(slot == .previous ? [] : blocks), "part": .string(file.partLine)]
                    .merging(file.kind == .sense ? record.filter { ["reach", "mode"].contains($0.key) } : file.part) { _, value in value })
            }
        }
        let skillRows = try InstalledSkillInventory.entries(dataRoot: root).map(\.row)
        for row in skillRows where row["source"] == .string("persona_body") {
            let path = doorText(row["bodyPath"])
            let body = try Data(contentsOf: URL(fileURLWithPath: path))
            let header = try AbilityStore.File(id: doorText(row["id"]), kind: .part, metadata: try AbilityStore.partHeader(row), body: "", pathExtension: "md")
            rows.append(["kind": .string("skill"), "id": row["id"] ?? .null, "name": row["name"] ?? .null,
                "role": .string("built_in"), "language": .string("guidance"), "status": row["status"] ?? .null,
                "source": .string(path), "source_digest": .string(SHA256.hash(data: body).map { String(format: "%02x", $0) }.joined()),
                "validation": .string("bundled"), "counterpart": .null, "blocks_cutover": .array([]), "part": .string(header.partLine)]
                .merging(header.part) { _, value in value })
        }
        for sense in try await senses.allChecked() where !files.contains(where: { $0.id == sense.id }) {
            let sources = sense.language == .native ? [:] : try senses.sourceFiles(sense)
            let body = sense.entry.flatMap { sources[$0] }
            let header = try AbilityStore.File(id: sense.id, kind: .sense,
                metadata: ["record": try .fromEncodable(sense)], body: "", pathExtension: "js")
            rows.append(["kind": .string("sense"), "id": .string(sense.id), "name": .string(sense.corner.key),
                "role": .string("built_in"), "language": .string(sense.language == .native ? "native" : "JS"),
                "status": .string(sense.status.rawValue), "source": .string("NativeAgent.app/Contents/Resources/Senses"),
                "selected_version": .int(Int64(sense.version)), "validation": .string("bundled"),
                "source_digest": body.map { .string(SHA256.hash(data: $0).map { String(format: "%02x", $0) }.joined()) } ?? .null,
                "counterpart": .null, "blocks_cutover": .array([]), "part": .string(header.partLine)]
                .merging(["reach": try .fromEncodable(sense.reach), "mode": .string(sense.mode.rawValue)]) { _, value in value })
        }
        let blocked = rows.count { !($0["blocks_cutover"]?.arrayValue ?? []).isEmpty }
        var census: [String: JSONValue] = ["status": .string("ok"), "page": .string("tools"), "item": .string("census"),
            "complete": .bool(blocked == 0), "blocked": .int(Int64(blocked)), "entries": .array(rows.map(JSONValue.object)),
            "note": .string("Read-only ability files and bundled defaults. Candidate JS: sealed proof, current dependencies and admission; migrated senses: checked source. Unavailable previous versions do not block working current versions.")]
        census["version"] = .string(doorVersion(page: "tools", item: "census", ["content": .object(census)]))
        return .object(census)
    }

    /// What the page or item shows now, read in process; a name the page
    /// does not have is status not_found, which `doorItemRead` words.
    /// Its version hashes only what the person would see change (content,
    /// settings, items), not the accessibility tree.
    @MainActor
    private func doorRead(page: QuietToolPage, item: String) async throws -> JSONValue {
        let root = quietHost()?.dataRootOverride ?? PersistenceCore.defaultDataRoot()
        do {
            // An action's guide, before any page reads its items as its own names.
            if item.hasPrefix("guide:"),
               let action = await Self.doorPageActions(page.id, hasSettings: false, dataRoot: root).first(where: { "guide:" + $0.id == item }),
               let guide = AppActions.about(action) {
                return .object(["status": .string("ok"), "page": .string(page.id), "item": .string(item),
                                "guide": .object([action.id: .string(guide)])])
            }
            if ["tools", "skills"].contains(page.id), item.lowercased() == "census" {
                return try await Self.doorAbilityCensus(root: quietHost()?.dataRootOverride ?? PersistenceCore.defaultDataRoot())
            }
            // A part reads by its id or name; a built-in skill's guidance reads too.
            if ["tools", "skills"].contains(page.id), !item.isEmpty {
                let read = try Parts(root: root).read(item)
                guard case .object(let fields) = read, fields["status"] == .string("ok") else { return ChatToolOutcome.refusedBeforeRunning(read) }
                return .object(["status": .string("ok"), "page": .string(page.id), "item": read])
            }
            if page.id == "skills" {
                let items = try InstalledSkillInventory.entries(dataRoot: root).map { entry in
                    JSONValue.object(entry.row.filter { ["id", "name", "description"].contains($0.key) }
                        .merging(["next_call": .object(["action": .string("ability.read"), "args": .object(["id": .string(entry.id)])])]) { $1 })
                }
                return .object(["status": .string("ok"), "page": .string(page.id), "title": .string(page.title), "items": .array(items),
                    "note": .string("Built-in guidance from the persona: read it with ability.read. What you write is an ability, on the tools page.")])
            }
            if page.id == "inbox" {
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
                guard ChatToolOutcome.outputLooksSuccessful(result) else { return result }
                guard case .object(let read) = result, case .array(let notes)? = read["notes"],
                      let note = notes.first else { return result }
                return .object(["status": .string("ok"), "page": .string("inbox"), "item": Self.doorButtons(note)])
            }
            if let tool = ["diagnostics": "doctor_status", "telegram": "telegram_status"][page.id],
               Self.doorItemReads[page.id]?[item.lowercased()] != nil {
                let result = try await healthRead(item.lowercased())
                guard ChatToolOutcome.outputLooksSuccessful(result) else { return result }
                return .object(["status": .string("ok"), "page": .string(page.id), "item": result])
            }
            if ["context", "agent_view"].contains(page.id) {
                return await runAppPageRead(input: ["page": .string(page.id), (page.id == "agent_view" ? "room" : "session_id"): .string(item)])
            }
            switch (page.id, item.isEmpty) {
            case ("chat", false):
                // The composer's own read.
                let result = await composerRead(sessionId: item)
                guard case .object(let state) = result, state["status"] == .string("ok") else { return result }
                return .object(["status": .string("ok"), "page": .string("chat"), "item": result])
            case (_, false):
                return ChatToolOutcome.refusedBeforeRunning(.object(["status": .string("not_found")]))
            default:
                let result = await runAppPageRead(input: ["page": .string(page.id)])
                guard case .object(var read) = result, read["status"] == .string("ok"), let host = quietHost() else { return result }
                // Chat also lists the sidebar's conversations, the first page of
                // chat.list. Outside the version: her own turn moves them.
                if page.id == "chat",
                   case .object(let list) = await host.runChatSession(verb: "list", input: [:], reachesUser: false) {
                    guard ChatToolOutcome.outputLooksSuccessful(.object(list)) else { return .object(list) }
                    read["conversations"] = list["conversations"]
                    read["conversations_next_offset"] = list["next_offset"]
                }
                // Providers also lists each account's id, fallback model and
                // models, as provider.test and provider.set_fallback_model take them.
                if page.id == "providers",
                   case .object(let list) = await host.provider(verb: "list", input: [:]) {
                    guard ChatToolOutcome.outputLooksSuccessful(.object(list)) else { return .object(list) }
                    read["accounts"] = list["accounts"]
                }
                return .object(read)
            }
        } catch {
            return ChatToolOutcome.failure(error: error, tool: "app", effects: ToolFailureError.Effects.none)
        }
    }

    static func doorVersion(page: String, item: String, _ read: [String: JSONValue]) -> String {
        var fields = read.filter { ["content", "settings", "items", "item", "count", "entries", "complete", "blocked"].contains($0.key) }
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
        if parts.first == "senses", parts.count == 2 {
            guard let registry = SensesHub.shared.registry as? FileSenseRegistry,
                  case .object(let read) = try await registry.lifecycleRead(id: parts[1]) else { return nil }
            return Self.inputString(read["version"])
        }
        guard let page = parts.first.flatMap(doorPage) else { return nil }
        let item = parts.count > 1 ? parts[1] : ""
        guard case .object(let read) = try await doorRead(page: page, item: item),
              read["status"] == .string("ok") else { return nil }
        return Self.inputString(read["version"]) ?? Self.doorVersion(page: page.id, item: item, read)
    }

    @MainActor
    private func doorFind(_ query: String) async throws -> JSONValue {
        let asked = AppActions.intentWords(query)
        let photosRead = AppActions.photosIntent(query)
        let root = quietHost()?.dataRootOverride ?? PersistenceCore.defaultDataRoot()
        let permissions = try? await MacIntegrationPermissionStore(dataRoot: root).readinessChecked()
        let (ranked, degraded) = try await AppActions.ranked(query, pages: doorPageIndex, dataRoot: root, memory: actionIndex)
        let matches = ranked.prefix(5)
        let actions = matches.filter { !$0.isItemRead }
        let named = AppActions.named(query)
        let items: [JSONValue] = matches.filter(\.isItemRead).map {
            .object($0.input.merging(["description": .string($0.label)]) { _, value in value })
        }
        let pages = doorPages.map { page in
            (page, AppActions.hits(Set(AppActions.intentWords(page.id + " " + page.title + " " + page.summary)), asked))
        }.filter { $0.1 > 0 }.sorted { $0.1 > $1.1 }.prefix(3)
        let disabled = try AppActions.disabledTools(asked, dataRoot: root).prefix(2)
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
            "status": .string(matches.isEmpty && pages.isEmpty && disabled.isEmpty && reads.isEmpty ? "not_found" : "ok"),
            "find": .string(query),
            "matched_actions": .int(Int64(AppActions.matchedActions(ranked).count)), "shown_actions": .int(Int64(actions.count)),
            // The best match and actions named by id carry their whole contract.
            "actions": .array(actions.enumerated().map { offset, action in
                let permissionBlocker = ToolPreloadHeuristics.macIntegrationGates[action.tool].flatMap {
                    permissions?.refusal(integration: $0.integration, mode: $0.mode)
                }
                let blocker = permissionBlocker
                guard offset == 0 || named.contains(action.id) else { return .string(action.line + (blocker.map { " Unavailable: " + $0 } ?? "")) }
                let discovery = AppActions.discovery(action, blocker: blocker, dataRoot: root)
                guard offset == 0, !named.contains(action.id), case .object(var fields) = discovery else { return discovery }
                if action.id == "mac.look", AppActions.hits(["screenshot", "capture"], asked) > 0 {
                    fields["example"] = .object(["action": .string("mac.look"), "args": .object(["pixels": .bool(true)])])
                }
                if action.id == "schedule.create", AppActions.timerIntent(query) {
                    fields["example"] = .object(["action": .string("schedule.create"), "args": .object([
                        "kind": .string("notify"), "payload": .object(["message": .string("Timer finished.")]),
                        "in_minutes": .int(10)])])
                }
                return .object(fields)
            }),
            "pages": .array(pages.map { .string("\($0.0.id): \($0.0.title). \($0.0.summary)") }),
            "read_next": .array(items + reads),
            "note": .string("find discovers actions, pages and home items. Among shown actions, the best and explicitly named ids include args_schema and example; others use id(args) label. Name an id for its full match. Search saved work with work.context {query}, conversations with chat.search {query}. Reversible actions run directly; irreversible examples use preview:true (checks only). Replace <placeholders> with your values."),
            // A find is a read; finding nothing is its answer.
            "effects": .string("none"),
        ]
        if found["status"] == .string("not_found") {
            found["reason"] = .string("no_match")
            found["message"] = .string("Nothing matches \"\(query)\": no action, page or item.")
        }
        if !disabled.isEmpty { found["disabled"] = .array(Array(disabled)) }
        if let degraded { found["ranking_degraded"] = .string("Ranked by words only: " + degraded) }
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
            found["photos_note"] = .string("photos.count counts; photos.recent reads newest asset metadata. Both filter by creation date and media type and request Photos access only when called. Neither reads image contents.")
        }
        if AppActions.timerIntent(query) {
            found["timer_note"] = .string("One-time timer: schedule.create with kind notify, payload.message and in_minutes, or schedule:'in 10 minutes'. For an alarm at a specific time, use that datetime as schedule.")
        }
        let information = ["what", "whats", "who", "when", "where", "why", "how"].contains(words.first ?? "")
            || AppActions.hits(["weather", "forecast", "temperature", "news", "price"], asked) > 0
        if words.contains("near") && words.contains("me") {
            found["location_note"] = .string("A timezone does not identify a city; an expired request is not a location.")
        }
        // "my …" with no strong local action (battery, IP, volume have one) is a personal fact to look up.
        let strongLocal = ranked.contains(where: {
            !$0.id.hasPrefix("web.") && AppActions.matchedWords($0, asked) >= min(asked.count, max(2, (asked.count + 1) / 2))
        })
        if words.contains("my"), information || words.first == "my", !strongLocal, !photosRead, actions.first?.id != "weather.forecast" {
            found["next_call"] = .object(["action": .string("work.context"), "args": .object(["query": .string(query)])])
            found["next_note"] = .string("Mail, Messages and Notes can hold personal facts. ")
        } else if information, !photosRead, actions.first?.id != "weather.forecast", !strongLocal {
            found["next_call"] = .object(["action": .string("web.search"), "args": .object(["query": .string(query)])])
            found["read_with"] = .object(["action": .string("web.read"),
                "args": .object(["url": .string("<URL from search result>")])])
            found["next_note"] = .string("No strong local action matches this information question.")
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
                remedy: "correct_arguments", "Call app from a chat turn's tool chain; this caller cannot bind a chat by supplying a session id.")
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

    /// Many in one call: each entry is its own app call, re-entering the whole
    /// chain as a script's calls do, in order, and every one runs and reports
    /// itself. A version given once guards each write on its page in turn,
    /// each taking the version the one before it left. A Stop ends it there.
    /// The first entry waiting on the person is the call's own envelope, so the
    /// turn waits and the card shows as for one action.
    @MainActor
    private func doorMany(_ entries: [JSONValue], base: [String: JSONValue]) async throws -> JSONValue {
        guard let perform = AppDoorReentry.perform else {
            return Self.doorRefusal("door_unavailable",
                "This call did not come through a chat's tool chain, so it has no gate to pass. Nothing ran.",
                remedy: "correct_arguments", "Call app from a chat turn's tool chain; this caller cannot bind a chat by supplying a session id.")
        }
        guard (1...AppScriptRunner.actionLimit).contains(entries.count) else {
            return Self.doorRefusal("invalid_actions",
                "One call runs 1 to \(AppScriptRunner.actionLimit) actions; this one has \(entries.count). Nothing ran.",
                remedy: "correct_arguments", "Split it into calls of at most \(AppScriptRunner.actionLimit).")
        }
        let snapshot = DoorNotesSnapshot.current ?? DoorNotesSnapshot()
        let outerBatch = snapshot.versions == nil
        if outerBatch { snapshot.versions = [:] }
        defer { if outerBatch { snapshot.versions = nil } }
        let given = Self.doorText(base["expected_version"])
        if let scope = given.split(separator: "@").first?.split(separator: "/").first.map(String.init) {
            snapshot.versions?[doorPage(scope)?.id ?? scope] = .string(given)
        }
        var receipts: [JSONValue] = []
        // One inbox read per action, after itself, as in a script.
        try await DoorNotesSnapshot.$current.withValue(snapshot) {
            for entry in entries {
                try Task.checkCancellation()
                guard case .object(let fields) = entry else {
                    receipts.append(Self.doorRefusal("invalid_actions", "Each entry is one app call, an object. Nothing ran.",
                        remedy: "correct_arguments", "Write it as {action, args}, {page} or {item}."))
                    continue
                }
                var call = base.filter { $0.key != "expected_version" }.merging(fields) { $1 }
                // A previewed list previews every entry; an entry's own preview:false never runs one.
                if base["preview"] == .bool(true) { call["preview"] = .bool(true) }
                let action = await AppActions.resolvedAction(Self.doorText(call["action"]),
                    dataRoot: quietHost()?.dataRootOverride ?? PersistenceCore.defaultDataRoot())
                let page: String
                if action?.id == "setting.set", case .object(let args)? = call["args"] {
                    page = QuietSettings.setting(id: Self.doorText(args["setting"]), host: quietHost())?.page ?? ""
                } else { page = action?.page ?? "" }
                if call["expected_version"] == nil { call["expected_version"] = snapshot.versions?[page] }
                let receipt: JSONValue
                do { receipt = try await perform("app", call) } catch { receipt = ChatToolOutcome.failure(error: error, tool: "app") }
                if call["expected_version"] != nil, case .object(let fields) = receipt, let after = fields["page_version"] { snapshot.versions?[page] = after }
                receipts.append(receipt)
            }
        }
        // A receipt waiting on the person speaks for the batch. So does a card
        // a call filed when it skipped (a permission it needs), but only when
        // nothing in the batch ran: answering the card replays the batch, which
        // then repeats nothing (fresh-root drive 10-17: a batched go+act filed
        // the screen-control card inside its receipts and nobody saw it).
        let speaking = receipts.first(where: ChatToolOutcome.isWaitingOnPerson)
            ?? (receipts.allSatisfy(ChatToolOutcome.neverRan) ? receipts.first(where: InlineInteractionNeed.isWaiting) : nil)
        if case .object(var waiting)? = speaking {
            waiting["receipts"] = .array(receipts)
            return .object(waiting)
        }
        let partial = receipts.count { if case .object(let fields) = $0 { fields["status"] == .string("partial") } else { false } }
        let landed = receipts.count {
            if case .object(let fields) = $0, fields["status"] == .string("partial") { return false }
            return ChatToolOutcome.outputLooksSuccessful($0)
        }
        var result: [String: JSONValue] = [
            "status": .string(landed == receipts.count ? "ok" : landed == 0 && partial == 0 ? "failed" : "partial"),
            "detail": .string("\(landed) of \(receipts.count) landed fully; \(partial) partially; each receipt, in order, says what happened."),
            "receipts": .array(receipts),
        ]
        if landed == 0 && partial == 0 {
            result["remedy"] = .object(["kind": .string("per_receipt"),
                "instruction": .string("Each receipt says why it did not land and what to do next."), "next_call": .null])
        }
        return .object(result)
    }

    /// The one argument given a list where the action takes a single value,
    /// and its values; nil when there is none, or more than one. A key or
    /// token never fans out.
    static func doorPlural(_ action: AppAction, _ args: [String: JSONValue]) -> (String, [JSONValue])? {
        guard case .object(let discovery) = AppActions.discovery(action), case .object(let schema)? = discovery["args_schema"],
              case .object(let properties)? = schema["properties"] else { return nil }
        let eligible = AppActions.pluralKeys(action, properties: properties)
        let plural = args.compactMap { key, value -> (String, [JSONValue])? in
            guard eligible.contains(key), case .array(let values) = value, !values.isEmpty,
                  let property = properties[key], doorTypeProblem(value, schema: property, path: key) != nil,
                  values.allSatisfy({ if case .array = $0 { false } else if case .object = $0 { false } else { true } })
            else { return nil }
            return (key, values)
        }
        return plural.count == 1 ? plural[0] : nil
    }

    // MARK: - Do

    @MainActor
    func doorUndo(input: [String: JSONValue]) async throws -> JSONValue {
        let root = quietHost()?.dataRootOverride ?? PersistenceCore.defaultDataRoot()
        let session = ChatToolSessionContext.verifiedSessionId ?? Self.inputString(input["__session_id"]) ?? ""
        guard !session.isEmpty, let saved = await AgentWorkspaceNavigation.shared.undoReceipt(dataRoot: root, scope: session),
              case .object(let receipt) = saved, let action = Self.inputString(receipt["action"]) else {
            return Self.failure("nothing_to_undo", "This conversation has no readable retained change to undo. Nothing was written.",
                extra: ["remedy": Repair.terminal(instruction: "No retained inverse is available. Do not invent an undo; inspect the affected state before choosing a new change.")])
        }
        if let reason = Self.inputString(receipt["undo_unavailable"]) {
            return Self.doorRefusal("undo_unavailable", reason, remedy: "inspect",
                "Read the recorded action's current contract; this receipt cannot undo it.", next: ["find": .string(action)])
        }
        let args: [String: JSONValue]
        switch action {
        case "layout.write":
            let outcome = SurfaceLayoutStore.read(dataRoot: root)
            guard case .object(let read) = outcome, let previous = read["previous"] else {
                if !ChatToolOutcome.outputLooksSuccessful(outcome) { return outcome }
                return Self.doorRefusal("undo_unavailable", "The previous layout could not be read. Nothing was written.",
                    remedy: "inspect", "Read the layout and its retained history; do not invent the previous layout.", next: ["action": .string("layout.read")])
            }
            args = ["layout": previous, "layout_version": receipt["version"] ?? .null]
        case "agent.recipe_write":
            let outcome = AgentRecipeStore.read(host: Self.inputString(receipt["host"]))
            guard case .object(let read) = outcome, let previous = read["previous"] else {
                if !ChatToolOutcome.outputLooksSuccessful(outcome) { return outcome }
                return Self.doorRefusal("undo_unavailable", "The previous recipe could not be read. Nothing was written.",
                    remedy: "inspect", "Read this recipe and its retained history; do not invent the previous recipe.",
                    next: ["action": .string("agent.recipe"), "args": .object(["host": receipt["host"] ?? .null])])
            }
            args = ["host": receipt["host"] ?? .null, "recipe": previous]
        case "setting.set":
            args = ["setting": receipt["setting"] ?? .null, "value": receipt["old_value"] ?? .null,
                    "because": receipt["user_request"] ?? .string("")]
        default:
            return Self.failure("undo_unavailable", "That receipt has no undo action. Nothing was written.",
                extra: ["remedy": Repair.terminal(instruction: "This receipt has no inverse. Inspect the affected state before choosing a new change.")])
        }
        guard let perform = AppDoorReentry.perform else {
            return Self.doorRefusal("door_unavailable", "Use app from a chat turn. Nothing was written.",
                remedy: "correct_arguments", "Call app from a chat turn's tool chain; this caller cannot bind a chat by supplying a session id.")
        }
        // Re-enter the original action's gates; only its owner applies the receipt.
        return try await perform("app", ["action": .string(action), "args": .object(args),
                                         "__session_id": .string(session), "__undo_receipt": saved])
    }

    @MainActor
    private func doorDo(_ id: String, input: [String: JSONValue], surface: String, inProcess: Bool) async throws -> JSONValue {
        if id.lowercased() == "find", !Self.doorText(input["find"]).isEmpty {
            return Self.doorRefusal("action_route", "find is an app key, not an action. Nothing ran.",
                remedy: "correct_route", "Make next_call to discover matching actions.",
                next: ["find": input["find"]!])
        }
        let root = quietHost()?.dataRootOverride ?? PersistenceCore.defaultDataRoot()
        // An older door answers through the one form and names the new call.
        if let alias = Self.partAlias(id, Self.partFields(input["args"]), root: root) {
            let result = try await doorDo(alias.id, input: input.merging(["args": .object(alias.args)]) { $1 }, surface: surface, inProcess: inProcess)
            guard case .object(var fields) = result else { return result }
            fields["alias"] = .string("\(id) is \(alias.id) now; call \(alias.id) directly.")
            // A skill.read's answer also in the shape its readers learned:
            // params, script {source, params} and selected_version.
            if id.lowercased() == "skill.read", case .object(var read)? = fields["result"] {
                let declares = Self.partFields(read["declares"])
                let params = declares["params"].flatMap { $0 == .null ? nil : $0 } ?? .object([:])
                read["params"] = params
                read["script"] = .object(["source": Self.partFields(read["source"])["code"] ?? .null, "params": params,
                                          "actions": declares["actions"] ?? .array([])])
                read["selected_version"] = Self.partFields(read["versions"])["current"] ?? .null
                fields["result"] = .object(read)
            }
            return .object(fields)
        }
        guard let action = await AppActions.resolvedAction(id, dataRoot: root) else {
            if let partID = ToolNameAliases.authoredTool(id), let row = try Parts(root: root).row(partID),
               let status = Self.inputString(row["status"]), status != "active" {
                let name = Self.inputString(row["name"]) ?? partID
                // An off whose actor is unreadable is named as the guard names it.
                if status == "disabled" {
                    do { _ = try CapabilityLifecycle.preservingOwnerOff(row, before: row, ownerAuthorized: true, preview: true) }
                    catch { return Self.failure("part_disabled", "\(name) didn't run: \(error.localizedDescription)",
                                                extra: ["requested": .string(id), "id": .string(partID)]) }
                }
                // Off by the person (or by a record too old to say who) is his
                // decision: name his control and owe nothing. Off by her is hers to restore.
                if status == "disabled", CapabilityLifecycle.requiresOwnerToEnable(isOff: true, disabledBy: Self.inputString(row["disabledBy"])) {
                    return Self.failure("part_disabled", "\(name) was switched off by the person; nothing ran.",
                        extra: ["remedy": Repair.why(owner: "ability \(partID): switched off by the person",
                                                     tap: "Tools page > \(name) > turn on"),
                                "requested": .string(id), "id": .string(partID)])
                }
                // No executable version has been shown by this failed run.
                // Open its versioned source instead of manufacturing a keep
                // from whatever happens to be in the catalog at click time.
                let hasCode = (row["candidateDigest"] ?? row["codeFingerprint"]) != nil
                let nextAction = hasCode ? "ability.read" : status == "disabled" ? "ability.restore" : "ability.enable"
                return Self.doorRefusal(status == "disabled" ? "part_disabled" : "not_kept",
                    hasCode ? "\(name) is \(status == "disabled" ? "switched off" : "a draft, not kept yet"); nothing ran. Read its exact version before keeping it."
                        : status == "disabled" ? "\(name) is switched off; nothing ran. ability.restore turns it back on."
                        : "\(name) is a draft, not kept yet; nothing ran. ability.enable keeps it.",
                    owner: "ability \(partID).status",
                    next: ["action": .string(nextAction), "args": .object(["id": .string(partID)])],
                    extra: ["requested": .string(id), "id": .string(partID)])
            }
            let qualified = Self.doorText(input["page"]) + "." + id
            if let correction = await Self.doorActionCorrection(qualified, input: input) {
                return try await runCorrectedRead(correction, input: input, surface: surface, inProcess: inProcess)
            }
            if let correction = await Self.doorActionCorrection(id, input: input) {
                return try await runCorrectedRead(correction, input: input, surface: surface, inProcess: inProcess)
            }
            return Self.doorRefusal("unknown_action", "No action is called that. See nearest, or use find by intent. A home name or ref (desk.4, mail.find, an agent's name) opens with item.",
                remedy: "find", "Use one of nearest, find it by what you want done, or open a home name with item; nothing was done.",
                next: ["find": .string(id)],
                extra: ["requested": .string(id),
                        "nearest": .array(try await AppActions.ranked(id, pages: doorPageIndex,
                            dataRoot: quietHost()?.dataRootOverride ?? PersistenceCore.defaultDataRoot(), memory: actionIndex)
                            .actions.filter { !$0.isItemRead }.prefix(3).map { .string($0.line) })])
        }
        // User, 10-02: under Full Mac his actions are hers too. The code each
        // runs posts the decided row he sees it by.
        let fullMac = action.isHis ? await Self.freshQuietPosture(dataRoot: root)?.name == Self.fullMacModeName : false
        var receipt: [String: JSONValue] = [
            "action": .string(action.id), "page": .string(action.page), "label": .string(action.label),
            "owner": .string(action.isHis && !fullMac ? "his" : "hers"), "execution": .string("not_run"),
        ]
        // What refuses or previews a folded tool points to its guide, never carries it.
        if !action.partAction, action.page != "*", AppActions.about(action) != nil {
            receipt["guide"] = .object(["page": .string(action.page), "item": .string("guide:" + action.id)])
        }
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
            if action.id == "desk.close" { args = given }
            else if case .object(let discovery) = AppActions.discovery(action), let schema = discovery["args_schema"] {
                args = ToolArguments.normalized(given, schema: schema,
                    preserving: ["ability.save", "sense.make"].contains(action.id) ? ["learned", "choices"] : [])
            } else { args = given.filter { $0.value != .null } }
        case nil, .null?: args = [:]
        default: return badArgs("invalid_args", "args is an object of the action's arguments by name: \(action.line)", "args")
        }
        let read = action.readOnly(args: args)
        let specs = action.argSpecs
        let known = Set(specs.flatMap(\.names))
        // An authored tool whose schema lists no arguments takes what it is given.
        let open = specs.isEmpty && (action.partAction || ToolNameAliases.authoredTool(action.id) != nil)
        if !open, let stray = args.keys.sorted().first(where: { !known.contains($0) }) {
            return badArgs("unknown_arg", "\(action.id) takes no \(stray): \(action.line)", "args.\(stray)")
        }
        let validationArgs = Self.doorValidationArgs(action, args)
        // A wake gives a part none of its call's arguments (what woke it rides
        // as input.wake), so what a call requires never refuses it.
        let woken = OwnedProgramRunner.wake != nil
        if !woken, let missing = specs.first(where: { spec in !spec.optional && !spec.names.contains { validationArgs[$0] != nil } }) {
            return badArgs("missing_arg", "\(action.id) needs \(missing.names.joined(separator: " or ")): \(action.line)",
                           "args.\(missing.names[0])")
        }
        if !woken, case .object(let discovery) = AppActions.discovery(action), let schema = discovery["args_schema"],
           let problem = Self.doorTypeProblem(.object(validationArgs), schema: schema, path: "args") {
            return badArgs("bad_input", "\(problem.path) must be \(problem.type): \(action.line)", problem.path)
        }
        // Validate before an owner-only preview can claim a callable target.
        let ownerRemedy: JSONValue = {
            let target = Self.doorText(args["id"] ?? args["provider"])
            let tap: String
            switch action.id {
            case "inbox.open_on_mac": tap = "Inbox → \(target) → Open on Mac"
            case "inbox.approve": tap = "Today → \(target) → Approve"
            case "inbox.deny": tap = "Today → \(target) → Decline"
            case "provider.sign_in": tap = "Providers → Sign in, reconnect or add an account"
            case "provider.disconnect": tap = "Providers → \(target) → Manage → Remove the key"
            case "connector.on": tap = target.lowercased() == "telegram"
                ? "Connectors → Telegram → Telegram is on" : "iPhone → Connectors → \(target) → Enabled"
            case "connector.disconnect": tap = "iPhone → Connectors → \(target) → Disconnect"
            case "telegram.disconnect": tap = "Connectors → Telegram → Disconnect Telegram"
            case "pairing.remove": tap = "Connectors → iPhone → \(target) → Remove"
            case "backup.restore": tap = "Trust → Advanced → Backups → \(target) → Restore"
            case "desk.approve": tap = "Desk → \(target) → Approve"
            default: return .null // Actions owned by the agent never use this remedy.
            }
            return Repair.why(owner: action.id, tap: tap)
        }()
        if fullMac, action.tool.isEmpty, case .his(let why, _) = action.owner {
            receipt["owner"] = .string("his")
            receipt["remedy"] = ownerRemedy
            return Self.failure("needs_person",
                "Under Full Mac \(action.id) is yours, but it needs the owner in person: \(why). Nothing was done.", extra: receipt)
        }
        if !fullMac, case .his(let why, _) = action.owner {
            receipt["why"] = .string(why)
            receipt["remedy"] = ownerRemedy
            func alternative(_ instruction: String, _ id: String, _ args: [String: JSONValue]) -> JSONValue {
                .object(["instruction": .string(instruction), "next_call": .object([
                    "tool": .string("app"), "input": .object(["action": .string(id), "args": .object(args)])])])
            }
            switch action.id {
            case "inbox.open_on_mac":
                receipt["alternatives"] = .array([
                    alternative("If you mean to decline the card, use inbox.not_now.", "inbox.not_now", args),
                    alternative("If the card is stale, archive it.", "inbox.archive", args)])
            case "connector.disconnect":
                receipt["alternatives"] = .array([alternative("To stop the connector without disconnecting it, turn it off.", "connector.off", args)])
            case "telegram.disconnect":
                receipt["alternatives"] = .array([alternative("To stop Telegram without removing its token, turn it off.", "setting.set",
                    ["setting": .string("telegram.enabled"), "value": .bool(false)])])
            default: break
            }
            if input["preview"] == .bool(true) {
                receipt["status"] = .string("preview")
                receipt["would_refuse"] = .string("owners_call")
                receipt["checks_not_run"] = .array([.string("Target, policy preflight and execution checks: this action belongs to the owner.")])
                receipt["detail"] = .string("Would refuse: that's the owner's, \(why). Nothing was done.")
                return .object(receipt)
            }
            return Self.failure("owners_call", "That's the owner's: \(why). Nothing was done.", extra: receipt)
        }
        // Why she put it away, on the receipt that lands in her transcript.
        // Never under `reason`: that key is the machine refusal code the
        // runner and the floor check classify on.
        if let reason = Self.inputString(args["reason"]) { receipt["reason_given"] = .string(String(reason.prefix(280))) }
        var call = action.binding.arguments(args)
        // A program calling gets a reader's structured form, where it has one.
        if input[Self.doorScriptKey] == .bool(true), call["structured"] == nil,
           action.argSpecs.flatMap(\.names).contains("structured") { call["structured"] = .bool(true) }
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
            guard action.page == "*" || scopePage == action.page
                || (action.tool == "sense_lifecycle" && scope == "senses/" + Self.doorText(args["sense_id"])) else {
                receipt["expected_version"] = .string(expected)
                return Self.doorRefusal("wrong_page_version",
                    "That version is from \(scopePage ?? scope), and \(action.id) is on \(action.page). Nothing was done.",
                    remedy: "reread", "Read \(action.id)'s current requirements before choosing its version.",
                    next: ["find": .string(action.id)], extra: receipt)
            }
            let current = try await doorCurrentVersion(scope: scope)
            guard current == expected else {
                receipt["expected_version"] = .string(expected)
                receipt["current_version"] = current.map(JSONValue.string) ?? .null
                let parts = scope.split(separator: "/", maxSplits: 1).map { JSONValue.string(String($0)) }
                var read: [String: JSONValue] = ["page": parts.first ?? .string(action.page)]
                if parts.count > 1 { read["item"] = parts[1] }
                if parts.first == .string("senses"), parts.count == 2 {
                    read = ["action": .string("sense.versions"), "args": .object(["sense_id": parts[1]])]
                }
                return Self.doorRefusal("stale_version", current == nil
                    ? "That version names nothing that reads now. Nothing was done."
                    : "\(scope) changed since that read. Nothing was done.",
                    remedy: "reread", "Read it again, check the action still fits, then pass the new version.",
                    next: current == nil ? ["find": .string(action.id)] : read, extra: receipt)
            }
        }
        if let session = input["__session_id"] { call["__session_id"] = session }
        if let address = input["__sense_address"] { call["__sense_address"] = address }
        // A stopped run resumes as its own run; a part's preview runs its code with every write previewed.
        if action.id == "ability.resume" {
            return Self.actionResult(await doorPartResume(args, preview: input["preview"] == .bool(true), session: input["__session_id"],
                                                          surface: surface, root: root), action: action, args: args, root: root)
        }
        if action.authored, input["preview"] == .bool(true) {
            return Self.actionResult(await doorPartPreview(action, args: args, input: input, surface: surface, root: root), action: action, args: args, root: root)
        }
        guard AppDoorReentry.perform != nil || inProcess else {
            return Self.doorRefusal("door_unavailable",
                "This call did not come through a chat's tool chain, so it has no gate to pass. Nothing was read or done.",
                remedy: "correct_arguments", "Call app from a chat turn's tool chain; this caller cannot bind a chat by supplying a session id.")
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
            // Only where the real call would run: elsewhere it refuses
            // door_unavailable, not a missing window.
            var refusal = await foldedRefusal(action, input: call, surface: surface)
            if let refused = refusal {
                refusal = Self.foldedResult(ChatToolOutcome.normalizedFailure(refused, tool: action.tool), guide: nil, tool: action.tool)
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
        // A folded tool answers as its direct call did: its own result, its
        // own gates and its own card. An ability runs as a part, whatever its face.
        if action.isFold && !action.authored || action.id == "chat.list" {
            let result = Self.foldedResult(try await runFolded(action, input: call, surface: surface), guide: receipt["guide"],
                                          browser: action.tool.hasPrefix("browser."), tool: action.tool)
            let folded = Self.actionResult(result, action: action, args: args, root: root)
            // A versioned write says the version it left, as the app's own buttons do.
            guard returnsVersion, case .object(var fields) = folded,
                  let after = try? await doorCurrentVersion(scope: scope) else { return folded }
            fields["page_version"] = .string(after)
            return .object(fields)
        }
        // In a script, one call's after is the next one's before: one inbox
        // read per action. A read raises nothing, so none is read around it.
        let snapshot = DoorNotesSnapshot.current
        let watch = !read
        let notesBefore = if !watch { [(id: String, title: String)]?.none }
            else if let held = snapshot?.notes { held } else { await doorNotes() }
        let knocksBefore = watch ? Result { try AttentionRouter.deliveredKnocks(dataRoot: root) } : .success([:])
        var result = Self.actionResult(action.authored ? try await doorPart(action, call: call, input: input, surface: surface, root: root)
            : try await runFolded(action, input: call, surface: surface), action: action, args: args, root: root)
        let surfacesChanged = if case .object(let fields) = result, case .array(let surfaces)? = fields["surfaces_changed"] {
            !surfaces.isEmpty
        } else { false }
        if Self.undoReceipt == nil, ["layout.write", "agent.recipe_write", "setting.set"].contains(action.id),
           case .object(var fields) = result, fields["changed"] == .bool(true) || surfacesChanged, ChatToolOutcome.outputLooksSuccessful(result),
           let session = ChatToolSessionContext.verifiedSessionId ?? Self.inputString(input["__session_id"]), !session.isEmpty {
            fields["action"] = .string(action.id)
            do {
                try await AgentWorkspaceNavigation.shared.rememberUndo(.object(fields), dataRoot: root, scope: session)
                if fields["undo_unavailable"] == nil || fields["undo_unavailable"] == .null {
                    receipt["undo"] = .object(["action": .string("undo")])
                }
            }
            catch {
                fields["undo_unavailable"] = .string(error.localizedDescription)
                result = .object(fields)
            }
        }
        let notesAfter = watch ? await doorNotes() : nil
        if watch { snapshot?.notes = notesAfter }
        let knocksAfter = watch ? Result { try AttentionRouter.deliveredKnocks(dataRoot: root) } : .success([:])

        result = ChatToolOutcome.normalizedFailure(result, tool: action.tool)

        // The receipt's status is the code's own: its status, else whether
        // its result reads as a success, never the door's own ok.
        receipt["status"] = .string(ChatToolOutcome.statusWord(result))
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
            receipt["message"] = fields["message"]
            let waiting = Self.doorText(fields["not_run_status"])
            // The refusal's own code on the receipt itself (owners_screen, not
            // tool_failed); a sentence stays where it is.
            if !reason.isEmpty, !reason.contains(" ") { receipt["reason"] = .string(reason) }
            if !waiting.isEmpty || Self.doorFloorReasons.contains(reason) {
                receipt["effects"] = .string("none")
                receipt["remedy"] = fields["remedy"] ?? .object([
                    "kind": .string(waiting == "approval_filed" ? "wait" : "none"),
                    "instruction": .string(waiting == "approval_filed"
                        ? "The owner has a card for it; it runs if they approve. Don't retry."
                        : "Nothing ran, and retrying changes nothing. Leave it for the owner."),
                    "next_call": .null,
                ])
            } else {
                receipt["effects"] = fields["effects"] ?? .string(read ? "none" : "unknown")
                receipt["remedy"] = fields["remedy"] ?? Self.readRecovery(action)
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
            "knocks_delivered": Self.knocksDelivered(before: knocksBefore, after: knocksAfter),
            "not_observed": .string("A turn a card's answer wakes on its own (one handed back to this call is "
                + "result.continuation), and anything the app does after this call returns."),
        ]) }
        if returnsVersion, let after = try? await doorCurrentVersion(scope: scope) {
            receipt["page_version"] = .string(after)
        }
        if watch { receipt["decided_by"] = .string("agent") }
        return .object(receipt)
    }

    /// Setting request evidence has its own refusal and applies only to model turns.
    static func doorValidationArgs(_ action: AppAction, _ args: [String: JSONValue]) -> [String: JSONValue] {
        action.id == "setting.set" ? args.merging(["because": .string("")]) { _, check in check } : args
    }

    /// The argument a stray obviously means: the only accepted name the call
    /// leaves out that its value fits as given (validation coerces it after).
    /// Anything else stays the refusal that names them all. Validation supplies
    /// the setting evidence, which a stray never means.
    static func doorMeantArg(_ value: JSONValue, of action: AppAction, given args: [String: JSONValue], schema: JSONValue) -> String? {
        // A flag carries no content: its name is its meaning, so a stray boolean
        // is never obviously another flag (background:true is not front:true).
        if case .bool = value { return nil }
        guard case .object(let root) = schema, case .object(let properties)? = root["properties"] else { return nil }
        let supplied = doorValidationArgs(action, args)
        let fits = action.argSpecs.filter { spec in !spec.names.contains { supplied[$0] != nil } }.flatMap(\.names).filter { name in
            properties[name].map { value.schemaProblem(schema: $0) == nil } ?? false
        }
        return fits.count == 1 ? fits[0] : nil
    }

    /// Validate the same public schema discovery returns, before renaming any arguments.
    private static func doorTypeProblem(_ value: JSONValue, schema: JSONValue, path: String) -> (path: String, type: String)? {
        value.schemaProblem(schema: schema, path: path).map { ($0.path, $0.expected) }
    }

    private static func readRecovery(_ action: AppAction) -> JSONValue {
        .object(["kind": .string("inspect"), "owner": .string(action.id),
            "instruction": .string("Read \(action.id)'s current requirements and correct the reported cause before another call. Check what took effect before repeating a change."),
            "next_call": .object(["tool": .string("app"), "input": .object(["find": .string(action.id)])])])
    }

    /// The registry's read contract supplies the evidence missing from a
    /// generic failure envelope. Preserve an explicitly uncertain mutation.
    private static func actionResult(_ result: JSONValue, action: AppAction, args: [String: JSONValue], root: URL = PersistenceCore.defaultDataRoot()) -> JSONValue {
        var fields: [String: JSONValue] = if case .object(let fields) = result { fields } else { ["result": result] }
        if ["sense.make", "ability.save", "ability.validate", "ability.enable"].contains(action.id),
           ["unknown_arg", "bad_input"].contains(doorText(fields["reason"])), fields["next_call"] == nil {
            if case .object(let remedy)? = fields["remedy"], case .object? = remedy["next_call"] {
                fields["next_call"] = remedy["next_call"]
            } else if case .object(let discovery) = AppActions.discovery(action), let example = discovery["example"] {
                let next: JSONValue = .object(["tool": .string("app"), "input": example])
                fields["next_call"] = next
                fields["remedy"] = .object(["kind": .string("correct_arguments"),
                    "instruction": .string("Use this call shape with your intended values. Nothing ran."), "next_call": next])
            }
        }
        // Authoring is a road: each step that lands hands back the next call.
        // Keeping is a road: a part that is on hands back its own run.
        if action.id == "ability.enable", fields["next_call"] == nil, ChatToolOutcome.outputLooksSuccessful(result),
           !ChatToolOutcome.isWaitingOnPerson(result), let run = inputString(fields["run"]) {
            fields["next_call"] = .object(["tool": .string("app"), "input": .object(["action": .string(run), "args": .object([:])])])
        }
        fields.merge(action.effectFields(args: args, result: fields)) { _, value in value }
        let status = doorText(fields["status"])
        if fields["execution"] == nil {
            fields["execution"] = .string(fields["not_run_status"] != nil || status == "not_run" || ChatToolOutcome.neverRan(result)
                || ChatToolOutcome.isWaitingOnPerson(result) ? "not_run"
                : ChatToolOutcome.exactResultClass(result) == .succeeded ? "executed" : "attempted")
        }
        guard action.readOnly(args: args), !ChatToolOutcome.outputLooksSuccessful(result),
              !ChatToolOutcome.isWaitingOnPerson(result), !ChatToolOutcome.wasCancelled(result),
              !InlineInteractionNeed.isWaiting(result),
              fields["effects_unknown"] != .bool(true),
              fields["effects"] == nil || fields["effects"] == .string("unknown") || fields["effects"] == .string("none") else { return .object(fields) }
        fields["effects"] = .string("none")
        fields["outcome"] = .string("unmet")
        if fields["remedy"] == nil || fields["remedy"] == .null { fields["remedy"] = readRecovery(action) }
        return .object(fields)
    }

    /// A folded tool's result as she reads it through the door: a call it
    /// points to by a folded name is that tool's app call, its sentences name
    /// folded tools by action id, its next page's args are the door's names,
    /// and a failure that was not User's or a card points to the tool's guide.
    /// Data fields are left as they are.
    static func foldedResult(_ result: JSONValue, guide: JSONValue?, browser: Bool = false, tool: String = "") -> JSONValue {
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
        if let guide, !ChatToolOutcome.outputLooksSuccessful(result), !ChatToolOutcome.isWaitingOnPerson(result),
           !doorFloorReasons.contains(doorText(fields["reason"])) {
            fields["guide"] = guide
        }
        return .object(fields)
    }

    private static let browserTools = ToolNameAliases.foldedTools.filter { $0.key.hasPrefix("browser.") }
        .sorted { $0.key.count > $1.key.count }

    /// `browser.chrome_scroll{delta_y}` in a page's text is `app chrome.scroll{delta_y}`.
    static func browserSteps(_ text: String) -> String {
        browserTools.reduce(text) { $0.replacingOccurrences(of: $1.key, with: "app " + $1.value) }
    }

    /// Knocks the call delivered, or why the ledger could not say: never a zero for an unread ledger.
    private static func knocksDelivered(before: Result<[String: String], any Error>,
                                        after: Result<[String: String], any Error>) -> JSONValue {
        switch (before, after) {
        case (.success(let before), .success(let after)):
            return .int(Int64(after.filter { before[$0.key] != $0.value }.count))
        case (.failure(let error), _), (_, .failure(let error)):
            return ownedFailure(error, code: "attention_ledger_unreadable", owner: "notify/attention_router.json",
                instruction: "Read notification delivery evidence before deciding whether another notification is needed; the unread ledger proves no count.",
                next: ["page": .string("notifications")], effects: .unknown)
        }
    }

    /// Every note by id, archived ones too, so a new id is a note the call
    /// raised. Read in process, as part of the action's own receipt. Nil when
    /// the inbox did not read; the receipt says so.
    @MainActor
    private func doorNotes() async -> [(id: String, title: String)]? {
        guard let host = quietHost(),
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
    // Nested batches re-enter the tool chain with the same guarded page versions.
    @MainActor var versions: [String: JSONValue]?
    private let lock = NSLock()
    private var held: [(id: String, title: String)]?
    var notes: [(id: String, title: String)]? {
        get { lock.withLock { held } }
        set { lock.withLock { held = newValue } }
    }
}

/// The door's own answer comes before any card: a door call is previewed
/// through the same checks the real call makes, and one it would refuse
/// (an owner's action, bad arguments) refuses instead of asking anyone.
extension AppToolExecutor: PureToolArgumentValidating {
    public func argumentRefusal(tool: String, input: [String: JSONValue]) async -> JSONValue? {
        guard tool == "app", input["preview"] != .bool(true), input["action"] != nil else { return nil }
        var preview = input
        preview["preview"] = .bool(true)
        guard case .object(var fields)? = try? await runAppDoor(input: preview, surface: "app", inProcess: true) else { return nil }
        if case .string(let code)? = fields["would_refuse"] {
            fields["status"] = .string("refused")
            fields["reason"] = .string(code)
            fields["effects"] = .string("none")
            return .object(fields)
        }
        return ChatToolOutcome.exactResultClass(.object(fields)) == .refused || fields["status"] == .string("failed")
            ? .object(fields) : nil
    }
}
