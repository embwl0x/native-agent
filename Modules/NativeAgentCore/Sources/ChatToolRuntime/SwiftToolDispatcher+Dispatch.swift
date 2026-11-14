import AuthoredCapabilities
import AgentWorkspace
import ChatToolParsing
import Foundation
import CryptoKit
import NativeAgentCore
import NativeAgentShared
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
// Blueprint: | `SwiftToolDispatcher+Dispatch.swift` | Normalized dispatch; pure validation; part-write receipts |
extension SwiftToolDispatcher {
    /// Only bare web addresses gain https://; explicit schemes, file names and navigation words retain their meaning.
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

    public func dispatch(tool requestedTool: String, input rawInput: [String: JSONValue], surface: String, turn: Turn,
        invocation: ChatToolInvocation) async throws -> JSONValue {
        return ChatToolOutcome.normalizedFailure(try await withToolArguments(turn: turn, invocation: invocation, tool: requestedTool, input: rawInput,
            surface: surface) { input, invocation in
            try await MacAppActGate.withAdmission(
                origin: SecurityOriginContext.currentTurn(turn: turn, surface: surface),
                dataRoot: dataRoot, turn: turn, context: invocation.macContext(dataRoot: dataRoot)
            ) { turn, context in
                try await dispatchNormalized(turn: turn, invocation: invocation.serving(mac: context), tool: requestedTool, input: input, surface: surface)
            }
        }, tool: CanonicalToolNameDispatcher.canonical(requestedTool), throughAppDoor: invocation.appDoor != nil)
    }
    private func dispatchNormalized(turn: Turn, invocation: ChatToolInvocation, tool requestedTool: String, input rawInput: [String: JSONValue],
        surface: String) async throws -> JSONValue {
        let tool = CanonicalToolNameDispatcher.canonical(requestedTool)
        var input = ChatToolSessionInjection.apply(turn: turn, toolName: tool, input: rawInput)
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
        // Internal Mac organs are unavailable at a conversational ingress.
        if Self.internalMacToolNames.contains(tool),
           !ChatToolSessionInjection.explicitSessionId(in: input).isEmpty {
            return .object([
                "status": .string("failed"),
                "effects": .string("none"),
                "reason": .string("internal_tool"),
                "detail": .string("\(tool) is internal now, so nothing ran. Use one of \(Self.fourVerbToolNames.joined(separator: ", ")) instead."),
                "tool": .string(tool),
                "replacement": .array(Self.fourVerbToolNames.map { .string($0) }),
            ])
        }
        var deskState: DeskState?
        if Self.deskItemTools.contains(tool) {
            if tool == "desk_wait" {
                try ToolArguments.requireDeclaredKeys(input, descriptor: BuiltInToolSchemaFactory(requestedNames: ["desk_wait"]).deskSchemas()
                    .compactMap { $0 }.first)
            }
            let state = try await SwiftNativeDeskStore(dataRoot: dataRoot).liveState()
            deskState = state
            let handle = try resolveDeskHandle(input, in: state)
            input["handle"] = .string(handle)
            if let refusal = try await deskHeld(handle) { return refusal }
        }
        // A contributed tool runs in its owner's executor.
        if let appTools, executorOwnedToolNames.contains(tool) {
            if tool == "app" {
                guard var door = invocation.appDoor else {
                    throw ToolFailureError("The app door has no dispatcher. Nothing ran.", effects: .none, owner: "App dispatch")
                }
                door.validate = { name, arguments, turn, invocation in
                    if let refusal = await self.preApprovalRefusal(turn: turn, invocation: invocation, tool: name, input: arguments,
                        surface: surface) { return refusal }
                    return await self.fileReadPreviewRefusal(turn: turn, invocation: invocation, tool: name, input: arguments, surface: surface)
                }
                return try await appTools.execute(tool: tool, input: input, surface: surface,
                    turn: turn, invocation: invocation.with(\.appDoor, door))
            }
            return try await appTools.execute(tool: tool, input: input, surface: surface, turn: turn, invocation: invocation)
        }
        if Self.fileAccessGatedToolNames.contains(tool), try await !fullMacToolAccess(turn: turn, surface: surface).fileOpsAllowed {
            return builderFullMacRequired(invocation: invocation, tool: tool, input: input)
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
            var result = await WebSearchRoutes.search(query: query, categories: categories, timeRange: timeRange) {
                try await reader.search(query: query, categories: categories.isEmpty ? nil : categories,
                                        timeRange: timeRange.isEmpty ? nil : timeRange)
            }
            let reply = ToolResult(result)
            // A search only reads: a failed one changed nothing.
            if case .object(var fields) = result,
               !(reply.said("ok") && reply.status == fields["status"]?.stringValue) {
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
                var failure: [String: JSONValue] = ["status": .string("failed"), "reason": .string("http_status"),
                    "http_status": .int(Int64(status)),
                    "url": .string(url), "effects": .string("none"),
                    "message": .string(ResearchClientError.httpStatus(status).localizedDescription)]
                if [404, 410].contains(status) {
                    failure["remedy"] = .object(["kind": .string("inspect"),
                        "instruction": .string("Use a different address or search for the page."), "next_call": .null])
                }
                return .object(failure)
            }
            catch let error as ResearchClientError where error.failureReason != nil {
                return .object(["status": .string("failed"), "reason": .string(error.failureReason!),
                    "url": .string(url), "effects": .string("none"), "message": .string(error.localizedDescription)])
            }
            let observedURL: String = if case .object(let fields) = fetched, case .object(let coverage)? = fields["coverage"],
                case .string(let finalURL)? = coverage["final_url"] { finalURL } else { url }
            if case .object(let httpFields) = fetched, httpFields["coverage"]?.objectValue?["thin_page"] == .bool(true) {
                // A successfully read script shell requires rendering. This is
                // reader selection, never recovery from an HTTP failure.
                func retainingHTTP(reason: String, attempted: Bool, browser: JSONValue? = nil, note: String) -> JSONValue {
                    var fields = httpFields
                    fields["status"] = .string("partial")
                    fields["reason"] = .string(reason)
                    fields["text_reader"] = .string("http")
                    fields["used_browser"] = .bool(attempted)
                    fields["http_read"] = fetched
                    fields["browser_read"] = browser
                    fields["reader_note"] = .string(note)
                    return .object(fields)
                }
                guard let door = invocation.appDoor else {
                    return retainingHTTP(reason: "browser_door_unavailable", attempted: false,
                        note: "This call has no Chrome app door. The HTTP text is retained; rendered content remains unknown.")
                }
                var arguments: [String: JSONValue] = ["url": .string(observedURL), "new_tab": .bool(true)]
                if let find, !full { arguments["find"] = .string(find) }
                for key in ["raw", "wrong", "why"] where input[key] != nil { arguments[key] = input[key] }
                let browser: JSONValue
                do {
                    // This nested navigation owns the rendered read. The enclosing
                    // workspace sees web.read, so it cannot attach Chrome's page.
                    browser = CanonicalToolNameDispatcher.actionResult(try await door.perform("app",
                        ["action": .string("chrome.navigate"), "args": .object(arguments)], turn,
                        invocation.with(\.frameSource, "direct")), action: "chrome.navigate")
                } catch is CancellationError { throw CancellationError() }
                catch {
                    try Task.checkCancellation()
                    return retainingHTTP(reason: "browser_read_unavailable", attempted: true,
                        browser: ChatToolOutcome.failure(error: error, tool: "chrome.navigate"),
                        note: "Chrome did not return a readable page; its actual failure is attached. The HTTP text is retained.")
                }
                guard case .object(var fields) = browser else {
                    return retainingHTTP(reason: "browser_read_unavailable", attempted: true, browser: browser,
                        note: "Chrome returned no page envelope. The HTTP text is retained; rendered content remains unknown.")
                }
                let page = fields["page"]?.objectValue
                guard case .string(let httpText)? = httpFields["text"],
                      let browserText = page?["text"]?.stringValue ?? page?["sense_page"]?.stringValue else {
                    return retainingHTTP(reason: "browser_content_unmeasured", attempted: true, browser: browser,
                        note: "Chrome supplied no measured readable text. The HTTP text is retained; Chrome's actual page or blocker is attached.")
                }
                // Measure the exact text each reader would serve, including an authored sense.
                let browserCharacters = browserText.filter { !$0.isWhitespace }.count
                let httpCharacters = httpText.filter { !$0.isWhitespace }.count
                let browserIsEmpty = browserCharacters == 0
                    || ["read_window_empty", "find_not_observed"].contains(page?["reason"]?.stringValue ?? "")
                guard !browserIsEmpty, browserCharacters > httpCharacters else {
                    let reason = browserIsEmpty ? "browser_read_empty" : "browser_read_not_richer"
                    let detail = page?["reason"]?.stringValue ?? "No additional readable content was observed in this window."
                    return retainingHTTP(reason: reason, attempted: true, browser: browser,
                        note: "Chrome's background read did not contain more readable content "
                            + "(\(browserCharacters) non-whitespace characters in served text; HTTP \(httpCharacters)). "
                            + "The HTTP text is retained. Chrome: " + detail)
                }
                fields["text"] = .string(browserText)
                if let status = page?["status"] { fields["status"] = status }
                if fields["status"] == nil { fields["status"] = .string("partial") }
                fields["used_browser"] = .bool(true)
                fields["text_reader"] = .string("browser")
                fields["http_read"] = fetched
                if fields["url"] == nil { fields["url"] = .string(observedURL) }
                fields["reader_note"] = .string("""
                    Chrome supplied more readable content than the thin HTTP text, so its background-tab read supplies text. The HTTP extraction and its \
                    source receipt remain in http_read. Chrome's receipt and page describe what actually happened. Consent was not accepted or dismissed.
                    """)
                return .object(fields)
            }
            let corner = SenseCorner.site(host: URL(string: observedURL)?.host?.lowercased() ?? parsed.host!.lowercased())
            var senseInput = input
            senseInput["__sense_action"] = .string("web.read")
            let result = try await SenseDoor.read(corner: corner, address: observedURL, input: senseInput,
                scope: turn.verifiedSessionID ?? "",
                nativeCorner: .stream(id: "web"),
                operation: invocation.senseOperation(turn: turn),
                raw: { _ in fetched },
                material: { document, _ in
                    let reply = ToolResult(document)
                    guard case .object(let fields) = document,
                          !(reply.said("failed") && reply.status == fields["status"]?.stringValue) else {
                        throw SenseFailure(code: "source_unavailable", message: "The original reader refused this read.")
                    }
                    return .pageSnapshot(document)
                })
            return result
        // Ask for the missing file-access switch; prose alone cannot resolve a workspace boundary.
        case "read_file":
            do {
                return try await impl_read_file(turn: turn, invocation: invocation, input: input, surface: surface)
            } catch {
                guard let need = fileOpsNeedEnvelope(invocation: invocation,
                    tool: tool, mode: .read, path: input["path"]?.stringValue, error: error
                ) else { throw error }
                return need
            }
        case "list_dir", "file_info":
            if tool == "list_dir" { input = Self.listDirInput(input) }
            if try await fullMacToolAccess(turn: turn, surface: surface).fileOpsAllowed {
                return tool == "list_dir" ? try await impl_full_mac_list_dir(turn: turn, invocation: invocation, input: input, surface: surface)
                    : try await impl_local_connector_tool(turn: turn, invocation: invocation, tool: tool, input: input, surface: surface)
            }
            do {
                return try await impl_file_metadata(turn: turn, invocation: invocation, tool: tool, input: input)
            } catch {
                guard let need = fileOpsNeedEnvelope(invocation: invocation,
                    tool: tool, mode: .read, path: input["path"]?.stringValue, error: error
                ) else { throw error }
                return need
            }
        case "write_file", "move_file", "copy_file", "trash_file":
            if try await fullMacToolAccess(turn: turn, surface: surface).fileOpsAllowed {
                return partWrote(invocation: invocation, try await impl_local_connector_tool(turn: turn, invocation: invocation, tool: tool, input: input,
                    surface: surface))
            }
            do {
                return partWrote(invocation: invocation, try await impl_trusted_file_mutation(turn: turn, invocation: invocation, tool: tool, input: input))
            } catch {
                guard let need = fileOpsNeedEnvelope(invocation: invocation,
                    tool: tool, mode: .write, path: input["path"]?.stringValue, error: error
                ) else { throw error }
                return need
            }
        case "bot_create", "bot_update", "bot_pause", "bot_run_once", "bot_list", "shelf_read", "shelf_entry", "bot_ask", "bot_delete":
            return try await impl_standingBots(turn: turn, invocation: invocation, tool: tool, input: input, surface: surface)
        case "recall_memory":   return try await impl_recall_memory(turn: turn, input: input, surface: surface)
        case "commit_memory":   return try await impl_commit_memory(turn: turn, invocation: invocation, input: input)
        case "memory_proposals_pending": return try await impl_memory_proposals_pending(input: input, surface: surface)
        case "memory_proposal_review": return try await impl_memory_proposal_review(turn: turn, invocation: invocation, input: input, surface: surface)
        case "forget_memory":   return try await impl_forget_memory(input: input)
        case "rebuild_knowledge_graph": return try await impl_rebuild_knowledge_graph(input: input)
        case "task_ledger_post": return try await impl_task_ledger_post(input: input)
        case "task_ledger_list": return try await impl_task_ledger_list(input: input)
        case "delegation_status": return try await impl_delegation_status(invocation: invocation, input: input)
        case "agent_contacts", "agent_connect", "agent_message", "agent_read", "agent_cancel":
            let result = try await impl_agentCommunication(turn: turn, invocation: invocation, tool: tool, input: input, surface: surface)
            // A connection ends discovery's offer of it in the same call.
            if tool == "agent_connect" { await AgentDiscoverySession.shared.settle(dataRoot: dataRoot) }
            return result
        case "desk_read": return try await impl_desk_read(input: input)
        case "desk_add_item": return try await impl_desk_add_item(input: input)
        case "desk_set_status": return try await impl_desk_set_status(invocation: invocation, input: input, state: deskState!)
        case "desk_wait": return try await impl_desk_wait(invocation: invocation, input: input, state: deskState!)
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
        case "desk_nag_control": return try await impl_desk_nag_control(turn: turn, invocation: invocation, input: input, surface: surface)
        case "desk_open_pursuit": return try await impl_desk_open_pursuit(input: input)
        case "desk_work_log": return try await impl_desk_work_log(input: input)
        // Consults and journal entries remain deliberate calls; dispatch neither appends nor retrieves automatically.
        case "studio_consult": return try await impl_studio_consult(input: input)
        case "studio_consult_read": return try await impl_studio_consult_read(input: input)
        case "studio_journal": return try await impl_studio_journal(turn: turn, input: input, surface: surface)
        case "studio_journal_amend": return try await impl_studio_journal_amend(turn: turn, input: input, surface: surface)
        case "studio_recall": return try await impl_studio_recall(turn: turn, invocation: invocation, input: input)
        case "dream_diary_read": return try await impl_dream_diary_read(input: input)
        case "studio_shelf_read": return await impl_studio_shelf(turn: turn, input: input, surface: surface, set: false)
        case "studio_shelf_set": return await impl_studio_shelf(turn: turn, input: input, surface: surface, set: true)
        case "studio_canon": return try await impl_studio_canon(input: input)
        // Derive the canon seat from runtime provenance, cross-checked against the live turn, never tool input.
        case "studio_canon_resolve":
            return try await impl_studio_canon_resolve(turn: turn, input: input, surface: surface)
        case "search_kg":       return try await impl_search_kg(input: input, surface: surface)
        case "search_chat_history": return try await impl_search_chat_history(input: input, invokedAs: tool)
        case "workspace":
            // The outer verified-session facade consumes this preparation; Core alone never turns a button into an ungated nested action.
            return .object(["status": .string("prepared"), "execution": .string("requires_workspace_runtime")])
        case "work_context": return try await impl_work_context(turn: turn, invocation: invocation, input: input, surface: surface)
        case "artifact_find": return try await impl_artifact_find(turn: turn, input: input)
        case "read_chat_message": return try await impl_read_chat_message(input: input, invokedAs: tool)
        case "get_persona_doc": return try await impl_get_persona_doc(turn: turn, input: input)
        case "persona_read": return try await impl_persona_read(turn: turn, input: input)
        case "persona_write": return try await impl_persona_write(input: input)
        case "persona_append_section": return try await impl_persona_append_section(input: input)
        case "agent_introspect": return try await impl_agent_introspect(turn: turn, input: input, surface: surface)
        case "tool_result_page": return await impl_tool_result_page(turn: turn, input: input)
        case "request_interaction": return await impl_request_interaction(invocation: invocation, input: input)
        case "context_lookup": return try await impl_context_lookup(input: input)
        case "context_expand": return try await impl_context_expand(turn: turn, invocation: invocation, input: input, surface: surface)
        case "scratchpad_read": return try await impl_scratchpad_read(input: input)
        case "recent_trace_summary": return try await impl_recent_trace_summary(turn: turn, invocation: invocation, input: input)
        case "time_now": return ClockReply.read(input) { $0.chat }
        case "inner_state": return await impl_inner_state(input: input, surface: surface)
        case "shell":
            return await Self.impl_shell(turn: turn, input: input, dataRoot: dataRoot)
        case "bash":
            return await Self.impl_shell(turn: turn, input: input, dataRoot: dataRoot, executable: "/bin/bash", toolName: "bash")
        case "git":
            return await Self.impl_git(turn: turn, input: input, dataRoot: dataRoot)
        case "apply_patch":
            return await Self.impl_apply_patch(turn: turn, input: input, dataRoot: dataRoot)
        case "swift_build":
            return await Self.impl_swift_package(turn: turn, command: "build", input: input, dataRoot: dataRoot)
        case "swift_test":
            return await Self.impl_swift_package(turn: turn, command: "test", input: input, dataRoot: dataRoot)
        case "remote_node_list":
            return try await impl_remote_node_list()
        case "remote_node_execute":
            return try await impl_remote_node_execute(input: input)
        case "install_app":
            return await Self.impl_install_app(input: input, dataRoot: dataRoot)
        // Share restart policy, cooldown and audit with Telegram /restart.
        case "restart_app":
            let reason: String = {
                if case .string(let r)? = input["reason"] { return r }
                return ""
            }()
            return await AppRelaunch.shared.requestRestart(turn: turn,
                reason: reason,
                source: "chat:\(surface)"
            )
        case "image_generate":
            let generated = await impl_image_generate(turn: turn, invocation: invocation, input: input, surface: surface)
            let reply = ToolResult(generated)
            guard case .object(let generation) = generated, reply.said("ok"), reply.status == generation["status"]?.stringValue else { return reply.payload }
            let paths = (generation["images"]?.arrayValue ?? []).compactMap { image -> String? in
                guard let path = (image.objectValue?["path"])?.stringValue else { return nil }
                return URL(fileURLWithPath: path).standardizedFileURL.resolvingSymlinksInPath().path
            }
            // Provider execution stays native; the part composes its raw artifact result with make.add. Only this native receipt grants output provenance, not
            // the part's returned or supplied JSON.
            let registration = await Parts(root: dataRoot).call(id: "make-generated", input: .object([
                    "generated": generated, "prompt": .string(input["prompt"]?.stringValue ?? input["description"]?.stringValue ?? ""),
                    "ref": input["__make_ref"]?.stringValue.map(JSONValue.string) ?? .null]),
                    within: .init(actions: ["make.add"], capabilities: []),
                    invocation: invocation.partInvocation(turn: turn.with(\.makeRegistration, .init(generatedImagePaths: Set(paths))), surface: surface),
                    as: JSONValue.self)
            switch registration {
            case .success(let result): return Self.studioImageInvitation(result)
            case .failure(let error):
                // Registration failed after generation completed. Keep the artifacts top-level for every reply surface and persistence.
                var response = generation
                response["status"] = .string("failed")
                response["reason"] = .string("make_registration_failed")
                response["detail"] = .string(error.message)
                response["effects"] = .string("unknown")
                return .object(response)
            }
        case let name where Self.macIntegrationAccess(forTool: name) != nil:
            return try await dispatchMacIntegrationTool(turn: turn, invocation: invocation, tool: name, surface: surface, input: input)
        case "mac_location":
            // The fix the Mac holds answers first, whatever the permission now. Not yet asked: macOS's own prompt is the ask (the reader raises it); the
            // Settings-row card is for a denial with nothing held.
            let held = try await MacLocationReader.read(context: invocation.macContext(dataRoot: dataRoot))
            let reply = ToolResult(held)
            guard !Task.isCancelled, !invocation.expired else { throw invocation.cancellationError }
            guard case .object(let fields) = held, !(reply.said("ok") && reply.status == fields["status"]?.stringValue),
                  [.denied, .restricted].contains(SystemPermissionPreflight.status(.location)) else { return held }
            return await Self.requestedInteraction(invocation: invocation, input: [
                "kind": .string("permission"), "target": .string("location"), "mode": .string("read"),
                "why": .string("I need Location Services to read where this Mac is."),
                "decline_consequence": .string("I can ask the paired iPhone for location or use a place you give me.")
            ], dataRoot: dataRoot)
        case "mac_screenshot_save":
            return try await impl_mac_screenshot_save(turn: turn, invocation: invocation, input: input, surface: surface)
        case let name where Self.fullMacFileToolNames.contains(name):
            return try await impl_local_connector_tool(turn: turn, invocation: invocation, tool: name, input: input, surface: surface)
        case let name where Self.fullMacSystemToolNames.contains(name):
            return try await impl_local_connector_tool(turn: turn, invocation: invocation, tool: name, input: input, surface: surface)
        // Four verbs own their composed execution before the raw routes.
        case let name where Self.fourVerbToolNames.contains(name):
            return try await impl_mac_four_verbs_tool(turn: turn, invocation: invocation, tool: name, input: input, surface: surface)
        case let name where Self.fullMacAccessibilityReadToolNames.contains(name)
            || Self.fullMacAccessibilityInjectionToolNames.contains(name)
            || Self.macClipboardToolNames.contains(name) || Self.macMenuToolNames.contains(name):
            return try await impl_mac_control_tool(turn: turn, invocation: invocation, tool: name, input: input, surface: surface)
        // Document reads also apply file authority when their route uses a path.
        case let name where Self.macReadToolNames.contains(name):
            return try await impl_mac_read_tool(turn: turn, invocation: invocation, tool: name, input: input, surface: surface)
        // Activity queries use capture preferences and remain Mac-local.
        case let name where Self.activityQueryToolNames.contains(name):
            return try await impl_activity_query_tool(turn: turn, tool: name, input: input, surface: surface)
        default:
            // Authored calls use Parts.run with the selected fingerprint. Parts verifies admission on every run; keeping follows its Full Mac/owner authority
            // rule. Built-ins matched above.
            if let record = try registryToolRecord(tool) {
                guard case .string(let fingerprint)? = record["codeFingerprint"], !fingerprint.isEmpty else {
                    return .object([
                        "status": .string("failed"),
                        "effects": .string("none"),
                        "reason": .string("unsigned_tool"),
                        "tool": .string(tool),
                        "fix": .string("""
                            Part '\(tool)' has no codeFingerprint in its selected abilities/<id>.js file. Read it with ability.read, then keep \
                            it with ability.enable.
                            """),
                    ])
                }
                // A verb the part answers passes its integration switch as the native verb did: granted, or the person's inline grant request.
                if let gate = try Self.integrationGate(tool: tool, input: input, turn: turn) {
                    let allowed = try await macIntegrationPermissionStore.allows(gate.integration, mode: gate.mode)
                    if !allowed {
                        return try await Self.macIntegrationDeniedEnvelope(invocation: invocation, integration: gate.integration, mode: gate.mode,
                            store: macIntegrationPermissionStore)
                    }
                } else if case .string(let verb)? = input["verb"], case .object(let reach)? = record["reach"],
                          case .array(let paths)? = reach["readPaths"], !paths.isEmpty, !(await fullMacYoloAdmitted(turn: turn, surface: surface)) {
                    // The person's files with no app switch over them are Full Mac's to read, refused without a card as a native reader was.
                    return ChatToolOutcome.refusedBeforeRunning(.object(["status": .string("failed"), "reason": .string("full_mac_required"),
                        "effects": .string("none"), "detail": .string("""
                            \(verb) reads files outside any app's switch, which needs admitted Full Mac and file-read permission. Check Trust and file \
                            access at the Mac; nothing was read and no card was raised.
                            """)]))
                }
                // Pin the selected fingerprint so a registry or manifest swap fails with fingerprintMismatch.
                var partInvocation = invocation.partInvocation(turn: turn, surface: surface)
                partInvocation = Parts.Invocation(host: partInvocation.host, execution: partInvocation.execution,
                    arrived: partInvocation.arrived, progressed: partInvocation.progressed,
                    openScreenWatch: { request, hands in
                        try await self.openScreenWatch(turn: turn, invocation: invocation, request, hands: hands, surface: surface)
                    })
                return try await Parts(root: dataRoot)
                    .run(id: tool, input: .object(input.filter { $0.key != "__session_id" }),
                         requiredFingerprint: invocation.valueCall.flatMap { $0.id == tool ? $0.version : nil } ?? fingerprint,
                         invocation: partInvocation)
            }
            throw AutonomyGateError.toolDenied(
                reason: "SwiftToolDispatcher: '\(tool)' is not in the dispatch table"
            )
        }
    }
}
extension SwiftToolDispatcher: PureToolArgumentValidating {
    public func argumentRefusal(tool: String, input: [String: JSONValue], turn: Turn) async -> JSONValue? {
        let tool = CanonicalToolNameDispatcher.canonical(tool)
        if tool == "desk_close" {
            do { try Self.validateDeskClose(input) }
            catch { return ChatToolOutcome.failure(error: error, tool: tool) }
        }
        if let appTools, executorOwnedToolNames.contains(tool) {
            return await (appTools as? any PureToolArgumentValidating)?.argumentRefusal(tool: tool, input: input, turn: turn)
        }
        if tool == "apply_patch" { return Self.builderValidatePatch(input: input).refusal }
        return await (macIntegrationBridge as? any PureToolArgumentValidating)?.argumentRefusal(tool: tool, input: input, turn: turn)
    }
}
extension SwiftToolDispatcher {
    /// A part's own file write, told to its run as it stands right after the write.
    func partWrote(invocation: ChatToolInvocation, _ result: JSONValue) -> JSONValue {
        guard let wrote = invocation.wrote, ChatToolOutcome.outputLooksSuccessful(result),
              case .object(let fields) = result, case .string(let path)? = fields["path"] else { return result }
        wrote(URL(fileURLWithPath: path))
        return result
    }
}
