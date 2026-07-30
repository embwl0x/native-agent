import Foundation
import Testing
import NativeAgentCore
import PersistenceCore
import TrustCenter
@testable import SystemOps

/// Permissive trust policy for tests that need the wave-8 autonomy gate to
/// allow the action through. Every flag is on.
private func _permissiveAutonomyPolicy() -> AutonomyTrustPolicyView {
    AutonomyTrustPolicyView(
        enableAutonomy: true,
        systemRebuildEnabled: true,
        gitStashRecoverEnabled: true,
        raw: .object([:])
    )
}

// MARK: - Subprocess stub

actor _SubprocessStub: SubprocessRunner {
    struct Invocation: Equatable {
        let executable: String
        let arguments: [String]
        let cwd: String?
        let timeout: TimeInterval
        let detached: Bool
    }
    private var responses: [(exitCode: Int32, stdout: String, stderr: String)] = []
    private(set) var invocations: [Invocation] = []
    private var throwAtIndex: Int? = nil

    func queue(exitCode: Int32 = 0, stdout: String = "", stderr: String = "") {
        responses.append((exitCode, stdout, stderr))
    }

    func run(
        executable: String,
        arguments: [String],
        cwd: URL?,
        timeout: TimeInterval,
        detached: Bool
    ) async throws -> (exitCode: Int32, stdout: String, stderr: String) {
        invocations.append(.init(
            executable: executable,
            arguments: arguments,
            cwd: cwd?.path,
            timeout: timeout,
            detached: detached
        ))
        if responses.isEmpty {
            return (0, "", "")
        }
        return responses.removeFirst()
    }
}

// MARK: - Helpers

private func makeTempDir() -> URL {
    let url = URL(fileURLWithPath: NSTemporaryDirectory())
        .appendingPathComponent("SystemOpsTests-\(UUID().uuidString)", isDirectory: true)
    try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
    return url
}

private func readJSONFile(_ url: URL) -> JSONValue? {
    guard let data = try? Data(contentsOf: url) else { return nil }
    return try? JSONValue.parse(data)
}

// MARK: - RouterPlan parity tests

@Test func routerPlanClassifiesApproval() async throws {
    let client = SwiftNativeRouterPlanClient()
    let r = try await client.planRoute(message: "please approve this")
    #expect(r.goalType == "approval")
    #expect(r.recommendedSurface == "activity")
    #expect(r.contextMode == "ops")
}

@Test func routerPlanClassifiesTelegram() async throws {
    let client = SwiftNativeRouterPlanClient()
    let r = try await client.planRoute(message: "telegram bot config")
    #expect(r.goalType == "telegram")
    #expect(r.recommendedSurface == "telegram")
}

@Test func routerPlanClassifiesSchedule() async throws {
    let client = SwiftNativeRouterPlanClient()
    let r = try await client.planRoute(message: "schedule a reminder")
    #expect(r.goalType == "schedule")
}

@Test func routerPlanClassifiesCalendarReadAsScheduleWithoutApproval() async throws {
    let client = SwiftNativeRouterPlanClient()
    let r = try await client.planRoute(
        message: "Do I have anything on my calendar today that would affect whether I should keep coding?"
    )
    #expect(r.goalType == "schedule")
    #expect(r.contextMode == "ops")
    #expect(r.risk == "low")
    #expect(r.requiresApproval == false)
}

@Test func routerPlanClassifiesMemoryUpdate() async throws {
    let client = SwiftNativeRouterPlanClient()
    let r = try await client.planRoute(message: "remember my preferences")
    #expect(r.goalType == "memory_update")
}

@Test func routerPlanClassifiesResearch() async throws {
    let client = SwiftNativeRouterPlanClient()
    let r = try await client.planRoute(message: "research the topic")
    #expect(r.goalType == "research")
}

@Test func routerPlanClassifiesWorkflow() async throws {
    let client = SwiftNativeRouterPlanClient()
    let r = try await client.planRoute(message: "automate this workflow")
    #expect(r.goalType == "workflow")
}

@Test func routerPlanClassifiesBuildTask() async throws {
    let client = SwiftNativeRouterPlanClient()
    let r = try await client.planRoute(message: "fix the swift build")
    #expect(r.goalType == "build_task")
}

@Test func routerPlanClassifiesGitStatusAsBuildTask() async throws {
    let client = SwiftNativeRouterPlanClient()
    let r = try await client.planRoute(message: "check git status in the NativeAgent repo")
    #expect(r.goalType == "build_task")
    #expect(r.contextMode == "capability")
}

@Test func routerPlanClassifiesRepoStandsAsBuildTask() async throws {
    let client = SwiftNativeRouterPlanClient()
    let r = try await client.planRoute(
        message: "Can you check where the NativeAgent repo stands right now? I just need the short version."
    )
    #expect(r.goalType == "build_task")
    #expect(r.contextMode == "capability")
}

@Test func routerPlanClassifiesSelfImprovement() async throws {
    let client = SwiftNativeRouterPlanClient()
    let r = try await client.planRoute(message: "improve self-improvement loop")
    #expect(r.goalType == "self_improvement")
}

@Test func routerPlanClassifiesChat() async throws {
    let client = SwiftNativeRouterPlanClient()
    let r = try await client.planRoute(message: "hello")
    #expect(r.goalType == "chat")
}

@Test func routerPlanWatchSetupRoutesToSchedule() async throws {
    let client = SwiftNativeRouterPlanClient()
    let r = try await client.planRoute(message: "watch my email inbox")
    #expect(r.goalType == "schedule")
    #expect(r.risk == "medium")
}

@Test func routerPlanEmailKeywordRisesRisk() async throws {
    let client = SwiftNativeRouterPlanClient()
    let r = try await client.planRoute(message: "send an email to bob")
    #expect(r.risk == "high")
    #expect(r.requiresApproval == true)
}

@Test func routerPlanIdAndCreatedAtPopulated() async throws {
    let client = SwiftNativeRouterPlanClient()
    let r = try await client.planRoute(message: "hello")
    #expect(!r.id.isEmpty)
    #expect(r.createdAt.contains("+00:00"))
}

@Test func routerPlanEmptyMessageThrows() async throws {
    let client = SwiftNativeRouterPlanClient()
    do {
        _ = try await client.planRoute(message: "")
        Issue.record("expected SystemOpsError.missingMessage")
    } catch SystemOpsError.missingMessage {
        // expected
    } catch {
        Issue.record("wrong error: \(error)")
    }
}

// MARK: - CrashReport tests

@Test func crashReportWritesJSONLLikePayload() async throws {
    let dir = makeTempDir()
    let client = SwiftNativeCrashReportClient(crashReportsDir: dir)
    let result = try await client.postCrashReport(
        traceback: "Traceback (most recent call last)...",
        stderrTail: "fatal error happened",
        exitCode: 134,
        capturedAt: "2026-05-31T12:34:56.000000+00:00"
    )
    #expect(result.stored == true)
    #expect(result.path.hasSuffix(".json"))
    let parsed = readJSONFile(URL(fileURLWithPath: result.path))
    guard case .object(let obj) = parsed ?? .null else {
        Issue.record("crash file is not a JSON object")
        return
    }
    if case .string(let s) = obj["traceback"] ?? .null {
        #expect(s.contains("Traceback"))
    } else {
        Issue.record("missing traceback")
    }
    if case .int(let code) = obj["exit_code"] ?? .null {
        #expect(code == 134)
    } else {
        Issue.record("missing exit_code")
    }
}

@Test func crashReportRedactsUserPaths() async throws {
    let dir = makeTempDir()
    let client = SwiftNativeCrashReportClient(crashReportsDir: dir)
    let result = try await client.postCrashReport(
        traceback: "boom at /Users/jane/secrets/foo.py line 1",
        stderrTail: "",
        exitCode: nil,
        capturedAt: "2026-05-31T00-00-00"
    )
    let parsed = readJSONFile(URL(fileURLWithPath: result.path))
    guard case .object(let obj) = parsed ?? .null,
          case .string(let tb) = obj["traceback"] ?? .null else {
        Issue.record("malformed payload")
        return
    }
    #expect(tb.contains("/Users/<user>/<path>"))
    #expect(!tb.contains("/Users/jane/"))
}

@Test func crashReportRedactsBearerToken() async throws {
    let dir = makeTempDir()
    let client = SwiftNativeCrashReportClient(crashReportsDir: dir)
    let result = try await client.postCrashReport(
        traceback: "Authorization Bearer abc123abc123abc123abc123 here",
        stderrTail: "",
        exitCode: nil,
        capturedAt: "2026-05-31T00-00-00"
    )
    let parsed = readJSONFile(URL(fileURLWithPath: result.path))
    if case .object(let obj) = parsed ?? .null,
       case .string(let tb) = obj["traceback"] ?? .null {
        #expect(tb.contains("Bearer [token-redacted]"))
        #expect(!tb.contains("abc123abc123"))
    } else {
        Issue.record("malformed payload")
    }
}

@Test func crashReportRedactsSkToken() async throws {
    let dir = makeTempDir()
    let client = SwiftNativeCrashReportClient(crashReportsDir: dir)
    let result = try await client.postCrashReport(
        traceback: "key=" + ["sk", "1234567890abcdef12345"].joined(separator: "-") + " leaked",
        stderrTail: "",
        exitCode: nil,
        capturedAt: "2026-05-31T00-00-00"
    )
    let parsed = readJSONFile(URL(fileURLWithPath: result.path))
    if case .object(let obj) = parsed ?? .null,
       case .string(let tb) = obj["traceback"] ?? .null {
        #expect(tb.contains("[token-redacted]"))
        #expect(!tb.contains("sk-1234567890"))
    } else {
        Issue.record("malformed payload")
    }
}

@Test func crashReportWritesLastJson() async throws {
    let dir = makeTempDir()
    let client = SwiftNativeCrashReportClient(crashReportsDir: dir)
    _ = try await client.postCrashReport(
        traceback: "x", stderrTail: "y", exitCode: nil, capturedAt: "2026-05-31T00-00-00"
    )
    let lastPath = dir.appendingPathComponent("last.json")
    #expect(FileManager.default.fileExists(atPath: lastPath.path))
}

@Test func crashReportPrunesOldFiles() async throws {
    let dir = makeTempDir()
    // Write 55 stub crash files DIRECTLY with staggered mtimes, then call
    // pruneOldCrashFiles. Doing it via 55 postCrashReport calls would all
    // collide on the same sanitized timestamp + 4-char suffix collision risk.
    let fm = FileManager.default
    for i in 0..<55 {
        let url = dir.appendingPathComponent("crash-2026-05-31T00-00-00-\(String(format: "%04d", i)).json")
        try Data("{}".utf8).write(to: url)
        let mtime = Date(timeIntervalSince1970: 1_700_000_000 + TimeInterval(i))
        try fm.setAttributes([.modificationDate: mtime], ofItemAtPath: url.path)
    }
    SwiftNativeCrashReportClient.pruneOldCrashFiles(in: dir, keep: 50)
    let remaining = (try fm.contentsOfDirectory(at: dir, includingPropertiesForKeys: nil))
        .filter { $0.lastPathComponent.hasPrefix("crash-") && $0.lastPathComponent.hasSuffix(".json") }
    #expect(remaining.count == 50)
}

@Test func crashReportImprovementSpawnedAlwaysFalse() async throws {
    let dir = makeTempDir()
    let client = SwiftNativeCrashReportClient(crashReportsDir: dir)
    let result = try await client.postCrashReport(
        traceback: "anything", stderrTail: "", exitCode: nil, capturedAt: "2026-05-31T00-00-00"
    )
    #expect(result.improvementSpawned == false)
}

// MARK: - health_card crash-reports-24h slice parity (WAVE 39 W10 §6.201)

/// Helper: write a stub crash file with an explicit mtime.
private func writeCrashStub(_ dir: URL, name: String, mtime: Date) throws {
    let url = dir.appendingPathComponent(name)
    try Data("{}".utf8).write(to: url)
    try FileManager.default.setAttributes([.modificationDate: mtime], ofItemAtPath: url.path)
}

@Test func recentCrashEntryEmptyDirIsOk() async throws {
    let dir = makeTempDir()
    let entry = SwiftNativeCrashReportClient.recentCrashSubsystemEntry(in: dir)
    #expect(entry.id == "crash_reports")
    #expect(entry.label == "Recent crashes")
    #expect(entry.status == "ok")          // n_recent == 0 → "ok"
    #expect(entry.detail == "0 in last 24h")
    #expect(entry.fixAction == nil)        // crash slice never sets fixAction
}

@Test func recentCrashEntryMissingDirCountsZero() async throws {
    // PARITY (gpt-5.5 wave-39 review BLOCKER fix): Python's
    // `Path.glob("crash-*.json")` returns an EMPTY iterator for a missing /
    // non-directory path (no raise) — verified empirically. So the daemon's
    // crash slice reports "0 in last 24h" / status "ok", NOT the `except`
    // "Crash report dir unavailable" row. The Swift helper must match: a
    // contentsOfDirectory failure maps to ZERO crash files, not the fallback.
    let dir = makeTempDir().appendingPathComponent("does-not-exist", isDirectory: true)
    let entry = SwiftNativeCrashReportClient.recentCrashSubsystemEntry(in: dir)
    #expect(entry.status == "ok")
    #expect(entry.detail == "0 in last 24h")
}

@Test func recentCrashEntryCountsOnlyLast24h() async throws {
    let dir = makeTempDir()
    let now = Date(timeIntervalSince1970: 1_700_000_000)
    // 2 recent (within 24h), 1 old (just over 24h → excluded), 1 boundary
    // (exactly 24h ago → `>= cutoff` includes it).
    try writeCrashStub(dir, name: "crash-a.json", mtime: now.addingTimeInterval(-3600))      // 1h ago: recent
    try writeCrashStub(dir, name: "crash-b.json", mtime: now.addingTimeInterval(-86_399))    // <24h: recent
    try writeCrashStub(dir, name: "crash-c.json", mtime: now.addingTimeInterval(-86_400))    // ==24h: included (>=)
    try writeCrashStub(dir, name: "crash-d.json", mtime: now.addingTimeInterval(-86_401))    // >24h: excluded
    let entry = SwiftNativeCrashReportClient.recentCrashSubsystemEntry(in: dir, now: now)
    #expect(entry.status == "warn")        // n_recent > 0
    #expect(entry.detail == "3 in last 24h")
}

@Test func recentCrashEntryIgnoresNonCrashFiles() async throws {
    let dir = makeTempDir()
    let now = Date(timeIntervalSince1970: 1_700_000_000)
    try writeCrashStub(dir, name: "crash-x.json", mtime: now)        // matches glob
    try writeCrashStub(dir, name: "last.json", mtime: now)           // wrong prefix
    try writeCrashStub(dir, name: "crash-x.txt", mtime: now)         // wrong suffix
    try writeCrashStub(dir, name: "notacrash.json", mtime: now)      // wrong prefix
    let entry = SwiftNativeCrashReportClient.recentCrashSubsystemEntry(in: dir, now: now)
    #expect(entry.detail == "1 in last 24h")  // only crash-x.json counts
    #expect(entry.status == "warn")
}

@Test func healthCardSubsystemJSONOmitsNilFixAction() async throws {
    let withFix = HealthCardSubsystem(id: "provider", label: "Provider", status: "error",
                                      detail: "Auth error", fixAction: "reauthorize_provider")
    let withoutFix = HealthCardSubsystem(id: "crash_reports", label: "Recent crashes",
                                         status: "ok", detail: "0 in last 24h")
    // fixAction present → key present.
    if case .object(let obj) = withFix.toJSON() {
        #expect(obj["fixAction"] == .string("reauthorize_provider"))
        #expect(obj["status"] == .string("error"))
    } else { Issue.record("expected object") }
    // fixAction nil → key ABSENT (mirrors daemon `if fix_action:`).
    if case .object(let obj) = withoutFix.toJSON() {
        #expect(obj["fixAction"] == nil)
        #expect(obj.keys.sorted() == ["detail", "id", "label", "status"])
    } else { Issue.record("expected object") }
}

@Test func healthCardSubsystemJSONOmitsEmptyFixAction() async throws {
    // PARITY (gpt-5.5 wave-39 review SHOULD-FIX): Python `if fix_action:` is
    // FALSY on empty-string too, so an empty fixAction is omitted, not emitted
    // as `fixAction: ""`. The Swift toJSON must omit on nil OR "".
    let emptyFix = HealthCardSubsystem(id: "x", label: "X", status: "ok",
                                       detail: "d", fixAction: "")
    if case .object(let obj) = emptyFix.toJSON() {
        #expect(obj["fixAction"] == nil)
        #expect(obj.keys.sorted() == ["detail", "id", "label", "status"])
    } else { Issue.record("expected object") }
}

// MARK: - health_card autonomy slice (wave 40 W06)

/// Write `<dataRoot>/trust/policy.json` with the given JSON object body.
private func writeTrustPolicy(_ dataRoot: URL, _ body: [String: JSONValue]) throws {
    let dir = dataRoot.appendingPathComponent("trust", isDirectory: true)
    try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    let data = try JSONValue.object(body).serializedData(pretty: false)
    try data.write(to: dir.appendingPathComponent("policy.json"))
}

/// Write `<dataRoot>/scheduler/jobs.json` with the given JSON array body.
private func writeJobs(_ dataRoot: URL, _ jobs: [JSONValue]) throws {
    let dir = dataRoot.appendingPathComponent("scheduler", isDirectory: true)
    try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    let data = try JSONValue.array(jobs).serializedData(pretty: false)
    try data.write(to: dir.appendingPathComponent("jobs.json"))
}

@Test func autonomyEntryEnabledIsOk() async throws {
    // enableAutonomy true → status "ok", detail "Enabled", no fixAction
    // (daemon the retired daemon).
    let root = makeTempDir()
    try writeTrustPolicy(root, ["enableAutonomy": .bool(true)])
    let entry = await SwiftNativeCrashReportClient.autonomySubsystemEntry(in: root)
    #expect(entry.id == "autonomy")
    #expect(entry.label == "Autonomy")
    #expect(entry.status == "ok")
    #expect(entry.detail == "Enabled")
    #expect(entry.fixAction == nil)
}

@Test func autonomyEntryDisabledIsWarnWithFix() async throws {
    // enableAutonomy false → status "warn", detail "Disabled",
    // fixAction "enable_autonomy" (daemon L28735).
    let root = makeTempDir()
    try writeTrustPolicy(root, ["enableAutonomy": .bool(false)])
    let entry = await SwiftNativeCrashReportClient.autonomySubsystemEntry(in: root)
    #expect(entry.status == "warn")
    #expect(entry.detail == "Disabled")
    #expect(entry.fixAction == "enable_autonomy")
}

@Test func autonomyEntryMissingPolicyIsDisabledNotExcept() async throws {
    // PARITY: a MISSING policy.json → `read_json(self.trust_path, {})` returns
    // `{}` → `enableAutonomy=False` → the DISABLED row, NOT the daemon's
    // `except`→"Could not check autonomy policy" branch (that fires only on a
    // genuine raise inside trust_policy(), which the pure file read cannot
    // reproduce). Swift readAutonomyTrustPolicy is fail-open-to-deny, matching.
    let root = makeTempDir()  // no trust/policy.json written
    let entry = await SwiftNativeCrashReportClient.autonomySubsystemEntry(in: root)
    #expect(entry.status == "warn")
    #expect(entry.detail == "Disabled")
    #expect(entry.fixAction == "enable_autonomy")
}

@Test func autonomyEntryMissingKeyDefaultsFalse() async throws {
    // policy.json present but WITHOUT the enableAutonomy key →
    // `bool(policy.get("enableAutonomy", False))` is False → DISABLED row.
    let root = makeTempDir()
    try writeTrustPolicy(root, ["somethingElse": .string("x")])
    let entry = await SwiftNativeCrashReportClient.autonomySubsystemEntry(in: root)
    #expect(entry.status == "warn")
    #expect(entry.detail == "Disabled")
}

@Test func autonomyEntryNonBooleanTruthyValueIsEnabled() async throws {
    // PARITY (gpt-5.5 wave-40 review finding #1): the daemon applies Python
    // `bool(policy.get("enableAutonomy", False))` to the RAW stored value, so a
    // non-boolean truthy value (legacy / hand-edited file) reports "Enabled".
    // The helper reads `raw` and applies retired truthiness, NOT TrustCenter's
    // strict `.bool(true)`-only view.
    for truthy: JSONValue in [.int(1), .double(0.5), .string("true"), .array([.int(1)]), .object(["x": .bool(true)])] {
        let root = makeTempDir()
        try writeTrustPolicy(root, ["enableAutonomy": truthy])
        let entry = await SwiftNativeCrashReportClient.autonomySubsystemEntry(in: root)
        #expect(entry.status == "ok", "truthy \(truthy) should be Enabled")
        #expect(entry.detail == "Enabled")
        #expect(entry.fixAction == nil)
    }
    // Non-boolean FALSY values (0, "", [], {}, null) → Disabled.
    for falsy: JSONValue in [.int(0), .double(0), .string(""), .array([]), .object([:]), .null] {
        let root = makeTempDir()
        try writeTrustPolicy(root, ["enableAutonomy": falsy])
        let entry = await SwiftNativeCrashReportClient.autonomySubsystemEntry(in: root)
        #expect(entry.status == "warn", "falsy \(falsy) should be Disabled")
        #expect(entry.detail == "Disabled")
        #expect(entry.fixAction == "enable_autonomy")
    }
}

// MARK: - health_card scheduler slice (wave 40 W06, file-backed COUNT only)

@Test func schedulerEntryCountsEnabledJobsDefaultTrue() async throws {
    // `n_enabled = sum(1 for j in jobs if j.get("enabled", True))` (daemon
    // L28778) — `enabled` DEFAULTS TRUE. Here: 1 explicit true, 1 missing key
    // (counts), 1 explicit false (excluded) → 2 enabled.
    let root = makeTempDir()
    try writeJobs(root, [
        .object(["id": .string("a"), "enabled": .bool(true)]),
        .object(["id": .string("b")]),                          // missing → default True
        .object(["id": .string("c"), "enabled": .bool(false)]), // excluded
    ])
    // schedulerThreadAlive supplied by caller (BLOCKED sub-fact). true → "ok".
    let alive = await SwiftNativeCrashReportClient.schedulerSubsystemEntry(
        in: root, schedulerThreadAlive: true)
    #expect(alive.id == "scheduler")
    #expect(alive.label == "Scheduler")
    #expect(alive.status == "ok")              // sched_alive → "ok" (L28780)
    #expect(alive.detail == "2 enabled jobs")  // file-backed COUNT (L28781)
    #expect(alive.fixAction == nil)
    // Same file, thread NOT alive → conservative "warn", count unchanged.
    let dead = await SwiftNativeCrashReportClient.schedulerSubsystemEntry(
        in: root, schedulerThreadAlive: false)
    #expect(dead.status == "warn")
    #expect(dead.detail == "2 enabled jobs")
}

@Test func schedulerEntryMissingFileCountsZero() async throws {
    // `read_json(self.jobs_path, [])` → [] for a missing file → 0 enabled.
    let root = makeTempDir()  // no scheduler/jobs.json
    let entry = await SwiftNativeCrashReportClient.schedulerSubsystemEntry(
        in: root, schedulerThreadAlive: false)
    #expect(entry.detail == "0 enabled jobs")
    #expect(entry.status == "warn")
}

@Test func schedulerEntryNonArrayFileCountsZero() async throws {
    // A jobs.json that is not an array (corrupt) → PersistenceCore returns the
    // default ([]) on a type mismatch / parse failure → 0 enabled. (And the
    // daemon's `if not isinstance(jobs, list): return []` likewise yields 0.)
    let root = makeTempDir()
    let dir = root.appendingPathComponent("scheduler", isDirectory: true)
    try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    try Data("{\"not\":\"an array\"}".utf8).write(to: dir.appendingPathComponent("jobs.json"))
    let entry = await SwiftNativeCrashReportClient.schedulerSubsystemEntry(
        in: root, schedulerThreadAlive: true)
    #expect(entry.detail == "0 enabled jobs")
    #expect(entry.status == "ok")
}

@Test func schedulerEntryNonObjectEntryYieldsFallback() async throws {
    // PARITY (gpt-5.5 wave-40 review finding #2): the daemon's list_jobs does
    // `d = dict(j)` for EVERY array element OUTSIDE any try/except; a non-dict
    // element raises, propagating to the scheduler slice's `except` → the
    // WHOLE-SLICE FALLBACK row "Scheduler status unavailable" (warn, no
    // fixAction). One non-object entry must trip the fallback, NOT a partial
    // count.
    let root = makeTempDir()
    try writeJobs(root, [
        .object(["id": .string("a"), "enabled": .bool(true)]),
        .string("not-an-object"),   // non-dict → daemon `dict(j)` raises
    ])
    let entry = await SwiftNativeCrashReportClient.schedulerSubsystemEntry(
        in: root, schedulerThreadAlive: true)   // even with alive thread → fallback
    #expect(entry.id == "scheduler")
    #expect(entry.label == "Scheduler")
    #expect(entry.status == "warn")
    #expect(entry.detail == "Scheduler status unavailable")
    #expect(entry.fixAction == nil)
}

@Test func pythonBoolGetMirrorsPythonBoolGetDefault() async throws {
    // `bool(obj.get(key, default))` — pin the unified truthiness building block.
    // KEY ABSENT returns the caller's default (verified for BOTH defaults).
    #expect(SwiftNativeCrashReportClient.pythonBoolGet([:], "k", default: true) == true)
    #expect(SwiftNativeCrashReportClient.pythonBoolGet([:], "k", default: false) == false)
    // KEY PRESENT -> retired truthiness of the stored value, default ignored.
    func t(_ v: JSONValue) -> Bool {
        SwiftNativeCrashReportClient.pythonBoolGet(["k": v], "k", default: true)
    }
    #expect(t(.bool(true)) == true)
    #expect(t(.bool(false)) == false)
    #expect(t(.null) == false)            // explicit null is falsy even with default true
    #expect(t(.int(0)) == false)
    #expect(t(.int(1)) == true)
    #expect(t(.double(0)) == false)
    #expect(t(.double(-0.0)) == false)    // negative zero == 0 → false (matches Python)
    #expect(t(.double(0.5)) == true)
    #expect(t(.string("")) == false)
    #expect(t(.string("x")) == true)
    #expect(t(.array([])) == false)
    #expect(t(.array([.int(1)])) == true)
    #expect(t(.object([:])) == false)
    #expect(t(.object(["a": .bool(false)])) == true)   // non-empty object is truthy
}

// MARK: - Throwing-readJSONL persistence stub (inbox unreadable-file parity)

/// PersistenceCore stub whose `readJSONL` always THROWS (simulating an existing-
/// but-unreadable items.jsonl), while `readJSON` delegates to a real read so the
/// inbox helper's index.json load still behaves normally. Used by
/// `inboxEntryExistingButUnreadableYieldsFallback`.
private struct _ThrowingJSONLPersistence: PersistenceCoreProtocol {
    private let real = SwiftNativePersistenceCore()
    enum StubError: Error { case unreadable }
    func readJSON(_ path: URL, defaultValue: JSONValue) async -> JSONValue {
        await real.readJSON(path, defaultValue: defaultValue)
    }
    func writeJSON(_ value: JSONValue, to path: URL) async throws {
        try await real.writeJSON(value, to: path)
    }
    func appendJSONL(_ record: JSONValue, to path: URL) async throws {
        try await real.appendJSONL(record, to: path)
    }
    func tailJSONL(_ path: URL, limit: Int, maxBytes: Int?) async throws -> [JSONValue] {
        throw StubError.unreadable
    }
    func readJSONL(_ path: URL) async throws -> [JSONValue] {
        throw StubError.unreadable
    }
}

// MARK: - health_card approvals slice (wave 42 W17, file-backed)

/// Write `<dataRoot>/workflows/approvals/requests.json` with the given JSON array.
private func writeApprovals(_ dataRoot: URL, _ approvals: [JSONValue]) throws {
    let dir = dataRoot
        .appendingPathComponent("workflows", isDirectory: true)
        .appendingPathComponent("approvals", isDirectory: true)
    try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    let data = try JSONValue.array(approvals).serializedData(pretty: false)
    try data.write(to: dir.appendingPathComponent("requests.json"))
}

@Test func approvalsEntryNoPendingIsOk() async throws {
    // No "pending" records → status "ok", detail "No pending approvals", no fix
    // (daemon the retired daemon). Resolved approvals are NOT counted.
    let root = makeTempDir()
    try writeApprovals(root, [
        .object(["id": .string("a"), "status": .string("approved")]),
        .object(["id": .string("b"), "status": .string("denied")]),
    ])
    let entry = await SwiftNativeCrashReportClient.approvalsSubsystemEntry(in: root)
    #expect(entry.id == "approvals")
    #expect(entry.label == "Approvals")
    #expect(entry.status == "ok")
    #expect(entry.detail == "No pending approvals")
    #expect(entry.fixAction == nil)
}

@Test func approvalsEntryPendingIsWarnWithFix() async throws {
    // n_pending > 0 → status "warn", detail "<n> pending", fixAction
    // "show_approvals" (daemon L28762). 2 pending among 3 records.
    let root = makeTempDir()
    try writeApprovals(root, [
        .object(["id": .string("a"), "status": .string("pending")]),
        .object(["id": .string("b"), "status": .string("approved")]),
        .object(["id": .string("c"), "status": .string("pending")]),
    ])
    let entry = await SwiftNativeCrashReportClient.approvalsSubsystemEntry(in: root)
    #expect(entry.status == "warn")
    #expect(entry.detail == "2 pending")   // NOT truncated (no [:60] in daemon)
    #expect(entry.fixAction == "show_approvals")
}

@Test func approvalsEntryMissingFileIsOkNotExcept() async throws {
    // `read_json(self.approvals_path, [])` → [] for a missing file → 0 pending →
    // the "No pending approvals" (ok) row, NOT the daemon `except`→"Approval
    // queue unavailable" branch (unreachable from a pure read).
    let root = makeTempDir()  // no workflows/approvals/requests.json
    let entry = await SwiftNativeCrashReportClient.approvalsSubsystemEntry(in: root)
    #expect(entry.status == "ok")
    #expect(entry.detail == "No pending approvals")
    #expect(entry.fixAction == nil)
}

@Test func approvalsEntryNonArrayFileIsOk() async throws {
    // A non-array requests.json → `if not isinstance(approvals, list): return []`
    // (L7475) → 0 pending. PersistenceCore returns the default ([]) on a type
    // mismatch, matching.
    let root = makeTempDir()
    let dir = root
        .appendingPathComponent("workflows", isDirectory: true)
        .appendingPathComponent("approvals", isDirectory: true)
    try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    try Data("{\"not\":\"a list\"}".utf8).write(to: dir.appendingPathComponent("requests.json"))
    let entry = await SwiftNativeCrashReportClient.approvalsSubsystemEntry(in: root)
    #expect(entry.status == "ok")
    #expect(entry.detail == "No pending approvals")
}

@Test func approvalsEntryNonObjectElementYieldsFallback() async throws {
    // PARITY: `a.get("status")` on a non-dict element raises AttributeError in
    // the daemon's comprehension → the WHOLE-SLICE except → "Approval queue
    // unavailable" (ok, no fixAction). One bad element trips the fallback, NOT a
    // partial count. (Mirrors the scheduler slice's non-object bail.)
    let root = makeTempDir()
    try writeApprovals(root, [
        .object(["id": .string("a"), "status": .string("pending")]),
        .string("not-an-object"),
    ])
    let entry = await SwiftNativeCrashReportClient.approvalsSubsystemEntry(in: root)
    #expect(entry.status == "ok")
    #expect(entry.detail == "Approval queue unavailable")
    #expect(entry.fixAction == nil)
}

@Test func approvalsEntryMissingStatusKeyNotPending() async throws {
    // `a.get("status") == "pending"`: a record WITHOUT a status key → None →
    // not "pending" → not counted.
    let root = makeTempDir()
    try writeApprovals(root, [
        .object(["id": .string("a")]),                          // no status → None
        .object(["id": .string("b"), "status": .string("pending")]),
    ])
    let entry = await SwiftNativeCrashReportClient.approvalsSubsystemEntry(in: root)
    #expect(entry.status == "warn")
    #expect(entry.detail == "1 pending")
}

// MARK: - health_card inbox slice (wave 42 W17, file-backed two-file store)

/// A5.2 (2026-07-24): the Doctor inbox slice reads the LIVE inbox
/// (`<dataRoot>/notifications/inbox.jsonl`, append-only, last-write-wins per
/// id). Write it from JSON-object lines; `replacements` appends full
/// replacement rows AFTER the items (how status changes land in the live
/// store — there is no index overlay anymore).
private func writeInbox(
    _ dataRoot: URL,
    items: [JSONValue],
    replacements: [JSONValue] = [],
    rawItemsText: String? = nil
) throws {
    let dir = dataRoot.appendingPathComponent("notifications", isDirectory: true)
    try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    let file = dir.appendingPathComponent("inbox.jsonl")
    if let rawItemsText {
        try Data(rawItemsText.utf8).write(to: file)
    } else {
        var lines: [String] = []
        for item in items + replacements {
            let data = try item.serializedData(pretty: false)
            lines.append(String(data: data, encoding: .utf8) ?? "")
        }
        try Data((lines.joined(separator: "\n") + "\n").utf8).write(to: file)
    }
}

@Test func inboxEntryCountsUnreadDefaultStatus() async throws {
    // Per-item status DEFAULTS to "unread" when the JSONL record omits it
    // (InboxItem.from_dict, the retired daemon). 2 unread (1 explicit, 1 default),
    // 1 read → n_unread 2 → status "ok" (<= 10), detail "2 pending".
    let root = makeTempDir()
    try writeInbox(root, items: [
        .object(["id": .string("a"), "created_at": .string("2026-06-01T00:00:00Z"), "status": .string("unread")]),
        .object(["id": .string("b"), "created_at": .string("2026-06-01T00:01:00Z")]),  // no status → unread
        .object(["id": .string("c"), "created_at": .string("2026-06-01T00:02:00Z"), "status": .string("read")]),
    ])
    let entry = await SwiftNativeCrashReportClient.inboxSubsystemEntry(in: root)
    #expect(entry.id == "inbox")
    #expect(entry.label == "Inbox")
    #expect(entry.status == "ok")
    #expect(entry.detail == "2 pending")
    #expect(entry.fixAction == nil)
}

@Test func inboxEntryLastWriteWinsReplacesStoredStatus() async throws {
    // LAST-WRITE-WINS: a later replacement row with the same id REPLACES the
    // earlier row's status. "a" unread then dismissed → NOT unread.
    // "b" read then unread → IS unread.
    let root = makeTempDir()
    try writeInbox(root, items: [
        .object(["id": .string("a"), "created_at": .string("2026-06-01T00:00:00Z"), "status": .string("unread")]),
        .object(["id": .string("b"), "created_at": .string("2026-06-01T00:01:00Z"), "status": .string("read")]),
    ], replacements: [
        .object(["id": .string("a"), "created_at": .string("2026-06-01T00:00:00Z"), "status": .string("dismissed")]),
        .object(["id": .string("b"), "created_at": .string("2026-06-01T00:01:00Z"), "status": .string("unread")]),
    ])
    let entry = await SwiftNativeCrashReportClient.inboxSubsystemEntry(in: root)
    #expect(entry.detail == "1 pending")   // only b counts after replacement
    #expect(entry.status == "ok")
}

@Test func inboxEntryReplacementRowWithoutStatusDefaultsUnread() async throws {
    // A replacement row that omits "status" defaults to unread (per-row
    // default) — the LATEST row is authoritative, fields and all.
    let root = makeTempDir()
    try writeInbox(root, items: [
        .object(["id": .string("a"), "created_at": .string("2026-06-01T00:00:00Z"), "status": .string("read")]),
    ], replacements: [
        .object(["id": .string("a"), "created_at": .string("2026-06-01T00:00:00Z"), "read_at": .null]),  // no status key
    ])
    let entry = await SwiftNativeCrashReportClient.inboxSubsystemEntry(in: root)
    #expect(entry.detail == "1 pending")
}

@Test func inboxEntryMissingItemsFileIsOkZero() async throws {
    // `_load_all` returns [] if items.jsonl does NOT exist →
    // 0 unread → "0 pending" (ok), NOT the daemon `except`→"Inbox unavailable".
    let root = makeTempDir()  // no notifications/inbox.jsonl
    let entry = await SwiftNativeCrashReportClient.inboxSubsystemEntry(in: root)
    #expect(entry.status == "ok")
    #expect(entry.detail == "0 pending")
}

@Test func inboxEntryWarnsAboveTen() async throws {
    // `inbox_status = "warn" if n_unread > 10 else "ok"` (L28770). 11 unread → warn.
    let root = makeTempDir()
    var items: [JSONValue] = []
    for i in 0..<11 {
        items.append(.object([
            "id": .string("u\(i)"),
            "created_at": .string(String(format: "2026-06-01T00:%02d:00Z", i)),
            "status": .string("unread"),
        ]))
    }
    let entry = await SwiftNativeCrashReportClient.inboxSubsystemEntry(in: root)
    _ = entry  // (placeholder so the helper is exercised even if writeInbox below changes)
    try writeInbox(root, items: items)
    let e2 = await SwiftNativeCrashReportClient.inboxSubsystemEntry(in: root)
    #expect(e2.status == "warn")
    #expect(e2.detail == "11 pending")
}

@Test func inboxEntryExactlyTenIsOk() async throws {
    // Boundary: n_unread == 10 → "ok" (the daemon uses strict `> 10`).
    let root = makeTempDir()
    var items: [JSONValue] = []
    for i in 0..<10 {
        items.append(.object([
            "id": .string("u\(i)"),
            "created_at": .string(String(format: "2026-06-01T00:%02d:00Z", i)),
            "status": .string("unread"),
        ]))
    }
    try writeInbox(root, items: items)
    let entry = await SwiftNativeCrashReportClient.inboxSubsystemEntry(in: root)
    #expect(entry.status == "ok")
    #expect(entry.detail == "10 pending")
}

@Test func inboxEntrySkipsUnparseableLines() async throws {
    // Unparseable JSONL lines are skipped (`except: pass`, the retired daemon;
    // readJSONL's compactMap try? parse drops them). Blank lines too. Here: 1
    // valid unread + 1 garbage line + 1 blank → n_unread 1.
    let root = makeTempDir()
    let raw = """
    {"id":"a","created_at":"2026-06-01T00:00:00Z","status":"unread"}
    not-json-at-all

    """
    try writeInbox(root, items: [], rawItemsText: raw)
    let entry = await SwiftNativeCrashReportClient.inboxSubsystemEntry(in: root)
    #expect(entry.detail == "1 pending")
}

@Test func inboxEntryCapsAtMostRecentThousand() async throws {
    // `list(unread_only=False, limit=1000)` sorts by created_at DESC and takes the
    // first 1000; health_card counts unread among THOSE. Here:
    // 1000 newest are "read", 5 OLDEST are "unread" → the 5 unread fall OUTSIDE the
    // 1000-cap → counted as 0. Proves the silent cap is reproduced.
    let root = makeTempDir()
    var items: [JSONValue] = []
    // 5 oldest unread (timestamps 2026-06-01T...): smaller minute → older.
    for i in 0..<5 {
        items.append(.object([
            "id": .string("old\(i)"),
            "created_at": .string(String(format: "2026-06-01T00:00:%02dZ", i)),
            "status": .string("unread"),
        ]))
    }
    // 1000 newer read items (year 2027 → lexicographically greater → newer).
    for i in 0..<1000 {
        items.append(.object([
            "id": .string("new\(i)"),
            "created_at": .string(String(format: "2027-01-01T%02d:%02d:00Z", i / 60, i % 60)),
            "status": .string("read"),
        ]))
    }
    try writeInbox(root, items: items)
    let entry = await SwiftNativeCrashReportClient.inboxSubsystemEntry(in: root)
    // The 5 unread are the oldest → excluded by the 1000-cap → 0 unread counted.
    #expect(entry.detail == "0 pending")
    #expect(entry.status == "ok")
}

@Test func inboxEntryEmptyIdRowsAreDropped() async throws {
    // A row with a missing/empty id cannot participate in last-write-wins
    // and is dropped from the count entirely.
    let root = makeTempDir()
    try writeInbox(root, items: [
        .object(["created_at": .string("2026-06-01T00:00:00Z"), "status": .string("unread")]),
        .object(["id": .string("b"), "created_at": .string("2026-06-01T00:01:00Z"), "status": .string("unread")]),
    ])
    let entry = await SwiftNativeCrashReportClient.inboxSubsystemEntry(in: root)
    #expect(entry.detail == "1 pending")   // only b; the id-less row is dropped
    #expect(entry.status == "ok")
}

@Test func inboxEntryActionsShapeNeverDropsRows() async throws {
    // A5.2: the live store has no InboxItem.from_dict parity layer — a weird
    // `actions` value never drops a row from the count. All five rows count.
    let root = makeTempDir()
    let rawText = [
        // truthy int actions → list(5) raises → DROPPED
        "{\"id\":\"a\",\"created_at\":\"2026-06-01T00:00:00Z\",\"status\":\"unread\",\"actions\":5}",
        // truthy bool actions → list(True) raises → DROPPED
        "{\"id\":\"b\",\"created_at\":\"2026-06-01T00:01:00Z\",\"status\":\"unread\",\"actions\":true}",
        // falsy 0 actions → `0 or []` → [] → kept
        "{\"id\":\"c\",\"created_at\":\"2026-06-01T00:02:00Z\",\"status\":\"unread\",\"actions\":0}",
        // proper list actions → kept
        "{\"id\":\"d\",\"created_at\":\"2026-06-01T00:03:00Z\",\"status\":\"unread\",\"actions\":[{\"id\":\"view\"}]}",
        // string actions → iterable → no raise → kept
        "{\"id\":\"e\",\"created_at\":\"2026-06-01T00:04:00Z\",\"status\":\"unread\",\"actions\":\"x\"}",
        "",
    ].joined(separator: "\n")
    try writeInbox(root, items: [], rawItemsText: rawText)
    let entry = await SwiftNativeCrashReportClient.inboxSubsystemEntry(in: root)
    #expect(entry.detail == "5 pending")
}

@Test func inboxEntryExistingButUnreadableYieldsFallback() async throws {
    // PARITY (gpt-5.5 wave-42 review finding #3): _load_all returns [] ONLY for a
    // MISSING items.jsonl (L264); an EXISTING-but-unreadable file lets read_text
    // raise → the health_card `except`→"Inbox unavailable" (ok) row (L28772). We
    // simulate an unreadable existing file with a stub persistence that throws
    // from readJSONL (a real chmod-000 file is flaky under the test runner's uid).
    let root = makeTempDir()
    let inboxDir = root.appendingPathComponent("notifications", isDirectory: true)
    try FileManager.default.createDirectory(at: inboxDir, withIntermediateDirectories: true)
    // Create the file so fileExists is true; the stub forces the read to throw.
    try Data("ignored".utf8).write(to: inboxDir.appendingPathComponent("inbox.jsonl"))
    let stub = _ThrowingJSONLPersistence()
    let entry = await SwiftNativeCrashReportClient.inboxSubsystemEntry(in: root, persistence: stub)
    #expect(entry.id == "inbox")
    #expect(entry.label == "Inbox")
    #expect(entry.status == "ok")
    #expect(entry.detail == "Inbox unavailable")
    #expect(entry.fixAction == nil)
}

@Test func inboxEntryMissingFileNotFallbackEvenWithThrowingStub() async throws {
    // Guard the missing-vs-unreadable split: a MISSING items.jsonl must short-
    // circuit to zero BEFORE readJSONL is consulted, so even a throwing stub must
    // yield "0 pending" (ok), NOT the "Inbox unavailable" fallback.
    let root = makeTempDir()  // no notifications/inbox.jsonl created
    let stub = _ThrowingJSONLPersistence()
    let entry = await SwiftNativeCrashReportClient.inboxSubsystemEntry(in: root, persistence: stub)
    #expect(entry.status == "ok")
    #expect(entry.detail == "0 pending")
}

@Test func inboxEntryStableSortTieBreakAtCapBoundary() async throws {
    // PARITY (gpt-5.5 wave-42 review finding #1): with equal created_at values
    // straddling the 1000-cap, the count must match Python's STABLE sort (original
    // file order preserved on ties). Construct 1001 items ALL with the SAME
    // created_at, where the FIRST (file-order) item is the only "read" and the rest
    // are "unread". Stable DESC sort keeps file order on the tie, so the first 1000
    // = item[0..1000) = the read one + 999 unread; the 1001st (an unread) is cut.
    // n_unread over the capped 1000 = 999. An UNSTABLE sort could instead drop a
    // different item and report 1000. Pinning 999 proves the tie-break.
    let root = makeTempDir()
    var items: [JSONValue] = []
    items.append(.object([
        "id": .string("first"),
        "created_at": .string("2026-06-01T00:00:00Z"),
        "status": .string("read"),
    ]))
    for i in 0..<1000 {
        items.append(.object([
            "id": .string("u\(i)"),
            "created_at": .string("2026-06-01T00:00:00Z"),   // SAME timestamp (tie)
            "status": .string("unread"),
        ]))
    }
    try writeInbox(root, items: items)
    let entry = await SwiftNativeCrashReportClient.inboxSubsystemEntry(in: root)
    // Stable order: [first(read), u0..u999]; first 1000 = first + u0..u998 → 999 unread.
    #expect(entry.detail == "999 pending")
    #expect(entry.status == "warn")
}

@Test func pythonListWouldRaiseMirrorsPythonListOrEmpty() async throws {
    // Pin the `list(value or [])` raise table. Falsy values hit
    // `or []` (no raise); truthy scalars (int/float/bool) raise; iterables don't.
    func r(_ v: JSONValue) -> Bool { SwiftNativeCrashReportClient.pythonListWouldRaise(v) }
    #expect(r(.null) == false)            // None → falsy → []
    #expect(r(.bool(false)) == false)     // False → falsy → []
    #expect(r(.bool(true)) == true)       // True → list(True) raises
    #expect(r(.int(0)) == false)          // 0 → falsy → []
    #expect(r(.int(5)) == true)           // truthy int → list(5) raises
    #expect(r(.double(0)) == false)       // 0.0 → falsy → []
    #expect(r(.double(2.5)) == true)      // truthy float → list(2.5) raises
    #expect(r(.string("")) == false)      // "" → falsy → []
    #expect(r(.string("x")) == false)     // truthy string IS iterable → list("x") ok
    #expect(r(.array([])) == false)       // iterable → ok
    #expect(r(.array([.int(1)])) == false)
    #expect(r(.object([:])) == false)     // iterable (dict) → ok
    #expect(r(.object(["k": .int(1)])) == false)
}

@Test func pythonStrGetMirrorsPythonStr() async throws {
    // `str(obj.get(key, default))` — pin the str-coercion building block.
    #expect(SwiftNativeCrashReportClient.pythonStrGet([:], "k", default: "d") == "d")  // absent → default
    func s(_ v: JSONValue) -> String {
        SwiftNativeCrashReportClient.pythonStrGet(["k": v], "k", default: "IGNORED")
    }
    #expect(s(.string("hi")) == "hi")
    #expect(s(.null) == "None")           // Python str(None) == "None"
    #expect(s(.bool(true)) == "True")     // Python str(True) == "True"
    #expect(s(.bool(false)) == "False")
    #expect(s(.int(42)) == "42")
    #expect(s(.double(1.0)) == "1.0")     // Python str(1.0) == "1.0"
    #expect(s(.double(2.5)) == "2.5")
}

// MARK: - GitStashRecover tests

@Test func gitStashRecoverHappyPath() async throws {
    let runner = _SubprocessStub()
    await runner.queue(exitCode: 0, stdout: "stash@{0}: WIP on main: my-label here\nstash@{1}: WIP on dev: other\n")
    await runner.queue(exitCode: 0, stdout: "Applied stash@{0}", stderr: "")
    let client = SwiftNativeGitStashRecoverClient(
        repoRoot: URL(fileURLWithPath: "/tmp/repo"),
        runner: runner,
        daemonAutonomy: true,
        policyProvider: { _permissiveAutonomyPolicy() }
    )
    let r = try await client.gitStashRecover(label: "my-label")
    #expect(r.ok == true)
    #expect(r.stashRef == "stash@{0}")
    #expect(r.output == "Applied stash@{0}")
}

@Test func gitStashRecoverEmptyLabelThrows() async throws {
    let runner = _SubprocessStub()
    let client = SwiftNativeGitStashRecoverClient(repoRoot: URL(fileURLWithPath: "/tmp/repo"), runner: runner, daemonAutonomy: true, policyProvider: { _permissiveAutonomyPolicy() })
    do {
        _ = try await client.gitStashRecover(label: "   ")
        Issue.record("expected missingLabel")
    } catch SystemOpsError.missingLabel {
    } catch {
        Issue.record("wrong error: \(error)")
    }
}

@Test func gitStashRecoverNotFoundThrows() async throws {
    let runner = _SubprocessStub()
    await runner.queue(exitCode: 0, stdout: "stash@{0}: WIP on main: something else\n")
    let client = SwiftNativeGitStashRecoverClient(repoRoot: URL(fileURLWithPath: "/tmp/repo"), runner: runner, daemonAutonomy: true, policyProvider: { _permissiveAutonomyPolicy() })
    do {
        _ = try await client.gitStashRecover(label: "nope-not-there")
        Issue.record("expected stashNotFound")
    } catch SystemOpsError.stashNotFound(let l) {
        #expect(l == "nope-not-there")
    } catch {
        Issue.record("wrong error: \(error)")
    }
}

@Test func gitStashRecoverPopFailureThrows() async throws {
    let runner = _SubprocessStub()
    await runner.queue(exitCode: 0, stdout: "stash@{0}: WIP on main: my-label\n")
    await runner.queue(exitCode: 1, stdout: "", stderr: "conflict")
    let client = SwiftNativeGitStashRecoverClient(repoRoot: URL(fileURLWithPath: "/tmp/repo"), runner: runner, daemonAutonomy: true, policyProvider: { _permissiveAutonomyPolicy() })
    do {
        _ = try await client.gitStashRecover(label: "my-label")
        Issue.record("expected stashPopFailed")
    } catch SystemOpsError.stashPopFailed(let msg) {
        #expect(msg.contains("conflict"))
    } catch {
        Issue.record("wrong error: \(error)")
    }
}

// MARK: - SystemRebuild tests

@Test func systemRebuildHappyPath() async throws {
    let tmp = makeTempDir()
    let scriptDir = tmp.appendingPathComponent("script", isDirectory: true)
    try FileManager.default.createDirectory(at: scriptDir, withIntermediateDirectories: true)
    let scriptPath = scriptDir.appendingPathComponent("install_app.sh")
    try Data("#!/bin/bash\necho ok\n".utf8).write(to: scriptPath)

    let runner = _SubprocessStub()
    // Isolate the cross-process rebuild lock per test — each tmp dir gets
    // its own .rebuild.lock. Production intentionally leaks the lock fd
    // (daemon dies mid-install in install_app.sh, matching Python L45185);
    // in-process tests would otherwise collide on the shared default-dataRoot
    // lock once the first happy-path test runs.
    let client = SwiftNativeSystemRebuildClient(repoRoot: tmp, runner: runner, daemonAutonomy: true, policyProvider: { _permissiveAutonomyPolicy() }, rebuildLock: RebuildLock(dataRoot: tmp))
    let r = try await client.systemRebuild()
    #expect(r.ok == true)
    #expect(r.message?.contains("Rebuild started") == true)

    let invocations = await runner.invocations
    #expect(invocations.count == 1)
    #expect(invocations.first?.executable == "/bin/bash")
    #expect(invocations.first?.arguments == [scriptPath.path])
    #expect(invocations.first?.detached == true)
}

@Test func systemRebuildScriptMissingThrows() async throws {
    let tmp = makeTempDir()
    let runner = _SubprocessStub()
    let client = SwiftNativeSystemRebuildClient(repoRoot: tmp, runner: runner, daemonAutonomy: true, policyProvider: { _permissiveAutonomyPolicy() }, rebuildLock: RebuildLock(dataRoot: tmp))
    do {
        _ = try await client.systemRebuild()
        Issue.record("expected scriptMissing")
    } catch SystemOpsError.scriptMissing(let p) {
        #expect(p.hasSuffix("install_app.sh"))
    } catch {
        Issue.record("wrong error: \(error)")
    }
}

@Test func systemRebuildIsDetached() async throws {
    let tmp = makeTempDir()
    let scriptDir = tmp.appendingPathComponent("script", isDirectory: true)
    try FileManager.default.createDirectory(at: scriptDir, withIntermediateDirectories: true)
    try Data("#!/bin/bash\n".utf8).write(to: scriptDir.appendingPathComponent("install_app.sh"))
    let runner = _SubprocessStub()
    let client = SwiftNativeSystemRebuildClient(repoRoot: tmp, runner: runner, daemonAutonomy: true, policyProvider: { _permissiveAutonomyPolicy() }, rebuildLock: RebuildLock(dataRoot: tmp))
    _ = try await client.systemRebuild()
    let invocations = await runner.invocations
    #expect(invocations.allSatisfy { $0.detached })
}

// MARK: - Factory routing

@Test func factoriesReturnSwiftNative() {
    #expect(makeRouterPlanClient() is SwiftNativeRouterPlanClient)
    #expect(makeSystemRebuildClient() is SwiftNativeSystemRebuildClient)
    #expect(makeGitStashRecoverClient() is SwiftNativeGitStashRecoverClient)
    #expect(makeCrashReportClient() is SwiftNativeCrashReportClient)
}

// MARK: - Production-gate refusal tests

@Test func systemRebuildRefusesByDefault() async throws {
    let tmp = makeTempDir()
    let scriptDir = tmp.appendingPathComponent("script", isDirectory: true)
    try FileManager.default.createDirectory(at: scriptDir, withIntermediateDirectories: true)
    try Data("#!/bin/bash\n".utf8).write(to: scriptDir.appendingPathComponent("install_app.sh"))
    let runner = _SubprocessStub()
    let client = SwiftNativeSystemRebuildClient(repoRoot: tmp, runner: runner)
    do {
        _ = try await client.systemRebuild()
        Issue.record("expected SystemOpsError.autonomyDenied")
    } catch SystemOpsError.autonomyDenied {
        // expected
    } catch {
        Issue.record("wrong error: \(error)")
    }
    let invocations = await runner.invocations
    #expect(invocations.isEmpty)
}

@Test func gitStashRecoverRefusesByDefault() async throws {
    let runner = _SubprocessStub()
    let client = SwiftNativeGitStashRecoverClient(repoRoot: URL(fileURLWithPath: "/tmp/repo"), runner: runner)
    do {
        _ = try await client.gitStashRecover(label: "anything")
        Issue.record("expected SystemOpsError.autonomyDenied")
    } catch SystemOpsError.autonomyDenied {
        // expected
    } catch {
        Issue.record("wrong error: \(error)")
    }
    let invocations = await runner.invocations
    #expect(invocations.isEmpty)
}

@Test func routerPlanToolCreationIsHighRiskRequiringApproval() async throws {
    let client = SwiftNativeRouterPlanClient()
    let r = try await client.planRoute(message: "create a tool to parse logs")
    #expect(r.goalType == "tool_creation")
    #expect(r.risk == "high")
    #expect(r.requiresApproval == true)
}

@Test func routerPlanToolProhibitionAndSlashProseStayMinimalChat() async throws {
    let client = SwiftNativeRouterPlanClient()
    let r = try await client.planRoute(
        message: "What does your current inner/body posture feel like? Please don't call a tool for this."
    )
    #expect(r.goalType == "chat")
    #expect(r.contextMode == "minimal")
    #expect(r.risk == "low")
    #expect(r.requiresApproval == false)
}

@Test func routerPlanExplicitCreationStillWinsBesideToolProhibition() async throws {
    let client = SwiftNativeRouterPlanClient()
    let r = try await client.planRoute(
        message: "Don't call a tool now; create a tool that can parse these logs."
    )
    #expect(r.goalType == "tool_creation")
    #expect(r.requiresApproval == true)
}

@Test func routerPlanExactCommunicationTokensRemainHighRisk() async throws {
    let client = SwiftNativeRouterPlanClient()
    let message = try await client.planRoute(message: "send that message for me")
    #expect(message.risk == "high")
    #expect(message.requiresApproval == true)

    let calendar = try await client.planRoute(message: "add this to my calendar")
    #expect(calendar.risk == "high")
    #expect(calendar.requiresApproval == true)
}

@Test func routerPlanWordFragmentsDoNotAllocateFileWork() async throws {
    let client = SwiftNativeRouterPlanClient()
    let profile = try await client.planRoute(message: "How does my profile look to you?")
    #expect(profile.goalType == "chat")
    #expect(profile.contextMode == "minimal")

    let file = try await client.planRoute(message: "Read the profile file for me")
    #expect(file.goalType == "file_work")
}

@Test func crashReportPruneSkipsNonRegularFiles() async throws {
    let dir = makeTempDir()
    let fm = FileManager.default
    for i in 0..<51 {
        let url = dir.appendingPathComponent("crash-2026-05-31T00-00-00-\(String(format: "%04d", i)).json")
        try Data("{}".utf8).write(to: url)
        let mtime = Date(timeIntervalSince1970: 1_700_000_000 + TimeInterval(i))
        try fm.setAttributes([.modificationDate: mtime], ofItemAtPath: url.path)
    }
    let fakeDir = dir.appendingPathComponent("crash-fake-dir.json", isDirectory: true)
    try fm.createDirectory(at: fakeDir, withIntermediateDirectories: true)

    SwiftNativeCrashReportClient.pruneOldCrashFiles(in: dir, keep: 50)

    #expect(fm.fileExists(atPath: fakeDir.path))
    var isDir: ObjCBool = false
    _ = fm.fileExists(atPath: fakeDir.path, isDirectory: &isDir)
    #expect(isDir.boolValue == true)
    let remaining = (try fm.contentsOfDirectory(at: dir, includingPropertiesForKeys: [.isRegularFileKey]))
        .filter { url in
            guard url.lastPathComponent.hasPrefix("crash-") && url.lastPathComponent.hasSuffix(".json") else { return false }
            let v = try? url.resourceValues(forKeys: [.isRegularFileKey])
            return v?.isRegularFile == true
        }
    #expect(remaining.count == 50)
}

// MARK: - Subsystem #17 wave 9 — CrashReport autonomous-improvement spawn

/// Test recorder for the `improvementSpawner` closure. Records every objective
/// it was called with and an optional throw-on-call flag.
final class _ImprovementSpawnRecorder: @unchecked Sendable {
    private let lock = NSLock()
    private var _objectives: [String] = []
    private var _shouldThrow: Bool = false

    var objectives: [String] {
        lock.lock(); defer { lock.unlock() }
        return _objectives
    }
    var callCount: Int { objectives.count }

    func setShouldThrow(_ value: Bool) {
        lock.lock(); defer { lock.unlock() }
        _shouldThrow = value
    }

    private func _record(_ objective: String) -> Bool {
        lock.lock(); defer { lock.unlock() }
        _objectives.append(objective)
        return _shouldThrow
    }

    func makeClosure() -> @Sendable (String) async throws -> Void {
        return { [self] objective in
            let shouldThrow = self._record(objective)
            if shouldThrow {
                throw SystemOpsError.subprocessFailed("mock spawn failure")
            }
        }
    }
}

/// Mutable clock for crash-throttle tests. Backed by a lock so test bodies can
/// advance time between `postCrashReport` calls and still satisfy the
/// `@Sendable` requirement on the `now:` closure.
final class _MutableClock: @unchecked Sendable {
    private let lock = NSLock()
    private var _date: Date

    init(_ date: Date) { self._date = date }

    func set(_ date: Date) {
        lock.lock(); defer { lock.unlock() }
        _date = date
    }

    func advance(by seconds: TimeInterval) {
        lock.lock(); defer { lock.unlock() }
        _date = _date.addingTimeInterval(seconds)
    }

    func nowClosure() -> @Sendable () -> Date {
        return { [self] in
            lock.lock(); defer { lock.unlock() }
            return _date
        }
    }
}

@Test func crashReportNoAutonomyNoSpawn() async throws {
    let dir = makeTempDir()
    let recorder = _ImprovementSpawnRecorder()
    let client = SwiftNativeCrashReportClient(
        crashReportsDir: dir,
        masterAutonomyEnabled: { false },
        improvementSpawner: recorder.makeClosure()
    )
    let r = try await client.postCrashReport(
        traceback: "Traceback (most recent call last):\n  RuntimeError: oops",
        stderrTail: "", exitCode: 1, capturedAt: "2026-05-31T00-00-00"
    )
    #expect(r.improvementSpawned == false)
    #expect(recorder.callCount == 0)
}

@Test func crashReportTrustDisabledNoSpawn() async throws {
    let dir = makeTempDir()
    let recorder = _ImprovementSpawnRecorder()
    let client = SwiftNativeCrashReportClient(
        crashReportsDir: dir,
        autonomyGate: { false },
        masterAutonomyEnabled: { true },
        improvementSpawner: recorder.makeClosure()
    )
    let r = try await client.postCrashReport(
        traceback: "Traceback: boom", stderrTail: "", exitCode: nil,
        capturedAt: "2026-05-31T00-00-00"
    )
    #expect(r.improvementSpawned == false)
    #expect(recorder.callCount == 0)
}

@Test func crashReportFirstCrashSpawns() async throws {
    let dir = makeTempDir()
    let recorder = _ImprovementSpawnRecorder()
    let clock = _MutableClock(Date(timeIntervalSince1970: 1_700_000_000))
    let client = SwiftNativeCrashReportClient(
        crashReportsDir: dir,
        now: clock.nowClosure(),
        autonomyGate: { true },
        masterAutonomyEnabled: { true },
        improvementSpawner: recorder.makeClosure()
    )
    let r = try await client.postCrashReport(
        traceback: "Traceback: detail line",
        stderrTail: "", exitCode: 1, capturedAt: "2026-05-31T00-00-00"
    )
    #expect(r.stored == true)
    #expect(r.improvementSpawned == true)
    #expect(recorder.callCount == 1)
    let obj = recorder.objectives[0]
    #expect(obj.contains("2026-05-31T00-00-00"))
    #expect(obj.contains("Traceback: detail line"))
}

@Test func crashReportThrottledWithin300s() async throws {
    let dir = makeTempDir()
    let recorder = _ImprovementSpawnRecorder()
    let clock = _MutableClock(Date(timeIntervalSince1970: 1_700_000_000))
    let client = SwiftNativeCrashReportClient(
        crashReportsDir: dir,
        now: clock.nowClosure(),
        autonomyGate: { true },
        masterAutonomyEnabled: { true },
        improvementSpawner: recorder.makeClosure()
    )
    let r1 = try await client.postCrashReport(
        traceback: "Traceback: a", stderrTail: "", exitCode: nil,
        capturedAt: "2026-05-31T00-00-00"
    )
    #expect(r1.improvementSpawned == true)
    clock.advance(by: 200)
    let r2 = try await client.postCrashReport(
        traceback: "Traceback: b", stderrTail: "", exitCode: nil,
        capturedAt: "2026-05-31T00-03-20"
    )
    #expect(r2.improvementSpawned == false)
    #expect(recorder.callCount == 1)
}

@Test func crashReportThrottleExpiresAfter300s() async throws {
    let dir = makeTempDir()
    let recorder = _ImprovementSpawnRecorder()
    let clock = _MutableClock(Date(timeIntervalSince1970: 1_700_000_000))
    let client = SwiftNativeCrashReportClient(
        crashReportsDir: dir,
        now: clock.nowClosure(),
        autonomyGate: { true },
        masterAutonomyEnabled: { true },
        improvementSpawner: recorder.makeClosure()
    )
    _ = try await client.postCrashReport(
        traceback: "Traceback: first", stderrTail: "", exitCode: nil,
        capturedAt: "2026-05-31T00-00-00"
    )
    clock.advance(by: 301)
    let r2 = try await client.postCrashReport(
        traceback: "Traceback: second", stderrTail: "", exitCode: nil,
        capturedAt: "2026-05-31T00-05-01"
    )
    #expect(r2.improvementSpawned == true)
    #expect(recorder.callCount == 2)
}

@Test func crashReportEmptyTracebackNoSpawn() async throws {
    let dir = makeTempDir()
    let recorder = _ImprovementSpawnRecorder()
    let client = SwiftNativeCrashReportClient(
        crashReportsDir: dir,
        autonomyGate: { true },
        masterAutonomyEnabled: { true },
        improvementSpawner: recorder.makeClosure()
    )
    let r = try await client.postCrashReport(
        traceback: "   \n  \t  ", stderrTail: "", exitCode: nil,
        capturedAt: "2026-05-31T00-00-00"
    )
    #expect(r.stored == true)
    #expect(r.improvementSpawned == false)
    #expect(recorder.callCount == 0)
}

@Test func crashReportSpawnFailureDoesNotThrow() async throws {
    let dir = makeTempDir()
    let recorder = _ImprovementSpawnRecorder()
    recorder.setShouldThrow(true)
    let client = SwiftNativeCrashReportClient(
        crashReportsDir: dir,
        autonomyGate: { true },
        masterAutonomyEnabled: { true },
        improvementSpawner: recorder.makeClosure()
    )
    let r = try await client.postCrashReport(
        traceback: "Traceback: kapow", stderrTail: "", exitCode: 1,
        capturedAt: "2026-05-31T00-00-00"
    )
    #expect(r.stored == true)
    #expect(r.improvementSpawned == false)
    #expect(recorder.callCount == 1)
}

@Test func crashReportThrottleAdvancesEvenOnFailure() async throws {
    let dir = makeTempDir()
    let recorder = _ImprovementSpawnRecorder()
    recorder.setShouldThrow(true)
    let clock = _MutableClock(Date(timeIntervalSince1970: 1_700_000_000))
    let client = SwiftNativeCrashReportClient(
        crashReportsDir: dir,
        now: clock.nowClosure(),
        autonomyGate: { true },
        masterAutonomyEnabled: { true },
        improvementSpawner: recorder.makeClosure()
    )
    _ = try await client.postCrashReport(
        traceback: "Traceback: a", stderrTail: "", exitCode: nil,
        capturedAt: "2026-05-31T00-00-00"
    )
    #expect(recorder.callCount == 1)
    clock.advance(by: 200)
    _ = try await client.postCrashReport(
        traceback: "Traceback: b", stderrTail: "", exitCode: nil,
        capturedAt: "2026-05-31T00-03-20"
    )
    // Throttle advanced before the call, so second attempt within 300s is suppressed.
    #expect(recorder.callCount == 1)
}

@Test func crashReportObjectiveFormatMatchesPython() async throws {
    let dir = makeTempDir()
    let recorder = _ImprovementSpawnRecorder()
    let client = SwiftNativeCrashReportClient(
        crashReportsDir: dir,
        autonomyGate: { true },
        masterAutonomyEnabled: { true },
        improvementSpawner: recorder.makeClosure()
    )
    _ = try await client.postCrashReport(
        traceback: "trace-X",
        stderrTail: "", exitCode: nil,
        capturedAt: "2026-05-31T00-00-00"
    )
    #expect(recorder.callCount == 1)
    // R23: objective wording de-daemoned (the app process IS the runtime);
    // structure (header/traceback/footer) still matches the Python original.
    let expected =
        "Fix the app crash captured at 2026-05-31T00-00-00. The traceback is:\n"
        + "trace-X\n\n"
        + "Read recent activity, audit the module that crashed, propose a fix in a worktree, "
        + "run ./script/test.sh to verify."
    #expect(recorder.objectives[0] == expected)
}

@Test func crashReportObjectiveTracebackCapped3000() async throws {
    let dir = makeTempDir()
    let recorder = _ImprovementSpawnRecorder()
    let client = SwiftNativeCrashReportClient(
        crashReportsDir: dir,
        autonomyGate: { true },
        masterAutonomyEnabled: { true },
        improvementSpawner: recorder.makeClosure()
    )
    // 5000 'a' chars — well under the 8000 prefix cap in postCrashReport, well
    // over the 3000-char objective cap. No regex hits in `aaaa...` so the
    // redacted output equals the input.
    let bigTraceback = String(repeating: "a", count: 5000)
    _ = try await client.postCrashReport(
        traceback: bigTraceback, stderrTail: "", exitCode: nil,
        capturedAt: "2026-05-31T00-00-00"
    )
    #expect(recorder.callCount == 1)
    let obj = recorder.objectives[0]
    // Slice out the traceback substring between the "is:\n" marker and the
    // trailing "\n\nRead recent activity" footer.
    let header = "Fix the app crash captured at 2026-05-31T00-00-00. The traceback is:\n"
    let footer = "\n\nRead recent activity, audit the module that crashed, propose a fix in a worktree, run ./script/test.sh to verify."
    #expect(obj.hasPrefix(header))
    #expect(obj.hasSuffix(footer))
    let middle = String(obj.dropFirst(header.count).dropLast(footer.count))
    #expect(middle.count == 3000)
    #expect(middle.allSatisfy { $0 == "a" })
}

// MARK: - Wave-11 capability scoring tests

private func _capObjString(_ entry: JSONValue, _ key: String) -> String? {
    guard case .object(let obj) = entry else { return nil }
    guard case .string(let s) = obj[key] ?? .null else { return nil }
    return s
}

private func _capObjArray(_ entry: JSONValue, _ key: String) -> [JSONValue]? {
    guard case .object(let obj) = entry else { return nil }
    guard case .array(let a) = obj[key] ?? .null else { return nil }
    return a
}

private func _capObjDouble(_ entry: JSONValue, _ key: String) -> Double? {
    guard case .object(let obj) = entry else { return nil }
    if case .double(let d) = obj[key] ?? .null { return d }
    if case .int(let i) = obj[key] ?? .null { return Double(i) }
    return nil
}

@Test func capabilityRecordsCountMatchesFeaturesPlusActions() throws {
    let recs = swiftNativeCapabilityRecords(nowISO: "2026-05-31T00:00:00+00:00")
    #expect(recs.count == featureSurfaceRecordsCount + connectorActionDescriptorsCount)
}

@Test func scoreContextCapabilityMemoryParity() throws {
    let recs = swiftNativeCapabilityRecords(nowISO: "2026-05-31T00:00:00+00:00")
    guard let memory = recs.first(where: { $0.id == "feature:memory_system" }) else {
        Issue.record("memory_system record missing")
        return
    }
    let parts = scoreContextCapabilityParts(memory, message: "I want memory recall", mode: "memory")
    #expect(parts.reasons.contains("trigger:memory"))
    #expect(parts.reasons.contains("trigger:recall"))
    #expect(parts.reasons.contains("mode:memory"))
    #expect(parts.score > 0)
}

@Test func selectContextCapabilitiesMinimalLimitDefault() throws {
    let recs = swiftNativeCapabilityRecords(nowISO: "2026-05-31T00:00:00+00:00")
    let r = selectContextCapabilities(
        records: recs,
        message: "workflow tool memory remember research chat command center status",
        mode: "minimal"
    )
    #expect(r.count <= 2)
    #expect(r.count > 0)
}

@Test func selectContextCapabilitiesCapabilityLimitDefault() throws {
    let recs = swiftNativeCapabilityRecords(nowISO: "2026-05-31T00:00:00+00:00")
    let r = selectContextCapabilities(
        records: recs,
        message: "workflow tool memory remember research chat command center status",
        mode: "capability"
    )
    #expect(r.count <= 8)
}

@Test func selectContextCapabilitiesFullLimitDefault() throws {
    let recs = swiftNativeCapabilityRecords(nowISO: "2026-05-31T00:00:00+00:00")
    let r = selectContextCapabilities(records: recs, message: "qxzpv blarg nomatch", mode: "full")
    #expect(r.count <= 18)
    #expect(r.count > 0)
}

@Test func selectContextCapabilitiesDropsZeroScoreOutsideFull() throws {
    let recs = swiftNativeCapabilityRecords(nowISO: "2026-05-31T00:00:00+00:00")
    let nonFull = selectContextCapabilities(records: recs, message: "qxzpv blarg nomatch", mode: "capability")
    for entry in nonFull {
        if let s = _capObjDouble(entry, "score") {
            #expect(s > 0)
        }
    }
}

@Test func selectContextCapabilitiesSortsByScoreThenStatusDescending() throws {
    let a = CapabilityScoringRecord(
        id: "feature:synth_a", sourceId: "synth_a", name: "Synth A",
        kind: "feature", status: "active",
        description: "Alpha trigger gamma.",
        triggers: ["alpha", "gamma"], permissions: [], riskClass: "read_only",
        endpoints: [], useCount: 0
    )
    let b = CapabilityScoringRecord(
        id: "feature:synth_b", sourceId: "synth_b", name: "Synth B",
        kind: "feature", status: "ready",
        description: "Alpha trigger gamma.",
        triggers: ["alpha", "gamma"], permissions: [], riskClass: "read_only",
        endpoints: [], useCount: 0
    )
    let r = selectContextCapabilities(records: [a, b], message: "alpha gamma", mode: "full")
    #expect(r.count == 2)
    #expect(_capObjString(r[0], "status") == "ready")
    #expect(_capObjString(r[1], "status") == "active")
}

@Test func selectContextCapabilitiesTruncatesFields() throws {
    let longDesc = String(repeating: "X", count: 800)
    let manyTriggers = (0..<12).map { "t\($0)" }
    let manyPerms = (0..<10).map { "p\($0)" }
    let manyEndpoints = (0..<10).map { "/v1/e\($0)" }
    let rec = CapabilityScoringRecord(
        id: "feature:synth_big", sourceId: "synth_big", name: "Synth Big",
        kind: "feature", status: "ready",
        description: longDesc,
        triggers: manyTriggers, permissions: manyPerms, riskClass: "read_only",
        endpoints: manyEndpoints, useCount: 0
    )
    let r = selectContextCapabilities(records: [rec], message: "synth big", mode: "full")
    #expect(r.count == 1)
    #expect(_capObjString(r[0], "description")?.count == 500)
    #expect(_capObjArray(r[0], "triggers")?.count == 6)
    #expect(_capObjArray(r[0], "permissions")?.count == 6)
    #expect(_capObjArray(r[0], "endpoints")?.count == 6)
    if let matched = _capObjArray(r[0], "matchedTerms") {
        #expect(matched.count <= 8)
    }
}

@Test func selectContextCapabilitiesFallbackRankingFullMode() throws {
    // kind="zzz_no_bias" + status="draft" → no kind/source bias, no status bonus,
    // no name match, no trigger substring → reasons stays empty → selectionReasons
    // falls back to ["fallback ranking"]. Mode "full" keeps the zero-score row.
    let rec = CapabilityScoringRecord(
        id: "synth:zero", sourceId: "zero", name: "Synth Zero",
        kind: "zzz_no_bias", status: "draft",
        description: "qqqq.",
        triggers: ["qqqqtrig"], permissions: [], riskClass: "read_only",
        endpoints: [], useCount: 0
    )
    let r = selectContextCapabilities(records: [rec], message: "totally unrelated", mode: "full")
    #expect(r.count == 1)
    guard let reasons = _capObjArray(r[0], "selectionReasons") else {
        Issue.record("selectionReasons missing")
        return
    }
    #expect(reasons.count == 1)
    if case .string(let s) = reasons[0] {
        #expect(s == "fallback ranking")
    } else {
        Issue.record("selectionReasons[0] not string")
    }
}

@Test func routerPlanWiresMatchedCapabilitiesEndToEnd() async throws {
    let client = SwiftNativeRouterPlanClient()
    let r = try await client.planRoute(message: "please update my memory")
    #expect(!r.matchedCapabilities.isEmpty)
    let ids: [String] = r.matchedCapabilities.compactMap { _capObjString($0, "id") }
    #expect(ids.contains("feature:memory_system"))
}

@Test func routerPlanHasMatchDrivesChatBranch() async throws {
    let client = SwiftNativeRouterPlanClient()
    let r = try await client.planRoute(message: "command center status overview")
    #expect(r.goalType == "chat")
    #expect(!r.matchedCapabilities.isEmpty)
    #expect(r.nextActions.contains("Load matched capability only for this turn"))
    #expect(r.nextActions.contains("Record usage metadata"))
}

@Test func routerPlanNoMatchChatBranch() async throws {
    // Faithfulness gate against Python L15238 (select_context_capabilities):
    // every FeatureSurfaceRecord ships with status="ready", which earns the
    // unconditional +0.3 status bonus in score_context_capability. So even a
    // nonsense message scores 0.3 on every feature record and survives the
    // `score <= 0` filter (filter is < strictly, not <=). matchedCapabilities
    // is NEVER empty in capability-mode when feature records are in the input
    // set — Python behaves the same way. What we CAN assert is: every entry
    // in this no-genuine-match case has selectionReasons == ["fallback
    // ranking"] (no triggers, no name-match, no mode-bias hits) and a score
    // of exactly 0.3 (just the status bonus).
    let client = SwiftNativeRouterPlanClient()
    // Avoid the letter `x` (and other 1-char letters used as standalone
    // triggers by connector actions like x.status / x.me / x.search_recent)
    // so the scorer's trigger-substring check produces zero hits.
    let r = try await client.planRoute(message: "qpzrn blarg")
    #expect(r.goalType == "chat")
    // Capability-mode default limit is 8; with only the +0.3 status bonus
    // surviving the filter, we expect a non-empty matched list of fallback-
    // ranked entries.
    #expect(!r.matchedCapabilities.isEmpty)
    for cap in r.matchedCapabilities {
        guard case .object(let obj) = cap else {
            Issue.record("capability entry not an object")
            continue
        }
        // Every entry should be a pure fallback rank — no triggers, no name,
        // no mode-bias matched.
        if case .array(let reasons) = obj["selectionReasons"] ?? .null {
            #expect(reasons.count == 1)
            if case .string(let r0) = reasons.first ?? .null {
                #expect(r0 == "fallback ranking")
            } else {
                Issue.record("selectionReasons[0] not string")
            }
        } else {
            Issue.record("selectionReasons missing")
        }
        // Pure status-bonus score: 1.2 * 0 (no overlap) + 0.3 (status=ready).
        if case .double(let s) = obj["score"] ?? .null {
            #expect(s == 0.3)
        } else {
            Issue.record("score not double")
        }
        // matchedTerms must be empty — no token overlap.
        if case .array(let terms) = obj["matchedTerms"] ?? .null {
            #expect(terms.isEmpty)
        } else {
            Issue.record("matchedTerms missing")
        }
    }
}

@Test func capabilityRecordsPreSortedByUpdatedAtDesc() async throws {
    // Python L15742 pre-sorts records by (updatedAt or name) DESC before
    // select_context_capabilities sees them. The later score-sort is
    // STABLE so pre-sort order is the final tie-breaker on equal
    // score+status rows. Feature records all share `now` for updatedAt,
    // so the tie-breaker for them is name DESC.
    let now = "2026-05-31T00:00:00.000000+00:00"
    let records = swiftNativeCapabilityRecords(nowISO: now)
    // First 19 entries should be the feature records (all share `now` for
    // updatedAt) ordered by name DESC as the tie-breaker.
    let featureRecords = records.prefix(19)
    let names = featureRecords.map { $0.name }
    let sortedNames = names.sorted(by: >)
    #expect(names == sortedNames)
}

@Test func connectorActionStatusReflectsNativeConnectorSet() async throws {
    let now = "2026-05-31T00:00:00.000000+00:00"
    let records = swiftNativeCapabilityRecords(nowISO: now)
    // Find a known native connector action (local_files.search) — should be active.
    let lf = records.first { $0.id == "connector_action:local_files.search" }
    #expect(lf != nil)
    #expect(lf?.status == "active")
    // Find a known non-native connector action (gmail.list_inbox) — should be needs_setup.
    let gm = records.first { $0.id == "connector_action:gmail.list_inbox" }
    if gm != nil {
        #expect(gm?.status == "needs_setup")
    }
    // Slack has a native Swift connector executor; auth health is layered elsewhere.
    let sk = records.first { $0.id == "connector_action:slack.post_message" }
    if sk != nil {
        #expect(sk?.status == "active")
    }
}

// MARK: - Wave 31 — ProductionMigrationPlan parity tests

@Test func migrationPlanMatchesPythonStaticShape() async throws {
    let fixedNow = Date(timeIntervalSince1970: 1_700_000_000)
    let client = SwiftNativeProductionMigrationPlanClient(now: { fixedNow })
    let result = try await client.migrationPlan()
    guard case .object(let obj) = result.toJSON() else {
        Issue.record("migration plan is not an object"); return
    }
    // Static fields are byte-accurate against the retired daemon.
    if case .string(let id) = obj["id"] ?? .null { #expect(id == "nativeagent-production-migration-v1") }
    else { Issue.record("missing id") }
    if case .string(let status) = obj["status"] ?? .null { #expect(status == "ready") }
    else { Issue.record("missing status") }
    guard case .array(let steps) = obj["steps"] ?? .null else {
        Issue.record("steps not an array"); return
    }
    #expect(steps.count == 5)
    // Step ids + statuses in order.
    let expected: [(String, String)] = [
        ("backup", "available"),
        ("export", "available"),
        ("install", "planned"),
        ("daemon_lifecycle", "available"),
        ("verify", "available"),
    ]
    for (i, step) in steps.enumerated() {
        guard case .object(let s) = step,
              case .string(let sid) = s["id"] ?? .null,
              case .string(let sstatus) = s["status"] ?? .null else {
            Issue.record("step \(i) malformed"); continue
        }
        #expect(sid == expected[i].0)
        #expect(sstatus == expected[i].1)
    }
    // createdAt comes from the injected clock.
    #expect(result.createdAt == SwiftNativeRouterPlanClient.isoTimestamp(fixedNow))
}

// MARK: - Wave 31 — ProductionExports parity tests

private func writeRegistry(_ value: JSONValue, into dir: URL) -> URL {
    let path = dir.appendingPathComponent("registry.json")
    let data = (try? value.serializedData(pretty: false)) ?? Data("[]".utf8)
    try? data.write(to: path)
    return path
}

@Test func productionExportsSortsByCreatedAtDescending() async throws {
    let dir = makeTempDir()
    let registry = JSONValue.array([
        .object(["id": .string("a"), "createdAt": .string("2026-05-01T00:00:00.000000+00:00"), "kind": .string("export")]),
        .object(["id": .string("b"), "createdAt": .string("2026-05-03T00:00:00.000000+00:00"), "kind": .string("support")]),
        .object(["id": .string("c"), "createdAt": .string("2026-05-02T00:00:00.000000+00:00"), "kind": .string("export")]),
    ])
    let path = writeRegistry(registry, into: dir)
    let client = SwiftNativeProductionExportsClient(registryPath: path)
    let receipts = try await client.listExports()
    #expect(receipts.count == 3)
    // DESC by createdAt → b, c, a.
    func idOf(_ r: ProductionExportReceipt) -> String {
        if case .object(let o) = r.toJSON(), case .string(let s) = o["id"] ?? .null { return s }
        return ""
    }
    #expect(idOf(receipts[0]) == "b")
    #expect(idOf(receipts[1]) == "c")
    #expect(idOf(receipts[2]) == "a")
}

@Test func productionExportsMissingFileReturnsEmpty() async throws {
    let dir = makeTempDir()
    // Point at a non-existent registry.json — read_json(path, []) → [].
    let path = dir.appendingPathComponent("does-not-exist.json")
    let client = SwiftNativeProductionExportsClient(registryPath: path)
    let receipts = try await client.listExports()
    #expect(receipts.isEmpty)
}

@Test func productionExportsNonListPayloadReturnsEmpty() async throws {
    let dir = makeTempDir()
    // Python: `if not isinstance(exports, list): return []`.
    let path = writeRegistry(.object(["unexpected": .string("shape")]), into: dir)
    let client = SwiftNativeProductionExportsClient(registryPath: path)
    let receipts = try await client.listExports()
    #expect(receipts.isEmpty)
}

@Test func productionExportsPreservesAllReceiptFields() async throws {
    let dir = makeTempDir()
    let registry = JSONValue.array([
        .object([
            "id": .string("x1"),
            "kind": .string("support"),
            "path": .string("/tmp/x1.tar.gz"),
            "scope": .array([.string("trust"), .string("catalog")]),
            "checksum": .string("deadbeef"),
            "sizeBytes": .int(4096),
            "createdAt": .string("2026-05-05T00:00:00.000000+00:00"),
        ]),
    ])
    let path = writeRegistry(registry, into: dir)
    let client = SwiftNativeProductionExportsClient(registryPath: path)
    let receipts = try await client.listExports()
    #expect(receipts.count == 1)
    guard case .object(let o) = receipts[0].toJSON() else {
        Issue.record("receipt not an object"); return
    }
    if case .string(let p) = o["path"] ?? .null { #expect(p == "/tmp/x1.tar.gz") }
    else { Issue.record("path not preserved") }
    if case .string(let c) = o["checksum"] ?? .null { #expect(c == "deadbeef") }
    else { Issue.record("checksum not preserved") }
    if case .int(let sz) = o["sizeBytes"] ?? .null { #expect(sz == 4096) }
    else { Issue.record("sizeBytes not preserved") }
    if case .array(let scope) = o["scope"] ?? .null { #expect(scope.count == 2) }
    else { Issue.record("scope not preserved") }
}

@Test func productionExportsEmptyCreatedAtStableTieBreak() async throws {
    let dir = makeTempDir()
    // Two rows missing createdAt → both sort key "" → registry order preserved.
    let registry = JSONValue.array([
        .object(["id": .string("first")]),
        .object(["id": .string("second")]),
    ])
    let path = writeRegistry(registry, into: dir)
    let client = SwiftNativeProductionExportsClient(registryPath: path)
    let receipts = try await client.listExports()
    func idOf(_ r: ProductionExportReceipt) -> String {
        if case .object(let o) = r.toJSON(), case .string(let s) = o["id"] ?? .null { return s }
        return ""
    }
    #expect(idOf(receipts[0]) == "first")
    #expect(idOf(receipts[1]) == "second")
}

// MARK: - SystemSubprocessRunner bounded-run regression (audit fix 2026-07-21)
//
// The old impl ran waitUntilExit() and only THEN drained the pipes — a child
// writing >64KB blocked on a full pipe and never exited; the deadline fired
// terminate() once with no SIGKILL escalation; and the deadline task was
// cancelled before the drains, so a grandchild holding the FDs hung the read
// unwatched. These tests pin the concurrent-drain + TERM→KILL contract.

@Test func systemSubprocessRunner_drainsLargeOutputWithoutDeadlock() async throws {
    let runner = SystemSubprocessRunner()
    // ~300KB stdout — far past the 64KB pipe buffer. The old read-after-wait
    // shape deadlocked here (child blocked on write, waitUntilExit never
    // returned). Wall-clock bound below is a gross-regression tripwire, not
    // a perf assertion.
    let start = Date()
    let result = try await runner.run(
        executable: "/usr/bin/python3",
        arguments: ["-c", "import sys; sys.stdout.write('x' * 300000); sys.stderr.write('y' * 70000)"],
        cwd: nil,
        timeout: 30,
        detached: false
    )
    #expect(result.exitCode == 0)
    #expect(result.stdout.count == 300000)
    #expect(result.stderr.count == 70000)
    #expect(Date().timeIntervalSince(start) < 60)
}

@Test func systemSubprocessRunner_timeoutEscalatesTermToKill() async throws {
    let runner = SystemSubprocessRunner()
    // Child IGNORES SIGTERM — the watchdog must escalate to SIGKILL after the
    // grace or run() never returns.
    let start = Date()
    let result = try await runner.run(
        executable: "/bin/bash",
        arguments: ["-c", "trap '' TERM; sleep 120"],
        cwd: nil,
        timeout: 1,
        detached: false
    )
    let elapsed = Date().timeIntervalSince(start)
    #expect(result.exitCode != 0)
    // timeout(1s) + kill grace(2s) + drain grace(≤2s each) ≈ 5s worst case;
    // 30s is the structural tripwire that proves escalation ran.
    #expect(elapsed < 30)
}
