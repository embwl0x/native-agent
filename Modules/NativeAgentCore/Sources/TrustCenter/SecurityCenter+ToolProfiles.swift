import AuthoredCapabilities
import Foundation
import NativeAgentCore
import PersistenceCore
import ToolRegistry

/// Primitive effects retain the authored envelope and the turn's ordinary gates.
public enum AuthoredToolEffects {
    @TaskLocal public static var admissionOnly = false
    @TaskLocal public static var call: (tool: String, perform: @Sendable () async throws -> JSONValue)?

    /// A watching part's hands on the window it watches (MacScreenWatch): act's effects.
    public static let handOperations: Set<String> = ["hand.click", "hand.double_click", "hand.right_click", "hand.move",
                                                     "hand.drag", "hand.key", "hand.hold", "hand.down", "hand.up"]
    public static let primitiveCapabilities: [String: Set<String>] = [
        "network.receive": ["safe_read", "network_read"],
        "network.connect": ["network_write"], "network.listen": ["network_write"],
        "network.accept": ["network_write"], "network.close": ["network_write"],
        "network.send": ["network_write", "external_send"],
        "apps.call": ["applescript", "system_control"],
        "screen.watch": ["safe_read"], "screen.next": ["safe_read"], "frame.read": ["safe_read"],
    ].merging(handOperations.map { ($0, ["mac_control", "ax_injection"]) }) { $1 }

    public static func appReadOnly(_ args: [String: JSONValue]) -> Bool {
        args["script"] == nil && (args["dictionary"] == .bool(true) || args["event_class"] == .string("core")
            && [.string("getd"), .string("cnte"), .string("doex")].contains(args["event_id"] ?? .null))
    }

    public static func primitiveEffect(_ operation: String, arguments: JSONValue?) -> (tool: String, capabilities: Set<String>) {
        let args: [String: JSONValue] = if case .object(let fields)? = arguments { fields } else { [:] }
        if operation == "apps.call", case .object(let args)? = arguments, appReadOnly(args) {
            return (operation, ["safe_read", "applescript"])
        }
        if operation == "fetch" || operation.hasPrefix("fetch.") {
            let read = args["method"] == nil || arguments?.stringFields["method"]?.uppercased() == "GET"
            let connector = operation == "fetch" ? arguments?.stringFields["connector"]
                : operation == "fetch.keyless" ? nil : String(operation.dropFirst("fetch.".count))
            let capability = connector.map { "connector_\(read ? "read" : "write"):\($0)" } ?? "network_public"
            return ("fetch." + (connector ?? "keyless"), read
                ? [capability, "safe_read", "network_read"] : [capability, "network_write", "external_send"])
        }
        return (operation, primitiveCapabilities[operation] ?? ["destructive"])
    }
}

/// Read-only projection of SecurityCenter's canonical tool profile risk.
/// Consumers may use this metadata for advisory behavior, but it grants no
/// authority and does not replace effect-time SecurityCenter evaluation.
public enum CanonicalToolRisk: String, Sendable, Codable, Equatable {
    case low
    case medium
    case high
    case critical
}

extension SwiftNativeSecurityCenter {
    static let catalogToolNames: Set<String> = ["tool_result_page"]
    // notificationToolNames are the carve-out for one-shot ping/notify
    // tools — they get the "notification" capability tag in `profile`
    // which exempts them from the external_send approval gate (a literal
    // notify-banner doesn't reach a third party). claude_message/codex_message
    // are in here because they're agent-to-agent bridge pings backed by local
    // inbox writes; codex_message may also post a local NativeAgent Mac
    // notification, still with no third-party send. (2026-06-08/15)
    static let notificationToolNames: Set<String> = [
        // 2026-09-07: bots tools only read/write local definitions, shelf receipts,
        // reader acknowledgements, or enqueue requests. bot_ask also uses the
        // runner's provider admission/spend gates; none sends or notifies.
        "bot_create", "bot_update", "bot_pause", "bot_run_once", "bot_list", "shelf_read", "shelf_entry", "bot_ask", "bot_delete",
        "mac.notify",
        "mobile.notify",
        "phone_request",
        "claude_message",
        "codex_message",
        "omp_message",
    ]
    // Local agent bridge handoffs are meant to carry task specifications to
    // another local agent. Those specs often contain instruction-looking text
    // ("do not edit X", "system prompt", "Personal Access Token") that should
    // still be audited/redacted, but not converted into an unserviceable
    // approval ask when the origin is already local or trusted.
    static let localAgentBridgeToolNames: Set<String> = [
        "claude_message",
        "codex_message",
        "omp_message",
        "invoke_codex",
    ]
    static let approvalStagingToolNames: Set<String> = [
        "agentmail.send",
        "agentmail_send",
        "slack.post_message",
        "slack_post_message",
    ]
    static let slackReadToolNames: Set<String> = [
        "slack.status",
        "slack.list_channels",
        "slack.search_messages",
        "slack.list_unreads",
        "slack_status",
        "slack_list_channels",
        "slack_search_messages",
    ]

    struct ToolProfile: Sendable {
        var capabilities: Set<String>
        var risk: SecurityRisk
    }

    public static func sendsExternally(tool: String, input: [String: JSONValue], dataRoot: URL) -> Bool {
        if tool == "interaction_act", input["target"] == .string("composer"), input["verb"] == .string("send") { return true }
        if notificationToolNames.contains(tool), !localAgentBridgeToolNames.contains(tool), tool != "bot_ask" { return false }
        return profile(tool: policyToolName(tool), input: input, dataRoot: dataRoot).capabilities.contains("external_send")
    }

    /// Classify a tool through the same profile owner used by authorization.
    /// This is deliberately pure: it does not read policy, assess origins,
    /// record receipts, or imply that the tool is allowed to run.
    public static func canonicalToolRisk(
        tool: String,
        input: [String: JSONValue],
        dataRoot: URL,
        trustedWorkspaceRoots: [URL] = []
    ) -> CanonicalToolRisk {
        let risk = profile(
            tool: policyToolName(tool),
            input: input,
            dataRoot: dataRoot,
            trustedWorkspaceRoots: trustedWorkspaceRoots
        ).risk
        switch risk {
        case .low: return .low
        case .medium: return .medium
        case .high: return .high
        case .critical: return .critical
        }
    }

    /// Domain capabilities not expressed by an action's read/owner flags.
    static let appActionCapabilities: [String: (capability: String, risk: SecurityRisk)] = [
        // Deny on her own Desk task's waiting step, as workshop_reject.
        "desk.deny": ("workshop_write", .low),
        // Her own memory store, through MemoryCuration.
        "memory.rewrite": ("memory_write", .low),
        "memory.pin": ("memory_write", .low),
        // A recipe says what this app writes and runs to reach an agent: connect's card below Full Mac.
        "agent.recipe_write": ("other_app_settings_write", .low),
        // The app's own layout (ui/layout.json): setting.set's tier. It writes
        // no other app's settings, so it files no card below Full Mac.
        "layout.write": ("app_data_write", .medium),
    ]

    static func profile(
        tool: String,
        input: [String: JSONValue],
        dataRoot: URL,
        trustedWorkspaceRoots: [URL] = []
    ) -> ToolProfile {
        if AuthoredToolEffects.primitiveCapabilities[tool] != nil || tool.hasPrefix("fetch.") {
            let effects = AuthoredToolEffects.primitiveEffect(tool, arguments: .object(input)).capabilities
            return ToolProfile(capabilities: effects.union(["tool_call"]), risk:
                effects.contains("destructive") || effects.contains("system_control") ? .critical
                    : effects.contains("safe_read") ? .low
                        : effects.contains("network_write") || effects.contains("external_send") ? .high : .medium)
        }
        // These mutate the same app-owned jobs as create. In particular,
        // delete is cancellation, not a filesystem-delete capability.
        if ["scheduler_cancel_job", "scheduler_delete_job", "scheduler_pause_job",
            "scheduler_resume_job", "scheduler_update_job"].contains(tool) {
            return profile(tool: "scheduler_create_job", input: input,
                           dataRoot: dataRoot, trustedWorkspaceRoots: trustedWorkspaceRoots)
        }
        var capabilities: Set<String> = ["tool_call"]
        var risk = SecurityRisk.low
        func add(_ capability: String, _ newRisk: SecurityRisk) {
            capabilities.insert(capability)
            risk = max(risk, newRisk)
        }
        if ["maps_route", "maps_search"].contains(tool) {
            add("network_read", .low)
            add("safe_read", .low)
            return ToolProfile(capabilities: capabilities, risk: risk)
        }

        // Local conversation facade calls are translated before this gate;
        // an untranslated message targets a remote peer and keeps send authority.
        if tool == "agent_contacts" {
            add("safe_read", .low)
            return ToolProfile(capabilities: capabilities, risk: risk)
        }
        if tool == "agent_read" {
            add("network_read", .medium)
            return ToolProfile(capabilities: capabilities, risk: risk)
        }
        // Stops a reply she started: tells the contact to stop, or interrupts
        // the run this app itself launched. It never sends her words anywhere.
        if tool == "agent_cancel" {
            add("network_write", .medium)
            return ToolProfile(capabilities: capabilities, risk: risk)
        }
        if tool == "agent_connect" {
            add("app_data_write", .medium)
            add("credential_write", .high)
            // Connect-by-name (and its disconnect) edits ANOTHER app's settings
            // file. Say so, so the person's posture decides: first driven in Work
            // mode it wrote the entry with no card, because nothing it declared
            // described a write outside this app.
            func given(_ key: String) -> Bool {
                guard let value = input[key] else { return false }
                return value != .string("")
            }
            if !given("endpoint"), !given("app_bundle_id") {
                add("other_app_settings_write", .high)
            }
            // Connect-by-name may prove itself by running that agent's own
            // command line once. It needs no extra capability here: connect is
            // already confirm-tier, and the one card it files says the run is
            // part of the setup before anything happens.
            return ToolProfile(capabilities: capabilities, risk: risk)
        }
        if tool == "agent_message" {
            if input["dry_run"] == .bool(true) {
                // A dry run sends nothing: the card or handshake it reads and
                // the recipe it learns. A command-line host still runs below.
                add("network_read", .medium)
                add("app_data_write", .medium)
            } else {
                add("external_send", .high)
                add("network_write", .high)
            }
            // A message to an agent host is delivered by running its command
            // line, so it carries exactly the capabilities `shell` carries. No
            // new authority and no quieter door: the same posture decides.
            if messagesAnAgentHostByCommand(input["agent"], dataRoot: dataRoot) {
                add("shell", .critical)
                add("process_spawn", .critical)
            }
            return ToolProfile(capabilities: capabilities, risk: risk)
        }
        if tool == "mail_mark_read" || tool == "mail_triage_batch" {
            add("app_data_write", .medium)
            return ToolProfile(capabilities: capabilities, risk: risk)
        }
        if catalogToolNames.contains(tool) {
            add("catalog_read", .low)
            return ToolProfile(capabilities: capabilities, risk: risk)
        }
        if notificationToolNames.contains(tool) {
            add("notification", .medium)
            add("external_send", .medium)
        }
        if ["bot_create", "bot_update", "bot_pause", "bot_run_once", "bot_list", "shelf_read", "shelf_entry", "bot_ask", "bot_delete"].contains(tool) {
            // Local app-data IO uses the notification-tier carve-out above.
            // Do not classify "create" as an arbitrary filesystem mutation.
            add(tool == "bot_list" ? "safe_read" : "app_data_write", .medium)
            return ToolProfile(capabilities: capabilities, risk: risk)
        }
        if tool == "agentmail_list" || tool == "agentmail_read" || tool == "agentmail.list_inbox" || tool == "agentmail.read" || tool == "agentmail.search" {
            add("safe_read", .low)
            return ToolProfile(capabilities: capabilities, risk: risk)
        }
        if tool == "image_generate" {
            add("network_write", .medium)
            add("app_data_write", .medium)
            add("image_generation", .medium)
            return ToolProfile(capabilities: capabilities, risk: risk)
        }
        if slackReadToolNames.contains(tool) {
            add("safe_read", .low)
            return ToolProfile(capabilities: capabilities, risk: risk)
        }
        if approvalStagingToolNames.contains(tool) {
            add("approval_stage", .high)
            add("external_send", .high)
            return ToolProfile(capabilities: capabilities, risk: risk)
        }
        let xReadOnlyConnectorTools: Set<String> = [
            "x.status",
            "x.me",
            "x.search_recent",
            "x.timeline_home",
            "x.user_tweets",
            "x.timeline_home_v1",
            "x.user_tweets_v1",
        ]
        if xReadOnlyConnectorTools.contains(tool) {
            add("safe_read", .low)
            return ToolProfile(capabilities: capabilities, risk: risk)
        }
        let browserReadTools: Set<String> = [
            "browser.chrome_status",
            "browser.status",
            "browser.read_text",
            "browser.read_links",
            "browser.screenshot",
            "browser.chrome_snapshot",
            "browser.chrome_wait",
            "browser.chrome_scroll",
            "browser.chrome_media",
            "browser.chrome_reload_extension",
        ]
        if browserReadTools.contains(tool) {
            add("safe_read", .low)
            return ToolProfile(capabilities: capabilities, risk: risk)
        }
        // The app door: NativeAgent's OWN pages — no user file, no process, no
        // other app. A page read, the index, find and a preview change
        // nothing. The registry identifies reads; domain writes keep their
        // own capability. A script is app_data_write, each of its actions judged
        // again as its own app call. Every action and read runs in process,
        // so this is their one judgment. A card that moves authority — a
        // permission grant, a Mac Control category, a Trust flag, a provider
        // key, a connector token — stands behind a second, checked Full Mac
        // read taken immediately before the write (AppToolExecutor+InteractionAct).
        if tool == "app" {
            let appAction = AppActionBinding.action(input: input)
            let action = string(input["action"])?.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() ?? ""
            let named = ["action", "script"].contains { key in
                if case .string(let text)? = input[key] { !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
                else if key == "script", case .array(let calls)? = input[key] { !calls.isEmpty }
                else { false }
            }
            let acts = named && input["preview"] != .bool(true)
            // A folded tool's action only passes the call on: it re-enters
            // under the tool's own name and is judged there, card and all.
            if acts, appAction?.read == true || appAction?.folded == true {
                add("safe_read", .low)
            } else if acts, let mapped = appActionCapabilities[action] {
                add(mapped.capability, mapped.risk)
            } else {
                add(acts ? "app_data_write" : "safe_read", acts ? .medium : .low)
            }
            return ToolProfile(capabilities: capabilities, risk: risk)
        }
        // fable51 item 30 — THE CLIPBOARD ORGAN. Both EARLY-RETURN so neither
        // falls through to the keyword classifier below ("write" would tag the
        // write half `filesystem_write`, which is a lie: it touches no file).
        //
        // The read is a `safe_read`: it changes nothing, and the text it hands
        // back has already been through the shape redactor.
        //
        // The write gets its own `clipboard_write` capability at MEDIUM rather
        // than being folded into an existing tag. It is not a filesystem write
        // and not input injection; what it IS is a change to shared machine
        // state that every app can read, and it deserves a name that says so.
        if tool == "clipboard_read" || tool == "mac.clipboard_read" {
            add("safe_read", .low)
            return ToolProfile(capabilities: capabilities, risk: risk)
        }
        if tool == "clipboard_write" || tool == "mac.clipboard_write" {
            add("clipboard_write", .medium)
            return ToolProfile(capabilities: capabilities, risk: risk)
        }
        // fable51 item 29 — THE MENU BAR ORGAN. Both EARLY-RETURN so neither
        // reaches the keyword classifier ("press" trips nothing today, but a
        // menu path like "File › Delete" must never be classified from its
        // ARGUMENTS, and the walk must never be mistaken for an act).
        //
        // The walk is a `safe_read`: one bounded descent, no CGEvent, no AX
        // action, and it does not even open a menu.
        //
        // The press carries the same `ax_injection` shape as the other
        // accessibility acts, at HIGH: it runs the app's own handler, and the
        // handler behind "File › Quit" or "Edit › Delete" is not medium.
        if tool == "menu" || tool == "mac.menu" {
            add("safe_read", .low)
            return ToolProfile(capabilities: capabilities, risk: risk)
        }
        // fable51 item 33 — THE READ ORGAN. An EARLY RETURN so it never reaches
        // the keyword classifier, which would tag it from the word "read" alone
        // and land it in whatever bucket that heuristic happens to pick.
        //
        // `safe_read` at LOW, beside `browser.chrome_scroll` — which is the
        // exact precedent: a scroll whose only purpose is to bring more of a
        // document into view, graded on what it can do rather than on the fact
        // that it emits something. This organ presses nothing, types nothing
        // and activates nothing; it moves a viewport and scrolls it back. Its
        // text has already been through the shape redactor before it returns.
        //
        // The one authority it can reach beyond a read — opening a file the
        // caller NAMES — is gated separately at dispatch on Full Mac file
        // access, not here.
        if tool == "read" || tool == "mac.read" {
            add("safe_read", .low)
            return ToolProfile(capabilities: capabilities, risk: risk)
        }
        if tool == "menu_press" || tool == "mac.menu_press" {
            add("ax_injection", .high)
            return ToolProfile(capabilities: capabilities, risk: risk)
        }
        if tool == "browser.chrome_setup" {
            add("outside_app_data_write", .high)
            add("ax_injection", .high)
            return ToolProfile(capabilities: capabilities, risk: risk)
        }
        if tool == "browser.open_url" || tool == "browser.navigate" {
            add("network_read", .medium)
            return ToolProfile(capabilities: capabilities, risk: risk)
        }
        if tool == "browser.chrome_close_tab" {
            // The extension checks current NativeAgent group membership.
            add("app_data_write", .medium)
            return ToolProfile(capabilities: capabilities, risk: risk)
        }
        if tool == "browser.chrome_navigate" {
            add("network_read", .medium)
            return ToolProfile(capabilities: capabilities, risk: risk)
        }
        if tool == "browser.chrome_click"
            || tool == "browser.chrome_fill"
            || tool == "browser.chrome_type"
            || tool == "browser.chrome_select"
            || tool == "browser.chrome_keypress"
            || tool == "browser.chrome_set_checked"
            || tool == "browser.chrome_double_click" {
            add("browser_interaction", .high)
            return ToolProfile(capabilities: capabilities, risk: risk)
        }

        if tool == "act" || tool == "go" {
            add("mac_control", .high)
            if tool == "act" { add("ax_injection", .high) }
            return ToolProfile(capabilities: capabilities, risk: risk)
        }

        if ["trash_file", "move_file", "copy_file"].contains(tool) {
            add("filesystem_write", .medium)
            if capabilityWritesOutsideAppData(input: input, dataRoot: dataRoot, trustedWorkspaceRoots: trustedWorkspaceRoots) {
                add("outside_app_data_write", .high)
            }
            return ToolProfile(capabilities: capabilities, risk: risk)
        }
        if AppActionBinding.authorableToolName(tool),
           let file = try? AbilityStore(dataRoot: dataRoot).read(id: tool), file.kind == .tool {
            // Running the sandbox has no effect; its host calls carry the actual capabilities.
            add("safe_read", .low)
            return ToolProfile(capabilities: capabilities, risk: risk)
        }
        let lower = tool.lowercased()
        // gpt-5.5 review fix (2026-06-08): explicit branch for builder
        // Process-spawn tools. The keyword classifier below catches
        // `shell`/`exec` but misses `bash`, `git`, the SwiftPM
        // builders, and undersells `apply_patch`. Register the precise
        // capabilities BEFORE the keyword classifier so the policy preview
        // surface gets the right risk shape.
        let builderProcessTools: Set<String> = [
            "shell", "bash", "git", "apply_patch",
            "swift_build", "swift_test",
        ]
        if builderProcessTools.contains(tool) {
            add("shell", .critical)
            add("process_spawn", .critical)
            // A shell is broad by design, but mutating macOS's permission
            // authority is not ordinary builder work. Classify the concrete
            // effect from the command body so SecurityCenter can hard-block it
            // without producing a contradictory approval prompt while Full
            // Mac/YOLO remains available for normal builds and repairs.
            if tool == "apply_patch" || tool == "git" || tool == "swift_build" || tool == "swift_test" {
                add("filesystem_write", .high)
            }
            if tool == "swift_test" {
                // Tests are allowed to mutate the workspace (build
                // artifacts, snapshot files, etc.).
                add("destructive", .high)
            }
        }
        if tool == "invoke_codex" {
            add("process_spawn", .high)
            add("agent_delegate", .high)
        }
        // commit_memory (2026-06-11): persona-internal long-term memory write.
        // Explicit low-risk memory_write tag — it writes only to Agent's own
        // MemoryV2 store, no Mac filesystem mutation and no process spawn, so
        // it must NOT inherit the medium filesystem_write tag the "write"
        // keyword would otherwise imply (the word "commit" dodges that catcher,
        // but pin the shape explicitly for the policy preview).
        if tool == "commit_memory" {
            add("memory_write", .low)
            return ToolProfile(capabilities: capabilities, risk: risk)
        }
        // The moments lane. Same store, same shape as commit_memory: no Mac
        // filesystem mutation, no process spawn, no third-party effect. The
        // read half is a plain local read. Early-return so neither falls
        // through to the keyword classifier.
        if tool == "memory_moments_pending" {
            add("safe_read", .low)
            return ToolProfile(capabilities: capabilities, risk: risk)
        }
        if tool == "memory_moment_review" {
            add("memory_write", .low)
            return ToolProfile(capabilities: capabilities, risk: risk)
        }
        // One already-persisted transcript row, read back verbatim. Same shape
        // as the search that hands out its id (Agent, 2026-09-06).
        // workspace admits only preparation here. Its canonical facade sends
        // each actual read/message through this same gate under its own name.
        if tool == "workspace" || tool == "read_chat_message" || tool == "work_context" || tool == "artifact_find" {
            add("safe_read", .low)
            return ToolProfile(capabilities: capabilities, risk: risk)
        }
        if tool == "forget_memory" || tool == "rebuild_knowledge_graph" {
            add("memory_write", .low)
            return ToolProfile(capabilities: capabilities, risk: risk)
        }
        if tool == "save_skill" {
            add("skill_write", .low)
            return ToolProfile(capabilities: capabilities, risk: risk)
        }
        // workshop_submit (2026-06-11, U5 W-I): medium-risk execution queue write.
        // A thin shim into SwiftNativeWorkshopRunner.submit — no Mac filesystem
        // mutation, no process spawn. The executor's own missionPolicy gate,
        // slot cap, and per-step approval gates apply downstream; this profile
        // pins the tool-layer shape (the word "submit" trips no keyword
        // catcher). workshop_status is a pure read.
        if tool == "workshop_submit" {
            add("workshop_write", .medium)
            return ToolProfile(capabilities: capabilities, risk: risk)
        }
        if tool == "workshop_status" {
            add("safe_read", .low)
            return ToolProfile(capabilities: capabilities, risk: risk)
        }
        // task_ledger_post (2026-06-11, U6): medium-risk cross-agent task ledger
        // WRITE. Appends one event to <dataRoot>/orchestration/task_ledger.jsonl
        // under the shared flock — no Mac filesystem mutation, no process spawn.
        // The dedicated `ledger_write` tag pins the tool-layer shape (the word
        // "post" trips no keyword catcher). task_ledger_list is a pure read.
        if tool == "task_ledger_post" {
            add("ledger_write", .medium)
            return ToolProfile(capabilities: capabilities, risk: risk)
        }
        if tool == "task_ledger_list" {
            add("safe_read", .low)
            return ToolProfile(capabilities: capabilities, risk: risk)
        }
        // delegation_status (2026-08-11, W2): pure read of the on-disk wake-job
        // records. Explicitly NOT notification-tier — nothing leaves the
        // machine, so the external_send carve-out must not apply to it.
        if tool == "delegation_status" {
            add("safe_read", .low)
            return ToolProfile(capabilities: capabilities, risk: risk)
        }
        // agent-desk (agent-desk): desk_read is a pure read; the nine desk
        // mutations are medium ledger-class WRITES (append one op to
        // <dataRoot>/desk/ under the shared flock — no Mac filesystem mutation,
        // no process spawn). Same `ledger_write` tag + medium risk as
        // task_ledger_post. Early-return so they don't fall through to the
        // keyword classifier ("status"/"close"/"archive" would otherwise
        // mis-tag).
        if tool == "desk_read" {
            add("safe_read", .low)
            return ToolProfile(capabilities: capabilities, risk: risk)
        }
        // Exact set of the desk MUTATIONS (NOT a `desk_` prefix) so a future
        // desk_* read/admin tool can't silently inherit the write profile
        // before it's explicitly classified (gpt-5.5 breadth review). Mirror of
        // the names registered in SwiftToolDispatcher+DeskTools.swift.
        let deskWriteTools: Set<String> = [
            "desk_add_item", "desk_set_status", "desk_update_item", "desk_note",
            "desk_add_ref", "desk_set_cadence", "desk_set_notify", "desk_close", "desk_archive",
            "desk_blocked_on", "desk_defer", "desk_breakdown",
            "desk_nag_control",
            // Both are desk WRITES and belong here for the same reason as
            // their siblings: desk_open_pursuit appends an origin=agent
            // pursuit row, desk_work_log appends a work-log entry.
            "desk_open_pursuit", "desk_work_log",
        ]
        if deskWriteTools.contains(tool) {
            add("ledger_write", .medium)
            return ToolProfile(capabilities: capabilities, risk: risk)
        }
        // studio (desk 903): the same shape as the desk lane. The two writes
        // append/write one local record under <dataRoot>/studio/ and reach
        // nothing outside it; the two reads touch only those same files. Exact
        // sets rather than a `studio_` prefix, so a later studio tool cannot
        // inherit either profile before it has been classified on its own.
        if tool == "dream_diary_read" {
            add("safe_read", .low)
            return ToolProfile(capabilities: capabilities, risk: risk)
        }
        if tool == "studio_consult_read" || tool == "studio_recall" || tool == "studio_shelf_read" {
            add("safe_read", .low)
            return ToolProfile(capabilities: capabilities, risk: risk)
        }
        if tool == "studio_consult" || tool == "studio_journal"
            || tool == "studio_journal_amend" || tool == "studio_shelf_set" {
            add("ledger_write", .medium)
            return ToolProfile(capabilities: capabilities, risk: risk)
        }
        if tool == "remote_node_list" {
            add("safe_read", .low)
            return ToolProfile(capabilities: capabilities, risk: risk)
        }
        if tool == "remote_node_execute" {
            add("process_spawn", .critical)
            add("remote_effect", .critical)
            add("filesystem_write", .high)
            return ToolProfile(capabilities: capabilities, risk: risk)
        }
        // restart_app (2026-06-10): spawns a detached relauncher process AND
        // terminates the running app — both axes are critical. No keyword
        // catcher below covers "restart"; classify explicitly so the policy
        // preview shows the real risk shape.
        if tool == "restart_app" || tool == "install_app" {
            add("process_spawn", .critical)
            add("system_control", .critical)
            if tool == "install_app" {
                add("filesystem_write", .critical)
                add("destructive", .critical)
            }
        }
        if lower.contains("shell") || lower.contains("terminal") || lower.contains("exec") {
            add("shell", .critical)
        }
        if lower.contains("delete") || lower.contains("trash") || lower.contains("remove")
            || lower.contains("wipe") || lower.contains("erase") || lower.contains(".rm")
            || lower.hasPrefix("rm_") || lower.contains("quarantine") {
            add("filesystem_delete", .critical)
            add("destructive", .critical)
        }
        if lower.contains("write") || lower.contains("save") || lower.contains("create")
            || lower.contains("patch") || lower.contains("edit") || lower.contains("append")
            || lower.contains("promote") || lower.contains("install")
            || lower.contains("enable") || lower.contains("disable") || lower.contains("configure")
            || lower.contains("set_") || lower.hasSuffix(".set")
            // gpt-5.5 review-2 NEEDS_FIX: move IS a write op — dst is
            // mutated and src is unlinked. Without this, `move_file` slid
            // through as low risk and the policy preview understated it.
            || lower.contains("move") || lower.hasPrefix("mv_") {
            add("filesystem_write", .medium)
        }
        if lower.contains("applescript") || lower.contains("jxa") || lower.contains("shortcut")
            || lower.contains("focus_app") || lower.contains("quit_app")
            || lower.contains("sleep") || lower.contains("lock_screen")
            || lower.contains("set_volume") {
            add("system_control", lower.contains("shortcut") ? .high : .critical)
        }
        // 2026-06-07 the user caught: messages_recent_threads was being
        // classified as high-risk external_send because the keyword
        // "message" matches it. That's a READ-ONLY tool (list threads).
        // The autonomy gate then blocked the call as a security risk.
        // Allowlist the Mac Integration read tools that contain a
        // sensitive keyword in their name; they go through the per-
        // integration permission store gate (mode: .read), not the
        // generic external_send classification.
        let macIntegrationReadOnly: Set<String> = [
            "messages_recent_threads",
            "mail_list_recent",
            "mail_search",
            "mail_senders",
        ]
        if (lower.contains("send") || lower.contains("post") || lower.contains("tweet")
            || lower.contains("message") || lower.contains("reply"))
            && !macIntegrationReadOnly.contains(tool) {
            add("external_send", notificationToolNames.contains(tool) ? .medium : .high)
        }
        if lower.contains("trade") || lower.contains("broker") || lower.contains("order")
            || lower.contains("buy") || lower.contains("sell") || lower.contains("wallet") {
            add("money", .critical)
        }
        if lower.contains("secret") || lower.contains("credential") || lower.contains("token")
            || lower.contains("keychain") {
            add("secrets", .high)
        }
        if tool == "file_info" || lower.contains("read") || lower.contains("list") || lower.contains("search")
            || lower.contains("recall") || lower.contains("status") || lower.contains("get") {
            capabilities.insert("safe_read")
        }

        if capabilityWritesOutsideAppData(
            input: input,
            dataRoot: dataRoot,
            trustedWorkspaceRoots: trustedWorkspaceRoots
        ),
           capabilities.contains("filesystem_write") || capabilities.contains("filesystem_delete") {
            add("outside_app_data_write", .high)
        }
        if !secretKeys(in: .object(input)).isEmpty {
            add("secret_input", .high)
        }
        return ToolProfile(capabilities: capabilities, risk: risk)
    }

    /// Whether an `agent_message` handle names an agent-host contact whose host
    /// actually HAS a command line — the only kind that runs anything. The
    /// contact's endpoint is `mcp://<host row id>`, and its recipe, as the
    /// store validated it (`AgentHostLaunches`), is the one the adapter reads.
    /// Contacts with no command line run no command and keep the ordinary
    /// send risk. The contact is read straight off its file rather than
    /// through the chat module, which depends on this one.
    /// Anything unreadable is not shell-class: the run itself is gated again at
    /// dispatch, and a guess here would only misprice the card.
    static func messagesAnAgentHostByCommand(_ handle: JSONValue?, dataRoot: URL) -> Bool {
        guard let raw = string(handle), raw.hasPrefix("peer:") else { return false }
        let id = String(raw.dropFirst("peer:".count)).lowercased()
        guard UUID(uuidString: id)?.uuidString.lowercased() == id,
              let data = try? Data(contentsOf: dataRoot.appendingPathComponent("agents/peers.json")),
              let rows = try? JSONSerialization.jsonObject(with: data) as? [[String: Any]],
              let contact = rows.first(where: { ($0["id"] as? String)?.lowercased() == id }),
              let transport = contact["transport"] as? String,
              ["mcpHost", "acp"].contains(transport),
              let endpoint = contact["endpoint"] as? String,
              endpoint.hasPrefix(transport == "acp" ? "acp://" : "mcp://") else { return false }
        let launch = AgentHostLaunches.launch(host: String(endpoint.dropFirst("mcp://".count)))
        return transport == "acp" ? launch.acp != nil : launch.commandLine != nil
    }

    /// The tools that run a command line; what one reaches is not known.
    static let commandLineTools: Set<String> = ["shell", "bash", "mac.shell", "mac_shell", "git"]

    /// The name a policy entry, profile and receipt are keyed on. Spellings
    /// resolve through the one alias table (`ToolNameAliases`); what is left
    /// here is not aliasing: a chat tool that fronts a connector action is
    /// judged as that action (`x_search` performs `x.search_recent`), and no
    /// such action id is ever dispatched as a tool.
    package static func policyToolName(_ raw: String) -> String {
        let tool = ToolNameAliases.canonical(raw).trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        return connectorActionIDs[tool] ?? tool
    }

    static let connectorActionIDs: [String: String] = [
        "mobile_notify": "mobile.notify",
        "mac_notify": "mac.notify",
        "x_status": "x.status",
        "x_me": "x.me",
        "x_search": "x.search_recent",
        "x_timeline": "x.timeline_home",
        "x_user_tweets": "x.user_tweets",
        "slack_status": "slack.status",
        "slack_list_channels": "slack.list_channels",
        "slack_search_messages": "slack.search_messages",
        "slack_post_message": "slack.post_message",
        "agentmail_send": "agentmail.send",
    ]
}
