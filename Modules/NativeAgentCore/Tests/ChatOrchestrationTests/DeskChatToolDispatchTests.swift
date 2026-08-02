import Testing
import Foundation
@testable import ChatOrchestration
import NativeAgentCore
import PersistenceCore

// MARK: - desk_* dispatcher-surface tests (agent-desk)
//
// Agent Desk chat lane. desk_read is a read; the nine mutations are medium
// ledger-class writes into <dataRoot>/desk/. Classified LAZY-LOAD
// (catalog-visible + builtInToolNames, NOT alwaysOnCoreNames), same shape as
// the task-ledger tools. These tests drive the impls directly (the same surface
// TaskLedgerChatToolDispatchTests exercises).

@Suite("DeskChatToolDispatch")
struct DeskChatToolDispatchTests {

    private func hermeticRoot() -> URL {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("DeskChatTool-\(UUID().uuidString)", isDirectory: true)
        try? FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        return root
    }

    private func dispatcher(_ root: URL) -> SwiftToolDispatcher {
        SwiftToolDispatcher(dataRoot: root)
    }

    // MARK: Catalog + schema

    @Test func catalogClassifiesDeskReadAlwaysOnAndMutationsLazy() {
        let all = ["desk_read", "desk_add_item", "desk_set_status", "desk_update_item",
                   "desk_note", "desk_add_ref", "desk_set_cadence", "desk_set_notify",
                   "desk_close", "desk_archive"]
        for n in all {
            #expect(SwiftToolDispatcher.builtInToolNames.contains(n), "builtInToolNames missing \(n)")
        }
        // desk_read is ALWAYS-ON (User's pull-to-retrieve flow: "update me on
        // what you're tracking" must work without a tracking keyword). The nine
        // mutations stay lazy — they preload on tracking intent (the capture flow).
        #expect(SwiftToolDispatcher.alwaysOnCoreNames.contains("desk_read"))
        for n in all where n != "desk_read" {
            #expect(!SwiftToolDispatcher.alwaysOnCoreNames.contains(n), "mutation \(n) should be lazy, not always-on")
        }
    }

    @Test func schemasWellFormed() async throws {
        let d = dispatcher(hermeticRoot())
        let schemas = d.builtInToolSchemas(includeFullMacFileTools: false)

        let add = try #require(schemas.first { $0.name == "desk_add_item" })
        let addParsed = try JSONValue.parse(add.parametersJSON)
        guard case .object(let ao) = addParsed, case .array(let areq)? = ao["required"] else {
            Issue.record("desk_add_item schema malformed"); return
        }
        #expect(areq == [.string("kind"), .string("project"), .string("title")])

        let read = try #require(schemas.first { $0.name == "desk_read" })
        let readParsed = try JSONValue.parse(read.parametersJSON)
        guard case .object(let ro) = readParsed, case .array(let rreq)? = ro["required"] else {
            Issue.record("desk_read schema malformed"); return
        }
        #expect(rreq == [])
    }

    // MARK: add → set_status → note → read round-trip

    @Test func addStatusNoteThenReadReflectsChanges() async throws {
        let root = hermeticRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let d = dispatcher(root)

        let created = try await d.impl_desk_add_item(input: [
            "kind": .string("project"),
            "project": .string("NativeAgent"),
            "title": .string("Wire the Desk tools"),
        ])
        guard case .object(let c) = created, c["status"] == .string("ok"),
              case .string(let handle)? = c["handle"], !handle.isEmpty,
              case .string(let alias)? = c["alias"] else {
            Issue.record("add malformed: \(created)"); return
        }

        _ = try await d.impl_desk_set_status(input: [
            "handle": .string(handle),
            "status": .string("now"),
        ])
        _ = try await d.impl_desk_note(input: [
            "handle": .string(handle),
            "text": .string("dispatch + schema landed"),
        ])

        let read = try await d.impl_desk_read(input: [:])
        guard case .object(let r) = read, r["status"] == .string("ok"),
              case .string(let projection)? = r["projection"] else {
            Issue.record("read malformed: \(read)"); return
        }
        // The projection reflects the live item: its alias, the `now` status,
        // its project + title.
        #expect(projection.contains("Wire the Desk tools"))
        #expect(projection.contains("now"))
        #expect(projection.contains("NativeAgent"))
        #expect(projection.contains(alias))
    }

    // MARK: ref + cadence + notify + close round-trip (full mutation surface)

    @Test func refCadenceNotifyCloseAllApply() async throws {
        let root = hermeticRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let d = dispatcher(root)

        let created = try await d.impl_desk_add_item(input: [
            "kind": .string("gh"),
            "project": .string("NativeAgent"),
            "title": .string("Track PR 42"),
        ])
        guard case .object(let c) = created, case .string(let handle)? = c["handle"] else {
            Issue.record("add malformed"); return
        }

        // add_ref (gh_pr shape).
        let refRes = try await d.impl_desk_add_ref(input: [
            "handle": .string(handle),
            "ref_kind": .string("gh_pr"),
            "repo": .string("NativeAgent"),
            "number": .int(42),
            "title": .string("Desk tools"),
        ])
        guard case .object(let rr) = refRes, rr["status"] == .string("ok") else {
            Issue.record("add_ref failed: \(refRes)"); return
        }

        _ = try await d.impl_desk_set_cadence(input: [
            "handle": .string(handle),
            "mode": .string("daily"),
            "refresh_sources": .string("gh, ci"),
        ])
        _ = try await d.impl_desk_set_notify(input: [
            "handle": .string(handle),
            "level": .string("direct"),
            "on": .string("state_change, blocked"),
        ])
        let closeRes = try await d.impl_desk_close(input: [
            "handle": .string(handle),
            "outcome_summary": .string("merged"),
        ])
        guard case .object(let cl) = closeRes, cl["status"] == .string("ok") else {
            Issue.record("close failed: \(closeRes)"); return
        }

        // Verify on-disk live state carries the mutations.
        let store = SwiftNativeDeskStore(dataRoot: root)
        let state = try await store.liveState()
        let item = try #require(state.items.first { $0.handle == handle })
        #expect(item.status == .done)
        #expect(item.summary == "merged")
        #expect(item.cadence.mode == .daily)
        #expect(item.cadence.refreshSources == ["gh", "ci"])
        #expect(item.notify.level == .direct)
        #expect(item.notify.on == ["state_change", "blocked"])
        #expect(item.refs.contains { if case .ghPr = $0.kind { return true } else { return false } })
    }

    // MARK: archive

    @Test func archiveRemovesTerminalItemFromLiveView() async throws {
        let root = hermeticRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let d = dispatcher(root)

        let created = try await d.impl_desk_add_item(input: [
            "kind": .string("plan"),
            "project": .string("NativeAgent"),
            "title": .string("Throwaway"),
        ])
        guard case .object(let c) = created, case .string(let handle)? = c["handle"] else {
            Issue.record("add malformed"); return
        }
        _ = try await d.impl_desk_close(input: [
            "handle": .string(handle),
            "outcome_summary": .string("done"),
        ])
        let arch = try await d.impl_desk_archive(input: ["handle": .string(handle)])
        guard case .object(let a) = arch, a["status"] == .string("ok") else {
            Issue.record("archive failed: \(arch)"); return
        }

        let store = SwiftNativeDeskStore(dataRoot: root)
        let live = try await store.liveState()
        #expect(!live.items.contains { $0.handle == handle })

        // include_archived surfaces it in the read.
        let read = try await d.impl_desk_read(input: ["include_archived": .bool(true)])
        guard case .object(let r) = read, case .string(let proj)? = r["projection"] else {
            Issue.record("read malformed"); return
        }
        #expect(proj.contains("archived"))
        #expect(proj.contains("Throwaway"))
    }

    // MARK: honest refusals

    @Test func setStatusOnBogusHandleThrows() async throws {
        let d = dispatcher(hermeticRoot())
        await #expect(throws: (any Error).self) {
            _ = try await d.impl_desk_set_status(input: [
                "handle": .string("desk_does-not-exist"),
                "status": .string("now"),
            ])
        }
    }

    @Test func addItemUnknownKindThrows() async throws {
        let d = dispatcher(hermeticRoot())
        await #expect(throws: (any Error).self) {
            _ = try await d.impl_desk_add_item(input: [
                "kind": .string("frobnicate"),
                "project": .string("X"),
                "title": .string("Y"),
            ])
        }
    }

    @Test func setStatusUnknownStatusThrows() async throws {
        let root = hermeticRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let d = dispatcher(root)
        let created = try await d.impl_desk_add_item(input: [
            "kind": .string("watch"), "project": .string("X"), "title": .string("Y"),
        ])
        guard case .object(let c) = created, case .string(let handle)? = c["handle"] else {
            Issue.record("add malformed"); return
        }
        await #expect(throws: (any Error).self) {
            _ = try await d.impl_desk_set_status(input: [
                "handle": .string(handle), "status": .string("sideways"),
            ])
        }
    }

    @Test func addRefUnknownKindThrows() async throws {
        let root = hermeticRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let d = dispatcher(root)
        let created = try await d.impl_desk_add_item(input: [
            "kind": .string("watch"), "project": .string("X"), "title": .string("Y"),
        ])
        guard case .object(let c) = created, case .string(let handle)? = c["handle"] else {
            Issue.record("add malformed"); return
        }
        await #expect(throws: (any Error).self) {
            _ = try await d.impl_desk_add_ref(input: [
                "handle": .string(handle), "ref_kind": .string("bogus"),
            ])
        }
    }

    @Test func emptyDeskReadsCleanly() async throws {
        let d = dispatcher(hermeticRoot())
        let read = try await d.impl_desk_read(input: [:])
        guard case .object(let r) = read, r["status"] == .string("ok"),
              case .string(let proj)? = r["projection"] else {
            Issue.record("read malformed: \(read)"); return
        }
        #expect(proj.contains("desk · owner"))
    }

    // Addressability (Agent caught live, 2026-06-29): the mutation tools must
    // accept the VISIBLE desk number, not just the hidden handle.
    @Test func mutationsAcceptVisibleAliasNotJustHandle() async throws {
        let root = hermeticRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let d = dispatcher(root)
        let created = try await d.impl_desk_add_item(input: [
            "kind": .string("watch"), "project": .string("na"), "title": .string("by number"),
        ])
        guard case .object(let c) = created, case .string(let alias)? = c["alias"] else {
            Issue.record("add malformed: \(created)"); return
        }
        // Drive the item by the VISIBLE alias (what desk_read shows), not the handle.
        let res = try await d.impl_desk_set_status(input: ["handle": .string(alias), "status": .string("now")])
        guard case .object(let r) = res, r["status"] == .string("ok") else {
            Issue.record("set_status by alias failed: \(res)"); return
        }
        let store = SwiftNativeDeskStore(dataRoot: root)
        let items = try await store.liveState().items
        let item = try #require(items.first { $0.alias == alias })
        #expect(item.status == .now)
    }

    // MARK: - Workshop pursuit lane (Wave A)

    @Test func pursuitToolsCatalogedLazyNotAlwaysOn() {
        for n in ["desk_open_pursuit", "desk_work_log"] {
            #expect(SwiftToolDispatcher.builtInToolNames.contains(n), "builtInToolNames missing \(n)")
            #expect(!SwiftToolDispatcher.alwaysOnCoreNames.contains(n), "\(n) must be lazy, not always-on")
        }
    }

    @Test func reserveWorkSessionExposesNoTool() {
        // H5 groundwork: the reservation seam is internal API — no chat tool may
        // name it, in the catalog OR the dispatch switch.
        #expect(!SwiftToolDispatcher.builtInToolNames.contains("reserve_work_session"))
        #expect(!SwiftToolDispatcher.builtInToolNames.contains("desk_reserve_work_session"))
        #expect(!SwiftToolDispatcher.alwaysOnCoreNames.contains("reserve_work_session"))
    }

    @Test func deskAddItemCannotMintAgentOrigin() async throws {
        let root = hermeticRoot(); defer { try? FileManager.default.removeItem(at: root) }
        let d = dispatcher(root)
        // desk_add_item has no origin surface at all; whatever it creates is user.
        let created = try await d.impl_desk_add_item(input: [
            "kind": .string("project"), "project": .string("na"), "title": .string("looks like a pursuit"),
            "origin": .string("agent"),   // ignored — no such param
        ])
        guard case .object(let c) = created, case .string(let handle)? = c["handle"] else {
            Issue.record("add malformed: \(created)"); return
        }
        let store = SwiftNativeDeskStore(dataRoot: root)
        let item = try #require(try await store.liveState().items.first { $0.handle == handle })
        #expect(item.origin == .owner)
        #expect(item.pursuit == nil)
    }

    @Test func openPursuitCreatesAgentWithValidDossier() async throws {
        let root = hermeticRoot(); defer { try? FileManager.default.removeItem(at: root) }
        let d = dispatcher(root)
        let res = try await d.impl_desk_open_pursuit(input: [
            "project": .string("na"),
            "title": .string("Why does the pump stall?"),
            "why": .string("It keeps nagging at me."),
            "done_looks_like": .string("A root cause in ≤8 sessions."),
            "abandon_condition": .string("No new evidence after two sessions."),
            "private_name": .string("the stall"),
            "evidence": .array([
                .object(["source": .string("standing_view"), "id": .string("sv1")]),
                .object(["source": .string("trace_friction"), "count": .int(4), "window": .string("7d")]),
            ]),
        ])
        guard case .object(let r) = res, r["status"] == .string("ok"),
              case .string(let handle)? = r["handle"] else {
            Issue.record("open_pursuit malformed: \(res)"); return
        }
        let store = SwiftNativeDeskStore(dataRoot: root)
        let item = try #require(try await store.liveState().items.first { $0.handle == handle })
        #expect(item.origin == .agent)
        #expect(item.isPursuit)
        #expect(item.pursuit?.privateName == "the stall")
    }

    @Test func openPursuitReturnsHonestRefusalOnFrictionOnly() async throws {
        let root = hermeticRoot(); defer { try? FileManager.default.removeItem(at: root) }
        let d = dispatcher(root)
        // A friction-only dossier: the tool RETURNS the store's honest refusal
        // (status "refused"), it does not throw.
        let res = try await d.impl_desk_open_pursuit(input: [
            "project": .string("na"), "title": .string("t"),
            "why": .string("w"), "done_looks_like": .string("d"), "abandon_condition": .string("a"),
            "evidence": .array([
                .object(["source": .string("trace_friction"), "count": .int(9), "window": .string("3d")]),
            ]),
        ])
        guard case .object(let r) = res, r["status"] == .string("refused"),
              case .string(let reason)? = r["reason"] else {
            Issue.record("expected refusal, got: \(res)"); return
        }
        #expect(reason.contains("friction"))
        // Nothing was created.
        let store = SwiftNativeDeskStore(dataRoot: root)
        #expect(try await store.liveState().items.isEmpty)
    }

    @Test func workLogAppendsReceiptToPursuitOnly() async throws {
        let root = hermeticRoot(); defer { try? FileManager.default.removeItem(at: root) }
        let d = dispatcher(root)
        let open = try await d.impl_desk_open_pursuit(input: [
            "project": .string("na"), "title": .string("t"),
            "why": .string("w"), "done_looks_like": .string("d"), "abandon_condition": .string("a"),
            "evidence": .array([
                .object(["source": .string("dream_digest"), "id": .string("dd1")]),
                .object(["source": .string("chat_observation"), "noteIds": .array([.string("n1"), .string("n2"), .string("n3")]), "distinctDays": .int(3)]),
            ]),
        ])
        guard case .object(let o) = open, case .string(let handle)? = o["handle"] else {
            Issue.record("open malformed: \(open)"); return
        }
        let logged = try await d.impl_desk_work_log(input: [
            "handle": .string(handle), "receipt": .string("read the trace, found the wedge"),
        ])
        guard case .object(let l) = logged, l["status"] == .string("ok") else {
            Issue.record("work_log failed: \(logged)"); return
        }
        let store = SwiftNativeDeskStore(dataRoot: root)
        let item = try #require(try await store.liveState().items.first { $0.handle == handle })
        #expect(item.notes.contains { $0.text == "read the trace, found the wedge" })

        // A work receipt on a NON-pursuit (user item) is refused honestly.
        let user = try await d.impl_desk_add_item(input: [
            "kind": .string("plan"), "project": .string("na"), "title": .string("user plan"),
        ])
        guard case .object(let j) = user, case .string(let userHandle)? = j["handle"] else {
            Issue.record("user add malformed"); return
        }
        let refused = try await d.impl_desk_work_log(input: [
            "handle": .string(userHandle), "receipt": .string("nope"),
        ])
        guard case .object(let rf) = refused, rf["status"] == .string("refused") else {
            Issue.record("expected refusal on non-pursuit, got: \(refused)"); return
        }
    }

    // MARK: - Sequencing lane (desk_blocked_on / desk_defer)

    @Test func sequencingToolsAreRegisteredEverywhere() async throws {
        for n in ["desk_blocked_on", "desk_defer"] {
            #expect(SwiftToolDispatcher.builtInToolNames.contains(n), "builtInToolNames missing \(n)")
            #expect(!SwiftToolDispatcher.alwaysOnCoreNames.contains(n), "\(n) should be lazy, not always-on")
        }
        // Schema present (a tool with no schema is invisible to the model).
        let d = dispatcher(hermeticRoot())
        let schemas = d.builtInToolSchemas(includeFullMacFileTools: false)
        _ = try #require(schemas.first { $0.name == "desk_blocked_on" })
        _ = try #require(schemas.first { $0.name == "desk_defer" })
    }

    /// desk_blocked_on accepts the VISIBLE NUMBER for the target AND for every
    /// blocker (invariant 2 — the addressability bug Agent caught live), and an
    /// empty `blocked_on` clears the whole set.
    @Test func blockedOnAcceptsVisibleNumbersForTargetAndBlockersAndClears() async throws {
        let root = hermeticRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let d = dispatcher(root)

        func add(_ title: String) async throws -> (handle: String, alias: String) {
            let res = try await d.impl_desk_add_item(input: [
                "kind": .string("plan"), "project": .string("na"), "title": .string(title),
            ])
            guard case .object(let o) = res, case .string(let h)? = o["handle"],
                  case .string(let a)? = o["alias"] else {
                throw NSError(domain: "test", code: 1, userInfo: [NSLocalizedDescriptionKey: "add malformed: \(res)"])
            }
            return (h, a)
        }
        let a = try await add("blocker A")
        let b = try await add("blocker B")
        let c = try await add("dependent C")

        // Everything addressed by the VISIBLE NUMBER — target and both blockers.
        let res = try await d.impl_desk_blocked_on(input: [
            "handle": .string(c.alias),
            "blocked_on": .string("\(a.alias), \(b.alias)"),
        ])
        guard case .object(let r) = res, r["status"] == .string("ok"),
              case .string(let confirmation)? = r["confirmation"] else {
            Issue.record("desk_blocked_on failed: \(res)"); return
        }
        #expect(confirmation.contains("blocked-on \(a.alias),\(b.alias)"), "confirmation: \(confirmation)")

        let store = SwiftNativeDeskStore(dataRoot: root)
        var row = try #require(try await store.liveState().items.first { $0.handle == c.handle })
        #expect(row.blockedOn == [a.handle, b.handle])

        // Derived: C is blocked, and never appears in next up.
        let plan = DeskSequencing.compute(try await store.liveState())
        #expect(plan.byHandle[c.handle]?.isReady == false)
        #expect(!plan.nextUp.contains(c.handle))

        // Empty string CLEARS.
        let cleared = try await d.impl_desk_blocked_on(input: [
            "handle": .string(c.alias),
            "blocked_on": .string(""),
        ])
        guard case .object(let cl) = cleared, cl["status"] == .string("ok") else {
            Issue.record("clear failed: \(cleared)"); return
        }
        row = try #require(try await store.liveState().items.first { $0.handle == c.handle })
        #expect(row.blockedOn.isEmpty)
        #expect(DeskSequencing.compute(try await store.liveState()).byHandle[c.handle]?.isReady == true)

        // An unresolvable blocker number is an honest denial, not a silent no-op.
        await #expect(throws: (any Error).self) {
            _ = try await d.impl_desk_blocked_on(input: [
                "handle": .string(c.alias), "blocked_on": .string("999"),
            ])
        }
    }

    // MARK: - desk_breakdown (one call: big idea → numbered campaign)

    @Test func breakdownRegisteredEverywhere() async throws {
        #expect(SwiftToolDispatcher.builtInToolNames.contains("desk_breakdown"))
        #expect(!SwiftToolDispatcher.alwaysOnCoreNames.contains("desk_breakdown"))
        let d = dispatcher(hermeticRoot())
        let schemas = d.builtInToolSchemas(includeFullMacFileTools: false)
        _ = try #require(schemas.first { $0.name == "desk_breakdown" })
    }

    /// The whole point: one call creates parent + ordered children + edges +
    /// defer, and reports which children are actionable right now.
    @Test func breakdownCreatesCampaignWithEdgesAndDefer() async throws {
        let root = hermeticRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let d = dispatcher(root)

        let res = try await d.impl_desk_breakdown(input: [
            "project": .string("na"),
            "title": .string("Ship the widget"),
            "children": .array([
                .object(["title": .string("Design the API")]),
                .object(["title": .string("Build the store"), "blocked_on": .string("1")]),
                .object(["title": .string("Wire the UI"), "blocked_on": .string("1,2")]),
                .object(["title": .string("Beta window"), "defer_until": .string("2099-04-01")]),
            ]),
        ])
        guard case .object(let r) = res, r["status"] == .string("ok"),
              case .string(let parentAlias)? = r["parent"],
              case .array(let plan)? = r["plan"],
              case .array(let ready)? = r["ready_now"] else {
            Issue.record("breakdown malformed: \(res)"); return
        }
        #expect(plan.count == 4)
        // Only the unblocked, undeferred child is ready.
        #expect(ready.count == 1)

        let store = SwiftNativeDeskStore(dataRoot: root)
        let state = try await store.liveState()
        let parent = try #require(state.items.first { $0.alias == parentAlias })
        func seq(_ alias: String) -> Int { Int(alias.split(separator: ".").last.map(String.init) ?? "") ?? Int.max }
        let kids = state.items.filter { $0.parent == parent.handle }
            .sorted { seq($0.alias) < seq($1.alias) }
        #expect(kids.count == 4)
        // Child 2 blocked on child 1; child 3 on 1+2; child 4 deferred.
        #expect(kids[1].blockedOn == [kids[0].handle])
        #expect(kids[2].blockedOn == [kids[0].handle, kids[1].handle])
        #expect(kids[3].deferUntil == "2099-04-01")

        // The cascade end-to-end through the TOOL surface: close 1, then 2 —
        // child 3 becomes ready with no further blocked_on call.
        let derived = DeskSequencing.compute(state)
        #expect(derived.byHandle[kids[2].handle]?.isReady == false)
        _ = try await d.impl_desk_close(input: [
            "handle": .string(kids[0].alias), "outcome_summary": .string("done"),
        ])
        _ = try await d.impl_desk_close(input: [
            "handle": .string(kids[1].alias), "outcome_summary": .string("done"),
        ])
        let after = DeskSequencing.compute(try await store.liveState())
        #expect(after.byHandle[kids[2].handle]?.isReady == true)
    }

    /// Graft mode: children attach to an existing parent, project inherited.
    @Test func breakdownGraftsOntoExistingItem() async throws {
        let root = hermeticRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let d = dispatcher(root)
        let created = try await d.impl_desk_add_item(input: [
            "kind": .string("project"), "project": .string("atrium"), "title": .string("Existing campaign"),
        ])
        guard case .object(let c) = created, case .string(let alias)? = c["alias"],
              case .string(let parentHandle)? = c["handle"] else {
            Issue.record("add malformed"); return
        }
        let res = try await d.impl_desk_breakdown(input: [
            "parent": .string(alias),
            "children": .array([
                .object(["title": .string("Grafted step")]),
            ]),
        ])
        guard case .object(let r) = res, r["status"] == .string("ok") else {
            Issue.record("graft failed: \(res)"); return
        }
        let store = SwiftNativeDeskStore(dataRoot: root)
        let kid = try #require(try await store.liveState().items.first { $0.parent == parentHandle })
        #expect(kid.project == "atrium")
        #expect(kid.title == "Grafted step")
    }

    /// An invented child field is REFUSED loudly, never silently dropped —
    /// the live-caught failure: `batch: 2` meaning ordering produced a flat
    /// campaign with zero edges and an all-ready ready_now.
    @Test func breakdownRefusesUnknownChildFieldsAndAcceptsArrayBlockedOn() async throws {
        let root = hermeticRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let d = dispatcher(root)
        await #expect(throws: (any Error).self) {
            _ = try await d.impl_desk_breakdown(input: [
                "project": .string("na"), "title": .string("Flat"),
                "children": .array([
                    .object(["title": .string("A")]),
                    .object(["title": .string("B"), "batch": .int(2)]),
                ]),
            ])
        }
        let store = SwiftNativeDeskStore(dataRoot: root)
        #expect(try await store.liveState().items.isEmpty)

        // The natural LLM shape — blocked_on as an array of ints — works.
        let res = try await d.impl_desk_breakdown(input: [
            "project": .string("na"), "title": .string("Arrayed"),
            "children": .array([
                .object(["title": .string("First")]),
                .object(["title": .string("Second"), "blocked_on": .array([.int(1)])]),
            ]),
        ])
        guard case .object(let r) = res, r["status"] == .string("ok") else {
            Issue.record("array blocked_on failed: \(res)"); return
        }
        let state = try await store.liveState()
        let second = try #require(state.items.first { $0.title == "Second" })
        let first = try #require(state.items.first { $0.title == "First" })
        #expect(second.blockedOn == [first.handle])
    }

    /// A bad batch position fails BEFORE any write — no half-campaign.
    @Test func breakdownBadPositionCreatesNothing() async throws {
        let root = hermeticRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let d = dispatcher(root)
        await #expect(throws: (any Error).self) {
            _ = try await d.impl_desk_breakdown(input: [
                "project": .string("na"), "title": .string("Doomed"),
                "children": .array([
                    .object(["title": .string("A"), "blocked_on": .string("7")]),
                ]),
            ])
        }
        let store = SwiftNativeDeskStore(dataRoot: root)
        #expect(try await store.liveState().items.isEmpty)
    }

    /// desk_defer accepts a visible number, and an empty `until` clears.
    @Test func deferAcceptsVisibleNumberAndClears() async throws {
        let root = hermeticRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let d = dispatcher(root)

        let created = try await d.impl_desk_add_item(input: [
            "kind": .string("plan"), "project": .string("na"), "title": .string("park me"),
        ])
        guard case .object(let c) = created, case .string(let handle)? = c["handle"],
              case .string(let alias)? = c["alias"] else {
            Issue.record("add malformed: \(created)"); return
        }
        let store = SwiftNativeDeskStore(dataRoot: root)

        let deferred = try await d.impl_desk_defer(input: [
            "handle": .string(alias), "until": .string("2099-04-01"),
        ])
        guard case .object(let df) = deferred, df["status"] == .string("ok") else {
            Issue.record("desk_defer failed: \(deferred)"); return
        }
        var row = try #require(try await store.liveState().items.first { $0.handle == handle })
        #expect(row.deferUntil == "2099-04-01")
        #expect(DeskSequencing.compute(try await store.liveState()).byHandle[handle]?.isDeferred == true)

        // Empty CLEARS the park.
        _ = try await d.impl_desk_defer(input: ["handle": .string(alias), "until": .string("")])
        row = try #require(try await store.liveState().items.first { $0.handle == handle })
        #expect(row.deferUntil == nil)
        #expect(DeskSequencing.compute(try await store.liveState()).byHandle[handle]?.isReady == true)

        // An unparseable date is refused HONESTLY (the store's message), not stored.
        let bad = try await d.impl_desk_defer(input: [
            "handle": .string(alias), "until": .string("whenever"),
        ])
        guard case .object(let bo) = bad, bo["status"] == .string("refused") else {
            Issue.record("expected a refusal for an unparseable date, got: \(bad)"); return
        }
        row = try #require(try await store.liveState().items.first { $0.handle == handle })
        #expect(row.deferUntil == nil)
    }

    // MARK: - desk_nag_control (Wave 3 nag lane)

    /// FIVE-SITE REGISTRATION for the new desk tool: dispatch case, catalog
    /// name, schema, Trust profile — and, deliberately, NOT always-on. The nag
    /// switch is flipped in a conversation ABOUT the desk; it never needs to
    /// occupy a slot in every turn's tool budget.
    @Test func nagControlIsRegisteredEverywhereButNotAlwaysOn() async throws {
        #expect(SwiftToolDispatcher.builtInToolNames.contains("desk_nag_control"))
        #expect(!SwiftToolDispatcher.alwaysOnCoreNames.contains("desk_nag_control"))

        let d = dispatcher(hermeticRoot())
        let schemas = d.builtInToolSchemas(includeFullMacFileTools: false)
        let schema = try #require(schemas.first { $0.name == "desk_nag_control" })
        let parsed = try JSONValue.parse(schema.parametersJSON)
        guard case .object(let obj) = parsed, case .array(let req)? = obj["required"] else {
            Issue.record("desk_nag_control schema malformed"); return
        }
        #expect(req == [.string("action")], "Agent parses the intent; the tool takes explicit args")
    }

    /// enable → mute → unmute → status, driven exactly as Agent would drive it,
    /// with the drift digest coming back IN the unmute reply.
    @Test func nagControlEnableMuteUnmuteStatusRoundTrip() async throws {
        let root = hermeticRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let d = dispatcher(root)
        let configStore = DeskNagConfigStore(dataRoot: root)

        // Default: OFF. Nothing on disk, nothing nagging.
        #expect(await configStore.load().enabled == false)

        // "Stay on me about the release track."
        let enabled = try await d.impl_desk_nag_control(input: ["action": .string("enable")])
        guard case .object(let e) = enabled, e["status"] == .string("ok") else {
            Issue.record("enable failed: \(enabled)"); return
        }
        let projectScoped = try await d.impl_desk_nag_control(input: [
            "action": .string("enable"), "scope_kind": .string("project"), "scope_id": .string("NativeAgent"),
        ])
        guard case .object(let p) = projectScoped, p["status"] == .string("ok") else {
            Issue.record("project scope failed: \(projectScoped)"); return
        }
        var config = await configStore.load()
        #expect(config.enabled)
        #expect(config.scopes.contains(DeskNagScope(kind: .project, id: "NativeAgent", enabled: true)))

        // "Go quiet, I'm busy this week."
        let muted = try await d.impl_desk_nag_control(input: [
            "action": .string("mute"), "until": .string("2099-01-01"),
        ])
        guard case .object(let m) = muted, m["status"] == .string("ok") else {
            Issue.record("mute failed: \(muted)"); return
        }
        config = await configStore.load()
        #expect(config.mutedUntil == "2099-01-01")
        #expect(config.isMuted(now: Date()))
        let windowBeforeUnmute = config.windowId

        // Something lands on the desk while he's quiet.
        _ = try await d.impl_desk_add_item(input: [
            "kind": .string("plan"), "project": .string("NativeAgent"), "title": .string("notary credential refresh"),
        ])

        // "Alright, back on me." — the reply itself says what moved.
        let unmuted = try await d.impl_desk_nag_control(input: ["action": .string("unmute")])
        guard case .object(let u) = unmuted, u["status"] == .string("ok"),
              case .array(let drift)? = u["drift"] else {
            Issue.record("unmute malformed: \(unmuted)"); return
        }
        #expect(drift.count == 1, "unmuting must never be blind")
        guard case .string(let line)? = drift.first else {
            Issue.record("drift line malformed"); return
        }
        #expect(line.contains("notary credential refresh"))
        config = await configStore.load()
        #expect(config.mutedUntil == nil)
        #expect(config.windowId == windowBeforeUnmute + 1, "unmute opens a new attention window")

        // status reports the WHOLE config honestly.
        let status = try await d.impl_desk_nag_control(input: ["action": .string("status")])
        guard case .object(let s) = status, s["status"] == .string("ok"),
              case .string(let summary)? = s["summary"], case .object = s["config"] else {
            Issue.record("status malformed: \(status)"); return
        }
        #expect(summary.contains("nagging ON globally"))
        #expect(summary.contains("project NativeAgent: on"))
    }

    /// Item scope takes the visible desk NUMBER (the addressability rule every
    /// desk mutation follows) and stores the stable handle.
    @Test func nagControlItemScopeResolvesTheVisibleNumber() async throws {
        let root = hermeticRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let d = dispatcher(root)

        let created = try await d.impl_desk_add_item(input: [
            "kind": .string("plan"), "project": .string("na"), "title": .string("stay on this one"),
        ])
        guard case .object(let c) = created, case .string(let handle)? = c["handle"],
              case .string(let alias)? = c["alias"] else {
            Issue.record("add malformed: \(created)"); return
        }
        let res = try await d.impl_desk_nag_control(input: [
            "action": .string("enable"), "scope_kind": .string("item"), "scope_id": .string(alias),
        ])
        guard case .object(let r) = res, r["status"] == .string("ok"),
              case .string(let confirmation)? = r["confirmation"] else {
            Issue.record("item scope failed: \(res)"); return
        }
        // Global is still off — the reply says so instead of implying pressure.
        #expect(confirmation.contains("GLOBAL nag switch is off"))
        let config = await DeskNagConfigStore(dataRoot: root).load()
        #expect(config.scopes == [DeskNagScope(kind: .item, id: handle, enabled: true)],
                "aliases are display; handles are identity")
    }

    /// A bad mute date is REFUSED honestly — never silently turned into
    /// "quiet forever", and never a thrown tool error the model can't read.
    @Test func nagControlRefusesAnUnparseableMuteDate() async throws {
        let root = hermeticRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let d = dispatcher(root)

        let res = try await d.impl_desk_nag_control(input: [
            "action": .string("mute"), "until": .string("sometime next week"),
        ])
        guard case .object(let r) = res, r["status"] == .string("refused"),
              case .string(let reason)? = r["reason"] else {
            Issue.record("expected a refusal, got: \(res)"); return
        }
        #expect(reason.contains("yyyy-MM-dd"))
        #expect(await DeskNagConfigStore(dataRoot: root).load().mutedUntil == nil)

        // Omitting `until` IS the indefinite mute — an explicit sentinel, not a
        // parse failure.
        _ = try await d.impl_desk_nag_control(input: ["action": .string("mute")])
        #expect(await DeskNagConfigStore(dataRoot: root).load().mutedUntil == DeskNagConfig.indefiniteMuteSentinel)

        // An unknown action is an honest tool denial, not a no-op.
        await #expect(throws: (any Error).self) {
            _ = try await d.impl_desk_nag_control(input: ["action": .string("yell")])
        }
    }
}
