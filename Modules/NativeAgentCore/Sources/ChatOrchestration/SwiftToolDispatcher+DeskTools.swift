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
}
