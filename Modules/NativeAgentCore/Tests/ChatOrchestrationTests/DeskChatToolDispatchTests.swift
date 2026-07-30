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
}
