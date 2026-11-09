import Experiences
import Cognition
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
// Blueprint: | `AppDoorActions.swift` | Shared admission, previews and typed receipts; accepted matters supply the call's knock count |
extension AppToolExecutor {
    @concurrent private static func doorUndoLayout(root: URL) async -> JSONValue {
        SurfaceLayoutStore.read(dataRoot: root)
    }
    @concurrent private static func doorUndoRecipe(host: String?) async -> JSONValue {
        AgentRecipeStore.read(host: host)
    }
    @MainActor
    func doorUndo(input: [String: JSONValue], turn: Turn, execution: AppActionExecution) async throws -> JSONValue {
        let root = quietHost()?.dataRootOverride ?? PersistenceCore.defaultDataRoot()
        let session = turn.verifiedSessionID ?? input["__session_id"]?.scalarText ?? ""
        guard !session.isEmpty, let saved = await AgentWorkspaceNavigation.shared.undoReceipt(dataRoot: root, scope: session),
              case .object(let receipt) = saved, let action = receipt["action"]?.scalarText else {
            return Self.failure("nothing_to_undo", "This conversation has no readable retained change to undo. Nothing was written.",
                extra: ["remedy": Repair.terminal(instruction: """
                    No retained inverse is available. Do not invent an undo; inspect the affected state before choosing a new change.
                    """)])
        }
        if let reason = receipt["undo_unavailable"]?.scalarText {
            return Self.doorRefusal("undo_unavailable", reason, remedy: "inspect",
                "Read the recorded action's current contract; this receipt cannot undo it.", next: ["find": .string(action)])
        }
        let args: [String: JSONValue]
        switch action {
        case "layout.write":
            let outcome = await Self.doorUndoLayout(root: root)
            guard case .object(let read) = outcome, let previous = read["previous"] else {
                if !ChatToolOutcome.outputLooksSuccessful(outcome) { return outcome }
                return Self.doorRefusal("undo_unavailable", "The previous layout could not be read. Nothing was written.",
                    remedy: "inspect", "Read the layout and its retained history; do not invent the previous layout.", next: ["action": .string("layout.read")])
            }
            args = ["layout": previous, "layout_version": receipt["version"] ?? .null]
        case "agent.recipe_write":
            let outcome = await Self.doorUndoRecipe(host: receipt["host"]?.scalarText)
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
        guard let perform = execution.perform else {
            return Self.doorRefusal("door_unavailable", "Use app from a chat turn. Nothing was written.",
                remedy: "correct_arguments", "Call app from a chat turn's tool chain; this caller cannot bind a chat by supplying a session id.")
        }
        // Re-enter the original action's gates; only its owner applies the receipt.
        return try await perform("app", ["action": .string(action), "args": .object(args),
                                         "__session_id": .string(session), "__undo_receipt": saved], turn, execution)
    }
    @MainActor
    func doorDo(_ id: String, resolved: (action: AppAction, discovery: [String: JSONValue])?, input: [String: JSONValue], surface: String,
        inProcess: Bool, turn: Turn, execution: AppActionExecution) async throws -> JSONValue {
        guard let resolved else {
            return try await doorDoBound(id, resolved: nil, input: input, surface: surface, inProcess: inProcess, turn: turn, execution: execution)
        }
        let binding = AppActions.boundArguments(resolved.action, input["args"]?.objectValue ?? [:], schema: resolved.discovery["args_schema"])
        var input = input
        if !binding.understood.isEmpty { input["args"] = .object(binding.args) }
        let result: JSONValue
        if input[Self.doorScriptKey] == .bool(true), let refusal = AppScriptRunner.secretRefusal(resolved.action, binding.args) {
            result = Self.doorRefusal(refusal.reason, refusal.detail, remedy: "correct_route",
                "Pass credentials in a single app action outside a script.")
        } else {
            do {
                result = try await doorDoBound(id, resolved: resolved, input: input, surface: surface, inProcess: inProcess, turn: turn,
                    execution: execution)
            } catch is CancellationError { throw CancellationError() }
            catch { result = ChatToolOutcome.failure(error: error, tool: "app") }
        }
        let advised = Self.advisedRefusal(result, action: resolved.action, args: binding.args,
            root: quietHost()?.dataRootOverride ?? PersistenceCore.defaultDataRoot())
        let reply = ToolResult(advised)
        var receipt = advised.objectValue ?? ["result": advised, "action": .string(resolved.action.id),
            "status": .string(ChatToolOutcome.statusWord(advised, verdict: reply.outcome)),
            "execution": .string(reply.outcome == .succeeded ? "executed" : "attempted")]
        if !binding.understood.isEmpty { receipt["understood"] = .string(binding.understood.joined(separator: "; ")) }
        return .object(receipt)
    }

    @MainActor
    private func doorDoBound(_ id: String, resolved: (action: AppAction, discovery: [String: JSONValue])?, input: [String: JSONValue], surface: String,
        inProcess: Bool, turn: Turn, execution: AppActionExecution) async throws -> JSONValue {
        let root = quietHost()?.dataRootOverride ?? PersistenceCore.defaultDataRoot()
        guard let action = resolved?.action else {
            if let partID = ToolNameAliases.authoredTool(id), let row = try Parts(root: root).row(partID),
               let status = row["status"]?.scalarText, status != "active" {
                let name = row["name"]?.scalarText ?? partID
                // An off whose actor is unreadable is named as the guard names it.
                if status == "disabled" {
                    do { _ = try CapabilityLifecycle.preservingOwnerOff(row, before: row, ownerAuthorized: true, preview: true, turn: turn) }
                    catch { return Self.failure("part_disabled", "\(name) didn't run: \(error.localizedDescription)",
                                                extra: ["requested": .string(id), "id": .string(partID)]) }
                }
                // User-off and unknown-actor records remain the user's decision; only agent-off records are the agent's to restore.
                if status == "disabled", CapabilityLifecycle.requiresOwnerToEnable(isOff: true, disabledBy: row["disabledBy"]?.scalarText) {
                    return Self.failure("part_disabled", "\(name) was switched off by the person; nothing ran.",
                        extra: ["remedy": Repair.why(owner: "ability \(partID): switched off by the person",
                                                     tap: "Tools page > \(name) > turn on"),
                                "requested": .string(id), "id": .string(partID)])
                }
                // Failed runs prove no executable version; open their versioned source instead of manufacturing a keep from the current catalog.
                let hasCode = (row["candidateDigest"] ?? row["codeFingerprint"]) != nil
                let nextAction = hasCode ? "ability.read" : status == "disabled" ? "ability.restore" : "ability.enable"
                return Self.doorRefusal(status == "disabled" ? "part_disabled" : "not_kept",
                    hasCode ? """
                        \(name) is \(status == "disabled" ? "switched off" : "a draft, not kept yet"); nothing ran. Read its exact version before keeping it.
                        """
                        : status == "disabled" ? "\(name) is switched off; nothing ran. ability.restore turns it back on."
                        : "\(name) is a draft, not kept yet; nothing ran. ability.enable keeps it.",
                    owner: "ability \(partID).status",
                    next: ["action": .string(nextAction), "args": .object(["id": .string(partID)])],
                    extra: ["requested": .string(id), "id": .string(partID)])
            }
            let qualified = Self.doorText(input["page"]) + "." + id
            if let correction = try await Self.doorActionCorrection(qualified, input: input, turn: turn) {
                return try await runCorrectedRead(correction, input: input, surface: surface, inProcess: inProcess, turn: turn, execution: execution)
            }
            if let correction = try await Self.doorActionCorrection(id, input: input, turn: turn) {
                return try await runCorrectedRead(correction, input: input, surface: surface, inProcess: inProcess, turn: turn, execution: execution)
            }
            let advice = try await AppActions.callAdvice(id, input: input, pages: doorPageIndex, dataRoot: root,
                                                        memory: await actionIndex, turn: turn)
            let next: [String: JSONValue]
            if let proposed = AppActions.advisedCall(advice) { next = proposed }
            else { next = ["find": .string(id)] }
            return Self.doorRefusal("unknown_action", """
                No action is called \(id). try_instead names current actions and their argument shapes. actions is a top-level array of calls. A home \
                name or ref (desk.4, mail.find, an agent's name) opens with item.
                """,
                remedy: "find", """
                    Choose a try_instead action using its schema and your values. Read a page's action list with {page, item:\"actions\"}; batch calls with \
                    {actions:[{action,args}]}. Nothing was done.
                    """,
                next: next,
                extra: ["requested": .string(id), "try_instead": advice])
        }
        // Who decides it: the person for a lever, the agent otherwise; a lever the person decided is still theirs.
        var receipt: [String: JSONValue] = [
            "action": .string(action.id), "page": .string(action.page), "label": .string(action.label),
            "owner": .string(action.isPersonOwned || PermissionLaw.personDecided(tool: "app", input: [
                "action": .string(action.id), "args": input["args"] ?? .object([:])], turn: turn) ? "person" : "agent"),
            "execution": .string("not_run"),
        ]
        // What refuses or previews a folded tool points to its guide, never carries it.
        if !action.partAction, action.page != "*", try AppActions.about(action) != nil {
            receipt["guide"] = .object(["page": .string(action.page), "item": .string("guide:" + action.id)])
        }
        let discovery = resolved?.discovery ?? [:]
        func badArgs(_ reason: String, _ detail: String, _ path: String) -> JSONValue {
            var extra = receipt
            extra["argument_path"] = .string(path)
            extra["args_schema"] = discovery["args_schema"]
            // A refusal names what the action takes, in the envelope's own accepted field.
            let names = discovery["args_schema"]?.objectValue?["properties"]?.objectValue?.keys.sorted()
            let accepted = names.map { $0.isEmpty ? "args takes no arguments" : "args takes " + $0.joined(separator: ", ") }
            extra["accepted"] = accepted.map(JSONValue.string)
            let advice = AppActions.callAdvice(action, input: input, discovery: discovery)
            extra["try_instead"] = advice
            let call = AppActions.advisedCall(advice)
            return Self.doorRefusal(reason, detail, remedy: "correct_arguments",
                "Review next_call against try_instead and your supplied values before sending it. Nothing ran.", next: call, extra: extra)
        }
        let args: [String: JSONValue]
        switch input["args"] {
        case .object(let given)?:
            args = Self.normalizedCallArguments(action, given, schema: discovery["args_schema"])
        case nil, .null?: args = [:]
        default: return badArgs("invalid_args", "args is an object of the action's arguments by name: \(action.line)", "args")
        }
        let read = action.readOnly(args: args)
        let validationArgs = Self.doorValidationArgs(action, args)
        // Wake arguments live in input.wake; required call arguments must not refuse a wake.
        let woken = action.authored && execution.wake != nil
        guard let schema = discovery["args_schema"] else {
            throw ToolFailureError("\(action.id)'s input schema is unavailable. Nothing ran.", effects: .none,
                owner: "Tool catalog", code: "tool_schema_unavailable",
                instruction: "Repair this action's registered schema before calling it again.", recovery: .repair)
        }
        if !woken {
            do { try ToolArguments.admit(validationArgs, schema: schema, path: "args") }
            catch let error as ToolFailureError {
                if error.code == "tool_schema_unavailable" { throw error }
                return badArgs("bad_input", error.localizedDescription, error.argumentPath ?? "args")
            }
        }
        // Validate before an owner-only preview can claim a callable target.
        let ownerRemedy: JSONValue = {
            // Provider contracts name provider; inbox and connector contracts name id.
            let target = Self.doorText(args["id"] ?? args["provider"])
            let tap: String
            switch action.id {
            case "inbox.open_on_mac": tap = "Inbox → \(target) → Open on Mac"
            case "inbox.approve": tap = "Today → \(target) → Approve"
            case "inbox.deny": tap = "Today → \(target) → Decline"
            case "provider.sign_in": tap = "Mac → Providers → Accounts → Add key or Sign in → protected entry"
            case "provider.disconnect": tap = "Providers → Accounts → \(target) → Disconnect"
            case "connector.on": tap = target.lowercased() == "telegram"
                ? "Connectors → Telegram → Telegram is on" : "iPhone → Connectors → \(target) → Enabled"
            case "connector.disconnect": tap = "iPhone → Connectors → \(target) → Disconnect"
            case "telegram.disconnect": tap = "Connectors → Telegram → Disconnect Telegram"
            case "pairing.remove": tap = "Connectors → iPhone → \(target) → Remove"
            case "backup.restore": tap = "Trust → Advanced → Backups → \(target) → Restore"
            default: return .null // Actions owned by the agent never use this remedy.
            }
            return Repair.why(owner: action.id, tap: tap)
        }()
        // A lever runs only as the person's own decision of this exact call (their tap, or the card they approved); the gate asked them
        // for the agent's call, and here nothing else passes, at any posture.
        let decided = PermissionLaw.personDecided(tool: "app", input: ["action": .string(action.id), "args": input["args"] ?? .object([:])],
            turn: turn)
        // A preview of a lever a card can carry is the gate's own check before it asks the person: it reads on, and the card decides.
        if let lever = action.lever, !decided, !(lever.asks && input["preview"] == .bool(true)) {
            let why = lever.why
            receipt["owner"] = .string("person")
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
            return Self.failure("owners_call", "\(action.id) is the person's lever: \(why). "
                + (lever.asks ? "Your call asks them on a card; " : "It needs the person themself; ") + "nothing was done.", extra: receipt)
        }
        // Archive reasons must not use reason, which runners classify as the machine refusal code.
        if let reason = args["reason"]?.scalarText { receipt["reason_given"] = .string(String(reason.prefix(280))) }
        var call = action.binding.arguments(args)
        // A program calling gets a reader's structured form, where it has one.
        if input[Self.doorScriptKey] == .bool(true), call["structured"] == nil,
           action.argSpecs.flatMap(\.names).contains("structured") { call["structured"] = .bool(true) }
        if action.id == "mac.look", args["__sense_screen_frame"] != nil {
            let cursor = args.filter { ["app", "__sense_screen_frame", "__sense_text_offset"].contains($0.key) }
            call["__sense_address"] = .string(try JSONValue.object(cursor).serialize(pretty: false))
        }
        // Receipts use host verb names; credentials must never ride a receipt.
        var shown = MacInjectionArgRedaction.redacted(tool: action.tool, input: call, turn: turn)
        for name in action.secretArgs where shown[action.rename[name] ?? name] != nil {
            shown[action.rename[name] ?? name] = .string("[redacted]")
        }
        receipt["underlying_call"] = .object(["input": .object(shown)])
        let expected = Self.doorText(input["expected_version"])
        let scope = expected.split(separator: "@", maxSplits: 1).first.map(String.init) ?? action.page
        let returnsVersion = !read && (!expected.isEmpty || action.page == "chat")
        if !expected.isEmpty {
            let scopeName = scope.split(separator: "/", maxSplits: 1).first.map(String.init)
            let scopePage: String? = if let scopeName { await doorPage(scopeName)?.id } else { nil }
            guard action.page == "*" || scopePage == action.page
                || (action.tool == "sense_lifecycle" && scope == "senses/" + Self.doorText(args["sense_id"])) else {
                receipt["expected_version"] = .string(expected)
                return Self.doorRefusal("wrong_page_version",
                    "That version is from \(scopePage ?? scope), and \(action.id) is on \(action.page). Nothing was done.",
                    remedy: "reread", "Read \(action.id)'s current requirements before choosing its version.",
                    next: ["find": .string(action.id)], extra: receipt)
            }
            let current = try await doorCurrentVersion(scope: scope, surface: surface, turn: turn, execution: execution)
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
            return Self.actionResult(await doorPartResume(args, preview: input["preview"] == .bool(true),
                surface: surface, root: root, turn: turn, execution: execution), action: action, args: args, root: root)
        }
        // A part's preview runs on what its live run would get, the verb a part answers included.
        if action.authored, input["preview"] == .bool(true) {
            return Self.actionResult(await doorPartPreview(action, args: call.filter { !$0.key.hasPrefix("__") }, input: input,
                surface: surface, root: root, turn: turn, execution: execution), action: action, args: args, root: root)
        }
        guard execution.perform != nil || inProcess else {
            return Self.doorRefusal("door_unavailable",
                "This call did not come through a chat's tool chain, so it has no gate to pass. Nothing was read or done.",
                remedy: "correct_arguments", "Call app from a chat turn's tool chain; this caller cannot bind a chat by supplying a session id.")
        }
        if input["preview"] == .bool(true) {
            if !execution.argumentPreflightOnly, action.tool == "mind_run",
               let verb = call["verb"]?.stringValue,
               verb == "dream" || MindClockVerb(rawValue: verb) != nil {
                call["preview"] = .bool(true)
                // Preview returns before door notes, version reads and change receipts; the owner supplies its actual decision.
                return try await runFolded(action, input: call, surface: surface, turn: turn, execution: execution)
            }
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
            // Preview shares the real call's checks and refuses unavailable execution as door_unavailable.
            var refusal = await foldedRefusal(action, input: call, surface: surface, turn: turn, execution: execution)
            if let refused = refusal {
                refusal = Self.advisedRefusal(Self.foldedResult(ChatToolOutcome.normalizedFailure(refused, tool: action.tool),
                    guide: nil, tool: action.tool), action: action, args: args, root: root)
            }
            guard case .object(let refused)? = refusal, refused["status"] != .string("would") else {
                receipt["would_card"] = .bool(try await doorWouldCard(action, call: call, input: input, surface: surface, turn: turn, execution: execution))
                receipt["detail"] = .string("""
                    Arguments and available preflight checks passed. See checks_not_run; this does not prove the action can run. Nothing was done.
                    """)
                // A lifecycle preview says what the call would leave, in its own words.
                if case .object(let would)? = refusal {
                    receipt.merge(would.filter { !["status", "detail"].contains($0.key) }) { $1 }
                    receipt["detail"] = .string(Self.doorText(would["detail"]) + " Nothing was done.")
                }
                return .object(receipt)
            }
            // A glass-only user card retains its refusal reason.
            let glass = refused["status"] == .string("needs_glass")
            let failureCode = Self.doorText(refused["failure_code"])
            let code = glass ? "needs_glass" : failureCode.isEmpty ? Self.doorText(refused["reason"]) : failureCode
            let why = glass ? Self.doorText(refused["reason"]) : ["detail", "message", "reason"]
                .map { Self.doorText(refused[$0]) }.first { !$0.isEmpty } ?? ""
            receipt["would_refuse"] = .string(code)
            for (key, value) in refused where key.hasPrefix("would_") || ["versions", "tools", "argument_path", "backups", "remedy", "try_instead"].contains(
                key) { receipt[key] = value }
            if glass || Self.doorFloorReasons.contains(code) {
                receipt["owner"] = .string("person")
                receipt["why"] = .string(why)
            }
            receipt["detail"] = .string("Would refuse: \(code). \(why) Nothing was done.")
            return .object(receipt)
        }
        // Folded tools retain their own result, gates and card; ability faces do not change part execution.
        if action.isFold && !action.authored || action.id == "chat.list" {
            let result = Self.foldedResult(try await runFolded(action, input: call, surface: surface, turn: turn, execution: execution),
                guide: receipt["guide"],
                                          browser: action.tool.hasPrefix("browser."), tool: action.tool)
            let folded = Self.actionResult(result, action: action, args: args, root: root)
            // A versioned write says the version it left, as the app's own buttons do.
            guard returnsVersion, case .object(let fields) = folded else { return folded }
            return .object(await attachPageVersion(to: fields, scope: scope, surface: surface, turn: turn, execution: execution))
        }
        // Each script action's after is the next before; reads raise no notes and need no surrounding inbox reads.
        let snapshot = execution.notesSnapshot
        let watch = !read
        let notesBefore = if !watch { [(id: String, title: String)]?.none }
            else if let held = snapshot?.notes { held } else { await doorNotes(turn: turn) }
        let knocksBefore: Result<Set<String>, Error> = watch ? await Self.acceptedKnocks(root: root) : .success([])
        var result = Self.actionResult(action.authored ? try await doorPart(action, call: call, input: input, surface: surface, root: root, turn: turn,
            execution: execution)
            : try await runFolded(action, input: call, surface: surface, turn: turn, execution: execution), action: action, args: args, root: root)
        let surfacesChanged = if case .object(let fields) = result, case .array(let surfaces)? = fields["surfaces_changed"] {
            !surfaces.isEmpty
        } else { false }
        if execution.undoReceipt == nil, ["layout.write", "agent.recipe_write", "setting.set"].contains(action.id),
           case .object(var fields) = result, fields["changed"] == .bool(true) || surfacesChanged, ChatToolOutcome.outputLooksSuccessful(result),
           let session = turn.verifiedSessionID ?? input["__session_id"]?.scalarText, !session.isEmpty {
            fields["action"] = .string(action.id)
            do {
                try await AgentWorkspaceNavigation.shared.rememberUndo(workspace: ChatWorkspaceBinding.operation(turn: turn,
                    invocation: execution.invocation), .object(fields), dataRoot: root, scope: session)
                if fields["undo_unavailable"] == nil || fields["undo_unavailable"] == .null {
                    receipt["undo"] = .object(["action": .string("undo")])
                }
            }
            catch {
                fields["undo_unavailable"] = .string(error.localizedDescription)
                result = .object(fields)
            }
        }
        let notesAfter = watch ? await doorNotes(turn: turn) : nil
        if watch { snapshot?.notes = notesAfter }
        let knocksAfter: Result<Set<String>, Error> = watch ? await Self.acceptedKnocks(root: root) : .success([])
        let reply = ToolResult(Self.advisedRefusal(ChatToolOutcome.normalizedFailure(result, tool: action.tool),
            action: action, args: args, root: root))
        result = reply.payload
        // Preserve the owner's status or result evidence; the door's ok must not replace it.
        receipt["status"] = .string(ChatToolOutcome.statusWord(reply.payload, verdict: reply.outcome))
        if case .object(let fields) = result {
            for key in ["execution", "changed", "effects", "effect", "read_only", "irreversible", "try_instead", "next_call"] {
                receipt[key] = fields[key]
            }
            if case .string(let status)? = fields["status"] { receipt["status"] = .string(status) }
            // User-only refusals and cards remain user-only through both preview and execution.
            if Self.doorFloorReasons.contains(Self.doorText(fields["reason"])) || fields["status"] == .string("needs_glass") {
                receipt["owner"] = .string("person")
            }
        }
        // Receipts name the requested action even when the host uses a different verb.
        let own = action.isCard ? "action" : "verb"
        if case .object(var fields) = result, fields[own] != nil {
            fields[own] = .string(String(action.id.split(separator: ".").last ?? Substring(action.id)))
            receipt["result"] = .object(fields)
        } else {
            receipt["result"] = result
        }
        if case .object(let fields) = result,
           !ChatToolOutcome.outputLooksSuccessful(reply.payload, verdict: reply.outcome)
                || ChatToolOutcome.isWaitingApproval(reply.payload) || reply.isWaitingInteraction {
            let reason = Self.doorText(fields["reason"])
            receipt["message"] = fields["message"]
            let waiting = Self.doorText(fields["not_run_status"])
            // Keep the owner's refusal code, such as owners_screen, rather than replacing it with tool_failed.
            if !reason.isEmpty, !reason.contains(" ") { receipt["reason"] = .string(reason) }
            if !waiting.isEmpty || Self.doorFloorReasons.contains(reason) {
                receipt["effects"] = .string("none")
                receipt["remedy"] = reply.remedy ?? .object([
                    "kind": .string(waiting == "approval_filed" ? "wait" : "none"),
                    "instruction": .string(waiting == "approval_filed"
                        ? "The owner has a card for it; it runs if they approve. Don't retry."
                        : "Nothing ran, and retrying changes nothing. Leave it for the owner."),
                    "next_call": .null,
                ])
            } else {
                receipt["effects"] = fields["effects"] ?? .string(read ? "none" : "unknown")
                receipt["remedy"] = reply.remedy ?? Self.readRecovery(action, read: read)
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
        if returnsVersion { receipt = await attachPageVersion(to: receipt, scope: scope, surface: surface, turn: turn, execution: execution) }
        // Who decided this call: the person when their own act is this exact call, else the agent.
        if watch {
            let decided = PermissionLaw.personDecided(tool: "app", input: ["action": .string(action.id), "args": .object(args)], turn: turn)
            receipt["decided_by"] = .string(decided ? "person" : "agent")
        }
        return .object(receipt)
    }

    /// Effects have already settled. A missing readback cannot turn into a missing field, and must never invite replaying the write.
    @MainActor
    private func attachPageVersion(to receipt: [String: JSONValue], scope: String, surface: String, turn: Turn,
                                   execution: AppActionExecution) async -> [String: JSONValue] {
        var fields = receipt
        do {
            guard let version = try await doorCurrentVersion(scope: scope, surface: surface, turn: turn, execution: execution) else {
                throw ToolFailureError("The page owner returned no current version for \(scope).", effects: .none, code: "page_version_unavailable")
            }
            fields["page_version"] = .string(version)
        } catch {
            fields["readback_failure"] = ChatToolOutcome.failure(error: error, tool: "app", effects: ToolFailureError.Effects.none)
            fields["readback_note"] = .string("""
                The action returned, but its page version could not be read. Read \(scope) to reconcile the result before continuing; do not repeat the \
                action.
                """)
        }
        return fields
    }
    /// The same protocol normalization for runtime and read-only inspection.
    static func normalizedCallArguments(_ action: AppAction, _ given: [String: JSONValue], schema: JSONValue?,
        recordShims: Bool = true) -> [String: JSONValue] {
        normalizedBoundArguments(action, AppActions.boundArguments(action, given, schema: schema).args, schema: schema, recordShims: recordShims)
    }

    static func retainsRawArgumentValues(_ action: AppAction) -> Bool {
        action.id == "desk.close" || MacContactsExecutor.parameters(for: action.tool) != nil
    }

    /// Coerce known values only after the complete argument map has been bound, including unknown expressions during source inspection.
    static func normalizedBoundArguments(_ action: AppAction, _ given: [String: JSONValue], schema: JSONValue?,
        recordShims: Bool = true) -> [String: JSONValue] {
        if retainsRawArgumentValues(action) { return given }
        guard let schema else { return given }
        func normalize(_ given: [String: JSONValue], shims: Bool) -> [String: JSONValue] {
            var normalized = ToolArguments.normalized(given, schema: schema,
                preserving: ["ability.save", "sense.make"].contains(action.id) ? ["learned", "choices"] : [], recordShims: shims)
            if action.id == "ability.save" {
                // Null clears params; malformed headers must reach their owner.
                for key in ["params", "reach", "face"] { normalized[key] = given[key] }
            }
            if action.id == "queue.update" {
                // Omission keeps a field; explicit null clears it.
                for key in ["action", "say", "until", "when"] { normalized[key] = given[key] }
            }
            // Desk clear/set admission judges the caller's string, not a coerced number. Keep the same raw value for door validation and re-entry.
            if action.id == "desk.blocked_on" { normalized["blocked_on"] = given["blocked_on"] }
            if action.id == "desk.defer" { normalized["until"] = given["until"] }
            // This door asks for macOS grants, so a bare grant name is that grant's card target; a bare name on card.request means a Trust category.
            if action.id == "permissions.request", let raw = normalized["capability"]?.stringValue,
               let target = SystemPermissionPreflight.grantTarget(raw) { normalized["capability"] = .string(target) }
            if action.id == "permissions.request", case .array(let extra)? = normalized["also_needed"] {
                normalized["also_needed"] = .array(extra.map { $0.stringValue.flatMap(SystemPermissionPreflight.grantTarget).map(JSONValue.string) ?? $0 })
            }
            return normalized
        }
        return normalize(given, shims: recordShims)
    }

    /// Setting request evidence has its own refusal and applies only to model turns.
    static func doorValidationArgs(_ action: AppAction, _ args: [String: JSONValue]) -> [String: JSONValue] {
        action.id == "setting.set" ? args.merging(["because": .string("")]) { _, check in check } : args
    }
    private static func readRecovery(_ action: AppAction, read: Bool = true) -> JSONValue {
        .object(["kind": .string("inspect"), "owner": .string(action.id),
            "instruction": .string(read
                ? "Read \(action.id)'s argument schema with next_call to choose a supported read and address the reported cause. This read changed nothing."
                : """
                    Read \(action.id)'s current requirements and correct the reported cause before another call. Check what took effect before repeating a \
                    change.
                    """),
            "next_call": .object(["tool": .string("app"), "input": .object(["find": .string(action.id)])])])
    }
    /// The registry's read contract supplies the evidence missing from a generic failure envelope. Preserve an explicitly uncertain mutation.
    private static func actionResult(_ result: JSONValue, action: AppAction, args: [String: JSONValue], root: URL = PersistenceCore.defaultDataRoot(
        )) -> JSONValue {
        let result = advisedRefusal(result, action: action, args: args, root: root)
        let reply = ToolResult(result)
        var fields: [String: JSONValue] = if case .object(let fields) = reply.payload { fields } else { ["result": reply.payload] }
        // Authoring receipts carry the next step; keeping a part carries its run call.
        if action.id == "ability.enable", fields["next_call"] == nil, ChatToolOutcome.outputLooksSuccessful(reply.payload, verdict: reply.outcome),
           !ChatToolOutcome.isWaitingApproval(reply.payload), !reply.isWaitingInteraction, let run = fields["run"]?.scalarText {
            fields["next_call"] = .object(["tool": .string("app"), "input": .object(["action": .string(run), "args": .object([:])])])
        }
        fields.merge(action.effectFields(args: args, result: fields)) { _, value in value }
        let status = doorText(fields["status"])
        if fields["execution"] == nil {
            fields["execution"] = .string(fields["not_run_status"] != nil || status == "not_run" || ChatToolOutcome.neverRan(result)
                || status == "refused" && fields["effects"] == .string("none")
                || ChatToolOutcome.isWaitingApproval(reply.payload) || reply.isWaitingInteraction ? "not_run"
                : reply.outcome == .succeeded ? "executed" : "attempted")
        }
        if fields["execution"] == .string("not_run") {
            fields["effect"] = .string("none")
        }
        if action.id == "agent.read", fields["execution"] == .string("executed") {
            fields["effect"] = .string("none")
            fields["effects"] = .string("none")
            return .object(fields)
        }
        guard action.readOnly(args: args), !ChatToolOutcome.outputLooksSuccessful(reply.payload, verdict: reply.outcome),
              !ChatToolOutcome.isWaitingApproval(reply.payload), !reply.isWaitingInteraction, reply.outcome != .cancelled,
              !InlineInteractionNeed.isWaiting(result),
              fields["effects_unknown"] != .bool(true),
              fields["effects"] == nil || fields["effects"] == .string("unknown") || fields["effects"] == .string("none") else { return .object(fields) }
        fields["effects"] = .string("none")
        fields["outcome"] = .string("unmet")
        if fields["remedy"] == nil || fields["remedy"] == .null { fields["remedy"] = readRecovery(action) }
        return .object(fields)
    }
    /// Owner refusals, previews and folded/native returns carry the same advice as door admission. Never replace an owner's recovery or replay a call.
    private static func advisedRefusal(_ result: JSONValue, action: AppAction, args: [String: JSONValue], root: URL) -> JSONValue {
        let reply = ToolResult(result)
        guard !ChatToolOutcome.outputLooksSuccessful(reply.payload, verdict: reply.outcome),
              case .object(var fields) = reply.payload else { return result }
        if let advice = reply.remedy?.objectValue?["try_instead"] { fields["try_instead"] = advice }
        let ownedNext = reply.remedy?.objectValue?["next_call"]
        if fields["try_instead"] == nil, let call = ownedNext?.objectValue, call["tool"] == .string("app"),
           let input = call["input"]?.objectValue, input["action"] == .string(action.id) {
            fields["try_instead"] = .object(input)
        }
        let code = doorText(fields["failure_code"] ?? fields["reason"])
        if fields["try_instead"] == nil,
           fields["argument_path"]?.stringValue != nil || reply.remedy?.objectValue?["kind"] == .string("correct_arguments")
                || ["unknown_arg", "bad_input", "invalid_args", "invalid_arguments", "invalid_input"].contains(code) {
            do {
                let contract = try AppActions.discovery(action, dataRoot: root).objectValue ?? [:]
                fields["try_instead"] = AppActions.callAdvice(action, input: ["args": .object(args)], discovery: contract, requiresChange: true)
            } catch {
                fields["schema_failure"] = ChatToolOutcome.failure(error: error, tool: "app", effects: ToolFailureError.Effects.none)
            }
        }
        if fields["next_call"] == nil {
            if let ownedNext { fields["next_call"] = ownedNext }
            else if let advice = fields["try_instead"], let call = AppActions.advisedCall(advice) {
                fields["next_call"] = .object(["tool": .string("app"), "input": .object(call)])
            }
        }
        return .object(fields)
    }
    /// Folded result guidance uses door action ids and argument names; non-user failures point to the guide. Nested data remains untouched.
    static func foldedResult(_ result: JSONValue, guide: JSONValue?, browser: Bool = false, tool: String = "") -> JSONValue {
        // Browser guidance names tools internally; door results must translate those steps to app calls.
        if browser, case .string(let page) = result { return .string(browserSteps(page)) }
        let reply = ToolResult(result)
        guard case .object(var fields) = ToolNameAliases.appCallPointers(result) else { return result }
        if browser, case .string(let page)? = fields["page"] { fields["page"] = .string(browserSteps(page)) }
        if browser, case .string(let note)? = fields["readback_note"] { fields["readback_note"] = .string(browserSteps(note)) }
        if case .object(let next)? = fields["next"] { fields["next"] = .object(ToolNameAliases.doorArgs(tool, next)) }
        // Translate only top-level guidance; nested strings may be user or domain data.
        for key in ToolNameAliases.foldedProseKeys {
            if case .string(let text)? = fields[key], text.contains(" ") {
                fields[key] = .string(ToolNameAliases.foldedProse(text))
            }
        }
        if let guide, !ChatToolOutcome.outputLooksSuccessful(reply.payload, verdict: reply.outcome),
           !ChatToolOutcome.isWaitingApproval(reply.payload), !reply.isWaitingInteraction,
           !doorFloorReasons.contains(doorText(fields["reason"])) {
            fields["guide"] = guide
        }
        return .object(fields)
    }
    private static let browserTools = ToolNameAliases.foldedTools.filter { $0.key.hasPrefix("browser.") }
        .sorted { $0.key.count > $1.key.count }
    static func browserSteps(_ text: String) -> String {
        browserTools.reduce(text) { $0.replacingOccurrences(of: $1.key, with: "app " + $1.value) }
    }
    /// One happening counts once, however many of its doors accepted it.
    private static func acceptedKnocks(root: URL) async -> Result<Set<String>, Error> {
        do {
            return .success(Set(try await ForPerson.at(root).matters().filter { matter in
                matter.owes.contains { $0.key.hasPrefix("deliver:") && $0.value.phase == .accepted }
            }.map(\.id)))
        } catch { return .failure(error) }
    }

    /// Unknown readings stay unknown in the call's side effects.
    private static func knocksDelivered(before: Result<Set<String>, any Error>,
                                        after: Result<Set<String>, any Error>) -> JSONValue {
        switch (before, after) {
        case (.success(let before), .success(let after)):
            return .int(Int64(after.subtracting(before).count))
        case (.failure(let error), _), (_, .failure(let error)):
            return ownedFailure(error, code: "attention_reading_unavailable", owner: "experiences",
                instruction: "Repair the reading of what is for the person before deciding whether another notification is needed.",
                next: ["page": .string("inbox")], effects: .unknown)
        }
    }
    /// Include archived note ids so only newly raised notes count; an unreadable inbox stays explicit in the receipt.
    @MainActor
    private func doorNotes(turn: Turn) async -> [(id: String, title: String)]? {
        guard let host = quietHost(),
              case .object(let list) = await host.inbox(verb: "list", input: [
                "filter": .string("all"), "limit": .int(200),
              ], turn: turn), case .array(let notes)? = list["notes"] else { return nil }
        return notes.compactMap { note in
            guard case .object(let row) = note, case .string(let id)? = row["id"] else { return nil }
            return (id, Self.doorText(row["title"]))
        }
    }
}
