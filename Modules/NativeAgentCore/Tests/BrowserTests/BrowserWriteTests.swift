import Testing
import Foundation
@testable import Browser
import NativeAgentCore
import PersistenceCore

// Wave 34 W17 — tests for the SwiftNative WRITE port (run dry-run path + cancel).

// MARK: - Helpers

/// A temp dir laid out like the daemon data root for the browser WRITE paths:
///   <root>/native_power/browser/{runs.json, receipts.jsonl}
///   <root>/native_power/actions/receipts.jsonl   (cross-action native receipts)
///   <root>/traces/events.jsonl
///   <root>/trust/policy.json
private struct WriteFixture {
    let root: URL
    let runsPath: URL
    let receiptsPath: URL
    let nativeActionsPath: URL
    let tracesPath: URL
    let profileDir: URL
    let sourcesDir: URL
    let screenshotsDir: URL
    let trustPolicyPath: URL

    init() throws {
        root = FileManager.default.temporaryDirectory
            .appendingPathComponent("browser-write-tests-\(UUID().uuidString)", isDirectory: true)
        let browser = root
            .appendingPathComponent("native_power", isDirectory: true)
            .appendingPathComponent("browser", isDirectory: true)
        try FileManager.default.createDirectory(at: browser, withIntermediateDirectories: true)
        runsPath = browser.appendingPathComponent("runs.json")
        receiptsPath = browser.appendingPathComponent("receipts.jsonl")
        nativeActionsPath = root
            .appendingPathComponent("native_power", isDirectory: true)
            .appendingPathComponent("actions", isDirectory: true)
            .appendingPathComponent("receipts.jsonl")
        tracesPath = root
            .appendingPathComponent("traces", isDirectory: true)
            .appendingPathComponent("events.jsonl")
        profileDir = browser.appendingPathComponent("profile", isDirectory: true)
        sourcesDir = browser.appendingPathComponent("sources", isDirectory: true)
        screenshotsDir = browser.appendingPathComponent("screenshots", isDirectory: true)
        trustPolicyPath = root
            .appendingPathComponent("trust", isDirectory: true)
            .appendingPathComponent("policy.json")
    }

    /// Uses the on-disk SwiftNativePersistenceCore so the flock path + atomic
    /// write + jsonl append all exercise the REAL persistence layer.
    func client(now: @escaping @Sendable () -> Date = { Date() }) -> SwiftNativeBrowserClient {
        SwiftNativeBrowserClient(
            runsPath: runsPath,
            receiptsPath: receiptsPath,
            profileDir: profileDir,
            sourcesDir: sourcesDir,
            screenshotsDir: screenshotsDir,
            trustPolicyPath: trustPolicyPath,
            persistence: SwiftNativePersistenceCore(),
            now: now
        )
    }

    func writeRuns(_ runs: [[String: Any]]) throws {
        let data = try JSONSerialization.data(withJSONObject: runs, options: [])
        try data.write(to: runsPath)
    }

    func readRunsRaw() -> [JSONValue] {
        guard let data = try? Data(contentsOf: runsPath),
              let parsed = try? JSONValue.parse(data),
              case .array(let arr) = parsed else { return [] }
        return arr
    }

    func receiptLineCount(_ path: URL) -> Int {
        guard let text = try? String(contentsOf: path, encoding: .utf8) else { return 0 }
        return text.split(separator: "\n", omittingEmptySubsequences: true).count
    }

    func receiptStatuses(_ path: URL) -> [String] {
        guard let text = try? String(contentsOf: path, encoding: .utf8) else { return [] }
        return text.split(separator: "\n").compactMap { line in
            guard let data = line.data(using: .utf8),
                  let value = try? JSONValue.parse(data) else { return nil }
            return str(value, "status")
        }
    }

    func cleanup() { try? FileManager.default.removeItem(at: root) }
}

// MARK: - canonical live-operation store

@Test func browserOperation_cancelWinsAgainstLateSuccess() async throws {
    let fix = try WriteFixture()
    defer { fix.cleanup() }
    let client = fix.client()
    let start = BrowserOperationStart(
        id: "race-run",
        url: "https://example.com/race",
        domain: "example.com",
        initialState: .running,
        visible: true,
        deadlineSeconds: 30
    )
    let digest = SwiftNativeBrowserClient.browserRequestDigest(for: start)
    _ = try await client.executeBrowserOperation(.start(start))
    let canceled = try #require(try await client.executeBrowserOperation(.cancel(id: "race-run")).run)
    #expect(str(canceled, "status") == "canceled")

    let late = try #require(try await client.executeBrowserOperation(.complete(.init(
        id: "race-run",
        requestDigest: digest,
        state: .succeeded,
        opened: true
    ))).run)
    #expect(str(late, "status") == "canceled")
    #expect(fix.receiptLineCount(fix.receiptsPath) == 1)
    #expect(fix.receiptLineCount(fix.nativeActionsPath) == 1)
    #expect(fix.receiptLineCount(fix.tracesPath) == 1)
}

@Test func browserOperation_restartRecoversStrandedRunningWithoutReopening() async throws {
    let fix = try WriteFixture()
    defer { fix.cleanup() }
    let startTime = Date(timeIntervalSince1970: 2_000_000_000)
    let first = fix.client(now: { startTime })
    let start = BrowserOperationStart(
        id: "stranded-run",
        url: "https://example.com/stranded",
        domain: "example.com",
        initialState: .running,
        visible: true,
        deadlineSeconds: 10
    )
    _ = try await first.executeBrowserOperation(.start(start))

    // A fresh process cannot inherit the WebKit task, even before the deadline.
    // Recovery records outcome_unknown; it never replays navigation.
    let restarted = fix.client(now: { startTime.addingTimeInterval(1) })
    let recovery = try await restarted.executeBrowserOperation(.recoverStrandedRunning)
    #expect(recovery.recoveredCount == 1)
    let run = try #require(recovery.run)
    #expect(str(run, "status") == "failed")
    #expect(str(run, "errorCode") == "restart_stranded_running")
    #expect(str(run, "outcomeKind") == "outcome_unknown")
    #expect(fix.receiptLineCount(fix.receiptsPath) == 1)

    let again = try await restarted.executeBrowserOperation(.recoverStrandedRunning)
    #expect(again.recoveredCount == 0)
    #expect(fix.receiptLineCount(fix.receiptsPath) == 1)
}

@Test func browserOperation_requestDigestMakesStartIdempotentAndRejectsCollision() async throws {
    let fix = try WriteFixture()
    defer { fix.cleanup() }
    let client = fix.client()
    let start = BrowserOperationStart(
        id: "stable-id",
        url: "https://example.com/a",
        domain: "example.com",
        initialState: .running,
        visible: true,
        deadlineSeconds: 30
    )
    let first = try await client.executeBrowserOperation(.start(start))
    let retry = try await client.executeBrowserOperation(.start(start))
    #expect(first.didTransition)
    #expect(!retry.didTransition)
    #expect(fix.readRunsRaw().count == 1)

    let conflict = BrowserOperationStart(
        id: "stable-id",
        url: "https://example.com/different",
        domain: "example.com",
        initialState: .running,
        visible: true,
        deadlineSeconds: 30
    )
    await #expect(throws: BrowserOperationStoreError.conflictingIdempotencyKey) {
        _ = try await client.executeBrowserOperation(.start(conflict))
    }
}

@Test func browserOperation_rejectsTraceDomainThatDoesNotMatchURLAuthority() async throws {
    let fix = try WriteFixture()
    defer { fix.cleanup() }
    let start = BrowserOperationStart(
        id: "domain-mismatch",
        url: "https://example.com/private",
        domain: "trusted.example",
        initialState: .running,
        visible: true,
        deadlineSeconds: 30
    )

    await #expect(throws: BrowserOperationStoreError.invalidDomain) {
        _ = try await fix.client().executeBrowserOperation(.start(start))
    }
    #expect(fix.readRunsRaw().isEmpty)
}

@Test func browserOperation_derivedReceiptsProjectExactlyOnce() async throws {
    let fix = try WriteFixture()
    defer { fix.cleanup() }
    let client = fix.client()
    let start = BrowserOperationStart(
        id: "receipt-run",
        url: "https://example.com/receipt",
        domain: "example.com",
        initialState: .running,
        visible: true,
        deadlineSeconds: 30
    )
    let digest = SwiftNativeBrowserClient.browserRequestDigest(for: start)
    _ = try await client.executeBrowserOperation(.start(start))
    #expect(str(try #require(fix.readRunsRaw().first), "verificationStatus") == "pending")
    let completion = BrowserOperationCompletion(
        id: "receipt-run",
        requestDigest: digest,
        state: .succeeded,
        opened: true,
        sourceReceipt: .object(["httpStatus": .int(200)])
    )
    _ = try await client.executeBrowserOperation(.complete(completion))
    _ = try await client.executeBrowserOperation(.complete(completion))
    _ = try await client.executeBrowserOperation(.projectPendingReceipts)

    #expect(fix.receiptLineCount(fix.receiptsPath) == 1)
    #expect(fix.receiptLineCount(fix.nativeActionsPath) == 1)
    #expect(fix.receiptLineCount(fix.tracesPath) == 1)
    let canonical = try #require(fix.readRunsRaw().first)
    #expect(str(canonical, "projectionState") == "projected")
    #expect(str(canonical, "verificationStatus") == "satisfied")
}

@Test func browserOperation_cancelPreservesEarlierUnprojectedTransition() async throws {
    let fix = try WriteFixture()
    defer { fix.cleanup() }
    let createdAt = "2026-07-13T00:00:00.000+00:00"
    let dryRun: [String: Any] = [
        "id": "outbox-race",
        "url": "https://example.com/outbox",
        "domain": "example.com",
        "status": "dry_run",
        "dryRun": true,
        "visible": true,
        "opened": false,
        "createdAt": createdAt,
    ]
    let row = dryRun.merging([
        "requestDigest": "legacy-digest",
        "transitionSequence": 1,
        "projectionId": "first-transition",
        "projectionState": "pending",
        "projectionOutbox": [[
            "id": "first-transition",
            "run": dryRun,
        ]],
    ]) { _, new in new }
    try fix.writeRuns([row])

    let canceled = try #require(
        try await fix.client().executeBrowserOperation(.cancel(id: "outbox-race")).run
    )
    #expect(str(canceled, "status") == "canceled")
    #expect(fix.receiptStatuses(fix.receiptsPath) == ["dry_run", "canceled"])
    #expect(str(try #require(fix.readRunsRaw().first), "projectionState") == "projected")
}

@Test func browserOperation_capacityNeverEvictsActiveCanonicalRuns() async throws {
    let fix = try WriteFixture()
    defer { fix.cleanup() }
    try fix.writeRuns((0..<200).map { ["id": "active-\($0)", "status": "running"] })
    let start = BrowserOperationStart(
        id: "overflow",
        url: "https://example.com/overflow",
        domain: "example.com",
        initialState: .dryRun,
        visible: true
    )

    await #expect(throws: BrowserOperationStoreError.capacityExceeded) {
        _ = try await fix.client().executeBrowserOperation(.start(start))
    }
    #expect(fix.readRunsRaw().count == 200)
    #expect(fix.receiptLineCount(fix.receiptsPath) == 0)
}

@Test func browserOperation_capacityPrunesProjectedDryRuns() async throws {
    let fix = try WriteFixture()
    defer { fix.cleanup() }
    try fix.writeRuns((0..<200).map {
        [
            "id": "dry-\($0)",
            "status": "dry_run",
            "projectionState": "projected",
        ]
    })
    let start = BrowserOperationStart(
        id: "dry-200",
        url: "https://example.com/latest",
        domain: "example.com",
        initialState: .dryRun,
        visible: true
    )

    let result = try await fix.client().executeBrowserOperation(.start(start))
    #expect(result.didTransition)
    let runs = fix.readRunsRaw()
    #expect(runs.count == 200)
    #expect(!runs.contains { str($0, "id") == "dry-0" })
    #expect(runs.contains { str($0, "id") == "dry-200" })
    #expect(fix.receiptLineCount(fix.receiptsPath) == 1)
}

private func str(_ v: JSONValue, _ key: String) -> String? {
    guard case .object(let o) = v, case .string(let s)? = o[key] else { return nil }
    return s
}
private func bool(_ v: JSONValue, _ key: String) -> Bool? {
    guard case .object(let o) = v, case .bool(let b)? = o[key] else { return nil }
    return b
}
private func isNull(_ v: JSONValue, _ key: String) -> Bool {
    guard case .object(let o) = v else { return false }
    return o[key] == .some(.null)
}

// MARK: - run (dry-run path)

@Test func runBrowser_dryRun_writesRunReceiptsAndTrace() async throws {
    let fix = try WriteFixture()
    defer { fix.cleanup() }
    let body: JSONValue = .object([
        "url": .string("https://Example.com/Path"),
        "dryRun": .bool(true),
        "readOnly": .bool(true),
        "captureSource": .bool(false),
    ])
    let result = try #require(try await fix.client().runBrowserAction(body: body))

    // Returned envelope mirrors run_browser_action's dry-run run dict.
    #expect(str(result, "status") == "dry_run")
    #expect(bool(result, "dryRun") == true)
    #expect(bool(result, "opened") == false)
    #expect(isNull(result, "approvalId"))
    #expect(isNull(result, "sourceReceipt"))
    #expect(isNull(result, "screenshotReceipt"))
    // domain is lowercased; url is preserved verbatim.
    #expect(str(result, "domain") == "example.com")
    #expect(str(result, "url") == "https://Example.com/Path")
    let createdAt = try #require(str(result, "createdAt"))
    #expect(createdAt.hasSuffix("+00:00"))

    // runs.json now holds exactly the one run.
    let runs = fix.readRunsRaw()
    #expect(runs.count == 1)
    #expect(str(runs[0], "status") == "dry_run")

    // browser receipts.jsonl + native actions receipts.jsonl each got ONE line.
    #expect(fix.receiptLineCount(fix.receiptsPath) == 1)
    #expect(fix.receiptLineCount(fix.nativeActionsPath) == 1)
    // trace events.jsonl got ONE line.
    #expect(fix.receiptLineCount(fix.tracesPath) == 1)
}

@Test func runBrowser_dryRun_appendsToExistingRunsCappedAt200() async throws {
    let fix = try WriteFixture()
    defer { fix.cleanup() }
    // Seed 200 runs; one more append must cap to the last 200 (drops the oldest).
    var seed: [[String: Any]] = []
    for i in 0..<200 { seed.append(["id": "seed-\(i)", "status": "succeeded"]) }
    try fix.writeRuns(seed)

    _ = try #require(try await fix.client().runBrowserAction(body: .object([
        "url": .string("https://example.com"),
        "dryRun": .bool(true),
        "readOnly": .bool(true),
        "captureSource": .bool(false),
    ])))

    let runs = fix.readRunsRaw()
    #expect(runs.count == 200)                       // capped
    #expect(str(runs[0], "id") == "seed-1")          // oldest (seed-0) dropped
    #expect(str(runs[199], "status") == "dry_run")   // new run is last
}

@Test func runBrowser_nonDryRun_fallsThroughToHTTP() async throws {
    let fix = try WriteFixture()
    defer { fix.cleanup() }
    // Non-dry-run pulls in approvals / IPC / fetch — NOT ported. Returns nil.
    let result = try await fix.client().runBrowserAction(body: .object([
        "url": .string("https://example.com"),
        "dryRun": .bool(false),
    ]))
    #expect(result == nil)
    // No files written.
    #expect(fix.readRunsRaw().isEmpty)
    #expect(fix.receiptLineCount(fix.tracesPath) == 0)
}

@Test func runBrowser_dryRunWithCaptureSource_fallsThroughToHTTP() async throws {
    let fix = try WriteFixture()
    defer { fix.cleanup() }
    // A dry-run that asks to capture source pulls in fetch_url — NOT ported.
    // (readOnly is NOT set, so the daemon would NOT force capture_source off.)
    let result = try await fix.client().runBrowserAction(body: .object([
        "url": .string("https://example.com"),
        "dryRun": .bool(true),
        "captureSource": .bool(true),
    ]))
    #expect(result == nil)
    #expect(fix.readRunsRaw().isEmpty)
}

@Test func runBrowser_emptyAndBadURL_fallThroughToHTTP() async throws {
    let fix = try WriteFixture()
    defer { fix.cleanup() }
    let c = fix.client()
    // Empty URL -> daemon raises ValueError; let HTTP own the error.
    #expect(try await c.runBrowserAction(body: .object(["dryRun": .bool(true)])) == nil)
    // Non-http scheme -> daemon raises ValueError.
    #expect(try await c.runBrowserAction(body: .object([
        "url": .string("ftp://example.com"), "dryRun": .bool(true), "readOnly": .bool(true), "captureSource": .bool(false),
    ])) == nil)
    // No host.
    #expect(try await c.runBrowserAction(body: .object([
        "url": .string("http://"), "dryRun": .bool(true), "readOnly": .bool(true), "captureSource": .bool(false),
    ])) == nil)
    #expect(fix.readRunsRaw().isEmpty)
}

@Test func runBrowser_emptyStringURLFallsThroughToInputURL() async throws {
    // R-W17 (gpt-5.5 review wave 34): Python `body.get("url") or payload.get("url")`
    // means an EXPLICIT empty-string body.url is falsy and falls through to
    // input.url. The old `pyStr(..) ?? pyStr(..)` kept the "" and rejected. pyOr
    // must pick input.url.
    let fix = try WriteFixture()
    defer { fix.cleanup() }
    let result = try #require(try await fix.client().runBrowserAction(body: .object([
        "url": .string(""),                                   // falsy → fall through
        "input": .object(["url": .string("https://github.com")]),
        "dryRun": .bool(true),
        "readOnly": .bool(true),
        "captureSource": .bool(false),
    ])))
    #expect(str(result, "domain") == "github.com")
    #expect(str(result, "url") == "https://github.com")
}

@Test func runBrowser_payloadURLFallback() async throws {
    // url = body.url or payload(input).url. Here only input.url is set.
    let fix = try WriteFixture()
    defer { fix.cleanup() }
    let result = try #require(try await fix.client().runBrowserAction(body: .object([
        "input": .object(["url": .string("https://github.com")]),
        "dryRun": .bool(true),
        "readOnly": .bool(true),
        "captureSource": .bool(false),
    ])))
    #expect(str(result, "domain") == "github.com")
}

// MARK: - cancel

@Test func cancelBrowserRun_byID_marksCanceledAndAppendsReceipt() async throws {
    let fix = try WriteFixture()
    defer { fix.cleanup() }
    try fix.writeRuns([
        ["id": "r1", "status": "succeeded"],
        ["id": "r2", "status": "running"],
        ["id": "r3", "status": "running"],
    ])
    let result = try #require(try await fix.client().cancelBrowserRun(body: .object(["id": .string("r2")])))
    #expect(str(result, "id") == "r2")
    #expect(str(result, "status") == "canceled")
    #expect(str(result, "canceledAt")?.hasSuffix("+00:00") == true)

    // Only r2 flipped; r3 still running (cancel stops at first match by id).
    let runs = fix.readRunsRaw()
    #expect(str(runs[1], "status") == "canceled")
    #expect(str(runs[2], "status") == "running")
    // One receipt appended.
    #expect(fix.receiptLineCount(fix.receiptsPath) == 1)
}

@Test func cancelBrowserRun_noID_cancelsFirstCancelable() async throws {
    let fix = try WriteFixture()
    defer { fix.cleanup() }
    // No id -> cancel the FIRST run whose status is cancelable. r1 is succeeded
    // (not cancelable); r2 dry_run IS cancelable -> it gets canceled.
    try fix.writeRuns([
        ["id": "r1", "status": "succeeded"],
        ["id": "r2", "status": "dry_run"],
        ["id": "r3", "status": "waiting_approval"],
    ])
    let result = try #require(try await fix.client().cancelBrowserRun(body: .object(["dryRun": .bool(true)])))
    #expect(str(result, "id") == "r2")
    #expect(str(result, "status") == "canceled")
    let runs = fix.readRunsRaw()
    #expect(str(runs[2], "status") == "waiting_approval") // r3 untouched
}

@Test func cancelBrowserRun_unknownID_returnsNotFound() async throws {
    let fix = try WriteFixture()
    defer { fix.cleanup() }
    try fix.writeRuns([["id": "r1", "status": "running"]])
    let result = try #require(try await fix.client().cancelBrowserRun(body: .object(["id": .string("nope")])))
    #expect(str(result, "status") == "not_found")
    #expect(str(result, "id") == "nope")
    #expect(str(result, "createdAt")?.hasSuffix("+00:00") == true)
    // r1 untouched, no receipt appended.
    #expect(str(fix.readRunsRaw()[0], "status") == "running")
    #expect(fix.receiptLineCount(fix.receiptsPath) == 0)
}

@Test func cancelBrowserRun_alreadyTerminalNotCancelable_returnsNotFound() async throws {
    let fix = try WriteFixture()
    defer { fix.cleanup() }
    // id matches but status is terminal (succeeded) -> not cancelable -> not_found.
    try fix.writeRuns([["id": "r1", "status": "succeeded"]])
    let result = try #require(try await fix.client().cancelBrowserRun(body: .object(["id": .string("r1")])))
    #expect(str(result, "status") == "not_found")
}

// MARK: - factory (write side)

@Test func writeFactory_returnsSwiftNative() async throws {
    let fix = try WriteFixture()
    defer { fix.cleanup() }
    let writer = makeBrowserWriter(client: fix.client())
    #expect(writer is SwiftNativeBrowserClient)
    let result = try await writer.runBrowserAction(body: .object([
        "url": .string("https://example.com"),
        "dryRun": .bool(true),
        "readOnly": .bool(true),
        "captureSource": .bool(false),
    ]))
    #expect(result != nil)
}

// MARK: - concurrency / flock behavior

@Test func runBrowser_concurrentDryRuns_allLandUnderFlock() async throws {
    // The flock'd R-M-W must not lose appends under concurrent runs. Fire 12
    // dry-runs concurrently against the SAME runs.json; all 12 must survive.
    let fix = try WriteFixture()
    defer { fix.cleanup() }
    let client = fix.client()
    await withTaskGroup(of: Void.self) { group in
        for i in 0..<12 {
            group.addTask {
                // `try?`: the concurrency test asserts the flock serializes the
                // R-M-W (all 12 land); a stray IO throw would just drop that one
                // append, which the count assertion would then catch.
                _ = try? await client.runBrowserAction(body: .object([
                    "url": .string("https://example.com/\(i)"),
                    "dryRun": .bool(true),
                    "readOnly": .bool(true),
                    "captureSource": .bool(false),
                ]))
            }
        }
    }
    #expect(fix.readRunsRaw().count == 12)
}
