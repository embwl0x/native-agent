import NativeAgentShared
import Foundation
import NativeAgentCore
import PersistenceCore
import Desk
import AgentConversations
import AgentWorkspace
import Experiences
import Studio
import ToolExecution
// Blueprint: | `SwiftToolDispatcher+DeskTools.swift` | `SwiftToolDispatcher`; raw mutation admission; checked waits and close |

// Desk actions use this dispatcher’s data root and the single event-sourced personal store. DeskOp has no actor field; mutations use ledger_write authority.

extension SwiftToolDispatcher {
    /// A clear must be stated, and its raw type must survive protocol admission. Called before normalization and again at the mutation owner.
    static func validateDeskMutationArguments(_ tool: String, input: [String: JSONValue]) throws {
        let key: String
        switch tool {
        case "desk_blocked_on": key = "blocked_on"
        case "desk_defer": key = "until"
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

    func deskString(_ input: [String: JSONValue], _ key: String) throws -> String {
        guard case .string(let value)? = input[key], !value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw deskInvalid(key, reason: "\(key) must be a nonempty string.")
        }
        return value
    }

    /// An item filed with no project goes where its caller says the app files its own (`absent`). A project that is given must name one.
    func deskProject(_ input: [String: JSONValue], absent: String) throws -> String {
        guard let given = input["project"], given != .null else { return absent }
        guard case .string(let value) = given, !value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
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
            return ChatToolOutcome.failure(error: ToolFailureError(
                "\(prefix) committed for \(handle), but its current Desk state could not be read: \(error.localizedDescription)",
                effects: .occurred, owner: "Desk", code: "desk_confirmation_unavailable",
                instruction: "Repair the reported Desk read failure, then read this handle before repeating the mutation."), tool: "desk")
        }
        let item = state.items.first { $0.handle == handle }
        let label: String
        if let item {
            // A person wait reads as the wait; otherwise the state in the words the Desk shows (an unstarted item is queued).
            let state = item.statusDescription.hasPrefix("waiting on ") ? item.statusDescription : item.spokenStatus
            // A prefix that is the state itself (a wait) is not said a second time.
            label = "\(item.alias) \(item.kind.rawValue) " + (state == prefix ? "" : "(\(state)) ") + item.displayTitle(peerName: deskPeerName())
        } else {
            label = handle
        }
        return .object([
            "status": .string("ok"),
            "handle": .string(handle),
            "confirmation": .string("\(prefix): \(label)"),
        ])
    }

    func deskCSV(_ input: [String: JSONValue], _ key: String) -> [String] {
        guard let raw = optionalString(input, key) else { return [] }
        return raw.split(separator: ",")
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
    }

    /// Missing progress preserves it; malformed values fail before any Desk op is appended.
    private func deskProgress(_ input: [String: JSONValue]) throws -> DeskProgress? {
        guard let raw = input["progress"], raw != .null else { return nil }
        guard case .object(let object) = raw,
              case .int(let doneRaw)? = object["done"],
              case .int(let totalRaw)? = object["total"],
              doneRaw >= Int64(Int.min), doneRaw <= Int64(Int.max),
              totalRaw >= Int64(Int.min), totalRaw <= Int64(Int.max) else {
            throw deskInvalid("progress",
                reason: "desk_set_status: progress requires integer done and total fields"
            )
        }
        let note: String?
        switch object["note"] {
        case nil: note = nil
        case .some(.string(let value)): note = value
        default:
            throw deskInvalid("progress.note", reason: "desk_set_status: progress.note must be a string")
        }
        guard let progress = DeskProgress(done: Int(doneRaw), total: Int(totalRaw), note: note) else {
            throw deskInvalid("progress",
                reason: "desk_set_status: progress requires 0 <= done <= total and total > 0"
            )
        }
        return progress
    }

    /// Blank or omitted metadata preserves its prior value; only nonblank strings update it.
    private func deskMetadataString(_ input: [String: JSONValue], _ key: String) throws -> String? {
        guard let raw = input[key], raw != .null else { return nil }
        guard case .string(let value) = raw else {
            throw ToolFailureError("\(key) must be a string.", argumentPath: "$.\(key)", effects: .none, code: "invalid_input")
        }
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
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
        guard let laneParent = state.items.first(where: {
            $0.handle == reference || $0.alias == reference
        }) else {
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

    func impl_desk_add_item(input: [String: JSONValue]) async throws -> JSONValue {
        let kind = try deskKind(input, "kind")
        let title = try deskString(input, "title").trimmingCharacters(in: .whitespacesAndNewlines)
        let parentRaw = optionalString(input, "parent")?.trimmingCharacters(in: .whitespacesAndNewlines)
        let summary = optionalString(input, "summary")?.trimmingCharacters(in: .whitespacesAndNewlines)
        let assignee = optionalString(input, "assignee")?.trimmingCharacters(in: .whitespacesAndNewlines)
        let laneRaw = optionalString(input, "lane_of")?.trimmingCharacters(in: .whitespacesAndNewlines)
        let until = optionalString(input, "until")?.trimmingCharacters(in: .whitespacesAndNewlines)
        let deferred = optionalString(input, "defer")?.trimmingCharacters(in: .whitespacesAndNewlines)
        if let until, let deferred, until != deferred {
            throw deskInvalid("until", reason: "desk_add_item: until and defer must agree")
        }
        let park = until ?? deferred
        if let park, !park.isEmpty, !DeskClock.isParseableDate(park) {
            throw deskInvalid("until", reason: "desk_add_item: until must be yyyy-MM-dd or an ISO timestamp; nothing was added")
        }
        // Persist stable parent handles rather than display numbers.
        let state = try await deskStore().liveState()
        let parent: String? = (parentRaw?.isEmpty == false) ? try resolveDeskRef(parentRaw!, in: state, field: "parent") : nil
        let laneOf: String? = (laneRaw?.isEmpty == false) ? try resolveDeskLaneRef(laneRaw!, in: state) : nil
        // A part filed with no project goes under its parent's, as a breakdown's parts do; with no parent, where the Desk files a person's task.
        let project = try deskProject(input, absent: parent.flatMap { handle in state.items.first { $0.handle == handle } }?.project
            ?? DeskItem.tasksProject)

        let allowDuplicate: Bool
        switch input["allow_duplicate"] {
        case .some(.bool(let value)): allowDuplicate = value
        default: allowDuplicate = false
        }
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
        if let park, !park.isEmpty { _ = try await store.setDeferUntil(item.handle, until: park) }
        return .object([
            "status": .string("ok"),
            "disposition": .string(result.reusedEquivalent ? "existing" : "created"),
            "created": .bool(!result.reusedEquivalent),
            "handle": .string(item.handle),
            "alias": .string(item.alias),
            "defer_until": (park?.isEmpty == false ? park : item.deferUntil).map(JSONValue.string) ?? .null,
            "next_call": .object(["tool": .string("app"), "input": .object([
                "action": .string("desk.read"), "args": .object(["handle": .string(item.handle)])])]),
            "confirmation": .string(result.reusedEquivalent
                ? "reused existing \(item.alias) \(item.kind.rawValue) \(item.project) · \(item.title)"
                : "created \(item.alias) \(item.kind.rawValue) \(item.project) · \(item.title)"),
        ])
    }

    // MARK: - desk_open_pursuit

    /// The sole chat path to an origin=agent pursuit; the store gates dossier sources and caps. Store refusals return their reason with status "refused".
    func impl_desk_open_pursuit(input: [String: JSONValue]) async throws -> JSONValue {
        let project = try deskProject(input, absent: DeskItem.workshopProject)
        let title = try deskString(input, "title").trimmingCharacters(in: .whitespacesAndNewlines)
        // The store owns refusal of empty pursuit fields.
        let why = (optionalString(input, "why") ?? "")
        let doneLooksLike = (optionalString(input, "done_looks_like") ?? "")
        let abandonCondition = (optionalString(input, "abandon_condition") ?? "")
        let privateName = optionalString(input, "private_name")
        let dossier = try deskParseDossier(input)
        func bound(_ key: String, defaultValue value: Int) throws -> Int {
            guard let raw = input[key] else { return value }
            guard case .int(let number) = raw, let checked = Int(exactly: number) else {
                throw deskInvalid(key, reason: "\(key) must be an integer. Nothing was opened.")
            }
            return checked
        }
        let pursuit = Pursuit(
            why: why,
            evidence: dossier,
            doneLooksLike: doneLooksLike,
            maxSessions: try bound("max_sessions", defaultValue: Pursuit.defaultMaxSessions),
            maxDays: try bound("max_days", defaultValue: Pursuit.defaultMaxDays),
            abandonCondition: abandonCondition,
            privateName: (privateName?.isEmpty == false) ? privateName : nil
        )
        let summary = optionalString(input, "summary")
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

    /// Every supplied citation must decode; the store owns the source-mix gate.
    private func deskParseDossier(_ input: [String: JSONValue]) throws -> PromotionDossier {
        guard let evidence = input["evidence"],
              let dossier = PromotionDossier.fromJSON(.object(["citations": evidence])) else {
            throw deskInvalid("evidence", reason: "evidence must be an array of complete current citation records. Nothing was opened.")
        }
        return dossier
    }

    // MARK: - desk_work_log

    /// Append a pursuit receipt or ordinary item note.
    func impl_desk_work_log(input: [String: JSONValue]) async throws -> JSONValue {
        let handle = try deskString(input, "handle")
        let receipt = try deskString(input, "receipt").trimmingCharacters(in: .whitespacesAndNewlines)
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

    func impl_desk_set_status(invocation: ChatToolInvocation, input: [String: JSONValue], state: DeskState) async throws -> JSONValue {
        if input["wait"] == .bool(true) { return try await impl_desk_wait(invocation: invocation, input: input, state: state) }
        let handle = try deskString(input, "handle")
        let statusText = try deskString(input, "status").trimmingCharacters(in: .whitespacesAndNewlines)
        var statusRaw = statusText.lowercased()
        let inlineWaitingOn: String?
        let waitNote: String?
        // A person wait is a status write, including every supplied update.
        if statusRaw.hasPrefix("waiting on ") {
            inlineWaitingOn = String(statusText.dropFirst("waiting on ".count)).trimmingCharacters(in: .whitespacesAndNewlines)
            waitNote = try deskMetadataString(input, "note") ?? deskMetadataString(input, "reason")
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
        let reasons = try [deskMetadataString(input, "blocked_reason"), deskMetadataString(input, "reason"), inlineReason, waitNote]
            .compactMap { $0 }.filter { !$0.isEmpty }
        guard Set(reasons).count <= 1 else {
            throw deskInvalid("reason", reason: """
                desk_set_status: conflicting blocked reasons; blocked_reason, reason, wait note, and status text 'blocked: reason' must agree. \
                Nothing was changed.
                """)
        }
        let blockedReason = reasons.first
        let explicitWaitingOn = try deskMetadataString(input, "waiting_on")
        if let inlineWaitingOn, let explicitWaitingOn, inlineWaitingOn != explicitWaitingOn {
            throw deskInvalid("waiting_on", reason: "desk_set_status: waiting_on must agree with the person named in status. Nothing was changed.")
        }
        let waitingOn = inlineWaitingOn ?? explicitWaitingOn
        // A blocked row must say what or whom it needs.
        if status == .blocked, blockedReason == nil, waitingOn == nil {
            throw deskInvalid("reason", reason: """
                desk_set_status: blocked needs a reason; send blocked_reason, reason, or status 'blocked: reason', and/or waiting_on. Nothing \
                was changed.
                """)
        }
        let progress = try deskProgress(input)
        let assignee = try deskMetadataString(input, "assignee")
        let laneRaw = try deskMetadataString(input, "lane_of")
        let laneOf: String?
        if let laneRaw {
            laneOf = try resolveDeskLaneRef(laneRaw, in: state, updating: handle)
        } else {
            laneOf = nil
        }
        let store = deskStore()
        // Closing an item with open parts: say the one call that does it.
        if let raw = input["remaining_work"], raw != .null {
            guard !status.isTerminal, let remaining = try deskMetadataString(input, "remaining_work") else {
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
        return await deskConfirm(store, handle: handle, prefix: inlineWaitingOn.map { "waiting on " + $0 } ?? "status set")
    }

    func impl_desk_wait(invocation: ChatToolInvocation, input: [String: JSONValue], state: DeskState) async throws -> JSONValue {
        let handle = try deskString(input, "handle")
        let values: [JSONValue]
        if case .array(let list)? = input["on"] { values = list }
        else { values = input["on"].map { [$0] } ?? [] }
        let ids = values.compactMap { value -> String? in
            guard case .string(let id) = value, !id.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return nil }
            return id.trimmingCharacters(in: .whitespacesAndNewlines)
        }
        let correction = """
            desk.wait takes on: a person's or agent's name (for example User, owner or Claude Desktop), what you are waiting for said in a \
            sentence, an agent's peer: id or a conversation id (each a status only), a Desk handle/number, an experience id (card, message, \
            delivery or repair), or a list of those dependency ids. note is optional.
            """
        guard !ids.isEmpty, ids.count == values.count else { throw ToolFailureError(correction, argumentPath: "$.on", effects: .none, code: "invalid_input") }
        let store = deskStore()
        // An id an owner just handed out may still be on its way into the store.
        let experiences = ExperienceStore.at(dataRoot)
        await experiences.drained()
        var blockers: [String] = [], settled: [String] = []
        let note = try deskMetadataString(input, "note")
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
                if ids.count == 1, words || conversation || contact, case .string? = input["on"] {
                    var statusInput = input
                    statusInput.removeValue(forKey: "wait")
                    statusInput["handle"] = .string(handle)
                    statusInput["status"] = .string("waiting on " + id)
                    if let note { statusInput["note"] = .string(note) }
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

    func impl_desk_update_item(input: [String: JSONValue]) async throws -> JSONValue {
        let handle = try deskString(input, "handle")
        let title = optionalString(input, "title")
        let summary = optionalString(input, "summary")
        if title == nil && summary == nil {
            throw deskInvalid("title", reason: "desk_update_item: provide at least one of title/summary")
        }
        let store = deskStore()
        _ = try await store.updateTitle(handle, title: title, summary: summary)
        return await deskConfirm(store, handle: handle, prefix: "updated")
    }

    // MARK: - desk_note

    func impl_desk_note(input: [String: JSONValue]) async throws -> JSONValue {
        let handle = try deskString(input, "handle")
        let text = try deskString(input, "text").trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else {
            throw deskInvalid("text", reason: "desk_note: text is empty")
        }
        let store = deskStore()
        _ = try await store.appendNote(handle, text: text, author: "agent")
        return await deskConfirm(store, handle: handle, prefix: "noted")
    }

    // MARK: - desk_add_ref

    func impl_desk_add_ref(input: [String: JSONValue]) async throws -> JSONValue {
        let handle = try deskString(input, "handle")
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

    func impl_desk_set_cadence(input: [String: JSONValue]) async throws -> JSONValue {
        let handle = try deskString(input, "handle")
        let modeRaw = try deskString(input, "mode").trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard let mode = CadenceMode(rawValue: modeRaw) else {
            throw deskInvalid("mode",
                reason: "desk_set_cadence: unknown mode '\(modeRaw)' (expected one of \(CadenceMode.allCases.map(\.rawValue).joined(separator: "/")))"
            )
        }
        let cadence = Cadence(
            mode: mode,
            interval: optionalString(input, "interval"),
            staleAfter: optionalString(input, "stale_after"),
            refreshSources: deskCSV(input, "refresh_sources")
        )
        let store = deskStore()
        _ = try await store.setCadence(handle, cadence: cadence)
        return await deskConfirm(store, handle: handle, prefix: "cadence \(mode.rawValue)")
    }

    // MARK: - desk_close

    static func validateDeskClose(_ input: [String: JSONValue]) throws {
        let fields = ["handle", "reason", "canceled", "subtree", "expected_updated_at"]
        for key in input.keys.sorted() where !key.hasPrefix("__") {
            guard fields.contains(key) else {
                throw ToolFailureError("desk.close takes no \(key). Nothing was closed.", argumentPath: "$.\(key)", effects: .none, code: "invalid_input")
            }
            let flag = ["canceled", "subtree"].contains(key)
            switch input[key] {
            case .string? where !flag, .bool? where flag: break
            default:
                throw ToolFailureError("desk.close \(key) must be a \(flag ? "boolean" : "string"). Nothing was closed.",
                    argumentPath: "$.\(key)", effects: .none, code: "invalid_input")
            }
        }
    }

    func impl_desk_close(input: [String: JSONValue]) async throws -> JSONValue {
        try Self.validateDeskClose(input)
        let handle = try deskString(input, "handle")
        guard case .string(let rawReason)? = input["reason"] else {
            throw ToolFailureError("reason is required.", argumentPath: "$.reason", effects: .none, code: "invalid_input")
        }
        let outcome = rawReason.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !outcome.isEmpty else {
            throw ToolFailureError("reason must not be empty.", argumentPath: "$.reason", effects: .none, code: "invalid_input")
        }
        let canceled = input["canceled"] == .bool(true)
        let subtree = input["subtree"] == .bool(true)
        let store = deskStore()
        let expectedUpdatedAt = optionalString(input, "expected_updated_at")?.trimmingCharacters(
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

    func impl_desk_blocked_on(input: [String: JSONValue], state: DeskState) async throws -> JSONValue {
        try Self.validateDeskMutationArguments("desk_blocked_on", input: input)
        let handle = try deskString(input, "handle")
        let refs = deskCSV(input, "blocked_on")
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

    /// An empty until clears the defer; deferred items are neither next-up nor stale.
    func impl_desk_defer(input: [String: JSONValue]) async throws -> JSONValue {
        try Self.validateDeskMutationArguments("desk_defer", input: input)
        let handle = try deskString(input, "handle")
        let raw = optionalString(input, "until")?.trimmingCharacters(in: .whitespacesAndNewlines)
        let until: String? = (raw?.isEmpty == false) ? raw : nil
        if let until, !DeskClock.isParseableDate(until) {
            throw deskInvalid("until", reason: "until must be yyyy-MM-dd or an ISO timestamp.")
        }
        let store = deskStore()
        do {
            _ = try await store.setDeferUntil(handle, until: until)
        } catch let e as DeskError {
            return .object([
                "status": .string("refused"),
                "reason": .string(e.errorDescription ?? "\(e)"),
            ])
        }
        return await deskConfirm(
            store, handle: handle,
            prefix: until.map { "deferred until \($0)" } ?? "defer cleared"
        )
    }

    // MARK: - desk_archive

    func impl_desk_archive(input: [String: JSONValue]) async throws -> JSONValue {
        let handle = try deskString(input, "handle")
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
    private func deskKind(_ input: [String: JSONValue], _ key: String) throws -> DeskKind {
        guard let given = input[key], given != .null else { return DeskItem.tasksKind }
        guard case .string(let text) = given else {
            throw deskInvalid(key, reason: "\(key) must be a string; leave it out for \(DeskItem.tasksKind.rawValue).")
        }
        let raw = text.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard let kind = DeskKind(rawValue: raw) else {
            throw deskInvalid(key,
                reason: "desk_add_item: unknown kind '\(raw)' (expected one of \(DeskKind.allCases.map(\.rawValue).joined(separator: "/")))"
            )
        }
        return kind
    }

    /// Author one current stored reference from the selected tool shape. Transport arguments never enter its persisted tagged union.
    private func deskBuildRef(_ input: [String: JSONValue]) throws -> DeskRef {
        let refKind = try deskString(input, "ref_kind").trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        var fields: [String: JSONValue] = [
            "kind": .string(refKind), "refId": .string(DeskClock.newRefId()),
        ]
        func string(_ tool: String, stored: String? = nil, required: Bool = false) throws {
            if required {
                fields[stored ?? tool] = .string(try deskString(input, tool))
                return
            }
            guard let raw = input[tool] else { return }
            guard case .string(let value) = raw else {
                throw deskInvalid(tool, reason: "desk_add_ref: \(tool) must be a string")
            }
            if !value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                fields[stored ?? tool] = .string(value)
            }
        }
        func integer(_ key: String, required: Bool = false) throws {
            guard let raw = input[key] else {
                if required { throw deskInvalid(key, reason: "desk_add_ref: \(key) is required") }
                return
            }
            guard case .int(let value) = raw, Int(exactly: value) != nil else {
                throw deskInvalid(key, reason: "desk_add_ref: \(key) must be an integer")
            }
            fields[key] = .int(value)
        }
        switch refKind {
        case "file":
            try string("path", required: true)
            try integer("line")
            try string("label")
        case "commit":
            try string("sha", required: true)
            try string("repo")
            try string("label")
            try string("status")
        case "gh_issue", "gh_pr":
            try string("repo", required: true)
            try integer("number", required: true)
            try string("title")
            try string("status")
            if refKind == "gh_pr" { try string("checks") }
        case "url":
            try string("url", required: true)
            try string("title")
        case "agent":
            try string("name", required: true)
            try string("handoff_id", stored: "handoffId")
            try string("session_id", stored: "sessionId")
        case "approval":
            try string("id", required: true)
            try string("status")
        case "trace":
            try string("id", required: true)
            try string("trace_kind", stored: "traceKind")
        case "note":
            try string("text", required: true)
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
