import Foundation
import PersistenceCore
import NativeAgentCore
import ChatSessionWork
import ApprovalInbox
import MemoryV2
import NotificationInbox
import Desk
import StandingBots
import WorkshopExecution
import SwarmRuns
import NativeAgentShared
// Blueprint: | `AgentWorkspaceNavigation.swift` | Shared `AgentWorkspaceNavigation` actor requires data root and scope to restore each `Session`'s conversation arrangement and last undo receipt, never in a second ledger |

/// Bounded per-chat navigation persists references and supported drafts; live buttons, grants and evidence stay disposable.
package actor AgentWorkspaceNavigation {
    package static let shared = AgentWorkspaceNavigation()

    struct Session: Sendable {
        var arrangement = AgentWorkspaceDesktopState(path: [.home])
        var buttons: [String: AgentWorkspaceButton] = [:]
        var issuedAt = Date.distantPast
        var touched = Date()
        var operation: UUID?
        var document: AgentWorkspaceDocument?
        var workLinkNotice: String?
        var lastUndoReceipt: JSONValue?
        var lastDoorPage: String?
        var store: AgentWorkspaceDesktopStore?
        var persistenceIssue: String?
        var nextPersistenceAttempt = Date.distantPast
        var needsStorageReload = false
        var lastPersisted: AgentWorkspaceDesktopState?
        var browserBookmark: AgentWorkspaceLocation?
        var browserBookmarks: [String: AgentWorkspaceLocation] = [:]
        var arrivals: AgentWorkspaceArrivals.State?
        var arrivalReturn: AgentWorkspaceArrivals.ReturnPlace?
        var controlsExpanded = false
        var switchingWindow = false
        /// An effect just ran (a receipt was shown): the place it reads back is a window.
        var actedJustNow = false
        /// Read conversations, tasks and bots are watched for arrivals without becoming windows.
        var watched: [AgentWorkspaceLocation] = []
        var buttonPrefix = ""
        var buttonCount = 0

        mutating func retireButtons() {
            for id in buttons.keys { buttons[id]?.retired = true }
        }
    }
    var sessions: [String: Session] = [:]
    private let capacity = 64
    func begin(key: String, dataRoot: URL, scope: String) throws -> UUID {
        if sessions[key]?.operation != nil {
            throw AgentWorkspaceFailure(message: "This workspace is already handling an action. No second action was started.")
        }
        var session = try session(key: key, dataRoot: dataRoot, scope: scope)
        let operation = UUID()
        session.operation = operation
        session.touched = Date()
        session.actedJustNow = false
        sessions[key] = session
        return operation
    }

    private func session(key: String, dataRoot: URL, scope: String) throws -> Session {
        if sessions[key] == nil, sessions.count >= capacity {
            guard let oldest = sessions.filter({ $0.value.operation == nil && canEvict($0.value) }).min(by: { $0.value.touched < $1.value.touched }) else {
                throw AgentWorkspaceFailure(message: "Resident workspaces contain unsaved or temporary drafts. Return to an existing chat to finish or discard a draft before opening another. Nothing was evicted.")
            }
            sessions.removeValue(forKey: oldest.key)
            HerNamed.shared.removeSession(oldest.key)
            HerItemPages.shared.removeSession(oldest.key)
        }
        return sessions[key] ?? restoredSession(dataRoot: dataRoot, scope: scope)
    }

    package func undoReceipt(dataRoot: URL, scope: String) -> JSONValue? {
        sessions[dataRoot.standardizedFileURL.path + "\u{0}" + scope]?.lastUndoReceipt
    }

    package func lastDoorPage(dataRoot: URL, scope: String) -> String? {
        sessions[dataRoot.standardizedFileURL.path + "\u{0}" + scope]?.lastDoorPage
    }

    package func rememberDoorPage(_ page: String?, dataRoot: URL, scope: String) throws {
        let key = dataRoot.standardizedFileURL.path + "\u{0}" + scope
        var session = try session(key: key, dataRoot: dataRoot, scope: scope)
        session.lastDoorPage = page
        session.touched = Date()
        sessions[key] = session
    }

    package func rememberUndo(_ receipt: JSONValue, dataRoot: URL, scope: String) throws {
        let key = dataRoot.standardizedFileURL.path + "\u{0}" + scope
        var session = try session(key: key, dataRoot: dataRoot, scope: scope)
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
        // Arrival pointers survive refreshes only in their verified issuing workspace and can only open reads.
        if sessions[key]?.arrivals?.pending.contains(where: { $0.id == id }) == true {
            return .openArrival(id)
        }
        let session = sessions[key], button = session?.buttons[id]
        guard let session, Date().timeIntervalSince(session.issuedAt) <= 1800,
              let button, !button.consumed, !button.retired else {
            var next: [String: JSONValue] = [:]
            if let name = button?.viewName { next["item"] = .string(name) }
            throw ToolFailureError("That reference is expired, consumed or no longer in this view. Nothing was repeated; entered form values remain. Open next_call for current controls.",
                argumentPath: "item", effects: .none, nextCall: ToolFailureError.call("app", next))
        }
        // Claim before dispatch so a lost send response cannot repeat the same button.
        sessions[key]?.buttons[id]?.consumed = true
        return button.action
    }

    func current(key: String) -> AgentWorkspaceLocation { sessions[key]?.arrangement.path.last ?? .home }

    func toggleControls(key: String) { sessions[key]?.controlsExpanded.toggle() }
    func beginWindowSwitch(key: String) { sessions[key]?.switchingWindow = true }

    /// The pages this conversation holds, current one first.
    func browserPages(key: String) -> [AgentWorkspaceLocation] {
        guard let session = sessions[key] else { return [] }
        var pages: [AgentWorkspaceLocation] = []
        if let current = session.browserBookmark { pages.append(current) }
        for place in session.arrangement.places.reversed() {
            guard case .browserBookmark = place, !pages.contains(place) else { continue }
            pages.append(place)
        }
        return pages.filter { if case .browserBookmark(_, _, let tab?) = $0 { !ChromePageMirror.isClosed(tab) } else { true } }
    }

    /// An explicitly closed tab leaves this chat's windows and home.
    package func forgetTab(tab: Int64, key: String) {
        guard var session = sessions[key] else { return }
        // Remove only the window and bookmark recorded for this tab.
        let identity = "browser.chrome_snapshot:" + String(tab)
        let bookmark = session.browserBookmarks[identity].flatMap { saved -> AgentWorkspaceLocation? in
            guard case .browserBookmark(_, _, let id) = saved else { return nil }
            return id == nil || tab == id ? saved : nil
        }
        func gone(_ place: AgentWorkspaceLocation) -> Bool {
            if case .record("browser.chrome_snapshot", let input, _) = place { return input["tab_id"] == .int(tab) }
            return bookmark != nil && place == bookmark
        }
        guard session.arrangement.places.contains(where: gone) || session.browserBookmarks[identity] != nil else { return }
        session.arrangement.places.removeAll(where: gone)
        session.browserBookmarks[identity] = nil
        if let current = session.browserBookmark, gone(current) { session.browserBookmark = nil }
        session.arrivals?.monitor.invalidate()
        sessions[key] = session
    }

    func compactDesktop(_ value: JSONValue, key: String) -> JSONValue {
        guard let session = sessions[key], !session.controlsExpanded,
              session.arrangement.path.last != .openPlaces, session.arrangement.path.last != .savedWorkspaces,
              case .object(var metadata) = value else { return value }
        if case .array(let places)? = metadata.removeValue(forKey: "open_places") {
            metadata["open_places"] = .int(Int64(places.count))
        }
        metadata.removeValue(forKey: "meaning")
        return .object(metadata)
    }

    func navigate(_ location: AgentWorkspaceLocation, key: String) throws {
        guard var session = sessions[key] else { return }
        if session.arrangement.path.last != location { session.controlsExpanded = false }
        // Switching windows starts a trail at Home; windows remain side by side.
        if session.switchingWindow {
            session.switchingWindow = false
            session.arrangement.path = [.home]
        }
        let oldPlaces = session.arrangement.places, oldWatched = session.watched
        if case .form(let form) = location {
            guard session.arrangement.drafts.contains(where: { $0.draftID == form.draftID }) || session.arrangement.drafts.count < 4 else {
                throw AgentWorkspaceFailure(message: "Four unfinished drafts are already open. Open places to finish or discard one before starting another; existing drafts were preserved.")
            }
            session.arrangement.drafts.removeAll { $0.draftID == form.draftID }
            session.arrangement.drafts.append(form)
            session.arrangement.path.removeAll { Self.placeIdentity($0) == "draft:" + form.draftID.uuidString }
            session.arrangement.path.append(location)
            if session.arrangement.path.count > 8 { session.arrangement.path.removeFirst(session.arrangement.path.count - 8) }
        } else if case .receipt(let tool, let title, _, _) = location,
           case .receipt(let previousTool, let previousTitle, _, _)? = session.arrangement.path.last,
           tool == previousTool, title == previousTitle {
            session.arrangement.path[session.arrangement.path.count - 1] = location
        } else if session.arrangement.path.last != location {
            session.arrangement.path.append(location)
            if session.arrangement.path.count > 8 { session.arrangement.path.removeFirst(session.arrangement.path.count - 8) }
        }
        if case .work(let topic) = location {
            session.document = nil; session.arrangement.workAnchor = location; session.arrangement.workTopic = topic
        }
        if case .record(let tool, let input, _) = location, tool == "desk_read", input["handle"] != nil {
            session.arrangement.workAnchor = location
        }
        // Windows retain drafts and browser pages; other reads leave none, and `keep` explicitly retains a place.
        var actsIn: Bool = switch location {
        case .form, .browserBookmark: true
        case .record(let tool, _, _): tool.hasPrefix("browser.") || tool == "read_page"
        default: false
        }
        // A receipt means an effect ran; the place it reads back is kept.
        if case .receipt = location { session.actedJustNow = true }
        else if session.actedJustNow { actsIn = true; session.actedJustNow = false }
        if !actsIn, case .record(let tool, _, _) = location,
           ["chat_conversations", "task_ledger_list", "agent_read"].contains(tool) {
            session.watched.removeAll { $0 == location }
            session.watched.append(location)
            if session.watched.count > 24 { session.watched.removeFirst(session.watched.count - 24) }
        }
        if actsIn, let identity = Self.placeIdentity(location) {
            session.arrangement.places.removeAll { Self.placeIdentity($0) == identity }
            session.arrangement.places.append(location)
            while session.arrangement.places.count > 24 {
                guard let index = session.arrangement.places.firstIndex(where: { if case .form = $0 { return false }; return true }) else { break }
                session.arrangement.places.remove(at: index)
            }
        }
        session.retireButtons()
        if oldPlaces != session.arrangement.places || oldWatched != session.watched { session.arrivals?.monitor.invalidate() }
        sessions[key] = session
    }

    /// Reopening a locator rereads its owner; reopening a draft edits inputs without repeating its effect.
    static func placeIdentity(_ location: AgentWorkspaceLocation) -> String? {
        switch location {
        case .form(let form): return "draft:" + form.draftID.uuidString
        case .page(let source, _): return placeIdentity(source)
        case .work(let topic): return "work:" + topic
        case .find(let query): return "find:" + query
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
                return tool + ":" + (["day", "calendar_name", "calendar_id", "hours_ahead"].map { (try? input[$0]?.serialize(pretty: false)) ?? "" }.joined(separator: "\u{0}"))
            case "mac_reminders_list_due_today": return tool
            case "mac_reminders_read": target = "id"
            case "mac_reminders_query":
                return tool + ":" + (["query", "list_name", "due_start", "due_end", "undated_only", "include_completed", "offset"].map { (try? input[$0]?.serialize(pretty: false)) ?? "" }.joined(separator: "\u{0}"))
            case "mail_search": target = "query"
            case "messages_recent_threads": target = "thread_id"
            case "mail_list_recent":
                guard case .int(let id)? = input["message_id"], case .string(let expected)? = input["expected_message_id"] else { return nil }
                return "mail:" + String(id) + "\u{0}" + expected
            case "browser.chrome_snapshot":
                if case .int(let tab)? = input["tab_id"] { return tool + ":" + String(tab) }
                return tool
            default: return nil
            }
            guard case .string(var value)? = input[target] else { return nil }
            // One helper, whatever case its id was saved in: one window.
            if tool == "agent_read", value.lowercased().hasPrefix("bot:") { value = value.lowercased() }
            let conversation: String
            if case .string(let value)? = input["conversation"] ?? input["session_id"] { conversation = value } else { conversation = "" }
            return tool + ":" + value + "\u{0}" + conversation
        default: return nil
        }
    }

    func openPlaces(key: String) -> WorkspacePage {
        recognizedOpenPlaces(key: key)
    }

    func rememberDocument(location: AgentWorkspaceLocation, result: JSONValue, evidence: (text: String, fingerprint: String)?, key: String) {
        guard var session = sessions[key] else { return }
        if case .record(let tool, _, _) = location, tool == "browser.chrome_snapshot",
           case .object(let row) = result, row["ok"] != .bool(false), row["error"] == nil,
           case .string(let url)? = row["url"], case .string(let title)? = row["title"],
           let bookmark = AgentWorkspaceDesktopStore.durable(.browserBookmark(url: url, title: title.isEmpty ? url : title,
                tabID: { if case .int(let id)? = row["tabId"] { return id }; return nil }())) {
            session.browserBookmark = bookmark
            if let identity = Self.placeIdentity(location) {
                // A restored reference and its current live view are the same window.
                session.arrangement.places.removeAll { $0 != location && Self.placeIdentity($0) == Self.placeIdentity(bookmark) }
                session.browserBookmarks[identity] = bookmark
                let retained = Set(session.arrangement.places.compactMap(Self.placeIdentity))
                session.browserBookmarks = session.browserBookmarks.filter { retained.contains($0.key) }
            }
        }
        if case .record(let tool, _, _) = location,
           ["read_file", "read_skill", "recall_memory", "read_page", "read_chat_message"].contains(tool) {
            session.document = evidence.map {
                .init(location: location, fingerprint: $0.fingerprint)
            }
        }
        sessions[key] = session
    }

    func clearSource(key: String) { sessions[key]?.document = nil }

    func finishDraft(_ form: AgentWorkspaceForm, key: String) {
        let identity = "draft:" + form.draftID.uuidString
        sessions[key]?.arrangement.drafts.removeAll { $0.draftID == form.draftID }
        sessions[key]?.arrangement.places.removeAll { Self.placeIdentity($0) == identity }
        sessions[key]?.arrangement.path.removeAll { Self.placeIdentity($0) == identity }
        guard var session = sessions[key] else { return }
        for index in session.arrangement.saved.indices {
            session.arrangement.saved[index].places.removeAll { Self.placeIdentity($0) == identity }
            session.arrangement.saved[index].path.removeAll { Self.placeIdentity($0) == identity }
            if Self.placeIdentity(session.arrangement.saved[index].current) == identity { session.arrangement.saved[index].current = .home }
        }
        if session.arrangement.path.isEmpty { session.arrangement.path = [.home] }
        sessions[key] = session
    }

    static let referenceState = "Reference; current evidence is read on reopen."

    static func recognition(_ location: AgentWorkspaceLocation) -> JSONValue {
        var row: [String: JSONValue] = ["state": .string(referenceState)]
        switch location {
        case .form(let form):
            row["state"] = .string("Unfinished draft; reopening never submits it. Supported inputs survive restart when desktop storage is saved.")
            row["purpose"] = .string(form.title)
        case .page(let source, let page):
            row["source"] = .string(source.title); row["page"] = .int(Int64(page + 1))
        case .work(let query), .documents(let query), .find(let query): row["subject"] = .string(query)
        case .browserBookmark(let url, _, _): row["source"] = .string(url)
        case .record(_, let input, _):
            for key in ["path", "query", "url", "name", "offset", "handle", "conversation", "conversation_session_id"] {
                if let value = input[key] { row[key] = value }
            }
            if input["version"] != nil || input["expected_content_sha256"] != nil {
                row["reading_position"] = .string("Retained with a source version; the owner refuses a changed source.")
            }
        default: break
        }
        return .object(row)
    }

    /// Entering Home preserves the trail and prior action references.
    func enterHome(key: String) {
        guard var session = sessions[key] else { return }
        session.switchingWindow = false
        session.controlsExpanded = false
        if session.arrangement.path.last != .home {
            session.arrangement.path.append(.home)
            if session.arrangement.path.count > 8 { session.arrangement.path.removeFirst(session.arrangement.path.count - 8) }
        }
        sessions[key] = session
    }

    func places(key: String) -> [AgentWorkspaceLocation] { sessions[key]?.arrangement.places ?? [] }
    func drafts(key: String) -> [AgentWorkspaceForm] { sessions[key]?.arrangement.drafts ?? [] }

    func back(key: String) -> AgentWorkspaceLocation {
        if (sessions[key]?.arrangement.path.count ?? 0) > 1 { sessions[key]?.arrangement.path.removeLast() }
        sessions[key]?.retireButtons()
        return current(key: key)
    }

    func returnToWork(key: String) -> AgentWorkspaceLocation {
        guard var session = sessions[key], let anchor = session.arrangement.workAnchor else { return current(key: key) }
        if let index = session.arrangement.path.lastIndex(of: anchor) { session.arrangement.path = Array(session.arrangement.path.prefix(index + 1)) }
        else { session.arrangement.path = [.home, anchor] }
        session.retireButtons()
        session.document = nil
        sessions[key] = session
        return current(key: key)
    }

    func present(_ projection: WorkspacePage, key: String, outcome: JSONValue) -> JSONValue {
        let projection = AgentWorkspaceReadiness.filter(projection)
        guard var session = sessions[key] else { return .object(["status": .string("unavailable")]) }
        session.retireButtons()
        session.issuedAt = Date()
        // Retired references keep their names within the bound; the session counter never reuses an id.
        if session.buttonPrefix.isEmpty {
            session.buttonPrefix = String((0..<4).map { _ in "abcdefghijkmnpqrstuvwxyz23456789".randomElement()! })
        }
        var items: [JSONValue] = []
        for item in projection.items.dropFirst(projection.page * 8).prefix(8) {
            let savedWorkspace = item.actions.contains { if case .restoreWorkspace = $0.action { return true }; return false }
            let controls = Self.renderButtons(item.actions, limit: savedWorkspace ? item.actions.count : 2, session: &session)
            items.append(.object(["title": .string(String(item.title.prefix(300))), "content": item.content,
                                  "actions": .array(controls)]))
        }
        var actions: [AgentWorkspaceButton] = projection.actions
        if case .record("browser.chrome_snapshot", _, _)? = session.arrangement.path.last,
           let identity = session.arrangement.path.last.flatMap(Self.placeIdentity),
           case .browserBookmark(let url, let title, _)? = session.browserBookmarks[identity],
           case .object(let content) = projection.content, content["snapshotId"] == nil {
            actions.insert(.init(label: "Open saved page in my browser tab", action: .perform(
                tool: "browser.chrome_navigate", input: ["url": .string(url)],
                title: title, textField: nil, isEffect: true)), at: 0)
        }
        if let source = session.document {
            if session.arrangement.path.last == source.location {
                // Kept discussions reuse exact owner bindings without reading contacts or choosing protocol identities.
                let discussions = session.arrangement.keptPlaces.reversed().compactMap { place -> AgentWorkspaceButton? in
                    guard case .record("agent_read", let input, let title) = place,
                          case .string(let agent)? = input["agent"],
                          !["conversation_id", "message_id", "task_id"].contains(where: { input[$0] != nil }) else { return nil }
                    let conversation: String?
                    if agent.hasPrefix("bot:") { conversation = nil }
                    else if case .string(let label)? = input["conversation"], !label.isEmpty { conversation = label }
                    else { return nil }
                    return .init(label: "Discuss with " + title,
                        action: .message(agent: agent, conversation: conversation, name: title, document: source), needsText: true)
                }
                actions += discussions.prefix(3)
            }
            if session.arrangement.path.last != source.location {
                actions.append(.init(label: "Return to " + source.location.title, action: .open(source.location)))
            }
            actions.append(.init(label: "Discuss " + source.location.title + " with…", action: .open(.people(page: 0))))
            actions.append(.init(label: "Put selected source away", action: .clearSource))
        }
        actions += [
            .init(label: "This work", action: .open(.workOverview)),
            .init(label: "Workspace home", action: .open(.home)),
            .init(label: "Find", action: .find, needsText: true),
            .init(label: "Arrivals", action: .open(.arrivals)),
            .init(label: "Open places", action: .open(.openPlaces)),
            .init(label: session.controlsExpanded ? "Hide workspace controls" : "Show workspace controls", action: .workspaceControls)
        ]
        if let current = session.arrangement.path.last, let keep = Self.keepablePlace(current, session: session),
           !session.arrangement.keptPlaces.contains(where: { Self.placeIdentity($0) == Self.placeIdentity(keep) }),
           Self.actedOn(keep, session: session) {
            actions.append(.init(label: "Keep with this work", action: .keepWorkPlace(keep)))
        }
        if session.controlsExpanded {
            actions += [
            .init(label: "Conversations", action: .open(.conversations(page: 0))),
            .init(label: "Saved workspaces", action: .open(.savedWorkspaces)),
            .init(label: "Keep this workspace as…", action: .saveWorkspace, needsText: true),
            .init(label: "Find an action", action: .findCapability, needsText: true)
            ]
        }
        if let previous = session.arrivalReturn?.path.last {
            actions.insert(.init(label: "Return to " + previous.title, action: .returnFromArrival), at: 0)
        }
        if session.arrivalReturn == nil, let anchor = session.arrangement.workAnchor, anchor != session.arrangement.path.last {
            actions.append(.init(label: "Return to original work", action: .returnToWork))
        }
        if let current = session.arrangement.path.last, case .record = current, let query = session.arrangement.workTopic {
            actions.append(.init(label: "Related documents", action: .open(.documents(query))))
        }
        if session.controlsExpanded { actions += [
            .init(label: "Find work", action: .findWork, needsText: true),
            .init(label: "Find a document", action: .findDocument, needsText: true),
            .init(label: "People and agents", action: .open(.people(page: 0)))
        ] }
        if session.arrivalReturn == nil, session.arrangement.path.count > 1 {
            actions.append(.init(label: "Back to " + session.arrangement.path[session.arrangement.path.count - 2].title, action: .back))
        }
        if let current = session.arrangement.path.last {
            let source: AgentWorkspaceLocation
            if case .page(let original, _) = current { source = original } else { source = current }
            if (projection.page + 1) * 8 < projection.items.count {
                actions.append(.init(label: "More items", action: .open(.page(source, projection.page + 1))))
            }
            if projection.page > 0 {
                actions.append(.init(label: "Previous items", action: .open(.page(source, projection.page - 1))))
            }
        }
        // The window strip uses resident references without polling owners or retaining live control handles.
        let windows = Self.windowTitle(session).prefix(18).map { place, title -> JSONValue in
            let selected = Self.placeIdentity(place) == session.arrangement.path.last.flatMap(Self.placeIdentity)
            let buttons = Self.renderButtons([.init(label: "Open " + title, action: .window(Self.windowAction(place)))], limit: 1, session: &session)
            return .object(["title": .string(title), "kind": .string(Self.placeKind(place)),
                "selected": .bool(selected), "actions": .array(buttons)])
        }
        let controls = Self.renderButtons(actions, limit: 40, session: &session)
        let path = session.arrangement.path.map { JSONValue.string(String($0.title.prefix(300))) }
            .reduce(into: [JSONValue]()) { if $0.last != $1 { $0.append($1) } }
        sessions[key] = session
        var frame: [String: JSONValue] = [
            "status": outcome, "workspace": .string(projection.title), "path": .array(path),
            "content": projection.content, "items": .array(items), "actions": .array(controls),
            "windows": .array(windows),
            "total_items": .int(Int64(projection.items.count)), "page": .int(Int64(projection.page))
        ]
        // Honest counts: a capped list says how much of it this is.
        let total = projection.items.count, first = projection.page * 8
        if total > 8 || projection.page > 0 {
            frame["showing"] = .string("items \(min(total, first + 1))–\(min(total, first + 8)) of \(total)"
                + (first + 8 < total ? "; \"More items\" shows the next" : ""))
        }
        return .object(frame)
    }

    private static func renderButtons(_ values: [AgentWorkspaceButton], limit: Int,
                                      session: inout Session) -> [JSONValue] {
        var values = values
        if let document = session.document {
            for value in values {
                if case .message(let agent, let conversation, let name, nil) = value.action {
                    values.append(.init(label: "Discuss " + document.location.title,
                        action: .message(agent: agent, conversation: conversation, name: name, document: document), needsText: true))
                }
            }
        }
        var rendered: [JSONValue] = []
        for var value in values.prefix(limit) {
            if session.buttons.count == 176, let retired = session.buttons.filter({ $0.value.retired }).keys.min(by: {
                (Int($0.split(separator: ".").last ?? "") ?? 0) < (Int($1.split(separator: ".").last ?? "") ?? 0)
            }) { session.buttons.removeValue(forKey: retired) }
            guard session.buttons.count < 176 else { break }
            session.buttonCount += 1
            let id = session.buttonPrefix + "." + String(session.buttonCount)
            if case .form(let form)? = session.arrangement.path.last { value.viewName = form.lastingName }
            else if let place = session.arrangement.path.last, place != .home {
                value.viewName = Self.recognizedPlaces(session).contains(place)
                    ? Self.windowReference(place) : HerScreen.textRoomName(place)
            }
            session.buttons[id] = value
            // An item of home's: app {item: id}, with args.text when it needs text.
            rendered.append(.object(["label": .string(String(value.label.prefix(200))),
                "item": .string(id), "needs_text": .bool(value.needsText)]))
        }
        return rendered
    }

}
