// U5 W-A "honest client" (2026-06-11) — tests for the three mechanisms the
// wave ships:
//
//   1. Honest JSONL reads (NativeClient.readJSONLHonest): missing file is
//      legitimate healthy-empty; a file WITH bytes that parses to zero rows
//      is corrupt and must THROW, never render as an empty panel. Plus the
//      inbox status-write path: a corrupt inbox returns false and the file
//      is left untouched (no silent drop, no rewrite).
//
//   2. Generic approval crash-window reconcile
//      (NativeClient.reconcileUnappliedApprovalExecutions): resolved
//      records lacking an executedAction annotation get their executor
//      re-fired on launch; annotated/pending records are skipped; the
//      self_improvement eligibility hook skips denied/canceled; the
//      browser preflight (terminalBrowserRun) caps approved re-fires at
//      once by healing the annotation from a terminal runs.json row
//      WITHOUT re-opening the URL.
//
//   3. fullMacGrantIsActive display == the REAL gate
//      (MacControlGate.fullMacActive) across the devMode × expiry matrix —
//      pinning the 9a fix: devMode must NOT make the display claim "full"
//      while the gate sweeps the tools.
//
// All roots are tmp dirs — no production data is touched.
import Foundation
import Testing
import ApprovalInbox
import Browser
import MacControl
import NativeAgentCore
import PersistenceCore
@testable import NativeAgentApp

// MARK: - helpers

private func makeU5TempRoot() throws -> URL {
    let url = FileManager.default.temporaryDirectory
        .appendingPathComponent("U5HonestClientTests-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
    return url
}

private func isoNow(offset: TimeInterval = 0) -> String {
    let fmt = ISO8601DateFormatter()
    fmt.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
    return fmt.string(from: Date().addingTimeInterval(offset))
}

/// Create a pending approval and resolve it through the real inbox actor
/// (the resolve path that does NOT run executors), producing the exact
/// "resolved + unannotated" crash-window shape the reconcile scans for.
private func makeResolvedUnannotated(
    root: URL,
    action: String,
    decision: ApprovalDecision,
    payload: JSONValue = .object([:])
) async throws -> ApprovalRecord {
    let inbox = SwiftNativeApprovalInbox(root: root)
    let created = try await inbox.create(.object([
        "title": .string("test \(action)"),
        "action": .string(action),
        "risk": .string("medium"),
        "reason": .string("crash-window fixture"),
        "payload": payload,
    ]))
    return try await inbox.resolve(created.id, decision: decision, decidedBy: "test")
}

/// Recording executor for injected reconcile kinds.
private actor ReconcileRecorder {
    private(set) var executedIds: [String] = []
    func record(_ id: String) { executedIds.append(id) }
}

@MainActor
private final class BrowserCancelProbe {
    var calls: [String] = []
}

private func approvalRequestsPath(root: URL) -> URL {
    root
        .appendingPathComponent("workflows", isDirectory: true)
        .appendingPathComponent("approvals", isDirectory: true)
        .appendingPathComponent("requests.json")
}

@Test @MainActor
func browserActiveRunRegistryTargetsExactRunAndProtectsReplacement() {
    let registry = BrowserActiveRunRegistry()
    let probe = BrowserCancelProbe()
    let oldToken = registry.register(runID: "run-a") { probe.calls.append("old-a") }
    _ = registry.register(runID: "run-b") { probe.calls.append("b") }

    #expect(registry.cancel(runID: "run-a"))
    #expect(probe.calls == ["old-a"])
    #expect(registry.contains(runID: "run-b"))

    let newToken = registry.register(runID: "run-a") { probe.calls.append("new-a") }
    registry.unregister(runID: "run-a", token: oldToken)
    #expect(registry.contains(runID: "run-a"))
    #expect(registry.cancel(runID: "run-a"))
    #expect(probe.calls == ["old-a", "new-a"])

    registry.unregister(runID: "run-a", token: newToken)
    #expect(!registry.contains(runID: "run-a"))
}

@Test
func browserRunningStatePersistsBeforeTerminalReceipts() async throws {
    let root = try makeU5TempRoot()
    defer { try? FileManager.default.removeItem(at: root) }
    let browserRoot = root.appendingPathComponent("native_power/browser", isDirectory: true)
    let browser = SwiftNativeBrowserClient(
        runsPath: browserRoot.appendingPathComponent("runs.json"),
        receiptsPath: browserRoot.appendingPathComponent("receipts.jsonl"),
        profileDir: browserRoot.appendingPathComponent("profile", isDirectory: true),
        sourcesDir: browserRoot.appendingPathComponent("sources", isDirectory: true),
        screenshotsDir: browserRoot.appendingPathComponent("screenshots", isDirectory: true),
        trustPolicyPath: root.appendingPathComponent("trust/policy.json")
    )
    let start = BrowserOperationStart(
        id: "live-run",
        url: "https://example.com",
        domain: "example.com",
        initialState: .running,
        visible: true,
        deadlineSeconds: 30
    )
    _ = try await browser.executeBrowserOperation(.start(start))

    let raw = try JSONValue.parse(Data(contentsOf: browser.runsPath))
    guard case .array(let rows) = raw else {
        Issue.record("expected browser runs array")
        return
    }
    #expect(rows.count == 1)
    #expect(NativeClient.jsonString(rows[0], "id") == "live-run")
    #expect(NativeClient.jsonString(rows[0], "status") == "running")
    #expect(!FileManager.default.fileExists(atPath: browser.receiptsPath.path))
}

@Test
func browserCanceledStateCannotBeOverwrittenByLateCompletion() async throws {
    let root = try makeU5TempRoot()
    defer { try? FileManager.default.removeItem(at: root) }
    let browserRoot = root.appendingPathComponent("native_power/browser", isDirectory: true)
    let browser = SwiftNativeBrowserClient(
        runsPath: browserRoot.appendingPathComponent("runs.json"),
        receiptsPath: browserRoot.appendingPathComponent("receipts.jsonl"),
        profileDir: browserRoot.appendingPathComponent("profile", isDirectory: true),
        sourcesDir: browserRoot.appendingPathComponent("sources", isDirectory: true),
        screenshotsDir: browserRoot.appendingPathComponent("screenshots", isDirectory: true),
        trustPolicyPath: root.appendingPathComponent("trust/policy.json")
    )
    let start = BrowserOperationStart(
        id: "race-run",
        url: "https://example.com",
        domain: "example.com",
        initialState: .running,
        visible: true,
        deadlineSeconds: 30
    )
    let digest = SwiftNativeBrowserClient.browserRequestDigest(for: start)
    _ = try await browser.executeBrowserOperation(.start(start))

    let canceled = try #require(try await browser.cancelBrowserRun(body: .object([
        "id": .string("race-run"),
    ])))
    #expect(NativeClient.jsonString(canceled, "status") == "canceled")

    let committed = try #require(try await browser.executeBrowserOperation(.complete(.init(
        id: "race-run",
        requestDigest: digest,
        state: .succeeded,
        opened: true
    ))).run)
    #expect(NativeClient.jsonString(committed, "status") == "canceled")
    #expect(NativeClient.jsonString(committed, "canceledAt") != nil)

    let raw = try JSONValue.parse(Data(contentsOf: browser.runsPath))
    guard case .array(let rows) = raw else {
        Issue.record("expected browser runs array")
        return
    }
    #expect(rows.count == 1)
    #expect(NativeClient.jsonString(rows[0], "status") == "canceled")
    #expect(NativeClient.jsonString(rows[0], "canceledAt") != nil)
}

/// Patch an executedAction annotation directly into the fixture
/// requests.json (the annotate helper is file-private to NativeClient).
private func stampExecutedAction(root: URL, id: String) throws {
    let path = approvalRequestsPath(root: root)
    let data = try Data(contentsOf: path)
    guard var rows = try JSONSerialization.jsonObject(with: data) as? [[String: Any]] else {
        throw NSError(domain: "U5Tests", code: 1, userInfo: [
            NSLocalizedDescriptionKey: "requests.json is not an array"])
    }
    for idx in rows.indices where (rows[idx]["id"] as? String) == id {
        rows[idx]["executedAction"] = ["op": "test_stamp"]
    }
    let out = try JSONSerialization.data(withJSONObject: rows)
    try out.write(to: path, options: .atomic)
}

private func loadApprovalRow(root: URL, id: String) throws -> [String: Any]? {
    let data = try Data(contentsOf: approvalRequestsPath(root: root))
    let rows = try JSONSerialization.jsonObject(with: data) as? [[String: Any]]
    return rows?.first { ($0["id"] as? String) == id }
}

// MARK: - 1. honest JSONL reads

@Test
func readJSONLHonest_missingFile_isHealthyEmpty() async throws {
    let root = try makeU5TempRoot()
    defer { try? FileManager.default.removeItem(at: root) }
    let rows = try await NativeClient.readJSONLHonest(
        SwiftNativePersistenceCore(),
        path: root.appendingPathComponent("absent.jsonl"),
        context: "test")
    #expect(rows.isEmpty)
}

@Test
func readJSONLHonest_validFile_returnsRows() async throws {
    let root = try makeU5TempRoot()
    defer { try? FileManager.default.removeItem(at: root) }
    let path = root.appendingPathComponent("ok.jsonl")
    try Data("{\"id\": \"a\"}\n{\"id\": \"b\"}\n".utf8).write(to: path)
    let rows = try await NativeClient.readJSONLHonest(
        SwiftNativePersistenceCore(), path: path, context: "test")
    #expect(rows.count == 2)
}

@Test
func readJSONLHonest_corruptFile_throwsInsteadOfEmpty() async throws {
    let root = try makeU5TempRoot()
    defer { try? FileManager.default.removeItem(at: root) }
    let path = root.appendingPathComponent("corrupt.jsonl")
    try Data("not json at all\n%%%%\n".utf8).write(to: path)
    await #expect(throws: (any Error).self) {
        _ = try await NativeClient.readJSONLHonest(
            SwiftNativePersistenceCore(), path: path, context: "test")
    }
}

@Test
func readJSONLHonest_partialCorruption_staysLossy() async throws {
    // One bad line must NOT nuke the list (existing lossy contract).
    let root = try makeU5TempRoot()
    defer { try? FileManager.default.removeItem(at: root) }
    let path = root.appendingPathComponent("partial.jsonl")
    try Data("{\"id\": \"a\"}\ngarbage-line\n{\"id\": \"b\"}\n".utf8).write(to: path)
    let rows = try await NativeClient.readJSONLHonest(
        SwiftNativePersistenceCore(), path: path, context: "test")
    #expect(rows.count == 2)
}

@Test
func inboxStatusWrite_corruptFile_returnsFalse_andNeverRewrites() async throws {
    let root = try makeU5TempRoot()
    defer { try? FileManager.default.removeItem(at: root) }
    let path = root.appendingPathComponent("inbox.jsonl")
    let corrupt = "totally corrupt inbox content\n"
    try Data(corrupt.utf8).write(to: path)

    let handled = await NativeClient.updateVisibleNotificationInboxStatus(
        id: "card-1", action: "archive", inboxPath: path)
    #expect(handled == false)
    // The corrupt bytes are untouched — the old swallow path could proceed
    // on rows=[] and (in the resurrection class) rewrite state it never read.
    let after = try String(contentsOf: path, encoding: .utf8)
    #expect(after == corrupt)
}

@Test
func inboxStatusWrite_validFile_stillUpdates() async throws {
    let root = try makeU5TempRoot()
    defer { try? FileManager.default.removeItem(at: root) }
    let path = root.appendingPathComponent("inbox.jsonl")
    try Data("{\"id\": \"card-1\", \"status\": \"unread\"}\n".utf8).write(to: path)

    let handled = await NativeClient.updateVisibleNotificationInboxStatus(
        id: "card-1", action: "archive", inboxPath: path)
    #expect(handled == true)
    let after = try String(contentsOf: path, encoding: .utf8)
    #expect(after.contains("\"archived\""))
}

// MARK: - 2. generic approval crash-window reconcile

@Test
func reconcile_firesExecutor_forResolvedUnannotatedRecords() async throws {
    let root = try makeU5TempRoot()
    defer { try? FileManager.default.removeItem(at: root) }
    let rec = try await makeResolvedUnannotated(
        root: root, action: "rem.proposal", decision: .approved)

    let recorder = ReconcileRecorder()
    await NativeClient.reconcileUnappliedApprovalExecutions(
        dataRoot: root,
        kinds: [NativeClient.ApprovalExecutionReconcileKind(
            action: "rem.proposal",
            shouldReconcile: { _ in true },
            execute: { record in await recorder.record(record.id) })])
    let executed = await recorder.executedIds
    #expect(executed == [rec.id])
}

@Test
func reconcile_skipsAnnotatedRecords() async throws {
    let root = try makeU5TempRoot()
    defer { try? FileManager.default.removeItem(at: root) }
    let rec = try await makeResolvedUnannotated(
        root: root, action: "mission.step", decision: .approved)
    try stampExecutedAction(root: root, id: rec.id)

    let recorder = ReconcileRecorder()
    await NativeClient.reconcileUnappliedApprovalExecutions(
        dataRoot: root,
        kinds: [NativeClient.ApprovalExecutionReconcileKind(
            action: "mission.step",
            shouldReconcile: { _ in true },
            execute: { record in await recorder.record(record.id) })])
    let executed = await recorder.executedIds
    #expect(executed.isEmpty)
}

@Test
func reconcile_skipsPendingRecords() async throws {
    let root = try makeU5TempRoot()
    defer { try? FileManager.default.removeItem(at: root) }
    let inbox = SwiftNativeApprovalInbox(root: root)
    _ = try await inbox.create(.object([
        "title": .string("still pending"),
        "action": .string("browser.open_url"),
        "risk": .string("medium"),
        "reason": .string("fixture"),
        "payload": .object([:]),
    ]))

    let recorder = ReconcileRecorder()
    await NativeClient.reconcileUnappliedApprovalExecutions(
        dataRoot: root,
        kinds: [NativeClient.ApprovalExecutionReconcileKind(
            action: "browser.open_url",
            shouldReconcile: { _ in true },
            execute: { record in await recorder.record(record.id) })])
    let executed = await recorder.executedIds
    #expect(executed.isEmpty)
}

@Test
func reconcile_selfImprovementHook_skipsDeniedAndCanceled() async throws {
    let root = try makeU5TempRoot()
    defer { try? FileManager.default.removeItem(at: root) }
    let denied = try await makeResolvedUnannotated(
        root: root, action: "self_improvement.apply", decision: .denied)
    let canceled = try await makeResolvedUnannotated(
        root: root, action: "self_improvement.apply", decision: .canceled)
    let approved = try await makeResolvedUnannotated(
        root: root, action: "self_improvement.apply", decision: .approved)

    // Direct predicate pins (the REAL production hook, not a test copy).
    #expect(NativeClient.selfImprovementReconcileEligible(denied) == false)
    #expect(NativeClient.selfImprovementReconcileEligible(canceled) == false)
    #expect(NativeClient.selfImprovementReconcileEligible(approved) == true)

    // Scan-level: only the approved record reaches the executor.
    let recorder = ReconcileRecorder()
    await NativeClient.reconcileUnappliedApprovalExecutions(
        dataRoot: root,
        kinds: [NativeClient.ApprovalExecutionReconcileKind(
            action: "self_improvement.apply",
            shouldReconcile: { NativeClient.selfImprovementReconcileEligible($0) },
            execute: { record in await recorder.record(record.id) })])
    let executed = await recorder.executedIds
    #expect(executed == [approved.id])
}

@Test
func terminalBrowserRun_classifiesRunStates() async throws {
    let root = try makeU5TempRoot()
    defer { try? FileManager.default.removeItem(at: root) }
    let runsPath = root.appendingPathComponent("runs.json")
    let rows: [[String: Any]] = [
        ["id": "run-done", "status": "succeeded", "url": "https://example.com"],
        ["id": "run-waiting", "status": "waiting_approval", "url": "https://example.com"],
    ]
    try JSONSerialization.data(withJSONObject: rows).write(to: runsPath)

    let done = await NativeClient.terminalBrowserRun(runID: "run-done", runsPath: runsPath)
    #expect(done != nil)
    let waiting = await NativeClient.terminalBrowserRun(runID: "run-waiting", runsPath: runsPath)
    #expect(waiting == nil)
    let absent = await NativeClient.terminalBrowserRun(runID: "run-absent", runsPath: runsPath)
    #expect(absent == nil)
    let empty = await NativeClient.terminalBrowserRun(runID: "", runsPath: runsPath)
    #expect(empty == nil)
}

@Test
func browserReconcile_terminalRun_healsAnnotationWithoutReopening() async throws {
    let root = try makeU5TempRoot()
    defer { try? FileManager.default.removeItem(at: root) }
    // Approved browser record whose navigation already persisted a terminal
    // run (the annotation-write crash window).
    let rec = try await makeResolvedUnannotated(
        root: root,
        action: "browser.open_url",
        decision: .approved,
        payload: .object([
            "url": .string("https://example.com"),
            "runId": .string("run-77"),
        ]))
    let runsPath = root.appendingPathComponent("runs.json")
    try JSONSerialization.data(withJSONObject: [
        ["id": "run-77", "status": "succeeded", "url": "https://example.com"],
    ]).write(to: runsPath)

    await NativeClient.reconcileResolvedBrowserRun(
        from: rec, runsPath: runsPath, dataRoot: root)

    let row = try #require(try loadApprovalRow(root: root, id: rec.id))
    #expect(row["executedAction"] != nil)
    let detail = (row["detail"] as? String) ?? ""
    #expect(detail.contains("not re-opened"))
    // Idempotency follow-through: with the annotation healed, a second
    // launch scan no longer selects the record at all.
    let recorder = ReconcileRecorder()
    await NativeClient.reconcileUnappliedApprovalExecutions(
        dataRoot: root,
        kinds: [NativeClient.ApprovalExecutionReconcileKind(
            action: "browser.open_url",
            shouldReconcile: { _ in true },
            execute: { record in await recorder.record(record.id) })])
    let executed = await recorder.executedIds
    #expect(executed.isEmpty)
}

// MARK: - 3. fullMacGrantIsActive == the real gate (devMode × expiry matrix)

private func u5TrustPolicy(
    permissionLevel: String = "full_mac_os",
    outside: String = "allow",
    neverExpires: Bool? = nil,
    maxDurationHours: Double? = nil,
    expiresAt: String? = nil,
    confirmedAt: String? = nil,
    developerMode: Bool
) -> TrustPolicy {
    TrustPolicy(
        permissionLevel: permissionLevel,
        filePolicy: TrustFilePolicy(
            allowedWorkspaceIds: nil,
            requireBackupBeforeWrite: nil,
            allowDestructiveActions: nil,
            outsideWorkspaceDefault: outside),
        fullMacNeverExpires: neverExpires,
        fullMacMaxDurationHours: maxDurationHours,
        fullMacExpiresAt: expiresAt,
        fullMacConfirmedAt: confirmedAt,
        developerMode: developerMode
    )
}

@Test
func fullMacDisplay_matchesGate_acrossDevModeAndExpiryMatrix() {
    // Matrix rows: (policy, expectedActive). expectedActive is asserted
    // BOTH against the display predicate and the real gate, so the test
    // pins display == gate AND the concrete verdicts.
    let active = isoNow(offset: -600)            // confirmed 10 min ago, 4h window
    let expired = isoNow(offset: -5 * 3600)      // confirmed 5h ago, 4h window
    let futureExpiry = isoNow(offset: 3600)
    let pastExpiry = isoNow(offset: -3600)

    let matrix: [(TrustPolicy, Bool, String)] = [
        // The 9a ux-lie: devMode + EXPIRED window — the old display
        // short-circuited TRUE here while the gate swept the tools.
        (u5TrustPolicy(maxDurationHours: 4, confirmedAt: expired, developerMode: true),
         false, "devMode + expired window must read INACTIVE"),
        (u5TrustPolicy(maxDurationHours: 4, confirmedAt: active, developerMode: true),
         true, "devMode + active window reads active"),
        (u5TrustPolicy(maxDurationHours: 4, confirmedAt: active, developerMode: false),
         true, "active window reads active"),
        (u5TrustPolicy(maxDurationHours: 4, confirmedAt: expired, developerMode: false),
         false, "expired window reads inactive"),
        (u5TrustPolicy(neverExpires: true, developerMode: false),
         true, "neverExpires reads active"),
        (u5TrustPolicy(neverExpires: true, developerMode: true),
         true, "neverExpires + devMode reads active"),
        (u5TrustPolicy(expiresAt: futureExpiry, developerMode: false),
         true, "explicit future expiresAt reads active"),
        (u5TrustPolicy(expiresAt: pastExpiry, developerMode: true),
         false, "devMode + explicit past expiresAt must read INACTIVE"),
        // Permission gate: balanced + outside=deny is not Full Mac at all,
        // regardless of stamps or devMode.
        (u5TrustPolicy(permissionLevel: "balanced", outside: "deny",
                       maxDurationHours: 4, confirmedAt: active, developerMode: true),
         false, "permission gate off must read INACTIVE even with devMode"),
        // Clamp drift: 0.05h (3 min) window confirmed 4 min ago. The gate
        // clamps max(0.01, min(h, 24)) → expired. The OLD display clamp
        // min(max(0.1, h), 24) stretched it to 6 min → lied "active".
        (u5TrustPolicy(maxDurationHours: 0.05, confirmedAt: isoNow(offset: -240),
                       developerMode: false),
         false, "sub-0.1h duration honors the gate clamp, not the old display clamp"),
    ]

    for (policy, expected, label) in matrix {
        let display = AppModel.fullMacGrantIsActive(policy)
        let gate = MacControlGate.fullMacActive(FullMacExpiry.trustFields(policy))
        #expect(display == gate, "display drifted from gate: \(label)")
        #expect(display == expected, "verdict wrong: \(label)")
    }
}

@Test
func agentAccessMode_neverClaimsFull_onExpiredDevModeGrant() {
    // The picker-sync consumer of the predicate: expired window + devMode
    // used to surface "full" in the ChatView picker + CommandCenter badge.
    let expiredDev = u5TrustPolicy(
        maxDurationHours: 4, confirmedAt: isoNow(offset: -5 * 3600), developerMode: true)
    #expect(AppModel.agentAccessMode(from: expiredDev, fallback: "auto") != "full")

    let activeDev = u5TrustPolicy(
        maxDurationHours: 4, confirmedAt: isoNow(offset: -600), developerMode: true)
    #expect(AppModel.agentAccessMode(from: activeDev, fallback: "auto") == "full")
}
