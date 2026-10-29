import AuthoredCapabilities
import AgentWorkspace
import ChatToolParsing
import Foundation
import CryptoKit
import NativeAgentCore
import PersistenceCore
import PersonaEngine
import MemoryV2
import ProviderRouting
import ToolRegistry
import TrustCenter
import Dispatcher
import Desk
import MacControl
import SwarmRuns
import MacIntegration
import ToolExecution
import Studio
import Senses
import Research
import TurnTrace
// Blueprint: | `SwiftToolDispatcher+Dispatch.swift` | One normalized dispatch ingress, pure argument validation and part-write receipts with unchanged routes and artifact results |
extension SwiftToolDispatcher {
    /// A bare address as a person types it ("example.com", "x.com/home") gets
    /// https:// before Chrome or page-read dispatch.
    /// Anything else, a scheme, not a domain ("back") or a file name
    /// ("notes.txt"), is returned as given; https:// typed out still works.
    static func withWebScheme(_ raw: String) -> String {
        let text = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        let bare = #"^(?:[a-z0-9](?:[a-z0-9-]*[a-z0-9])?\.)+[a-z]{2,}(?::\d+)?(?:[/?#]\S*)?$"#
        guard text.range(of: bare, options: [.regularExpression, .caseInsensitive]) != nil else { return raw }
        let host = text.prefix { !":/?#".contains($0) }.lowercased()
        return fileSuffixes.contains(String(host.split(separator: ".").last ?? "")) ? raw : "https://" + text
    }
    private static let fileSuffixes: Set<String> = ["txt", "md", "json", "jsonl", "pdf", "png", "jpg", "jpeg", "gif", "heic",
        "webp", "svg", "swift", "js", "ts", "py", "rb", "rs", "sh", "html", "css", "csv", "tsv", "log", "zip", "gz", "tar",
        "dmg", "pkg", "app", "doc", "docx", "xls", "xlsx", "ppt", "pptx", "key", "pages", "numbers", "mov", "mp3", "mp4",
        "wav", "yaml", "yml", "toml", "xml", "plist", "sql", "db", "rtf", "ipynb"]

    public func dispatch(tool requestedTool: String, input rawInput: [String: JSONValue], surface: String) async throws -> JSONValue {
        ChatToolOutcome.normalizedFailure(try await withToolArguments(tool: requestedTool, input: rawInput) { input in
            try await dispatchNormalized(tool: requestedTool, input: input, surface: surface)
        }, tool: CanonicalToolNameDispatcher.canonical(requestedTool))
    }
    private func dispatchNormalized(tool requestedTool: String, input rawInput: [String: JSONValue], surface: String) async throws -> JSONValue {
        let tool = CanonicalToolNameDispatcher.canonical(requestedTool)
        var input = ChatToolSessionInjection.apply(toolName: tool, input: rawInput)
        if ToolCallParser.isIgnorableToolName(tool) {
            return .object([
                "status": .string("ignored"),
                "reason": .string("placeholder_tool_name"),
                "tool": .string(tool),
            ])
        }
        if !usesCanonicalBody, Self.canonicalBodyOnlyToolNames.contains(tool) {
            return .object([
                "status": .string("failed"),
                "effects": .string("none"),
                "reason": .string("canonical_body_unavailable"),
                "detail": .string("\(tool) is not available in this context, so nothing ran."),
                "tool": .string(tool),
            ])
        }
        // Four-verb cutover: a conversational call always carries session_id.
        // Keep the mac_* organs callable by direct diagnostics (which do not)
        // while refusing stale model calls from an old persisted loadout.
        if Self.legacyMacModelToolNames.contains(tool),
           !ChatToolSessionInjection.explicitSessionId(in: input).isEmpty {
            return .object([
                "status": .string("failed"),
                "effects": .string("none"),
                "reason": .string("legacy_mac_tool_internal_only"),
                "detail": .string("\(tool) is internal now, so nothing ran. Use one of \(Self.fourVerbToolNames.joined(separator: ", ")) instead."),
                "tool": .string(tool),
                "replacement": .array(Self.fourVerbToolNames.map { .string($0) }),
            ])
        }
        var deskState: DeskState?
        if Self.deskItemTools.contains(tool) {
            let state = try await SwiftNativeDeskStore(dataRoot: dataRoot).liveState()
            deskState = state
            let handle = try resolveDeskHandle(input, in: state)
            input["handle"] = .string(handle)
            if let session = ChatToolSessionInjection.currentSession,
               let refusal = try await deskHeld(handle, session: session) { return refusal }
        }
        // A contributed tool runs in its owner's executor.
        if let appTools, executorOwnedToolNames.contains(tool) {
            if tool == "app" {
                return try await AppDoorReentry.$validate.withValue({ name, arguments in
                    if let refusal = await self.preApprovalRefusal(tool: name, input: arguments, surface: surface) { return refusal }
                    return await self.fileReadPreviewRefusal(tool: name, input: arguments, surface: surface)
                }) {
                    try await appTools.execute(tool: tool, input: input, surface: surface)
                }
            }
            return try await appTools.execute(tool: tool, input: input, surface: surface)
        }
        if Self.fileAccessGatedToolNames.contains(tool), await !fullMacToolAccess(surface: surface).fileOpsAllowed {
            return builderFullMacRequired(tool: tool, input: input)
        }
        switch tool {
        case "maps_search":
            return try await impl_maps_search(input: input)
        case "maps_route":
            return try await impl_maps_route(input: input)
        case "web_search":
            func text(_ key: String) -> String {
                guard case .string(let value)? = input[key] else { return "" }
                return value.trimmingCharacters(in: .whitespacesAndNewlines)
            }
            let query = text("query"), categories = text("categories"), timeRange = text("time_range")
            guard !query.isEmpty else {
                throw ToolFailureError("search needs query: the words to search for.", argumentPath: "query", effects: .none)
            }
            let reader = pageReader
            let tools = appTools
            var result = await WebSearchRoutes.search(query: query, categories: categories, timeRange: timeRange, chromeConnected: {
                guard let tools, case .object(let status)? = try? await tools.execute(tool: "browser.chrome_status", input: [:], surface: surface)
                else { return false }
                return status["extension_connected"] == .bool(true)
            }) {
                try await reader.search(query: query, categories: categories.isEmpty ? nil : categories,
                                        timeRange: timeRange.isEmpty ? nil : timeRange)
            }
            // A search only reads: a failed one changed nothing.
            if case .object(var fields) = result, fields["status"] != .string("ok") {
                fields["effects"] = .string("none")
                result = .object(fields)
            }
            return result
        case "read_page":
            guard case .string(let raw)? = input["url"], case let url = Self.withWebScheme(raw),
                  let parsed = URL(string: url),
                  ["http", "https"].contains(parsed.scheme?.lowercased() ?? ""),
                  parsed.host?.isEmpty == false, parsed.user == nil, parsed.password == nil else {
                throw AutonomyGateError.toolDenied(reason: "read_page requires a public http(s) URL.")
            }
            let find: String?
            switch input["find"] {
            case nil, .null?: find = nil
            case .string(let words)? where !words.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty:
                find = words.trimmingCharacters(in: .whitespacesAndNewlines)
            default: throw AutonomyGateError.toolDenied(reason: "find must contain the words to locate in the page.")
            }
            let around: Int
            switch input["around"] {
            case nil, .null?: around = 1
            case .int(let value)? where (0...3).contains(value): around = Int(value)
            default: throw AutonomyGateError.toolDenied(reason: "around must be an integer from 0 through 3 surrounding paragraphs.")
            }
            let full: Bool
            switch input["full"] {
            case nil, .null?: full = false
            case .bool(let value)?: full = value
            default: throw AutonomyGateError.toolDenied(reason: "full must be true or false.")
            }
            let fetched: JSONValue
            do { fetched = try await self.pageReader.fetchURL(url).readJSON(find: find, around: around, full: full) }
            catch ResearchClientError.httpStatus(let status) {
                return .object(["status": .string("failed"), "http_status": .int(Int64(status)),
                    "url": .string(url), "effects": .string("none"),
                    "message": .string("HTTP \(status) refused this public read.")])
            }
            catch let error as ResearchClientError where error.failureReason != nil {
                return .object(["status": .string("failed"), "reason": .string(error.failureReason!),
                    "url": .string(url), "effects": .string("none"), "message": .string(error.localizedDescription)])
            }
            let observedURL: String = if case .object(let fields) = fetched, case .object(let coverage)? = fields["coverage"],
                case .string(let finalURL)? = coverage["final_url"] { finalURL } else { url }
            let corner = SenseCorner.site(host: URL(string: observedURL)?.host?.lowercased() ?? parsed.host!.lowercased())
            var senseInput = input
            senseInput["__sense_action"] = .string("web.read")
            let result = try await SenseDoor.read(corner: corner, address: observedURL, input: senseInput,
                scope: ChatToolSessionContext.verifiedSessionId ?? "",
                nativeCorner: .stream(id: "web"),
                raw: { fetched },
                material: { document in
                    guard case .object(let fields) = document, fields["status"] != .string("failed") else {
                        throw SenseFailure(code: "source_unavailable", message: "The original reader refused this read.")
                    }
                    return .pageSnapshot(document)
                })
            if case .object(let fields) = fetched, case .object(let coverage)? = fields["coverage"], coverage["thin_page"] == .bool(true) {
                let continuation: [String: JSONValue] = ["reason": .string("thin_page"), "hint": coverage["hint"] ?? .null,
                    "next_call": .object(["tool": .string("app"), "input": .object(["action": .string("chrome.navigate"), "args": .object(["url": .string(observedURL)])])])]
                if case .object(let output) = result { return .object(output.merging(continuation) { _, next in next }) }
                if case .string(let text) = result { return .string(text + "\n" + (try JSONValue.object(continuation).serialize(pretty: false))) }
            }
            return result
        // The three basic file tools, when Full Mac file access is off. A path
        // the workspace lane cannot reach is not a fact to report in prose —
        // it is one switch away, and asking for it is the honest move.
        case "read_file":
            do {
                return try await impl_read_file(input: input, surface: surface)
            } catch {
                guard let need = fileOpsNeedEnvelope(
                    tool: tool, mode: .read, path: input["path"]?.stringValue, error: error
                ) else { throw error }
                return need
            }
        case "list_dir", "file_info":
            if tool == "list_dir" { input = Self.listDirInput(input) }
            if await fullMacToolAccess(surface: surface).fileOpsAllowed {
                return tool == "list_dir" ? try await impl_full_mac_list_dir(input: input, surface: surface)
                    : try await impl_local_connector_tool(tool: tool, input: input, surface: surface)
            }
            do {
                return try await impl_file_metadata(tool: tool, input: input)
            } catch {
                guard let need = fileOpsNeedEnvelope(
                    tool: tool, mode: .read, path: input["path"]?.stringValue, error: error
                ) else { throw error }
                return need
            }
        case "write_file", "move_file", "copy_file", "trash_file":
            if await fullMacToolAccess(surface: surface).fileOpsAllowed {
                return partWrote(try await impl_local_connector_tool(tool: tool, input: input, surface: surface))
            }
            do {
                return partWrote(try await impl_trusted_file_mutation(tool: tool, input: input))
            } catch {
                guard let need = fileOpsNeedEnvelope(
                    tool: tool, mode: .write, path: input["path"]?.stringValue, error: error
                ) else { throw error }
                return need
            }
        case "bot_create", "bot_update", "bot_pause", "bot_run_once", "bot_list", "shelf_read", "shelf_entry", "bot_ask", "bot_delete":
            return try await impl_standingBots(tool: tool, input: input, surface: surface)
        case "recall_memory":   return try await impl_recall_memory(input: input, surface: surface)
        case "commit_memory":   return try await impl_commit_memory(input: input)
        // Her review seat over the memory proposals still waiting on her.
        case "memory_proposals_pending": return try await impl_memory_proposals_pending(input: input, surface: surface)
        case "memory_proposal_review": return try await impl_memory_proposal_review(input: input, surface: surface)
        case "forget_memory":   return try await impl_forget_memory(input: input)
        case "rebuild_knowledge_graph": return try await impl_rebuild_knowledge_graph(input: input)
        case "workshop_submit": return try await impl_workshop_submit(input: input)
        case "workshop_status": return try await impl_workshop_status(input: input)
        case "task_ledger_post": return try await impl_task_ledger_post(input: input)
        case "task_ledger_list": return try await impl_task_ledger_list(input: input)
        // delegation_status reads wake-job stores without writes, spawns or network access.
        case "delegation_status": return try await impl_delegation_status(input: input)
        case "agent_contacts", "agent_connect", "agent_message", "agent_read", "agent_cancel":
            let result = try await impl_agentCommunication(tool: tool, input: input, surface: surface)
            // A connection ends discovery's offer of it in the same call.
            if tool == "agent_connect" { await AgentDiscoverySession.shared.settle(dataRoot: dataRoot) }
            return result
        case "desk_read": return try await impl_desk_read(input: input)
        case "desk_add_item": return try await impl_desk_add_item(input: input)
        case "desk_set_status": return try await impl_desk_set_status(input: input, state: deskState!)
        case "desk_wait": return try await impl_desk_wait(input: input, state: deskState!)
        case "desk_update_item": return try await impl_desk_update_item(input: input)
        case "desk_note": return try await impl_desk_note(input: input)
        case "desk_add_ref": return try await impl_desk_add_ref(input: input)
        case "desk_set_cadence": return try await impl_desk_set_cadence(input: input)
        case "desk_set_notify": return try await impl_desk_set_notify(input: input)
        case "desk_close": return try await impl_desk_close(input: input)
        case "desk_archive": return try await impl_desk_archive(input: input)
        case "desk_blocked_on": return try await impl_desk_blocked_on(input: input, state: deskState!)
        case "desk_defer": return try await impl_desk_defer(input: input)
        case "desk_breakdown": return try await impl_desk_breakdown(input: input)
        case "desk_nag_control": return try await impl_desk_nag_control(input: input)
        case "desk_open_pursuit": return try await impl_desk_open_pursuit(input: input)
        case "desk_work_log": return try await impl_desk_work_log(input: input)
        // Studio chat lane (desk 903): consults filed against the agent's taste
        // and the journal she writes herself. Nothing here auto-appends and
        // nothing auto-retrieves.
        case "studio_consult": return try await impl_studio_consult(input: input)
        case "studio_consult_read": return try await impl_studio_consult_read(input: input)
        case "studio_journal": return try await impl_studio_journal(input: input)
        case "studio_journal_amend": return try await impl_studio_journal_amend(input: input)
        case "studio_recall": return try await impl_studio_recall(input: input)
        case "dream_diary_read": return try await impl_dream_diary_read(input: input)
        case "studio_shelf_read": return await impl_studio_shelf(input: input, surface: surface, set: false)
        case "studio_shelf_set": return await impl_studio_shelf(input: input, surface: surface, set: true)
        case "studio_canon": return try await impl_studio_canon(input: input)
        // `surface` is threaded in because the canon SEAT is decided from
        // runtime provenance and cross-checked against the running turn, never
        // read from tool input. See StudioCanonSeatGate.
        case "studio_canon_resolve":
            return try await impl_studio_canon_resolve(input: input, surface: surface)
        case "search_kg":       return try await impl_search_kg(input: input, surface: surface)
        case "search_chat_history": return try await impl_search_chat_history(input: input, invokedAs: tool)
        case "workspace":
            // The outer verified-session facade consumes this preparation;
            // Core alone never turns a button into an ungated nested action.
            return .object(["status": .string("prepared"), "execution": .string("requires_workspace_runtime")])
        case "work_context": return try await impl_work_context(input: input, surface: surface)
        case "artifact_find": return try await impl_artifact_find(input: input)
        case "read_chat_message": return try await impl_read_chat_message(input: input, invokedAs: tool)
        case "get_persona_doc": return try await impl_get_persona_doc(input: input)
        case "persona_read": return try await impl_persona_read(input: input)
        case "persona_write": return try await impl_persona_write(input: input)
        case "persona_append_section": return try await impl_persona_append_section(input: input)
        case "agent_introspect": return try await impl_agent_introspect(input: input)
        case "tool_result_page": return await impl_tool_result_page(input: input)
        case "request_interaction": return await impl_request_interaction(input: input)
        case "context_lookup": return try await impl_context_lookup(input: input)
        case "context_expand": return try await impl_context_expand(input: input, surface: surface)
        case "scratchpad_read": return try await impl_scratchpad_read(input: input)
        case "recent_trace_summary": return try await impl_recent_trace_summary(input: input)
        case "time_now": return ClockReply.read(input) { $0.chat }
        // Reading inner state never mutates, persists or calls a provider.
        case "inner_state": return await impl_inner_state(input: input, surface: surface)
        // Builder CLI calls require the Full Mac file-operations gate and write data/builder_audit/<uuid>.json.
        case "shell":
            return await Self.impl_shell(input: input, dataRoot: dataRoot)
        case "bash":
            return await Self.impl_shell(input: input, dataRoot: dataRoot, executable: "/bin/bash", toolName: "bash")
        case "git":
            return await Self.impl_git(input: input, dataRoot: dataRoot)
        case "apply_patch":
            return await Self.impl_apply_patch(input: input, dataRoot: dataRoot)
        case "swift_build":
            return await Self.impl_swift_package(command: "build", input: input, dataRoot: dataRoot)
        case "swift_test":
            return await Self.impl_swift_package(command: "test", input: input, dataRoot: dataRoot)
        case "remote_node_list":
            return try await impl_remote_node_list()
        case "remote_node_execute":
            return try await impl_remote_node_execute(input: input)
        case "install_app":
            return await Self.impl_install_app(input: input, dataRoot: dataRoot)
        // restart_app shares the builder gate and AppRelaunch cooldown, audit and relaunch with Telegram /restart.
        case "restart_app":
            let reason: String = {
                if case .string(let r)? = input["reason"] { return r }
                return ""
            }()
            return await AppRelaunch.shared.requestRestart(
                reason: reason,
                source: "chat:\(surface)"
            )
        case "agent_swarm": return try await impl_agent_swarm(input: input, surface: surface)
        case "image_generate":
            let generated = await impl_image_generate(input: input, surface: surface)
            guard case .object(let generation) = generated, generation["status"] == .string("ok") else { return generated }
            let paths = (generation["images"]?.arrayValue ?? []).compactMap { image -> String? in
                guard let path = (image.objectValue?["path"])?.stringValue else { return nil }
                return URL(fileURLWithPath: path).standardizedFileURL.resolvingSymlinksInPath().path
            }
            // Provider execution stays native; the part composes its raw
            // artifact result with make.add. Only this native receipt grants
            // output provenance, not the part's returned or supplied JSON.
            let registration = await MakeStudio.$generatedImagePaths.withValue(Set(paths)) {
                await Parts(root: dataRoot).call(id: "make-generated", input: .object([
                    "generated": generated, "prompt": .string(input["prompt"]?.stringValue ?? input["description"]?.stringValue ?? ""),
                    "ref": input["__make_ref"]?.stringValue.map(JSONValue.string) ?? .null]),
                    within: .init(actions: ["make.add"], capabilities: []), as: JSONValue.self)
            }
            switch registration {
            case .success(let result): return Self.studioImageInvitation(result)
            case .failure(let error):
                // Registration failed after generation completed. Keep the
                // artifacts top-level for every reply surface and persistence.
                var response = generation
                response["status"] = .string("failed")
                response["reason"] = .string("make_registration_failed")
                response["detail"] = .string(error.message)
                response["effects"] = .string("unknown")
                return .object(response)
            }
        case let name where MacIntegrationGates.byTool[name] != nil:
            return try await dispatchMacIntegrationTool(tool: name, surface: surface, input: input)
        case "claude_message":
            // Claude messages append to the private JSONL inbox without launching a process.
            return try await runClaudeMessage(
                input: input,
                surface: surface,
                configRootOverride: agentBridgeConfigRoot
            )
        case "codex_message":
            // Codex messages use the durable inbox and optionally notify through the Mac integration bridge.
            return try await runCodexMessage(input: input, surface: surface)
        case "omp_message":
            return try await runOMPMessage(input: input, surface: surface)
        case "invoke_codex":
            // codex exec runs a bounded subprocess with a Trust-selected sandbox and a data/from_codex/<uuid>.json audit.
            return PeerDataTaintDispatcher.labelled(try await Self.runInvokeCodex(input: input, dataRoot: dataRoot,
                launch: await Self.drivenAgentLaunch(
                surface: surface, contact: Self.drivenAgentContact(host: "codex", dataRoot: dataRoot),
                name: "Codex", dataRoot: dataRoot)), agent: "codex", dataRoot: dataRoot)
        case "mac_location":
            // The fix the Mac holds answers first, whatever the permission now.
            // Not yet asked: macOS's own prompt is the ask (the reader raises it);
            // the Settings-row card is for a denial with nothing held.
            let held = await MacLocationReader.read()
            guard case .object(let fields) = held, fields["status"] != .string("ok"),
                  [.denied, .restricted].contains(SystemPermissionPreflight.status(.location)) else { return held }
            return await Self.requestedInteraction(input: [
                "kind": .string("permission"), "target": .string("location"), "mode": .string("read"),
                "why": .string("I need Location Services to read where this Mac is."),
                "decline_consequence": .string("I can ask the paired iPhone for location or use a place you give me.")
            ], dataRoot: dataRoot)
        case "mac_screenshot_save":
            return try await impl_mac_screenshot_save(input: input, surface: surface)
        case let name where Self.fullMacFileToolNames.contains(name):
            return try await impl_local_connector_tool(tool: name, input: input, surface: surface)
        case let name where Self.fullMacSystemToolNames.contains(name):
            return try await impl_local_connector_tool(tool: name, input: input, surface: surface)
        // Four verbs own their composed execution before the raw routes.
        case let name where Self.fourVerbToolNames.contains(name):
            return try await impl_mac_four_verbs_tool(tool: name, input: input, surface: surface)
        case let name where Self.fullMacAccessibilityReadToolNames.contains(name)
            || Self.fullMacAccessibilityInjectionToolNames.contains(name)
            || Self.macClipboardToolNames.contains(name) || Self.macMenuToolNames.contains(name):
            return try await impl_mac_control_tool(tool: name, input: input, surface: surface)
        // Document reads also apply file authority when their route uses a path.
        case let name where Self.macReadToolNames.contains(name):
            return try await impl_mac_read_tool(tool: name, input: input, surface: surface)
        // Activity queries use capture preferences and remain Mac-local.
        case let name where Self.activityQueryToolNames.contains(name):
            return try await impl_activity_query_tool(tool: name, input: input, surface: surface)
        default:
            // Authored calls use Parts.run with the selected fingerprint.
            // Parts verifies admission on every run; keeping follows its
            // Full Mac/owner authority rule. Built-ins matched above.
            if let record = try registryToolRecord(tool) {
                guard case .string(let fingerprint)? = record["codeFingerprint"], !fingerprint.isEmpty else {
                    return .object([
                        "status": .string("failed"),
                        "effects": .string("none"),
                        "reason": .string("unsigned_tool"),
                        "tool": .string(tool),
                        "fix": .string("Part '\(tool)' has no codeFingerprint in its selected abilities/<id>.js file. Read it with ability.read, then keep it with ability.enable."),
                    ])
                }
                // Pin execution to the selected fingerprint; a registry or manifest
                // swap between selection and run must fail with fingerprintMismatch.
                return try await Parts(root: dataRoot)
                    .run(id: tool, input: .object(input.filter { $0.key != "__session_id" }),
                         requiredFingerprint: OwnedProgramInvocation.valueCall.flatMap { $0.id == tool ? $0.version : nil } ?? fingerprint)
            }
            throw AutonomyGateError.toolDenied(
                reason: "SwiftToolDispatcher: '\(tool)' is not in the dispatch table"
                    + (ToolNameAliases.retiredAppTools.union(ToolNameAliases.mergedTools).contains(tool)
                        ? ". " + ToolNameAliases.retiredAppToolHint : "")
            )
        }
    }
}
extension SwiftToolDispatcher: PureToolArgumentValidating {
    public func argumentRefusal(tool: String, input: [String: JSONValue]) async -> JSONValue? {
        let tool = CanonicalToolNameDispatcher.canonical(tool)
        if tool == "desk_close" {
            do { try Self.validateDeskClose(input) }
            catch { return ChatToolOutcome.failure(error: error, tool: tool) }
        }
        if let appTools, executorOwnedToolNames.contains(tool) {
            return await (appTools as? any PureToolArgumentValidating)?.argumentRefusal(tool: tool, input: input)
        }
        if tool == "apply_patch" { return Self.builderValidatePatch(input: input).refusal }
        if ["mail_mark_read", "mail_archive", "mail_delete", "mail_reply", "mail_draft"].contains(tool),
           !(tool == "mail_mark_read" && input["messages"] != nil), !(tool == "mail_draft" && input["to"] != nil) {
            let hasLocator = ["message_id", "expected_message_id"].contains { input[$0] != nil && input[$0] != .null }
            let subject = if case .string(let text)? = input["subject"] { text } else { "" }
            if hasLocator ? MailReadLocator.parse(input) == nil : subject.isEmpty {
                return ChatToolOutcome.failure(error: ToolFailureError(
                    "Use message_id with a nonempty expected_message_id from the same read, or a subject.",
                    argumentPath: "$.expected_message_id", accepted: "An observed exact Mail locator, or subject matching.", effects: .none), tool: tool)
            }
        }
        return await (macIntegrationBridge as? any PureToolArgumentValidating)?.argumentRefusal(tool: tool, input: input)
    }
}
extension SwiftToolDispatcher {
    /// A part's own file write, told to its run as it stands right after the write.
    func partWrote(_ result: JSONValue) -> JSONValue {
        guard let wrote = SkillRunContext.wrote, ChatToolOutcome.outputLooksSuccessful(result),
              case .object(let fields) = result, case .string(let path)? = fields["path"] else { return result }
        wrote(URL(fileURLWithPath: path))
        return result
    }
}
