import Experiences
import AgentWorkspace
import Agents
import TurnTrace
import AuthoredCapabilities
import AttentionRouting
import ChatTurnContracts
import ChatTurnRuntime
import ChatToolRuntime
import AgentConversations
import ChatToolParsing
import CryptoKit
import Foundation
import Privacy
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
// Blueprint: | `AppToolExecutor+AppDoor.swift` | `app`, `visible`, `undo`; App dispatch, version recovery and action-owned undo |
/// The app door adds no gate: registry admission and folded re-entry retain the complete chain.
/// It refuses user-only actions below Full Mac, stale versions and undeclared arguments.
extension AppToolExecutor {
    public static let doorToolNames = ["app"]
    /// The rail's inbox means Notifications, while door inbox reads notes from the Today sheet.
    static let doorInbox = QuietToolPage.inbox
    @MainActor var doorPages: [QuietToolPage] { get throws { [Self.doorInbox] + (try presentation.pages) } }
    @MainActor var doorPageIndex: [String: QuietToolPage] { get throws { try Dictionary(doorPages.map { ($0.id, $0) }, uniquingKeysWith: { first,
        _ in first }) } }
    /// Resolve mounted presentation for "visible" before ordinary page lookup; "current" means the Advanced sidebar page.
    @MainActor func doorPage(_ raw: String) -> QuietToolPage? {
        let key = AppDoorNames.resolve(raw)
        if key == "inbox" { return Self.doorInbox }
        if key == "current" { return presentation.currentPage }
        // Context receipts and agent_view read outside the index; the latter must not resolve as the agents contact page.
        return QuietToolPage.unindexed.first { $0.id == key } ?? presentation.page(named: key)
    }
    public static let doorDoctor = "Doctor (app {page:\"diagnostics\", item:\"doctor\"})"
    /// Keys beginning with __ belong to the gate chain.
    static let doorKeys: Set<String> = ["page", "item", "action", "args", "actions", "preview", "expected_version", "find", "script"]
    static func doorText(_ value: JSONValue?) -> String {
        value?.scalarText?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
    }
    /// Home and unpaged items may name effects, so they share resolution with scripts.
    static func opensHomeItem(_ input: [String: JSONValue]) -> Bool {
        guard !doorText(input["item"]).isEmpty else { return false }
        let page = doorText(input["page"]).lowercased()
        return page.isEmpty || page == "home"
    }
    static let doorScriptKey = "__script"
    /// Door refusals precede execution and name the correcting call.
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
    /// Owned refusals retain the deciding owner and its exact recovery control.
    static func doorRefusal(_ reason: String, _ detail: String, owner: String, next: [String: JSONValue]? = nil,
                            tap: String? = nil, extra: [String: JSONValue] = [:]) -> JSONValue {
        var extra = extra
        extra["remedy"] = Repair.remedy(owner: owner,
            nextCall: next.map { .object(["tool": .string("app"), "input": .object($0)]) }, tap: tap)
        return failure(reason, detail, extra: extra)
    }
    /// Only explicit release with a reason or a successful operation settles owed repair.
    @MainActor
    func runRepairLetGo(input: [String: JSONValue]) async -> JSONValue {
        var id = (input["id"]?.scalarText ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        let reason = (input["reason"]?.scalarText ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        guard !id.isEmpty, !reason.isEmpty else {
            return Self.doorRefusal("invalid_args", "Pass id (from an OWED line on your home) and reason. Nothing was let go.",
                remedy: "correct_arguments", "Call repair.let_go with id and reason.")
        }
        let root = quietHost()?.dataRootOverride ?? PersistenceCore.defaultDataRoot()
        let store = ExperienceStore.at(root)
        do {
            await store.drained()
            var owed = try await store.experience(id)
            // A named subject may settle only the unique open repair whose operation ends with that subject.
            if owed == nil {
                let named = try await store.open().filter { debt in
                    RepairOwed.isOwed(debt) && RepairDebt(debt).operation.map { $0 == id || $0.hasSuffix(":" + id) } == true
                }
                if named.count == 1 { owed = named[0]; id = named[0].id }
            }
            // Reply debt settles through its delivery owner so experience and Desk state agree.
            if let owed, owed.owes["deliver"]?.phase.isSettled == false,
               owed.evidence.contains(where: { $0.source == "codex-completion-lifecycle" }) {
                try await CodexCompletionLifecycle.letGoReplies(deliveryIDs: [id], outcome: reason, dataRoot: root,
                    configRoot: InstallPaths.current.bridgeConfigRoot(dataRoot: root))
                return .object(["status": .string("ok"), "id": .string(id), "let_go": .string(reason), "effects": .string("occurred")])
            }
            // Release obsolete reply debt through its redelivery checkpoint so recovery cannot deliver it again.
            if let owed, id.hasPrefix(Experience.answer(run: "")),
               owed.owes.contains(where: { $0.key.hasPrefix("deliver:") && !$0.value.phase.isSettled }),
               let conversation = owed.addressedTo.first(where: { $0.hasPrefix("conversation:") }) {
                try await store.append([.claim(.init(claim: "let go: " + reason, evidence: []))], to: id)
                try await SwiftNativeChatOrchestrationClient.settleReplyCheckpoint(dataRoot: root,
                    sessionId: String(conversation.dropFirst("conversation:".count)),
                    runId: String(id.dropFirst(Experience.answer(run: "").count)), verdict: "let_go")
                return .object(["status": .string("ok"), "id": .string(id), "let_go": .string(reason), "effects": .string("occurred")])
            }
            if let owed, owed.owes["decide"]?.phase.isSettled == false {
                return Self.doorRefusal("person_decides", """
                    \(id) waits on the person's decision; it is theirs to answer, not yours to let go. Nothing was let go.
                    """,
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
    @MainActor func runBackgroundRepair(tool: String, input: [String: JSONValue], workspace: WorkspaceOperation) async -> JSONValue {
        let root = quietHost()?.dataRootOverride ?? securityCenter.dataRoot
        do {
            let detail: String
            switch tool {
            case "turn_reconcile":
                try await AbandonedTurnReconciliationHook.reconcile(dataRoot: root,
                    sessionId: Self.doorText(input["session_id"]), turnId: Self.doorText(input["turn_id"]))
                detail = "The saved turn was reconciled."
            default:
                detail = try ResidentWake.shared.accept(workspace: workspace, dataRoot: root, id: input["id"]?.scalarText)
            }
            return .object(["status": .string("ok"), "detail": .string(detail)])
        } catch { return ChatToolOutcome.failure(error: error) }
    }
    /// Read-only actions named as pages/items run directly; changes return a corrected call because they require explicit execution.
    func runCorrectedRead(_ correction: JSONValue, input: [String: JSONValue], surface: String, inProcess: Bool, turn: Turn,
        execution: AppActionExecution) async throws -> JSONValue {
        // Parts cannot turn reads into actions here; the host already checked the one declared-read correction.
        if let part = turn.partID, part != "app-script" { return correction }
        let reply = ToolResult(correction)
        guard case .object(let remedy)? = reply.remedy,
              case .object(let next)? = remedy["next_call"], case .object(var call)? = next["input"],
              call["preview"] != .bool(true), case .string(let id)? = call["action"], let action = try AppActions.action(id,
                  turn: turn) else { return correction }
        // A misplaced find argument supplies memory.recall's absent query. Both forms here name an optional query, which the door's binding of
        // a missing required argument never reaches, and neither arrives as an args key.
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
        var value = AgentWorkspace.resolvedRead(try await runAppDoor(input: call, surface: surface, inProcess: inProcess, turn: turn, execution: execution),
            as: id)
        if case .object(var result) = value {
            result["argument_notes"] = .array((result["argument_notes"]?.arrayValue ?? [])
                + [.string("Ran as {action:\"\(id)\"}; it is an action, not a page or item.")])
            result["resolved"] = .string(id)
            value = .object(result)
        }
        return value
    }
    static func doorActionCorrection(_ name: String, input: [String: JSONValue], turn: Turn) async throws -> JSONValue? {
        let key = name.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        let args = if case .object(let args)? = input["args"] { args } else { [String: JSONValue]() }
        let call = try (AppActions.action(key, turn: turn) ?? AppActions.pagePrefixedAction(key, turn: turn)).map { ["action": JSONValue.string($0.id),
            "args": input["args"]
            ?? .object(args)] }
        guard var call else { return nil }
        for key in ["preview", "expected_version"] { if let value = input[key] { call[key] = value } }
        TurnTraceBus.fireFromContext(kind: "shim.fired", payload: .object(["id": .string("T16"), "site": .string(
            "AppToolExecutor+AppDoor.swift:doorActionCorrection")]), turn: turn)
        return doorRefusal("action_route", "Use the corrected app call. Nothing ran.",
            remedy: "correct_route", "Make next_call instead.", next: call,
            extra: ["resolved": call["action"] ?? .null])
    }
    /// User/posture refusals run nothing; retrying without changing the cause cannot help.
    static let doorFloorReasons: Set<String> = [
        "owners_call", "owner_only", "trust_mode_read_only", "trust_mode_unreadable", "owners_screen", "owner_is_in_it",
        "trust_posture_needs_full_mac", "full_mac_only", "opens_for_owner", "owners_ears", "owners_draft",
        // Remote or unknown-origin cards remain user-owned.
        "not_yours_to_answer", "origin_unverifiable",
        // Direct person-only actions remain so under Full Mac, including browser sign-in.
        "needs_person",
    ]
    static let doorItemReads = AppDoorNames.items
    /// Every page words not_found consistently with its page/name/recovery read; unrelated failures retain their own cause.
    static func doorItemRead(_ result: JSONValue, page: QuietToolPage, item: String) -> JSONValue {
        guard !item.isEmpty, case .object(let fields) = result, fields["status"] == .string("not_found") else { return result }
        return doorRefusal("unknown_item", "Nothing named \(item) is on the \(page.title) page now; app {page:\"\(page.id)\"} lists what is.",
            remedy: "read_page", "Read the page without item; nothing was done.", next: ["page": .string(page.id)])
    }
    /// Note buttons share door action ids; viewing is an item read, and unnamed buttons retain inbox.act.
    static func doorButtons(_ note: JSONValue) -> JSONValue {
        guard case .object(var row) = note, case .array(let buttons)? = row["actions"] else { return note }
        row["actions"] = .array(buttons.compactMap { button -> JSONValue? in
            let text = button.scalarText ?? ""
            let parts = text.split(separator: ":", maxSplits: 1).map { $0.trimmingCharacters(in: .whitespaces) }
            return noteButton(id: parts[0], label: parts.count > 1 ? parts[1] : parts[0]).map(JSONValue.string)
        })
        return .object(row)
    }
    /// View/read/reply remain reads; other buttons bind their action or inbox.act by id.
    public static func noteButton(id raw: String, label: String) -> String? {
        let id = InboxActionVocabulary.normalizedAction(raw.lowercased())
        guard !["view", "read", "reply"].contains(id) else { return nil }
        // Inbox buttons are fixed declarations, never a file-backed catalog lookup.
        let seeds: [AppAction]
        do { seeds = try AppActions.seedActions }
        catch { return label + " · action catalog unavailable: " + error.localizedDescription + "; repair the catalog before using this button" }
        let action = seeds.first { $0.page == "inbox" && $0.label.caseInsensitiveCompare(label) == .orderedSame }
            ?? (["archive", "dismiss", "repair"].contains(id) ? seeds.first { $0.id == "inbox." + id } : nil)
        guard let action else { return "inbox.act(action: \"\(id)\") \(label)" }
        return action.id + (action.isPersonOwned ? " · the owner's" : "")
    }
    /// Self-window handoffs execute in process inside the original gated act/go/screen call.
    @MainActor
    public func runSelfAppRoute(input: [String: JSONValue], surface: String, turn: Turn, execution: AppActionExecution) async -> JSONValue {
        do { return try await runAppDoor(input: input, surface: surface, inProcess: true, turn: turn, execution: execution) }
        catch { return ChatToolOutcome.failure(error: error, tool: "app") }
    }
    @MainActor
    func runAppDoor(input rawInput: [String: JSONValue], surface: String, inProcess: Bool = false, turn: Turn,
        execution: AppActionExecution) async throws -> JSONValue {
        var input = rawInput
        let workspace = ChatWorkspaceBinding.operation(turn: turn, invocation: execution.invocation)
        if AppDoorNames.resolve(Self.doorText(input["page"])) == "visible", input["action"] == nil {
            guard let visible = presentation.visiblePageInput else { return Self.unattachedFailure() }
            input.merge(visible) { _, visible in visible }
        }
        // Approval replay carries the same receipt into this action's explicit execution.
        if let saved = input.removeValue(forKey: "__undo_receipt") {
            let root = quietHost()?.dataRootOverride ?? PersistenceCore.defaultDataRoot()
            let session = turn.verifiedSessionID ?? input["__session_id"]?.scalarText ?? ""
            guard !session.isEmpty, case .object(let receipt) = saved, receipt["action"] == input["action"],
                  saved == (await AgentWorkspaceNavigation.shared.undoReceipt(dataRoot: root, scope: session)) else {
                return Self.failure("stale_undo", "That undo receipt is no longer this conversation's last change. Nothing was written.")
            }
            var undoExecution = execution
            undoExecution.undoReceipt = saved
            let result = try await runAppDoor(input: input, surface: surface, inProcess: inProcess, turn: turn, execution: undoExecution)
            if input["preview"] != .bool(true), ChatToolOutcome.outputLooksSuccessful(result), !ChatToolOutcome.isWaitingOnPerson(result) {
                await AgentWorkspaceNavigation.shared.clearUndo(saved, dataRoot: root, scope: session)
            }
            return result
        }
        if case .string? = input["item"], Self.doorText(input["item"]).isEmpty { input.removeValue(forKey: "item") }
        let root = quietHost()?.dataRootOverride ?? PersistenceCore.defaultDataRoot()
        let scope = input["__session_id"]?.scalarText ?? turn.verifiedSessionID ?? ""
        if Self.doorText(input["page"]).isEmpty, !Self.doorText(input["item"]).isEmpty,
           input[Self.doorScriptKey] != .bool(true), !scope.isEmpty,
           let page = await AgentWorkspaceNavigation.shared.lastDoorPage(dataRoot: root, scope: scope),
           ["tools", "skills"].contains(page) {
            let item = Self.doorText(input["item"])
            let known = page == "tools" ? try Parts(root: root).row(item, kind: nil) != nil
                : try InstalledSkillInventory.match(item, in: InstalledSkillInventory.entries(dataRoot: root)) != nil
            if known || item.lowercased() == "census" { input["page"] = .string(page) }
        }
        // Call prediction must share the exact page/item resolution used by execution.
        if let step = AppDoorNames.step(page: Self.doorText(input["page"]), item: Self.doorText(input["item"]),
                                        action: !Self.doorText(input["action"]).isEmpty) {
            if step.page.isEmpty { input.removeValue(forKey: "page") } else { input["page"] = .string(step.page) }
            if let item = step.item { input["item"] = .string(item) }
            let result = try await runAppDoor(input: input, surface: surface, inProcess: inProcess, turn: turn, execution: execution)
            return AgentWorkspace.resolvedRead(result, as: step.label)
        }
        let action = Self.doorText(input["action"])
        let resolvedAction = try await AppActions.resolvedAction(action, dataRoot: root, turn: turn)
        // A bare item names its unique owner; ambiguity is explicit, including a home room.
        if Self.doorText(input["page"]).isEmpty, case .string? = input["item"], !Self.doorText(input["item"]).isEmpty {
            let named = Self.doorText(input["item"])
            let root = quietHost()?.dataRootOverride ?? PersistenceCore.defaultDataRoot()
            let scope = input["__session_id"]?.scalarText ?? turn.verifiedSessionID ?? ""
            var owners = Dictionary(uniqueKeysWithValues: Self.doorItemReads.filter {
                $0.value[named.lowercased()] != nil
            }.map { ($0.key, named.lowercased()) })
            let skillName = named.hasPrefix("skill:") ? String(named.dropFirst(6)).trimmingCharacters(in: .whitespaces) : named
            if let skill = InstalledSkillInventory.match(skillName, in: try InstalledSkillInventory.entries(dataRoot: root)) {
                owners["skills"] = skill.id
            }
            if let host = quietHost() {
                if let refusal = await host.inboxFence(verb: "read", input: ["id": .string(named)], turn: turn) {
                    guard case .object(let fields) = refusal, fields["reason"] == .string("unknown_id") else { return refusal }
                } else { owners["inbox"] = named }
            }
            if let desk = try await SwiftToolDispatcher.deskMatches(named,
                in: SwiftNativeDeskStore(dataRoot: root).liveState()).first {
                owners["desk"] = desk.handle
            }
            let conversations = try HumanConversationIndex.rows(dataRoot: root)
            let ids = conversations.filter { $0["id"]?.stringValue.flatMap({ $0.isEmpty ? nil : $0 })?.caseInsensitiveCompare(named) == .orderedSame }
            let conversationID = !ids.isEmpty
            let matches = conversationID ? ids : conversations.filter { $0["title"]?.stringValue.flatMap({ $0.isEmpty ? nil : $0 })?.caseInsensitiveCompare(
                named) == .orderedSame }
            guard matches.count <= 1 else {
                return Self.doorRefusal("ambiguous_item", "More than one conversation has that name.",
                    remedy: "choose_item", "Read chat.list, then use an exact conversation id.", next: ["action": .string("chat.list")])
            }
            if let row = matches.first { owners["chat"] = row["id"]?.stringValue.flatMap({ $0.isEmpty ? nil : $0 }) }
            if !owners.isEmpty, !conversationID, !(owners["desk"] != nil && named.lowercased().hasPrefix("desk.")),
               await AgentScreen.classify(workspace: workspace, named, dataRoot: root, scope: scope) != .unknown {
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
                return AgentWorkspace.resolvedRead(try await runAppDoor(input: input, surface: surface, inProcess: inProcess, turn: turn, execution: execution),
                                         as: page + "." + item)
            }
            if let page = doorPage(named) {
                input["page"] = .string(page.id)
                input.removeValue(forKey: "item")
                return AgentWorkspace.resolvedRead(try await runAppDoor(input: input, surface: surface, inProcess: inProcess, turn: turn,
                    execution: execution), as: page.id)
            }
        }
        // Other keys app does not take still fail loudly.
        let stray = input.keys.filter { !Self.doorKeys.contains($0) && !$0.hasPrefix("__") }.sorted()
        if !stray.isEmpty {
            if stray.count == 1, action.isEmpty, let key = stray.first, let value = input[key],
               let correction = try await Self.doorActionCorrection(key, input: input.merging(["args": value]) { _, value in value }, turn: turn) {
                return try await runCorrectedRead(correction, input: input, surface: surface, inProcess: inProcess, turn: turn, execution: execution)
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
            return try await doorMany(list, base: beside, turn: turn, execution: execution)
        }
        if let value = input["script"], value != .null, value != .string("") {
            // One call is one thing: the gates and the plan judge it by its action, so a script never rides under one.
            guard action.isEmpty else {
                return Self.doorRefusal("action_and_script",
                    "app takes an action or a script, not both. Nothing was run.", remedy: "correct_arguments",
                    "Call app again with only the action and its args, or only the script.")
            }
            guard case .string(let script) = value else {
                return Self.doorRefusal("invalid_script", "script must be a JavaScript function body. Nothing was run.",
                    remedy: "correct_arguments", "Use script:\"return [app.files.list({path:'docs'}), app.desk.read({})];\".")
            }
            return Self.previewApproval(await doorScript(script, input: input, surface: surface, turn: turn, execution: execution),
                preview: input["preview"] == .bool(true))
        }
        // A screen name given as an action opens the same item its DO list names.
        if !action.isEmpty, resolvedAction == nil,
           input[Self.doorScriptKey] != .bool(true),
           await AgentScreen.classify(workspace: workspace, action, dataRoot: quietHost()?.dataRootOverride ?? PersistenceCore.defaultDataRoot(),
                                    scope: input["__session_id"]?.scalarText ?? turn.verifiedSessionID ?? "") != .unknown {
            var item = input.filter { !["action", "page", "item"].contains($0.key) }
            item["item"] = .string(action)
            return try await runAppDoor(input: item, surface: surface, inProcess: inProcess, turn: turn, execution: execution)
        }
        // Scalar-list fan-out is allowed only for reads or folded tools whose gates judge each element; other changes require actions.
        if let target = resolvedAction?.action, case .object(let args)? = input["args"],
           target.isFold || target.readOnly(args: args), let (key, values) = Self.doorPlural(target, args, discovery: resolvedAction?.discovery ?? [:]) {
            TurnTraceBus.fireFromContext(kind: "shim.fired", payload: .object(["id": .string("T17"), "site": .string(
                "AppToolExecutor+AppDoor.swift:runAppDoor")]), turn: turn)
            return try await doorMany(values.map { .object(["args": .object(args.merging([key: $0]) { $1 })]) },
                                      base: input.filter { $0.key != "args" }, turn: turn, execution: execution)
        }
        if !action.isEmpty {
            var value = try await doorDo(action, resolved: resolvedAction, input: input, surface: surface, inProcess: inProcess, turn: turn,
                execution: execution)
            if let action = resolvedAction?.action, case .object(var fields) = value {
                if fields["execution"] == nil { fields["execution"] = .string("not_run") }
                var metadata = action.effectFields(args: input["args"]?.objectValue ?? [:], result: fields)
                if fields["execution"] == .string("not_run") { metadata["effect"] = .string("none") }
                fields.merge(metadata) { current, _ in current }
                value = .object(fields)
            }
            return Self.previewApproval(value, preview: input["preview"] == .bool(true))
        }
        let find = Self.doorText(input["find"])
        let page = Self.doorText(input["page"])
        var item = Self.doorText(input["item"])
        if !page.isEmpty, item.isEmpty, doorPage(page) == nil, let correction = try await Self.doorActionCorrection(page, input: input, turn: turn) {
            return try await runCorrectedRead(correction, input: input, surface: surface, inProcess: inProcess, turn: turn, execution: execution)
        }
        // A guide names its action, and the action its page: guide:<id> reads with or without page, and from a page that is not the action's own (a room,
        // Senses) it reads from the action's.
        if item.hasPrefix("guide:"), page.isEmpty || doorPage(page) == nil,
           let named = (try await AppActions.resolvedAction(String(item.dropFirst("guide:".count)), dataRoot: root, turn: turn))?.action, named.page != "*" {
            var call = input
            call["page"] = .string(named.page)
            call["item"] = .string("guide:" + named.id)
            return try await runAppDoor(input: call, surface: surface, inProcess: inProcess, turn: turn, execution: execution)
        }
        if page.isEmpty, !item.isEmpty, let correction = try await Self.doorActionCorrection(item, input: input, turn: turn) {
            return try await runCorrectedRead(correction, input: input, surface: surface, inProcess: inProcess, turn: turn, execution: execution)
        }
        // An item with no page is a name or ref from home or one of its rooms.
        let homeItem = Self.opensHomeItem(input)
        // A script reads pages; it never opens an item anywhere but a real page.
        if input[Self.doorScriptKey] == .bool(true), input["item"].map({ $0 != .null }) == true,
           homeItem || doorPage(page) == nil {
            return Self.doorRefusal("action_required",
                "A script opens an item only on a real page; a home item can send or change something. Nothing was read or done.",
                remedy: "none", "Call the item's named action through app instead.")
        }
        // A home item does what its name says at once: there is nothing to preview, and no page version guards it.
        if homeItem, input["preview"] == .bool(true) || !Self.doorText(input["expected_version"]).isEmpty {
            if item.lowercased().hasSuffix(".say") {
                var args: [String: JSONValue]
                switch input["args"] {
                case .object(let supplied)?: args = supplied
                case nil, .null?: args = [:]
                default:
                    return Self.doorRefusal("invalid_args", "Message arguments must be an object. Nothing was sent.",
                        remedy: "correct_arguments", "Use agent.message with its named arguments and preview:true.")
                }
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
        if !find.isEmpty && !homeItem { return try await doorFind(find, turn: turn, execution: execution) }
        if homeItem || page.lowercased() == "home" {
            if input[Self.doorScriptKey] != .bool(true), !scope.isEmpty {
                try await AgentWorkspaceNavigation.shared.rememberDoorPage(workspace: workspace, nil, dataRoot: root, scope: scope)
            }
            var call: [String: JSONValue] = [:]
            if !item.isEmpty { call["action"] = .string(item) } else if !find.isEmpty { call["query"] = .string(find) }
            if case .object(let args)? = input["args"] {
                if let stray = args.keys.sorted().first(where: { !["text", "fields", "conversation", "expects_reply"].contains($0) }) {
                    return Self.doorRefusal("unknown_arg",
                        "A home item takes text, fields, or an agent conversation label and expects_reply in args, not \(stray). Nothing was read or done.",
                        remedy: "correct_arguments", """
                            Call app again with args {text, conversation?, expects_reply?} for an agent message, {fields} for a form, or none.
                            """,
                        extra: ["argument_path": .string("args.\(stray)")])
                }
                for (key, value) in args where value != .null { call[key] = value }
            }
            return await doorHome(call, input: input, turn: turn, execution: execution)
        }
        if page.isEmpty {
            if input[Self.doorScriptKey] != .bool(true), !scope.isEmpty {
                try await AgentWorkspaceNavigation.shared.rememberDoorPage(workspace: workspace, nil, dataRoot: root, scope: scope)
            }
            return try await doorIndex(input, turn: turn, execution: execution)
        }
        if let corner = SenseCorner(key: page), let result = try await doorSenseRead(corner: corner, item: item, input: input, turn: turn,
            execution: execution) {
            return result
        }
        guard let resolved = doorPage(page) else {
            let root = quietHost()?.dataRootOverride ?? PersistenceCore.defaultDataRoot()
            let scope = input["__session_id"]?.scalarText ?? turn.verifiedSessionID ?? ""
            let kind = await AgentScreen.classify(workspace: workspace, page, dataRoot: root, scope: scope)
            if kind != .unknown {
                // A page read may open a room or record, never invoke its effect verbs.
                let name = item.isEmpty ? page : item
                let itemKind = item.isEmpty ? kind : await AgentScreen.classify(workspace: workspace, item,
                    dataRoot: root, scope: scope)
                if kind == .read, itemKind == .read {
                    var call = input
                    call["page"] = .string("home")
                    call["item"] = .string(name)
                    return AgentWorkspace.resolvedRead(try await runAppDoor(input: call, surface: surface, inProcess: inProcess, turn: turn,
                        execution: execution),
                                             as: "home." + name)
                }
                return Self.doorRefusal("item_action", "That home name acts; a page only reads.", remedy: "open_item",
                    "Use item to invoke it explicitly.", next: ["item": .string(name)])
            }
            return Self.doorRefusal("unknown_page", "No page is called that.", remedy: "read_index",
                "Read {} for the pages; nothing was done.", next: [:],
                extra: ["requested": .string(page), "pages": .array(try doorPages.map { .string($0.id) })])
        }
        switch input["args"] {
        case .object(let args)?:
            let acceptsLimit = resolved.id == "chat" && !item.isEmpty && !item.hasPrefix("guide:")
            let acceptsOffset = resolved.id == "tools" && item != "census" && item != "actions" && !item.hasPrefix("guide:")
            let allowed = Set((acceptsLimit ? ["limit"] : []) + (acceptsOffset ? ["offset"] : []))
            if let stray = args.keys.sorted().first(where: { !allowed.contains($0) }) {
                // Single-subject pages use item so the scope remains explicit.
                let subject = ["context": "conversation id", "agent_view": "room"][resolved.id]
                let named: String = { if case .string(let v)? = args[stray] { return v }; return item }()
                return Self.doorRefusal("unknown_arg", "A \(resolved.id) page read does not accept args.\(stray). Nothing was read.",
                    remedy: "correct_arguments", acceptsOffset ? "Pass args.offset (a nonnegative integer) to continue this named Tools read."
                        : acceptsLimit ? "Remove that argument; this conversation read accepts only args.limit (integer)."
                        : subject.map { "Name the \($0) as item: {page: \"\(resolved.id)\", item: \"<\($0)>\"}; without item it reads the one on screen." }
                        ?? "Read the page without args. Use find for action arguments.",
                    next: ["page": .string(resolved.id), "item": .string(subject == nil ? item : named),
                           "args": .object(args.filter { allowed.contains($0.key) })],
                    extra: ["argument_path": .string("args.\(stray)")])
            }
            if let offset = args["offset"] {
                guard case .int(let n) = offset, n >= 0 else {
                    return Self.doorRefusal("bad_input", "args.offset must be a nonnegative integer. Nothing was read.",
                        remedy: "correct_arguments", "Pass the next_offset from this Tools read.", extra: ["argument_path": .string("args.offset")])
                }
            }
            if let limit = args["limit"], limit != .null,
               let problem = limit.schemaProblem(schema: .object(["type": .string("integer")]), path: "args.limit") {
                return Self.doorRefusal("bad_input", "\(problem.words). Nothing was read.",
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
        // Resolve conversation titles only when exactly one matches.
        if resolved.id == "chat", !item.isEmpty, !catalog, !item.hasPrefix("guide:") {
            let rows = try HumanConversationIndex.rows(dataRoot: quietHost()?.dataRootOverride ?? PersistenceCore.defaultDataRoot())
            if !rows.contains(where: { $0["id"]?.stringValue.flatMap({ $0.isEmpty ? nil : $0 }) == item }) {
            let named = rows.filter { $0["title"]?.stringValue.flatMap({ $0.isEmpty ? nil : $0 })?.caseInsensitiveCompare(item) == .orderedSame }
            if named.count == 1, let id = named[0]["id"]?.stringValue.flatMap({ $0.isEmpty ? nil : $0 }) { item = id }
            }
        }
        if resolved.id == "desk", !item.isEmpty, !catalog, !item.hasPrefix("guide:") {
            return Self.doorItemRead(try await doorDo("desk.read", resolved: try await AppActions.resolvedAction("desk.read", dataRoot: root, turn: turn),
                input: ["args": .object(["handle": .string(item)])],
                                                      surface: surface, inProcess: inProcess, turn: turn, execution: execution), page: resolved, item: item)
        }
        let offset: Int64 = if case .int(let value)? = input["args"]?.objectValue?["offset"] { value } else { 0 }
        let result = Self.doorItemRead(try await doorRead(page: resolved, item: catalog ? "" : item, offset: Int(offset), surface: surface,
            turn: turn, execution: execution),
            page: resolved, item: catalog ? ""
            : item)
        guard case .object(var read) = result, read["status"] == .string("ok") else { return result }
        if resolved.id == "tools", item != "census" {
            read["stopped_run_ids"] = .array(try PartRunStore.waitingIDs(root: root).map(JSONValue.string))
            read["resume_note"] = .string("""
                stopped_run_ids are saved targets for ability.resume; an empty list means none. Resume rechecks the seal, the ability and replayed reads.
                """)
        }
        if input[Self.doorScriptKey] != .bool(true), !scope.isEmpty {
            try await AgentWorkspaceNavigation.shared.rememberDoorPage(
                workspace: workspace, resolved.id, dataRoot: root, scope: scope)
        }
        if page != resolved.id { read["resolved"] = .string(resolved.id) }
        read["version"] = try read["version"] ?? .string(Self.doorVersion(page: resolved.id, item: catalog ? "" : item, read))
        if item.isEmpty, let items = Self.doorItemReads[resolved.id] {
            read["item_reads"] = .array(items.sorted { $0.key < $1.key }.map { .string("\($0.key): \($0.value)") })
        }
        // Conversation messages and reply eligibility stay outside the version because the agent's own turn moves them.
        if resolved.id == "chat", case .object(let composer)? = read["item"],
           let id = composer["conversation"]?.scalarText {
            let args: [String: JSONValue] = if case .object(let given)? = input["args"] { given } else { [:] }
            read["conversation"] = await HumanConversationReader.open(turn: turn, sessionID: id,
                limit: args["limit"]?.scalarText.flatMap { Int($0) },
                dataRoot: quietHost()?.dataRootOverride ?? PersistenceCore.defaultDataRoot())
        }
        // This chat means the request's origin, which may differ from the visible conversation.
        if resolved.id == "chat", item.isEmpty, let asking = turn.verifiedSessionID, !asking.isEmpty {
            let onScreen: String? = if case .object(let composer)? = read["item"] { composer["conversation"]?.scalarText } else { nil }
            if onScreen != asking {
                read["this_conversation"] = .object(["session_id": .string(asking),
                    "note": .string("""
                        The conversation this request came from. \"This chat\" means this one; omit session_id or pass this id. Other conversations here are \
                        what the owner has on screen.
                        """)])
            }
        }
        let hasSettings = if case .array(let rows)? = read["settings"] { !rows.isEmpty } else { false }
        let actions = try await Self.doorPageActions(resolved.id, hasSettings: hasSettings, dataRoot: root, turn: turn)
        // Compact after eight reads to bound the page alongside universal actions.
        let compact = actions.count > 8 && !catalog
        read["actions"] = .array(actions.map { .string(compact ? $0.signature : $0.line) })
        if compact { read["actions_read"] = .object(["page": .string(resolved.id), "item": .string("actions")]) }
        // One example supplies the preview shape without repeating every action.
        read["preview_examples"] = .array(try actions.filter { $0.irreversible && $0.page != "*" }.prefix(1).compactMap {
            if case .object(let discovery) = try AppActions.discovery($0) { discovery["example"] } else { nil }
        })
        // The full Mac act guide is an explicit item read; other argument rules ride schemas and refusals.
        let guides = actions.filter { $0.id == "mac.act" }
        if !guides.isEmpty {
            read["guide_reads"] = .object(Dictionary(uniqueKeysWithValues: guides.map {
                ($0.id, .object(["page": .string(resolved.id), "item": .string("guide:" + $0.id)]))
            }))
            read["guide_note"] = .string(guides.map {
                """
                    Only before \($0.id) actions, read app {page:\"\(resolved.id)\", item:\"guide:\($0.id)\"}. Plain reads (mac.look, mac.system_info, \
                    mac.volume with no args) need no guide.
                    """
            }.joined(separator: " "))
        }
        return .object(read)
    }
}
/// Preview shares execution checks and refuses invalid/user-only calls before any card can be filed.
extension AppToolExecutor: PureToolArgumentValidating {
    public func argumentRefusal(tool: String, input: [String: JSONValue], turn: Turn) async -> JSONValue? {
        await argumentRefusal(tool: tool, input: input, turn: turn, execution: actionExecution)
    }

    // Argument validation uses preflight, never an owner's model call.
    func argumentRefusal(tool: String, input: [String: JSONValue], turn: Turn, execution: AppActionExecution) async -> JSONValue? {
        guard tool == "app", input["preview"] != .bool(true), input["action"] != nil else { return nil }
        var preview = input
        preview["preview"] = .bool(true)
        let result: JSONValue
        do {
            var preflight = execution
            preflight.argumentPreflightOnly = true
            result = try await runAppDoor(input: preview, surface: "chat", inProcess: true, turn: turn, execution: preflight)
        } catch { return ChatToolOutcome.failure(error: error, tool: "app", effects: ToolFailureError.Effects.none) }
        let reply = ToolResult(result)
        guard case .object(var fields) = reply.payload else {
            return ChatToolOutcome.failure(error: ToolFailureError("""
                Argument preflight returned no structured result. Repair the action contract before running it.
                """, effects: .none, code: "argument_preflight_failed"), tool: "app")
        }
        if case .string(let code)? = fields["would_refuse"] {
            fields["status"] = .string("refused")
            fields["reason"] = .string(code)
            fields["effects"] = .string("none")
            return .object(fields)
        }
        // Keep the exact failed spelling; reply.status also accepts state and normalized spellings.
        return reply.outcome == .refused || fields["status"] == .string("failed")
            ? .object(fields) : nil
    }
}
