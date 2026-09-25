import Foundation
import PersistenceCore

/// Her life rooms (2026-09-24): music, markets, X, Slack, Notion and Google
/// Calendar open by name like any place (`music`, `x.search`, `markets.2`).
/// Each is its owner's own read laid out by the shared text room; opening
/// one runs that read on demand, home never does. Calendar and reminders were
/// already places; their changes now come back as the same text room.
enum AgentWorkspaceLife {
    static let destinations: [AgentWorkspaceDestination] = [
        .init(id: "music", title: "Music", summary: "What's playing, playback, playlists and the library.", tool: "music_now_playing"),
        .init(id: "markets", title: "Markets", summary: "Watchlists and live quotes. Read-only; nothing trades.", tool: "market_watchlists", input: ["includeSymbols": .bool(false)]),
        .init(id: "x", title: "X", summary: "X in Chrome first; the paid X API only as a fallback.", tool: nil),
        .init(id: "slack", title: "Slack", summary: "Channels, message search, and a post staged for approval.", tool: "slack_status"),
        .init(id: "notion", title: "Notion", summary: "Search and read pages shared with the integration.", tool: "notion_search", input: ["limit": .int(8)]),
        .init(id: "gcal", title: "Google Calendar", summary: "The primary Google Calendar, next seven days.", tool: "google_calendar_list", input: ["limit": .int(16)]),
    ]

    static let readTools: Set<String> = [
        "music_now_playing", "music_search_library", "music_list_playlists", "music_list_library",
        "market_status", "market_watchlists", "tradingview_watchlist", "market_quote",
        "x_status", "x_me", "x_search", "x_timeline", "x_user_tweets",
        "slack_status", "slack_list_channels", "slack_search_messages",
        "notion_status", "notion_search", "notion_read_page", "google_calendar_status", "google_calendar_list",
    ]

    /// The room a tool's reads and receipts show in; nil keeps the old frame.
    /// A Notion page stays a frame: its text is the point and a room clips it.
    static func room(for tool: String) -> String? {
        if tool == "notion_read_page" { return nil }
        if tool.hasPrefix("mac_calendar_") { return "calendar" }
        if tool.hasPrefix("mac_reminders_") { return "reminders" }
        for (prefix, room) in [("music_", "music"), ("market_", "markets"), ("tradingview_", "markets"), ("x_", "x"),
                               ("slack_", "slack"), ("notion_", "notion"), ("google_calendar_", "gcal")] where tool.hasPrefix(prefix) {
            return room
        }
        return nil
    }

    static func project(tool: String, input: [String: JSONValue], result: JSONValue) -> AgentWorkspaceProjection? {
        guard room(for: tool) != nil, !tool.hasPrefix("mac_") else { return nil }
        let row = object(result)
        var content: [String: JSONValue] = ["status": row["status"] ?? (row["ok"] == .bool(false) ? .string("failed") : .string("ok"))]
        if let problem = problem(row) { content["error"] = .string(problem) }
        // A connection card reads the same as the other rooms' (comms): one line.
        if row["needs"] != nil, row["kind"] == .string("connector") {
            content["error"] = .string((destinations.first { $0.id == room(for: tool) }?.title ?? "It") + " not connected"
                + (tool.hasPrefix("notion") ? ", so nothing was searched" : ", so nothing was read")
                + " — request_interaction (kind connector) puts the connect card in this chat; or the person opens Settings (the gear, bottom-left), then Connectors.")
        }
        var items: [AgentWorkspaceItem] = [], actions: [AgentWorkspaceButton] = []
        switch tool {
        case "music_now_playing", "music_control", "music_search_library", "music_list_playlists", "music_list_library":
            let now = tool == "music_control" ? object(row["now_playing"] ?? .null) : row
            if tool == "music_now_playing" || tool == "music_control", content["error"] == nil { content["message"] = .string(playing(now)) }
            for value in array(row["results"]) + array(row["tracks"]) {
                let track = object(value)
                guard let name = text(track["name"]) else { continue }
                items.append(.init(title: name, content: .object(["who": track["artist"] ?? .null, "summary": track["album"] ?? .null]),
                    actions: [effect("Play", tool: "music_control", input: ["action": .string("play"), "track": .string(name),
                                                                            "artist": track["artist"] ?? .string("")])]))
            }
            if items.isEmpty, content["message"] == nil, let why = text(row["reason"]) { content["message"] = .string(why) }
            var counts: Set<Int> = []
            for value in array(row["playlists"]) {
                let list = object(value)
                guard let name = text(list["name"]) else { continue }
                // Music's built-in whole-library lists repeat one another (Library, Music).
                let tracks = int(list["track_count"]) ?? 0
                if text(list["special_kind"]).map({ $0 != "none" }) == true, !counts.insert(tracks).inserted { continue }
                items.append(.init(title: name, content: .object(["summary": .string("\(tracks) track\(tracks == 1 ? "" : "s")")]),
                    actions: [effect("Play", tool: "music_control", input: ["action": .string("play"), "playlist": .string(name)])]))
            }
            actions = [effect("Play", tool: "music_control", input: ["action": .string("play")]),
                       effect("Pause", tool: "music_control", input: ["action": .string("pause")]),
                       effect("Next track", tool: "music_control", input: ["action": .string("next")]),
                       effect("Previous track", tool: "music_control", input: ["action": .string("previous")]),
                       typed("Play a playlist", tool: "music_control", input: ["action": .string("play")], field: "playlist", effect: true),
                       typed("Play a song", tool: "music_control", input: ["action": .string("play")], field: "track", effect: true),
                       typed("Find in library", tool: "music_search_library", field: "query"),
                       read("Playlists", tool: "music_list_playlists", input: ["limit": .int(24)])]
        case "market_status", "market_watchlists", "tradingview_watchlist", "market_quote":
            if row["status"] == .string("missing_config") { content["message"] = .string("No market sources are set up yet; quotes still work for plain symbols.") }
            // Local lists come as watchlists, TradingView's as its payload.
            for value in array(row["watchlists"]) + array(row["payload"]) {
                let list = object(value)
                guard let id = text(list["name"]) ?? text(list["id"]) else { continue }
                let count = int(list["symbol_count"]) ?? int(list["symbols_count"]) ?? array(list["symbols"]).count
                items.append(.init(title: id, content: .object(["summary": .string("\(count) symbols")]),
                    actions: tool == "tradingview_watchlist" ? [] : [typed("Quote", tool: "market_quote", input: ["watchlist": .string(id)], field: nil)]))
            }
            for value in array(row["quotes"]) {
                let quote = object(value)
                guard let symbol = text(quote["symbol"]) ?? text(quote["name"]) else { continue }
                let price = number(quote["close"] ?? quote["regularMarketPrice"])
                let change = number(quote["change"] ?? quote["regularMarketChangePercent"])
                var line = [symbol, price.map { String(format: "%.2f", $0) }, change.map { String(format: "%+.2f%%", $0) }].compactMap { $0 }.joined(separator: " ")
                // How old the price is, and TradingView's delay ("delayed_streaming_900").
                if let at = text(quote["as_of"]).flatMap(HerScreen.date) { line += " · as of " + HerScreen.age(Date().timeIntervalSince(at)) + " ago" }
                if let mode = text(quote["update_mode"]), mode.hasPrefix("delayed") {
                    line += Int(mode.split(separator: "_").last ?? "").map { " (\($0 / 60)m delayed)" } ?? " (delayed)"
                }
                items.append(.init(title: line, content: .object(["summary": quote["description"] ?? quote["shortName"] ?? .null]), actions: []))
            }
            // Symbols the provider returned nothing for still show, flagged.
            if let missing = text(row["not_found"])?.components(separatedBy: " — ").first {
                for symbol in missing.components(separatedBy: ", ") where !symbol.isEmpty {
                    items.append(.init(title: symbol + " · not quoted", content: .object(["summary": .string("try the exchange prefix, e.g. NASDAQ:AAPL")]), actions: []))
                }
            }
            actions = [typed("Quote symbols", tool: "market_quote", field: "symbol"),
                       read("TradingView watchlists", tool: "tradingview_watchlist", input: ["includeSymbols": .bool(false)]),
                       read("Local watchlists", tool: "market_watchlists", input: ["includeSymbols": .bool(false)])]
        case "x_status", "x_me", "x_search", "x_timeline", "x_user_tweets":
            // User, 2026-09-24: X is read in Chrome, not on his paid API key.
            if tool == "x_status" {
                content["message"] = .string("Read X in Chrome: x.open, or browser.go https://x.com/<handle> or x.com/search?q=<words>.")
                content["note"] = .string("The (API) verbs spend the paid X API; use them only if the person asks or Chrome can't.")
                // A real status read (x.status) says how the API stands; the room itself reads nothing.
                if row["room"] == nil { content["detail"] = content["error"] ?? .string("The X API is connected.") }
            }
            if tool == "x_me", case .object(let me)? = row["data"], let handle = text(me["username"]) {
                let metrics = object(me["public_metrics"] ?? .null)
                content["message"] = .string("@\(handle) · \(int(metrics["followers_count"]) ?? 0) followers · \(int(metrics["tweet_count"]) ?? 0) posts")
            }
            let by = text(row["username"])
            for value in array(row["tweets"]) {
                let tweet = object(value)
                guard let words = text(tweet["text"]) else { continue }
                let who = text(tweet["author"]) ?? by
                items.append(.init(title: words, content: .object(["from": who.map { .string("@" + $0) } ?? .null, "when": tweet["created_at"] ?? .null]), actions: []))
            }
            if case .string(let next)? = object(row["meta"] ?? .null)["next_token"], tool == "x_search", case .string(let query)? = input["query"] {
                actions.append(read("Next page of results", tool: "x_search", input: ["query": .string(query), "next_token": .string(next)]))
            }
            actions.insert(effect("Open x.com in Chrome", tool: "browser.chrome_navigate", input: ["url": .string("https://x.com/home")]), at: 0)
            actions += [typed("Search posts (API)", tool: "x_search", field: "query"),
                        read("Following timeline (API)", tool: "x_timeline", input: ["max": .int(20)]),
                        typed("Posts by an account (API)", tool: "x_user_tweets", field: "username"),
                        read("My profile (API)", tool: "x_me"), read("Status (API)", tool: "x_status")]
        case "slack_status", "slack_list_channels", "slack_search_messages":
            let response = object(row["response"] ?? .null)
            if tool == "slack_status", content["error"] == nil, let team = text(response["team"]) {
                content["message"] = .string("Connected to \(team)" + (text(response["user"]).map { " as \($0)" } ?? "") + ".")
            }
            for value in array(response["channels"]) {
                let channel = object(value)
                guard let id = text(channel["id"]) else { continue }
                let direct = text(channel["kind"])?.contains("DM") == true
                items.append(.init(title: text(channel["name"]).map { direct ? $0 : "#" + $0 } ?? id, content: .object(["kind": channel["kind"] ?? .null]),
                    actions: [configure("Post here", tool: "slack_post_message", input: ["channel": .string(id)])]))
            }
            for value in array(object(response["messages"] ?? .null)["matches"]) {
                let match = object(value)
                guard let words = text(match["text"]) else { continue }
                items.append(.init(title: words, content: .object(["from": match["from"] ?? .null, "when": match["when"] ?? .null]), actions: []))
            }
            actions = [read("Channels", tool: "slack_list_channels", input: ["limit": .int(200)]),
                       typed("Search messages", tool: "slack_search_messages", field: "query"),
                       configure("Post a message", tool: "slack_post_message")]
        case "notion_status", "notion_search", "google_calendar_status", "google_calendar_list":
            for value in array(row["results"]) {
                let page = object(value)
                guard let id = text(page["id"]) else { continue }
                items.append(.init(title: text(page["title"]) ?? "Untitled", content: .object(["kind": page["object"] ?? .null, "updated": page["lastEditedTime"] ?? .null]),
                    actions: [read("Read", tool: "notion_read_page", input: ["id": .string(id)], title: text(page["title"]) ?? "Notion page")]))
            }
            for value in array(row["events"]) {
                let event = object(value)
                items.append(.init(title: text(event["summary"]) ?? "Event", content: .object(["start": event["start"] ?? .null, "summary": event["location"] ?? .null]), actions: []))
            }
            actions = tool.hasPrefix("notion") ? [typed("Search pages", tool: "notion_search", field: "query")]
                : [read("Next 7 days", tool: "google_calendar_list", input: ["limit": .int(16)]), typed("One day", tool: "google_calendar_list", field: "day")]
        default:
            // An effect's receipt in one of these rooms: what happened, in words.
            if content["error"] == nil { content["message"] = .string("Done.") }
        }
        return .init(title: destinations.first { $0.id == room(for: tool) }?.title ?? "Workspace", content: .object(content), items: items, actions: actions)
    }

    /// "Playing: Song — Artist · Album · 1:02 of 3:40", or why nothing is.
    static func playing(_ row: [String: JSONValue]) -> String {
        if row["playerState"] == .string("not_running") { return "Music isn't open. music.play starts it." }
        let track = object(row["track"] ?? .null)
        guard let name = text(track["name"]) else { return "Nothing playing." }
        func clock(_ value: JSONValue?) -> String? {
            guard let seconds = number(value), seconds > 0 else { return nil }
            return String(format: "%d:%02d", Int(seconds) / 60, Int(seconds) % 60)
        }
        let state = row["isPlaying"] == .bool(true) ? "Playing" : text(row["playerState"])?.capitalized ?? "Paused"
        var parts = [name + (text(track["artist"]).map { " — " + $0 } ?? "")]
        if let album = text(track["album"]) { parts.append(album) }
        if let at = clock(track["position_seconds"]), let of = clock(track["duration_seconds"]) { parts.append(at + " of " + of) }
        return state + ": " + parts.joined(separator: " · ")
    }

    /// The one sentence that says why a read or change did not work.
    static func problem(_ row: [String: JSONValue]) -> String? {
        let failed = row["ok"] == .bool(false) || ["failed", "error", "denied", "unavailable", "needs_setup", "needs_authentication"].contains(text(row["status"]) ?? "")
            || row["needs"] != nil
        guard failed else { return nil }
        return ["fix", "hint", "detail", "reason", "error", "message"].lazy.compactMap { text(row[$0]) }.first ?? "The read did not complete."
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

    private static func configure(_ label: String, tool: String, input: [String: JSONValue] = [:]) -> AgentWorkspaceButton {
        .init(label: label, action: .configure(tool: tool, input: input, title: label))
    }

    static func object(_ value: JSONValue) -> [String: JSONValue] { if case .object(let row) = value { return row }; return [:] }
    private static func array(_ value: JSONValue?) -> [JSONValue] { if case .array(let rows)? = value { return rows }; return [] }
    private static func text(_ value: JSONValue?) -> String? {
        guard case .string(let text)? = value else { return nil }
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }
    private static func int(_ value: JSONValue?) -> Int? { number(value).map { Int($0) } }
    private static func number(_ value: JSONValue?) -> Double? {
        switch value {
        case .int(let n)?: return Double(n)
        case .double(let n)?: return n
        case .string(let s)?: return Double(s)
        default: return nil
        }
    }
}

extension HerScreen {
    /// A read or a change in a life room as that room's text, with what the
    /// change did on the line under the header. Nil keeps the old frame.
    static func lifeRoom(_ place: AgentWorkspaceLocation, projection: AgentWorkspaceProjection, frame: JSONValue, dataRoot: URL) -> String? {
        let tool: String, receipt: JSONValue?
        var shown = projection
        var watchlist: String?
        switch place {
        case .record(let name, let input, _):
            tool = name
            if case .string(let list)? = input["watchlist"] { watchlist = list }
            receipt = AgentWorkspaceLife.object(projection.content)["action_receipt"]
        case .receipt(let name, _, let value, _):
            tool = name; receipt = value
            if let own = AgentWorkspaceLife.project(tool: name, input: [:], result: value) { shown = own }
        case .area("gcal"): tool = "google_calendar_list"; receipt = nil
        default: return nil
        }
        guard let room = AgentWorkspaceLife.room(for: tool) else { return nil }
        // A calendar or reminder change keeps its old receipt frame unless
        // its list was read back (the record carries the receipt).
        if case .receipt = place, tool.hasPrefix("mac_") { return nil }
        var lines = textRoom(room, place: place, projection: shown, frame: frame, dataRoot: dataRoot).components(separatedBy: "\n")
        // A quoted watchlist is titled by its name.
        if let watchlist, let first = lines.first, first.hasPrefix("MARKETS") {
            lines[0] = "MARKETS · " + clip(watchlist.uppercased(), 30) + first.dropFirst(7)
        }
        if room == "gcal", let first = lines.first, first.hasPrefix("GCAL") {
            lines[0] = "GCAL · Google Calendar (separate from your Mac calendar)" + first.dropFirst(4)
        }
        if let receipt {
            let row = AgentWorkspaceLife.object(receipt)
            let what = ["title", "action_performed", "playlist", "track"].lazy.compactMap { key -> String? in
                if case .string(let text)? = row[key], !text.isEmpty { return text } else { return nil }
            }.first
            let said = AgentWorkspaceLife.problem(row).map { "✗ " + $0 } ?? "✓ " + (what.map { "done: " + $0 } ?? "done")
            lines.insert(pad("DONE", 10) + clip(said, 100), at: min(1, lines.count))
        }
        return lines.joined(separator: "\n")
    }

    /// Home's names for these rooms (the last PLACES row).
    static let lifePlaces = "music · markets · x · slack · notion · gcal"

    /// "calendar: 2 today · 3h" from the latest read today, else the bare name.
    static func lifePulse(_ name: String, now: Date = Date()) -> String {
        guard let seen = HerLifePulse.shared.latest(name), Calendar.current.isDate(seen.at, inSameDayAs: now) else { return name }
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
/// of its verbs instead. Per data root, for the life of the app.
final class HerItemPages: @unchecked Sendable {
    static let shared = HerItemPages()
    private let lock = NSLock()
    private var byRoot: [String: [String: String]] = [:]

    func keep(_ root: URL, _ pages: [String: String]) {
        guard !pages.isEmpty else { return }
        lock.withLock { byRoot[root.standardizedFileURL.path, default: [:]].merge(pages) { _, new in new } }
    }

    func page(_ root: URL, _ name: String) -> String? { lock.withLock { byRoot[root.standardizedFileURL.path]?[name] } }
}

extension HerScreen {
    /// The x room without touching the API (User: X is read in Chrome): the
    /// Chrome-first header and the verbs, API ones marked as the fallback.
    static func xRoom(dataRoot: URL) -> String? {
        guard let projection = AgentWorkspaceLife.project(tool: "x_status", input: [:], result: .object(["status": .string("ok"), "room": .bool(true)])) else { return nil }
        return textRoom("x", place: .area("x"), projection: projection, frame: .object(["status": .string("ok")]), dataRoot: dataRoot)
    }
}

/// The latest calendar-today and reminders-due counts, noted as those reads
/// pass through the dispatcher, for home to show without reading. Memory only.
final class HerLifePulse: @unchecked Sendable {
    static let shared = HerLifePulse()
    private let lock = NSLock()
    private var rows: [String: (words: String, at: Date)] = [:]

    /// Passes the read's result through untouched.
    static func noted(_ name: String, _ result: JSONValue) -> JSONValue {
        let row = AgentWorkspaceLife.object(result)
        guard row["status"] == .string("completed"), case .int(let count)? = row["count"] else { return result }
        if name == "calendar", row["day"] == .string("today") { shared.set(name, "\(count) today") }
        if name == "reminders", row["includeCompleted"] == .bool(false), case .array(let due)? = row["reminders"] {
            // Overdue apart from due today: "6 overdue", "1 due · 5 overdue".
            let today = Calendar.current.startOfDay(for: Date())
            let overdue = due.filter { value in
                guard case .string(let at)? = AgentWorkspaceLife.object(value)["dueAt"], let date = ISO8601DateFormatter().date(from: at) else { return false }
                return date < today
            }.count
            let words = [count - Int64(overdue) > 0 ? "\(count - Int64(overdue)) due" : nil, overdue > 0 ? "\(overdue) overdue" : nil].compactMap { $0 }
            shared.set(name, words.isEmpty ? "none due" : words.joined(separator: " · "))
        }
        return result
    }

    private func set(_ name: String, _ words: String) { lock.withLock { rows[name] = (words, Date()) } }
    func latest(_ name: String) -> (words: String, at: Date)? { lock.withLock { rows[name] } }
}
