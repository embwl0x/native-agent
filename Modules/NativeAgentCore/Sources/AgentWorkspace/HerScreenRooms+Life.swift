import Foundation
import PersistenceCore
import ChatSessionWork
// Blueprint: | `HerScreenRooms+Life.swift` | Native Music target bindings, status/unavailable evidence and rendering; playback narration, track/playlist curation and action labels are removed to `workspace-readout.js`; `lifeRoom` presents a failed nested Music readback with its full cause while retaining the original control receipt on its separate DONE line; `lifePulse`, `opening`; `HerItemPages` caches text without read-side peer lists |

/// Music opens by name like any place (`music`).
/// Each is its owner's own read laid out by the shared text room; opening
/// one runs that read on demand, home never does. Calendar and reminders were
/// already places; their changes now come back as the same text room.
enum AgentWorkspaceLife {
    static let destinations: [AgentWorkspaceDestination] = [
        .init(id: "music", title: "Music", summary: "What's playing, playback, playlists and the library.", tool: "music_now_playing"),
    ]

    static let readTools: Set<String> = [
        "music_now_playing", "music_search_library", "music_list_playlists", "music_list_library",
    ]

    /// The room a tool's reads and receipts show in; nil keeps the old frame.
    /// Detail reads keep their full frame; a room would clip their contents.
    static func room(for tool: String) -> String? {
        if tool == "mac_reminders_read" { return nil }
        if tool.hasPrefix("mac_calendar_") { return "calendar" }
        if tool.hasPrefix("mac_reminders_") { return "reminders" }
        return tool.hasPrefix("music_") ? "music" : nil
    }

    static func project(tool: String, input: [String: JSONValue], result: JSONValue, dataRoot: URL) async -> WorkspacePage {
        let row = object(result)
        var native: [String: JSONValue] = ["status": row["status"] ?? (row["ok"] == .bool(false) ? .string("failed") : .string("ok"))]
        for key in ["connected", "detail", "fix", "reason", "failure_code", "error_code", "effects", "remedy", "hint", "next_call", "tap"] { native[key] = row[key] }
        if problem(row) != nil {
            native = row
            if native["status"] == nil { native["status"] = .string("failed") }
        }
        let required = ["music_search_library":"results","music_list_library":"tracks","music_list_playlists":"playlists"][tool]
        if let required, row[required]?.arrayValue == nil, problem(native) == nil, native["error"] == nil {
            native["status"] = .string("unavailable")
            native["error"] = .string("Music source did not supply its " + required + " array.")
        }
        if ["music_now_playing", "music_control"].contains(tool), problem(native) == nil, native["error"] == nil {
            let playback = tool == "music_control" ? row["now_playing"]?.objectValue : result.objectValue
            let track = playback?["track"]
            let explicitTrack = track == .null || text(track?.objectValue?["name"]) != nil
            if let failure = playback.flatMap(problem) {
                // The read failed; the original control receipt still owns
                // its separate DONE line in lifeRoom.
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
            if let name = text(track["name"]) {
                items[key] = .init(title:name,content:.object(["who":track["artist"] ?? .null,"summary":track["album"] ?? .null]),actions:[])
                actions[key+":play"] = effect("play",tool:"music_control",input:["action":.string("play"),"track":.string(name),"artist":track["artist"] ?? .string("")])
            }
        }
        for (index,value) in array(row["playlists"]).enumerated() {
            let list = object(value), key = "playlist:" + String(index)
            if let name = text(list["name"]) {
                items[key] = .init(title:name,content:value,actions:[])
                actions[key+":play"] = effect("play",tool:"music_control",input:["action":.string("play"),"playlist":.string(name)])
            }
        }
        for verb in ["play","pause","stop","next","previous"] { actions[verb] = effect(verb,tool:"music_control",input:["action":.string(verb)]) }
        actions["playlist"] = typed("playlist",tool:"music_control",input:["action":.string("play")],field:"playlist",effect:true)
        actions["track"] = typed("track",tool:"music_control",input:["action":.string("play")],field:"track",effect:true)
        actions["find"] = typed("find",tool:"music_search_library",field:"query")
        actions["playlists"] = read("playlists",tool:"music_list_playlists",input:["limit":.int(24)])
        let failed = problem(native) != nil || native["error"] != nil
        return await WorkspaceReadout.project(input:.object(["mode":.string("music"),"tool":.string(tool),"state":.string(failed ? "unavailable" : "available"),
            "result":result,"failed":.bool(failed)]),dataRoot:dataRoot,items:items,actions:actions,native:native)
    }

    /// The one sentence that says why a read or change did not work.
    static func problem(_ row: [String: JSONValue]) -> String? {
        guard !ChatToolOutcome.hasReadEvidence(.object(row)) else { return nil }
        return HerScreen.failureFace(.object(row))
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
    private static func text(_ value: JSONValue?) -> String? {
        guard let text = value?.stringValue else { return nil }
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }
}

extension HerScreen {
    /// Passes the owner read through while retaining its same-day badge.
    package static func notedLifeRead(_ name: String, _ result: JSONValue, dataRoot: URL) -> JSONValue {
        let row = AgentWorkspaceLife.object(result)
        guard row["status"] == .string("completed"), case .int(let count)? = row["count"] else { return result }
        if name == "calendar", row["day"] == .string("today") { HerReadBadges.shared.note(name, "\(count) today", dataRoot: dataRoot) }
        if name == "reminders", row["includeCompleted"] == .bool(false), case .string(let summary)? = row["summary"] {
            HerReadBadges.shared.note(name, summary, dataRoot: dataRoot)
        }
        return result
    }

    /// A read or a change in a life room as that room's text, with what the
    /// change did on the line under the header. Nil leaves the frame to the caller.
    static func lifeRoom(_ place: AgentWorkspaceLocation, projection: WorkspacePage, status: JSONValue, dataRoot: URL, scope: String) async -> String? {
        let tool: String, receipt: JSONValue?
        var shown = projection
        switch place {
        case .record(let name, _, _):
            tool = name
            receipt = AgentWorkspaceLife.object(projection.content)["action_receipt"]
        case .receipt(let name, _, let value, _):
            tool = name; receipt = value
            if AgentWorkspaceLife.room(for: name) == "music" { shown = await AgentWorkspaceLife.project(tool: name, input: [:], result: value, dataRoot: dataRoot) }
        case .page(let inner, _):
            return await lifeRoom(inner, projection: projection, status: status, dataRoot: dataRoot, scope: scope)
        default: return nil
        }
        guard let room = AgentWorkspaceLife.room(for: tool) else { return nil }
        // A calendar or reminder change keeps its receipt frame unless
        // its list was read back (the record carries the receipt).
        if case .receipt = place, tool.hasPrefix("mac_") { return nil }
        let readStatus = tool == "music_control" ? (AgentWorkspaceLife.object(shown.content)["status"] ?? status) : status
        var lines = textRoom(room, place: place, projection: shown, status: readStatus, dataRoot: dataRoot, scope: scope).components(separatedBy: "\n")
        if let receipt {
            let row = AgentWorkspaceLife.object(receipt)
            let what = ["title", "action_performed", "playlist", "track"].lazy.compactMap { key -> String? in
                if case .string(let text)? = row[key], !text.isEmpty { return text } else { return nil }
            }.first
            let outcome = ChatToolOutcome.exactResultClass(receipt)
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

    /// "calendar: 2 today · 3h" from the latest read today, else the bare name.
    static func lifePulse(_ name: String, dataRoot: URL, now: Date = Date()) -> String {
        guard let seen = HerReadBadges.shared.latest(name, dataRoot: dataRoot), Calendar.current.isDate(seen.at, inSameDayAs: now) else { return name }
        return name + ": " + seen.words + " · " + age(now.timeIntervalSince(seen.at))
    }
}

extension HerScreen {
    /// Whether doing an action only opens something (a place, a read, a form).
    static func opening(_ action: AgentWorkspaceAction) -> Bool {
        switch action {
        case .open, .window, .configure, .openArrival: return true
        case .perform(_, _, _, _, let isEffect): return !isEffect
        default: return false
        }
    }
}

/// A row that would act when named (`reminders.3`) opens as this short page
/// of its verbs instead, as long as her names last (`HerRoomCache`).
final class HerItemPages: @unchecked Sendable {
    static let shared = HerItemPages()
    struct Page: Sendable { let text: String; let speech: [ContactThread.Line] }
    private let cache = HerRoomCache<Page>(lasting: true)

    func keep(_ root: URL, _ pages: [String: String], room: String? = nil, scope: String? = nil,
              speech: [String: [ContactThread.Line]] = [:]) {
        cache.keep(root, Dictionary(uniqueKeysWithValues: pages.map {
            ($0.key, Page(text: $0.value, speech: speech[$0.key] ?? []))
        }), room: room, scope: scope)
    }

    func page(_ root: URL, _ name: String) -> String? {
        guard let page = cache.value(root, name) else { return nil }
        if !HerScreen.previewing {
            for row in page.speech { ContactThread.consume(row, mark: { peer, _ in AgentWorkspacePorts.current.tools.markConsumed(peer: peer) }) }
        }
        return page.text
    }

    func removeSession(_ key: String) { cache.removeSession(key) }
}
