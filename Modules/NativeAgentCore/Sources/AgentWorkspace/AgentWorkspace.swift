import Foundation
import ChatSessionWork
import ChatToolParsing
import PersistenceCore
import NativeAgentCore
// Blueprint: | `AgentWorkspace.swift` | `AgentWorkspace`, `dispatch`: Home and named items through gated owner calls |

package struct AgentWorkspaceFailure: Error, LocalizedError {
    let message: String
    package var errorDescription: String? { message }
}

package enum AgentWorkspace {
    package typealias Perform = @Sendable (String, [String: JSONValue]) async throws -> JSONValue
    package typealias Catalog = @Sendable () async throws -> [LLMToolSchema]

    package static func resolvedRead(_ result: JSONValue, as name: String) -> JSONValue {
        let result = if case .string = result { JSONValue.object(["content": result]) } else { result }
        guard case .object(var fields) = result else { return result }
        if fields["resolved"] == nil { fields["resolved"] = .string(name) }
        return .object(fields)
    }

    package static func dispatch(workspace: WorkspaceOperation, input: [String: JSONValue], scope: String, dataRoot: URL,
                         catalog: Catalog = { [] }, perform: Perform) async throws -> JSONValue {
        let navigation = AgentWorkspaceNavigation.shared
        let key = dataRoot.standardizedFileURL.path + "\u{0}" + scope
        let operation = try await navigation.begin(key: key)
        do {
            await navigation.refreshArrivals(workspace: workspace, key: key, scope: scope, dataRoot: dataRoot)
            let catalog: Catalog = { let schemas = try await catalog(); AgentWorkspaceScreenPreview.keep(catalog: schemas, dataRoot: dataRoot); return schemas }
            var sent: JSONValue?
            var resolved: String?
            var result = try await run(workspace: workspace, input: input, key: key, scope: scope, dataRoot: dataRoot, navigation: navigation,
                                       catalog: catalog, perform: perform, sent: &sent, resolved: &resolved)
            result = await navigation.attachArrivals(to: result, workspace: workspace, dataRoot: dataRoot, key: key)
            if case .object(var receipt)? = sent { receipt["view"] = result; result = .object(receipt) }
            else if let sent { result = .object(["receipt": sent, "view": result]) }
            if let resolved { result = resolvedRead(result, as: resolved) }
            await navigation.end(key: key, operation: operation)
            return result
        } catch {
            await navigation.end(key: key, operation: operation)
            throw error
        }
    }

    private static func text(_ value: JSONValue?) throws -> String? {
        guard let value, value != .null else { return nil }
        guard case .string(let raw) = value else { throw AgentWorkspaceFailure(message: "Item arguments must be text or null.") }
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }

    private static func run(workspace: WorkspaceOperation, input: [String: JSONValue], key: String, scope: String, dataRoot: URL,
        navigation: AgentWorkspaceNavigation,
                            catalog: Catalog, perform: Perform, sent: inout JSONValue?, resolved: inout String?) async throws -> JSONValue {
        let (action, suppliedText, suppliedConversation, rawText) = try workspaceArguments(input)
        var location: AgentWorkspaceLocation = .home
        var result: JSONValue?
        if let action {
            let saved = WorkspaceActionReceipt(sent: sent, resolved: resolved)
            defer { sent = saved.sent; resolved = saved.resolved }
            switch try await runWorkspaceAction(action, suppliedText: suppliedText, suppliedConversation: suppliedConversation,
                                                rawText: rawText, workspace: workspace, input: input, key: key, scope: scope,
                                                dataRoot: dataRoot, navigation: navigation, catalog: catalog, perform: perform,
                                                saved: saved) {
            case .page(let page): return page
            case .location(let target, let value): location = target; result = value
            }
        }
        return try await readWorkspaceLocation(location, result: result, workspace: workspace, key: key, scope: scope,
                                               dataRoot: dataRoot, navigation: navigation, catalog: catalog, perform: perform)
    }

    private final class WorkspaceActionReceipt {
        var sent: JSONValue?
        var resolved: String?

        init(sent: JSONValue?, resolved: String?) {
            self.sent = sent
            self.resolved = resolved
        }
    }

    private enum WorkspaceActionResult {
        case page(JSONValue)
        case location(AgentWorkspaceLocation, JSONValue?)
    }

    /// Validate the named item and the supplied text before doing any work.
    private static func workspaceArguments(_ input: [String: JSONValue]) throws -> (String?, String?, String?, String?) {
        if let fields = input["fields"], fields != .null {
            throw AgentWorkspaceFailure(message: "Use app {action, args} for named fields. Nothing was run.")
        }
        let action = try text(input["action"])
        let suppliedText = try text(input["text"])
        let suppliedConversation = try text(input["conversation"])
        let rawText: String?
        if case .string(let value)? = input["text"] { rawText = value } else { rawText = nil }
        guard (action?.count ?? 0) <= 400, (rawText?.count ?? 0) <= 16000 else {
            throw AgentWorkspaceFailure(
                message: """
                    Open one item, up to 400 characters. Its text is limited \
                    to 16000 characters.
                    """)
        }
        if action == nil, suppliedText != nil || suppliedConversation != nil {
            throw AgentWorkspaceFailure(message: "Text belongs to an item that needs it. app {page:\"home\", find} finds across your work.")
        }
        return (action, suppliedText, suppliedConversation, rawText)
    }

    /// Resolve the current screen target using this scope's navigation.
    private static func resolveScreenTarget(_ name: String, workspace: WorkspaceOperation, dataRoot: URL, scope: String,
                                            key: String, navigation: AgentWorkspaceNavigation) async -> AgentScreen.Target? {
        await AgentScreen.resolve(workspace: workspace, name, dataRoot: dataRoot, scope: scope, browserPages: await navigation.browserPages(key: key),
                                currentPlace: await navigation.current(key: key))
    }

    /// Resolve a named item, drawing its room on first use when needed.
    private static func screenName(_ raw: String, workspace: WorkspaceOperation, dataRoot: URL, scope: String,
                                   key: String, navigation: AgentWorkspaceNavigation, catalog: Catalog,
                                   perform: Perform) async throws -> AgentScreen.Target? {
        if let target = await resolveScreenTarget(raw, workspace: workspace, dataRoot: dataRoot, scope: scope, key: key, navigation: navigation) { return target }
        let named = raw.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        if let dot = named.lastIndex(of: "."), Int(named[named.index(after: dot)...]) == nil,
           case .action(.open(let place))? = await resolveScreenTarget(String(named[..<dot]), workspace: workspace, dataRoot: dataRoot,
                   scope: scope, key: key, navigation: navigation), case .area = place,
           AgentNamed.shared.firstDraw(dataRoot, String(named[..<dot]), scope: scope) {
            if await AgentScreen.room(workspace: workspace, place, dataRoot: dataRoot, scope: scope) == nil {
                guard let projection = try await AgentWorkspaceEnvironment.view(workspace: workspace, location: place, dataRoot: dataRoot, catalog: catalog,
                    perform: perform) else {
                    throw AgentWorkspaceFailure(
                        message: "That room has no current home view. Open home for the places available now; nothing was repeated.")
                }
                let status = AgentWorkspaceEnvironment.outcome(projection.content)
                if await AgentScreen.lifeRoom(workspace: workspace, place, projection: projection, status: status, dataRoot: dataRoot, scope: scope) == nil,
                   let room = AgentScreen.textRoomName(place) {
                    _ = AgentScreen.textRoom(workspace: workspace, room, place: place, projection: projection, status: status, dataRoot: dataRoot,
                        scope: scope)
                }
            }
            if let target = await resolveScreenTarget(raw, workspace: workspace, dataRoot: dataRoot, scope: scope, key: key, navigation: navigation) { return target }
        }
        let call = raw.trimmingCharacters(in: .whitespacesAndNewlines).replacingOccurrences(of: " {}", with: "")
        if AgentScreen.families.contains(where: { $0.tools.contains { $0 == call || (($0.hasSuffix("_") || $0.hasSuffix(".")) && call.hasPrefix($0)) } }),
           let schema = try await AgentWorkspaceEnvironment.optionalSchema(call, catalog: catalog) {
            guard AgentWorkspaceEnvironment.readTools.contains(call), try ToolSignature.argumentNames(schema.parametersJSON).required.isEmpty else {
                throw AgentWorkspaceFailure(message: "\(call) is an action, not an item name: use app find to read its arguments. "
                    + "Nothing was run.")
            }
            return .action(.open(.record(tool: call, input: [:], title: call)))
        }
        return try await AgentScreen.familyRoom(workspace: workspace, raw, catalog: catalog).map(AgentScreen.Target.page)
    }

    /// Open the selected item or dispatch its effect and retain its readback.
    private static func runWorkspaceAction(_ action: String, suppliedText: String?, suppliedConversation: String?, rawText: String?,
                                           workspace: WorkspaceOperation, input: [String: JSONValue], key: String, scope: String,
                                           dataRoot: URL, navigation: AgentWorkspaceNavigation, catalog: Catalog, perform: Perform,
                                           saved: WorkspaceActionReceipt) async throws -> WorkspaceActionResult {
        var location: AgentWorkspaceLocation = .home
        var result: JSONValue?
        let selected: AgentWorkspaceAction
        if let arrival = try? await navigation.claim(action, key: key) { selected = arrival }
        else {
            switch try await screenName(action, workspace: workspace, dataRoot: dataRoot, scope: scope, key: key,
                                        navigation: navigation, catalog: catalog, perform: perform) {
            case .action(let found)?: selected = found
            case .page(let page)?: return .page(.string(page))
            case nil:
                let name = action.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
                if AgentNamed.shared.withdrawn(dataRoot, name, scope: scope), let dot = name.lastIndex(of: ".") {
                    throw AgentWorkspaceFailure(message: "\(name) is gone: \(name[..<dot]) no longer offers it. Open \(name[..<dot]) for what it offers now. Nothing was run.")
                }
                throw ToolFailureError("Nothing on home is named \(action).", argumentPath: "item", effects: .none,
                    nextCall: ToolFailureError.call("app", ["find": .string(action)]))
            }
        }
        if suppliedConversation != nil {
            guard case .message(let agent, _, _) = selected, !agent.hasPrefix("bot:") else {
                throw AgentWorkspaceFailure(message: "A conversation label belongs to an agent message. Helpers use their existing chat. Nothing was sent.")
            }
        }
        var effect: (tool: String, input: [String: JSONValue], title: String, readback: AgentWorkspaceLocation?)?
        switch selected {
        case .openArrival(let id):
            guard suppliedText == nil else { throw AgentWorkspaceFailure(message: "Opening an arrival does not take text.") }
            location = try await navigation.openArrival(id, key: key)
        case .dismissArrival(let id):
            guard suppliedText == nil else { throw AgentWorkspaceFailure(message: "Clearing a notice does not take text.") }
            await navigation.dismissArrival(id, key: key)
            location = .arrivals
        case .open(let target):
            guard suppliedText == nil else { throw AgentWorkspaceFailure(message: "Opening this item does not take text.") }
            location = target
            if case .area = target { saved.resolved = AgentScreen.textRoomName(target) }
        case .perform(let tool, let bound, let title, let textField, let isEffect):
            var args = bound
            if let textField {
                let value = ["content", "value"].contains(textField) ? rawText : suppliedText
                guard let value, bound[textField] == nil else { throw AgentWorkspaceFailure(
                    message: "Supply the text requested by this action; its selected target cannot be replaced.") }
                args[textField] = .string(textField == "url" ? workspace.ports.tools.withWebScheme(value) : value)
            } else if suppliedText != nil { throw AgentWorkspaceFailure(message: "This action already carries its input and does not take text.") }
            if !isEffect {
                guard AgentWorkspaceEnvironment.readTools.contains(tool) else { throw AgentWorkspaceFailure(
                    message: "This operation has no repeatable reader. Nothing was run.") }
                location = .record(tool: tool, input: args, title: title)
            } else {
                effect = (tool, args, title, nil)
            }
        case .searchWeb:
            guard let suppliedText, suppliedText.count <= 2000 else { throw AgentWorkspaceFailure(
                message: "Give the web search words, up to 2000 characters.") }
            location = .record(tool: AgentWorkspaceKnowledge.webSearchTool, input: ["query": .string(suppliedText)], title: "Web search: " + suppliedText)
        case .followUpSavedReply(let reply):
            guard let suppliedText else { throw AgentWorkspaceFailure(message: "Give the follow-up message in text.") }
            let message = try await reply.message(suppliedText, perform: perform)
            effect = ("agent_message", ["agent": .string(reply.agent), "text": .string(message)],
                "Follow up: " + reply.title, reply.location)
        case .message(let agent, let conversation, let name):
            guard let suppliedText else { throw AgentWorkspaceFailure(message: "Give the message to send in text.") }
            let conversation = suppliedConversation ?? conversation
            var target: [String: JSONValue] = ["agent": .string(agent)]
            if let conversation { target["conversation"] = .string(conversation) }
            location = .record(tool: "agent_read", input: target, title: name ?? agent)
            try await navigation.navigate(location, key: key)
            if case .bool? = input["expects_reply"] { target["expects_reply"] = input["expects_reply"] }
            target["text"] = .string(suppliedText)
            result = try await perform("agent_message", target)
            saved.sent = result
        }
        if let (tool, args, title, savedReadback) = effect {
            let receipt = try await AgentWorkspaceActionReadback.dispatchEffect(tool: tool, input: args, perform: perform)
            saved.sent = receipt
            location = .receipt(tool: tool, title: title, value: AgentWorkspaceEnvironment.retained(receipt),
                readback: savedReadback ?? AgentWorkspaceEnvironment.readback(tool: tool, input: args))
            result = receipt
            if let next = try await AgentWorkspaceActionReadback.followUp(tool: tool, input: args, receipt: receipt, title: title, perform: perform) {
                location = next.location; result = next.result
            }
        }
        return .location(location, result)
    }

    /// Navigate to the selected location and read its projection or underlying record.
    private static func readWorkspaceLocation(_ location: AgentWorkspaceLocation, result: JSONValue?, workspace: WorkspaceOperation,
                                               key: String, scope: String, dataRoot: URL, navigation: AgentWorkspaceNavigation,
                                               catalog: Catalog, perform: Perform) async throws -> JSONValue {
        var location = location
        if case .page(.conversations, let page) = location { location = .conversations(page: page) }
        try await navigation.navigate(location, key: key)
        if case .home = location {
            return .string(await AgentScreen.home(workspace: workspace, dataRoot: dataRoot, scope: scope, browserPages: await navigation.browserPages(key: key)))
        }
        let source: AgentWorkspaceLocation = if case .page(let source, _) = location { source } else { location }
        var roomObservation: (world: AgentWorld, at: Date, health: Set<String>)?
        if [.area("ongoing"), .area("computer"), .area("helpers"), .area("browser"), .people(page: 0),
            .area("files"), .area("code")].contains(location)
            || { if case .conversations = location { return true }; return false }(),
           let room = await AgentScreen.room(workspace: workspace, location, dataRoot: dataRoot, scope: scope,
                                           observed: { roomObservation = ($0, $1, $2) }) {
            await AgentScreen.markRoomSeen(workspace: workspace, location, dataRoot: dataRoot, observation: roomObservation)
            return .string(room)
        }
        if case .arrivals = source {
            await navigation.refreshArrivals(workspace: workspace, key: key, scope: scope, dataRoot: dataRoot, retryUnavailable: true)
            let projection = await navigation.arrivalProjection(workspace: workspace, dataRoot: dataRoot, key: key)
            return await showWorkspaceProjection(projection, at: location, key: key, outcome: .string("ok"),
                workspace: workspace, dataRoot: dataRoot, scope: scope, navigation: navigation)
        }
        let environment: WorkspacePage?
        do { environment = try await AgentWorkspaceEnvironment.view(workspace: workspace, location: source, dataRoot: dataRoot, catalog: catalog,
            perform: perform) }
        catch {
            environment = .init(title: location.title, content: .object(["status": .string("unavailable"),
                "detail": .string("This place could not be read: " + error.localizedDescription + ". Its reference remains available; no work was resumed.")]),
                    items: [], actions: [])
        }
        if var environment {
            let outcome = AgentWorkspaceEnvironment.outcome(environment.content)
            if [JSONValue.string("unavailable"), .string("failed"), .string("error")].contains(outcome), environment.actions.isEmpty {
                environment.actions.append(.init(label: "Refresh this view", action: .open(location)))
            }
            return await showWorkspaceProjection(environment, at: location, key: key, outcome: outcome,
                workspace: workspace, dataRoot: dataRoot, scope: scope, navigation: navigation)
        }
        var result = result
        if result == nil {
          do {
            result = try await AgentWorkspaceEnvironment.read(workspace: workspace, location: source, dataRoot: dataRoot, perform: perform)
          } catch {
            result = .object(["status": .string("unavailable"),
                "detail": .string("This place could not be read: " + error.localizedDescription + ". Its reference remains available; no work was resumed.")])
          }
        }
        let value = result ?? .null
        return await renderWorkspaceRecord(value, location: location, source: source, workspace: workspace, key: key, scope: scope,
                                           dataRoot: dataRoot, navigation: navigation, roomObservation: roomObservation)
    }

    /// Bind record identities and draw the resulting view.
    private static func renderWorkspaceRecord(_ value: JSONValue, location: AgentWorkspaceLocation, source: AgentWorkspaceLocation,
                                               workspace: WorkspaceOperation, key: String, scope: String, dataRoot: URL,
                                               navigation: AgentWorkspaceNavigation,
                                               roomObservation: (world: AgentWorld, at: Date, health: Set<String>)?) async -> JSONValue {
        var location = location
        var roomObservation = roomObservation
        if case .record("browser.chrome_snapshot", let arguments, _) = location,
           case .object(let page) = value, page["ok"] != .bool(false), page["error"] == nil,
           page["snapshotId"] != nil, case .int(let tab)? = page["tabId"],
           arguments["tab_id"] == nil || arguments["tab_id"] == .int(tab),
           case .string(let title)? = page["title"], !title.isEmpty {
            var boundArguments = arguments; boundArguments["tab_id"] = .int(tab)
            let bound = AgentWorkspaceLocation.record(tool: "browser.chrome_snapshot", input: boundArguments, title: title)
            await navigation.bindCurrent(from: location, to: bound, key: key)
            location = bound
        }
        if case .record("bot_list", let arguments, _) = location, let id = arguments["id"],
           case .object(let root) = value, root["status"] == .string("ok"),
           case .array(let bots)? = root["bots"], bots.count == 1,
           case .object(let bot) = bots[0], bot["id"] == id, case .string(let name)? = bot["name"] {
            let bound = AgentWorkspaceLocation.record(tool: "bot_list", input: arguments, title: name)
            await navigation.bindCurrent(from: location, to: bound, key: key)
            location = bound
        }
        if case .record("screen", let arguments, _) = location,
           let bound = AgentWorkspaceApps.computerLocation(input: arguments, result: value) {
            await navigation.bindCurrent(from: location, to: bound, key: key)
            location = bound
        }
        if case .record(let tool, var arguments, let title) = location, tool == "agent_read",
           case .string(let agent)? = arguments["agent"], !agent.hasPrefix("bot:"),
           let row = try? workspace.ports.conversations.find(dataRoot: dataRoot, scopeSessionID: scope, agent: agent,
               label: { if case .string(let label)? = arguments["conversation"] { return label }; return nil }()) {
            arguments["conversation"] = .string(row.label)
            let bound = AgentWorkspaceLocation.record(tool: tool, input: arguments, title: title)
            await navigation.bindCurrent(from: location, to: bound, key: key)
            location = bound
        }
        if case .record("shelf_entry", let arguments, _) = location,
           case .string(let entry)? = arguments["id"], case .string(let bot)? = arguments["bot_id"] {
            let title = AgentWorkspaceSavedReply.title(value)
            let source = AgentWorkspaceSavedReply(entryID: entry, botID: bot, title: title)
            if source.evidence(value) != nil {
                await navigation.bindCurrent(from: location, to: source.location, key: key)
                location = source.location
            }
        }
        if case .record("recall_memory", let arguments, let oldTitle) = location,
           ["Memory", "Memory evidence"].contains(oldTitle),
           case .object(let memory) = value, memory["status"] == .string("ok"),
           arguments["memory_id"] != nil, memory["id"] == arguments["memory_id"] {
            let named = AgentWorkspaceLocation.record(tool: "recall_memory", input: arguments,
                title: AgentWorkspaceKnowledge.memoryTitle(memory))
            await navigation.bindCurrent(from: location, to: named, key: key)
            location = named
        }
        let evidence = AgentWorkspaceDocument.evidence(location: location, value: value)
        await navigation.rememberDocument(location: location, result: value, key: key)
        let outcome = AgentWorkspaceEnvironment.outcome(value)
        let projection: WorkspacePage
        if case .record("chat_conversations", let args, _) = source {
            projection = HumanConversationRead.project(input: args, result: value,
                observations: await navigation.observationStamps(key: key))
        } else { projection = await .project(workspace: workspace, location: location, result: value, dataRoot: dataRoot, evidence: evidence) }
        var recoveredProjection = projection
        if case .page(_, let page) = location { recoveredProjection.page = max(0, page) }
        if case .record("chat_conversations", let args, let title) = location, args["conversation_session_id"] != nil,
           title != "Conversation with you" { recoveredProjection.title = title }
        let issue: String? = {
            if readablePageOutcome(value, projection: recoveredProjection) { return nil }
            return AgentScreen.failureFace(value)
        }()
        if let room = await AgentScreen.room(workspace: workspace, location, dataRoot: dataRoot, scope: scope, issue: issue, value: value,
            projection: recoveredProjection,
                                           observed: { roomObservation = ($0, $1, $2) }) {
            _ = await navigation.observe(location: location, result: value, key: key)
            await AgentScreen.markRoomSeen(workspace: workspace, location, dataRoot: dataRoot, observation: roomObservation)
            var fields: [String: JSONValue] = if issue != nil, case .object(let row) = value { row } else { [:] }
            fields["status"] = outcome
            fields["content"] = .string(room)
            return .object(fields)
        }
        if case .record("agent_read", let args, _) = location, case .string(let agent)? = args["agent"],
           ["details", "history_before", "history_exchange"].allSatisfy({ args[$0] == nil }) {
            do {
                let sessions = try AgentWorkSession.sessions(workspace: workspace, with: agent, dataRoot: dataRoot)
                recoveredProjection.items += sessions.prefix(4).map(\.item)
                if sessions.count > 4, case .object(var content) = recoveredProjection.content {
                    content["work_sessions"] = .string("4 newest of \(sessions.count) shown; all of them are in Your conversations (open \"conversations\")")
                    recoveredProjection.content = .object(content)
                }
            } catch {
                var content = recoveredProjection.content.objectValue ?? ["result": recoveredProjection.content]
                content["work_sessions"] = .string("Unavailable: " + error.localizedDescription)
                recoveredProjection.content = .object(content)
            }
        }
        if [JSONValue.string("unavailable"), .string("failed"), .string("error")].contains(outcome), recoveredProjection.actions.isEmpty {
            recoveredProjection.actions.append(.init(label: "Refresh this view", action: .open(location)))
        }
        return await showWorkspaceProjection(recoveredProjection, at: location, key: key, outcome: outcome, value: value,
            workspace: workspace, dataRoot: dataRoot, scope: scope, navigation: navigation)
    }

    /// Draw a projection and attach any observed changes.
    private static func showWorkspaceProjection(_ projection: WorkspacePage, at place: AgentWorkspaceLocation, key: String,
                                                outcome: JSONValue, value: JSONValue? = nil, workspace: WorkspaceOperation,
                                                dataRoot: URL, scope: String, navigation: AgentWorkspaceNavigation) async -> JSONValue {
        var projection = projection
        if case .page(_, let page) = place { projection.page = max(0, page) }
        let changes: JSONValue? = if let value { await navigation.observe(location: place, result: value, key: key) } else { nil }
        if let life = await AgentScreen.lifeRoom(workspace: workspace, place, projection: projection, status: outcome, dataRoot: dataRoot, scope: scope) {
            return .object(["status": outcome, "content": .string(life)])
        }
        let room = AgentScreen.textRoomName(place) ?? "items"
        let text = AgentScreen.textRoom(workspace: workspace, room, place: place, projection: projection, status: outcome, dataRoot: dataRoot, scope: scope)
        if case .area = place { AgentWorkspaceScreenPreview.keep(room: room, text: text, dataRoot: dataRoot) }
        if AgentScreen.textRoomName(place) == nil {
            var frame: [String: JSONValue] = ["status": outcome, "content": projection.content, "view": .string(text)]
            if let changes { frame["changes"] = changes }
            return .object(frame)
        }
        return .object(["status": outcome, "content": .string(text)])
    }

    private static func readablePageOutcome(_ value: JSONValue, projection: WorkspacePage) -> Bool {
        let reply = ToolResult(value)
        return reply.hasReadEvidence(completeOnly: true) || (reply.hasReadEvidence() && !projection.items.isEmpty)
    }

}
