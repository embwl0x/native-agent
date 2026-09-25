import Foundation
import NativeAgentCore
import PersistenceCore

// MARK: - Agent Desk chat lane (desk_*)
//
// Ten chat tools over SwiftNativeDeskStore — Agent's personal, event-sourced
// "things the user told me to track" store. desk_read renders the live projection;
// the other nine mutate by op (create/status/update/note/ref/cadence/notify/
// close/archive). Same wiring canon as the cross-agent task-ledger chat lane
// (task_ledger_post / task_ledger_list): always-on catalog block, LAZY-LOADED
// (in builtInToolNames, NOT alwaysOnCoreNames). The store is obtained exactly
// like SwiftNativeTaskLedger(dataRoot:) — pointed at THIS dispatcher's data
// root.
//
// ACTOR: the Desk is Agent's SINGLE personal store — DeskOp carries no actor
// field, so there is no impersonation surface to pin (unlike the cross-agent
// ledger, where the actor is server-pinned to `agent`). Every desk write is
// inherently Agent's. desk_read = read-only; all mutations = the same write
// class as task_ledger_post (`ledger_write`, medium).

extension SwiftToolDispatcher {

    private func deskStore() -> SwiftNativeDeskStore {
        SwiftNativeDeskStore(dataRoot: dataRoot)
    }

    /// Short confirmation for a mutation: the item's view alias + title from the
    /// freshly recompacted live state (falls back to the bare handle if the
    /// item is no longer live, e.g. just archived).
    private func deskConfirm(_ store: SwiftNativeDeskStore, handle: String, prefix: String) async -> JSONValue {
        let state = (try? await store.liveState())
        let item = state?.items.first { $0.handle == handle }
        let label: String
        if let item {
            label = "\(item.alias) \(item.status.rawValue) \(item.title)"
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
    private func deskCSV(_ input: [String: JSONValue], _ key: String) -> [String] {
        guard let raw = optionalString(input, key) else { return [] }
        return raw.split(separator: ",")
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
    }

    /// Parse explicit model-reported progress. Missing means no new progress;
    /// malformed or impossible values fail before any Desk op is appended.
    private func deskProgress(_ input: [String: JSONValue]) throws -> DeskProgress? {
        guard let raw = input["progress"] else { return nil }
        guard case .object(let object) = raw,
              case .int(let doneRaw)? = object["done"],
              case .int(let totalRaw)? = object["total"],
              doneRaw >= Int64(Int.min), doneRaw <= Int64(Int.max),
              totalRaw >= Int64(Int.min), totalRaw <= Int64(Int.max) else {
            throw AutonomyGateError.toolDenied(
                reason: "desk_set_status: progress requires integer done and total fields"
            )
        }
        let note: String?
        switch object["note"] {
        case nil: note = nil
        case .some(.string(let value)): note = value
        default:
            throw AutonomyGateError.toolDenied(reason: "desk_set_status: progress.note must be a string")
        }
        guard let progress = DeskProgress(done: Int(doneRaw), total: Int(totalRaw), note: note) else {
            throw AutonomyGateError.toolDenied(
                reason: "desk_set_status: progress requires 0 <= done <= total and total > 0"
            )
        }
        return progress
    }

    /// Optional live-activity metadata updates only from nonblank strings.
    /// Models may fill optional string slots with blanks; like omission these
    /// preserve the prior value, never clear it or invent a lane reference.
    private func deskMetadataString(_ input: [String: JSONValue], _ key: String) throws -> String? {
        guard let raw = input[key] else { return nil }
        guard case .string(let value) = raw else {
            throw AutonomyGateError.toolDenied(reason: "desk_set_status: \(key) must be a string")
        }
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }

    /// Resolve a mutation's `handle` param to a stable handle. Accepts EITHER a
    /// stable handle (desk_…) OR the visible desk NUMBER the user sees in the
    /// projection ("1", "2.1") — so User/Agent can drive an item by its number,
    /// not a hidden id (the addressability gap Agent caught live, 2026-06-29:
    /// desk numbers were readable but not addressable).
    private func resolveDeskHandle(_ input: [String: JSONValue]) async throws -> String {
        try await resolveDeskRef(try requireString(input, "handle"))
    }

    /// The item number in what she wrote: her screen's `desk.4`, `#4`, or
    /// `4 Title` copied from a board row all mean 4.
    static func deskAlias(_ raw: String) -> String {
        var r = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        if r.lowercased().hasPrefix("desk.") { r = String(r.dropFirst(5)) }
        if r.hasPrefix("#") { r = String(r.dropFirst()) }
        if let first = r.split(separator: " ").first, first.count < r.count,
           first.allSatisfy({ $0.isNumber || $0 == "." }) { r = String(first) }
        return r
    }

    /// Map a handle-or-alias string to a CURRENT stable handle, or throw.
    private func resolveDeskRef(_ raw: String) async throws -> String {
        let r = Self.deskAlias(raw)
        guard !r.isEmpty else {
            throw AutonomyGateError.toolDenied(reason: "desk: empty item reference")
        }
        if r.hasPrefix("desk_") { return r }
        let state = try await deskStore().liveState()
        if let item = state.items.first(where: { $0.alias == r }) { return item.handle }
        if let item = state.items.first(where: { $0.handle == r }) { return item.handle }
        throw AutonomyGateError.toolDenied(
            reason: "desk: no live item numbered or handled '\(r)' — use the desk number you see (e.g. 1 or 2.1), or call desk_read first"
        )
    }

    /// `laneOf` has no hierarchy validator in the store because it is display
    /// metadata, so its tool boundary must prove the referenced item is live.
    private func resolveDeskLaneRef(_ raw: String, updating handle: String? = nil) async throws -> String {
        let reference = Self.deskAlias(raw)
        guard !reference.isEmpty else {
            throw AutonomyGateError.toolDenied(reason: "desk: empty lane_of reference")
        }
        let state = try await deskStore().liveState()
        guard let laneParent = state.items.first(where: {
            $0.handle == reference || $0.alias == reference
        }) else {
            throw AutonomyGateError.toolDenied(
                reason: "desk: lane_of '\(reference)' is not a live Desk item"
            )
        }
        guard laneParent.handle != handle else {
            throw AutonomyGateError.toolDenied(reason: "desk_set_status: an item cannot be its own lane_of parent")
        }
        return laneParent.handle
    }

    // MARK: - desk_read

    /// desk_read — render the bounded live Desk projection, or search the full
    /// live store by exact handle/alias or text. With include_archived=true,
    /// append a compact list of archived records.
    func impl_desk_read(input: [String: JSONValue]) async throws -> JSONValue {
        let store = deskStore()
        let state = try await store.liveState()
        let handle = optionalString(input, "handle")?
            .trimmingCharacters(in: .whitespacesAndNewlines)
        let query = optionalString(input, "query")?
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard handle?.isEmpty != false || query?.isEmpty != false else {
            throw AutonomyGateError.toolDenied(
                reason: "desk_read: use handle for one exact item or query for text search, not both"
            )
        }

        // 2026-09-22: triage view. The board shows 25 rows with no dates, so
        // staleness was unjudgeable; list every open top-level item, oldest first.
        if optionalString(input, "sort") == "stale", handle?.isEmpty != false, query?.isEmpty != false {
            let open = state.topLevel.filter { !$0.status.isTerminal }.sorted {
                $0.updatedAt != $1.updatedAt ? $0.updatedAt < $1.updatedAt : $0.handle < $1.handle
            }
            return .object([
                "status": .string("ok"), "sort": .string("stale"), "count": .int(Int64(open.count)),
                "items": .array(open.map {
                    .object(["id": .string($0.alias), "title": .string(String($0.title.prefix(160))),
                             "status": .string($0.status.rawValue), "updated": .string(String($0.updatedAt.prefix(10)))])
                }),
            ])
        }

        let rawMatches: [DeskItem]
        if let handle, !handle.isEmpty {
            let wanted = Self.deskAlias(handle)
            rawMatches = state.items.filter { $0.handle == wanted || $0.alias == wanted }
        } else if let query, !query.isEmpty {
            let needle = query.folding(
                options: [.caseInsensitive, .diacriticInsensitive],
                locale: Locale(identifier: "en_US_POSIX")
            )
            rawMatches = state.items.filter { item in
                [item.alias, item.handle, item.project, item.title, item.summary ?? ""]
                    .contains { value in
                        value.folding(
                            options: [.caseInsensitive, .diacriticInsensitive],
                            locale: Locale(identifier: "en_US_POSIX")
                        ).contains(needle)
                    }
            }
        } else {
            rawMatches = []
        }

        if input["structured"] == .bool(true) {
            return Self.workspaceDesk(state: state, input: input, handle: handle, query: query, matches: rawMatches)
        }

        let isFiltered = (handle?.isEmpty == false) || (query?.isEmpty == false)
        let matchCap = 25
        let matches = Array(rawMatches.prefix(matchCap))
        let renderState: DeskState
        if isFiltered {
            var selected = Set(matches.map(\.handle))
            var frontier = matches.compactMap(\.parent)
            while let parent = frontier.popLast(), selected.insert(parent).inserted {
                frontier.append(contentsOf: state.items.first { $0.handle == parent }?.parent.map { [$0] } ?? [])
            }
            for match in matches where match.parent == nil {
                selected.formUnion(state.children(of: match.handle).map(\.handle))
            }
            renderState = DeskState(
                items: state.items.filter { selected.contains($0.handle) },
                generatedTs: state.generatedTs
            )
        } else {
            renderState = state
        }
        var text = DeskProjection.render(renderState)
        if isFiltered, matches.isEmpty {
            text += "\nno live Desk items matched"
        }
        // Never a silent cut: say what's hidden and how to reach it.
        if isFiltered, rawMatches.count > matchCap {
            text += "\nshowing \(matchCap) of \(rawMatches.count) matches — narrow the query"
        } else if !isFiltered, case let shown = DeskProjection.cappedTopLevel(state), shown.count < state.topLevel.count {
            let shownHandles = Set(shown.map(\.handle))
            let quietBefore = DeskClock.nowISO(Date().addingTimeInterval(-20 * 86_400))
            let quiet = state.topLevel.filter {
                !$0.status.isTerminal && !shownHandles.contains($0.handle)
                    && DeskProjection.lastActive($0, in: state) < quietBefore
            }.count
            text += "\nshowing \(shown.count) of \(state.topLevel.count) top-level, most recently active first"
                + (quiet > 0 ? " · \(quiet) quiet 20d+" : "")
                + " — sort:\"stale\" to see them; or query / handle"
        }
        // Asked for by NAME: open the folder, not the board. The compact
        // projection above keeps its caps — every note but the latest one of a
        // blocked row is dropped, refs collapse to a count — which is right for
        // a board and useless for "what did we decide on Tuesday". An exact
        // handle/alias read appends the item's own record: summary, refs,
        // dependency edges both ways, parts, and its notes in order. A `query`
        // read is still a board read and is untouched.
        // A query that finds exactly one item opens it too: no second read.
        if handle?.isEmpty == false || matches.count == 1 {
            for match in matches {
                text += "\n\n" + DeskProjection.renderRecord(match, in: state)
            }
        }

        let includeArchived: Bool
        switch input["include_archived"] {
        case .some(.bool(let b)): includeArchived = b
        case .some(.string(let s)): includeArchived = ["true", "1", "yes", "y", "on"].contains(s.lowercased())
        default: includeArchived = false
        }
        if includeArchived {
            let archived = try await store.archivedRecords()
            if !archived.isEmpty {
                var lines = ["", "archived (\(archived.count)):"]
                for rec in archived {
                    lines.append("  \(rec.handle.replacingOccurrences(of: "desk_", with: "")) \(rec.finalStatus.rawValue) \(rec.project) · \(rec.title) — \(rec.summary)")
                }
                text += "\n" + lines.joined(separator: "\n")
            }
        }
        let defaultProjectionIsBounded = !isFiltered && (
            state.topLevel.count > DeskProjection.topLevelCap
                || state.topLevel.filter { $0.status.isTerminal }.count > DeskProjection.doneCap
        )
        return .object([
            "status": .string("ok"),
            "projection": .string(text),
            "liveItemCount": .int(Int64(state.items.count)),
            "topLevelItemCount": .int(Int64(state.topLevel.count)),
            "projectionTopLevelCap": .int(Int64(DeskProjection.topLevelCap)),
            "projectionIsBounded": .bool(defaultProjectionIsBounded),
            "matchCount": .int(Int64(rawMatches.count)),
            "matchesTruncated": .bool(rawMatches.count > matchCap),
        ])
    }

    // MARK: - desk_add_item

    /// desk_add_item — create a Desk item. Returns the new stable handle + alias.
    func impl_desk_add_item(input: [String: JSONValue]) async throws -> JSONValue {
        let kind = try deskRequireKind(input, "kind")
        let project = try requireString(input, "project").trimmingCharacters(in: .whitespacesAndNewlines)
        let title = try requireString(input, "title").trimmingCharacters(in: .whitespacesAndNewlines)
        guard !project.isEmpty, !title.isEmpty else {
            throw AutonomyGateError.toolDenied(reason: "desk_add_item: project and title must be non-empty")
        }
        let parentRaw = optionalString(input, "parent")?.trimmingCharacters(in: .whitespacesAndNewlines)
        let summary = optionalString(input, "summary")?.trimmingCharacters(in: .whitespacesAndNewlines)
        let assignee = optionalString(input, "assignee")?.trimmingCharacters(in: .whitespacesAndNewlines)
        let laneRaw = optionalString(input, "lane_of")?.trimmingCharacters(in: .whitespacesAndNewlines)
        // Resolve a parent given as a number ("2") to its handle, so "add a step
        // under 2" works by the visible alias.
        let parent: String? = (parentRaw?.isEmpty == false) ? try await resolveDeskRef(parentRaw!) : nil
        let laneOf: String? = (laneRaw?.isEmpty == false) ? try await resolveDeskLaneRef(laneRaw!) : nil

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
        return .object([
            "status": .string("ok"),
            "disposition": .string(result.reusedEquivalent ? "existing" : "created"),
            "created": .bool(!result.reusedEquivalent),
            "handle": .string(item.handle),
            "alias": .string(item.alias),
            "confirmation": .string(result.reusedEquivalent
                ? "reused existing \(item.alias) \(item.kind.rawValue) \(item.project) · \(item.title)"
                : "created \(item.alias) \(item.kind.rawValue) \(item.project) · \(item.title)"),
        ])
    }

    // MARK: - desk_open_pursuit

    /// desk_open_pursuit — the ONLY chat path to an origin=agent pursuit. Takes
    /// why / evidence / doneLooksLike / abandonCondition (+ optional privateName,
    /// maxSessions, maxDays). `evidence` is an array of typed citations in the
    /// dossier wire shape ({source, ...}); the store gates on the source-mix rule
    /// and the open-pursuit cap. On a cap or dossier refusal, returns the store's
    /// HONEST refusal text (status "refused") rather than a bare tool error, so
    /// Agent sees exactly why the pursuit was declined.
    func impl_desk_open_pursuit(input: [String: JSONValue]) async throws -> JSONValue {
        let project = try requireString(input, "project").trimmingCharacters(in: .whitespacesAndNewlines)
        let title = try requireString(input, "title").trimmingCharacters(in: .whitespacesAndNewlines)
        guard !project.isEmpty, !title.isEmpty else {
            throw AutonomyGateError.toolDenied(reason: "desk_open_pursuit: project and title must be non-empty")
        }
        // Required pursuit fields resolved from input; the store is the single
        // refusal point for emptiness (returns an honest, specific message).
        let why = (optionalString(input, "why") ?? "")
        let doneLooksLike = (optionalString(input, "done_looks_like") ?? "")
        let abandonCondition = (optionalString(input, "abandon_condition") ?? "")
        let privateName = optionalString(input, "private_name")
        let dossier = deskParseDossier(input)
        let pursuit = Pursuit(
            why: why,
            evidence: dossier,
            doneLooksLike: doneLooksLike,
            maxSessions: optionalInt(input, "max_sessions") ?? Pursuit.defaultMaxSessions,
            maxDays: optionalInt(input, "max_days") ?? Pursuit.defaultMaxDays,
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
            // The store's honest refusal — surfaced as a result, not an exception,
            // so the model reads the reason and can adjust the dossier/scope.
            return .object([
                "status": .string("refused"),
                "reason": .string(e.errorDescription ?? "\(e)"),
            ])
        }
    }

    /// Parse the `evidence` argument (an array of typed citation objects in the
    /// dossier wire shape) into a PromotionDossier. Unknown/malformed citations
    /// are dropped (tolerant) — a dropped citation can only weaken the dossier,
    /// and the store refuses an under-cited pursuit.
    private func deskParseDossier(_ input: [String: JSONValue]) -> PromotionDossier {
        guard case .array(let arr)? = input["evidence"] else { return PromotionDossier(citations: []) }
        return PromotionDossier(citations: arr.compactMap { DossierSource.fromJSON($0) })
    }

    // MARK: - desk_work_log

    /// desk_work_log — append a work receipt note to a pursuit (Agent logging
    /// progress from chat). Refuses a non-pursuit target. Reservation-backed work
    /// completion is Wave B's internal path (completeWorkSession), NOT a tool.
    func impl_desk_work_log(input: [String: JSONValue]) async throws -> JSONValue {
        let handle = try await resolveDeskHandle(input)
        let receipt = try requireString(input, "receipt").trimmingCharacters(in: .whitespacesAndNewlines)
        guard !receipt.isEmpty else {
            throw AutonomyGateError.toolDenied(reason: "desk_work_log: receipt is empty")
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

    func impl_desk_set_status(input: [String: JSONValue]) async throws -> JSONValue {
        let handle = try await resolveDeskHandle(input)
        var statusRaw = try requireString(input, "status").trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        // The words people use for the same states.
        let synonyms = ["cancelled": "canceled", "cancel": "canceled", "dropped": "canceled", "complete": "done", "completed": "done",
                        "finished": "done", "closed": "done", "in_progress": "now", "in progress": "now", "active": "now",
                        "doing": "now", "working": "now", "started": "now", "backlog": "todo"]
        statusRaw = synonyms[statusRaw] ?? statusRaw
        guard let status = DeskStatus(rawValue: statusRaw) else {
            throw AutonomyGateError.toolDenied(
                reason: "desk_set_status: unknown status '\(statusRaw)' (expected one of \(DeskStatus.allCases.map(\.rawValue).joined(separator: "/")))"
            )
        }
        let blockedReason = optionalString(input, "blocked_reason")
        let waitingOn = optionalString(input, "waiting_on")
        let progress = try deskProgress(input)
        let assignee = try deskMetadataString(input, "assignee")
        let laneRaw = try deskMetadataString(input, "lane_of")
        let laneOf: String?
        if let laneRaw {
            laneOf = try await resolveDeskLaneRef(laneRaw, updating: handle)
        } else {
            laneOf = nil
        }
        let store = deskStore()
        // Closing an item with open parts: say the one call that does it.
        if status.isTerminal {
            let state = try await store.liveState()
            let open = SwiftNativeDeskStore.descendants(of: handle, in: state).filter { !$0.status.isTerminal }
            if !open.isEmpty {
                let alias = state.items.first { $0.handle == handle }?.alias ?? handle
                let parts = open.prefix(6).map(\.alias).joined(separator: ", ") + (open.count > 6 ? ", …" : "")
                return .object([
                    "status": .string("refused"),
                    "reason": .string("\(alias) still has \(open.count) open part\(open.count == 1 ? "" : "s") (\(parts)). desk_close with handle \"\(alias)\", subtree true\(status == .canceled ? ", canceled true" : "") and an outcome_summary closes them and it in one call."),
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
        return await deskConfirm(store, handle: handle, prefix: "status set")
    }

    // MARK: - desk_update_item

    func impl_desk_update_item(input: [String: JSONValue]) async throws -> JSONValue {
        let handle = try await resolveDeskHandle(input)
        let title = optionalString(input, "title")
        let summary = optionalString(input, "summary")
        if title == nil && summary == nil {
            throw AutonomyGateError.toolDenied(reason: "desk_update_item: provide at least one of title/summary")
        }
        let store = deskStore()
        _ = try await store.updateTitle(handle, title: title, summary: summary)
        return await deskConfirm(store, handle: handle, prefix: "updated")
    }

    // MARK: - desk_note

    func impl_desk_note(input: [String: JSONValue]) async throws -> JSONValue {
        let handle = try await resolveDeskHandle(input)
        let text = try requireString(input, "text").trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else {
            throw AutonomyGateError.toolDenied(reason: "desk_note: text is empty")
        }
        let store = deskStore()
        _ = try await store.appendNote(handle, text: text)
        return await deskConfirm(store, handle: handle, prefix: "noted")
    }

    // MARK: - desk_add_ref

    func impl_desk_add_ref(input: [String: JSONValue]) async throws -> JSONValue {
        let handle = try await resolveDeskHandle(input)
        let ref = try deskBuildRef(input)
        let store = deskStore()
        _ = try await store.addRef(handle, ref: ref)
        return await deskConfirm(store, handle: handle, prefix: "ref added (\(ref.kind.token))")
    }

    // MARK: - desk_set_cadence

    func impl_desk_set_cadence(input: [String: JSONValue]) async throws -> JSONValue {
        let handle = try await resolveDeskHandle(input)
        let modeRaw = try requireString(input, "mode").trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard let mode = CadenceMode(rawValue: modeRaw) else {
            throw AutonomyGateError.toolDenied(
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

    // MARK: - desk_set_notify

    func impl_desk_set_notify(input: [String: JSONValue]) async throws -> JSONValue {
        let handle = try await resolveDeskHandle(input)
        let levelRaw = try requireString(input, "level").trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard let level = NotifyLevel(rawValue: levelRaw) else {
            throw AutonomyGateError.toolDenied(
                reason: "desk_set_notify: unknown level '\(levelRaw)' (expected one of \(NotifyLevel.allCases.map(\.rawValue).joined(separator: "/")))"
            )
        }
        let policy = NotifyPolicy(
            level: level,
            on: deskCSV(input, "on"),
            cooldown: optionalString(input, "cooldown")
        )
        let store = deskStore()
        _ = try await store.setNotify(handle, policy: policy)
        return await deskConfirm(store, handle: handle, prefix: "notify \(level.rawValue)")
    }

    // MARK: - desk_close

    func impl_desk_close(input: [String: JSONValue]) async throws -> JSONValue {
        let handle = try await resolveDeskHandle(input)
        let outcome = try requireString(input, "outcome_summary").trimmingCharacters(in: .whitespacesAndNewlines)
        guard !outcome.isEmpty else {
            throw AutonomyGateError.toolDenied(reason: "desk_close: outcome_summary must be non-empty")
        }
        func flag(_ key: String) -> Bool {
            switch input[key] {
            case .some(.bool(let b)): return b
            case .some(.string(let s)): return ["true", "1", "yes", "y", "on"].contains(s.lowercased())
            default: return false
            }
        }
        let canceled = flag("canceled")
        let subtree = flag("subtree")
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
            for kid in SwiftNativeDeskStore.descendants(of: handle, in: state).reversed() where !kid.status.isTerminal {
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
                _ = try await store.closeItem(handle, outcomeSummary: outcome, canceled: canceled)
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
                // 2026-09-06: closing an already-terminal item is refused by the
                // store now (it used to overwrite the recorded outcome). Report
                // it the way every other Desk refusal reports, not as a thrown
                // tool error.
                return .object([
                    "status": .string("refused"),
                    "reason": .string(e.errorDescription ?? "\(e)"),
                ])
            }
        }
        return await deskConfirm(store, handle: handle, prefix: canceled ? "canceled" : "closed")
    }

    // MARK: - desk_blocked_on

    /// desk_blocked_on — point an item at the ITEMS blocking it (never prose).
    /// `blocked_on` is a CSV of visible numbers or handles and REPLACES the whole
    /// set; an EMPTY string clears it.
    ///
    /// Every blocker ref goes through `resolveDeskRef` (invariant 2): passing the
    /// visible number must work for the blockers exactly as it does for the
    /// target — the addressability gap Agent caught live.
    func impl_desk_blocked_on(input: [String: JSONValue]) async throws -> JSONValue {
        let handle = try await resolveDeskHandle(input)
        // Absent `blocked_on` is the same as an explicit clear: the op replaces
        // the whole set, so there is no "leave it alone" reading of a missing arg.
        let refs = deskCSV(input, "blocked_on")
        var blockers: [String] = []
        for ref in refs {
            blockers.append(try await resolveDeskRef(ref))
        }
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
        return await deskConfirm(store, handle: handle, prefix: prefix)
    }

    // MARK: - desk_defer

    /// desk_defer — park an item until a day (`yyyy-MM-dd`) or ISO stamp. An
    /// empty `until` clears the park. A deferred item is not "next up" and is
    /// never flagged stale.
    func impl_desk_defer(input: [String: JSONValue]) async throws -> JSONValue {
        let handle = try await resolveDeskHandle(input)
        let raw = optionalString(input, "until")?.trimmingCharacters(in: .whitespacesAndNewlines)
        let until: String? = (raw?.isEmpty == false) ? raw : nil
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

    // MARK: - desk_breakdown

    /// desk_breakdown — one call from a big idea to a numbered campaign: create
    /// a parent (or graft onto an existing item via `parent`), create its
    /// sub-items in order, wire blocked-on edges between them, and park any
    /// child with a defer date.
    ///
    /// In a child's `blocked_on` CSV, a BARE INTEGER is the 1-based position of
    /// a sibling in THIS call; anything else (a dotted number like "3.1" or a
    /// desk_ handle) resolves against the live desk. Top-level items can't be
    /// referenced by their bare number here — that would be ambiguous with
    /// batch positions — so wire those afterward with desk_blocked_on.
    ///
    /// A mid-batch refusal reports status "partial" with everything already
    /// created — never a silent half-campaign.
    func impl_desk_breakdown(input: [String: JSONValue]) async throws -> JSONValue {
        guard case .array(let rawChildren)? = input["children"], !rawChildren.isEmpty else {
            throw AutonomyGateError.toolDenied(reason: "desk_breakdown: children must be a non-empty array")
        }
        struct ChildSpec {
            var title: String
            var summary: String?
            var blockedOnCSV: String
            var deferUntil: String?
        }
        var specs: [ChildSpec] = []
        // An LLM inventing a plausible-but-wrong child field is the NORMAL
        // failure mode, not an edge case — Agent's first live call passed
        // `batch: 2` meaning ordering and got a silently flat campaign.
        // Unknown keys are REFUSED loudly, never dropped.
        let allowedChildKeys: Set<String> = ["title", "summary", "blocked_on", "defer_until"]
        for (idx, raw) in rawChildren.enumerated() {
            guard case .object(let obj) = raw,
                  case .string(let title)? = obj["title"],
                  !title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
                throw AutonomyGateError.toolDenied(reason: "desk_breakdown: child \(idx + 1) needs a non-empty title")
            }
            let unknown = obj.keys.filter { !allowedChildKeys.contains($0) }.sorted()
            guard unknown.isEmpty else {
                throw AutonomyGateError.toolDenied(
                    reason: "desk_breakdown: child \(idx + 1) has unknown field(s) \(unknown.joined(separator: ", ")) — allowed: title, summary, blocked_on, defer_until. For ordering, put the blocking sibling positions in blocked_on (e.g. \"1,2\" or [1,2]).")
            }
            func str(_ k: String) -> String? {
                if case .string(let s)? = obj[k] { return s.trimmingCharacters(in: .whitespacesAndNewlines) }
                return nil
            }
            // blocked_on: CSV string OR an array of strings/ints — the array
            // is the shape a model reaches for naturally; both are honest.
            let blockedOnCSV: String
            switch obj["blocked_on"] {
            case .some(.string(let s)):
                blockedOnCSV = s
            case .some(.array(let arr)):
                var tokens: [String] = []
                for entry in arr {
                    switch entry {
                    case .string(let s): tokens.append(s)
                    case .int(let i): tokens.append(String(i))
                    // Wire JSON numbers decode as .double on some paths (the
                    // bridge caught this live: literal `1` arrived as 1.0) —
                    // an integral double is an integer position.
                    case .double(let d) where d == d.rounded() && d.magnitude < 1_000_000:
                        tokens.append(String(Int(d)))
                    default:
                        throw AutonomyGateError.toolDenied(
                            reason: "desk_breakdown: child \(idx + 1) blocked_on array entries must be strings or integers")
                    }
                }
                blockedOnCSV = tokens.joined(separator: ",")
            case .none:
                blockedOnCSV = ""
            default:
                throw AutonomyGateError.toolDenied(
                    reason: "desk_breakdown: child \(idx + 1) blocked_on must be a CSV string or an array")
            }
            specs.append(ChildSpec(
                title: title.trimmingCharacters(in: .whitespacesAndNewlines),
                summary: (str("summary")?.isEmpty == false) ? str("summary") : nil,
                blockedOnCSV: blockedOnCSV,
                deferUntil: (str("defer_until")?.isEmpty == false) ? str("defer_until") : nil
            ))
        }
        // Pre-validate every batch-position token BEFORE any write, so a bad
        // position fails the whole call instead of leaving a half-campaign.
        for (idx, spec) in specs.enumerated() {
            for token in spec.blockedOnCSV.split(separator: ",")
                .map({ $0.trimmingCharacters(in: .whitespacesAndNewlines) }).filter({ !$0.isEmpty }) {
                if let pos = Int(token) {
                    guard pos >= 1, pos <= specs.count else {
                        throw AutonomyGateError.toolDenied(
                            reason: "desk_breakdown: child \(idx + 1) blocked_on '\(pos)' is not a position in this batch (1–\(specs.count))")
                    }
                    guard pos != idx + 1 else {
                        throw AutonomyGateError.toolDenied(reason: "desk_breakdown: child \(idx + 1) cannot block on itself")
                    }
                }
            }
        }

        let store = deskStore()
        let parentHandle: String
        let project: String
        var reusedParent = false
        let parentRaw = optionalString(input, "parent")?.trimmingCharacters(in: .whitespacesAndNewlines)
        if let parentRaw, !parentRaw.isEmpty {
            // Graft mode: attach the new sub-items to an existing item.
            parentHandle = try await resolveDeskRef(parentRaw)
            let state = try await store.liveState()
            guard let parentItem = state.items.first(where: { $0.handle == parentHandle }) else {
                throw AutonomyGateError.toolDenied(reason: "desk_breakdown: parent '\(parentRaw)' is not live")
            }
            project = parentItem.project
        } else {
            let proj = try requireString(input, "project").trimmingCharacters(in: .whitespacesAndNewlines)
            let title = try requireString(input, "title").trimmingCharacters(in: .whitespacesAndNewlines)
            guard !proj.isEmpty, !title.isEmpty else {
                throw AutonomyGateError.toolDenied(reason: "desk_breakdown: project and title must be non-empty")
            }
            let kindRaw = optionalString(input, "kind")?.trimmingCharacters(in: .whitespacesAndNewlines)
            let kind = (kindRaw?.isEmpty == false) ? DeskKind(rawValue: kindRaw!) : .plan
            guard let kind else {
                throw AutonomyGateError.toolDenied(
                    reason: "desk_breakdown: unknown kind '\(kindRaw ?? "")' — one of \(DeskKind.allCases.map(\.rawValue).joined(separator: ", "))")
            }
            let summary = optionalString(input, "summary")?.trimmingCharacters(in: .whitespacesAndNewlines)
            // A re-run must not mint a second same-titled live campaign under a
            // new number — duplicates read as "the numbers shifted". Reuse the
            // live campaign of the same kind and add only its missing steps.
            let same = SwiftNativeDeskStore.equivalentDeskText
            if let existing = try await store.liveState().topLevel.first(where: {
                !$0.status.isTerminal && $0.kind == kind && same($0.project) == same(proj) && same($0.title) == same(title)
            }) {
                parentHandle = existing.handle
                reusedParent = true
            } else {
                parentHandle = try await store.createItem(
                    kind: kind, project: proj, title: title,
                    parent: nil, summary: (summary?.isEmpty == false) ? summary : nil
                ).handle
            }
            project = proj
        }

        // Create the children in order, then wire edges + defers. From here on
        // a refusal reports PARTIAL state honestly instead of throwing away
        // what already exists on the desk.
        var createdHandles: [String] = []
        var planLines: [String] = []
        // Steps already open under a reused campaign keep their handle and
        // wiring; batch positions still map to them.
        var reusedSteps: Set<Int> = []
        let openSteps = reusedParent
            ? try await store.liveState().children(of: parentHandle).filter { !$0.status.isTerminal } : []
        func partial(_ reason: String) async -> JSONValue {
            let state = try? await store.liveState()
            let parentAlias = state?.items.first { $0.handle == parentHandle }?.alias ?? parentHandle
            return .object([
                "status": .string("partial"),
                "reason": .string(reason),
                "parent": .string(parentAlias),
                "created": .array(planLines.map { .string($0) }),
            ])
        }
        for (idx, spec) in specs.enumerated() {
            if let open = openSteps.first(where: {
                SwiftNativeDeskStore.equivalentDeskText($0.title) == SwiftNativeDeskStore.equivalentDeskText(spec.title)
            }) {
                createdHandles.append(open.handle)
                reusedSteps.insert(idx)
                continue
            }
            do {
                let child = try await store.createItem(
                    kind: .plan, project: project, title: spec.title,
                    parent: parentHandle, summary: spec.summary
                )
                createdHandles.append(child.handle)
                planLines.append("\(child.alias) \(spec.title)")
            } catch {
                return await partial("creating child \(idx + 1) '\(spec.title)': \(error.localizedDescription)")
            }
        }
        for (idx, spec) in specs.enumerated() where !reusedSteps.contains(idx) {
            let tokens = spec.blockedOnCSV.split(separator: ",")
                .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }.filter { !$0.isEmpty }
            if !tokens.isEmpty {
                var blockers: [String] = []
                do {
                    for token in tokens {
                        if let pos = Int(token) {
                            blockers.append(createdHandles[pos - 1])
                        } else {
                            blockers.append(try await resolveDeskRef(token))
                        }
                    }
                    _ = try await store.setBlockedOn(createdHandles[idx], blockers: blockers)
                } catch let e as DeskError {
                    return await partial("wiring child \(idx + 1) blockers: \(e.errorDescription ?? "\(e)")")
                } catch {
                    return await partial("wiring child \(idx + 1) blockers: \(error.localizedDescription)")
                }
            }
            if let until = spec.deferUntil {
                do {
                    _ = try await store.setDeferUntil(createdHandles[idx], until: until)
                } catch let e as DeskError {
                    return await partial("deferring child \(idx + 1): \(e.errorDescription ?? "\(e)")")
                } catch {
                    return await partial("deferring child \(idx + 1): \(error.localizedDescription)")
                }
            }
        }

        // The numbered plan + what's actionable right now, aliases only.
        let state = try await store.liveState()
        let plan = DeskSequencing.compute(state)
        let parentAlias = state.items.first { $0.handle == parentHandle }?.alias ?? parentHandle
        let byHandle = Dictionary(uniqueKeysWithValues: state.items.map { ($0.handle, $0) })
        var lines: [String] = []
        let addedHandles = createdHandles.enumerated().filter { !reusedSteps.contains($0.offset) }.map(\.element)
        for handle in addedHandles {
            guard let item = byHandle[handle] else { continue }
            var segs = ["\(item.alias) \(item.title)"]
            segs.append(contentsOf: DeskProjection.sequencingSegments(item, in: state, plan: plan, includeRollup: false))
            lines.append(segs.joined(separator: " · "))
        }
        let readyNow = createdHandles.filter { plan.byHandle[$0]?.isReady == true }
            .compactMap { byHandle[$0]?.alias }
        if reusedParent {
            return .object([
                "status": .string("existing"),
                "parent": .string(parentAlias),
                "handle": .string(parentHandle),
                "plan": .array(lines.map { .string($0) }),
                "ready_now": .array(readyNow.map { .string($0) }),
                "confirmation": .string("campaign \(parentAlias) already live · added \(addedHandles.count) missing step(s), \(reusedSteps.count) already open"),
            ])
        }
        return .object([
            "status": .string("ok"),
            "parent": .string(parentAlias),
            "handle": .string(parentHandle),
            "plan": .array(lines.map { .string($0) }),
            "ready_now": .array(readyNow.map { .string($0) }),
            "confirmation": .string("campaign \(parentAlias) · \(createdHandles.count) sub-items · ready now: \(readyNow.isEmpty ? "none" : readyNow.joined(separator: ", "))"),
        ])
    }

    // MARK: - desk_archive

    func impl_desk_archive(input: [String: JSONValue]) async throws -> JSONValue {
        let handle = try await resolveDeskHandle(input)
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
        let raw = try requireString(input, key).trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard let kind = DeskKind(rawValue: raw) else {
            throw AutonomyGateError.toolDenied(
                reason: "desk_add_item: unknown kind '\(raw)' (expected one of \(DeskKind.allCases.map(\.rawValue).joined(separator: "/")))"
            )
        }
        return kind
    }

    /// Build a DeskRef from `ref_kind` + that kind's fields. Honest error on an
    /// unknown ref_kind or a missing required field for the chosen kind.
    private func deskBuildRef(_ input: [String: JSONValue]) throws -> DeskRef {
        let refKind = try requireString(input, "ref_kind").trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        func req(_ k: String) throws -> String {
            let v = optionalString(input, k)
            guard let v, !v.isEmpty else {
                throw AutonomyGateError.toolDenied(reason: "desk_add_ref: ref_kind '\(refKind)' requires '\(k)'")
            }
            return v
        }
        func reqInt(_ k: String) throws -> Int {
            guard let v = optionalInt(input, k) else {
                throw AutonomyGateError.toolDenied(reason: "desk_add_ref: ref_kind '\(refKind)' requires integer '\(k)'")
            }
            return v
        }
        let kind: DeskRefKind
        switch refKind {
        case "file":
            kind = .file(path: try req("path"), line: optionalInt(input, "line"), label: optionalString(input, "label"))
        case "commit":
            kind = .commit(sha: try req("sha"), repo: optionalString(input, "repo"), label: optionalString(input, "label"), status: optionalString(input, "status"))
        case "gh_issue":
            kind = .ghIssue(repo: try req("repo"), number: try reqInt("number"), title: optionalString(input, "title"), status: optionalString(input, "status"))
        case "gh_pr":
            kind = .ghPr(repo: try req("repo"), number: try reqInt("number"), title: optionalString(input, "title"), status: optionalString(input, "status"), checks: optionalString(input, "checks"))
        case "url":
            kind = .url(url: try req("url"), title: optionalString(input, "title"))
        case "agent":
            kind = .agent(name: try req("name"), handoffId: optionalString(input, "handoff_id"), sessionId: optionalString(input, "session_id"))
        case "approval":
            kind = .approval(id: try req("id"), status: optionalString(input, "status"))
        case "trace":
            kind = .trace(id: try req("id"), kind: optionalString(input, "trace_kind"))
        case "note":
            kind = .note(text: try req("text"))
        default:
            throw AutonomyGateError.toolDenied(
                reason: "desk_add_ref: unknown ref_kind '\(refKind)' (expected file|commit|gh_issue|gh_pr|url|agent|approval|trace|note)"
            )
        }
        return DeskRef(kind: kind)
    }

    // MARK: - desk_nag_control

    /// desk_nag_control — User's nag switch, driven by DETERMINISTIC params.
    ///
    /// Agent parses the intent ("stay on me about the release track" / "go
    /// quiet, I'm busy this week"); the TOOL takes explicit arguments and never
    /// guesses. Actions: enable | disable | mute | unmute | status.
    ///
    /// `unmute` is the one that carries weight: it clears the mute, opens a new
    /// attention window (re-arming every item's one nag), AND returns the drift
    /// digest in the reply — muted must never mean blind, so the answer to
    /// "what moved while I was quiet?" comes back in the same turn User asks for
    /// the pressure back.
    func impl_desk_nag_control(input: [String: JSONValue]) async throws -> JSONValue {
        let action = try requireString(input, "action")
            .trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        let kindRaw = (optionalString(input, "scope_kind") ?? "global")
            .trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard ["global", "project", "item"].contains(kindRaw) else {
            throw AutonomyGateError.toolDenied(
                reason: "desk_nag_control: unknown scope_kind '\(kindRaw)' (expected global|project|item)")
        }
        let scopeIdRaw = optionalString(input, "scope_id")?.trimmingCharacters(in: .whitespacesAndNewlines)
        let untilRaw = optionalString(input, "until")?.trimmingCharacters(in: .whitespacesAndNewlines)
        let configStore = DeskNagConfigStore(dataRoot: dataRoot)

        switch action {
        case "enable", "disable":
            let on = (action == "enable")
            switch kindRaw {
            case "global":
                let next = try await configStore.update { $0.settingGlobal(on) }
                return .object([
                    "status": .string("ok"),
                    "confirmation": .string("nagging \(on ? "ON" : "OFF") globally (window \(next.windowId))"),
                    "config": deskNagConfigJSON(next),
                ])
            case "project":
                guard let scopeIdRaw, !scopeIdRaw.isEmpty else {
                    throw AutonomyGateError.toolDenied(reason: "desk_nag_control: scope_kind 'project' needs scope_id (the project name)")
                }
                let next = try await configStore.update { $0.settingScope(kind: .project, id: scopeIdRaw, enabled: on) }
                return .object([
                    "status": .string("ok"),
                    "confirmation": .string(deskNagScopeConfirmation(
                        "project \(scopeIdRaw)", on: on, config: next)),
                    "config": deskNagConfigJSON(next),
                ])
            default:
                guard let scopeIdRaw, !scopeIdRaw.isEmpty else {
                    throw AutonomyGateError.toolDenied(reason: "desk_nag_control: scope_kind 'item' needs scope_id (the desk number or handle)")
                }
                // Same addressability rule as every other desk mutation: the
                // visible number works, and it is resolved to a stable handle
                // BEFORE it is stored (aliases are display, handles identity).
                let handle = try await resolveDeskRef(scopeIdRaw)
                let next = try await configStore.update { $0.settingScope(kind: .item, id: handle, enabled: on) }
                let alias = (try? await deskStore().liveState())?.items.first { $0.handle == handle }?.alias
                return .object([
                    "status": .string("ok"),
                    "handle": .string(handle),
                    "confirmation": .string(deskNagScopeConfirmation(
                        "item \(alias ?? handle)", on: on, config: next)),
                    "config": deskNagConfigJSON(next),
                ])
            }

        case "mute":
            // A bad date is REFUSED, not silently turned into "quiet forever" —
            // the failure mode this lane must never have.
            if let untilRaw, !untilRaw.isEmpty, !DeskClock.isParseableDate(untilRaw) {
                return .object([
                    "status": .string("refused"),
                    "reason": .string("desk_nag_control: cannot mute until '\(untilRaw)' — expected a yyyy-MM-dd day or a full ISO timestamp (omit `until` to mute indefinitely)"),
                ])
            }
            let next = try await configStore.update { $0.muted(until: untilRaw?.isEmpty == false ? untilRaw : nil) }
            let phrase = (next.mutedUntil == DeskNagConfig.indefiniteMuteSentinel)
                ? "indefinitely" : "until \(next.mutedUntil ?? "?")"
            return .object([
                "status": .string("ok"),
                "confirmation": .string("nagging muted \(phrase) — still tracking, nothing will ping"),
                "config": deskNagConfigJSON(next),
            ])

        case "unmute":
            // Read the desk ONCE, then compute the digest and consume the drift
            // against that same snapshot inside the config flock.
            let state = try await deskStore().liveState()
            let now = Date()
            let plan = DeskSequencing.compute(state, now: now)
            let (next, digest) = try await configStore.updating { current in
                let lines = DeskNagEvaluator.digestOnUnmute(state: state, plan: plan, config: current, now: now)
                // Consume BEFORE the window bump: what User just read in the
                // digest must not come straight back as a nag on the next tick.
                let consumed = DeskNagEvaluator.consumingDrift(state: state, plan: plan, config: current, now: now)
                return (consumed.unmuted(), lines)
            }
            let summary = digest.isEmpty
                ? "nagging back on (window \(next.windowId)) — nothing drifted while you were quiet"
                : "nagging back on (window \(next.windowId)) — \(digest.count) item(s) moved while quiet"
            return .object([
                "status": .string("ok"),
                "confirmation": .string(summary),
                "drift": .array(digest.map { .string($0) }),
                "config": deskNagConfigJSON(next),
            ])

        case "status":
            let config = await configStore.load()
            let muted = config.isMuted(now: Date())
            var lines: [String] = ["nagging \(config.enabled ? "ON" : "OFF") globally · window \(config.windowId)"]
            if muted {
                lines.append(config.mutedUntil == DeskNagConfig.indefiniteMuteSentinel
                    ? "muted indefinitely" : "muted until \(config.mutedUntil ?? "?")")
            } else if config.mutedUntil != nil {
                lines.append("mute has elapsed (\(config.mutedUntil ?? "")) — the next tick reports the drift")
            }
            if config.scopes.isEmpty {
                lines.append("no scopes — nothing nags until you name a project or item")
            } else {
                for scope in config.scopes {
                    lines.append("  \(scope.kind.rawValue) \(scope.id): \(scope.enabled ? "on" : "off")")
                }
            }
            lines.append("\(config.ledger.count) item(s) already nagged in this window; \(config.observed.count) tracked")
            return .object([
                "status": .string("ok"),
                "summary": .string(lines.joined(separator: "\n")),
                "config": deskNagConfigJSON(config),
            ])

        default:
            throw AutonomyGateError.toolDenied(
                reason: "desk_nag_control: unknown action '\(action)' (expected enable|disable|mute|unmute|status)")
        }
    }

    /// Honest confirmation for a scope flip: turning a scope on while the
    /// GLOBAL switch is off changes nothing yet, and saying so beats letting
    /// User believe the pressure is live.
    private func deskNagScopeConfirmation(_ label: String, on: Bool, config: DeskNagConfig) -> String {
        let base = "nagging \(on ? "ON" : "OFF") for \(label)"
        if on && !config.enabled {
            return base + " — but the GLOBAL nag switch is off, so nothing will ping until you enable it"
        }
        return base
    }

    /// The whole config, verbatim — `status` must be honest, not a summary that
    /// hides the ledger.
    private func deskNagConfigJSON(_ config: DeskNagConfig) -> JSONValue {
        config.toJSON()
    }
}
