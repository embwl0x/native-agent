import Foundation
import PersistenceCore

extension AgentWorkspaceNavigation {
    struct DesktopFailure: Error, LocalizedError {
        let message: String
        var errorDescription: String? { message }
    }

    func restoredSession(dataRoot: URL?, scope: String?) -> Session {
        var session = Session()
        guard let dataRoot, let scope else { return session }
        let store = AgentWorkspaceDesktopStore(dataRoot: dataRoot, scope: scope)
        session.store = store
        do {
            if let saved = try store.load() {
                // Restored windows sit beside each other: Home, then the one that was open.
                session.path = saved.path.last.map { $0 == .home ? [.home] : [.home, $0] }
                    ?? (saved.current == .home ? [.home] : [.home, saved.current])
                session.drafts = saved.drafts
                session.places = saved.places
                session.workAnchor = saved.workAnchor
                session.workTopic = saved.workTopic
                session.saved = saved.saved
                session.selectedWorkspaceID = saved.selectedWorkspaceID
                session.workNote = saved.workNote; session.keptPlaces = saved.keptPlaces
                session.focusedWork = saved.focusedWork; session.lastWorkAction = saved.lastWorkAction
                session.placeActions = saved.placeActions
                session.lastPersisted = saved
                session.observations = saved.observations
            }
        } catch {
            session.needsStorageReload = true
            session.persistenceIssue = "Saved workspace storage is unavailable. Its bytes were preserved; current navigation remains temporary. " + error.localizedDescription
        }
        // The people and helpers she already talks with are watched for
        // arrivals from the first look, but they are not windows: `windows`
        // lists only what she has open (desk walk 4: Goose, never opened, was
        // there; Codex and Grok, just read, were not). Home lists the people.
        let present = Set(session.places.compactMap { place -> String? in
            guard case .record("agent_read", let input, _) = place, case .string(let agent)? = input["agent"] else { return nil }
            return agent
        })
        session.watched = Self.conversationWindows(dataRoot: dataRoot).filter {
            guard case .record(_, let input, _) = $0, case .string(let agent)? = input["agent"] else { return false }
            return !present.contains(agent)
        }
        return session
    }

    /// Her newest conversation per contact, oldest first so the strip shows
    /// the most recent one nearest the front.
    private static func conversationWindows(dataRoot: URL) -> [AgentWorkspaceLocation] {
        let rows = (try? AgentConversationStore(dataRoot: dataRoot).records()) ?? []
        var windows: [(at: Date, agent: String, location: AgentWorkspaceLocation)] = rows.filter { $0.phase != "sending" }.map { row in
            var input: [String: JSONValue] = ["agent": .string(row.agent)]
            if !row.agent.hasPrefix("bot:") { input["conversation"] = .string(row.label) }
            return (row.updatedAt, row.agent, .record(tool: "agent_read", input: input, title: row.name))
        }
        // 2026-09-22: someone who only ever opened chats with her over the
        // bridge still gets their window; it lists those work sessions.
        let people = AgentWorkSession.people(dataRoot: dataRoot)
        let iso = ISO8601DateFormatter()
        iso.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        for session in AgentWorkSession.all(dataRoot: dataRoot) {
            guard let person = AgentWorkSession.owner(session.sender, people: people),
                  let at = iso.date(from: session.updatedAt) ?? ISO8601DateFormatter().date(from: session.updatedAt) else { continue }
            windows.append((at, person.agent, .record(tool: "agent_read", input: ["agent": .string(person.agent)], title: person.name)))
        }
        var seen: Set<String> = []
        return windows.sorted { $0.at > $1.at }
            .filter { seen.insert($0.agent).inserted }
            .prefix(6).reversed().map(\.location)
    }

    private static func durable(_ location: AgentWorkspaceLocation, session: Session) -> AgentWorkspaceLocation? {
        if case .form(let form) = location {
            guard let latest = session.drafts.first(where: { $0.draftID == form.draftID }), latest.canPersist else { return nil }
            return .form(latest)
        }
        if case .record(let tool, _, _) = location, tool == "browser.chrome_snapshot",
           let identity = placeIdentity(location), let bookmark = session.browserBookmarks[identity] { return bookmark }
        return AgentWorkspaceDesktopStore.durable(location)
    }

    private static func snapshot(_ session: Session) -> AgentWorkspaceDesktopState {
        var places: [AgentWorkspaceLocation] = []
        for place in session.places {
            if let value = durable(place, session: session) {
                if let identity = placeIdentity(value) {
                    places.removeAll { placeIdentity($0) == identity }
                } else {
                    places.removeAll { $0 == value }
                }
                places.append(value)
            }
        }
        let current = session.path.reversed().compactMap { place -> AgentWorkspaceLocation? in
            if case .savedWorkspaces = place { return nil }
            if case .workOverview = place { return nil }
            if case .openPlaces = place { return nil }
            if case .page(.openPlaces, _) = place { return nil }
            return durable(place, session: session)
        }.first ?? .home
        var saved = session.saved
        for index in saved.indices {
            saved[index].current = durable(saved[index].current, session: session) ?? .home
            saved[index].places = saved[index].places.compactMap { durable($0, session: session) }
            saved[index].path = saved[index].path.compactMap { durable($0, session: session) }
        }
        return .init(current: current, places: Array(places.suffix(24)),
                     workAnchor: session.workAnchor.flatMap { durable($0, session: session) },
                     workTopic: session.workTopic, saved: saved, selectedWorkspaceID: session.selectedWorkspaceID,
                     observations: session.observations,
                     path: Array(session.path.suffix(8).compactMap { durable($0, session: session) }),
                     drafts: session.drafts.filter(\.canPersist), workNote: session.workNote, keptPlaces: session.keptPlaces,
                     focusedWork: session.focusedWork, lastWorkAction: session.lastWorkAction, placeActions: session.placeActions)
    }

    func canEvict(_ session: Session) -> Bool {
        if session.drafts.isEmpty { return session.persistenceIssue == nil }
        return session.store != nil && session.persistenceIssue == nil && session.drafts.allSatisfy(\.canPersist)
            && session.lastPersisted == Self.snapshot(session)
    }

    /// Never enter an effect while disk still contains a ready-to-submit copy
    /// of these inputs. Failed storage must not turn restart into silent replay.
    func draftAttemptIsDurable(_ form: AgentWorkspaceForm, key: String) -> Bool {
        guard let session = sessions[key] else { return false }
        guard session.store != nil else { return true }
        guard session.persistenceIssue == nil, !session.needsStorageReload else { return false }
        let saved = session.lastPersisted?.drafts.first { $0.draftID == form.draftID }
        if !form.canPersist { return saved == nil }
        return saved?.needsOutcomeReview == true && saved?.draftValues == form.draftValues && saved?.bound == form.bound
    }

    /// Persistence is reported separately from the actual tool outcome. A disk
    /// failure must never turn a completed send/write into a request to replay.
    func persistDesktop(key: String) -> JSONValue {
        guard var session = sessions[key] else { return .object(["storage": .string("unavailable")]) }
        if session.needsStorageReload, let store = session.store, Date() >= session.nextPersistenceAttempt {
            do {
                if let previous = try store.load() {
                    let recovered = previous.drafts.filter { old in !session.drafts.contains { $0.draftID == old.draftID } }
                    guard session.drafts.count + recovered.count <= 4 else {
                        throw DesktopFailure(message: "Saved and resident drafts exceed four slots. Discard a resident draft before storage recovery; saved bytes remain intact.")
                    }
                    session.drafts += recovered
                    session.saved = previous.saved
                    session.observations = previous.observations
                    if session.path == [.home] {
                        session.path = previous.path.isEmpty ? [.home, previous.current] : previous.path
                        session.places = previous.places
                        session.workAnchor = previous.workAnchor; session.workTopic = previous.workTopic
                        session.selectedWorkspaceID = previous.selectedWorkspaceID
                        session.workNote = previous.workNote; session.keptPlaces = previous.keptPlaces
                        session.focusedWork = previous.focusedWork; session.lastWorkAction = previous.lastWorkAction
                        session.placeActions = previous.placeActions
                    }
                }
                session.needsStorageReload = false; session.persistenceIssue = nil
            } catch {
                session.persistenceIssue = "Saved workspace could not be recovered; existing bytes and resident drafts are preserved. " + error.localizedDescription
                session.nextPersistenceAttempt = Date().addingTimeInterval(5)
            }
        }
        var snapshot = Self.snapshot(session)
        if let id = session.selectedWorkspaceID, let index = session.saved.firstIndex(where: { $0.id == id }) {
            snapshot.saved[index].current = snapshot.current
            snapshot.saved[index].places = snapshot.places
            snapshot.saved[index].workAnchor = snapshot.workAnchor
            snapshot.saved[index].workTopic = snapshot.workTopic
            snapshot.saved[index].workNote = snapshot.workNote
            snapshot.saved[index].keptPlaces = snapshot.keptPlaces
            snapshot.saved[index].focusedWork = snapshot.focusedWork
            snapshot.saved[index].lastWorkAction = snapshot.lastWorkAction
            snapshot.saved[index].placeActions = snapshot.placeActions
            snapshot.saved[index].path = snapshot.path.filter {
                if case .savedWorkspaces = $0 { return false }
                return true
            }
            session.saved = snapshot.saved
        }
        if let store = session.store, !session.needsStorageReload, Date() >= session.nextPersistenceAttempt,
           snapshot != session.lastPersisted || session.persistenceIssue != nil {
            do { try store.save(snapshot); session.lastPersisted = snapshot; session.persistenceIssue = nil }
            catch {
                session.nextPersistenceAttempt = Date().addingTimeInterval(5)
                session.persistenceIssue = "Navigation could not be saved. A later workspace action will retry storage only; the tool outcome is unchanged and no effect is repeated. " + error.localizedDescription
            }
        }
        sessions[key] = session
        let name = session.saved.first(where: { $0.id == session.selectedWorkspaceID })?.name ?? "Current workspace"
        let current = session.path.last ?? .home
        let selected = Self.placeIdentity(current).flatMap { session.browserBookmarks[$0] } ?? current
        var metadata: [String: JSONValue] = [
            "name": .string(name), "selected_place": .string(selected.title),
            "open_places": .array(Self.recognizedPlaces(session).map { .string($0.title) }),
            "storage": .string(session.persistenceIssue != nil ? "unavailable" : session.store == nil ? "temporary" : session.drafts.contains(where: { !$0.canPersist }) ? "saved_with_temporary_drafts" : "saved"),
            "unfinished_drafts": .int(Int64(session.drafts.count)),
            "temporary_drafts": .int(Int64(session.drafts.filter { !$0.canPersist }.count)),
            "meaning": .string("Arrangement, eight Back positions and up to four supported drafts are scoped to this chat. Restart restores inputs, never approvals, browser leases, loaded evidence or running actions. Current schemas, owners and permissions are rechecked before use.")
        ]
        if let issue = session.persistenceIssue { metadata["attention"] = .string(issue) }
        if let note = session.workNote {
            metadata["continuation_note"] = .string(String(note.prefix(240)))
            metadata["note_source"] = .string("Your saved work note; open This work for the full note and attached places.")
        }
        if !session.keptPlaces.isEmpty { metadata["kept_with_work"] = .int(Int64(session.keptPlaces.count)) }
        if let notice = session.workLinkNotice { metadata["work_attention"] = .string(notice) }
        if session.focusedWork { metadata["opened_sources_stay_with_work"] = .bool(true) }
        if let receipt = Self.placeAction(selected, session: session) { metadata["last_action_here"] = receipt }
        else if let receipt = session.lastWorkAction { metadata["last_work_action"] = receipt.value }
        return .object(metadata)
    }

    private func requireName(_ name: String, session: Session, replacing: String? = nil) throws {
        guard !name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty, name.count <= 120,
              !name.unicodeScalars.contains(where: { CharacterSet.controlCharacters.contains($0) }) else {
            throw DesktopFailure(message: "Use a short readable workspace name, up to 120 characters.")
        }
        guard !session.saved.contains(where: { $0.id != replacing && $0.name.caseInsensitiveCompare(name) == .orderedSame }) else {
            throw DesktopFailure(message: "That workspace name is already saved. Reopen it or choose a different name; nothing was replaced.")
        }
        if session.persistenceIssue != nil {
            throw DesktopFailure(message: "Workspace storage is unavailable. Existing saved arrangements were preserved; this change was not saved.")
        }
    }

    func saveWorkspace(name: String, empty: Bool, key: String) throws -> AgentWorkspaceLocation {
        guard var session = sessions[key] else { throw DesktopFailure(message: "Open your workspace first.") }
        try requireName(name, session: session)
        guard session.saved.count < 12 else { throw DesktopFailure(message: "Twelve workspaces are already saved. Forget an old arrangement before saving another; its files and work will remain intact.") }
        let state = Self.snapshot(session)
        let entry = AgentWorkspaceSavedDesktop(name: name, current: empty ? .home : state.current,
            places: empty ? [] : state.places, workAnchor: empty ? nil : state.workAnchor,
            workTopic: empty ? nil : state.workTopic, path: empty ? [.home] : state.path,
            workNote: empty ? nil : state.workNote, keptPlaces: empty ? [] : state.keptPlaces,
            focusedWork: empty ? false : state.focusedWork, lastWorkAction: empty ? nil : state.lastWorkAction,
            placeActions: empty ? [:] : state.placeActions)
        session.saved.append(entry)
        session.selectedWorkspaceID = entry.id
        if empty {
            session.path = [.home]; session.places = []; session.workAnchor = nil
            session.workTopic = nil; session.document = nil; session.browserBookmark = nil
            session.workNote = nil; session.keptPlaces = []
            session.workLinkNotice = nil
            session.focusedWork = false; session.lastWorkAction = nil
            session.placeActions = [:]
            session.browserBookmarks = [:]
            session.arrivalReturn = nil
        }
        sessions[key] = session
        return empty ? .home : .savedWorkspaces
    }

    func restoreWorkspace(id: String, key: String) throws -> AgentWorkspaceLocation {
        guard var session = sessions[key], let saved = session.saved.first(where: { $0.id == id }) else {
            throw DesktopFailure(message: "That saved workspace is no longer available in this chat. Nothing was restarted.")
        }
        let residentDrafts = session.drafts
        func refreshed(_ location: AgentWorkspaceLocation) -> AgentWorkspaceLocation? {
            if case .form(let form) = location {
                return residentDrafts.first(where: { $0.draftID == form.draftID }).map(AgentWorkspaceLocation.form)
            }
            return location
        }
        session.path = (saved.path.isEmpty ? [.home, saved.current] : saved.path).compactMap(refreshed)
        if session.path.isEmpty { session.path = [.home] }
        session.places = saved.places.compactMap(refreshed); session.workAnchor = saved.workAnchor; session.workTopic = saved.workTopic
        session.workNote = saved.workNote; session.keptPlaces = saved.keptPlaces
        session.focusedWork = saved.focusedWork; session.lastWorkAction = saved.lastWorkAction
        session.placeActions = saved.placeActions
        session.workLinkNotice = nil
        session.document = nil; session.browserBookmark = nil; session.buttons = [:]
        session.browserBookmarks = [:]
        session.arrivalReturn = nil
        session.selectedWorkspaceID = saved.id
        sessions[key] = session
        return session.path.last ?? .home
    }

    func renameWorkspace(id: String, name: String, key: String) throws {
        guard var session = sessions[key], let index = session.saved.firstIndex(where: { $0.id == id }) else {
            throw DesktopFailure(message: "That saved workspace is no longer available.")
        }
        try requireName(name, session: session, replacing: id)
        session.saved[index].name = name
        sessions[key] = session
    }

    func forgetWorkspace(id: String, key: String) throws {
        guard var session = sessions[key], session.persistenceIssue == nil else {
            throw DesktopFailure(message: "Workspace storage is unavailable. Saved arrangements were preserved.")
        }
        session.saved.removeAll { $0.id == id }
        if session.selectedWorkspaceID == id { session.selectedWorkspaceID = nil }
        sessions[key] = session
    }

    func closePlace(_ location: AgentWorkspaceLocation, key: String) {
        guard var session = sessions[key] else { return }
        let identity = Self.placeIdentity(location)
        session.places.removeAll { Self.placeIdentity($0) == identity }
        if session.workAnchor == location { session.workAnchor = nil; session.workTopic = nil }
        if session.document?.location == location { session.document = nil }
        // Keep closed references out of saved selection and Back history too.
        let oldSession = session
        session.path.removeAll { location in
            guard let identity else { return false }
            if Self.placeIdentity(location) == identity { return true }
            return Self.durable(location, session: oldSession).map { Self.placeIdentity($0) == identity } ?? false
        }
        if session.path.isEmpty { session.path = [.home] }
        sessions[key] = session
    }

    func savedWorkspaces(key: String) -> AgentWorkspaceProjection {
        let session = sessions[key] ?? Session()
        return .init(title: "Saved workspaces", content: .object([
            "status": .string(session.persistenceIssue == nil ? "ok" : "unavailable"),
            "message": .string(session.persistenceIssue ?? "Named arrangements in this chat. Reopen restores places and reads the selected owner. Saving and switching never resumes work or sends a message; forgetting only removes the saved arrangement.")]),
            items: session.saved.map { saved in
                var content: [String: JSONValue] = [
                    "selected_place": .string(saved.current.title),
                    "selected_kind": .string(Self.placeKind(saved.current)),
                    "open_place_count": .int(Int64(saved.places.count)),
                    "recent_places": .array(saved.places.suffix(3).reversed().map { .string($0.title) }),
                    "active": .bool(saved.id == session.selectedWorkspaceID),
                    "evidence": .string("Saved references; current content is read on reopen.")
                ]
                if let topic = saved.workTopic { content["work_topic"] = .string(String(topic.prefix(160))) }
                if let note = saved.workNote { content["continuation_note"] = .string(String(note.prefix(400))) }
                content["kept_with_work"] = .array(saved.keptPlaces.map { .string($0.title) })
                content["opened_sources_stay_with_work"] = .bool(saved.focusedWork)
                if let receipt = saved.lastWorkAction { content["last_action"] = receipt.value }
                let draftIDs = Set(([saved.current] + saved.places).compactMap { location -> UUID? in
                    if case .form(let form) = location { return form.draftID }
                    return nil
                })
                let drafts = session.drafts.filter { draftIDs.contains($0.draftID) }
                content["unfinished_drafts"] = .int(Int64(drafts.count))
                content["drafts_needing_attention"] = .int(Int64(drafts.filter { $0.needsOutcomeReview || $0.schemaIssue != nil }.count))
                return .init(title: saved.name, content: .object(content), actions: [
                        .init(label: "Reopen workspace", action: .restoreWorkspace(saved.id)),
                        .init(label: "Rename workspace", action: .renameWorkspace(saved.id), needsText: true),
                        .init(label: "Forget saved arrangement", action: .forgetWorkspace(saved.id))
                    ])
            }, actions: [.init(label: "Start a workspace named…", action: .newWorkspace, needsText: true)])
    }
}
