import XCTest
import Foundation
@testable import PersistenceCore

private actor AppendFailureGate {
    private let failAt: Int
    private var count = 0
    private var armed = false

    init(failAt: Int) { self.failAt = failAt }

    func arm() {
        count = 0
        armed = true
    }

    func shouldFail() -> Bool {
        guard armed else { return false }
        count += 1
        if count == failAt {
            armed = false
            return true
        }
        return false
    }
}

private final class FailingAppendPersistence: PersistenceCoreProtocol, Sendable {
    private let base = SwiftNativePersistenceCore()
    private let gate: AppendFailureGate

    init(failAt: Int) { self.gate = AppendFailureGate(failAt: failAt) }

    func arm() async { await gate.arm() }

    func readJSON(_ path: URL, defaultValue: JSONValue) async -> JSONValue {
        await base.readJSON(path, defaultValue: defaultValue)
    }

    func writeJSON(_ value: JSONValue, to path: URL) async throws {
        try await base.writeJSON(value, to: path)
    }

    func appendJSONL(_ record: JSONValue, to path: URL) async throws {
        if await gate.shouldFail() {
            throw PersistenceCoreError.ioFailure("injected append failure")
        }
        try await base.appendJSONL(record, to: path)
    }

    func tailJSONL(_ path: URL, limit: Int, maxBytes: Int?) async throws -> [JSONValue] {
        try await base.tailJSONL(path, limit: limit, maxBytes: maxBytes)
    }

    func readJSONL(_ path: URL) async throws -> [JSONValue] {
        try await base.readJSONL(path)
    }
}

// MARK: - Agent Desk store tests
//
// Proves the consumer's non-negotiable invariants:
//   • op round-trip (create→set_status→add_ref→append_note→close).
//   • rebuild-from-ops == in-memory fold; state.json written in-lock.
//   • ALIAS STABILITY — numbers never renumber when siblings close/archive, and
//     a closed/archived sibling's alias is NEVER reused.
//   • projection matches the exact ground-truth shape; caps enforced.
//   • archive refuses non-terminal child / refuses standing; archived item is
//     excluded from live state and present in the archive feed.
//   • staleness marker; tolerant decode (a junk line never crashes rebuild).

final class DeskStoreTests: XCTestCase {

    private func tmpRoot() -> URL {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("desk-\(UUID().uuidString)", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    /// Seed a historical invalid event without going through the production
    /// append boundary. Reconciliation and archive tests need to prove behavior
    /// against feeds written before the hierarchy invariant existed.
    private func appendLegacyOp(_ op: DeskOp, to store: SwiftNativeDeskStore) async throws {
        try await SwiftNativePersistenceCore().appendJSONL(op.toJSON(), to: store.opsPath)
    }

    // MARK: op round-trip

    func test_op_roundtrip_create_status_ref_note_close() async throws {
        let root = tmpRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let store = SwiftNativeDeskStore(dataRoot: root)

        let item = try await store.createItem(kind: .plan, project: "na", title: "wire the desk", summary: "first")
        XCTAssertTrue(item.handle.hasPrefix("desk_"))
        XCTAssertEqual(item.alias, "1")
        XCTAssertEqual(item.status, .watch)            // create default
        XCTAssertEqual(item.cadence.mode, .on_ask)      // create default
        XCTAssertEqual(item.notify.level, .quiet)       // create default

        _ = try await store.setStatus(item.handle, status: .now)
        _ = try await store.addRef(item.handle, ref: DeskRef(kind: .ghPr(repo: "na/repo", number: 50, title: nil, status: "open", checks: nil)))
        _ = try await store.appendNote(item.handle, text: "halfway")
        _ = try await store.closeItem(item.handle, outcomeSummary: "shipped it")

        let state = try await store.liveState()
        let row = try XCTUnwrap(state.items.first { $0.handle == item.handle })
        XCTAssertEqual(row.status, .done)               // close → done
        XCTAssertEqual(row.summary, "shipped it")        // outcomeSummary
        XCTAssertNotNil(row.closedAt)
        XCTAssertEqual(row.refs.count, 1)
        XCTAssertEqual(row.notes.map { $0.text }, ["halfway"])
    }

    // MARK: rebuild-from-ops == in-memory fold; state.json in-lock

    func test_rebuild_equals_fold_and_state_written_in_lock() async throws {
        let root = tmpRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let store = SwiftNativeDeskStore(dataRoot: root)

        let a = try await store.createItem(kind: .watch, project: "na", title: "A")
        let b = try await store.createItem(kind: .plan, project: "atrium", title: "B")
        _ = try await store.setStatus(a.handle, status: .flag)
        let child = try await store.addChild(parentHandle: b.handle, title: "B-child")
        _ = try await store.closeItem(child.handle, outcomeSummary: "done child")
        _ = try await store.closeItem(b.handle, outcomeSummary: "done b")

        // (a) live state recompacted from the ops feed (the in-memory fold).
        let folded = try await store.liveState()
        // (b) the materialized state.json the append wrote IN THE LOCK.
        XCTAssertTrue(FileManager.default.fileExists(atPath: store.statePath.path))
        let onDisk = await SwiftNativePersistenceCore().readJSON(store.statePath, defaultValue: .null)
        guard case .object(let obj) = onDisk, case .array(let arr)? = obj["items"] else {
            return XCTFail("state.json missing items array")
        }
        let diskItems = arr.compactMap { DeskItem.fromJSON($0) }

        // No drift: the two materializations agree item-for-item.
        XCTAssertEqual(diskItems, folded.items)
        XCTAssertEqual(diskItems.count, 3) // A, B, B-child
    }

    // MARK: ALIAS STABILITY

    func test_alias_stability_close_and_new_child_never_reuses() async throws {
        let root = tmpRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let store = SwiftNativeDeskStore(dataRoot: root)

        let one = try await store.createItem(kind: .watch, project: "na", title: "one")
        let two = try await store.createItem(kind: .plan, project: "na", title: "two")
        let three = try await store.createItem(kind: .watch, project: "na", title: "three")
        XCTAssertEqual([one.alias, two.alias, three.alias], ["1", "2", "3"])

        // Close #1 → #2 keeps "2" (never renumbered).
        _ = try await store.closeItem(one.handle, outcomeSummary: "closed one")
        let afterClose = try await store.liveState()
        XCTAssertEqual(afterClose.items.first { $0.handle == two.handle }?.alias, "2")

        // Children 2.1 / 2.2.
        let c1 = try await store.addChild(parentHandle: two.handle, title: "child a")
        let c2 = try await store.addChild(parentHandle: two.handle, title: "child b")
        XCTAssertEqual([c1.alias, c2.alias], ["2.1", "2.2"])

        // Close 2.1 → 2.2 stays "2.2"; the NEXT child is 2.3 (never reuses 2.1).
        _ = try await store.closeItem(c1.handle, outcomeSummary: "closed child a")
        let c3 = try await store.addChild(parentHandle: two.handle, title: "child c")
        XCTAssertEqual(c3.alias, "2.3")
        let live = try await store.liveState()
        XCTAssertEqual(live.items.first { $0.handle == c2.handle }?.alias, "2.2")

        // Archiving the closed 2.1 STILL doesn't free its alias — next is 2.4.
        _ = try await store.archiveItem(c1.handle)
        let c4 = try await store.addChild(parentHandle: two.handle, title: "child d")
        XCTAssertEqual(c4.alias, "2.4")
    }

    // MARK: compaction retains deep nesting (grandchildren are never dropped)

    func test_compact_retains_grandchildren_in_live_state() async throws {
        let root = tmpRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let store = SwiftNativeDeskStore(dataRoot: root)

        let top = try await store.createItem(kind: .plan, project: "na", title: "top")
        let child = try await store.addChild(parentHandle: top.handle, title: "child")
        let grand = try await store.addChild(parentHandle: child.handle, title: "grandchild")
        XCTAssertEqual(grand.alias, "1.1.1")

        let live = try await store.liveState()
        // All three levels present in materialized state — none dropped.
        XCTAssertTrue(live.items.contains { $0.handle == grand.handle })
        XCTAssertEqual(live.items.count, 3)
        // Depth-first order: top, child, grandchild.
        XCTAssertEqual(live.items.map { $0.alias }, ["1", "1.1", "1.1.1"])

        // And the rebuild-from-disk state.json agrees (no drift on deep trees).
        let onDisk = await SwiftNativePersistenceCore().readJSON(store.statePath, defaultValue: .null)
        guard case .object(let obj) = onDisk, case .array(let arr)? = obj["items"] else {
            return XCTFail("state.json missing items")
        }
        XCTAssertEqual(arr.compactMap { DeskItem.fromJSON($0) }, live.items)
    }

    func test_archive_refuses_non_terminal_self() async throws {
        let root = tmpRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let store = SwiftNativeDeskStore(dataRoot: root)

        let it = try await store.createItem(kind: .plan, project: "na", title: "still active")
        _ = try await store.setStatus(it.handle, status: .now) // non-terminal
        do {
            _ = try await store.archiveItem(it.handle)
            XCTFail("expected archive to refuse a non-terminal item")
        } catch let DeskError.archiveRefusedNonTerminalSelf(handle, status) {
            XCTAssertEqual(handle, it.handle)
            XCTAssertEqual(status, .now)
        }
    }

    func test_trace_ref_roundtrips_without_discriminator_collision() {
        let ref = DeskRef(refId: "r1", kind: .trace(id: "t-9", kind: "turn"))
        let decoded = try? XCTUnwrap(DeskRef.fromJSON(ref.toJSON()))
        XCTAssertEqual(decoded, ref)
        guard case let .trace(id, kind)? = decoded?.kind else { return XCTFail("not a trace ref") }
        XCTAssertEqual(id, "t-9")
        XCTAssertEqual(kind, "turn")
    }

    // MARK: projection — exact ground-truth shape

    func test_projection_matches_exact_sample() throws {
        // Fixed instant so staleness / archive countdowns are deterministic.
        let now = Date(timeIntervalSince1970: 1_780_000_000)
        let gen = "2026-06-29T17:00:00.000000+00:00"
        let opened = DeskClock.nowISO(now)

        func item(_ alias: String, parent: String? = nil, kind: DeskKind, status: DeskStatus = .watch,
                  project: String, title: String, summary: String? = nil, refs: [DeskRef] = [],
                  cadence: Cadence = Cadence(), notify: NotifyPolicy = NotifyPolicy(),
                  closedAt: String? = nil) -> DeskItem {
            DeskItem(handle: "h_\(alias)", alias: alias, parent: parent, kind: kind, status: status,
                     project: project, title: title, summary: summary, refs: refs, cadence: cadence,
                     notify: notify, openedAt: opened, updatedAt: opened, closedAt: closedAt)
        }
        func ghIssues(_ n: Int) -> [DeskRef] {
            (1...n).map { DeskRef(kind: .ghIssue(repo: "newproj/repo", number: $0, title: nil, status: "open")) }
        }

        // 1 — watch, stale 42m (lastRefreshAt 42m ago, staleAfter 30m).
        let i1 = item("1", kind: .watch, project: "na", title: "executions list refresh lag -> #50",
                      cadence: Cadence(mode: .on_ask, lastRefreshAt: DeskClock.nowISO(now.addingTimeInterval(-2520)), staleAfter: "30m"))
        // 2 — plan with 3 refs + 3 children; the `now` child highlights inline.
        let i2 = item("2", kind: .plan, project: "atrium", title: "clean-rebuild cmd center",
                      refs: [DeskRef(kind: .file(path: "a.swift", line: nil, label: nil)),
                             DeskRef(kind: .file(path: "b.swift", line: nil, label: nil)),
                             DeskRef(kind: .commit(sha: "abc1234", repo: nil, label: nil, status: nil))])
        let i2a = item("2.1", parent: "h_2", kind: .plan, status: .done, project: "atrium", title: "GRDB schema scaffold")
        let i2b = item("2.2", parent: "h_2", kind: .plan, status: .now, project: "atrium", title: "session store -> GRDB")
        let i2c = item("2.3", parent: "h_2", kind: .plan, status: .next, project: "atrium", title: "outbound dispatch queue")
        // 3 — event-driven; renders the notify segment `quiet/event`.
        let i3 = item("3", kind: .watch, project: "standing", title: "ping when Codex lands big diff -> Claude xreview",
                      cadence: Cadence(mode: .event), notify: NotifyPolicy(level: .quiet, on: ["big_diff"]))
        // 4 — gh container: summary + a single `next` child collapsed inline + refs:6.
        let i4 = item("4", kind: .gh, project: "newproj", title: "repo/name", summary: "6 open issues", refs: ghIssues(6))
        let i4c = item("4.1", parent: "h_4", kind: .gh, status: .next, project: "newproj", title: "read issues + draft plan")
        // 5 — done within grace → `archives in 2d`.
        let i5 = item("5", kind: .plan, status: .done, project: "na", title: "subconscious additive-warmth tuning",
                      closedAt: DeskClock.nowISO(now))

        let state = DeskState(items: [i1, i2, i2a, i2b, i2c, i3, i4, i4c, i5], generatedTs: gen)
        let rendered = DeskProjection.render(state, now: now)

        // Sequencing wave: parents gain a DERIVED `<done>/<total> done` rollup
        // (items 2 and 4 have children), and the desk gains the trailing
        // `next up:` section — the "what's next" answer. Rows with no children,
        // no blockers and no defer render exactly as before.
        let expected = """
        desk · owner · rev \(gen) · stale ok
        status: watch · flag · now · next · todo · done · blocked
        1 watch na · executions list refresh lag -> #50 · stale:42m
        2 plan atrium · clean-rebuild cmd center · now session store -> GRDB · 1/3 closed · refs:3
          2.1 done GRDB schema scaffold
          2.2 now session store -> GRDB
          2.3 next outbound dispatch queue
        3 watch standing · ping when Codex lands big diff -> Claude xreview · quiet/event
        4 gh newproj · repo/name · 6 open issues · next read issues + draft plan · 0/1 closed · refs:6
        5 done na · subconscious additive-warmth tuning · archives in 2d
        next up:
          2.2 now session store -> GRDB
          4.1 next read issues + draft plan
          2.3 next outbound dispatch queue
          1 watch executions list refresh lag -> #50
          2 watch clean-rebuild cmd center
        """
        XCTAssertEqual(rendered, expected)
    }

    // MARK: projection — caps

    func test_projection_caps_top_level_25_and_done_3() {
        let gen = "2026-06-29T17:00:00.000000+00:00"
        let opened = "2026-06-29T16:00:00.000000+00:00"

        // 26 live watch items → at most 25 rendered.
        let many = (1...26).map {
            DeskItem(handle: "h\($0)", alias: "\($0)", kind: .watch, status: .watch,
                     project: "na", title: "t\($0)", openedAt: opened, updatedAt: opened)
        }
        let renderedMany = DeskProjection.render(DeskState(items: many, generatedTs: gen))
        let topLines = itemLines(renderedMany)
        XCTAssertEqual(topLines.count, 25)

        // 5 done items → at most 3 rendered (most-recent by closedAt).
        let dones = (1...5).map { i in
            DeskItem(handle: "d\(i)", alias: "\(i)", kind: .plan, status: .done,
                     project: "na", title: "d\(i)", openedAt: opened, updatedAt: opened,
                     closedAt: "2026-06-29T1\(i):00:00.000000+00:00", pinned: true) // pinned → suppress countdown noise
        }
        let renderedDone = DeskProjection.render(DeskState(items: dones, generatedTs: gen))
        XCTAssertEqual(itemLines(renderedDone).count, 3)
    }

    /// The desk's ITEM region: everything after the 2 header lines and before the
    /// trailing `next up:` section, top-level rows only (children are indented).
    private func itemLines(_ rendered: String) -> [Substring] {
        var lines = rendered.split(separator: "\n").dropFirst(2)
        if let cut = lines.firstIndex(of: "next up:") {
            lines = lines[..<cut]
        }
        return lines.filter { !$0.hasPrefix("  ") }
    }

    func test_projection_refs_summarized_when_three_or_more() {
        let gen = "2026-06-29T17:00:00.000000+00:00"
        let opened = "2026-06-29T16:00:00.000000+00:00"
        let refs = (1...4).map { DeskRef(kind: .ghIssue(repo: "r", number: $0, title: nil, status: "open")) }
        let it = DeskItem(handle: "h1", alias: "1", kind: .gh, status: .watch, project: "na",
                          title: "x", refs: refs, openedAt: opened, updatedAt: opened)
        let rendered = DeskProjection.render(DeskState(items: [it], generatedTs: gen))
        XCTAssertTrue(rendered.contains("refs:4"), rendered)
    }

    // MARK: ref priority order

    func test_ref_priority_order_live_render() {
        let opened = "2026-06-29T16:00:00.000000+00:00"
        // Scrambled insertion order; liveRefs must return priority order:
        // gh_pr > gh_issue > file > commit > url > … (capped at 3).
        let it = DeskItem(handle: "h1", alias: "1", kind: .gh, status: .watch, project: "na", title: "x",
                          refs: [
                            DeskRef(kind: .note(text: "n")),
                            DeskRef(kind: .file(path: "f.swift", line: nil, label: nil)),
                            DeskRef(kind: .ghPr(repo: "r", number: 7, title: nil, status: "open", checks: nil)),
                            DeskRef(kind: .ghIssue(repo: "r", number: 8, title: nil, status: "open")),
                          ],
                          openedAt: opened, updatedAt: opened)
        let tokens = it.liveRefs(limit: 3).map { $0.kind.token }
        XCTAssertEqual(tokens, ["gh_pr", "gh_issue", "file"])
    }

    // MARK: update_ref — in-place cached-field update

    func test_update_ref_merges_cached_fields_in_place() async throws {
        let root = tmpRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let store = SwiftNativeDeskStore(dataRoot: root)

        let it = try await store.createItem(kind: .gh, project: "na", title: "pr watch")
        let ref = DeskRef(kind: .ghPr(repo: "na/repo", number: 12, title: "old", status: "open", checks: nil))
        _ = try await store.addRef(it.handle, ref: ref)
        _ = try await store.updateRef(it.handle, refId: ref.refId, cachedFields: [
            "status": .string("merged"), "checks": .string("green"), "title": .string("new"),
        ])
        let liveAfter = try await store.liveState()
        let row = try XCTUnwrap(liveAfter.items.first { $0.handle == it.handle })
        guard case let .ghPr(repo, number, title, status, checks) = row.refs.first?.kind else {
            return XCTFail("expected a gh_pr ref")
        }
        XCTAssertEqual(repo, "na/repo")     // identity field untouched
        XCTAssertEqual(number, 12)          // identity field untouched
        XCTAssertEqual(title, "new")
        XCTAssertEqual(status, "merged")
        XCTAssertEqual(checks, "green")
    }

    // MARK: archive — refusals + exclusion + feed presence

    func test_archive_refuses_non_terminal_child() async throws {
        let root = tmpRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let store = SwiftNativeDeskStore(dataRoot: root)

        let parent = try await store.createItem(kind: .plan, project: "na", title: "parent")
        let child = try await store.addChild(parentHandle: parent.handle, title: "open child")
        _ = try await store.setStatus(child.handle, status: .now) // non-terminal
        // Seed a legacy contradictory row directly; public close now refuses
        // this shape before it can enter the event log.
        try await appendLegacyOp(DeskOp(
            handle: parent.handle,
            body: .closeItem(outcomeSummary: "parent done", status: .done)
        ), to: store)

        do {
            _ = try await store.archiveItem(parent.handle)
            XCTFail("expected archive to refuse a non-terminal child")
        } catch let DeskError.archiveRefusedNonTerminalChild(handle, childHandle) {
            XCTAssertEqual(handle, parent.handle)
            XCTAssertEqual(childHandle, child.handle)
        }
    }

    func test_close_and_terminal_status_refuse_non_terminal_descendants() async throws {
        let root = tmpRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let store = SwiftNativeDeskStore(dataRoot: root)

        let parent = try await store.createItem(kind: .plan, project: "na", title: "parent")
        let child = try await store.addChild(parentHandle: parent.handle, title: "open child")
        _ = try await store.setStatus(child.handle, status: .next)
        let opsBefore = try await store.readOpsUnlocked().count

        do {
            _ = try await store.closeItem(parent.handle, outcomeSummary: "claimed done")
            XCTFail("expected close to refuse an open child")
        } catch let DeskError.terminalStatusRefusedNonTerminalChild(handle, childHandle) {
            XCTAssertEqual(handle, parent.handle)
            XCTAssertEqual(childHandle, child.handle)
        }
        do {
            _ = try await store.setStatus(parent.handle, status: .done)
            XCTFail("expected terminal setStatus to refuse an open child")
        } catch let DeskError.terminalStatusRefusedNonTerminalChild(handle, childHandle) {
            XCTAssertEqual(handle, parent.handle)
            XCTAssertEqual(childHandle, child.handle)
        }
        do {
            _ = try await store.append(DeskOp(
                handle: parent.handle,
                body: .closeItem(outcomeSummary: "raw close", status: .done)
            ))
            XCTFail("expected raw append to enforce the same hierarchy invariant")
        } catch let DeskError.terminalStatusRefusedNonTerminalChild(handle, childHandle) {
            XCTAssertEqual(handle, parent.handle)
            XCTAssertEqual(childHandle, child.handle)
        }

        let opsAfter = try await store.readOpsUnlocked().count
        XCTAssertEqual(opsAfter, opsBefore)
        let live = try await store.liveState()
        XCTAssertEqual(live.items.first { $0.handle == parent.handle }?.status, .watch)
        XCTAssertEqual(live.items.first { $0.handle == child.handle }?.status, .next)
    }

    func test_terminal_transition_refuses_non_terminal_grandchild() async throws {
        let root = tmpRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let store = SwiftNativeDeskStore(dataRoot: root)

        let top = try await store.createItem(kind: .plan, project: "na", title: "top")
        let child = try await store.addChild(parentHandle: top.handle, title: "child")
        let grandchild = try await store.addChild(parentHandle: child.handle, title: "grandchild")
        _ = try await store.setStatus(grandchild.handle, status: .next)
        try await appendLegacyOp(DeskOp(
            handle: child.handle,
            body: .closeItem(outcomeSummary: "legacy child close", status: .done)
        ), to: store)
        let opsBefore = try await store.readOpsUnlocked().count

        do {
            _ = try await store.closeItem(top.handle, outcomeSummary: "claimed top close")
            XCTFail("expected recursive descendant guard")
        } catch let DeskError.terminalStatusRefusedNonTerminalChild(handle, childHandle) {
            XCTAssertEqual(handle, top.handle)
            XCTAssertEqual(childHandle, grandchild.handle)
        }
        let opsAfter = try await store.readOpsUnlocked().count
        XCTAssertEqual(opsAfter, opsBefore)
    }

    func test_create_child_refuses_terminal_parent() async throws {
        let root = tmpRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let store = SwiftNativeDeskStore(dataRoot: root)

        let parent = try await store.createItem(kind: .plan, project: "na", title: "parent")
        _ = try await store.closeItem(parent.handle, outcomeSummary: "done")

        do {
            _ = try await store.addChild(parentHandle: parent.handle, title: "late child")
            XCTFail("expected terminal parent to reject a new child")
        } catch let DeskError.childRefusedTerminalParent(parentHandle) {
            XCTAssertEqual(parentHandle, parent.handle)
        }
        let liveCount = try await store.liveState().items.count
        XCTAssertEqual(liveCount, 1)
    }

    func test_reopening_child_refuses_terminal_ancestor() async throws {
        let root = tmpRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let store = SwiftNativeDeskStore(dataRoot: root)

        let parent = try await store.createItem(kind: .plan, project: "na", title: "parent")
        let child = try await store.addChild(parentHandle: parent.handle, title: "child")
        _ = try await store.closeItem(child.handle, outcomeSummary: "child done")
        _ = try await store.closeItem(parent.handle, outcomeSummary: "parent done")
        let opsBefore = try await store.readOpsUnlocked().count

        do {
            _ = try await store.setStatus(child.handle, status: .next)
            XCTFail("expected reopen beneath terminal ancestor to fail")
        } catch let DeskError.nonTerminalStatusRefusedTerminalAncestor(handle, ancestorHandle) {
            XCTAssertEqual(handle, child.handle)
            XCTAssertEqual(ancestorHandle, parent.handle)
        }
        let opsAfter = try await store.readOpsUnlocked().count
        XCTAssertEqual(opsAfter, opsBefore)
    }

    func test_reconcile_terminal_parents_appends_prior_nonterminal_status_and_is_idempotent() async throws {
        let root = tmpRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let store = SwiftNativeDeskStore(dataRoot: root)

        let parent = try await store.createItem(kind: .plan, project: "na", title: "parent")
        _ = try await store.setStatus(parent.handle, status: .now)
        let child = try await store.addChild(parentHandle: parent.handle, title: "child")
        _ = try await store.setStatus(child.handle, status: .next)
        try await appendLegacyOp(DeskOp(
            handle: parent.handle,
            body: .closeItem(outcomeSummary: "claimed done", status: .done)
        ), to: store)
        let before = try await store.readOpsUnlocked()

        let repairs = try await store.reconcileTerminalParentsWithNonTerminalDescendants()

        XCTAssertEqual(repairs.count, 1)
        XCTAssertEqual(repairs.first?.handle, parent.handle)
        if case .setStatus(let status, _, _)? = repairs.first?.body {
            XCTAssertEqual(status, .now)
        } else {
            XCTFail("expected append-only set_status repair")
        }
        let after = try await store.readOpsUnlocked()
        XCTAssertEqual(after.count, before.count + 1)
        XCTAssertTrue(after.contains { op in
            guard op.handle == parent.handle,
                  case .closeItem(_, .done) = op.body else { return false }
            return true
        })
        let live = try await store.liveState()
        XCTAssertEqual(live.items.first { $0.handle == parent.handle }?.status, .now)
        XCTAssertEqual(live.items.first { $0.handle == child.handle }?.status, .next)

        let secondRepairs = try await store.reconcileTerminalParentsWithNonTerminalDescendants()
        let finalCount = try await store.readOpsUnlocked().count
        XCTAssertEqual(secondRepairs, [])
        XCTAssertEqual(finalCount, after.count)
    }

    func test_archive_refuses_standing() async throws {
        let root = tmpRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let store = SwiftNativeDeskStore(dataRoot: root)

        let standing = try await store.createItem(kind: .standing, project: "na", title: "standing watcher")
        do {
            _ = try await store.archiveItem(standing.handle)
            XCTFail("expected archive to refuse a standing item")
        } catch DeskError.archiveRefusedStanding {
            // expected
        }
    }

    func test_raw_archive_append_cannot_bypass_guarded_archive_path() async throws {
        let root = tmpRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let store = SwiftNativeDeskStore(dataRoot: root)

        let item = try await store.createItem(kind: .plan, project: "na", title: "done")
        _ = try await store.closeItem(item.handle, outcomeSummary: "done")
        let opsBefore = try await store.readOpsUnlocked().count

        do {
            _ = try await store.append(DeskOp(handle: item.handle, body: .archiveItem))
            XCTFail("expected direct archive append to be refused")
        } catch let DeskError.directArchiveRequiresGuardedPath(handle) {
            XCTAssertEqual(handle, item.handle)
        }
        let opsAfter = try await store.readOpsUnlocked().count
        let live = try await store.liveState()
        let archived = try await store.archivedRecords()
        XCTAssertEqual(opsAfter, opsBefore)
        XCTAssertTrue(live.items.contains { $0.handle == item.handle })
        XCTAssertTrue(archived.isEmpty)
    }

    func test_archive_excludes_from_live_and_present_in_feed() async throws {
        let root = tmpRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let store = SwiftNativeDeskStore(dataRoot: root)

        let it = try await store.createItem(kind: .plan, project: "na", title: "to archive", summary: "the work")
        _ = try await store.addRef(it.handle, ref: DeskRef(kind: .ghPr(repo: "r", number: 1, title: nil, status: "merged", checks: nil)))
        _ = try await store.closeItem(it.handle, outcomeSummary: "shipped")
        let record = try await store.archiveItem(it.handle)

        // Excluded from live state.
        let live = try await store.liveState()
        XCTAssertFalse(live.items.contains { $0.handle == it.handle })

        // Present in the archive feed with the final fields.
        let feed = try await store.archivedRecords()
        let rec = try XCTUnwrap(feed.first { $0.handle == it.handle })
        XCTAssertEqual(rec.finalStatus, .done)
        XCTAssertEqual(rec.title, "to archive")
        XCTAssertEqual(rec.summary, "shipped")
        XCTAssertEqual(rec.refs.count, 1)
        XCTAssertEqual(record.handle, it.handle)
    }

    func test_archive_sweep_returns_eligible_but_does_not_mutate() async throws {
        let root = tmpRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let store = SwiftNativeDeskStore(dataRoot: root)

        let done = try await store.createItem(kind: .plan, project: "na", title: "old done")
        _ = try await store.closeItem(done.handle, outcomeSummary: "done")
        let openItem = try await store.createItem(kind: .plan, project: "na", title: "still open")
        _ = openItem

        // closedAt is "now" → not past a 48h grace; sweep returns nothing yet.
        let none = try await store.archiveSweep(now: Date())
        XCTAssertTrue(none.isEmpty)

        // Far-future now → past grace → eligible. Sweep is pure: nothing archived.
        let future = Date().addingTimeInterval(72 * 3600)
        let eligible = try await store.archiveSweep(now: future)
        XCTAssertEqual(eligible, [done.handle])
        let live = try await store.liveState()
        XCTAssertTrue(live.items.contains { $0.handle == done.handle }) // NOT auto-archived
    }

    // MARK: tolerant decode

    func test_tolerant_decode_junk_line_does_not_crash_rebuild() async throws {
        let root = tmpRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let store = SwiftNativeDeskStore(dataRoot: root)

        let it = try await store.createItem(kind: .watch, project: "na", title: "valid")

        // Inject a junk line AND an unknown-op-token line directly into the feed.
        let junk = "this is not json\n"
        let unknownOp = "{\"opId\":\"x\",\"ts\":\"2026-06-29T16:00:00.000000+00:00\",\"op\":\"frobnicate\",\"handle\":\"h\"}\n"
        let handle = FileHandle(forWritingAtPath: store.opsPath.path)
        try handle?.seekToEnd()
        handle?.write(Data((junk + unknownOp).utf8))
        try handle?.close()

        // Rebuild survives: only the valid op materializes.
        let ops = try await store.readOpsUnlocked()
        XCTAssertEqual(ops.count, 1)
        let live = try await store.liveState()
        XCTAssertEqual(live.items.count, 1)
        XCTAssertEqual(live.items.first?.handle, it.handle)
    }

    // MARK: - Review-fix regressions (gpt-5.5 correctness pass, 2026-06-29)

    /// HIGH: a mutation on a missing OR archived handle must THROW, not silently
    /// append an op that changes nothing.
    func test_mutation_on_unknown_or_archived_handle_throws() async throws {
        let root = tmpRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let store = SwiftNativeDeskStore(dataRoot: root)

        do {
            _ = try await store.setStatus("desk_nope", status: .now)
            XCTFail("expected unknownHandle on a missing handle")
        } catch DeskError.unknownHandle { /* expected */ }

        let it = try await store.createItem(kind: .plan, project: "na", title: "x")
        _ = try await store.closeItem(it.handle, outcomeSummary: "done")
        _ = try await store.archiveItem(it.handle)
        do {
            _ = try await store.appendNote(it.handle, text: "too late")
            XCTFail("expected unknownHandle on an archived handle")
        } catch DeskError.unknownHandle { /* expected */ }
    }

    /// HIGH: archive recurses the WHOLE subtree — a terminal child with a
    /// non-terminal grandchild is refused (direct-only check would have missed it).
    func test_archive_refuses_non_terminal_grandchild() async throws {
        let root = tmpRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let store = SwiftNativeDeskStore(dataRoot: root)

        let top = try await store.createItem(kind: .plan, project: "na", title: "top")
        let child = try await store.addChild(parentHandle: top.handle, title: "child")
        let grand = try await store.addChild(parentHandle: child.handle, title: "grandchild")
        _ = try await store.setStatus(grand.handle, status: .now)                 // non-terminal grandchild
        // Seed the legacy contradictory hierarchy directly so archive's
        // independent refusal remains covered after mutation-time guards.
        try await appendLegacyOp(DeskOp(
            handle: child.handle,
            body: .closeItem(outcomeSummary: "child done", status: .done)
        ), to: store)
        try await appendLegacyOp(DeskOp(
            handle: top.handle,
            body: .closeItem(outcomeSummary: "top done", status: .done)
        ), to: store)

        do {
            _ = try await store.archiveItem(top.handle)
            XCTFail("expected refusal on a non-terminal grandchild")
        } catch let DeskError.archiveRefusedNonTerminalChild(handle, childHandle) {
            XCTAssertEqual(handle, top.handle)
            XCTAssertEqual(childHandle, grand.handle)
        }
    }

    /// HIGH: archiving a fully-terminal tree cascades — no live orphans, every
    /// node lands in the archive feed.
    func test_archive_cascades_terminal_subtree() async throws {
        let root = tmpRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let store = SwiftNativeDeskStore(dataRoot: root)

        let top = try await store.createItem(kind: .plan, project: "na", title: "top")
        let child = try await store.addChild(parentHandle: top.handle, title: "child")
        let grand = try await store.addChild(parentHandle: child.handle, title: "grandchild")
        for h in [grand.handle, child.handle, top.handle] {
            _ = try await store.closeItem(h, outcomeSummary: "done")
        }
        _ = try await store.archiveItem(top.handle)

        let liveAfter = try await store.liveState()
        XCTAssertTrue(liveAfter.items.isEmpty)                          // no orphans left live
        let archived = Set(try await store.archivedRecords().map { $0.handle })
        XCTAssertEqual(archived, [top.handle, child.handle, grand.handle])
    }

    func test_archive_partial_append_failure_repairs_projection_before_rethrow() async throws {
        let root = tmpRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        // Failure 3 occurs after the deepest node's record+canonical op have
        // committed, while the next archive record is being appended.
        let persistence = FailingAppendPersistence(failAt: 3)
        let store = SwiftNativeDeskStore(dataRoot: root, persistence: persistence)

        let top = try await store.createItem(kind: .plan, project: "na", title: "top")
        let child = try await store.addChild(parentHandle: top.handle, title: "child")
        let grand = try await store.addChild(parentHandle: child.handle, title: "grandchild")
        for h in [grand.handle, child.handle, top.handle] {
            _ = try await store.closeItem(h, outcomeSummary: "done")
        }
        await persistence.arm()

        do {
            _ = try await store.archiveItem(top.handle)
            XCTFail("expected injected append failure")
        } catch PersistenceCoreError.ioFailure(let message) {
            XCTAssertEqual(message, "injected append failure")
        }

        let canonical = SwiftNativeDeskStore.compact(try await store.readOpsUnlocked())
        let projectedJSON = await SwiftNativePersistenceCore().readJSON(
            store.statePath,
            defaultValue: .object([:])
        )
        XCTAssertEqual(projectedJSON, canonical.toJSON())
        XCTAssertFalse(canonical.items.contains { $0.handle == grand.handle })
        XCTAssertTrue(canonical.items.contains { $0.handle == child.handle })
        XCTAssertTrue(canonical.items.contains { $0.handle == top.handle })
    }

    /// HIGH: a terminal status reached via set_status (not close_item) still
    /// stamps closedAt → sweepable + countdown; re-opening clears it.
    func test_set_status_terminal_stamps_closedAt_and_is_sweepable() async throws {
        let root = tmpRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let store = SwiftNativeDeskStore(dataRoot: root)

        let it = try await store.createItem(kind: .plan, project: "na", title: "via setStatus")
        _ = try await store.setStatus(it.handle, status: .done)        // terminal via setStatus
        let liveItems = try await store.liveState().items
        let row = try XCTUnwrap(liveItems.first { $0.handle == it.handle })
        XCTAssertNotNil(row.closedAt)

        let eligible = try await store.archiveSweep(now: Date().addingTimeInterval(72 * 3600))
        XCTAssertEqual(eligible, [it.handle])                          // skipped if closedAt were nil

        _ = try await store.setStatus(it.handle, status: .now)         // re-open
        let reopenedItems = try await store.liveState().items
        let reopened = try XCTUnwrap(reopenedItems.first { $0.handle == it.handle })
        XCTAssertNil(reopened.closedAt)
    }

    /// Projection: a lone child the now/next highlight does NOT surface (e.g.
    /// blocked) is LISTED, never hidden; a lone now/next child stays collapsed in
    /// the highlight (no duplicate).
    func test_projection_lists_single_non_highlight_child() {
        let gen = "2026-06-29T17:00:00.000000+00:00"
        let opened = "2026-06-29T16:00:00.000000+00:00"
        func mk(_ alias: String, parent: String? = nil, status: DeskStatus, title: String) -> DeskItem {
            DeskItem(handle: "h_\(alias)", alias: alias, parent: parent, kind: .plan, status: status,
                     project: "na", title: title, openedAt: opened, updatedAt: opened)
        }
        // Single BLOCKED child → no highlight → listed.
        let blocked = DeskProjection.render(DeskState(
            items: [mk("1", status: .now, title: "parent"),
                    mk("1.1", parent: "h_1", status: .blocked, title: "blocked child")], generatedTs: gen))
        XCTAssertTrue(blocked.contains("\n  1.1 blocked blocked child"), blocked)

        // Single NEXT child → collapsed in the highlight, NOT listed separately.
        let collapsed = DeskProjection.render(DeskState(
            items: [mk("2", status: .now, title: "parent2"),
                    mk("2.1", parent: "h_2", status: .next, title: "next child")], generatedTs: gen))
        // Scope to the ITEM region: the trailing `next up:` section legitimately
        // lists the ready child by alias, which is not the duplicate-child-row
        // regression this test guards.
        let collapsedItems = collapsed.components(separatedBy: "\nnext up:")[0]
        XCTAssertFalse(collapsedItems.contains("2.1 next next child"), collapsed)
        XCTAssertTrue(collapsedItems.contains("· next next child"), collapsed)
    }

    // MARK: - Notify evaluator (desk-side push: idempotent, no cognition)

    func test_notify_fires_only_for_active_direct_or_urgent() async throws {
        let root = tmpRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let store = SwiftNativeDeskStore(dataRoot: root)

        let a = try await store.createItem(kind: .watch, project: "na", title: "ping me")
        _ = try await store.setNotify(a.handle, policy: NotifyPolicy(level: .direct))
        let b = try await store.createItem(kind: .watch, project: "na", title: "quiet one") // default quiet
        let c = try await store.createItem(kind: .plan, project: "na", title: "done one")
        _ = try await store.setNotify(c.handle, policy: NotifyPolicy(level: .urgent))
        _ = try await store.closeItem(c.handle, outcomeSummary: "done")

        let state = try await store.liveState()
        let handles = Set(DeskNotifyEvaluator.decisions(state, now: Date()).map { $0.handle })
        XCTAssertTrue(handles.contains(a.handle))    // direct + active -> fires
        XCTAssertFalse(handles.contains(b.handle))   // quiet -> no
        // REBASELINED (desk-delegation-pushes, 2026-08-17): a FRESH close on a
        // direct/urgent item now fires its one completion ping — that was the
        // whole feature ("I'll let you know when it's done" made mechanical).
        // Historical closes staying silent is pinned in DeskDelegationNotifyTests.
        XCTAssertTrue(handles.contains(c.handle))    // urgent + just closed -> completion ping
    }

    func test_notify_idempotent_markNotified_no_refire_and_no_updatedAt_bump() async throws {
        let root = tmpRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let store = SwiftNativeDeskStore(dataRoot: root)

        let it = try await store.createItem(kind: .watch, project: "na", title: "watch me")
        _ = try await store.setNotify(it.handle, policy: NotifyPolicy(level: .urgent))

        let beforeItems = try await store.liveState().items
        let before = try XCTUnwrap(beforeItems.first { $0.handle == it.handle })
        XCTAssertEqual(DeskNotifyEvaluator.decisions(DeskState(items: [before], generatedTs: ""), now: Date()).count, 1)

        // Fire the push: markNotified stamps lastNotifiedAt, must NOT bump updatedAt.
        _ = try await store.markNotified(it.handle)
        let afterItems = try await store.liveState().items
        let after = try XCTUnwrap(afterItems.first { $0.handle == it.handle })
        XCTAssertNotNil(after.notify.lastNotifiedAt)
        XCTAssertEqual(after.updatedAt, before.updatedAt)   // notifying is NOT a content change
        // No re-fire — nothing changed since the ping.
        XCTAssertTrue(DeskNotifyEvaluator.decisions(DeskState(items: [after], generatedTs: ""), now: Date()).isEmpty)
    }

    func test_notify_cooldown_blocks_rapid_refire() {
        let opened = "2026-06-29T16:00:00.000000+00:00"
        let now = Date(timeIntervalSince1970: 1_780_000_000)
        func urgent(updated: String, lastNotified: String?, cooldown: String?) -> DeskItem {
            DeskItem(handle: "h1", alias: "1", kind: .watch, status: .blocked, project: "na", title: "x",
                     notify: NotifyPolicy(level: .urgent, cooldown: cooldown, lastNotifiedAt: lastNotified),
                     openedAt: opened, updatedAt: updated)
        }
        let pingedAt = DeskClock.nowISO(now.addingTimeInterval(-600))          // last ping 10m ago
        let changedAfterPing = DeskClock.nowISO(now.addingTimeInterval(-60))   // changed 1m ago (after the ping)
        let changedBeforePing = DeskClock.nowISO(now.addingTimeInterval(-1200))// changed 20m ago (before the ping)

        func fires(_ item: DeskItem) -> Int {
            DeskNotifyEvaluator.decisions(DeskState(items: [item], generatedTs: ""), now: now).count
        }
        // Changed since ping, but 30m cooldown not elapsed (only 10m since ping) -> no fire.
        XCTAssertEqual(fires(urgent(updated: changedAfterPing, lastNotified: pingedAt, cooldown: "30m")), 0)
        // Changed since ping, 5m cooldown elapsed -> fires.
        XCTAssertEqual(fires(urgent(updated: changedAfterPing, lastNotified: pingedAt, cooldown: "5m")), 1)
        // No change since the ping (changed before it) -> no fire even with a 1m cooldown.
        XCTAssertEqual(fires(urgent(updated: changedBeforePing, lastNotified: pingedAt, cooldown: "1m")), 0)

        let future = DeskNotifyEvaluator.nextMeaningfulDeadline(
            DeskState(items: [urgent(
                updated: changedAfterPing,
                lastNotified: pingedAt,
                cooldown: "30m"
            )], generatedTs: ""),
            after: now
        )
        XCTAssertEqual(try! XCTUnwrap(future).timeIntervalSince(now), 20 * 60, accuracy: 0.01)
        XCTAssertNil(DeskNotifyEvaluator.nextMeaningfulDeadline(
            DeskState(items: [urgent(
                updated: changedBeforePing,
                lastNotified: pingedAt,
                cooldown: "30m"
            )], generatedTs: ""),
            after: now
        ))
    }

    func test_notify_markIfUnchanged_skips_when_changed_since_observed() async throws {
        let root = tmpRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let store = SwiftNativeDeskStore(dataRoot: root)

        let it = try await store.createItem(kind: .watch, project: "na", title: "x")
        _ = try await store.setNotify(it.handle, policy: NotifyPolicy(level: .urgent))
        let items0 = try await store.liveState().items
        let observed = try XCTUnwrap(items0.first { $0.handle == it.handle }).updatedAt

        // A content change lands AFTER we observed -> CAS must SKIP (no stamp),
        // leaving the item eligible so the next tick pings the newer state.
        // No tick-wait needed: DeskClock.nowISO() is strictly monotonic
        // in-process, so appendNote's updatedAt is guaranteed to differ from
        // `observed` even when both land in the same wall-clock millisecond.
        _ = try await store.appendNote(it.handle, text: "changed mid-tick")
        let skipped = try await store.markNotifiedIfUnchanged(it.handle, expectedUpdatedAt: observed)
        XCTAssertFalse(skipped)
        let afterSkipItems = try await store.liveState().items
        let afterSkip = try XCTUnwrap(afterSkipItems.first { $0.handle == it.handle })
        XCTAssertNil(afterSkip.notify.lastNotifiedAt)    // not stamped -> still eligible

        // Stamp against the CURRENT version -> succeeds.
        let stamped = try await store.markNotifiedIfUnchanged(it.handle, expectedUpdatedAt: afterSkip.updatedAt)
        XCTAssertTrue(stamped)
        let afterStampItems = try await store.liveState().items
        let afterStamp = try XCTUnwrap(afterStampItems.first { $0.handle == it.handle })
        XCTAssertNotNil(afterStamp.notify.lastNotifiedAt)
    }

    // MARK: - Clock monotonicity

    // The markNotifiedIfUnchanged CAS compares updatedAt strings, so two
    // mutations stamped in the same millisecond MUST NOT produce equal
    // timestamps. Back-to-back nowISO() calls land in the same millisecond
    // constantly, so this fails deterministically without the monotonic bump.
    func test_deskClock_nowISO_strictly_monotonic() {
        var prev = DeskClock.nowISO()
        for _ in 0..<1000 {
            let next = DeskClock.nowISO()
            XCTAssertGreaterThan(next, prev, "back-to-back nowISO() stamps must never be equal")
            prev = next
        }
    }

    // commitStamp must land strictly past BOTH the process-monotonic state and
    // the newest committed feed ts (the cross-writer / stale-pre-minted-stamp
    // guard), and later plain nowISO() stamps must not fall back behind it.
    func test_deskClock_commitStamp_floors_past_committed_ts() throws {
        // A committed ts a few ms ahead of "now" — as if another process (or a
        // stamp minted before a lock stall) already wrote it to the feed.
        let base = try XCTUnwrap(DeskClock.parseISO(DeskClock.nowISO()))
        let committed = DeskClock.nowISO(base.addingTimeInterval(0.005))
        let stamp = DeskClock.commitStamp(notBefore: committed)
        XCTAssertGreaterThan(stamp, committed)
        XCTAssertGreaterThan(DeskClock.nowISO(), stamp)
    }

    // Bumped stamps must stay byte-compatible with TaskLedgerClock's format
    // (fixed-width, so lexicographic order == chronological order across feeds)
    // and parseable by DeskClock.parseISO.
    func test_deskClock_nowISO_format_stays_ledger_compatible() throws {
        let stamp = DeskClock.nowISO()
        let parsed = try XCTUnwrap(DeskClock.parseISO(stamp))
        XCTAssertEqual(DeskClock.nowISO(parsed), stamp)
        XCTAssertEqual(TaskLedgerClock.nowISO(parsed), stamp)
    }

    // MARK: - Terminal lifecycle: canceled rows are swept and capped

    /// A CANCELED top-level item is sweep-eligible on the same grace clock as a
    /// done one. Pre-fix (`guard item.status == .done`) canceled rows were never
    /// returned, so they sat in live state forever.
    func test_archive_sweep_includes_canceled_items() async throws {
        let root = tmpRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let store = SwiftNativeDeskStore(dataRoot: root)

        let canceled = try await store.createItem(kind: .plan, project: "na", title: "abandoned")
        _ = try await store.setStatus(canceled.handle, status: .canceled)
        let done = try await store.createItem(kind: .plan, project: "na", title: "shipped")
        _ = try await store.closeItem(done.handle, outcomeSummary: "done")
        let open = try await store.createItem(kind: .plan, project: "na", title: "still open")

        // Terminal via setStatus stamps closedAt, so the grace clock applies.
        let rows = try await store.liveState().items
        let row = try XCTUnwrap(rows.first { $0.handle == canceled.handle })
        XCTAssertEqual(row.status, .canceled)
        XCTAssertNotNil(row.closedAt)

        let insideGrace = try await store.archiveSweep(now: Date())
        XCTAssertTrue(insideGrace.isEmpty)
        let eligible = try await store.archiveSweep(now: Date().addingTimeInterval(72 * 3600))
        XCTAssertEqual(Set(eligible), Set([canceled.handle, done.handle]))
        XCTAssertFalse(eligible.contains(open.handle))
    }

    /// A canceled item archives through the same path and records a CANCELED
    /// final status — proving the sweep hands archiveItem work it accepts.
    func test_canceled_item_archives_with_canceled_final_status() async throws {
        let root = tmpRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let store = SwiftNativeDeskStore(dataRoot: root)

        let it = try await store.createItem(kind: .plan, project: "na", title: "abandoned")
        _ = try await store.setStatus(it.handle, status: .canceled)
        let eligible = try await store.archiveSweep(now: Date().addingTimeInterval(72 * 3600))
        XCTAssertEqual(eligible, [it.handle])

        let record = try await store.archiveItem(it.handle)
        XCTAssertEqual(record.finalStatus, .canceled)
        let live = try await store.liveState()
        XCTAssertFalse(live.items.contains { $0.handle == it.handle })
    }

    /// Projection: 25 canceled top-level rows must NOT eat the 25-item cap and
    /// push live work off the desk. Pre-fix the cap counted only `.done`, so the
    /// canceled rows (lowest aliases) filled prefix(25) and the live items
    /// vanished.
    func test_projection_canceled_items_do_not_dominate_top_level_cap() {
        let opened = "2026-07-01T10:00:00.000000+00:00"
        func mk(_ n: Int, status: DeskStatus, title: String, closedAt: String?) -> DeskItem {
            var item = DeskItem(handle: "h\(n)", alias: "\(n)", parent: nil, kind: .plan, status: status,
                                project: "na", title: title, openedAt: opened, updatedAt: opened)
            item.closedAt = closedAt
            return item
        }
        var items: [DeskItem] = []
        for n in 1...25 {
            // Ascending closedAt so the newest-3 are deterministic (23, 24, 25).
            items.append(mk(n, status: .canceled, title: "dead \(n)",
                            closedAt: "2026-07-01T10:00:\(String(format: "%02d", n)).000000+00:00"))
        }
        for n in 26...30 {
            items.append(mk(n, status: .now, title: "live \(n)", closedAt: nil))
        }

        let kept = DeskProjection.cappedTopLevel(DeskState(items: items, generatedTs: opened))
        let keptCanceled = kept.filter { $0.status == .canceled }
        XCTAssertEqual(keptCanceled.count, DeskProjection.doneCap)
        XCTAssertEqual(Set(keptCanceled.map(\.handle)), Set(["h23", "h24", "h25"]))
        // Every live item survives.
        for n in 26...30 {
            XCTAssertTrue(kept.contains { $0.handle == "h\(n)" }, "live item h\(n) fell off the desk")
        }

        let rendered = DeskProjection.render(DeskState(items: items, generatedTs: opened))
        XCTAssertTrue(rendered.contains("live 30"), rendered)
    }

    // MARK: - Per-item history caps

    /// Notes are capped to the newest `notesCap`; the tail readers care about
    /// (`notes.last`) is preserved. Pre-fix the list grew unbounded and the whole
    /// tree was re-serialized on every op.
    func test_notes_are_capped_to_newest_window() async throws {
        let root = tmpRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let store = SwiftNativeDeskStore(dataRoot: root)

        let it = try await store.createItem(kind: .plan, project: "na", title: "chatty")
        let total = SwiftNativeDeskStore.notesCap + 50
        for i in 1...total {
            _ = try await store.appendNote(it.handle, text: "note \(i)")
        }

        let items = try await store.liveState().items
        let row = try XCTUnwrap(items.first { $0.handle == it.handle })
        XCTAssertEqual(row.notes.count, SwiftNativeDeskStore.notesCap)
        XCTAssertEqual(row.notes.last?.text, "note \(total)")
        XCTAssertEqual(row.notes.first?.text, "note \(total - SwiftNativeDeskStore.notesCap + 1)")
        XCTAssertFalse(row.notes.contains { $0.text == "note 1" })
    }

    /// The cap survives a compaction round-trip: the base is written from the
    /// capped fold, so a rebuild from base + tail stays capped (this is the
    /// O(n²) the fix exists to prevent).
    func test_notes_cap_survives_compaction() async throws {
        let root = tmpRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        // Low threshold so compaction certainly fires mid-run and the capped
        // fold is baked into the base, then more notes land in the tail.
        let store = SwiftNativeDeskStore(dataRoot: root, opsCompactionThreshold: 64)

        let it = try await store.createItem(kind: .plan, project: "na", title: "chatty")
        for i in 1...(SwiftNativeDeskStore.notesCap + 25) {
            _ = try await store.appendNote(it.handle, text: "note \(i)")
        }
        for i in 1...25 {
            _ = try await store.appendNote(it.handle, text: "post \(i)")
        }

        let items = try await store.liveState().items
        let row = try XCTUnwrap(items.first { $0.handle == it.handle })
        XCTAssertEqual(row.notes.count, SwiftNativeDeskStore.notesCap)
        XCTAssertEqual(row.notes.last?.text, "post 25")
    }

    /// Refs are capped by IMPORTANCE, not recency: a gh identity ref (priority 0)
    /// must outlive a flood of low-priority note refs, because
    /// GitHubProjectTracking matches and retires desk rows by it.
    func test_refs_cap_evicts_least_important_and_keeps_gh_identity() async throws {
        let root = tmpRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let store = SwiftNativeDeskStore(dataRoot: root)

        let it = try await store.createItem(kind: .gh, project: "na", title: "tracked pr")
        _ = try await store.addRef(it.handle, ref: DeskRef(kind: .ghPr(
            repo: "o/r", number: 42, title: "pr", status: "open", checks: nil)))
        for i in 1...(SwiftNativeDeskStore.refsCap + 40) {
            _ = try await store.addRef(it.handle, ref: DeskRef(kind: .note(text: "n\(i)")))
        }

        let items = try await store.liveState().items
        let row = try XCTUnwrap(items.first { $0.handle == it.handle })
        XCTAssertEqual(row.refs.count, SwiftNativeDeskStore.refsCap)
        XCTAssertTrue(row.refs.contains { ref in
            if case .ghPr(_, let number, _, _, _) = ref.kind { return number == 42 }
            return false
        }, "gh identity ref was evicted — tracker rows would orphan")
        // Among equal-priority note refs the OLDEST go first.
        XCTAssertFalse(row.refs.contains { ref in
            if case .note(let text) = ref.kind { return text == "n1" }
            return false
        })
    }

    // gpt-5.5 wave-2 review: the ORIGINAL tracking ref must survive even a
    // flood of newer EQUAL-priority gh refs (the case the note-only flood
    // above could not catch — equal priority evicts oldest-first, which is
    // the tracking identity). Tracking refs are never eviction victims.
    func test_refs_cap_protects_gh_identity_under_equal_priority_flood() async throws {
        let root = tmpRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let store = SwiftNativeDeskStore(dataRoot: root)

        let it = try await store.createItem(kind: .gh, project: "na", title: "tracked pr")
        // The tracking identity, added at creation (oldest gh_pr).
        _ = try await store.addRef(it.handle, ref: DeskRef(kind: .ghPr(
            repo: "o/r", number: 42, title: "pr", status: "open", checks: nil)))
        // A flood of newer, same-priority gh_pr refs on the same row.
        for n in 100...(100 + SwiftNativeDeskStore.refsCap + 40) {
            _ = try await store.addRef(it.handle, ref: DeskRef(kind: .ghPr(
                repo: "o/r", number: n, title: nil, status: "open", checks: nil)))
        }

        let items = try await store.liveState().items
        let row = try XCTUnwrap(items.first { $0.handle == it.handle })
        XCTAssertTrue(row.refs.contains { ref in
            if case .ghPr(_, let number, _, _, _) = ref.kind { return number == 42 }
            return false
        }, "the original gh tracking ref was evicted under an equal-priority gh flood — the tracker row would orphan")
    }

    // MARK: - Sequencing: blocked-on edges, defer, auto-unblock, next-action
    //
    // The load-bearing property is that blockedness is DERIVED: closing a
    // blocker unblocks its dependents with NO op written for the dependent.

    /// Both sequencing ops survive append → rebuild-from-ops, and the rebuild
    /// equals the in-memory fold.
    func test_sequencing_ops_roundtrip_through_rebuild() async throws {
        let root = tmpRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let store = SwiftNativeDeskStore(dataRoot: root)

        let a = try await store.createItem(kind: .plan, project: "na", title: "A")
        let b = try await store.createItem(kind: .plan, project: "na", title: "B")
        _ = try await store.setBlockedOn(b.handle, blockers: [a.handle])
        _ = try await store.setDeferUntil(b.handle, until: "2099-01-01")

        let folded = try await store.liveState()
        let row = try XCTUnwrap(folded.items.first { $0.handle == b.handle })
        XCTAssertEqual(row.blockedOn, [a.handle])
        XCTAssertEqual(row.deferUntil, "2099-01-01")

        // Rebuild from the raw ops feed (no base yet) must equal the fold.
        let rebuilt = SwiftNativeDeskStore.compact(try await store.readOpsUnlocked())
        XCTAssertEqual(rebuilt.items, folded.items)
    }

    /// THE FEATURE: A blocks B. Closing A makes B ready with NO op written for B.
    func test_auto_unblock_cascade_needs_no_op_on_the_dependent() async throws {
        let root = tmpRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let store = SwiftNativeDeskStore(dataRoot: root)

        let a = try await store.createItem(kind: .plan, project: "na", title: "A")
        let b = try await store.createItem(kind: .plan, project: "na", title: "B")
        _ = try await store.setStatus(b.handle, status: .now)
        _ = try await store.setBlockedOn(b.handle, blockers: [a.handle])

        let before = try await store.liveState()
        let planBefore = DeskSequencing.compute(before)
        XCTAssertEqual(planBefore.byHandle[b.handle]?.effectiveBlockers, [a.handle])
        XCTAssertEqual(planBefore.byHandle[b.handle]?.isReady, false)
        XCTAssertFalse(planBefore.nextUp.contains(b.handle), "a blocked item must never be next up")

        let opsForBBefore = try await store.readOpsUnlocked().filter { $0.handle == b.handle }.count

        // Close the BLOCKER. Nothing touches B.
        _ = try await store.closeItem(a.handle, outcomeSummary: "done A")

        let after = try await store.liveState()
        let planAfter = DeskSequencing.compute(after)
        XCTAssertEqual(planAfter.byHandle[b.handle]?.effectiveBlockers, [],
                       "a terminal blocker must not block — this IS the cascade")
        XCTAssertEqual(planAfter.byHandle[b.handle]?.isReady, true)
        XCTAssertTrue(planAfter.nextUp.contains(b.handle))

        // The stored edge is untouched, and NO op was written for B.
        let rowB = try XCTUnwrap(after.items.first { $0.handle == b.handle })
        XCTAssertEqual(rowB.blockedOn, [a.handle])
        let opsForBAfter = try await store.readOpsUnlocked().filter { $0.handle == b.handle }.count
        XCTAssertEqual(opsForBAfter, opsForBBefore,
                       "unblocking must be DERIVED — no op may be written for the dependent")
    }

    /// A→B→C: closing A leaves C blocked by B; closing B frees C.
    func test_cascade_depth_unblocks_one_level_at_a_time() async throws {
        let root = tmpRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let store = SwiftNativeDeskStore(dataRoot: root)

        let a = try await store.createItem(kind: .plan, project: "na", title: "A")
        let b = try await store.createItem(kind: .plan, project: "na", title: "B")
        let c = try await store.createItem(kind: .plan, project: "na", title: "C")
        _ = try await store.setBlockedOn(b.handle, blockers: [a.handle])
        _ = try await store.setBlockedOn(c.handle, blockers: [b.handle])

        _ = try await store.closeItem(a.handle, outcomeSummary: "A done")
        var plan = DeskSequencing.compute(try await store.liveState())
        XCTAssertEqual(plan.byHandle[b.handle]?.isReady, true)
        XCTAssertEqual(plan.byHandle[c.handle]?.effectiveBlockers, [b.handle])
        XCTAssertEqual(plan.byHandle[c.handle]?.isReady, false)

        _ = try await store.closeItem(b.handle, outcomeSummary: "B done")
        plan = DeskSequencing.compute(try await store.liveState())
        XCTAssertEqual(plan.byHandle[c.handle]?.effectiveBlockers, [])
        XCTAssertEqual(plan.byHandle[c.handle]?.isReady, true)
    }

    /// An ARCHIVED blocker is gone from live state entirely — it must not block.
    func test_archived_blocker_does_not_block() async throws {
        let root = tmpRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let store = SwiftNativeDeskStore(dataRoot: root)

        let a = try await store.createItem(kind: .plan, project: "na", title: "A")
        let b = try await store.createItem(kind: .plan, project: "na", title: "B")
        _ = try await store.setBlockedOn(b.handle, blockers: [a.handle])
        _ = try await store.closeItem(a.handle, outcomeSummary: "A done")
        _ = try await store.archiveItem(a.handle)

        let state = try await store.liveState()
        XCTAssertFalse(state.items.contains { $0.handle == a.handle })
        let plan = DeskSequencing.compute(state)
        XCTAssertEqual(plan.byHandle[b.handle]?.effectiveBlockers, [])
        XCTAssertEqual(plan.byHandle[b.handle]?.isReady, true)
    }

    /// CLEARS must round-trip. The prior shipped bug in this file was an
    /// empty-string clear silently dropped by the omit-empty encoder.
    func test_sequencing_clears_survive_rebuild_from_ops() async throws {
        let root = tmpRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let store = SwiftNativeDeskStore(dataRoot: root)

        let a = try await store.createItem(kind: .plan, project: "na", title: "A")
        let b = try await store.createItem(kind: .plan, project: "na", title: "B")
        _ = try await store.setBlockedOn(b.handle, blockers: [a.handle])
        _ = try await store.setDeferUntil(b.handle, until: "2099-01-01")

        _ = try await store.setBlockedOn(b.handle, blockers: [])
        _ = try await store.setDeferUntil(b.handle, until: nil)

        // The clear ops themselves must be on the wire (not omitted).
        let raw = try await SwiftNativePersistenceCore().readJSONL(store.opsPath)
        let clearBlocked = raw.compactMap { DeskOp.fromJSON($0) }
            .last { if case .setBlockedOn = $0.body { return true } else { return false } }
        XCTAssertEqual(clearBlocked?.body, .setBlockedOn(handles: []))
        let clearDefer = raw.compactMap { DeskOp.fromJSON($0) }
            .last { if case .setDeferUntil = $0.body { return true } else { return false } }
        XCTAssertEqual(clearDefer?.body, .setDeferUntil(until: nil))

        // And the rebuild-from-ops sees the clears.
        let rebuilt = SwiftNativeDeskStore.compact(try await store.readOpsUnlocked())
        let row = try XCTUnwrap(rebuilt.items.first { $0.handle == b.handle })
        XCTAssertEqual(row.blockedOn, [])
        XCTAssertNil(row.deferUntil)
    }

    /// Write-time refusals: unknown blocker, self-block, cycle, bad defer date.
    func test_blocked_on_write_time_refusals() async throws {
        let root = tmpRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let store = SwiftNativeDeskStore(dataRoot: root)

        let a = try await store.createItem(kind: .plan, project: "na", title: "A")
        let b = try await store.createItem(kind: .plan, project: "na", title: "B")

        // Unknown blocker.
        do {
            _ = try await store.setBlockedOn(a.handle, blockers: ["desk_nope"])
            XCTFail("expected blockedOnUnknown")
        } catch let e as DeskError {
            guard case .blockedOnUnknown = e else { return XCTFail("wrong error \(e)") }
        }
        // Self block.
        do {
            _ = try await store.setBlockedOn(a.handle, blockers: [a.handle])
            XCTFail("expected blockedOnSelf")
        } catch let e as DeskError {
            guard case .blockedOnSelf = e else { return XCTFail("wrong error \(e)") }
        }
        // Cycle: A blocked-on B, then B blocked-on A.
        _ = try await store.setBlockedOn(a.handle, blockers: [b.handle])
        do {
            _ = try await store.setBlockedOn(b.handle, blockers: [a.handle])
            XCTFail("expected blockedOnCycle")
        } catch let e as DeskError {
            guard case .blockedOnCycle = e else { return XCTFail("wrong error \(e)") }
        }
        // The refused edge left NOTHING behind.
        let liveAfterRefusal = try await store.liveState()
        let rowB = try XCTUnwrap(liveAfterRefusal.items.first { $0.handle == b.handle })
        XCTAssertEqual(rowB.blockedOn, [])

        // Unparseable defer.
        do {
            _ = try await store.setDeferUntil(b.handle, until: "next tuesday-ish")
            XCTFail("expected deferUntilUnparseable")
        } catch let e as DeskError {
            guard case .deferUntilUnparseable = e else { return XCTFail("wrong error \(e)") }
        }
    }

    /// A cycle written by a HAND-AUTHORED feed (bypassing the write gate) must
    /// not hang compute, and both nodes are flagged. If this regresses the test
    /// hangs rather than fails — which is exactly the failure mode being guarded
    /// (a hang here freezes every desk_read).
    func test_hand_authored_cycle_does_not_hang_and_is_flagged() async throws {
        let root = tmpRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let store = SwiftNativeDeskStore(dataRoot: root)

        let a = try await store.createItem(kind: .plan, project: "na", title: "A")
        let b = try await store.createItem(kind: .plan, project: "na", title: "B")
        // Straight to the feed — no validation, the way another process or a
        // legacy/hand-edited file could leave it.
        try await appendLegacyOp(DeskOp(handle: a.handle, body: .setBlockedOn(handles: [b.handle])), to: store)
        try await appendLegacyOp(DeskOp(handle: b.handle, body: .setBlockedOn(handles: [a.handle])), to: store)

        let state = try await store.liveState()
        let plan = DeskSequencing.compute(state)
        XCTAssertEqual(plan.byHandle[a.handle]?.blockedByCycle, true)
        XCTAssertEqual(plan.byHandle[b.handle]?.blockedByCycle, true)
        XCTAssertEqual(plan.byHandle[a.handle]?.isReady, false)
        XCTAssertEqual(plan.byHandle[b.handle]?.isReady, false)
        XCTAssertTrue(plan.nextUp.isEmpty)

        // And it renders honestly rather than silently vanishing.
        XCTAssertTrue(DeskProjection.render(state, plan: plan).contains("⚠ blocked-on cycle"))
    }

    /// blockedOn / deferUntil survive a snapshot+tail compaction.
    func test_sequencing_fields_survive_compaction() async throws {
        let root = tmpRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let store = SwiftNativeDeskStore(dataRoot: root, opsCompactionThreshold: 6)

        let a = try await store.createItem(kind: .plan, project: "na", title: "A")
        let b = try await store.createItem(kind: .plan, project: "na", title: "B")
        _ = try await store.setBlockedOn(b.handle, blockers: [a.handle])
        _ = try await store.setDeferUntil(b.handle, until: "2099-03-04")
        // Push past the threshold so the base snapshot is written.
        for i in 0..<8 { _ = try await store.appendNote(a.handle, text: "n\(i)") }

        XCTAssertTrue(FileManager.default.fileExists(atPath: store.basePath.path),
                      "expected a compaction base to have been written")
        let state = try await store.liveState()
        let row = try XCTUnwrap(state.items.first { $0.handle == b.handle })
        XCTAssertEqual(row.blockedOn, [a.handle], "a blocker edge was lost across compaction")
        XCTAssertEqual(row.deferUntil, "2099-03-04")
    }

    /// A base row with a malformed `blockedOn` FAILS the strict decode rather
    /// than silently dropping the edges. In the base this snapshot is the only
    /// copy — a dropped edge would vanish the dependency forever.
    func test_malformed_blocked_on_fails_strict_decode() throws {
        let opened = "2026-07-01T10:00:00.000000+00:00"
        func row(_ blockedOn: JSONValue) -> JSONValue {
            .object([
                "handle": .string("desk_x"), "alias": .string("1"),
                "kind": .string("plan"), "status": .string("todo"),
                "project": .string("na"), "title": .string("t"),
                "openedAt": .string(opened), "updatedAt": .string(opened),
                "pinned": .bool(false),
                "blockedOn": blockedOn,
            ])
        }
        // Not an array at all.
        XCTAssertNil(DeskItem.fromJSON(row(.string("desk_a")), strictCollections: true))
        // An array with a non-string element.
        XCTAssertNil(DeskItem.fromJSON(row(.array([.string("desk_a"), .int(7)])), strictCollections: true))
        // Tolerant mode still decodes (forward-compat readers), dropping the junk.
        let tolerant = try XCTUnwrap(DeskItem.fromJSON(row(.array([.string("desk_a"), .int(7)]))))
        XCTAssertEqual(tolerant.blockedOn, ["desk_a"])
        // A well-formed row decodes strictly.
        let strict = try XCTUnwrap(DeskItem.fromJSON(row(.array([.string("desk_a")])), strictCollections: true))
        XCTAssertEqual(strict.blockedOn, ["desk_a"])
        // And a whole state carrying a malformed row fails loud.
        XCTAssertNil(DeskState.fromJSON(.object([
            "generatedTs": .string(opened),
            "items": .array([row(.string("nope"))]),
        ])))
    }

    /// A pre-wave row (no blockedOn / deferUntil) serializes with NO new keys —
    /// byte-identical to before the wave, so the compaction base's shape gate
    /// still passes on an existing snapshot.
    func test_item_without_sequencing_fields_emits_no_new_keys() throws {
        let opened = "2026-07-01T10:00:00.000000+00:00"
        let item = DeskItem(handle: "desk_x", alias: "1", kind: .plan, status: .todo,
                            project: "na", title: "t", openedAt: opened, updatedAt: opened)
        guard case .object(let obj) = item.toJSON() else { return XCTFail("not an object") }
        XCTAssertNil(obj["blockedOn"])
        XCTAssertNil(obj["deferUntil"])
        // Round-trip is stable (the base gate re-encodes and compares shape).
        let back = try XCTUnwrap(DeskItem.fromJSON(item.toJSON(), strictCollections: true))
        XCTAssertEqual(back.toJSON(), item.toJSON())
        XCTAssertEqual(back, item)
    }

    // MARK: - Sequencing: ordering, rollup, defer rendering

    private func seqItem(
        _ alias: String, parent: String? = nil, status: DeskStatus = .todo,
        title: String? = nil, openedAt: String = "2026-07-01T10:00:00.000000+00:00",
        blockedOn: [String] = [], deferUntil: String? = nil,
        cadence: Cadence = Cadence()
    ) -> DeskItem {
        DeskItem(handle: "h_\(alias)", alias: alias, parent: parent, kind: .plan, status: status,
                 project: "na", title: title ?? "t\(alias)", cadence: cadence,
                 openedAt: openedAt, updatedAt: openedAt,
                 blockedOn: blockedOn, deferUntil: deferUntil)
    }

    /// nextUp respects status rank, then openedAt; a blocked item never appears.
    func test_next_up_ordering_and_excludes_blocked() {
        let early = "2026-07-01T09:00:00.000000+00:00"
        let late = "2026-07-01T18:00:00.000000+00:00"
        let items = [
            seqItem("1", status: .todo, openedAt: late),
            seqItem("2", status: .now, openedAt: late),
            seqItem("3", status: .next, openedAt: late),
            seqItem("4", status: .next, openedAt: early),   // same rank, opened EARLIER → first
            seqItem("5", status: .now, blockedOn: ["h_2"]), // highest rank but BLOCKED
            seqItem("6", status: .done, openedAt: early),   // terminal → never ready
        ]
        let plan = DeskSequencing.compute(DeskState(items: items, generatedTs: early))
        XCTAssertEqual(plan.nextUp, ["h_2", "h_4", "h_3", "h_1"])
        XCTAssertEqual(plan.byHandle["h_5"]?.isReady, false)
        XCTAssertEqual(plan.byHandle["h_6"]?.isReady, false)
    }

    /// nextUp is capped at 5.
    func test_next_up_capped_at_five() {
        let opened = "2026-07-01T10:00:00.000000+00:00"
        let items = (1...9).map { seqItem("\($0)", status: .todo, openedAt: opened) }
        let plan = DeskSequencing.compute(DeskState(items: items, generatedTs: opened))
        XCTAssertEqual(plan.nextUp.count, DeskSequencing.nextUpCap)
    }

    /// A deferred item renders `deferred until` and is NOT flagged stale even
    /// when its cadence window has long elapsed (Agent's #3).
    func test_deferred_item_shows_defer_and_suppresses_stale() {
        let now = Date(timeIntervalSince1970: 1_780_000_000)
        let gen = DeskClock.nowISO(now)
        // Stale by any measure: refreshed 42m ago against a 30m window.
        let staleCadence = Cadence(mode: .on_ask,
                                   lastRefreshAt: DeskClock.nowISO(now.addingTimeInterval(-2520)),
                                   staleAfter: "30m")
        let parked = seqItem("1", title: "parked on purpose", deferUntil: "2099-05-06", cadence: staleCadence)
        let notParked = seqItem("2", title: "genuinely neglected", cadence: staleCadence)
        let state = DeskState(items: [parked, notParked], generatedTs: gen)
        let plan = DeskSequencing.compute(state, now: now)

        XCTAssertEqual(plan.byHandle["h_1"]?.isDeferred, true)
        XCTAssertEqual(plan.byHandle["h_1"]?.isReady, false)
        XCTAssertFalse(plan.nextUp.contains("h_1"))
        XCTAssertNil(DeskProjection.staleSegment(parked, now: now),
                     "a deliberately parked item must never be flagged stale")
        XCTAssertNotNil(DeskProjection.staleSegment(notParked, now: now))

        let rendered = DeskProjection.render(state, now: now, plan: plan)
        let parkedLine = try? XCTUnwrap(rendered.split(separator: "\n").first { $0.contains("parked on purpose") })
        XCTAssertTrue(parkedLine?.contains("deferred until 2099-05-06") == true, rendered)
        XCTAssertFalse(parkedLine?.contains("stale:") == true, rendered)
        // The un-parked sibling still gets its staleness marker.
        XCTAssertTrue(rendered.contains("stale:42m"), rendered)

        // An unparseable defer is NOT a park — never silently shelve an item.
        let junk = seqItem("3", deferUntil: "soon-ish")
        XCTAssertFalse(DeskSequencing.isDeferred(junk, now: now))
        // A PAST defer has expired.
        let expired = seqItem("4", deferUntil: "2020-01-01")
        XCTAssertFalse(DeskSequencing.isDeferred(expired, now: now))
    }

    /// The parent rollup counts the WHOLE subtree, not just direct children.
    func test_parent_rollup_counts_whole_subtree() {
        let opened = "2026-07-01T10:00:00.000000+00:00"
        let items = [
            seqItem("1", status: .now),
            seqItem("1.1", parent: "h_1", status: .done),
            seqItem("1.2", parent: "h_1", status: .todo),
            seqItem("1.2.1", parent: "h_1.2", status: .done),
            seqItem("1.2.2", parent: "h_1.2", status: .canceled),   // terminal counts as done
            seqItem("1.2.3", parent: "h_1.2", status: .todo),
        ]
        let state = DeskState(items: items, generatedTs: opened)
        let plan = DeskSequencing.compute(state, now: Date(timeIntervalSince1970: 1_780_000_000))
        // 5 descendants, 3 terminal — direct-children-only would say 1/2.
        XCTAssertEqual(plan.byHandle["h_1"]?.doneCount, 3)
        XCTAssertEqual(plan.byHandle["h_1"]?.totalCount, 5)
        // Self excluded at every level.
        XCTAssertEqual(plan.byHandle["h_1.2"]?.doneCount, 2)
        XCTAssertEqual(plan.byHandle["h_1.2"]?.totalCount, 3)
        XCTAssertEqual(plan.byHandle["h_1.1"]?.totalCount, 0)

        let rendered = DeskProjection.render(state, now: Date(timeIntervalSince1970: 1_780_000_000), plan: plan)
        XCTAssertTrue(rendered.contains("3/5 closed"), rendered)
    }

    /// A child of a blocked (or deferred) parent is not actionable.
    func test_child_of_blocked_parent_is_not_ready() {
        let opened = "2026-07-01T10:00:00.000000+00:00"
        let items = [
            seqItem("1", status: .todo),                                   // the blocker
            seqItem("2", status: .todo, blockedOn: ["h_1"]),               // blocked parent
            seqItem("2.1", parent: "h_2", status: .now),                   // its child
            seqItem("3", status: .todo, deferUntil: "2099-01-01"),         // parked parent
            seqItem("3.1", parent: "h_3", status: .now),                   // its child
        ]
        let plan = DeskSequencing.compute(DeskState(items: items, generatedTs: opened),
                                          now: Date(timeIntervalSince1970: 1_780_000_000))
        XCTAssertEqual(plan.byHandle["h_2.1"]?.isReady, false, "a child of a blocked parent is not actionable")
        XCTAssertEqual(plan.byHandle["h_3.1"]?.isReady, false, "a child of a parked parent is not actionable")
        // The child has no blockers of its OWN — the obstruction is inherited.
        XCTAssertEqual(plan.byHandle["h_2.1"]?.effectiveBlockers, [])
        XCTAssertEqual(plan.nextUp, ["h_1"])
    }

    /// blocked-on renders ALIASES (never handles), capped at 3 + `+N`.
    func test_blocked_on_renders_aliases_capped() {
        let opened = "2026-07-01T10:00:00.000000+00:00"
        var items = (1...5).map { seqItem("\($0)", status: .todo) }
        items.append(seqItem("9", status: .todo, blockedOn: ["h_1", "h_2", "h_3", "h_4", "h_5"]))
        let state = DeskState(items: items, generatedTs: opened)
        let rendered = DeskProjection.render(state, now: Date(timeIntervalSince1970: 1_780_000_000))
        XCTAssertTrue(rendered.contains("blocked-on 1,2,3+2"), rendered)
        XCTAssertFalse(rendered.contains("desk_"), "the projection must never render a raw handle")
        XCTAssertFalse(rendered.contains("h_1 "), "the projection must never render a raw handle")
    }

    // MARK: - Wave 5: drift surfacing in the projection

    private func driftItem(notes: [DeskNote], status: DeskStatus = .todo) -> DeskState {
        let opened = "2026-07-01T10:00:00.000000+00:00"
        var item = seqItem("1", status: status)
        item.notes = notes
        return DeskState(items: [item], generatedTs: opened)
    }

    private func note(_ offsetHour: Int, _ text: String) -> DeskNote {
        DeskNote(ts: "2026-07-0\(offsetHour)T10:00:00.000000+00:00", text: text)
    }

    private var renderNow: Date { Date(timeIntervalSince1970: 1_780_000_000) }

    /// A drift flag reaches the compact line AND the note line even on an item
    /// whose status is plain `todo` — drift is the desk contradicting itself, and
    /// the old blocked/flag-only note gate would have hidden exactly that.
    func test_drift_note_surfaces_on_a_non_blocked_item() {
        let drift = DeskDrift(handle: "h_1", kind: .untrackedButShipped, refKeys: ["gh:o/r#7"],
                              detail: "d", observedAt: "2026-07-02T10:00:00.000000+00:00")
        let rendered = DeskProjection.render(driftItem(notes: [note(2, drift.noteText)]), now: renderNow)
        XCTAssertTrue(rendered.contains("⚑ drift:untracked_but_shipped"), rendered)
        XCTAssertTrue(rendered.contains("  note: ⚑ drift["), rendered)
    }

    /// The flag is DERIVED from the tail of the note trail, so anything newer
    /// clears it. This is the property that makes drift un-stickable: there is no
    /// stored bit to leave on after reality moves back.
    func test_drift_segment_clears_when_a_newer_note_lands() {
        let drift = DeskDrift(handle: "h_1", kind: .blockedButShipped, refKeys: ["gh:o/r#7"],
                              detail: "d", observedAt: "2026-07-02T10:00:00.000000+00:00")
        let state = driftItem(notes: [note(2, drift.noteText), note(3, "User: reopened it, still working")])
        let rendered = DeskProjection.render(state, now: renderNow)
        XCTAssertFalse(rendered.contains("⚑ drift"), rendered)
        XCTAssertFalse(rendered.contains("  note:"), "a todo item's ordinary note is not high-signal")
    }

    /// `hasPrefix`, not `contains`: a note that merely QUOTES the marker cannot
    /// forge a flag. Same spoofing rule the applier's dedupe uses.
    func test_note_quoting_the_marker_does_not_forge_a_drift_flag() {
        let state = driftItem(notes: [note(2, "asked her why the ⚑ drift flag fired last week")])
        let rendered = DeskProjection.render(state, now: renderNow)
        XCTAssertFalse(rendered.contains("⚑ drift:"), rendered)
    }

    /// A receipt is not a drift — an auto-resolved item stays quiet on the line.
    func test_receipt_note_is_not_rendered_as_drift() {
        let resolve = DeskAutoResolve(handle: "h_1", expectedUpdatedAt: "x", refKeys: ["gh:o/r#7"],
                                      evidence: ["gh:o/r#7: merged — e"],
                                      observedAt: "2026-07-02T10:00:00.000000+00:00",
                                      materialFingerprint: "f")
        let rendered = DeskProjection.render(driftItem(notes: [note(2, resolve.receiptNote)]), now: renderNow)
        XCTAssertFalse(rendered.contains("⚑ drift"), rendered)
    }

    func test_owner_cadence_attempt_is_typed_idempotent_and_terminal() async throws {
        let root = tmpRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let store = SwiftNativeDeskStore(dataRoot: root)
        let item = try await store.createItem(kind: .watch, project: "ops", title: "daily digest")
        _ = try await store.setCadence(item.handle, cadence: Cadence(mode: .daily))
        let day = DeskClock.dayStamp(Date())
        let first = try await store.reserveWorkAttempt(
            item.handle, lane: .ownerCadence, day: day, slot: "b1")
        let replay = try await store.reserveWorkAttempt(
            item.handle, lane: .ownerCadence, day: day, slot: "b1")
        XCTAssertEqual(first, replay)
        let reservedState = try await store.liveState()
        XCTAssertEqual(reservedState.items.first { $0.handle == item.handle }?.workAttempts.count, 1)

        _ = try await store.completeWorkAttempt(item.handle, attemptId: first, receipt: "[completed] digest")
        let secondSettlement = try await store.completeWorkAttempt(
            item.handle, attemptId: first, receipt: "[completed] digest")
        XCTAssertNil(secondSettlement)
        let settledState = try await store.liveState()
        let settled = try XCTUnwrap(settledState.items.first { $0.handle == item.handle })
        XCTAssertEqual(settled.workAttempts.first?.lane, .ownerCadence)
        XCTAssertNotNil(settled.workAttempts.first?.completedAt)
        XCTAssertNotNil(settled.cadence.nextRefreshAt)
        XCTAssertEqual(settled.notes.filter { $0.text == "[completed] digest" }.count, 1)
    }
}
