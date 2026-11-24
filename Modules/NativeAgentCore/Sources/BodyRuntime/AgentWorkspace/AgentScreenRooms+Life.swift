import Foundation
import MacNerves
import PersistenceCore
// Blueprint: | `AgentScreenRooms+Life.swift` | `workspace-readout.js`, `lifeRoom`, `opening`, `AgentItemPages`: named owner actions and readback |

enum AgentWorkspaceLife {
    static let destinations: [AgentWorkspaceDestination] = [
        .init(id: "music", title: "Music", summary: "What's playing, playback, playlists and the library.", tool: "music.now_playing"),
    ]

    static let readTools: Set<String> = [
        "music.now_playing", "music.search", "music.playlists", "music.library",
    ]

    static func room(for tool: String) -> String? {
        if tool == "mac_reminders_read" { return nil }
        if tool.hasPrefix("mac_calendar_") { return "calendar" }
        if tool.hasPrefix("mac_reminders_") { return "reminders" }
        return tool.hasPrefix("music.") ? "music" : nil
    }

    static func project(workspace: WorkspaceOperation, tool: String, input: [String: JSONValue], result: JSONValue, dataRoot: URL) async -> WorkspacePage {
        let row = object(result)
        var native: [String: JSONValue] = ["status": row["status"] ?? (row["ok"] == .bool(false) ? .string("failed") : .string("ok"))]
        for key in ["connected", "detail", "fix", "reason", "failure_code", "error_code", "effects", "remedy", "hint", "next_call", "tap"] {
            native[key] = row[key] }
        if problem(row) != nil {
            native = row
            if native["status"] == nil { native["status"] = .string("failed") }
        }
        let required = ["music.search":"results","music.library":"tracks","music.playlists":"playlists"][tool]
        if let required, row[required]?.arrayValue == nil, problem(native) == nil, native["error"] == nil {
            native["status"] = .string("unavailable")
            native["error"] = .string("Music source did not supply its " + required + " array.")
        }
        if ["music.now_playing", "music.control"].contains(tool), problem(native) == nil, native["error"] == nil {
            let playback = tool == "music.control" ? row["now_playing"]?.objectValue : result.objectValue
            let track = playback?["track"]
            let explicitTrack = track == .null || track?.objectValue?["name"]?.trimmedString != nil
            if let failure = playback.flatMap(problem) {
                native["status"] = .string("failed")
                native["message"] = .string("Couldn't read what's playing: " + failure)
                native["source"] = result
            } else if playback?["playerState"]?.stringValue == nil || !explicitTrack {
                native["status"] = .string("unavailable")
                native["error"] = .string("Music source did not supply a playback state and explicit track.")
                native["source"] = result
            }
        }
        var items: [String: AgentWorkspaceItem] = [:], actions: [String: AgentWorkspaceButton] = [:]
        let tracks = array(row["results"]) + array(row["tracks"])
        for (index,value) in tracks.enumerated() {
            let track = object(value), key = "track:" + String(index)
            if let name = track["name"]?.trimmedString {
                items[key] = .init(title:name,content:.object(["who":track["artist"] ?? .null,"summary":track["album"] ?? .null]),actions:[])
                actions[key+":play"] = effect("play",tool:"music.control",input:["action":.string("play"),"track":.string(name),"artist":track["artist"]
                    ?? .string("")])
            }
        }
        for (index,value) in array(row["playlists"]).enumerated() {
            let list = object(value), key = "playlist:" + String(index)
            if let name = list["name"]?.trimmedString {
                items[key] = .init(title:name,content:value,actions:[])
                actions[key+":play"] = effect("play",tool:"music.control",input:["action":.string("play"),"playlist":.string(name)])
            }
        }
        for verb in ["play","pause","stop","next","previous"] { actions[verb] = effect(verb,tool:"music.control",input:["action":.string(verb)]) }
        actions["playlist"] = typed("playlist",tool:"music.control",input:["action":.string("play")],field:"playlist",effect:true)
        actions["track"] = typed("track",tool:"music.control",input:["action":.string("play")],field:"track",effect:true)
        actions["find"] = typed("find",tool:"music.search",field:"query")
        actions["playlists"] = read("playlists",tool:"music.playlists",input:["limit":.int(24)])
        let failed = problem(native) != nil || native["error"] != nil
        return await WorkspaceReadout.project(workspace: workspace, input:.object(["mode":.string("music"),"tool":.string(tool),"state":.string(
            failed ? "unavailable" : "available"),
            "result":result,"failed":.bool(failed)]),dataRoot:dataRoot,items:items,actions:actions,native:native)
    }

    static func problem(_ row: [String: JSONValue]) -> String? {
        let reply = ToolResult(.object(row))
        guard !reply.hasReadEvidence() else { return nil }
        return AgentScreen.failureFace(.object(row))
    }

    private static func read(_ label: String, tool: String, input: [String: JSONValue] = [:], title: String? = nil) -> AgentWorkspaceButton {
        .init(label: label, action: .open(.record(tool: tool, input: input, title: title ?? label)))
    }

    private static func typed(_ label: String, tool: String, input: [String: JSONValue] = [:], field: String?, effect: Bool = false) -> AgentWorkspaceButton {
        .init(label: label, action: .perform(tool: tool, input: input, title: label, textField: field, isEffect: effect), needsText: field != nil)
    }

    private static func effect(_ label: String, tool: String, input: [String: JSONValue]) -> AgentWorkspaceButton {
        .init(label: label, action: .perform(tool: tool, input: input, title: label, textField: nil, isEffect: true))
    }

    static func object(_ value: JSONValue) -> [String: JSONValue] { value.objectValue ?? [:] }
    private static func array(_ value: JSONValue?) -> [JSONValue] { value?.arrayValue ?? [] }
}

extension AgentScreen {
    package static func notedLifeRead(_ name: String, _ result: JSONValue, dataRoot: URL) -> JSONValue {
        let row = AgentWorkspaceLife.object(result)
        guard row["status"] == .string("completed"), case .int(let count)? = row["count"] else { return result }
        if name == "calendar", row["day"] == .string("today"), case .string(let start)? = row["rangeStart"] {
            AgentReadBadges.shared.note(name, "\(count) in day beginning " + start, dataRoot: dataRoot)
        }
        if name == "reminders", row["includeCompleted"] == .bool(false),
           case .string(let start)? = row["due_start"],
           case .int(let due)? = row["today"]?.objectValue?["count"],
           case .int(let overdue)? = row["overdue"]?.objectValue?["count"] {
            AgentReadBadges.shared.note(name, "Due day beginning " + start + ": \(due) · earlier: \(overdue)", dataRoot: dataRoot)
        }
        return result
    }

    static func lifeRoom(workspace: WorkspaceOperation, _ place: AgentWorkspaceLocation, projection: WorkspacePage, status: JSONValue, dataRoot: URL,
        scope: String) async -> String? {
        let tool: String, receipt: JSONValue?
        var shown = projection
        switch place {
        case .record(let name, _, _):
            tool = name
            receipt = AgentWorkspaceLife.object(projection.content)["action_receipt"]
        case .receipt(let name, _, let value, _):
            tool = name; receipt = value
            if AgentWorkspaceLife.room(for: name) == "music" { shown = await AgentWorkspaceLife.project(workspace: workspace, tool: name, input: [:],
                result: value,
                dataRoot: dataRoot) }
        case .page(let inner, _):
            return await lifeRoom(workspace: workspace, inner, projection: projection, status: status, dataRoot: dataRoot, scope: scope)
        default: return nil
        }
        guard let room = AgentWorkspaceLife.room(for: tool) else { return nil }
        if case .receipt = place, tool.hasPrefix("mac_") { return nil }
        let readStatus = tool == "music.control" ? (AgentWorkspaceLife.object(shown.content)["status"] ?? status) : status
        var lines = textRoom(workspace: workspace, room, place: place, projection: shown, status: readStatus, dataRoot: dataRoot, scope: scope).components(
            separatedBy: "\n")
        if let receipt {
            let row = AgentWorkspaceLife.object(receipt)
            let what = ["title", "action_performed", "playlist", "track"].lazy.compactMap { key -> String? in
                if case .string(let text)? = row[key], !text.isEmpty { return text } else { return nil }
            }.first
            let reply = ToolResult(receipt)
            let outcome = reply.outcome
            let label: String, said: String
            switch outcome {
            case .succeeded:
                label = "DONE"; said = "✓ " + (what.map { "done: " + $0 } ?? "done")
            case .failed, .refused, .cancelled, .timeout:
                label = "RESULT"; said = failureFace(receipt)
            case .unknown:
                label = "STATUS"
                said = failureFace(receipt)
            }
            lines.insert(pad(label, 10) + (outcome == .succeeded ? clip(said, 100) : said), at: min(1, lines.count))
        }
        if ["mac_calendar_calendars", "mac_calendar_free_busy"].contains(tool) {
            let details: JSONValue = if !shown.items.isEmpty {
                .array(shown.items.dropFirst(shown.page * 8).prefix(8).map(\.content))
            } else { shown.content }
            if let text = try? details.serialize(pretty: true) { lines.append("Calendar details:\n" + text) }
        }
        return lines.joined(separator: "\n")
    }
}

extension AgentScreen {
    static func opening(_ action: AgentWorkspaceAction) -> Bool {
        switch action {
        case .open(.record("app", let input, _)) where input["find"] != nil: return false
        case .open, .openArrival: return true
        case .perform(_, _, _, _, let isEffect): return !isEffect
        default: return false
        }
    }
}

final class AgentItemPages: Sendable {
    static let shared = AgentItemPages()
    private let cache = AgentRoomCache<String>(lasting: true)

    func keep(_ root: URL, _ pages: [String: String], room: String? = nil, scope: String? = nil) {
        cache.keep(root, pages, room: room, scope: scope)
    }

    func page(_ root: URL, _ name: String) -> String? {
        cache.value(root, name)
    }

    func removeSession(_ key: String) { cache.removeSession(key) }
}
