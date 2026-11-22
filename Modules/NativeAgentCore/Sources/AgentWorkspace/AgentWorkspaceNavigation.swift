import Foundation
import PersistenceCore
import NativeAgentCore
import ChatSessionWork
import ApprovalInbox
import MemoryV2
import NotificationInbox
import Desk
import StandingBots
import NativeAgentShared
// Blueprint: | `AgentWorkspaceNavigation.swift` | `AgentWorkspaceNavigation`, `Session`: Resident item context, arrivals, undo receipts and door page |

package actor AgentWorkspaceNavigation {
    package static let shared = AgentWorkspaceNavigation()

    struct Session: Sendable {
        var current: AgentWorkspaceLocation = .home
        var touched = Date()
        var operation: UUID?
        var lastUndoReceipt: JSONValue?
        var lastDoorPage: String?
        var browserBookmark: AgentWorkspaceLocation?
        var browserBookmarks: [String: AgentWorkspaceLocation] = [:]
        var arrivals: AgentWorkspaceArrivals.State?
        var watched: [AgentWorkspaceLocation] = []
        var observations: [AgentWorkspaceChanges.Stamp] = []
    }
    var sessions: [String: Session] = [:]
    private let capacity = 64
    func begin(key: String) throws -> UUID {
        if sessions[key]?.operation != nil {
            throw AgentWorkspaceFailure(message: "Home is already handling an action. No second action was started.")
        }
        var session = try session(key: key)
        let operation = UUID()
        session.operation = operation
        session.touched = Date()
        sessions[key] = session
        return operation
    }

    private func session(key: String) throws -> Session {
        if sessions[key] == nil, sessions.count >= capacity {
            guard let oldest = sessions.filter({ $0.value.operation == nil }).min(by: { $0.value.touched < $1.value.touched }) else {
                throw AgentWorkspaceFailure(message: "Home is busy in every resident conversation. Nothing was evicted.")
            }
            sessions.removeValue(forKey: oldest.key)
            AgentNamed.shared.removeSession(oldest.key)
            AgentItemPages.shared.removeSession(oldest.key)
        }
        return sessions[key] ?? Session()
    }

    package func undoReceipt(dataRoot: URL, scope: String) -> JSONValue? {
        sessions[dataRoot.standardizedFileURL.path + "\u{0}" + scope]?.lastUndoReceipt
    }

    package func issued(_ id: String, dataRoot: URL, scope: String) -> Bool {
        guard let session = sessions[dataRoot.standardizedFileURL.path + "\u{0}" + scope] else { return false }
        return session.arrivals?.pending.contains(where: { $0.id == id }) == true
    }

    package func lastDoorPage(dataRoot: URL, scope: String) -> String? {
        sessions[dataRoot.standardizedFileURL.path + "\u{0}" + scope]?.lastDoorPage
    }

    package func rememberDoorPage(_ page: String?, dataRoot: URL, scope: String) throws {
        let key = dataRoot.standardizedFileURL.path + "\u{0}" + scope
        var session = try session(key: key)
        session.lastDoorPage = page
        session.touched = Date()
        sessions[key] = session
    }

    package func rememberUndo(_ receipt: JSONValue, dataRoot: URL, scope: String) throws {
        let key = dataRoot.standardizedFileURL.path + "\u{0}" + scope
        var session = try session(key: key)
        session.lastUndoReceipt = receipt
        session.touched = Date()
        sessions[key] = session
    }

    package func clearUndo(_ receipt: JSONValue, dataRoot: URL, scope: String) {
        let key = dataRoot.standardizedFileURL.path + "\u{0}" + scope
        if sessions[key]?.lastUndoReceipt == receipt { sessions[key]?.lastUndoReceipt = nil }
    }

    func end(key: String, operation: UUID) {
        guard sessions[key]?.operation == operation else { return }
        sessions[key]?.operation = nil
    }

    func claim(_ id: String, key: String) throws -> AgentWorkspaceAction {
        if sessions[key]?.arrivals?.pending.contains(where: { $0.id == id }) == true {
            return .openArrival(id)
        }
        throw AgentWorkspaceFailure(message: "This arrival is no longer available. Open app {} for current items.")
    }

    func current(key: String) -> AgentWorkspaceLocation { sessions[key]?.current ?? .home }

    package func currentPlace(dataRoot: URL, scope: String) -> String? {
        guard let place = sessions[dataRoot.standardizedFileURL.path + "\u{0}" + scope]?.current, place != .home else { return nil }
        return "Current item in this conversation (untrusted source label, not a fresh read): " + String(place.title.prefix(160))
    }

    func browserPages(key: String) -> [AgentWorkspaceLocation] {
        guard let session = sessions[key] else { return [] }
        var pages: [AgentWorkspaceLocation] = []
        if let current = session.browserBookmark { pages.append(current) }
        for place in session.browserBookmarks.values {
            guard case .browserBookmark = place, !pages.contains(place) else { continue }
            pages.append(place)
        }
        return pages.filter { if case .browserBookmark(_, _, let tab?) = $0 { !ChromePageMirror.isClosed(tab) } else { true } }
    }

    package func forgetTab(tab: Int64, key: String) {
        guard var session = sessions[key] else { return }
        let identity = "browser.chrome_snapshot:" + String(tab)
        let bookmark = session.browserBookmarks[identity].flatMap { saved -> AgentWorkspaceLocation? in
            guard case .browserBookmark(_, _, let id) = saved else { return nil }
            return id == nil || tab == id ? saved : nil
        }
        func gone(_ place: AgentWorkspaceLocation) -> Bool {
            if case .record("browser.chrome_snapshot", let input, _) = place { return input["tab_id"] == .int(tab) }
            return bookmark != nil && place == bookmark
        }
        session.browserBookmarks[identity] = nil
        if let current = session.browserBookmark, gone(current) { session.browserBookmark = nil }
        session.watched.removeAll(where: gone)
        if gone(session.current) { session.current = .home }
        session.arrivals?.monitor.invalidate()
        sessions[key] = session
    }

    func navigate(_ location: AgentWorkspaceLocation, key: String) throws {
        guard var session = sessions[key] else { return }
        session.current = location
        if case .record(let tool, _, _) = location, ["chat_conversations", "task_ledger_list", "agent_read"].contains(tool) {
            session.watched.removeAll { Self.placeIdentity($0) == Self.placeIdentity(location) }
            session.watched.append(location)
            if session.watched.count > 24 { session.watched.removeFirst(session.watched.count - 24) }
            session.arrivals?.monitor.invalidate()
        }
        sessions[key] = session
    }

    static func placeIdentity(_ location: AgentWorkspaceLocation) -> String? {
        switch location {
        case .page(let source, _): return placeIdentity(source)
        case .area(let id): return "area:" + id
        case .browserBookmark(let url, _, let tabID): return "browser:" + url + (tabID.map { "\u{0}tab:\($0)" } ?? "")
        case .record(let tool, let input, _):
            let target: String
            switch tool {
            case "read_file", "list_dir": target = "path"
            case "agent_read": target = "agent"
            case "chat_conversations": target = "conversation_session_id"
            case "desk_read": target = "handle"
            case "work_context":
                guard case .string(let query)? = input["query"] else { return nil }
                if case .string(let scope)? = input["session_id"], !scope.isEmpty { return "work:" + query + "\u{0}" + scope }
                return "work:" + query
            case "task_ledger_list": target = "task_id"
            case "read_skill": target = "name"
            case "read_page":
                guard case .string(let url)? = input["url"] else { return nil }
                return "browser:" + url
            case "recall_memory", "recall_search": target = input["memory_id"] == nil ? "query" : "memory_id"
            case "read_chat_message": target = "message_id"
            case "shelf_entry": target = "id"
            case "screen": return "screen:" + (input["app"].flatMap { if case .string(let app) = $0 { return app }; return nil } ?? "frontmost")
            case "bot_list": target = "id"
            case "mac_calendar_list_upcoming":
                do { return tool + ":" + (try ["day", "calendar_name", "calendar_id", "hours_ahead"].map { try (input[$0] ?? .null).serialize(pretty: false) }
                    .joined(separator: "\u{0}")) }
                catch { return nil }
            case "mac_reminders_list_due_today": return tool
            case "mac_reminders_read": target = "id"
            case "mac_reminders_query":
                do { return tool + ":" + (try ["query", "list_name", "due_start", "due_end", "undated_only", "include_completed", "offset"].map { try (
                    input[$0] ?? .null).serialize(pretty: false) }.joined(separator: "\u{0}")) }
                catch { return nil }
            case "mail.search": target = "query"
            case "messages.recent": target = "thread_id"
            case "mail.recent":
                guard case .int(let id)? = input["message_id"], case .string(let expected)? = input["expected_message_id"] else { return nil }
                return "mail:" + String(id) + "\u{0}" + expected
            case "browser.chrome_snapshot":
                if case .int(let tab)? = input["tab_id"] { return tool + ":" + String(tab) }
                return tool
            default: return nil
            }
            guard case .string(var value)? = input[target] else { return nil }
            if tool == "agent_read", value.lowercased().hasPrefix("bot:") { value = value.lowercased() }
            let conversation: String
            if case .string(let value)? = input["conversation"] { conversation = value } else { conversation = "" }
            return tool + ":" + value + "\u{0}" + conversation
        default: return nil
        }
    }

    func rememberDocument(location: AgentWorkspaceLocation, result: JSONValue, key: String) {
        guard var session = sessions[key] else { return }
        if case .record(let tool, _, _) = location, tool == "browser.chrome_snapshot",
           case .object(let row) = result, row["ok"] != .bool(false), row["error"] == nil,
           case .string(let url)? = row["url"], case .string(let title)? = row["title"],
           !url.isEmpty {
            let bookmark = AgentWorkspaceLocation.browserBookmark(url: url, title: title.isEmpty ? url : title,
                tabID: { if case .int(let id)? = row["tabId"] { return id }; return nil }())
            session.browserBookmark = bookmark
            if let identity = Self.placeIdentity(location) {
                session.browserBookmarks[identity] = bookmark
                if session.browserBookmarks.count > 24, let old = session.browserBookmarks.keys.sorted().first(where: { $0 != identity }) {
                    session.browserBookmarks[old] = nil
                }
            }
        }
        sessions[key] = session
    }

}
