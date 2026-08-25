import Foundation
import Testing
@testable import PersistenceCore

// Ledger rows: cli.deskSweep, cli.deskSweep.retireTrackerGh,
//              cli.deskSweep.ghReport
//
// These are boundary evaluations, not source-shape checks.  Each one seeds
// through the real Desk owner, invokes the separately-built DeskSweepCLI in a
// subprocess, and then reopens the same root through the real owner.  In
// particular, the negative cases assert that a missing or non-settled
// GitHub-tracking record cannot turn into an irreversible Desk close.

private struct DeskSweepRun: Sendable {
    let exitCode: Int32
    let stdout: String
    let stderr: String
}

private final class DeskSweepTestBundleAnchor {}

private func deskSweepProduct() throws -> URL {
    // SwiftPM's Swift Testing runner makes Bundle.main the toolchain's
    // swiftpm-testing-helper, not this package's test bundle. Anchor on a type
    // emitted by this target so this stays tied to the exact products directory
    // that built the test, rather than searching .build for a stale artifact or
    // a different target triple.
    let product = Bundle(for: DeskSweepTestBundleAnchor.self).bundleURL
        .deletingLastPathComponent()
        .appendingPathComponent("DeskSweepCLI", isDirectory: false)
    if FileManager.default.isExecutableFile(atPath: product.path) { return product }
    throw NSError(domain: "DeskSweepCLIW8BehaviorTests", code: 1, userInfo: [
        NSLocalizedDescriptionKey: "DeskSweepCLI is not beside this test bundle: \(product.path)",
    ])
}

private func runDeskSweep(
    _ executable: URL,
    _ arguments: [String],
    environment additions: [String: String] = [:],
    timeout: TimeInterval = 30
) throws -> DeskSweepRun {
    let process = Process()
    process.executableURL = executable
    process.arguments = arguments
    var environment = ProcessInfo.processInfo.environment
    // The CLI's explicit --data-root must be its only state root.  Removing
    // this guards against an operator shell leaking its live root into a test.
    environment.removeValue(forKey: "NATIVE_AGENT_DATA_ROOT")
    for (key, value) in additions { environment[key] = value }
    process.environment = environment

    let outPipe = Pipe()
    let errPipe = Pipe()
    process.standardOutput = outPipe
    process.standardError = errPipe
    try process.run()

    let lock = NSLock()
    var stdout = Data()
    var stderr = Data()
    let readers = DispatchGroup()
    for (pipe, isStandardOut) in [(outPipe, true), (errPipe, false)] {
        readers.enter()
        let reader = Thread {
            let bytes = pipe.fileHandleForReading.readDataToEndOfFile()
            lock.lock()
            if isStandardOut { stdout = bytes } else { stderr = bytes }
            lock.unlock()
            readers.leave()
        }
        reader.stackSize = 512 * 1024
        reader.start()
    }

    let deadline = Date().addingTimeInterval(timeout)
    while process.isRunning, Date() < deadline {
        Thread.sleep(forTimeInterval: 0.02)
    }
    if process.isRunning {
        process.terminate()
        Thread.sleep(forTimeInterval: 0.5)
        if process.isRunning { kill(process.processIdentifier, SIGKILL) }
    }
    process.waitUntilExit()
    _ = readers.wait(timeout: .now() + 10)

    lock.lock()
    defer { lock.unlock() }
    return DeskSweepRun(
        exitCode: process.terminationStatus,
        stdout: String(decoding: stdout, as: UTF8.self),
        stderr: String(decoding: stderr, as: UTF8.self)
    )
}

private func deskSweepRoot(_ label: String) throws -> URL {
    let root = FileManager.default.temporaryDirectory
        .appendingPathComponent("desk-sweep-w8-\(label)-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    return root
}

private func deskItem(
    _ store: SwiftNativeDeskStore,
    kind: DeskKind,
    title: String,
    refreshSources: [String] = []
) async throws -> DeskItem {
    let item = try await store.createItem(kind: kind, project: "eval", title: title)
    if !refreshSources.isEmpty {
        _ = try await store.setCadence(
            item.handle,
            cadence: Cadence(mode: .event, refreshSources: refreshSources)
        )
    }
    return try #require(await store.liveState().items.first(where: { $0.handle == item.handle }))
}

private func requireItem(_ handle: String, in store: SwiftNativeDeskStore) async throws -> DeskItem {
    try #require(await store.liveState().items.first(where: { $0.handle == handle }))
}

private func validPursuit(_ suffix: Int) -> Pursuit {
    Pursuit(
        why: "This keeps recurring and needs a bounded answer.",
        evidence: PromotionDossier(citations: [
            .standingView(id: "view-\(suffix)"),
            .feltSalience(dates: ["2026-08-01", "2026-08-02"]),
            .traceFriction(count: 3, window: "7d"),
        ]),
        doneLooksLike: "A concrete answer exists.",
        abandonCondition: "Two sessions find no new evidence."
    )
}

private func githubObservation(
    number: Int,
    version: String,
    signals: Set<GitHubCommandActionSignal> = [],
    open: Bool = true,
    merged: Bool = false,
    decision: GitHubCommandBlocker? = nil,
    waiting: GitHubCommandWaitingKind = .review
) -> GitHubCommandObservation {
    GitHubCommandObservation(
        repository: "example/widgets",
        number: number,
        kind: .pullRequest,
        title: "state \(number)",
        isOpen: open,
        isMerged: merged,
        observedVersion: "observed-\(version)",
        actionableEventVersion: signals.isEmpty ? nil : version,
        signals: signals,
        headSHA: "head-\(version)",
        humanDecision: decision,
        waitingKind: waiting,
        isStale: false,
        finalReceipt: open ? nil : "example/widgets #\(number) settled"
    )
}

private func dispatchWorkingItem(
    _ store: GitHubCommandStore,
    item: GitHubCommandItem
) async throws -> GitHubCommandDispatchReceipt {
    let intent = try #require(try await store.prepareDispatch(itemId: item.itemId))
    let receipt = GitHubCommandDispatchReceipt(
        eventKey: intent.eventKey,
        dispatchId: intent.dispatchId,
        messageId: intent.dispatchId,
        queuedAt: DeskClock.nowISO()
    )
    _ = try await store.recordDispatchSuccess(itemId: item.itemId, receipt: receipt)
    return receipt
}

private func waitForFile(_ url: URL, timeout: TimeInterval = 5) throws {
    let deadline = Date().addingTimeInterval(timeout)
    while !FileManager.default.fileExists(atPath: url.path), Date() < deadline {
        Thread.sleep(forTimeInterval: 0.01)
    }
    guard FileManager.default.fileExists(atPath: url.path) else {
        throw NSError(domain: "DeskSweepCLIW8BehaviorTests", code: 2, userInfo: [
            NSLocalizedDescriptionKey: "CLI did not reach its planned-CAS barrier at \(url.path)",
        ])
    }
}

private func printedPlan(_ stdout: String, verb: String) -> [String] {
    stdout.split(whereSeparator: { $0.isNewline })
        .map(String.init)
        .filter { $0.hasPrefix(verb + " ") }
        .map {
            String($0.dropFirst(verb.count + 1))
                .trimmingCharacters(in: .whitespaces)
        }
}

@Suite("DeskSweep CLI Wave 8 behavior")
struct DeskSweepCLIW8BehaviorTests {
    @Test("retire-tracker-gh plans and closes only active GitHub-cadenced GH items")
    func retireTrackerGhHasExactSelectionAndDryRunParity() async throws {
        let root = try deskSweepRoot("retire")
        defer { try? FileManager.default.removeItem(at: root) }
        let store = SwiftNativeDeskStore(dataRoot: root)
        let tracked = try await deskItem(store, kind: .gh, title: "tracker managed", refreshSources: ["github"])
        let untrackedGH = try await deskItem(store, kind: .gh, title: "manual gh")
        let nonGH = try await deskItem(store, kind: .project, title: "project with github cadence", refreshSources: ["github"])
        let pursuit = try await store.openPursuit(
            project: "eval", title: "never sweep a pursuit", pursuit: validPursuit(1)
        )
        _ = try await store.setCadence(
            pursuit.handle, cadence: Cadence(mode: .event, refreshSources: ["github"])
        )
        let terminalTracked = try await deskItem(store, kind: .gh, title: "already terminal", refreshSources: ["github"])
        _ = try await store.closeItem(terminalTracked.handle, outcomeSummary: "already done")
        let cli = try deskSweepProduct()

        let dry = try runDeskSweep(cli, [
            "--data-root", root.path, "--retire-tracker-gh", "--dry-run",
        ])
        #expect(dry.exitCode == 0, "dry-run failed: \(dry.stderr)")
        #expect(printedPlan(dry.stdout, verb: "DRY").contains { $0.hasPrefix(tracked.alias) })
        for excluded in [untrackedGH, nonGH, pursuit, terminalTracked] {
            #expect(!dry.stdout.contains(excluded.alias), "dry-run widened to \(excluded.alias): \(dry.stdout)")
        }
        #expect((try await requireItem(tracked.handle, in: store)).status.isTerminal == false)

        let wet = try runDeskSweep(cli, ["--data-root", root.path, "--retire-tracker-gh"])
        #expect(wet.exitCode == 0, "real sweep failed: \(wet.stderr)")
        #expect(wet.stdout.contains("CLOSE \(tracked.alias)"))
        #expect(
            printedPlan(dry.stdout, verb: "DRY") == printedPlan(wet.stdout, verb: "CLOSE"),
            "dry-run plan diverged from the real write plan\ndry:\n\(dry.stdout)\nwet:\n\(wet.stdout)"
        )
        #expect(wet.stdout.contains("closed 1, failed 0, skipped 0"))
        #expect((try await requireItem(tracked.handle, in: store)).status.isTerminal)
        #expect((try await requireItem(untrackedGH.handle, in: store)).status.isTerminal == false)
        #expect((try await requireItem(nonGH.handle, in: store)).status.isTerminal == false)
        #expect((try await requireItem(pursuit.handle, in: store)).status.isTerminal == false)
        #expect((try await requireItem(terminalTracked.handle, in: store)).status.isTerminal)
    }

    @Test("settled-GitHub sweep closes only explicitly closed or merged records")
    func settledGHSweepRejectsOpenAndUnknownEvidence() async throws {
        let root = try deskSweepRoot("settled")
        defer { try? FileManager.default.removeItem(at: root) }
        let store = SwiftNativeDeskStore(dataRoot: root)
        let closed = try await deskItem(store, kind: .gh, title: "closed upstream")
        let merged = try await deskItem(store, kind: .gh, title: "merged upstream")
        let open = try await deskItem(store, kind: .gh, title: "still open")
        let unknown = try await deskItem(store, kind: .gh, title: "unknown state")
        let emptyState = try await deskItem(store, kind: .gh, title: "empty state")
        let nonGH = try await deskItem(store, kind: .project, title: "non gh")
        for (item, number) in [(closed, 10), (merged, 11), (open, 12), (unknown, 13), (emptyState, 14)] {
            _ = try await store.addRef(
                item.handle,
                ref: DeskRef(kind: .ghPr(repo: "example/widgets", number: number, title: nil, status: "open", checks: nil))
            )
        }
        let snapshot = root.appendingPathComponent("connectors/github/tracking_snapshot.json")
        try FileManager.default.createDirectory(at: snapshot.deletingLastPathComponent(), withIntermediateDirectories: true)
        let rows: [[String: Any]] = [
            ["repository": "example/widgets", "number": 10, "state": "closed", "merged": false],
            ["repository": "example/widgets", "number": 11, "state": "merged", "merged": true],
            ["repository": "example/widgets", "number": 12, "state": "open", "merged": false],
            ["repository": "example/widgets", "number": 13, "state": "unknown", "merged": false],
            ["repository": "example/widgets", "number": 14, "state": "", "merged": false],
        ]
        let snapshotBytes = try JSONSerialization.data(withJSONObject: ["entities": rows], options: [.sortedKeys])
        try snapshotBytes.write(to: snapshot)
        let cli = try deskSweepProduct()

        let dry = try runDeskSweep(cli, ["--data-root", root.path, "--close-settled-gh", "--dry-run"])
        #expect(dry.exitCode == 0, "settled dry-run failed: \(dry.stderr)")
        let sweep = try runDeskSweep(cli, ["--data-root", root.path, "--close-settled-gh"])
        #expect(sweep.exitCode == 0, "settled sweep failed: \(sweep.stderr)")
        #expect(sweep.stdout.contains("closed 2, failed 0, skipped 0"))
        #expect(printedPlan(dry.stdout, verb: "DRY") == printedPlan(sweep.stdout, verb: "CLOSE"))
        for expected in [closed, merged] { #expect(sweep.stdout.contains("CLOSE \(expected.alias)")) }
        for excluded in [open, unknown, emptyState, nonGH] { #expect(!sweep.stdout.contains(excluded.alias)) }
        #expect((try await requireItem(closed.handle, in: store)).status.isTerminal)
        #expect((try await requireItem(merged.handle, in: store)).status.isTerminal)
        #expect((try await requireItem(open.handle, in: store)).status.isTerminal == false)
        #expect((try await requireItem(unknown.handle, in: store)).status.isTerminal == false)
        #expect((try await requireItem(emptyState.handle, in: store)).status.isTerminal == false)
        #expect((try await requireItem(nonGH.handle, in: store)).status.isTerminal == false)
    }

    @Test("settled-GitHub sweep refuses an absent tracking snapshot without mutation")
    func settledGHSweepFailsClosedWhenTrackingSnapshotIsAbsent() async throws {
        let root = try deskSweepRoot("missing-snapshot")
        defer { try? FileManager.default.removeItem(at: root) }
        let store = SwiftNativeDeskStore(dataRoot: root)
        let item = try await deskItem(store, kind: .gh, title: "must remain open")
        _ = try await store.addRef(
            item.handle,
            ref: DeskRef(kind: .ghPr(repo: "example/widgets", number: 99, title: nil, status: "open", checks: nil))
        )
        let cli = try deskSweepProduct()

        let refused = try runDeskSweep(cli, ["--data-root", root.path, "--close-settled-gh"])
        #expect(refused.exitCode == 1)
        #expect(refused.stderr.contains("cannot read tracking snapshot"))
        #expect((try await requireItem(item.handle, in: store)).status.isTerminal == false)
    }

    @Test("settled-GitHub sweep refuses a malformed tracking snapshot without mutation")
    func settledGHSweepFailsClosedWhenTrackingSnapshotIsMalformed() async throws {
        let root = try deskSweepRoot("malformed-snapshot")
        defer { try? FileManager.default.removeItem(at: root) }
        let store = SwiftNativeDeskStore(dataRoot: root)
        let item = try await deskItem(store, kind: .gh, title: "must remain open after malformed feed")
        _ = try await store.addRef(
            item.handle,
            ref: DeskRef(kind: .ghPr(repo: "example/widgets", number: 100, title: nil, status: "open", checks: nil))
        )
        let snapshot = root.appendingPathComponent("connectors/github/tracking_snapshot.json")
        try FileManager.default.createDirectory(at: snapshot.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data("{ not JSON".utf8).write(to: snapshot)
        let cli = try deskSweepProduct()

        let refused = try runDeskSweep(cli, ["--data-root", root.path, "--close-settled-gh"])
        #expect(refused.exitCode == 1)
        #expect(refused.stderr.contains("cannot read tracking snapshot"))
        #expect((try await requireItem(item.handle, in: store)).status.isTerminal == false)
    }

    @Test("a wholly stale retire plan prints SKIP, preserves the item, and exits nonzero")
    func retireTrackerGhFailsWhenEveryCASCloseIsStale() async throws {
        let root = try deskSweepRoot("stale-cas")
        defer { try? FileManager.default.removeItem(at: root) }
        let store = SwiftNativeDeskStore(dataRoot: root)
        let tracked = try await deskItem(store, kind: .gh, title: "change between plan and close", refreshSources: ["github"])
        let ready = root.appendingPathComponent("plan-ready")
        let proceed = root.appendingPathComponent("plan-continue")
        let cli = try deskSweepProduct()

        let run = Task.detached { () throws -> DeskSweepRun in
            try runDeskSweep(
                cli,
                ["--data-root", root.path, "--retire-tracker-gh"],
                environment: [
                    "NATIVE_AGENT_DESK_SWEEP_TEST_PLAN_READY_FILE": ready.path,
                    "NATIVE_AGENT_DESK_SWEEP_TEST_PLAN_CONTINUE_FILE": proceed.path,
                ]
            )
        }
        // Always release the bounded subprocess barrier, including when an
        // assertion or mutation fails, so this eval cannot leave a helper live.
        defer { FileManager.default.createFile(atPath: proceed.path, contents: Data()) }
        try waitForFile(ready)
        _ = try await store.appendNote(tracked.handle, text: "concurrent owner update")
        FileManager.default.createFile(atPath: proceed.path, contents: Data())

        let stale = try await run.value
        #expect(stale.exitCode == 1, "all-skipped run was falsely successful: \(stale.stdout) \(stale.stderr)")
        #expect(stale.stdout.contains("SKIP \(tracked.alias)"))
        #expect(stale.stdout.contains("closed 0, failed 0, skipped 1"))
        #expect((try await requireItem(tracked.handle, in: store)).status.isTerminal == false)
    }

    @Test("GitHub report distinguishes every live state, sums exactly, and is read-only")
    func githubReportCoversEveryStateWithAnExactHistogram() async throws {
        let root = try deskSweepRoot("gh-report")
        defer { try? FileManager.default.removeItem(at: root) }
        let commands = GitHubCommandStore(dataRoot: root)

        // Every public state is reached through the command store's real
        // transition API, then observed only through the operator CLI.
        _ = try await commands.detect(
            repository: "example/widgets", number: 41, kind: .pullRequest, title: "detected"
        )
        let needsCodex = try await commands.observe(githubObservation(
            number: 42, version: "needs-codex", signals: [.changesRequested]
        ))
        let working = try await commands.observe(githubObservation(
            number: 43, version: "working", signals: [.changesRequested]
        ))
        _ = try await dispatchWorkingItem(commands, item: working)
        let verifying = try await commands.observe(githubObservation(
            number: 44, version: "verifying", signals: [.changesRequested]
        ))
        let verifyingReceipt = try await dispatchWorkingItem(commands, item: verifying)
        _ = try await commands.recordCallback(
            messageIds: [verifyingReceipt.messageId], codexStatus: "completed", summary: "done"
        )
        _ = try await commands.observe(githubObservation(
            number: 45,
            version: "needs-user",
            decision: GitHubCommandBlocker(detail: "owner decision required", owner: "Owner")
        ))
        _ = try await commands.observe(githubObservation(number: 46, version: "waiting"))
        let failedDispatch = try await commands.observe(githubObservation(
            number: 47, version: "dispatch-failed", signals: [.changesRequested]
        ))
        let failureIntent = try #require(try await commands.prepareDispatch(itemId: failedDispatch.itemId))
        _ = try await commands.recordDispatchFailure(
            itemId: failedDispatch.itemId, eventKey: failureIntent.eventKey, detail: "bridge unavailable"
        )
        _ = try await commands.detect(
            repository: "example/widgets", number: 48, kind: .pullRequest, title: "resolved"
        )
        _ = try await commands.observe(githubObservation(number: 48, version: "resolved", open: false, merged: true))
        #expect(needsCodex.state == .needsCodex)
        let before = try await commands.liveState()
        let cli = try deskSweepProduct()

        let report = try runDeskSweep(cli, ["--data-root", root.path, "--gh-report"])
        #expect(report.exitCode == 0, "GitHub report failed: \(report.stderr)")
        #expect(report.stdout.contains("items: 8"))
        var histogram: [String: Int] = [:]
        let histogramRows = report.stdout
            .split(whereSeparator: { $0.isNewline })
            .compactMap({ line -> (String, Int)? in
                guard line.hasPrefix("  "),
                      let separator = line.lastIndex(of: ":"),
                      let count = Int(line[line.index(after: separator)...].trimmingCharacters(in: .whitespaces)) else {
                    return nil
                }
                let labelStart = line.index(line.startIndex, offsetBy: 2)
                return (String(line[labelStart..<separator]), count)
            })
        for (label, count) in histogramRows {
            histogram[label, default: 0] += count
        }
        #expect(histogram.values.reduce(0, +) == 8, "histogram did not account for every stored item: \(report.stdout)")
        #expect(histogram.count == 8, "distinct states collapsed into one label: \(report.stdout)")
        for label in ["detected", "needs_codex", "codex_working", "verifying", "needs_user", "resolved"] {
            #expect(histogram[label] == 1, "missing or ambiguous \(label): \(report.stdout)")
        }
        #expect(histogram.keys.contains { $0.hasPrefix("waiting_upstream(") })
        #expect(histogram.keys.contains { $0.hasPrefix("attention(") })
        #expect(try await commands.liveState() == before)

        // An empty command store is a distinct explicit report, never a
        // fabricated set of zero-valued states that looks like a full feed.
        let emptyRoot = try deskSweepRoot("gh-report-empty")
        defer { try? FileManager.default.removeItem(at: emptyRoot) }
        let empty = try runDeskSweep(cli, ["--data-root", emptyRoot.path, "--gh-report"])
        #expect(empty.exitCode == 0)
        #expect(empty.stdout.trimmingCharacters(in: .whitespacesAndNewlines) == "items: 0")
    }
}
