import NativeAgentShared
import Foundation
import NativeAgentCore
import PersistenceCore
import DeskCore
import SenseCore
// Blueprint: | `DeskActions+DeskTools.swift` | `SwiftToolDispatcher`; raw mutation admission; checked waits and close |

// Desk actions use this dispatcher’s data root and the single event-sourced personal store. DeskOp has no actor field; mutations use ledger_write authority.

func nonblankDoorText(_ text: String?) -> String? {
    text.trimmedNonEmpty == nil ? nil : text
}

extension SwiftToolDispatcher {
    static func validateDeskMutationArguments(_ tool: String, input: [String: JSONValue]) throws {
        let key: String
        switch tool {
        case "desk_blocked_on": key = DeskBlockedOnArgs.blockedOnField.name
        case "desk_defer": key = DeskDeferArgs.untilField.name
        default: return
        }
        guard case .string? = input[key] else {
            throw ToolFailureError("\(key) is required as a string; use an explicit empty string to clear it. Nothing was changed.",
                argumentPath: "$." + key, effects: .none, code: "invalid_input")
        }
    }

    func deskInvalid(_ field: String, reason: String) -> ToolFailureError {
        ToolFailureError(reason, argumentPath: "$." + field, effects: .none, code: "invalid_input")
    }

    func deskString(_ value: String?, _ key: String) throws -> String {
        guard let value, !value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw deskInvalid(key, reason: "\(key) must be a nonempty string.")
        }
        return value
    }

    /// An item filed with no project goes where its caller says the app files its own (`absent`). A project that is given must name one.
    func deskProject(_ value: String?, absent: String) throws -> String {
        guard let value else { return absent }
        guard !value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw deskInvalid("project", reason: "project must be a nonempty string; leave it out to file under \(absent).")
        }
        return value.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    func deskStore() -> SwiftNativeDeskStore {
        SwiftNativeDeskStore(dataRoot: dataRoot)
    }

    /// A peer's step is named by its contact, read as Home reads it; a contact book that cannot be read leaves the id the step recorded.
    func deskPeerName() -> (String) -> String? {
        do { return AgentScreen.peerName(identity: try AgentContactIdentity(dataRoot: dataRoot)) } catch { return { $0 } }
    }

    /// A committed effect remains committed when its confirmation cannot be read.
    func deskConfirm(_ store: SwiftNativeDeskStore, handle: String, prefix: String) async -> JSONValue {
        let state: DeskState
        do { state = try await store.liveState() }
        catch {
            let failure = ChatToolOutcome.failure(error: ToolFailureError(
                "\(prefix) committed for \(handle), but its current Desk state could not be read: \(error.localizedDescription)",
                effects: .occurred, owner: "Desk", code: "desk_confirmation_unavailable",
                instruction: "Repair the reported Desk read failure, then read this handle before repeating the mutation."), tool: "desk")
            var fields = JSONValue.objectOrEmpty(failure)
            fields["handle"] = .string(handle)
            return .object(fields)
        }
        let item = state.items.first { $0.handle == handle }
        let label: String
        if let item {
            // A person wait reads as the wait; otherwise the state in the words the Desk shows (an unstarted item is queued).
            let state = item.statusDescription.hasPrefix("waiting on ") ? item.statusDescription : item.spokenStatus
            // A prefix that is the state itself (a wait) is not said a second time.
            label = "\(item.alias) \(item.kind.rawValue) " + (state == prefix ? "" : "(\(state)) ") + item.displayTitle(dataRoot: dataRoot, peerName: deskPeerName())
        } else {
            label = handle
        }
        return .object([
            "status": .string("ok"),
            "handle": .string(handle),
            "confirmation": .string("\(prefix): \(label)"),
        ])
    }

    func deskCSV(_ value: String?) -> [String] {
        guard let raw = value else { return [] }
        return raw.split(separator: ",")
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
    }

    static let deskItemTools: Set<String> = [
        "desk_set_status", "desk_wait", "desk_update_item", "desk_note", "desk_add_ref", "desk_set_cadence", "desk_set_notify",
        "desk_close", "desk_archive", "desk_blocked_on", "desk_defer", "desk_work_log",
    ]

    func deskHeld(_ handle: String) async throws -> JSONValue? {
        guard let conflict = try await deskStore().runHold(handle) else { return nil }
        return conflict.refusal(handle)
    }

    /// Resolve against the mutation snapshot to avoid targeting a different item.
    func resolveDeskHandle(_ input: [String: JSONValue], in state: DeskState) throws -> String {
        guard case .string(let raw)? = input["handle"] else {
            throw ToolFailureError("Supply the item's handle from desk.read.", argumentPath: "$.handle", effects: .none, code: "invalid_input")
        }
        return try resolveDeskRef(raw, in: state)
    }

    func resolveDeskRef(_ raw: String, in state: DeskState, field: String = "handle") throws -> String {
        let r = DeskState.reference(raw)
        guard !r.isEmpty else {
            throw deskInvalid(field, reason: "\(field) must not be empty.")
        }
        let matches = try state.matching(raw, field: field)
        if matches.count == 1 { return matches[0].handle }
        throw deskInvalid(field, reason: "No live item has handle '\(r)'; desk.read lists the current handles.")
    }

    /// Display-only `laneOf` requires a live reference at the tool boundary.
    private func resolveDeskLaneRef(_ raw: String, in state: DeskState, updating handle: String? = nil) throws -> String {
        let reference = DeskState.reference(raw)
        guard !reference.isEmpty else {
            throw deskInvalid("lane_of", reason: "desk: empty lane_of reference")
        }
        // A numbered label ("2 Renew insurance") names its item the same way every Desk reference does.
        let named = try? state.matching(raw, field: "lane_of")
        guard let laneParent = state.items.first(where: { $0.handle == reference || $0.alias == reference })
                ?? (named?.count == 1 ? named?.first : nil) else {
            throw deskInvalid("lane_of",
                reason: "desk: lane_of '\(reference)' is not a live Desk item"
            )
        }
        guard laneParent.handle != handle else {
            throw deskInvalid("lane_of", reason: "desk_set_status: an item cannot be its own lane_of parent")
        }
        return laneParent.handle
    }

    // MARK: - desk_add_item

    func impl_desk_add_item(input: DeskAddItemArgs) async throws -> JSONValue {
        let kind = try deskKind(input.kind, "kind")
        let title = try deskString(input.title, "title").trimmingCharacters(in: .whitespacesAndNewlines)
        let parentRaw = input.parent.trimmedNonEmpty
        let summary = input.summary.trimmedNonEmpty
        let assignee = input.assignee.trimmedNonEmpty
        let laneRaw = input.laneOf.trimmedNonEmpty
        let until = input.until.trimmedNonEmpty
        let deferred = input.deferred.trimmedNonEmpty
        if let until, let deferred, until != deferred {
            throw deskInvalid("until", reason: "desk_add_item: until and defer must agree")
        }
        let park = until ?? deferred
        if let park, !DeskClock.isParseableDate(park) {
            throw deskInvalid("until", reason: "desk_add_item: until must be yyyy-MM-dd or an ISO timestamp; nothing was added")
        }
        // Persist stable parent handles rather than display numbers.
        let state = try await deskStore().liveState()
        let parent: String? = (parentRaw?.isEmpty == false) ? try resolveDeskRef(parentRaw!, in: state, field: "parent") : nil
        let laneOf: String? = (laneRaw?.isEmpty == false) ? try resolveDeskLaneRef(laneRaw!, in: state) : nil
        // A part filed with no project goes under its parent's, as a breakdown's parts do; with no parent, where the Desk files a person's task.
        let project = try deskProject(input.project, absent: parent.flatMap { handle in state.items.first { $0.handle == handle } }?.project
            ?? DeskItem.tasksProject)

        let allowDuplicate = input.allowDuplicate ?? false
        let store = deskStore()
        let result: SwiftNativeDeskStore.CreateResult
        if allowDuplicate {
            let item = try await store.createItem(
                kind: kind, project: project, title: title,
                parent: parent,
                summary: (summary?.isEmpty == false) ? summary : nil,
                assignee: (assignee?.isEmpty == false) ? assignee : nil,
                laneOf: laneOf
            )
            result = .init(item: item, reusedEquivalent: false)
        } else {
            result = try await store.createOrReuseEquivalentItem(
                kind: kind, project: project, title: title,
                parent: parent,
                summary: (summary?.isEmpty == false) ? summary : nil,
                assignee: (assignee?.isEmpty == false) ? assignee : nil,
                laneOf: laneOf
            )
        }
        let item = result.item
        if let park {
            let refusal: JSONValue? = try await SwiftNativePersistenceCore.withFileLock(store.opsPath) {
                if result.reusedEquivalent, let conflict = try await store.runHold(item.handle) { return conflict.refusal() }
                try await store.setDeferUntil(item.handle, until: park)
                return nil
            }
            if let refusal { return refusal }
        }
        return .object([
            "status": .string("ok"),
            "effects": .string(result.reusedEquivalent && park == nil ? "none" : "occurred"),
            "disposition": .string(result.reusedEquivalent ? "existing" : "created"),
            "created": .bool(!result.reusedEquivalent),
            "handle": .string(item.handle),
            "alias": .string(item.alias),
            "defer_until": (park ?? item.deferUntil).map(JSONValue.string) ?? .null,
            "next_call": .object(["tool": .string("app"), "input": .object([
                "action": .string("desk.read"), "args": .object(["handle": .string(item.handle)])])]),
            "confirmation": .string(result.reusedEquivalent
                ? "reused existing \(item.alias) \(item.kind.rawValue) \(item.project) · \(item.title)"
                : "created \(item.alias) \(item.kind.rawValue) \(item.project) · \(item.title)"),
        ])
    }

    // MARK: - desk_open_pursuit

    /// The sole chat path to an origin=agent pursuit; the store gates dossier sources and caps. Store refusals return their reason with status "refused".
    func impl_desk_open_pursuit(input: DeskOpenPursuitArgs) async throws -> JSONValue {
        let project = try deskProject(input.project, absent: DeskItem.workshopProject)
        let title = try deskString(input.title, "title").trimmingCharacters(in: .whitespacesAndNewlines)
        // The store owns refusal of empty pursuit fields.
        let why = (nonblankDoorText(input.why) ?? "")
        let doneLooksLike = (nonblankDoorText(input.doneLooksLike) ?? "")
        let abandonCondition = (nonblankDoorText(input.abandonCondition) ?? "")
        let privateName = nonblankDoorText(input.privateName)
        let dossier = PromotionDossier(citations: input.evidence)
        guard dossier.isValid else {
            throw deskInvalid("evidence", reason: "evidence must be an array of complete current citation records. Nothing was opened.")
        }
        let pursuit = Pursuit(
            why: why,
            evidence: dossier,
            doneLooksLike: doneLooksLike,
            maxSessions: input.maxSessions ?? Pursuit.defaultMaxSessions,
            maxDays: input.maxDays ?? Pursuit.defaultMaxDays,
            abandonCondition: abandonCondition,
            privateName: (privateName?.isEmpty == false) ? privateName : nil
        )
        let summary = nonblankDoorText(input.summary)
        let store = deskStore()
        do {
            let item = try await store.openPursuit(
                project: project, title: title, pursuit: pursuit,
                summary: (summary?.isEmpty == false) ? summary : nil
            )
            return .object([
                "status": .string("ok"),
                "handle": .string(item.handle),
                "alias": .string(item.alias),
                "confirmation": .string("opened pursuit \(item.alias) \(item.project) · \(item.title)"),
            ])
        } catch let e as DeskError {
            // Surface the store’s refusal so the model can adjust the dossier or scope.
            return .object([
                "status": .string("refused"),
                "reason": .string(e.errorDescription ?? "\(e)"),
            ])
        }
    }

    // MARK: - desk_work_log

    /// Append a pursuit receipt or ordinary item note.
    func impl_desk_work_log(input: DeskWorkLogArgs) async throws -> JSONValue {
        let handle = try deskString(input.handle, "handle")
        let receipt = try deskString(input.receipt, "receipt").trimmingCharacters(in: .whitespacesAndNewlines)
        guard !receipt.isEmpty else {
            throw deskInvalid("receipt", reason: "desk_work_log: receipt is empty")
        }
        let store = deskStore()
        do {
            _ = try await store.appendWorkReceipt(handle, receipt: receipt)
            return await deskConfirm(store, handle: handle, prefix: "work logged")
        } catch let e as DeskError {
            return .object([
                "status": .string("refused"),
                "reason": .string(e.errorDescription ?? "\(e)"),
            ])
        }
    }

    // MARK: - desk_set_status

    func impl_desk_set_status(invocation: ChatToolInvocation, input: DeskSetStatusArgs, state: DeskState) async throws -> JSONValue {
        let handle = try deskString(input.handle, "handle")
        let statusText = try deskString(input.status, "status").trimmingCharacters(in: .whitespacesAndNewlines)
        var statusRaw = statusText.lowercased()
        let inlineWaitingOn: String?
        let waitNote: String?
        // A person wait is a status write, including every supplied update.
        if statusRaw.hasPrefix("waiting on ") {
            inlineWaitingOn = String(statusText.dropFirst("waiting on ".count)).trimmingCharacters(in: .whitespacesAndNewlines)
            waitNote = input.reason.trimmedNonEmpty
            statusRaw = "blocked"
        } else { inlineWaitingOn = nil; waitNote = nil }
        // The workspace status action takes one text value; keep its reason's case.
        let inlineReason: String?
        if statusRaw.hasPrefix("blocked:") {
            statusRaw = "blocked"
            inlineReason = String(statusText.dropFirst("blocked:".count)).trimmingCharacters(in: .whitespacesAndNewlines)
        } else { inlineReason = nil }
        let synonyms = ["cancelled": "canceled", "cancel": "canceled", "dropped": "canceled", "complete": "done", "completed": "done",
                        "finished": "done", "closed": "done", "in_progress": "now", "in progress": "now", "active": "now",
                        "doing": "now", "working": "now", "started": "now", "backlog": "todo"]
        statusRaw = synonyms[statusRaw] ?? statusRaw
        guard let status = DeskStatus(rawValue: statusRaw) else {
            throw ToolFailureError(
                "Unknown status '\(statusRaw)'; use \(DeskStatus.allCases.map(\.rawValue).joined(separator: "/")) or 'waiting on <person>'.",
                    argumentPath: "$.status", effects: .none, code: "invalid_input")
        }
        let reasons = [input.blockedReason.trimmedNonEmpty, input.reason.trimmedNonEmpty, inlineReason, waitNote]
            .compactMap { $0 }.filter { !$0.isEmpty }
        guard Set(reasons).count <= 1 else {
            throw deskInvalid("reason", reason: """
                desk_set_status: conflicting blocked reasons; blocked_reason, reason, wait note, and status text 'blocked: reason' must agree. \
                Nothing was changed.
                """)
        }
        let blockedReason = reasons.first
        let inlineParty = inlineWaitingOn.map { OwnerAttentionPolicy.canonicalWaitingOn($0, dataRoot: dataRoot) }
        let explicitParty = input.waitingOn.trimmedNonEmpty.map { OwnerAttentionPolicy.canonicalWaitingOn($0, dataRoot: dataRoot) }
        if let inlineParty, let explicitParty, inlineParty != explicitParty {
            throw deskInvalid("waiting_on", reason: "desk_set_status: waiting_on must agree with the person named in status. Nothing was changed.")
        }
        let waitingOn = inlineParty ?? explicitParty
        // A blocked row must say what or whom it needs.
        if status == .blocked, blockedReason == nil, waitingOn == nil {
            throw deskInvalid("reason", reason: """
                desk_set_status: blocked needs a reason; send blocked_reason, reason, or status 'blocked: reason', and/or waiting_on. Nothing \
                was changed.
                """)
        }
        let progress = try input.progress.map { fields in
            guard let progress = DeskProgress(done: fields.done, total: fields.total, note: fields.note) else {
                throw deskInvalid("progress", reason: "desk_set_status: progress requires 0 <= done <= total and total > 0")
            }
            return progress
        }
        let assignee = input.assignee.trimmedNonEmpty
        let laneRaw = input.laneOf.trimmedNonEmpty
        let laneOf: String?
        if let laneRaw {
            laneOf = try resolveDeskLaneRef(laneRaw, in: state, updating: handle)
        } else {
            laneOf = nil
        }
        let store = deskStore()
        // Closing an item with open parts: say the one call that does it.
        if input.remainingWork != nil {
            guard !status.isTerminal, let remaining = input.remainingWork.trimmedNonEmpty else {
                throw deskInvalid("remaining_work", reason: "remaining_work must be nonblank and attached to a nonterminal status. Nothing was changed.")
            }
            guard let journal = invocation.deskContinuation else {
                throw deskInvalid("remaining_work", reason: "remaining_work requires an accepted turn and an exact reply route. Nothing was changed.")
            }
            try await journal.attach(handle: handle, remainingWork: remaining)
        }
        if status.isTerminal {
            let open = SwiftNativeDeskStore.descendants(of: handle, in: state).filter { !$0.status.isTerminal }
            if !open.isEmpty {
                let alias = state.items.first { $0.handle == handle }?.alias ?? handle
                let parts = open.prefix(6).map(\.alias).joined(separator: ", ") + (open.count > 6 ? ", …" : "")
                return .object([
                    "status": .string("refused"),
                    "reason": .string("""
                        \(alias) still has \(open.count) open part\(open.count == 1 ? "" : "s") (\(parts)). desk.close with handle \"\(alias)\", \
                        subtree true\(status == .canceled ? ", canceled true" : "") and a reason closes them and it in one call.
                        """),
                ])
            }
        }
        _ = try await store.setStatus(
            handle,
            status: status,
            blockedReason: blockedReason,
            waitingOn: waitingOn,
            progress: progress,
            assignee: assignee,
            laneOf: laneOf
        )
        if let waitNote { _ = try await store.appendNote(handle, text: waitNote) }
        return await deskConfirm(store, handle: handle, prefix: (inlineWaitingOn != nil ? waitingOn : nil).map { "waiting on " + $0 } ?? "status set")
    }

    func impl_desk_wait(invocation: ChatToolInvocation, input: DeskWaitArgs, state: DeskState) async throws -> JSONValue {
        let handle = try deskString(input.handle, "handle")
        let values = input.on.values
        let ids = values.compactMap(\.trimmedNonEmpty)
        let correction = """
            desk.wait takes on: owner (or the owner's exact name, User, or human) for an owner wait, a contact name like Claude Desktop, \
            what you are waiting for said in a sentence (descriptive only), an agent's peer: id or a conversation id (each a status only), \
            a Desk handle/number, an experience id (card, message, delivery or repair), or a list of those dependency ids. note is optional.
            """
        guard !ids.isEmpty, ids.count == values.count else { throw ToolFailureError(correction, argumentPath: "$.on", effects: .none, code: "invalid_input") }
        let store = deskStore()
        // An id an owner just handed out may still be on its way into the store.
        let experiences = ExperienceStore.at(dataRoot)
        await experiences.drained()
        var blockers: [String] = [], settled: [String] = []
        let note = input.note.trimmedNonEmpty
        for id in ids {
            if let item = try state.matching(id, field: "on").first { blockers.append(item.handle); continue }
            // A card answers to its bare id too (its experience is `interaction:<id>`), and an approval to the `approval:<id>` its Home row shows.
            var found = try await experiences.experience(id.hasPrefix("approval:") ? String(id.dropFirst("approval:".count)) : id)
            if found == nil { found = try await experiences.experience("interaction:" + id) }
            guard let experience = found else {
                // What she waits for said in words, a name or a sentence about what has to happen, is a wait and not an invented
                // dependency. One unbroken token that is not a plain name is identifier-shaped and still fails at the input boundary.
                let words = id.contains(where: \.isLetter) && !id.lowercased().hasPrefix("desk.")
                    && (id.contains(where: \.isWhitespace) || id.allSatisfy { $0.isLetter || "-'.".contains($0) })
                // A contact is named by the id agent.read hands out (peer:…) as well as by name.
                let contact = id.hasPrefix("peer:")
                    ? try AgentPeerStore(dataRoot: dataRoot).list().contains { "peer:" + $0.id == id } : false
                // A conversation the agent can reach is waited on like its person, through the same identity resolver as agent.read.
                let conversation = !words && !contact && ids.count == 1
                    ? try AgentConversationStore(dataRoot: dataRoot).containsConversation(id) : false
                if ids.count == 1, words || conversation || contact, case .string = input.on {
                    let statusInput = DeskSetStatusArgs(waiting: handle, on: id, note: note)
                    return try await impl_desk_set_status(invocation: invocation, input: statusInput, state: state)
                }
                throw ToolFailureError("Unknown condition \(id). " + correction, argumentPath: "$.on", effects: .none, code: "invalid_input")
            }
            if experience.isOpen { blockers.append("exp:" + experience.id) } else { settled.append(id) }
        }
        _ = try await store.setBlockedOn(handle, blockers: blockers, waiting: true, note: note)
        if blockers.isEmpty { return await deskConfirm(store, handle: handle, prefix: "already settled: nothing to wait for; go on now") }
        // A Desk item is named as she reads it (desk.N), never by its stored handle.
        let named = blockers.map { blocker in
            blocker.hasPrefix("exp:") ? String(blocker.dropFirst(4))
                : state.items.first { $0.handle == blocker }.map { "desk." + $0.alias } ?? blocker
        }
        return await deskConfirm(store, handle: handle, prefix: "waiting on " + named.joined(separator: ", ")
            + (settled.isEmpty ? "" : "; already settled: " + settled.joined(separator: ", ")))
    }

    // MARK: - desk_update_item

    func impl_desk_update_item(input: DeskUpdateItemArgs) async throws -> JSONValue {
        let handle = try deskString(input.handle, "handle")
        let title = nonblankDoorText(input.title)
        let summary = nonblankDoorText(input.summary)
        if title == nil && summary == nil {
            throw deskInvalid("title", reason: "desk_update_item: provide at least one of title/summary")
        }
        let store = deskStore()
        _ = try await store.updateTitle(handle, title: title, summary: summary)
        return await deskConfirm(store, handle: handle, prefix: "updated")
    }

    // MARK: - desk_note

    func impl_desk_note(input: DeskNoteArgs, byPerson: Bool) async throws -> JSONValue {
        let handle = try deskString(input.handle, "handle")
        let text = try deskString(input.text, "text").trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else {
            throw deskInvalid("text", reason: "desk_note: text is empty")
        }
        let store = deskStore()
        _ = try await store.appendNote(handle, text: text, author: byPerson ? "owner" : "agent")
        return await deskConfirm(store, handle: handle, prefix: "noted")
    }

    // MARK: - desk_add_ref

    func impl_desk_add_ref(input: DeskAddRefArgs) async throws -> JSONValue {
        let handle = try deskString(input.handle, "handle")
        let ref = try deskBuildRef(input)
        try deskRequireMadeThing(ref)
        let store = deskStore()
        _ = try await store.addRef(handle, ref: ref)
        return await deskConfirm(store, handle: handle, prefix: DeskPiece.makeRef(ref) == nil ? "ref added (\(ref.kind.token))" : "piece laid")
    }

    /// A url addressed `make:` lays a piece, so it names a Make ref that holds a version; any other url passes untouched.
    private func deskRequireMadeThing(_ ref: DeskRef) throws {
        guard case .url(let url, _) = ref.kind, url.lowercased().hasPrefix(DeskPiece.scheme) else { return }
        guard let made = DeskPiece.makeRef(address: url), MakeStudio.isRef(made) else {
            throw deskInvalid("url", reason: "desk_add_ref: a piece's url is make: and the Make ref of something I made, like make:3f2a1b9c "
                + "(make.read lists versions; page:make lists what I made). Nothing was laid.")
        }
        let meta: MakeStudio.Meta?
        do { meta = try MakeStudio(dataRoot: dataRoot).readMeta(made) } catch {
            throw ToolFailureError("desk_add_ref: Make could not read \(made): \(error.localizedDescription). Nothing was laid.",
                argumentPath: "$.url", effects: .none, code: "make_unreadable")
        }
        guard let meta, !meta.versions.isEmpty else {
            throw deskInvalid("url", reason: "desk_add_ref: nothing in Make is called \(made); page:make lists what I made. Nothing was laid.")
        }
    }

    // MARK: - desk_set_cadence

    func impl_desk_set_cadence(input: DeskSetCadenceArgs) async throws -> JSONValue {
        let handle = try deskString(input.handle, "handle")
        let modeRaw = try deskString(input.mode, "mode").trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard let mode = CadenceMode(rawValue: modeRaw) else {
            throw deskInvalid("mode",
                reason: "desk_set_cadence: unknown mode '\(modeRaw)' (expected one of \(CadenceMode.allCases.map(\.rawValue).joined(separator: "/")))"
            )
        }
        let cadence = Cadence(
            mode: mode,
            interval: nonblankDoorText(input.interval),
            staleAfter: nonblankDoorText(input.staleAfter),
            refreshSources: deskCSV(input.refreshSources)
        )
        let store = deskStore()
        _ = try await store.setCadence(handle, cadence: cadence)
        return await deskConfirm(store, handle: handle, prefix: "cadence \(mode.rawValue)")
    }

    // MARK: - desk_close

    static func validateDeskClose(_ input: [String: JSONValue]) throws {
        for key in input.keys.sorted() where !key.hasPrefix("__") {
            guard let field = DeskCloseArgs.doorFields.first(where: { $0.name == key }) else {
                throw ToolFailureError("desk.close takes no \(key). Nothing was closed.", argumentPath: "$.\(key)", effects: .none, code: "invalid_input")
            }
            let flag = field.schema.objectValue?["type"] == .string("boolean")
            switch input[key] {
            case .string? where !flag, .bool? where flag: break
            default:
                throw ToolFailureError("desk.close \(key) must be a \(flag ? "boolean" : "string"). Nothing was closed.",
                    argumentPath: "$.\(key)", effects: .none, code: "invalid_input")
            }
        }
    }

    func impl_desk_close(input: DeskCloseArgs) async throws -> JSONValue {
        let handle = try deskString(input.handle, "handle")
        let outcome = input.reason.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !outcome.isEmpty else {
            throw ToolFailureError("reason must not be empty.", argumentPath: "$.reason", effects: .none, code: "invalid_input")
        }
        let canceled = input.canceled ?? false
        let subtree = input.subtree ?? false
        let store = deskStore()
        let expectedUpdatedAt = nonblankDoorText(input.expectedUpdatedAt)?.trimmingCharacters(
            in: .whitespacesAndNewlines
        )
        let refusedChanged: JSONValue = .object([
            "status": .string("refused"),
            "reason": .string("desk_close: item changed or is no longer active; refresh the Desk before closing it"),
        ])
        // Close descendants deepest-first so no open child remains beneath the closed item.
        var closedAliases: [String] = []
        func subtreeResult(_ status: String, reason: String? = nil) -> JSONValue {
            var out: [String: JSONValue] = [
                "status": .string(status), "closed": .int(Int64(closedAliases.count)),
                "handles": .array(closedAliases.map { .string($0) }),
            ]
            if let reason { out["reason"] = .string(reason) }
            return .object(out)
        }
        if subtree {
            let state = try await store.liveState()
            let root = state.items.first { $0.handle == handle }
            if let expectedUpdatedAt, !expectedUpdatedAt.isEmpty, root?.updatedAt != expectedUpdatedAt {
                return refusedChanged
            }
            let descendants = SwiftNativeDeskStore.descendants(of: handle, in: state).reversed().filter { !$0.status.isTerminal }
            if let conflict = try await store.runHold([handle] + descendants.map(\.handle)) {
                return conflict.refusal("An item in \(handle)'s subtree")
            }
            for kid in descendants {
                do {
                    // A child keeps its own summary; only a bare one gets a pointer.
                    let own = kid.summary?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
                    _ = try await store.closeItem(kid.handle, outcomeSummary: own.isEmpty ? "closed with \(root?.alias ?? handle)" : own, canceled: canceled)
                    closedAliases.append(kid.alias)
                } catch let e as DeskError {
                    return subtreeResult("partial", reason: "\(kid.alias): \(e.errorDescription ?? "\(e)")")
                }
            }
            do {
                if let expectedUpdatedAt, !expectedUpdatedAt.isEmpty {
                    guard try await store.closeItemIfUnchanged(handle, expectedUpdatedAt: expectedUpdatedAt,
                        outcomeSummary: outcome, canceled: canceled) else {
                        return subtreeResult(closedAliases.isEmpty ? "refused" : "partial",
                            reason: "Root changed or is no longer active; closed children are retained. Refresh the Desk before closing the root.")
                    }
                } else {
                    _ = try await store.closeItem(handle, outcomeSummary: outcome, canceled: canceled)
                }
                closedAliases.insert(root?.alias ?? handle, at: 0)
            } catch let e as DeskError {
                return subtreeResult(closedAliases.isEmpty ? "refused" : "partial", reason: e.errorDescription ?? "\(e)")
            }
            return subtreeResult("ok")
        }
        if let expectedUpdatedAt, !expectedUpdatedAt.isEmpty {
            let closed = try await store.closeItemIfUnchanged(
                handle,
                expectedUpdatedAt: expectedUpdatedAt,
                outcomeSummary: outcome,
                canceled: canceled
            )
            guard closed else { return refusedChanged }
        } else {
            do {
                _ = try await store.closeItem(handle, outcomeSummary: outcome, canceled: canceled)
            } catch let DeskError.closeRefusedTerminal(_, status) {
                // Closing what is already closed asks for what already holds: nothing changes and the batch goes on.
                return .object([
                    "status": .string("ok"), "effects": .string("none"), "already": .string(status.rawValue),
                    "note": .string("\(handle) was already \(status.rawValue); its recorded outcome stands and nothing was changed. "
                        + "Reopen it first if that outcome is wrong."),
                ])
            } catch let e as DeskError {
                // Report attempts to close terminal items as Desk refusals, preserving their recorded outcomes.
                return .object([
                    "status": .string("refused"),
                    "reason": .string(e.errorDescription ?? "\(e)"),
                ])
            }
        }
        return await deskConfirm(store, handle: handle, prefix: canceled ? "canceled" : "closed")
    }

    // MARK: - desk_blocked_on

    /// desk_blocked_on — point an item at the ITEMS blocking it (never prose). `blocked_on` is a CSV of visible numbers or handles and REPLACES the whole
    /// set; an EMPTY string clears it.

    func impl_desk_blocked_on(input: DeskBlockedOnArgs, state: DeskState) async throws -> JSONValue {
        let handle = try deskString(input.handle, "handle")
        let refs = deskCSV(input.blockedOn)
        let blockers = try refs.map { try resolveDeskRef($0, in: state, field: "blocked_on") }
        let store = deskStore()
        do {
            _ = try await store.setBlockedOn(handle, blockers: blockers)
        } catch let e as DeskError {
            return .object([
                "status": .string("refused"),
                "reason": .string(e.errorDescription ?? "\(e)"),
            ])
        }
        let aliases = blockers.map { h in state.items.first { $0.handle == h }?.alias ?? h }
        let prefix = blockers.isEmpty
            ? "blockers cleared"
            : "blocked-on \(aliases.joined(separator: ","))"
        return await deskConfirm(store, handle: handle, prefix: prefix)
    }

    // MARK: - desk_defer

    func impl_desk_defer(input: DeskDeferArgs) async throws -> JSONValue {
        let handle = try deskString(input.handle, "handle")
        let raw = input.until.trimmedNonEmpty
        let until: String? = (raw?.isEmpty == false) ? raw : nil
        if let until, !DeskClock.isParseableDate(until) {
            throw deskInvalid("until", reason: "until must be yyyy-MM-dd or an ISO timestamp.")
        }
        let store = deskStore()
        let prefix: String
        do {
            prefix = try await SwiftNativePersistenceCore.withFileLock(store.opsPath) {
                let when = until.map { "at \($0)" }
                if let until, let when,
                   let entry = try await MyQueue.entry(handle, store: store), entry.item.project == MyQueue.project, entry.step.action == nil,
                   case .at? = MyQueue.when(entry), case .at? = MyQueue.When(when) {
                    var step = entry.step
                    step.when = when
                    let updated = try await MyQueue.update(entry, step: step, store: store)
                    if updated.item.deferUntil != nil { _ = try await store.setDeferUntil(handle, until: nil) }
                    return "moved to \(until)"
                }
                _ = try await store.setDeferUntil(handle, until: until)
                return until.map { "deferred until \($0)" } ?? "defer cleared"
            }
        } catch let error where error is DeskError || error is MyQueue.Superseded {
            return .object([
                "status": .string("refused"),
                "reason": .string(error.localizedDescription),
            ])
        }
        return await deskConfirm(store, handle: handle, prefix: prefix)
    }

    // MARK: - desk_archive

    func impl_desk_archive(input: DeskArchiveArgs) async throws -> JSONValue {
        let handle = try deskString(input.handle, "handle")
        let store = deskStore()
        let rec = try await store.archiveItem(handle)
        return .object([
            "status": .string("ok"),
            "handle": .string(handle),
            "confirmation": .string("archived \(rec.project) · \(rec.title) (\(rec.finalStatus.rawValue))"),
        ])
    }

    // MARK: - Helpers

    /// An item filed with no kind takes the kind the Desk files a person's task as; a kind that is given must be one of the Desk's.
    private func deskKind(_ text: String?, _ key: String) throws -> DeskKind {
        guard let text else { return DeskItem.tasksKind }
        let raw = text.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard let kind = DeskKind(rawValue: raw) else {
            throw deskInvalid(key,
                reason: "desk_add_item: unknown kind '\(raw)' (expected one of \(DeskKind.allCases.map(\.rawValue).joined(separator: "/")))"
            )
        }
        return kind
    }

    /// Author one current stored reference from the selected tool shape. Transport arguments never enter its persisted tagged union.
    private func deskBuildRef(_ input: DeskAddRefArgs) throws -> DeskRef {
        let refKind = try deskString(input.refKind, "ref_kind").trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        var fields: [String: JSONValue] = [
            "kind": .string(refKind), "refId": .string(DeskClock.newRefId()),
        ]
        func string(_ value: String?, _ key: String, stored: String? = nil, required: Bool = false) throws {
            if required { fields[stored ?? key] = .string(try deskString(value, key)) }
            else { fields[stored ?? key] = nonblankDoorText(value).map(JSONValue.string) }
        }
        func integer(_ value: Int?, _ key: String, required: Bool = false) throws {
            if required, value == nil { throw deskInvalid(key, reason: "desk_add_ref: \(key) is required") }
            fields[key] = value.map { .int(Int64($0)) }
        }
        switch refKind {
        case "file":
            try string(input.path, "path", required: true)
            try integer(input.line, "line")
            try string(input.label, "label")
        case "commit":
            try string(input.sha, "sha", required: true)
            try string(input.repo, "repo")
            try string(input.label, "label")
            try string(input.status, "status")
        case "gh_issue", "gh_pr":
            try string(input.repo, "repo", required: true)
            try integer(input.number, "number", required: true)
            try string(input.title, "title")
            try string(input.status, "status")
            if refKind == "gh_pr" { try string(input.checks, "checks") }
        case "url":
            try string(input.url, "url", required: true)
            try string(input.title, "title")
        case "agent":
            try string(input.name, "name", required: true)
            try string(input.handoffID, "handoff_id", stored: "handoffId")
            try string(input.sessionID, "session_id", stored: "sessionId")
        case "approval":
            try string(input.id, "id", required: true)
            try string(input.status, "status")
        case "trace":
            try string(input.id, "id", required: true)
            try string(input.traceKind, "trace_kind", stored: "traceKind")
        case "note":
            try string(input.text, "text", required: true)
        default:
            throw deskInvalid("ref_kind",
                reason: "desk_add_ref: unknown ref_kind '\(refKind)' (expected file|commit|gh_issue|gh_pr|url|agent|approval|trace|note)")
        }
        guard let ref = DeskRef.fromJSON(.object(fields)) else {
            throw deskInvalid("ref_kind", reason: "desk_add_ref: ref_kind '\(refKind)' has missing or malformed required fields")
        }
        return ref
    }

}
