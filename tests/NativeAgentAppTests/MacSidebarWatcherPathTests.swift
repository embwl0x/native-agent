import Foundation
import PersistenceCore
import Testing
@testable import NativeAgentApp

// Ledger fence app.mac — rows `loop.sidebarActivityBadgeWatcher` and
// `loop.chatSessionIndexWatcher`.
//
// ViewFileRefreshTaskTests already covers the debounce/coalescing PRIMITIVE.
// What nothing covered is the arming: which PATHS the two ContentView watchers
// hand it. A path that stops existing — or a data-root relocation — makes the
// watcher arm on something nothing writes, and the failure is completely
// silent: the badge freezes at its last value and looks healthy, and the whole
// Mac projection of chat sessions stops updating while the last-known list
// keeps rendering confidently.
//
// So this file does two things. It proves BEHAVIOURALLY, against a seeded
// clone root, that a write to each watched path wakes the refresh (a path the
// event source cannot observe fails here), and it proves the path EXPRESSIONS
// in ContentView are the same ones the canonical writers construct.

private actor RefreshProbe {
    private var count = 0
    func record() { count += 1 }
    func value() -> Int { count }
}

private func awaitCount(_ probe: RefreshProbe, atLeast target: Int, deadline: TimeInterval = 5) async -> Int {
    let end = Date().addingTimeInterval(deadline)
    while Date() < end {
        let value = await probe.value()
        if value >= target { return value }
        try? await Task.sleep(for: .milliseconds(25))
    }
    return await probe.value()
}

/// The four paths ContentView arms the sidebar-badge watcher with, rebuilt
/// against an arbitrary root exactly as ContentView builds them against
/// `PersistenceCore.defaultDataRoot()`.
private func sidebarBadgeWatchedPaths(root: URL) -> [URL] {
    let memoryDatabase = root
        .appendingPathComponent("memory", isDirectory: true)
        .appendingPathComponent("memory.sqlite")
    return [
        root.appendingPathComponent("workflows/approvals/requests.json"),
        root.appendingPathComponent("notifications/inbox.jsonl"),
        memoryDatabase,
        URL(fileURLWithPath: memoryDatabase.path + "-wal"),
    ]
}

private func chatSessionIndexPath(root: URL) -> URL {
    root.appendingPathComponent("chat", isDirectory: true)
        .appendingPathComponent("sessions.json")
}

// MARK: - behavioural: every watched path is one the event source can observe

@MainActor
@Test("a write to any watched sidebar path wakes the badge refresh")
func sidebarBadgeWatcher_everyArmedPathIsObservable() async throws {
    let root = FileManager.default.temporaryDirectory
        .appendingPathComponent("na-sidebar-watch-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(
        at: root.appendingPathComponent("workflows/approvals", isDirectory: true),
        withIntermediateDirectories: true
    )
    try FileManager.default.createDirectory(
        at: root.appendingPathComponent("notifications", isDirectory: true),
        withIntermediateDirectories: true
    )
    try FileManager.default.createDirectory(
        at: root.appendingPathComponent("memory", isDirectory: true),
        withIntermediateDirectories: true
    )
    defer { try? FileManager.default.removeItem(at: root) }

    let paths = sidebarBadgeWatchedPaths(root: root)
    #expect(paths.count == 4)

    // One watcher per path so a single dead path cannot hide behind a live
    // sibling — that is exactly the failure mode being tested.
    for path in paths {
        let probe = RefreshProbe()
        let task = Task { @MainActor in
            await ViewFileRefreshTask.run(paths: [path], debounceDelay: .milliseconds(30)) {
                await probe.record()
            }
        }
        defer { task.cancel() }

        // The initial read always fires once.
        #expect(await awaitCount(probe, atLeast: 1) >= 1, "no initial read for \(path.lastPathComponent)")

        try Data("{\"seeded\":true}".utf8).write(to: path, options: .atomic)
        let after = await awaitCount(probe, atLeast: 2)
        #expect(after >= 2, "a write to \(path.lastPathComponent) did not wake the badge refresh")

        task.cancel()
        _ = await task.value
    }
}

@MainActor
@Test("one write to the session index refreshes once; a burst coalesces")
func chatSessionIndexWatcher_refreshesOnceAndCoalescesBursts() async throws {
    let root = FileManager.default.temporaryDirectory
        .appendingPathComponent("na-session-watch-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(
        at: root.appendingPathComponent("chat", isDirectory: true),
        withIntermediateDirectories: true
    )
    defer { try? FileManager.default.removeItem(at: root) }

    let path = chatSessionIndexPath(root: root)
    let probe = RefreshProbe()
    // The debounce ContentView actually uses.
    let task = Task { @MainActor in
        await ViewFileRefreshTask.run(paths: [path], debounceDelay: .milliseconds(150)) {
            await probe.record()
        }
    }
    defer { task.cancel() }

    #expect(await awaitCount(probe, atLeast: 1) >= 1)

    try Data("[]".utf8).write(to: path, options: .atomic)
    #expect(await awaitCount(probe, atLeast: 2) >= 2, "a sessions.json write did not refresh the index")

    // A burst of writes must produce at least one refresh and strictly fewer
    // than one per write — the trailing-edge debounce is what keeps a busy
    // chat turn from re-reading the whole index a dozen times.
    let before = await probe.value()
    for i in 0..<12 {
        try Data("[{\"id\":\"s\(i)\"}]".utf8).write(to: path, options: .atomic)
    }
    let coalesced = await awaitCount(probe, atLeast: before + 1)
    try await Task.sleep(for: .milliseconds(400))
    let settled = await probe.value()
    #expect(settled >= before + 1)
    #expect(settled - before < 12, "a 12-write burst produced \(settled - before) refreshes — coalescing is gone")
    #expect(coalesced <= settled)

    task.cancel()
    _ = await task.value
}

// MARK: - the arming expressions in ContentView

@Test("both watchers arm on the canonical data root, with the documented paths")
func contentViewWatchers_armOnTheCanonicalWriterPaths() throws {
    let source = try AppSourceScraping.appSource("ContentView.swift")

    // A relocated data root is the failure that makes both watchers point at
    // nothing. Both must resolve the root through PersistenceCore rather than
    // capturing a URL from somewhere else.
    #expect(AppSourceScraping.occurrences(of: "PersistenceCore.defaultDataRoot()", in: source) >= 2)

    for relative in [
        "\"workflows/approvals/requests.json\"",
        "\"notifications/inbox.jsonl\"",
        "\"memory.sqlite\"",
        "memoryDatabase.path + \"-wal\"",
        "\"sessions.json\"",
    ] {
        #expect(source.contains(relative), "watched path \(relative) is no longer armed")
    }

    // The badge watcher covers the SQLite journal as well as the database:
    // WAL-mode writes land in `-wal` and may not touch the main file for a
    // long time, so watching only `memory.sqlite` freezes the memory badge.
    #expect(source.contains("URL(fileURLWithPath: memoryDatabase.path + \"-wal\")"))

    // Both are scene-phase gated — an inactive window must not keep polling.
    #expect(AppSourceScraping.occurrences(of: "guard scenePhase == .active else { return }", in: source) >= 2)

    // And the session-index watcher keeps its 150ms debounce (the value the
    // behavioural test above exercises).
    #expect(source.contains("debounceDelay: .milliseconds(150)"))

    // Cross-check against a live writer of the same index: NativeClient's
    // createChatSession builds the same relative path from the same root.
    let writer = try AppSourceScraping.appSource("NativeClient+ProviderTelegramSessions.swift")
    #expect(writer.contains("let sessionsPath = dataRoot\n            .appendingPathComponent(\"chat\", isDirectory: true)\n            .appendingPathComponent(\"sessions.json\")"))
    #expect(chatSessionIndexPath(root: URL(fileURLWithPath: "/tmp/x")).path == "/tmp/x/chat/sessions.json")

    // …and a live writer of the approvals + inbox files the badge reads.
    let scan = try AppSourceScraping.appSource("NativeAgentScheduledProactiveScan.swift")
    #expect(scan.contains("dataRoot.appendingPathComponent(\"notifications/inbox.jsonl\")"))
    #expect(scan.contains("dataRoot.appendingPathComponent(\"workflows/approvals/requests.json\")"))
}
