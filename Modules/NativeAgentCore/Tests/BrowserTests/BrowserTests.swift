import Testing
import Foundation
@testable import Browser
import NativeAgentCore
import PersistenceCore

// MARK: - Helpers

private func obj(_ pairs: [String: JSONValue]) -> JSONValue { .object(pairs) }

/// A temp dir laid out like the daemon data root for browser status:
///   <root>/native_power/browser/{runs.json, receipts.jsonl}
///   <root>/trust/policy.json
private struct Fixture {
    let root: URL
    let runsPath: URL
    let receiptsPath: URL
    let profileDir: URL
    let sourcesDir: URL
    let screenshotsDir: URL
    let trustPolicyPath: URL

    init() throws {
        root = FileManager.default.temporaryDirectory
            .appendingPathComponent("browser-tests-\(UUID().uuidString)", isDirectory: true)
        let browser = root
            .appendingPathComponent("native_power", isDirectory: true)
            .appendingPathComponent("browser", isDirectory: true)
        try FileManager.default.createDirectory(at: browser, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(
            at: root.appendingPathComponent("trust", isDirectory: true),
            withIntermediateDirectories: true
        )
        runsPath = browser.appendingPathComponent("runs.json")
        receiptsPath = browser.appendingPathComponent("receipts.jsonl")
        profileDir = browser.appendingPathComponent("profile", isDirectory: true)
        sourcesDir = browser.appendingPathComponent("sources", isDirectory: true)
        screenshotsDir = browser.appendingPathComponent("screenshots", isDirectory: true)
        trustPolicyPath = root
            .appendingPathComponent("trust", isDirectory: true)
            .appendingPathComponent("policy.json")
    }

    func client() -> SwiftNativeBrowserClient {
        SwiftNativeBrowserClient(
            runsPath: runsPath,
            receiptsPath: receiptsPath,
            profileDir: profileDir,
            sourcesDir: sourcesDir,
            screenshotsDir: screenshotsDir,
            trustPolicyPath: trustPolicyPath
        )
    }

    func writeRuns(_ runs: [[String: Any]]) throws {
        let data = try JSONSerialization.data(withJSONObject: runs, options: [])
        try data.write(to: runsPath)
    }

    func writeReceiptsLines(_ lines: [[String: Any]]) throws {
        var text = ""
        for line in lines {
            let d = try JSONSerialization.data(withJSONObject: line, options: [])
            text += String(data: d, encoding: .utf8)! + "\n"
        }
        try text.write(to: receiptsPath, atomically: true, encoding: .utf8)
    }

    func writeTrust(_ policy: [String: Any]) throws {
        let data = try JSONSerialization.data(withJSONObject: policy, options: [])
        try data.write(to: trustPolicyPath)
    }

    func cleanup() { try? FileManager.default.removeItem(at: root) }
}

private func string(_ env: JSONValue, _ key: String) -> String? {
    guard case .object(let o) = env, case .string(let s)? = o[key] else { return nil }
    return s
}

private func array(_ env: JSONValue, _ key: String) -> [JSONValue]? {
    guard case .object(let o) = env, case .array(let a)? = o[key] else { return nil }
    return a
}

private func ints(_ env: JSONValue, _ key: String) -> Int64? {
    guard case .object(let o) = env, case .int(let n)? = o[key] else { return nil }
    return n
}

private func runIDs(_ vals: [JSONValue]) -> [String] {
    vals.compactMap { v in
        if case .object(let o) = v, case .string(let id)? = o["id"] { return id }
        return nil
    }
}

// MARK: - Envelope shape

@Test func browserStatus_envelopeMirrorsDaemon() async throws {
    let fix = try Fixture()
    defer { fix.cleanup() }
    let env = await fix.client().browserStatus()
    let unwrapped = try #require(env)
    #expect(string(unwrapped, "status") == "ready")
    #expect(string(unwrapped, "profilePath") == fix.profileDir.path)
    #expect(string(unwrapped, "sourcePath") == fix.sourcesDir.path)
    #expect(string(unwrapped, "screenshotPath") == fix.screenshotsDir.path)
    // createdAt is now_iso()-shaped: "...+00:00" offset (NOT a trailing Z).
    let createdAt = try #require(string(unwrapped, "createdAt"))
    #expect(createdAt.hasSuffix("+00:00"))
}

// MARK: - activeRuns filtering

@Test func browserStatus_activeRunsFilterMatchesPython() async throws {
    let fix = try Fixture()
    defer { fix.cleanup() }
    try fix.writeRuns([
        ["id": "r1", "status": "running"],
        ["id": "r2", "status": "succeeded"],
        ["id": "r3", "status": "waiting_approval"],
        ["id": "r4", "status": "dry_run"],
        ["id": "r5", "status": "canceled"],
        ["id": "r6", "status": "failed"],
    ])
    let env = try #require(await fix.client().browserStatus())
    let active = try #require(array(env, "activeRuns"))
    // Only running + waiting_approval are "active" (matches browser_status()).
    #expect(runIDs(active) == ["r1", "r3"])
}

@Test func browserStatus_missingRunsFileGivesEmptyActive() async throws {
    let fix = try Fixture()
    defer { fix.cleanup() }
    // No runs.json on disk -> read_json default [] -> no active runs.
    let env = try #require(await fix.client().browserStatus())
    #expect(array(env, "activeRuns") == [])
}

// MARK: - receipts: last 20, newest-first

@Test func browserStatus_receiptsNewestFirstCappedAt20() async throws {
    let fix = try Fixture()
    defer { fix.cleanup() }
    // 25 receipts in file order (oldest first). tail_jsonl keeps last 20,
    // then reversed() -> newest first. So latestReceipt is the LAST line, and
    // receiptCount is 20.
    var lines: [[String: Any]] = []
    for i in 0..<25 { lines.append(["id": "rcpt-\(i)", "n": i]) }
    try fix.writeReceiptsLines(lines)
    let env = try #require(await fix.client().browserStatus())
    #expect(ints(env, "receiptCount") == 20)
    // latestReceipt = newest = the last written line (rcpt-24).
    guard case .object(let o)? = (env.asObject?["latestReceipt"]),
          case .string(let latestID)? = o["id"] else {
        Issue.record("latestReceipt not an object with id")
        return
    }
    #expect(latestID == "rcpt-24")
}

@Test func browserStatus_receiptsTailScanWindowMatchesDaemon1MiB() async throws {
    // R-W17 review #1: a >1 MiB receipts.jsonl must be TAIL-scanned (last ~1 MiB),
    // matching Python tail_jsonl's default max_bytes=1_048_576, NOT fully read.
    // Pad each early line so the file exceeds 1 MiB, then the last 20 short lines
    // are what survive the window. receiptCount stays 20 and latestReceipt is the
    // final line — the same as the daemon would serve.
    let fix = try Fixture()
    defer { fix.cleanup() }
    let pad = String(repeating: "x", count: 50_000) // ~50 KB per padded line
    var lines: [[String: Any]] = []
    for i in 0..<30 { lines.append(["id": "old-\(i)", "pad": pad]) } // ~1.5 MiB of old lines
    for i in 0..<20 { lines.append(["id": "recent-\(i)"]) }          // 20 small recent lines
    try fix.writeReceiptsLines(lines)
    let env = try #require(await fix.client().browserStatus())
    #expect(ints(env, "receiptCount") == 20)
    guard case .object(let o)? = (env.asObject?["latestReceipt"]),
          case .string(let latestID)? = o["id"] else {
        Issue.record("latestReceipt not an object with id")
        return
    }
    #expect(latestID == "recent-19")
}

@Test func approvedDomains_nonStringElementsCoercedPythonStyle() async throws {
    // R-W17 review #2: Python str()-stringifies every element. A misconfigured
    // list [123, " Foo ", true] -> ["123", "foo", "true"] (lower+strip+sort).
    let fix = try Fixture()
    defer { fix.cleanup() }
    try fix.writeTrust([
        "browserPolicy": [
            "approvedDomains": [123, " Foo ", true]
        ]
    ])
    let env = try #require(await fix.client().browserStatus())
    #expect(env.asObject?["domainPolicy"] == .string("approval_risk_tiering"))
    let domains = try #require(array(env, "approvedDomains")).compactMap { v -> String? in
        if case .string(let s) = v { return s }
        return nil
    }
    // 123 -> "123"; " Foo " -> "foo"; true -> "True".lower() -> "true". Sorted.
    #expect(domains == ["123", "foo", "true"])
}

@Test func browserStatus_noReceiptsGivesNullLatestAndZeroCount() async throws {
    let fix = try Fixture()
    defer { fix.cleanup() }
    let env = try #require(await fix.client().browserStatus())
    #expect(ints(env, "receiptCount") == 0)
    #expect(env.asObject?["latestReceipt"] == .some(.null))
}

// MARK: - approvedDomains

@Test func approvedDomains_defaultWhenNoPolicy() async throws {
    let fix = try Fixture()
    defer { fix.cleanup() }
    let env = try #require(await fix.client().browserStatus())
    let domains = try #require(array(env, "approvedDomains")).compactMap { v -> String? in
        if case .string(let s) = v { return s }
        return nil
    }
    // Default list, lowercased + sorted.
    #expect(domains == ["127.0.0.1", "example.com", "github.com", "linear.app", "localhost", "openai.com"])
}

@Test func approvedDomains_configuredListLowercasedStrippedSorted() async throws {
    let fix = try Fixture()
    defer { fix.cleanup() }
    try fix.writeTrust([
        "browserPolicy": [
            "approvedDomains": ["  Example.COM ", "Foo.io", "", "   ", "bar.dev", "FOO.io"]
        ]
    ])
    let env = try #require(await fix.client().browserStatus())
    let domains = try #require(array(env, "approvedDomains")).compactMap { v -> String? in
        if case .string(let s) = v { return s }
        return nil
    }
    // strip + lower + drop empties + dedup (FOO.io == foo.io) + sort.
    #expect(domains == ["bar.dev", "example.com", "foo.io"])
}

// MARK: - factory gating

@Test func factory_returnsSwiftNative() async throws {
    let fix = try Fixture()
    defer { fix.cleanup() }
    let client = makeBrowserClient(client: fix.client())
    #expect(client is SwiftNativeBrowserClient)
    // Serves a non-nil envelope from the injected native fixture.
    #expect(await client.browserStatus() != nil)
}

@Test func factoryDerivesEveryBrowserPathFromInjectedDataRoot() throws {
    let root = FileManager.default.temporaryDirectory
        .appendingPathComponent("BrowserFactoryRoot-\(UUID().uuidString)", isDirectory: true)
    let client = try #require(makeBrowserClient(dataRoot: root) as? SwiftNativeBrowserClient)
    let browserRoot = root
        .appendingPathComponent("native_power", isDirectory: true)
        .appendingPathComponent("browser", isDirectory: true)

    #expect(client.runsPath == browserRoot.appendingPathComponent("runs.json"))
    #expect(client.receiptsPath == browserRoot.appendingPathComponent("receipts.jsonl"))
    #expect(client.profileDir == browserRoot.appendingPathComponent("profile", isDirectory: true))
    #expect(client.sourcesDir == browserRoot.appendingPathComponent("sources", isDirectory: true))
    #expect(client.screenshotsDir == browserRoot.appendingPathComponent("screenshots", isDirectory: true))
    #expect(client.trustPolicyPath == root
        .appendingPathComponent("trust", isDirectory: true)
        .appendingPathComponent("policy.json"))
}

// MARK: - JSONValue object accessor (test-local convenience)

private extension JSONValue {
    var asObject: [String: JSONValue]? {
        if case .object(let o) = self { return o }
        return nil
    }
}
