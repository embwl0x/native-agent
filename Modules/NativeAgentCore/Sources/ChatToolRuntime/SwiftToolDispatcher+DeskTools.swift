import NativeAgentShared
import Foundation
import NativeAgentCore
import PersistenceCore
import Desk
import Experiences
import ToolExecution
// Blueprint: | `SwiftToolDispatcher+DeskTools.swift` | `SwiftToolDispatcher`: ordinary Desk mutations, shared store and handle/argument methods; person waits use existing status fields, dependency waits retain their conditions, and close resolves holds once while retaining closed children on conflict |

// Desk actions use this dispatcher’s data root and the single event-sourced personal store.
// DeskOp has no actor field; mutations use ledger_write authority.

extension SwiftToolDispatcher {
    func deskInvalid(_ field: String, reason: String) -> ToolFailureError {
        ToolFailureError(reason, argumentPath: "$." + field, effects: .none, code: "invalid_input")
    }

    func deskString(_ input: [String: JSONValue], _ key: String) throws -> String {
        guard case .string(let value)? = input[key], !value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw deskInvalid(key, reason: "\(key) must be a nonempty string.")
        }
        return value
    }

    func deskStore() -> SwiftNativeDeskStore {
        SwiftNativeDeskStore(dataRoot: dataRoot)
    }

    /// A mutation's fresh snapshot supplies its confirmation, or its bare handle if archived.
    func deskConfirm(_ state: DeskState?, handle: String, prefix: String) -> JSONValue {
        let item = state?.items.first { $0.handle == handle }
        let label: String
        if let item {
            label = "\(item.alias) \(item.kind.rawValue) (status: \(item.statusDescription)) \(item.title)"
        } else {
            label = handle
        }
        return .object([
            "status": .string("ok"),
            "handle": .string(handle),
            "confirmation": .string("\(prefix): \(label)"),
        ])
    }

    /// CSV → trimmed, non-empty string list (for refresh_sources / notify-on).
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

    /// Working an item holds it for this conversation.
    static let deskItemTools: Set<String> = [
        "desk_set_status", "desk_wait", "desk_update_item", "desk_note", "desk_add_ref", "desk_set_cadence", "desk_set_notify",
        "desk_close", "desk_archive", "desk_blocked_on", "desk_defer", "desk_work_log",
    ]

    /// Takes the resolved item for this conversation, or names its current holder.
    func deskHeld(_ handle: String, session: String) async throws -> JSONValue? {
        guard let by = try await deskStore().hold(handle, session: session) else { return nil }
        return .object([
            "status": .string("refused"), "reason": .string("held_by"), "held_by": .string(by), "effects": .string("none"),
            "detail": .string("\(handle) is held by \(by), which is working it; nothing changed. "
                + "Leave it to that one, or pick it up there."),
        ])
    }

    /// Resolve the mutation's target against its operation snapshot.
    func resolveDeskHandle(_ input: [String: JSONValue], in state: DeskState) throws -> String {
        guard case .string(let raw)? = input["handle"] ?? input["id"] else {
            throw ToolFailureError("Supply the item's handle from desk.read.", argumentPath: "$.handle", effects: .none, code: "invalid_input")
        }
        return try resolveDeskRef(raw, in: state)
    }

    /// `desk.4`, `#4` and `4 Title` copied from a board row all address item 4.
    static func deskAlias(_ raw: String) -> String {
        var r = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        if r.lowercased().hasPrefix("desk.") { r = String(r.dropFirst(5)) }
        if r.hasPrefix("#") { r = String(r.dropFirst()) }
        if let first = r.split(separator: " ").first, first.count < r.count,
           first.allSatisfy({ $0.isNumber || $0 == "." }) { r = String(first) }
        return r
    }

    /// Map a handle-or-alias string to a CURRENT stable handle, or throw.
    package static func deskMatches(_ raw: String, in state: DeskState, field: String = "handle") throws -> [DeskItem] {
        let reference = deskAlias(raw)
        let exact = state.items.filter { $0.alias == reference || $0.handle == reference }
        let matches = exact.isEmpty ? state.items.filter {
            $0.title.caseInsensitiveCompare(raw.trimmingCharacters(in: .whitespacesAndNewlines)) == .orderedSame
        } : exact
        guard matches.count <= 1 else {
            throw ToolFailureError("Several items share that title; use query in desk.read to find their handles.", argumentPath: "$." + field, effects: .none, code: "invalid_input")
        }
        return matches
    }

    func resolveDeskRef(_ raw: String, in state: DeskState, field: String = "handle") throws -> String {
        let r = Self.deskAlias(raw)
        guard !r.isEmpty else {
            throw deskInvalid(field, reason: "\(field) must not be empty.")
        }
        let matches = try Self.deskMatches(raw, in: state, field: field)
        if matches.count == 1 { return matches[0].handle }
        throw deskInvalid(field, reason: "No live item has handle '\(r)'; desk.read lists the current handles.")
    }

    /// Display-only `laneOf` requires a live reference at the tool boundary.
    private func resolveDeskLaneRef(_ raw: String, in state: DeskState, updating handle: String? = nil) throws -> String {
        let reference = Self.deskAlias(raw)
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

    /// desk_add_item — create a Desk item. Returns the new stable handle + alias.
    func impl_desk_add_item(input: [String: JSONValue]) async throws -> JSONValue {
        let kind = try deskRequireKind(input, "kind")
        let project = try deskString(input, "project").trimmingCharacters(in: .whitespacesAndNewlines)
        let title = try deskString(input, "title").trimmingCharacters(in: .whitespacesAndNewlines)
        guard !project.isEmpty, !title.isEmpty else {
            throw deskInvalid("title", reason: "desk_add_item: project and title must be non-empty")
        }
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
        // Resolve visible parent numbers to their stable handles.
        let state = try await deskStore().liveState()
        let parent: String? = (parentRaw?.isEmpty == false) ? try resolveDeskRef(parentRaw!, in: state, field: "parent") : nil
        let laneOf: String? = (laneRaw?.isEmpty == false) ? try resolveDeskLaneRef(laneRaw!, in: state) : nil

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

    /// The sole chat path to an origin=agent pursuit; the store gates dossier sources and caps.
    /// Store refusals return their reason with status "refused".
    func impl_desk_open_pursuit(input: [String: JSONValue]) async throws -> JSONValue {
        let project = try deskString(input, "project").trimmingCharacters(in: .whitespacesAndNewlines)
        let title = try deskString(input, "title").trimmingCharacters(in: .whitespacesAndNewlines)
        guard !project.isEmpty, !title.isEmpty else {
            throw deskInvalid("title", reason: "desk_open_pursuit: project and title must be non-empty")
        }
        // The store owns refusal of empty pursuit fields.
        let why = (optionalString(input, "why") ?? "")
        let doneLooksLike = (optionalString(input, "done_looks_like") ?? "")
        let abandonCondition = (optionalString(input, "abandon_condition") ?? "")
        let privateName = optionalString(input, "private_name")
        let dossier = deskParseDossier(input)
        let pursuit = Pursuit(
            why: why,
            evidence: dossier,
            doneLooksLike: doneLooksLike,
            maxSessions: Self.jsonInt(input["max_sessions"]) ?? Pursuit.defaultMaxSessions,
            maxDays: Self.jsonInt(input["max_days"]) ?? Pursuit.defaultMaxDays,
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

    /// Drop malformed citations; the store refuses any resulting under-cited pursuit.
    private func deskParseDossier(_ input: [String: JSONValue]) -> PromotionDossier {
        guard case .array(let arr)? = input["evidence"] else { return PromotionDossier(citations: []) }
        return PromotionDossier(citations: arr.compactMap { DossierSource.fromJSON($0) })
    }

    // MARK: - desk_work_log

    /// Append a pursuit receipt or ordinary item note; reserved work completes through Workshop settlement.
    func impl_desk_work_log(input: [String: JSONValue]) async throws -> JSONValue {
        let handle = try deskString(input, "handle")
        let receipt = try deskString(input, "receipt").trimmingCharacters(in: .whitespacesAndNewlines)
        guard !receipt.isEmpty else {
            throw deskInvalid("receipt", reason: "desk_work_log: receipt is empty")
        }
        let store = deskStore()
        do {
            _ = try await store.appendWorkReceipt(handle, receipt: receipt)
            return deskConfirm(try? await store.liveState(), handle: handle, prefix: "work logged")
        } catch DeskError.notAPursuit {
            return try await impl_desk_note(input: ["handle": .string(handle), "text": .string(receipt)])
        } catch let e as DeskError {
            return .object([
                "status": .string("refused"),
                "reason": .string(e.errorDescription ?? "\(e)"),
            ])
        }
    }

    // MARK: - desk_set_status

    func impl_desk_set_status(input: [String: JSONValue], state: DeskState) async throws -> JSONValue {
        if input["wait"] == .bool(true) { return try await impl_desk_wait(input: input, state: state) }
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
        // The words people use for the same states.
        let synonyms = ["cancelled": "canceled", "cancel": "canceled", "dropped": "canceled", "complete": "done", "completed": "done",
                        "finished": "done", "closed": "done", "in_progress": "now", "in progress": "now", "active": "now",
                        "doing": "now", "working": "now", "started": "now", "backlog": "todo"]
        statusRaw = synonyms[statusRaw] ?? statusRaw
        guard let status = DeskStatus(rawValue: statusRaw) else {
            throw ToolFailureError("Unknown status '\(statusRaw)'; use \(DeskStatus.allCases.map(\.rawValue).joined(separator: "/")) or 'waiting on <person>'.", argumentPath: "$.status", effects: .none, code: "invalid_input")
        }
        let reasons = try [deskMetadataString(input, "blocked_reason"), deskMetadataString(input, "reason"), inlineReason, waitNote]
            .compactMap { $0 }.filter { !$0.isEmpty }
        guard Set(reasons).count <= 1 else {
            throw deskInvalid("reason", reason: "desk_set_status: conflicting blocked reasons; blocked_reason, reason, wait note, and status text 'blocked: reason' must agree. Nothing was changed.")
        }
        let blockedReason = reasons.first
        let explicitWaitingOn = try deskMetadataString(input, "waiting_on")
        if let inlineWaitingOn, let explicitWaitingOn, inlineWaitingOn != explicitWaitingOn {
            throw deskInvalid("waiting_on", reason: "desk_set_status: waiting_on must agree with the person named in status. Nothing was changed.")
        }
        let waitingOn = inlineWaitingOn ?? explicitWaitingOn
        // A blocked row must say what or whom it needs.
        if status == .blocked, blockedReason == nil, waitingOn == nil {
            throw deskInvalid("reason", reason: "desk_set_status: blocked needs a reason; send blocked_reason, reason, or status 'blocked: reason', and/or waiting_on. Nothing was changed.")
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
            guard let journal = DeskContinuationScope.current else {
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
                    "reason": .string("\(alias) still has \(open.count) open part\(open.count == 1 ? "" : "s") (\(parts)). desk.close with handle \"\(alias)\", subtree true\(status == .canceled ? ", canceled true" : "") and a summary closes them and it in one call."),
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
        return deskConfirm(try? await store.liveState(), handle: handle, prefix: inlineWaitingOn.map { "waiting on " + $0 } ?? "status set")
    }

    func impl_desk_wait(input: [String: JSONValue], state: DeskState) async throws -> JSONValue {
        let handle = try deskString(input, "handle")
        let values: [JSONValue]
        if case .array(let list)? = input["on"] { values = list }
        else { values = input["on"].map { [$0] } ?? [] }
        let ids = values.compactMap { value -> String? in
            guard case .string(let id) = value, !id.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return nil }
            return id.trimmingCharacters(in: .whitespacesAndNewlines)
        }
        let correction = "desk.wait takes on: a person's name (for example User or owner), a Desk handle/number, an experience id (card, message, delivery or repair), or a list of those dependency ids. note is optional."
        guard !ids.isEmpty, ids.count == values.count else { throw ToolFailureError(correction, argumentPath: "$.on", effects: .none, code: "invalid_input") }
        let store = deskStore()
        // An id an owner just handed out may still be on its way into the store.
        let experiences = ExperienceStore.at(dataRoot)
        await experiences.drained()
        var blockers: [String] = [], settled: [String] = []
        let note = try deskMetadataString(input, "note") ?? deskMetadataString(input, "why")
        for id in ids {
            if let item = try Self.deskMatches(id, in: state, field: "on").first { blockers.append(item.handle); continue }
            // A card answers to its bare id too (its experience is `interaction:<id>`).
            var found = try await experiences.experience(id)
            if found == nil { found = try await experiences.experience("interaction:" + id) }
            guard let experience = found else {
                // A single person's name is a wait, not an invented dependency.
                // Identifier-shaped unknowns still fail at the input boundary.
                let personName = id.contains(where: { $0.isLetter }) && id.allSatisfy {
                    $0.isLetter || $0.isWhitespace || "-'.".contains($0)
                } && !id.lowercased().hasPrefix("desk.")
                if ids.count == 1, personName, case .string? = input["on"] {
                    var statusInput = input
                    statusInput.removeValue(forKey: "wait")
                    statusInput["handle"] = .string(handle)
                    statusInput["status"] = .string("waiting on " + id)
                    if let note { statusInput["note"] = .string(note) }
                    return try await impl_desk_set_status(input: statusInput, state: state)
                }
                throw ToolFailureError("Unknown condition \(id). " + correction, argumentPath: "$.on", effects: .none, code: "invalid_input")
            }
            if experience.isOpen { blockers.append("exp:" + experience.id) } else { settled.append(id) }
        }
        _ = try await store.setBlockedOn(handle, blockers: blockers, waiting: true, note: note)
        if blockers.isEmpty { return deskConfirm(try? await store.liveState(), handle: handle, prefix: "already settled: nothing to wait for; go on now") }
        return deskConfirm(try? await store.liveState(), handle: handle, prefix: "waiting on " + blockers.map { $0.hasPrefix("exp:") ? String($0.dropFirst(4)) : $0 }.joined(separator: ", ")
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
        return deskConfirm(try? await store.liveState(), handle: handle, prefix: "updated")
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
        return deskConfirm(try? await store.liveState(), handle: handle, prefix: "noted")
    }

    // MARK: - desk_add_ref

    func impl_desk_add_ref(input: [String: JSONValue]) async throws -> JSONValue {
        let handle = try deskString(input, "handle")
        let ref = try deskBuildRef(input)
        let store = deskStore()
        _ = try await store.addRef(handle, ref: ref)
        return deskConfirm(try? await store.liveState(), handle: handle, prefix: "ref added (\(ref.kind.token))")
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
        return deskConfirm(try? await store.liveState(), handle: handle, prefix: "cadence \(mode.rawValue)")
    }

    // MARK: - desk_close

    static func validateDeskClose(_ input: [String: JSONValue]) throws {
        let fields = ["handle", "id", "summary", "outcome_summary", "canceled", "subtree", "expected_updated_at"]
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
        guard input["summary"] == nil || input["outcome_summary"] == nil || input["summary"] == input["outcome_summary"] else {
            throw ToolFailureError("summary and its alias must agree.", argumentPath: "$.summary", effects: .none, code: "invalid_input")
        }
        guard case .string(let rawSummary)? = input["summary"] ?? input["outcome_summary"] else {
            throw ToolFailureError("summary is required.", argumentPath: "$.summary", effects: .none, code: "invalid_input")
        }
        let outcome = rawSummary.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !outcome.isEmpty else {
            throw ToolFailureError("summary must not be empty.", argumentPath: "$.summary", effects: .none, code: "invalid_input")
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
        // subtree: close every open descendant deepest-first, then the item,
        // so a whole campaign closes in one call instead of one per row.
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
            let session = ChatToolSessionInjection.explicitSessionId(in: input)
            if !session.isEmpty, let by = try await store.hold([handle] + descendants.map(\.handle), session: session) {
                return .object([
                    "status": .string("refused"), "reason": .string("held_by"), "held_by": .string(by), "effects": .string("none"),
                    "detail": .string("An item in this subtree is held by \(by), which is working it; nothing was closed. Leave it to that one, or pick it up there."),
                ])
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
        return deskConfirm(try? await store.liveState(), handle: handle, prefix: canceled ? "canceled" : "closed")
    }

    // MARK: - desk_blocked_on

    /// desk_blocked_on — point an item at the ITEMS blocking it (never prose).
    /// `blocked_on` is a CSV of visible numbers or handles and REPLACES the whole
    /// set; an EMPTY string clears it.

    func impl_desk_blocked_on(input: [String: JSONValue], state: DeskState) async throws -> JSONValue {
        let handle = try deskString(input, "handle")
        // Absent `blocked_on` is the same as an explicit clear: the op replaces
        // the whole set, so there is no "leave it alone" reading of a missing arg.
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
        // Name the resolved blockers by the ALIASES the operator sees.
        let state = try? await store.liveState()
        let aliases = blockers.compactMap { h in state?.items.first { $0.handle == h }?.alias }
        let prefix = aliases.isEmpty
            ? "blockers cleared"
            : "blocked-on \(aliases.joined(separator: ","))"
        return deskConfirm(state, handle: handle, prefix: prefix)
    }

    // MARK: - desk_defer

    /// desk_defer — park an item until a day (`yyyy-MM-dd`) or ISO stamp. An
    /// empty `until` clears the park. A deferred item is not "next up" and is
    /// never flagged stale.
    func impl_desk_defer(input: [String: JSONValue]) async throws -> JSONValue {
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
        return deskConfirm(
            try? await store.liveState(), handle: handle,
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

    private func deskRequireKind(_ input: [String: JSONValue], _ key: String) throws -> DeskKind {
        let raw = try deskString(input, key).trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard let kind = DeskKind(rawValue: raw) else {
            throw deskInvalid(key,
                reason: "desk_add_item: unknown kind '\(raw)' (expected one of \(DeskKind.allCases.map(\.rawValue).joined(separator: "/")))"
            )
        }
        return kind
    }

    /// Normalize tool spelling and coercions before DeskRef decodes the fields.
    private func deskBuildRef(_ input: [String: JSONValue]) throws -> DeskRef {
        let refKind = try deskString(input, "ref_kind").trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard ["file", "commit", "gh_issue", "gh_pr", "url", "agent", "approval", "trace", "note"].contains(refKind) else {
            throw deskInvalid("ref_kind",
                reason: "desk_add_ref: unknown ref_kind '\(refKind)' (expected file|commit|gh_issue|gh_pr|url|agent|approval|trace|note)"
            )
        }
        var fields = input.filter { $0.value.stringValue?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == false }
        fields["kind"] = .string(refKind)
        for key in ["line", "number"] {
            fields[key] = Self.jsonInt(input[key]).map { .int(Int64($0)) }
        }
        for (tool, stored) in [("handoff_id", "handoffId"), ("session_id", "sessionId"), ("trace_kind", "traceKind")] {
            fields[stored] = optionalString(input, tool).map(JSONValue.string)
        }
        guard let ref = DeskRef.fromJSON(.object(fields)) else {
            throw deskInvalid("ref_kind", reason: "desk_add_ref: ref_kind '\(refKind)' has missing or malformed required fields")
        }
        return DeskRef(kind: ref.kind)
    }

}
