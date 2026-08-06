import Foundation
import Testing
@testable import PersistenceCore
@testable import NativeAgentApp

// Sweep R4 W5 — the desk interaction tier.
//
// Two classes of proof here:
//
//   1. PURE — selection order, arrow movement, reveal keys, fuzzy match, the
//      palette grammar, defer presets, ref affordances and the nag panel model.
//      All of it is data shaping, so none of it needs SwiftUI.
//
//   2. SEAM — the part that actually matters: every desk action routes to the
//      SAME `impl_desk_*` the chat tool calls. Proven twice, on purpose:
//      a spy pins the tool NAME + argument shape without touching disk, and a
//      LIVE run against a temp dataRoot proves the dispatch really lands in the
//      impl (the store changes) rather than in a stub that returns "ok".

// MARK: - fixtures

private func item(
    _ alias: String,
    title: String = "t",
    project: String = "p",
    kind: DeskKind = .plan,
    status: DeskStatus = .now,
    origin: DeskOrigin = .owner,
    pursuit: Pursuit? = nil,
    refs: [DeskRef] = []
) -> DeskItem {
    DeskItem(
        handle: "desk_\(alias)",
        alias: alias,
        kind: kind,
        status: status,
        project: project,
        title: title,
        refs: refs,
        openedAt: "2026-08-01T00:00:00.000000+00:00",
        updatedAt: "2026-08-01T00:00:00.000000+00:00",
        origin: origin,
        pursuit: pursuit)
}

private func utcCalendar() -> Calendar {
    var cal = Calendar(identifier: .gregorian)
    cal.timeZone = TimeZone(identifier: "UTC")!
    return cal
}

// MARK: - selection order

@Test("selection order walks the sections in render order and skips collapsed children")
func deskSelectionOrderMatchesRender() {
    let items = [
        item("1", title: "root one"),
        item("1.1", title: "child one"),
        item("2", title: "root two"),
        item("w1", title: "a watch", kind: .watch, status: .watch),
        item("9", title: "done thing", status: .done),
    ]
    // Collapsed: the child is NOT on screen, so it may not take the caret.
    let collapsed = DeskBoardLayout.selectableHandles(items: items, expandedRoots: [])
    #expect(collapsed == ["desk_w1", "desk_1", "desk_2"])

    // Expanded: the child slots in directly under its root, exactly as rendered.
    let expanded = DeskBoardLayout.selectableHandles(items: items, expandedRoots: ["board:1"])
    #expect(expanded == ["desk_w1", "desk_1", "desk_1.1", "desk_2"])

    // Terminal rows never enter the order — "Recently finished" stays glance-only.
    #expect(!expanded.contains("desk_9"))
}

@Test("pursuits lead the order and GitHub rows only appear when their roll-up is open")
func deskSelectionOrderPursuitsAndGitHub() {
    let pursuit = Pursuit(
        why: "w", evidence: PromotionDossier(citations: []),
        doneLooksLike: "d", abandonCondition: "a")
    let items = [
        item("1", title: "board row"),
        item("3", title: "gh row", project: "acme", kind: .gh),
        item("5", title: "her pursuit", kind: .project, origin: .agent, pursuit: pursuit),
    ]
    #expect(DeskBoardLayout.selectableHandles(items: items, expandedRoots: [])
            == ["desk_5", "desk_1"])
    #expect(DeskBoardLayout.selectableHandles(items: items, expandedRoots: ["gh:acme"])
            == ["desk_5", "desk_1", "desk_3"])
}

@Test("reveal keys open exactly the family a buried row lives in")
func deskRevealKeys() {
    let items = [item("1"), item("1.1"), item("1.2"), item("2"),
                 item("g", project: "acme", kind: .gh)]
    #expect(DeskBoardLayout.revealKeys(for: "desk_1.1", items: items) == ["board:1"])
    // A family ROOT is already visible — nothing to open.
    #expect(DeskBoardLayout.revealKeys(for: "desk_1", items: items) == [])
    #expect(DeskBoardLayout.revealKeys(for: "desk_g", items: items) == ["gh:acme"])
    #expect(DeskBoardLayout.revealKeys(for: "desk_nope", items: items) == [])
}

// MARK: - selection movement

@Test("arrows clamp at both ends and enter the list from the edge they came from")
func deskSelectionMovement() {
    let order = ["a", "b", "c"]
    #expect(DeskSelection.move(from: nil, by: 1, in: order) == "a")
    #expect(DeskSelection.move(from: nil, by: -1, in: order) == "c")
    #expect(DeskSelection.move(from: "a", by: 1, in: order) == "b")
    // Clamp, never wrap: holding ↓ comes to rest at the bottom.
    #expect(DeskSelection.move(from: "c", by: 1, in: order) == "c")
    #expect(DeskSelection.move(from: "a", by: -1, in: order) == "a")
    // An unknown current selection re-enters from the edge rather than vanishing.
    #expect(DeskSelection.move(from: "zzz", by: 1, in: order) == "a")
    #expect(DeskSelection.move(from: "a", by: 1, in: []) == nil)
}

@Test("a selection whose row disappeared is dropped, not left pointing at nothing")
func deskSelectionReconcile() {
    #expect(DeskSelection.reconcile("b", order: ["a", "b"]) == "b")
    #expect(DeskSelection.reconcile("b", order: ["a"]) == nil)
    #expect(DeskSelection.reconcile(nil, order: ["a"]) == nil)
}

// MARK: - palette grammar

@Test("the palette grammar separates a verb from its item query")
func deskPaletteParse() {
    #expect(DeskPaletteQuery.parse("") == DeskPaletteQuery(verb: nil, query: ""))
    #expect(DeskPaletteQuery.parse("auth bug") == DeskPaletteQuery(verb: nil, query: "auth bug"))
    #expect(DeskPaletteQuery.parse("close auth bug")
            == DeskPaletteQuery(verb: .close, query: "auth bug"))
    #expect(DeskPaletteQuery.parse("DEFER release")
            == DeskPaletteQuery(verb: .deferItem, query: "release"))
    // A bare verb means "the row already selected", not "the first row".
    #expect(DeskPaletteQuery.parse("note") == DeskPaletteQuery(verb: .note, query: ""))
    #expect(DeskPaletteQuery.parse("  note   ") == DeskPaletteQuery(verb: .note, query: ""))
    // A partial verb is still a search — "cl" must not arm a close.
    #expect(DeskPaletteQuery.parse("cl") == DeskPaletteQuery(verb: nil, query: "cl"))
    #expect(DeskPaletteQuery.parse("closer") == DeskPaletteQuery(verb: nil, query: "closer"))
}

@Test("fuzzy match ranks prefixes above substrings above subsequences")
func deskFuzzyRanking() {
    #expect(DeskFuzzy.rank(query: "desk", candidate: "desk") == 0)
    #expect(DeskFuzzy.rank(query: "des", candidate: "desk view") == 1)
    #expect(DeskFuzzy.rank(query: "view", candidate: "desk view") == 2)
    #expect(DeskFuzzy.rank(query: "sk vi", candidate: "desk view") == 3)
    #expect(DeskFuzzy.rank(query: "dkv", candidate: "desk view") == 4)
    #expect(DeskFuzzy.rank(query: "zzz", candidate: "desk view") == nil)
    // Empty query matches everything equally — the palette opens on the board.
    #expect(DeskFuzzy.rank(query: "", candidate: "anything") == 0)
}

@Test("fuzzy filter returns a total order so rows can't swap under an unchanged query")
func deskFuzzyFilterStable() {
    let rows = [
        DeskPaletteRow(handle: "h1", alias: "1", title: "release cut", project: "p", status: "now"),
        DeskPaletteRow(handle: "h2", alias: "2", title: "release", project: "p", status: "now"),
        DeskPaletteRow(handle: "h3", alias: "3", title: "unrelated", project: "p", status: "now"),
    ]
    let out = DeskFuzzy.filter(rows, query: "release")
    // Exact-ish (shorter) title wins the tie at the same rank; the non-match drops.
    #expect(out.map(\.handle) == ["h2", "h1"])
    #expect(DeskFuzzy.filter(rows, query: "release").map(\.handle)
            == DeskFuzzy.filter(rows, query: "release").map(\.handle))
    #expect(DeskFuzzy.filter(rows, query: "", limit: 2).count == 2)
}

// MARK: - defer presets

@Test("defer presets emit the yyyy-MM-dd day desk_defer expects")
func deskDeferPresetDays() {
    let cal = utcCalendar()
    let now = cal.date(from: DateComponents(year: 2026, month: 8, day: 6, hour: 23, minute: 59))!
    #expect(DeskDeferPreset.tomorrow.day(from: now, calendar: cal) == "2026-08-07")
    #expect(DeskDeferPreset.nextWeek.day(from: now, calendar: cal) == "2026-08-13")
    // Month boundary — the arithmetic is the calendar's, not a 86400 guess.
    let eom = cal.date(from: DateComponents(year: 2026, month: 8, day: 31, hour: 12))!
    #expect(DeskDeferPreset.tomorrow.day(from: eom, calendar: cal) == "2026-09-01")
}

// MARK: - ref affordances

@Test("refs with a URL open; bare refs copy — a ref click is never a no-op")
func deskRefAffordances() {
    let pr = DeskRefAffordance.action(for: DeskRef(kind: .ghPr(
        repo: "acme/app", number: 12, title: "fix", status: nil, checks: nil)))
    #expect(pr == .open(url: "https://github.com/acme/app/pull/12", label: "fix"))

    let url = DeskRefAffordance.action(for: DeskRef(kind: .url(url: "https://x.dev", title: nil)))
    #expect(url.opensExternally)

    let file = DeskRefAffordance.action(for: DeskRef(kind: .file(
        path: "Sources/A.swift", line: 42, label: nil)))
    #expect(file == .copy(text: "Sources/A.swift:42", label: "Sources/A.swift:42"))

    // A commit with a repo can be opened; without one it can only be copied.
    let bareCommit = DeskRefAffordance.action(for: DeskRef(kind: .commit(
        sha: "abcdef1234", repo: nil, label: nil, status: nil)))
    #expect(!bareCommit.opensExternally)
    let repoCommit = DeskRefAffordance.action(for: DeskRef(kind: .commit(
        sha: "abcdef1234", repo: "acme/app", label: nil, status: nil)))
    #expect(repoCommit.opensExternally)
}

// MARK: - action → tool mapping (spy seam)

private actor DeskToolSpy: DeskToolInvoking {
    private(set) var calls: [(tool: String, input: [String: JSONValue])] = []
    private let reply: JSONValue

    init(reply: JSONValue = .object(["status": .string("ok"), "confirmation": .string("done")])) {
        self.reply = reply
    }

    func run(tool: String, input: [String: JSONValue]) async throws -> JSONValue {
        calls.append((tool, input))
        return reply
    }

    func recorded() -> [(tool: String, input: [String: JSONValue])] { calls }
}

@Test("close / defer / note route to the desk_* tools the chat lane calls, with the chat lane's arguments")
func deskQuickActionToolMapping() async throws {
    // Close: `outcome_summary` is REQUIRED by impl_desk_close (it refuses an
    // empty one), so the one-keystroke close must carry a real default.
    let close = DeskQuickAction.close(handle: "desk_1", outcome: DeskQuickAction.deskCloseOutcome)
    #expect(close.tool == "desk_close")
    #expect(close.input["handle"] == .string("desk_1"))
    #expect(close.input["outcome_summary"] == .string(DeskQuickAction.deskCloseOutcome))

    let park = DeskQuickAction.defer_(handle: "desk_1", until: "2026-08-07")
    #expect(park.tool == "desk_defer")
    #expect(park.input["until"] == .string("2026-08-07"))
    // An EMPTY `until` is impl_desk_defer's documented "clear the park".
    #expect(DeskQuickAction.defer_(handle: "desk_1", until: nil).input["until"] == .string(""))

    let note = DeskQuickAction.note(handle: "desk_1", text: "hello")
    #expect(note.tool == "desk_note")
    #expect(note.input["text"] == .string("hello"))

    // And the runner actually calls that tool with that input.
    let spy = DeskToolSpy()
    _ = await DeskActionRunner.perform(close, via: spy)
    _ = await DeskActionRunner.perform(park, via: spy)
    _ = await DeskActionRunner.perform(note, via: spy)
    let calls = await spy.recorded()
    #expect(calls.map(\.tool) == ["desk_close", "desk_defer", "desk_note"])
}

@Test("every nag control routes to desk_nag_control with deterministic params")
func deskNagActionToolMapping() {
    #expect(DeskQuickAction.nagGlobal(on: true).tool == "desk_nag_control")
    #expect(DeskQuickAction.nagGlobal(on: true).input["action"] == .string("enable"))
    #expect(DeskQuickAction.nagGlobal(on: false).input["action"] == .string("disable"))
    #expect(DeskQuickAction.nagGlobal(on: true).input["scope_kind"] == .string("global"))

    let lane = DeskQuickAction.nagProject(project: "NativeAgent", on: true)
    #expect(lane.input["scope_kind"] == .string("project"))
    #expect(lane.input["scope_id"] == .string("NativeAgent"))

    let one = DeskQuickAction.nagItem(handle: "desk_1", on: false)
    #expect(one.input["scope_kind"] == .string("item"))
    #expect(one.input["scope_id"] == .string("desk_1"))

    #expect(DeskQuickAction.nagMute(until: "2026-08-09").input["until"] == .string("2026-08-09"))
    // No `until` at all = the tool's indefinite mute; an empty string would be
    // a different (refused) thing.
    #expect(DeskQuickAction.nagMute(until: nil).input["until"] == nil)
    #expect(DeskQuickAction.nagUnmute.input["action"] == .string("unmute"))
}

@Test("a refusal is surfaced as a refusal, never rendered as success")
func deskActionResultReader() {
    let ok = DeskActionResultReader.read(
        .object(["status": .string("ok"), "confirmation": .string("closed 2 done title")]),
        fallback: "Closing")
    #expect(ok == DeskActionOutcome(ok: true, message: "closed 2 done title"))

    let refused = DeskActionResultReader.read(
        .object(["status": .string("refused"), "reason": .string("cannot defer: cycle")]),
        fallback: "Deferring")
    #expect(refused.ok == false)
    #expect(refused.message == "cannot defer: cycle")

    let failed = DeskActionResultReader.read(
        .object(["status": .string("failed"), "reason": .string("not_loaded")]),
        fallback: "Closing")
    #expect(failed.ok == false)

    // An unrecognised shape is NOT optimistically read as success.
    #expect(DeskActionResultReader.read(.string("?"), fallback: "Closing").ok == false)
    #expect(DeskActionResultReader.read(.object([:]), fallback: "Closing").ok == false)
}

// MARK: - nag panel model

@Test("nag lanes mirror the config's scope decision, and the summary never claims silent pressure is live")
func deskNagPanelModelLanes() {
    let items = [
        item("1", project: "alpha"),
        item("2", project: "alpha"),
        item("3", project: "beta"),
        item("4", project: "gamma", status: .done),
    ]
    var config = DeskNagConfig(enabled: true)
    config = config.settingScope(kind: .project, id: "alpha", enabled: true)

    let lanes = DeskNagPanelModel.lanes(items: items, config: config)
    // Terminal-only projects contribute no lane; a project with no scope entry
    // is OFF, matching DeskNagConfig.scopeEnabled.
    #expect(lanes.map(\.project) == ["alpha", "beta"])
    #expect(lanes[0].enabled == true)
    #expect(lanes[0].itemCount == 2)
    #expect(lanes[1].enabled == false)

    #expect(DeskNagPanelModel.summary(config, lanes: lanes, now: Date())
            == "Nagging is ON for 1 lane.")

    // The state that pings nothing must SAY it pings nothing.
    let globalOff = DeskNagConfig(enabled: false, scopes: config.scopes)
    let offLanes = DeskNagPanelModel.lanes(items: items, config: globalOff)
    #expect(DeskNagPanelModel.summary(globalOff, lanes: offLanes, now: Date())
            .contains("armed but silent"))

    let muted = config.muted(until: nil)
    #expect(DeskNagPanelModel.summary(muted, lanes: lanes, now: Date())
            .hasPrefix("Muted indefinitely"))
}

@Test("snooze options map to the days the mute tool accepts")
func deskNagSnoozeOptions() {
    let cal = utcCalendar()
    let now = cal.date(from: DateComponents(year: 2026, month: 8, day: 6, hour: 9))!
    let options = DeskNagPanelModel.snoozeOptions(from: now, calendar: cal)
    #expect(options.map(\.until) == ["2026-08-07", "2026-08-13", nil])
}

// MARK: - LIVE seam: the same impl, proven by the store changing

/// Everything below runs the REAL router against a temp dataRoot. A spy proves
/// which tool name a button sends; only this proves the dispatch actually
/// reaches `impl_desk_*` — that the seam is wired, not merely named.
private func withTempDeskRoot<T>(_ body: (URL) async throws -> T) async throws -> T {
    let root = URL(fileURLWithPath: NSTemporaryDirectory())
        .appendingPathComponent("desk-w5-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: root) }
    return try await body(root)
}

@Test("desk Close lands in impl_desk_close — the live store shows the item closed")
func deskCloseRoutesToTheRealImpl() async throws {
    try await withTempDeskRoot { root in
        let store = SwiftNativeDeskStore(dataRoot: root)
        let created = try await store.createItem(
            kind: .plan, project: "p", title: "close me", parent: nil, summary: nil)

        let outcome = await DeskActionRunner.perform(
            .close(handle: created.handle, outcome: DeskQuickAction.deskCloseOutcome),
            via: DeskToolDispatchRouter(dataRoot: root))
        #expect(outcome.ok, "close should land, got: \(outcome.message)")

        let state = try await store.liveState()
        let after = state.items.first { $0.handle == created.handle }
        #expect(after?.status == .done)
    }
}

@Test("desk Defer lands in impl_desk_defer — the live store shows the park, and clearing removes it")
func deskDeferRoutesToTheRealImpl() async throws {
    try await withTempDeskRoot { root in
        let store = SwiftNativeDeskStore(dataRoot: root)
        let created = try await store.createItem(
            kind: .plan, project: "p", title: "park me", parent: nil, summary: nil)
        let router = DeskToolDispatchRouter(dataRoot: root)

        let parked = await DeskActionRunner.perform(
            .defer_(handle: created.handle, until: "2026-12-24"), via: router)
        #expect(parked.ok, "defer should land, got: \(parked.message)")
        #expect(try await store.liveState().items
            .first { $0.handle == created.handle }?.deferUntil == "2026-12-24")

        let cleared = await DeskActionRunner.perform(
            .defer_(handle: created.handle, until: nil), via: router)
        #expect(cleared.ok, "clearing the park should land, got: \(cleared.message)")
        #expect(try await store.liveState().items
            .first { $0.handle == created.handle }?.deferUntil == nil)
    }
}

@Test("desk Note lands in impl_desk_note — the note is in the live store's note list")
func deskNoteRoutesToTheRealImpl() async throws {
    try await withTempDeskRoot { root in
        let store = SwiftNativeDeskStore(dataRoot: root)
        let created = try await store.createItem(
            kind: .plan, project: "p", title: "note me", parent: nil, summary: nil)

        let outcome = await DeskActionRunner.perform(
            .note(handle: created.handle, text: "from the desk"),
            via: DeskToolDispatchRouter(dataRoot: root))
        #expect(outcome.ok, "note should land, got: \(outcome.message)")

        let after = try await store.liveState().items.first { $0.handle == created.handle }
        #expect(after?.notes.last?.text == "from the desk")
    }
}

@Test("the nags panel writes through impl_desk_nag_control — the same config file the tool owns")
func deskNagPanelRoutesToTheRealImpl() async throws {
    try await withTempDeskRoot { root in
        let configStore = DeskNagConfigStore(dataRoot: root)
        #expect(await configStore.load().enabled == false)
        let router = DeskToolDispatchRouter(dataRoot: root)

        let on = await DeskActionRunner.perform(.nagGlobal(on: true), via: router)
        #expect(on.ok, "enabling should land, got: \(on.message)")
        #expect(await configStore.load().enabled == true)

        let lane = await DeskActionRunner.perform(
            .nagProject(project: "alpha", on: true), via: router)
        #expect(lane.ok, "lane toggle should land, got: \(lane.message)")
        let scoped = await configStore.load()
        #expect(scoped.scopes.contains { $0.kind == .project && $0.id == "alpha" && $0.enabled })

        let muted = await DeskActionRunner.perform(.nagMute(until: nil), via: router)
        #expect(muted.ok, "mute should land, got: \(muted.message)")
        #expect(await configStore.load().mutedUntil == DeskNagConfig.indefiniteMuteSentinel)

        // Unmute clears the mute AND opens a new attention window — the
        // behaviour that makes "muted never means blind" true.
        let before = await configStore.load().windowId
        let unmuted = await DeskActionRunner.perform(.nagUnmute, via: router)
        #expect(unmuted.ok, "unmute should land, got: \(unmuted.message)")
        let after = await configStore.load()
        #expect(after.mutedUntil == nil)
        #expect(after.windowId > before)
    }
}

@Test("a bad park date comes back as the tool's honest refusal, not a silent success")
func deskDeferBadDateSurfacesRefusal() async throws {
    try await withTempDeskRoot { root in
        let store = SwiftNativeDeskStore(dataRoot: root)
        let created = try await store.createItem(
            kind: .plan, project: "p", title: "x", parent: nil, summary: nil)
        let outcome = await DeskActionRunner.perform(
            .defer_(handle: created.handle, until: "not-a-date"),
            via: DeskToolDispatchRouter(dataRoot: root))
        #expect(outcome.ok == false)
        #expect(try await store.liveState().items
            .first { $0.handle == created.handle }?.deferUntil == nil)
    }
}
