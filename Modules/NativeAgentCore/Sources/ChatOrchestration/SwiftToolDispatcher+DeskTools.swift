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

    /// Resolve a mutation's `handle` param to a stable handle. Accepts EITHER a
    /// stable handle (desk_…) OR the visible desk NUMBER the user sees in the
    /// projection ("1", "2.1") — so User/Agent can drive an item by its number,
    /// not a hidden id (the addressability gap Agent caught live, 2026-06-29:
    /// desk numbers were readable but not addressable).
    private func resolveDeskHandle(_ input: [String: JSONValue]) async throws -> String {
        try await resolveDeskRef(try requireString(input, "handle"))
    }

    /// Map a handle-or-alias string to a CURRENT stable handle, or throw.
    private func resolveDeskRef(_ raw: String) async throws -> String {
        let r = raw.trimmingCharacters(in: .whitespacesAndNewlines)
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

    // MARK: - desk_read

    /// desk_read — render the live Desk projection. With include_archived=true,
    /// append a compact list of archived records.
    func impl_desk_read(input: [String: JSONValue]) async throws -> JSONValue {
        let store = deskStore()
        let state = try await store.liveState()
        var text = DeskProjection.render(state)

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
        return .object([
            "status": .string("ok"),
            "projection": .string(text),
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
        // Resolve a parent given as a number ("2") to its handle, so "add a step
        // under 2" works by the visible alias.
        let parent: String? = (parentRaw?.isEmpty == false) ? try await resolveDeskRef(parentRaw!) : nil

        let store = deskStore()
        let item = try await store.createItem(
            kind: kind, project: project, title: title,
            parent: parent,
            summary: (summary?.isEmpty == false) ? summary : nil
        )
        return .object([
            "status": .string("ok"),
            "handle": .string(item.handle),
            "alias": .string(item.alias),
            "confirmation": .string("created \(item.alias) \(item.kind.rawValue) \(item.project) · \(item.title)"),
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
        let statusRaw = try requireString(input, "status").trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard let status = DeskStatus(rawValue: statusRaw) else {
            throw AutonomyGateError.toolDenied(
                reason: "desk_set_status: unknown status '\(statusRaw)' (expected one of \(DeskStatus.allCases.map(\.rawValue).joined(separator: "/")))"
            )
        }
        let blockedReason = optionalString(input, "blocked_reason")
        let waitingOn = optionalString(input, "waiting_on")
        let store = deskStore()
        _ = try await store.setStatus(handle, status: status, blockedReason: blockedReason, waitingOn: waitingOn)
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
        let canceled: Bool
        switch input["canceled"] {
        case .some(.bool(let b)): canceled = b
        case .some(.string(let s)): canceled = ["true", "1", "yes", "y", "on"].contains(s.lowercased())
        default: canceled = false
        }
        let store = deskStore()
        _ = try await store.closeItem(handle, outcomeSummary: outcome, canceled: canceled)
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
            let parentItem = try await store.createItem(
                kind: kind, project: proj, title: title,
                parent: nil, summary: (summary?.isEmpty == false) ? summary : nil
            )
            parentHandle = parentItem.handle
            project = proj
        }

        // Create the children in order, then wire edges + defers. From here on
        // a refusal reports PARTIAL state honestly instead of throwing away
        // what already exists on the desk.
        var createdHandles: [String] = []
        var planLines: [String] = []
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
        for (idx, spec) in specs.enumerated() {
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
        for handle in createdHandles {
            guard let item = byHandle[handle] else { continue }
            var segs = ["\(item.alias) \(item.title)"]
            segs.append(contentsOf: DeskProjection.sequencingSegments(item, in: state, plan: plan, includeRollup: false))
            lines.append(segs.joined(separator: " · "))
        }
        let readyNow = createdHandles.filter { plan.byHandle[$0]?.isReady == true }
            .compactMap { byHandle[$0]?.alias }
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
