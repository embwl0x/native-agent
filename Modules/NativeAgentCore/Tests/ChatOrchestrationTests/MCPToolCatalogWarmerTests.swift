import Foundation
import Testing
@testable import ChatOrchestration
import NativeAgentCore
import MCPDispatcher

// gpt-5.5 NEEDS_FIX (2026-08-02): the MCP live tools cache was WRITTEN but never
// REFRESHED in production. `MCPToolBridge.listMCPTools` — the sole producer of
// `mcp__<server>__<tool>` descriptors for the model — reads
// `mcp/cache/tools.json` and nothing else, and the only callers of
// `refreshAllToolsCaches` / `listToolsLive` were manual UI actions. A configured
// stdio server with an empty cache therefore advertised ZERO tools forever: no
// error, no retry, capability simply absent.
//
// The trigger chosen is the TOOL-CATALOG BUILD (`modelVisibleMCPTools()`), the
// production chat path. These tests pin all three properties it has to have:
// it fires, it never blocks the caller, and it is bounded.

private actor SweepSpy {
    private(set) var roots: [URL] = []
    private var gate: CheckedContinuation<Void, Never>?
    private let blocks: Bool

    init(blocks: Bool = false) { self.blocks = blocks }

    func run(_ root: URL) async {
        roots.append(root)
        if blocks {
            // Never resumed — stands in for a wedged MCP server.
            await withCheckedContinuation { (c: CheckedContinuation<Void, Never>) in
                gate = c
            }
        }
    }

    var count: Int { roots.count }
}

/// 30s, not 5: the full 5k-test suite runs these detached sweeps against a
/// saturated cooperative pool, and a starved-scheduler timeout is a flake, not
/// a finding. Every condition here settles in milliseconds when unloaded.
private func waitUntil(
    _ label: String,
    timeout: TimeInterval = 30,
    _ condition: @Sendable () async -> Bool
) async {
    let deadline = Date().addingTimeInterval(timeout)
    while Date() < deadline {
        if await condition() { return }
        try? await Task.sleep(nanoseconds: 10_000_000)
    }
    Issue.record("timed out waiting for: \(label)")
}

@Test func warmer_kicksOnceThenSuppressesUntilTheRearmWindowElapses() async {
    let spy = SweepSpy()
    let now = Mutex(Date(timeIntervalSince1970: 1_000_000))
    let warmer = MCPToolCatalogWarmer(
        sweep: { root in await spy.run(root) },
        clock: { now.get() },
        rearmInterval: 300,
        sweepDeadline: 60   // irrelevant here; the fake sweep returns instantly
    )
    let root = URL(fileURLWithPath: "/tmp/na-warmer-test")

    #expect(await warmer.kickIfDue(dataRoot: root) == true)
    await waitUntil("first sweep finishes") { await warmer._testState().finished == 1 }

    // Inside the re-arm window: a per-turn catalog build must not fan out into
    // a subprocess storm.
    #expect(await warmer.kickIfDue(dataRoot: root) == false)
    #expect(await warmer.kickIfDue(dataRoot: root) == false)
    #expect(await spy.count == 1)

    // Past it: the cache is refreshed again so an MCP server added after launch
    // becomes visible without a relaunch.
    now.set(Date(timeIntervalSince1970: 1_000_301))
    #expect(await warmer.kickIfDue(dataRoot: root) == true)
    await waitUntil("second sweep finishes") { await warmer._testState().finished == 2 }
    #expect(await spy.roots == [root, root])
}

@Test func warmer_neverBlocksTheCallerAndIsDeadlineBounded() async {
    // A wedged server: the sweep never returns on its own.
    let spy = SweepSpy(blocks: true)
    let warmer = MCPToolCatalogWarmer(
        sweep: { root in await spy.run(root) },
        rearmInterval: 0,
        sweepDeadline: 0.3
    )
    let root = URL(fileURLWithPath: "/tmp/na-warmer-wedged")

    let started = Date()
    #expect(await warmer.kickIfDue(dataRoot: root) == true)
    // The kick itself returns immediately — a dead MCP server can never sit in
    // front of a chat turn's tool-catalog build. The sweep NEVER returns, so an
    // implementation that awaited it would hang here forever; 1s is a generous
    // margin that still fails hard on the blocking shape.
    #expect(Date().timeIntervalSince(started) < 1.0)
    // A concurrent kick while the sweep is in flight is refused, not queued.
    #expect(await warmer.kickIfDue(dataRoot: root) == false)

    // …and the sweep is abandoned at the deadline rather than pinning the slot
    // forever, so a later kick can still refresh the cache.
    await waitUntil("wedged sweep hits its deadline") {
        await warmer._testState().inFlight == false
    }
    #expect(await spy.count == 1)
    #expect(await warmer.kickIfDue(dataRoot: root) == true)
}

/// The finding itself: there must be a PRODUCTION caller. Building the
/// model-visible MCP tool catalog — what every chat turn does — has to arm the
/// refresh. Pre-fix this assertion fails: nothing on any non-UI path ever
/// touched the warmer.
@Test func toolCatalogBuild_armsTheProductionRefresh() async throws {
    let root = FileManager.default.temporaryDirectory
        .appendingPathComponent("na-warm-trigger-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: root) }

    let dispatcher = SwiftToolDispatcher(dataRoot: root)

    // No servers.json under this root, so the live sweep is a fast no-op — the
    // claim under test is that the trigger EXISTS, not what the sweep found.
    #expect(dispatcher.modelVisibleMCPTools().isEmpty)

    // Asserted as "armed at all", not "armed by THIS call": the process-wide
    // warmer has a 5-minute re-arm window, so an earlier suite that built a
    // tool catalog legitimately owns the stamp. Pre-fix the stamp is nil no
    // matter how many catalogs were built, which is exactly the bug.
    await waitUntil("a tool-catalog build arms the production refresh") {
        await MCPToolCatalogWarmer.shared._testState().lastStartedAt != nil
    }
}

/// Tiny lock box so the fake clock is Sendable without pulling in a test-only
/// dependency.
private final class Mutex<T>: @unchecked Sendable {
    private let lock = NSLock()
    private var value: T
    init(_ value: T) { self.value = value }
    func get() -> T { lock.lock(); defer { lock.unlock() }; return value }
    func set(_ new: T) { lock.lock(); value = new; lock.unlock() }
}
