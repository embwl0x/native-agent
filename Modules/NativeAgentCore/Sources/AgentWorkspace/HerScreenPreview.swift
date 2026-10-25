import Foundation
import NativeAgentCore
import NativeAgentShared
import PersistenceCore
// Blueprint: | `HerScreenPreview.swift` | shared screen/room text projection |

/// User's window into her shared glance and room renderers. Preview home omits
/// retained workspace window titles. Names resolve as her workspace resolves
/// them. Nothing marks seen, writes a name or remembers a verb, and no tool
/// runs: an owner-read place shows its last copy, or says what it would read.
package enum AgentWorkspaceScreenPreview {
    public static let didChange = Notification.Name("NativeAgent.herWorldDidChange")
    /// Home, then every place home's PLACES rows show, in order, then the
    /// rooms home's own sections and footer open.
    public static func tabs(_ layout: SurfaceLayout, profile: String?) -> [String] {
        var names = ["home"]
        for name in (layout.shown("places", profile: profile).map(\.name) + ["people", "helpers", "mac", "conversations", "windows", "arrivals", "work"]).map(AppDoorNames.resolve)
            where !names.contains(name) { names.append(name) }
        return names
    }

    /// What home, rooms and the glance read, relative to the data root.
    public static let watchedPaths = [
        "agents/peers.json", "agents/conversations.json", "agents/grok-requests", "agents/resident-wake.json", "chat/sessions.json",
        "desk/desk_ops.jsonl", "desk/desk_ops_base.json", "workshop/executions", "bots/definitions",
        "bots/shelf-index.json", "bots/run-queue.json", "workflows/approvals/requests.json",
        "memory/memory.sqlite", "memory/memory.sqlite-wal", "memory/profile.json", "swarms/live.json", "swarms/runs.json",
        "her_screen/last_seen.json", "her_screen/touched.json",
        "abilities",
        // Home's sections and places in the layout's order.
        "ui/layout.json",
    ]

    /// The glance as a turn renders it, without a turn's pin or budget.
    public static func glance(dataRoot: URL, scope: String) async -> String? {
        if scope.hasPrefix("bot-") { return nil }
        return await HerScreen.$previewing.withValue(true) {
            let now = Date()
            async let parts = AgentWorkspacePorts.parts(for: "", dataRoot: dataRoot)
            let home = await HerScreen.renderGlance(dataRoot: dataRoot, scope: scope.isEmpty ? nil : scope, now: now)
            return await [home, parts].compactMap { $0 }.joined(separator: "\n")
        }
    }

    public static func render(_ room: String, dataRoot: URL, scope: String) async -> String {
        await AgentWorkspaceReadiness.withSnapshot(dataRoot: dataRoot) {
            await HerScreen.$previewing.withValue(true) { await look(room, dataRoot: dataRoot, scope: scope) }
        }
    }

    private static func look(_ room: String, dataRoot: URL, scope: String) async -> String {
        let navigation = AgentWorkspaceNavigation.shared
        let key = dataRoot.standardizedFileURL.path + "\u{0}" + scope
        let pages = await navigation.browserPages(key: key)
        if room == "home" { return await HerScreen.home(dataRoot: dataRoot, scope: scope, browserPages: pages, markSeen: false) }
        let schemas = lock.withLock { catalogs[dataRoot.standardizedFileURL.path] }
        let catalog: AgentWorkspace.Catalog = { schemas ?? [] }
        let noCatalog = room.uppercased() + " · laid out from the tools her chat offers. She hasn't opened a place since the app started, so this view has no tool list to show it from."

        let target = await HerScreen.resolve(room, dataRoot: dataRoot, scope: scope, browserPages: pages,
                                            openPlaces: await navigation.places(key: key), currentPlace: await navigation.current(key: key))
        let location: AgentWorkspaceLocation
        switch target {
        case .page(let text)?: return text
        case .action(.window(.open(let place)))?, .action(.open(let place))?: location = place
        case .action?: return room.uppercased() + " · opens as an action, not a room."
        case nil:
            guard HerScreen.families.contains(where: { $0.name == AppDoorNames.resolve(room) }) else { return room.uppercased() + " · not a name her workspace opens." }
            guard schemas != nil else { return noCatalog }
            do { return try await HerScreen.familyRoom(room, catalog: catalog) ?? noCatalog } catch {
                return room.uppercased() + " · couldn't read the tool list: \(error.localizedDescription)"
            }
        }

        // Her own rooms: no owner read comes first.
        if let text = await HerScreen.room(location, dataRoot: dataRoot, scope: scope) { return text }
        var projection: AgentWorkspaceProjection
        switch location {
        case .arrivals: projection = await navigation.arrivalProjection(key: key)
        case .openPlaces: projection = await navigation.openPlaces(key: key)
        case .workOverview: projection = await navigation.workOverview(key: key)
        case .area(let id):
            guard let place = AgentWorkspaceEnvironment.destinations.first(where: { $0.id == id }) else { return room.uppercased() + " · no such place." }
            // A place whose opening runs its owner's read: her last copy.
            let reads = id == "today" || place.tool.map { tool in
                place.searchField == nil && AgentWorkspaceEnvironment.readTools.contains(tool) && schemas?.contains { $0.name == tool } != false
            } ?? false
            let what = place.tool ?? place.tools.joined(separator: " + ")
            guard !reads else { return shown(room, dataRoot: dataRoot, tool: what) }
            guard schemas != nil else { return noCatalog }
            do {
                guard let view = try await AgentWorkspaceEnvironment.view(location: location, dataRoot: dataRoot, catalog: catalog,
                                                                          perform: { _, _ in throw CancellationError() })  // it runs no tool
                else { return room.uppercased() + " · no such place." }
                projection = view
            } catch { return shown(room, dataRoot: dataRoot, tool: what) }
        default: return room.uppercased() + " · opens with an owner read this view does not run."
        }
        let outcome = AgentWorkspaceEnvironment.outcome(projection.content)
        if [JSONValue.string("unavailable"), .string("failed"), .string("error")].contains(outcome), projection.actions.isEmpty {
            projection.actions.append(.init(label: "Refresh this view", action: .open(location)))
        }
        let name = HerScreen.textRoomName(location) ?? room
        return HerScreen.textRoom(name, place: location, projection: projection, frame: .object(["status": outcome]), dataRoot: dataRoot)
    }

    private static func shown(_ room: String, dataRoot: URL, tool: String) -> String {
        guard let kept = lock.withLock({ rooms[dataRoot.standardizedFileURL.path + "\u{0}" + room] }) else {
            return room.uppercased() + " · opens with \(tool), her own tool read through its gates and receipts. This view runs no tool, "
                + "and she hasn't opened \(room) since the app started, so there is no copy to show."
        }
        return "(as she last saw it, \(HerScreen.age(Date().timeIntervalSince(kept.at))) ago; opening it runs \(tool) again)\n\n" + kept.text
    }

    // MARK: What her workspace last showed, in memory only

    private static let lock = NSLock()
    nonisolated(unsafe) private static var catalogs: [String: [LLMToolSchema]] = [:]
    nonisolated(unsafe) private static var rooms: [String: (text: String, at: Date)] = [:]

    static func keep(catalog: [LLMToolSchema], dataRoot: URL) {
        lock.withLock { catalogs[dataRoot.standardizedFileURL.path] = catalog }
    }

    static func keep(room: String, text: String, dataRoot: URL) {
        lock.withLock { rooms[dataRoot.standardizedFileURL.path + "\u{0}" + room] = (text, Date()) }
    }
}
