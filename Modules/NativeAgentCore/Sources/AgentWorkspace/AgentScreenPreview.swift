import Foundation
import Synchronization
import NativeAgentCore
import NativeAgentShared
import PersistenceCore
import Transcripts
// Blueprint: | `AgentScreenPreview.swift` | shared screen/room text projection |

/// The user's Agent view must not mark seen, mint names, remember verbs or run tools; owner-read places expose only their retained copies.
package enum AgentWorkspaceScreenPreview {
    public static let didChange = Notification.Name("NativeAgent.agentWorldDidChange")
    /// Keep preview order aligned with Home's layout.
    public static func tabs(_ layout: SurfaceLayoutAvailability, profile: String?) -> [String] {
        var names = ["home"]
        for name in (layout.contentNames("places", profile: profile) + ["people", "helpers", "mac", "conversations", "windows", "arrivals", "work"]).map(
            AppDoorNames.resolve)
            where !names.contains(name) { names.append(name) }
        return names
    }

    public static let watchedPaths = [
        "agents/peers.json", "agents/conversations.json", "agents/grok-requests", "chat/sessions.json",
        "desk/desk_ops.jsonl", "desk/desk_ops_base.json", "bots/definitions",
        "bots/shelf-index.json", "bots/run-queue.json", "workflows/approvals/requests.json",
        "memory/memory.sqlite", "memory/memory.sqlite-wal", "memory/profile.json", "agents/jobs.json",
        "her_screen/last_seen.json", "her_screen/touched.json",
        "ui/layout.json",
    ]

    /// Render the glance without a turn's pin or budget.
    package static func glance(workspace: WorkspaceOperation, dataRoot: URL, scope: String) async -> String? {
        do { if try SessionConversation.checkedIsHelper(scope, dataRoot: dataRoot) { return nil } }
        catch { return "Conversation ownership unavailable: \(error.localizedDescription). Repair the saved session index before reading this room." }
        let workspace = workspace.preview()
        let now = Date()
        async let parts = AgentWorkspacePorts.parts(for: "", dataRoot: dataRoot, turn: workspace.turn)
        let home = await AgentScreen.renderGlance(workspace: workspace, dataRoot: dataRoot, scope: scope.isEmpty ? nil : scope, now: now)
        return await [home, parts.text].compactMap { $0 }.joined(separator: "\n")
    }

    package static func render(workspace: WorkspaceOperation, _ room: String, dataRoot: URL, scope: String) async -> String {
        await AgentWorkspaceReadiness.withSnapshot(workspace: workspace.preview(), dataRoot: dataRoot) { workspace in
            await look(workspace: workspace, room, dataRoot: dataRoot, scope: scope)
        }
    }

    private static func look(workspace: WorkspaceOperation, _ room: String, dataRoot: URL, scope: String) async -> String {
        let navigation = AgentWorkspaceNavigation.shared
        let key = dataRoot.standardizedFileURL.path + "\u{0}" + scope
        let pages = await navigation.browserPages(key: key)
        if room == "home" { return await AgentScreen.home(workspace: workspace, dataRoot: dataRoot, scope: scope, browserPages: pages, markSeen: false) }
        let schemas = cache.withLock { $0.catalogs[dataRoot.standardizedFileURL.path] }
        let catalog: AgentWorkspace.Catalog = { schemas ?? [] }
        let noCatalog = room.uppercased()
            + " · laid out from the tools the agent's chat offers. The agent hasn't opened a place since the app started,"
            + " so this view has no tool list to show it from."

        let target = await AgentScreen.resolve(workspace: workspace, room, dataRoot: dataRoot, scope: scope, browserPages: pages,
                                            openPlaces: await navigation.places(key: key), currentPlace: await navigation.current(key: key))
        let location: AgentWorkspaceLocation
        switch target {
        case .page(let text)?: return text
        case .action(.window(.open(let place)))?, .action(.open(let place))?: location = place
        case .action?: return room.uppercased() + " · opens as an action, not a room."
        case nil:
            guard AgentScreen.families.contains(where: { $0.name == AppDoorNames.resolve(room) }) else { return room.uppercased()
                + " · not a name the agent's workspace opens." }
            guard schemas != nil else { return noCatalog }
            do { return try await AgentScreen.familyRoom(workspace: workspace, room, catalog: catalog) ?? noCatalog } catch {
                return room.uppercased() + " · couldn't read the tool list: \(error.localizedDescription)"
            }
        }

        if let text = await AgentScreen.room(workspace: workspace, location, dataRoot: dataRoot, scope: scope) { return text }
        var projection: WorkspacePage
        switch location {
        case .arrivals: projection = await navigation.arrivalProjection(workspace: workspace, key: key)
        case .openPlaces: projection = await navigation.openPlaces(key: key)
        case .workOverview: projection = await navigation.workOverview(key: key)
        case .area(let id):
            guard let place = AgentWorkspaceEnvironment.destinations.first(where: { $0.id == id }) else { return room.uppercased() + " · no such place." }
            // Owner-read places expose their retained copy.
            let reads = id == "today" || place.tool.map { tool in
                place.searchField == nil && AgentWorkspaceEnvironment.readTools.contains(tool) && schemas?.contains { $0.name == tool } != false
            } ?? false
            let what = place.tool ?? place.tools.joined(separator: " + ")
            guard !reads else { return shown(room, dataRoot: dataRoot, tool: what) }
            guard schemas != nil else { return noCatalog }
            do {
                guard let view = try await AgentWorkspaceEnvironment.view(workspace: workspace, location: location, dataRoot: dataRoot, catalog: catalog,
                                                                          perform: { _, _ in throw CancellationError() })
                else { return room.uppercased() + " · no such place." }
                projection = view
            } catch { return shown(room, dataRoot: dataRoot, tool: what) }
        default: return room.uppercased() + " · opens with an owner read this view does not run."
        }
        let outcome = AgentWorkspaceEnvironment.outcome(projection.content)
        if [JSONValue.string("unavailable"), .string("failed"), .string("error")].contains(outcome), projection.actions.isEmpty {
            projection.actions.append(.init(label: "Refresh this view", action: .open(location)))
        }
        let name = AgentScreen.textRoomName(location) ?? room
        return AgentScreen.textRoom(workspace: workspace, name, place: location, projection: projection, status: outcome, dataRoot: dataRoot)
    }

    private static func shown(_ room: String, dataRoot: URL, tool: String) -> String {
        guard let kept = cache.withLock({ $0.rooms[dataRoot.standardizedFileURL.path + "\u{0}" + room] }) else {
            return room.uppercased() + " · opens with \(tool), the agent's own tool read through its gates and receipts. This view runs no tool, "
                + "and the agent hasn't opened \(room) since the app started, so there is no copy to show."
        }
        return "(the view as last read, \(AgentScreen.age(Date().timeIntervalSince(kept.at))) ago; opening it runs \(tool) again)\n\n" + kept.text
    }

    // MARK: What the agent's workspace last showed, in memory only

    private static let cache = Mutex<(catalogs: [String: [LLMToolSchema]], rooms: [String: (text: String, at: Date)])>(([:], [:]))

    static func keep(catalog: [LLMToolSchema], dataRoot: URL) {
        cache.withLock { $0.catalogs[dataRoot.standardizedFileURL.path] = catalog }
    }

    static func keep(room: String, text: String, dataRoot: URL) {
        cache.withLock { $0.rooms[dataRoot.standardizedFileURL.path + "\u{0}" + room] = (text, Date()) }
    }
}
