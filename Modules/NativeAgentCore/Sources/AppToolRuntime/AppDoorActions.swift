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
// Blueprint: | `AppDoorActions.swift` | App action execution, version recovery and result handling |
extension AppToolExecutor {
    @MainActor
    func doorUndo(input: [String: JSONValue]) async throws -> JSONValue {
        let root = quietHost()?.dataRootOverride ?? PersistenceCore.defaultDataRoot()
        let session = ChatToolSessionContext.verifiedSessionId ?? input["__session_id"]?.scalarText ?? ""
        guard !session.isEmpty, let saved = await AgentWorkspaceNavigation.shared.undoReceipt(dataRoot: root, scope: session),
              case .object(let receipt) = saved, let action = receipt["action"]?.scalarText else {
            return Self.failure("nothing_to_undo", "This conversation has no readable retained change to undo. Nothing was written.",
                extra: ["remedy": Repair.terminal(instruction: "No retained inverse is available. Do not invent an undo; inspect the affected state before choosing a new change.")])
        }
        if let reason = receipt["undo_unavailable"]?.scalarText {
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
            let outcome = AgentRecipeStore.read(host: receipt["host"]?.scalarText)
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
    func doorDo(_ id: String, resolved: (action: AppAction, discovery: [String: JSONValue])?, input: [String: JSONValue], surface: String, inProcess: Bool) async throws -> JSONValue {
        if id.lowercased() == "find", let find = input["find"], !Self.doorText(find).isEmpty {
            return Self.doorRefusal("action_route", "find is an app key, not an action. Nothing ran.",
                remedy: "correct_route", "Make next_call to discover matching actions.",
                next: ["find": find])
        }
        let root = quietHost()?.dataRootOverride ?? PersistenceCore.defaultDataRoot()
        // An older door answers through the one form and names the new call.
        if let alias = Self.partAlias(id, Self.partFields(input["args"]), root: root) {
            let result = try await doorDo(alias.id, resolved: await AppActions.resolvedAction(alias.id, dataRoot: root), input: input.merging(["args": .object(alias.args)]) { $1 }, surface: surface, inProcess: inProcess)
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
        guard let action = resolved?.action else {
            if let partID = ToolNameAliases.authoredTool(id), let row = try Parts(root: root).row(partID),
               let status = row["status"]?.scalarText, status != "active" {
                let name = row["name"]?.scalarText ?? partID
                // An off whose actor is unreadable is named as the guard names it.
                if status == "disabled" {
                    do { _ = try CapabilityLifecycle.preservingOwnerOff(row, before: row, ownerAuthorized: true, preview: true) }
                    catch { return Self.failure("part_disabled", "\(name) didn't run: \(error.localizedDescription)",
                                                extra: ["requested": .string(id), "id": .string(partID)]) }
                }
                // Off by the person (or by a record too old to say who) is his
                // decision: name his control and owe nothing. Off by her is hers to restore.
                if status == "disabled", CapabilityLifecycle.requiresOwnerToEnable(isOff: true, disabledBy: row["disabledBy"]?.scalarText) {
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
            let requestedPage = Self.doorText(input["page"])
            let nearestPage = AppDoorNames.resolve(requestedPage.isEmpty ? String(id.split(separator: ".").first ?? "") : requestedPage)
            let ownActions = await Self.doorPageActions(nearestPage, hasSettings: false, dataRoot: root)
                .filter { $0.page == nearestPage && !$0.isItemRead }
            let nearest: [AppAction]
            if ownActions.isEmpty {
                nearest = try await AppActions.ranked(id, pages: doorPageIndex, dataRoot: root, memory: actionIndex)
                    .actions.filter { !$0.isItemRead }
            } else { nearest = ownActions }
            return Self.doorRefusal("unknown_action", "No action is called that. See nearest, or use find by intent. actions is a top-level argument for an array of calls, not an action. A home name or ref (desk.4, mail.find, an agent's name) opens with item.",
                remedy: "find", "Use one of nearest or find by intent. Read a page's action list with {page, item:\"actions\"}; batch calls with {actions:[{action,args}]}. Nothing was done.",
                next: ["find": .string(id)],
                extra: ["requested": .string(id),
                        "nearest": .array(nearest.prefix(3).map { .string($0.line) })])
        }
        // Under Full Mac his actions are hers too. The code each
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
        let discovery = resolved?.discovery ?? [:]
        func badArgs(_ reason: String, _ detail: String, _ path: String) -> JSONValue {
            var extra = receipt
            extra["argument_path"] = .string(path)
            extra["args_schema"] = discovery["args_schema"]
            var example = if case .object(let call)? = discovery["example"] { call } else { [String: JSONValue]() }
            if input["preview"] == .bool(true) { example["preview"] = .bool(true) }
            if let version = input["expected_version"] { example["expected_version"] = version }
            if action.id.hasPrefix("desk.") {
                return ChatToolOutcome.failure(error: ToolFailureError(detail, argumentPath: "$." + path,
                    effects: .none, code: "invalid_input"), tool: "app")
            }
            return Self.doorRefusal(reason, detail, remedy: "correct_arguments",
                "Use this call shape with your intended values. Nothing ran.", next: example, extra: extra)
        }
        let args: [String: JSONValue]
        switch input["args"] {
        case .object(let given)?:
            if action.id == "desk.close" { args = given }
            else if let schema = discovery["args_schema"] {
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
        if !woken, let schema = discovery["args_schema"],
           let problem = JSONValue.object(validationArgs).schemaProblem(schema: schema, path: "args") {
            return badArgs("bad_input", "\(problem.path) must be \(problem.expected): \(action.line)", problem.path)
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
        if let reason = args["reason"]?.scalarText { receipt["reason_given"] = .string(String(reason.prefix(280))) }
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
           let session = ChatToolSessionContext.verifiedSessionId ?? input["__session_id"]?.scalarText, !session.isEmpty {
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
            for key in ["execution", "changed", "effects", "effect", "read_only", "irreversible"] { receipt[key] = fields[key] }
            if case .string(let status)? = fields["status"] { receipt["status"] = .string(status) }
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
                receipt["remedy"] = fields["remedy"] ?? Self.readRecovery(action, read: read)
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
    private static func readRecovery(_ action: AppAction, read: Bool = true) -> JSONValue {
        .object(["kind": .string("inspect"), "owner": .string(action.id),
            "instruction": .string(read
                ? "Read \(action.id)'s argument schema with next_call to choose a supported read and address the reported cause. This read changed nothing."
                : "Read \(action.id)'s current requirements and correct the reported cause before another call. Check what took effect before repeating a change."),
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
           !ChatToolOutcome.isWaitingOnPerson(result), let run = fields["run"]?.scalarText {
            fields["next_call"] = .object(["tool": .string("app"), "input": .object(["action": .string(run), "args": .object([:])])])
        }
        fields.merge(action.effectFields(args: args, result: fields)) { _, value in value }
        let status = doorText(fields["status"])
        if fields["execution"] == nil {
            fields["execution"] = .string(fields["not_run_status"] != nil || status == "not_run" || ChatToolOutcome.neverRan(result)
                || status == "refused" && fields["effects"] == .string("none")
                || ChatToolOutcome.isWaitingOnPerson(result) ? "not_run"
                : ChatToolOutcome.exactResultClass(result) == .succeeded ? "executed" : "attempted")
        }
        if fields["execution"] == .string("not_run") {
            fields["effect"] = .string("none")
        }
        if action.id == "agent.read", fields["execution"] == .string("executed") {
            fields["effect"] = .string("none")
            fields["effects"] = .string("none")
            return .object(fields)
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
