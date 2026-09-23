import Foundation
import PersistenceCore

extension AgentWorkspaceNavigation {
    /// Distinguish same-titled windows without exposing routing handles.
    /// Ordering by resident identity keeps labels stable across recency changes.
    static func windowTitle(_ place: AgentWorkspaceLocation, session: Session) -> String {
        func title(_ value: AgentWorkspaceLocation) -> String {
            let display = placeIdentity(value).flatMap { session.browserBookmarks[$0] } ?? value
            let name = String(display.title.prefix(130))
            if case .browserBookmark(_, _, nil) = display { return name + " (saved source)" }
            return name
        }
        let name = title(place)
        let matches = recognizedPlaces(session).filter { title($0) == name }
            .sorted {
                let left = placeIdentity($0).flatMap { session.browserBookmarks[$0] } ?? $0
                let right = placeIdentity($1).flatMap { session.browserBookmarks[$0] } ?? $1
                return (placeIdentity(left) ?? "") < (placeIdentity(right) ?? "")
            }
        guard matches.count > 1, let index = matches.firstIndex(where: { samePlace($0, place) }) else { return name }
        return name + " (window \(index + 1))"
    }
    /// Explicitly selecting an app window brings that app forward through the
    /// normal Mac owner. Refresh/Back/restoration remain observations only.
    static func windowAction(_ place: AgentWorkspaceLocation) -> AgentWorkspaceAction {
        if case .browserBookmark(let url, let title, let tabID) = place, let tabID {
            return .perform(tool: "browser.chrome_acquire", input: ["mode": .string("claim"),
                "tab_id": .int(tabID), "expected_url": .string(url), "expected_title": .string(title)],
                title: title, textField: nil, isEffect: true)
        }
        if case .record("screen", let input, let title) = place, case .string(let app)? = input["app"] {
            return .perform(tool: "go", input: ["name": .string(app)], title: title, textField: nil, isEffect: true)
        }
        return .open(place)
    }
    /// The strip's selection for a window or place named exactly (any case).
    /// Several same-named windows open none; the query falls through to Find.
    func window(named query: String, key: String) -> AgentWorkspaceAction? {
        guard let session = sessions[key] else { return nil }
        let name = query.lowercased()
        let places = Self.recognizedPlaces(session).filter {
            Self.windowTitle($0, session: session).lowercased() == name || $0.title.lowercased() == name }
        if places.count > 1 { return nil }
        if let place = places.first { return .window(Self.windowAction(place)) }
        return AgentWorkspaceEnvironment.destinations.first { $0.title.lowercased() == name }.map { .open(.area($0.id)) }
    }
    /// Recognition uses only this chat's bounded resident references. Listing
    /// does not read transcripts, acknowledge arrivals, or refresh owner state.
    func recognizedOpenPlaces(key: String) -> AgentWorkspaceProjection {
        let session = sessions[key] ?? Session()
        let places = Self.recognizedPlaces(session)
        let current = session.path.reversed().first { !Self.isOverview($0) }
        let returning = session.arrivalReturn?.path.last
        let items = places.map { location -> AgentWorkspaceItem in
            let display = Self.placeIdentity(location).flatMap { session.browserBookmarks[$0] } ?? location
            var content = Self.placeRecognition(display)
            if let receipt = Self.placeAction(display, session: session) { content["last_action_here"] = receipt }
            let group = Self.placeGroup(location, session: session)
            content["group"] = .string(group)
            if Self.samePlace(location, current) { content["context"] = .string("Last selected place") }
            if Self.samePlace(location, session.workAnchor) { content["work_context"] = .string(session.workTopic ?? "Current work") }
            if Self.samePlace(location, returning) { content["return_point"] = .bool(true) }
            let close: AgentWorkspaceButton
            let openLabel: String
            if case .form(let form) = location {
                close = .init(label: "Discard draft", action: .discardDraft(form))
                openLabel = form.needsOutcomeReview ? "Review previous outcome" : "Continue draft"
            } else {
                close = .init(label: "Close place", action: .closePlace(location))
                openLabel = "Open"
            }
            return .init(title: Self.windowTitle(location, session: session), content: .object(content), actions: [
                .init(label: openLabel, action: Self.windowAction(location)), close
            ])
        }
        let groups = ["Needs attention", "Unfinished drafts", "Return to work", "Recent places"]
        let counts = groups.compactMap { group -> JSONValue? in
            let count = places.filter { Self.placeGroup($0, session: session) == group }.count
            return count == 0 ? nil : .object(["name": .string(group), "count": .int(Int64(count))])
        }
        return .init(title: "Open places", content: .object([
            "status": .string("ok"), "groups": .array(counts),
            "message": .string("Unfinished work first, then your return point and recent places. These are saved references; opening reads current evidence. Closing a place leaves its owner unchanged. Discarding a draft removes its entered work.")
        ]), items: items, actions: [])
    }

    /// Home exposes only meaningful continuation controls, not a duplicate
    /// list of every recent place. It neither moves selection nor reads owners.
    func workspaceHomeOverview(key: String) -> (content: JSONValue, actions: [AgentWorkspaceButton]) {
        let session = sessions[key] ?? Session()
        let all = recognizedOpenPlaces(key: key).items
        let important = all.filter { item in
            guard case .object(let row) = item.content else { return false }
            return row["group"] != .string("Recent places")
        }
        let actions = important.prefix(3).compactMap { item -> AgentWorkspaceButton? in
            guard var action = item.actions.first else { return nil }
            action.label += ": " + String(item.title.prefix(100))
            return action
        }
        var content: [String: JSONValue] = [
            "open_places": .int(Int64(all.count)),
            "unfinished_drafts": .int(Int64(session.drafts.count)),
            "drafts_needing_attention": .int(Int64(session.drafts.filter { $0.needsOutcomeReview || $0.schemaIssue != nil }.count))
        ]
        if let topic = session.workTopic { content["work_topic"] = .string(String(topic.prefix(160))) }
        if let returning = session.arrivalReturn?.path.last,
           let valid = Self.recognizedPlaces(session).first(where: { Self.samePlace($0, returning) }) {
            content["return_to"] = .string(String(valid.title.prefix(160)))
        }
        return (.object(content), actions)
    }

    static func recognizedPlaces(_ session: Session) -> [AgentWorkspaceLocation] {
        var places: [AgentWorkspaceLocation] = []
        func append(_ location: AgentWorkspaceLocation) {
            let latest: AgentWorkspaceLocation
            if case .form(let form) = location {
                guard let resident = session.drafts.first(where: { $0.draftID == form.draftID }) else { return }
                latest = .form(resident)
            } else { latest = location }
            guard !places.contains(where: { samePlace($0, latest) }) else { return }
            places.append(latest)
        }
        // Drafts belong to the chat and remain reachable across arrangements.
        for draft in session.drafts.reversed() { append(.form(draft)) }
        if let returning = session.arrivalReturn?.path.last, !isOverview(returning) { append(returning) }
        if let anchor = session.workAnchor { append(anchor) }
        for location in session.places.reversed() { append(location) }
        return places.enumerated().sorted { lhs, rhs in
            let a = placePriority(lhs.element, session: session)
            let b = placePriority(rhs.element, session: session)
            return a == b ? lhs.offset < rhs.offset : a < b
        }.map(\.element)
    }

    private static func placePriority(_ location: AgentWorkspaceLocation, session: Session) -> Int {
        if case .form(let form) = location { return form.needsOutcomeReview || form.schemaIssue != nil ? 0 : 1 }
        if samePlace(location, session.arrivalReturn?.path.last) || samePlace(location, session.workAnchor) { return 2 }
        return 3
    }

    private static func placeGroup(_ location: AgentWorkspaceLocation, session: Session) -> String {
        ["Needs attention", "Unfinished drafts", "Return to work", "Recent places"][placePriority(location, session: session)]
    }

    private static func samePlace(_ lhs: AgentWorkspaceLocation, _ rhs: AgentWorkspaceLocation?) -> Bool {
        guard let rhs else { return false }
        if let a = placeIdentity(lhs), let b = placeIdentity(rhs) { return a == b }
        return lhs == rhs
    }

    private static func isOverview(_ location: AgentWorkspaceLocation) -> Bool {
        switch location {
        case .home, .openPlaces, .savedWorkspaces, .workOverview, .arrivals: return true
        case .page(let source, _): return isOverview(source)
        default: return false
        }
    }

    static func placeRecognition(_ location: AgentWorkspaceLocation) -> [String: JSONValue] {
        var content: [String: JSONValue] = [:]
        if case .object(let existing) = recognition(location) { content = existing }
        content["kind"] = .string(placeKind(location))
        if case .form(let form) = location {
            content["entered_fields"] = .int(Int64(form.draftValues.count))
            content["needs_attention"] = .bool(form.needsOutcomeReview || form.schemaIssue != nil)
            if form.needsOutcomeReview { content["state"] = .string("Previous attempt needs review; opening cannot repeat it.") }
            else if let issue = form.schemaIssue { content["state"] = .string(String(issue.prefix(240))) }
            for key in ["agent", "conversation", "path", "name"] {
                if let value = form.bound[key] ?? form.draftValues[key], case .string(let text) = value {
                    content[key] = .string(String(text.prefix(240)))
                }
            }
        }
        return content
    }

    static func placeKind(_ location: AgentWorkspaceLocation) -> String {
        switch location {
        case .form: return "Draft"
        case .work: return "Work"
        case .find, .documents, .capabilities: return "Findings"
        case .browserBookmark: return "Web page"
        case .people, .conversations: return "Conversations"
        case .area: return "Workspace area"
        case .page(let source, _): return placeKind(source)
        case .receipt: return "Outcome"
        case .record(let tool, _, _):
            switch tool {
            case "agent_read", "chat_conversations", "read_chat_message": return "Conversation"
            case "read_file": return "File"
            case "list_dir": return "Folder"
            case "read_page", "browser.chrome_snapshot": return "Web page"
            case "recall_memory", "recall_search": return "Memory"
            case "read_skill": return "Skill"
            case "work_context", "desk_read", "task_ledger_list": return "Work"
            case "messages_recent_threads": return "Messages"
            case "mail_list_recent": return "Mail"
            case "shelf_entry": return "Helper result"
            case "bot_list": return "Helper"
            case "screen": return "App window"
            case "mac_calendar_list_upcoming": return "Calendar"
            case "mac_reminders_list_due_today": return "Reminders"
            default: return "Reference"
            }
        default: return "Workspace"
        }
    }
}
