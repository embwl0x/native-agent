import Foundation
import Testing
import NativeAgentCore
import PersistenceCore
@testable import MacControl

// MARK: - Coverage wave A — core.maccontrol
//
// One eval per UNCOVERED / REPORTS-ONLY ledger row in the `core.maccontrol`
// fence (docs/evals/ledger.json). Every test here asserts a property of an
// ENVELOPE the rest of the system reads — a persisted record, a result object,
// a returned read model — never an internal that only this file can see.
//
// HERMETIC BY CONSTRUCTION: temp data roots, injected adapters, non-shared
// actor instances. Nothing here touches the host screen, the window server,
// TCC, the network, or the repo's data/ tree.

private func waveARoot(_ label: String) throws -> URL {
    let root = FileManager.default.temporaryDirectory
        .appendingPathComponent("maccontrol-wave-a-\(label)-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    return root
}

private func waveADigest(_ action: String, _ body: [String: JSONValue] = [:]) throws -> String {
    try MacControlOperationStore.requestDigest(action: action, body: body)
}

private func waveAObject(_ value: JSONValue) -> [String: JSONValue] {
    guard case .object(let object) = value else { return [:] }
    return object
}

// ============================================================================
// ROW: maccontrol.client.motorActionReadModel  (REPORTS-ONLY → covered)
//
// SILENT FAILURE: the phase mapping drifts and a BLOCKED operation reads as
// `succeeded` in whatever consumes the motor read model. Nothing asserted the
// mapping, so a reordered switch ships green.
// ============================================================================

/// Every `MacControlOperationState` reached through the store's own legal
/// transitions, so this walks the REAL lifecycle rather than hand-built rows.
private func waveAStore(
    reaching state: MacControlOperationState,
    root: URL,
    id: String
) async throws -> MacControlOperationStore {
    let store = MacControlOperationStore(dataRoot: root)
    _ = try await store.begin(
        operationId: id,
        action: "notify",
        requestDigest: try waveADigest("notify", ["id": .string(id)]),
        deadlineSeconds: 30
    )
    switch state {
    case .accepted:
        break
    case .started, .blocked, .refused, .failed, .cancelRequested:
        if state != .accepted { _ = try await store.transition(operationId: id, to: state) }
    case .cancelAcknowledged, .timedOut, .outcomeUnknown, .completed:
        _ = try await store.transition(operationId: id, to: .started)
        _ = try await store.transition(operationId: id, to: state)
    }
    return store
}

@Test
func motorActionReadModel_mapsEveryOperationStateToItsDocumentedPhase() async throws {
    let root = try waveARoot("motor-phase")
    defer { try? FileManager.default.removeItem(at: root) }

    // THE TABLE. Written out rather than derived from the code under test —
    // a mapping asserted against itself proves nothing.
    let expected: [MacControlOperationState: MotorActionPhase] = [
        .accepted: .ready,
        .started: .running,
        .cancelRequested: .running,
        .cancelAcknowledged: .cancelled,
        .timedOut: .expired,
        .outcomeUnknown: .waitingExternal,
        .completed: .succeeded,
        .failed: .failed,
        .blocked: .blocked,
        .refused: .blocked,
    ]
    #expect(Set(expected.keys) == Set(MacControlOperationState.allCases),
            "a new operation state must be given an explicit phase here, not inherited by accident")

    for state in MacControlOperationState.allCases {
        let id = "phase-\(state.rawValue)"
        let store = try await waveAStore(reaching: state, root: root, id: id)
        let record = try #require(try await store.record(operationId: id))
        #expect(record.state == state, "\(state.rawValue) was not actually reached")

        let model = try #require(try await store.motorActionReadModel(actionId: id))
        #expect(model.phase == expected[state],
                "\(state.rawValue) must read as \(expected[state]!.rawValue), got \(model.phase.rawValue)")
        #expect(model.domain == "mac_control")
        #expect(model.domainState == state.rawValue)

        // A terminal operation is not cancellable and has no live deadline —
        // the two fields a scheduler would act on.
        if state.isTerminal {
            #expect(model.cancellationIdentity == nil, "\(state.rawValue) is terminal; nothing may cancel it")
            #expect(model.deadline == nil, "\(state.rawValue) is terminal; it has no remaining budget")
        } else {
            #expect(model.cancellationIdentity == id, "\(state.rawValue) is live and must stay cancellable")
            #expect(model.deadline?.timeoutSeconds == 30, "\(state.rawValue) must carry its accepted budget")
            #expect(model.deadline?.scope == .operation)
        }

        // The identity that crosses the seam is OPAQUE — the raw operation id
        // is a local secret, not a wire value.
        #expect(model.actionIdentity != id,
                "the read model must not hand the raw operation id across the seam")
        #expect(!model.actionIdentity.isEmpty)
    }

    // An identity nobody minted has no read model — never a default row.
    let store = MacControlOperationStore(dataRoot: root)
    #expect(try await store.motorActionReadModel(actionId: "never-existed") == nil)
}

// ============================================================================
// ROW: store.macControl.operations.retentionCap  (UNCOVERED → covered)
//
// SILENT FAILURE: `bound()` keeps ALL active rows plus max(0, cap - active)
// terminal rows. If actives ever exceed the cap the array grows without limit
// and no terminal row survives — a leak that reads as a healthy store.
// ============================================================================

private struct WaveASnapshot: Codable {
    var schemaVersion: Int
    var operations: [MacControlOperationRecord]
}

private func waveAWriteSnapshot(_ operations: [MacControlOperationRecord], to root: URL) throws {
    let path = root
        .appendingPathComponent("mac_control", isDirectory: true)
        .appendingPathComponent("operations.json")
    try FileManager.default.createDirectory(
        at: path.deletingLastPathComponent(), withIntermediateDirectories: true
    )
    let encoder = JSONEncoder()
    encoder.dateEncodingStrategy = .iso8601
    encoder.outputFormatting = [.sortedKeys]
    try encoder.encode(WaveASnapshot(schemaVersion: 1, operations: operations)).write(to: path, options: .atomic)
}

private func waveAReadSnapshot(_ root: URL) throws -> [MacControlOperationRecord] {
    let path = root
        .appendingPathComponent("mac_control", isDirectory: true)
        .appendingPathComponent("operations.json")
    let decoder = JSONDecoder()
    decoder.dateDecodingStrategy = .iso8601
    return try decoder.decode(WaveASnapshot.self, from: try Data(contentsOf: path)).operations
}

private func waveARecord(
    _ index: Int,
    state: MacControlOperationState,
    at base: Date
) throws -> MacControlOperationRecord {
    let id = "retain-\(state.rawValue)-\(index)"
    return MacControlOperationRecord(
        operationId: id,
        action: "notify",
        requestDigest: try waveADigest("notify", ["id": .string(id)]),
        state: state,
        acceptedAt: base.addingTimeInterval(Double(index)),
        startedAt: state.isTerminal ? base.addingTimeInterval(Double(index)) : nil,
        terminalAt: state.isTerminal ? base.addingTimeInterval(Double(index) + 0.5) : nil,
        verification: state.isTerminal ? .unverified : .pending
    )
}

@Test
func operationRetentionCapEvictsOldestTerminalRowsAndNeverAnActiveOne() async throws {
    let root = try waveARoot("retention-terminal")
    defer { try? FileManager.default.removeItem(at: root) }
    let base = Date(timeIntervalSince1970: 1_700_000_000)

    // Newest-first, exactly as the store stores it: 3 live rows on top, then
    // 510 terminal rows — 13 over the cap.
    var rows: [MacControlOperationRecord] = []
    for i in 0..<3 { rows.append(try waveARecord(i, state: .started, at: base)) }
    for i in 0..<510 { rows.append(try waveARecord(i, state: .completed, at: base)) }
    try waveAWriteSnapshot(rows, to: root)

    let store = MacControlOperationStore(dataRoot: root)
    _ = try await store.begin(
        operationId: "retain-new",
        action: "notify",
        requestDigest: try waveADigest("notify", ["id": .string("retain-new")]),
        deadlineSeconds: 10
    )

    let after = try waveAReadSnapshot(root)
    // 500 is written out, NOT read back from the constant under test: comparing
    // a cap against itself passes for any value the cap happens to hold.
    #expect(MacControlOperationStore.maxRetainedOperations == 500,
            "the retention cap changed — this eval and the ledger row must change with it")
    #expect(after.count == 500, "the store must bound itself at the cap, found \(after.count)")

    let ids = Set(after.map(\.operationId))
    // Every live row survives, including the one just accepted.
    #expect(ids.contains("retain-new"))
    for i in 0..<3 {
        #expect(ids.contains("retain-started-\(i)"), "an ACTIVE row was evicted — the cap ate live work")
    }
    // Terminal rows are evicted OLDEST-first: the head of the terminal run
    // survives, the tail does not.
    #expect(ids.contains("retain-completed-0"))
    #expect(!ids.contains("retain-completed-509"),
            "the oldest terminal row must be the one dropped")
    #expect(after.filter { !$0.state.isTerminal }.count == 4)
}

@Test
func operationRetentionRefusesToDropActiveRowsEvenAboveTheCap() async throws {
    let root = try waveARoot("retention-active")
    defer { try? FileManager.default.removeItem(at: root) }
    let base = Date(timeIntervalSince1970: 1_700_000_000)

    // 510 LIVE rows and one terminal row. This is the leak shape: the cap
    // cannot bite without evicting work that may still be running, so the
    // store deliberately grows instead. That trade is asserted here rather
    // than assumed, so a future "just trim it" change has to argue with a test.
    var rows: [MacControlOperationRecord] = []
    for i in 0..<510 { rows.append(try waveARecord(i, state: .started, at: base)) }
    rows.append(try waveARecord(0, state: .completed, at: base))
    try waveAWriteSnapshot(rows, to: root)

    let store = MacControlOperationStore(dataRoot: root)
    _ = try await store.begin(
        operationId: "retain-overflow",
        action: "notify",
        requestDigest: try waveADigest("notify", ["id": .string("retain-overflow")]),
        deadlineSeconds: 10
    )

    let after = try waveAReadSnapshot(root)
    let active = after.filter { !$0.state.isTerminal }
    #expect(active.count == 511, "no active row may be evicted, found \(active.count) of 511")
    #expect(after.count == 511,
            "with actives over the cap the terminal budget is zero — the terminal row is what goes")
    #expect(!after.contains { $0.operationId == "retain-completed-0" })
}

// ============================================================================
// ROW: maccontrol.operationTimeoutBudget  (UNCOVERED → covered, test tier)
//
// SILENT FAILURE: an action's budget drifts (or a caller's `timeout` escapes
// its clamp) and a 20-second look still returns `ok` inside its budget. The
// deadline the store durably records is the only place the budget is visible.
// ============================================================================

@Test
func operationDeadlineSecondsAreClampedIntoTheOneToOneTwentySecondWindow() async throws {
    let root = try waveARoot("deadline-clamp")
    defer { try? FileManager.default.removeItem(at: root) }
    let base = Date(timeIntervalSince1970: 1_700_000_000)
    let store = MacControlOperationStore(dataRoot: root, now: { base })

    // requested → recorded budget in seconds
    let cases: [(Int, Double)] = [
        (-100, 1),   // negative can never mean "no deadline"
        (0, 1),      // nor can zero — an instantly-expired op is not honest
        (1, 1),
        (60, 60),
        (120, 120),  // the ceiling
        (100_000, 120),
    ]
    for (requested, expected) in cases {
        let id = "deadline-\(requested)"
        let outcome = try await store.begin(
            operationId: id,
            action: "shell",
            requestDigest: try waveADigest("shell", ["id": .string(id)]),
            deadlineSeconds: requested
        )
        guard case .accepted(let record) = outcome else {
            Issue.record("expected a fresh acceptance for \(requested)")
            continue
        }
        let deadline = try #require(record.deadlineAt)
        #expect(deadline.timeIntervalSince(record.acceptedAt) == expected,
                "deadlineSeconds \(requested) must record \(expected)s, got \(deadline.timeIntervalSince(record.acceptedAt))")
    }

    // No requested deadline ⇒ no invented one.
    let outcome = try await store.begin(
        operationId: "deadline-none",
        action: "shell",
        requestDigest: try waveADigest("shell", ["id": .string("deadline-none")]),
        deadlineSeconds: nil
    )
    guard case .accepted(let record) = outcome else {
        Issue.record("expected a fresh acceptance")
        return
    }
    #expect(record.deadlineAt == nil, "an unbudgeted operation must not be given a fabricated deadline")
}

@Test
func eachDispatchedActionRecordsItsOwnDocumentedTimeoutBudget() async throws {
    let root = try waveARoot("budget-per-action")
    defer { try? FileManager.default.removeItem(at: root) }

    /// The budget table as DOCUMENTED, asserted through the durable record the
    /// dispatch writes. A budget that silently doubles shows up right here.
    func budget(
        action: String,
        body: [String: JSONValue],
        id: String
    ) async throws -> Double? {
        let store = MacControlOperationStore(dataRoot: root)
        let process = _MockProcessAdapter()
        await process.queue(ProcessRunResult(exitCode: 0, stdout: "", stderr: ""))
        let client = SwiftNativeMacControl(
            notificationCenterAdapter: _MockNotificationCenter(),
            processAdapter: process,
            operationStore: store
        )
        var body = body
        body["operationId"] = .string(id)
        _ = try? await client.dispatch(action: action, body: body)
        guard let record = try await store.record(operationId: id),
              let deadline = record.deadlineAt else { return nil }
        return deadline.timeIntervalSince(record.acceptedAt)
    }

    #expect(try await budget(action: "spotlight", body: ["query": .string("x")], id: "b-spotlight") == 10)
    #expect(try await budget(action: "ax_status", body: [:], id: "b-axstatus") == 15)
    #expect(try await budget(action: "shell", body: ["command": .string("true")], id: "b-shell") == 60)
    // Anything without a named budget falls to the conservative default.
    #expect(try await budget(action: "notify", body: [
        "title": .string("t"), "message": .string("m"),
    ], id: "b-notify") == 90)

    // A caller-supplied timeout overrides the table — and is clamped by it.
    #expect(try await budget(action: "shell", body: [
        "command": .string("true"), "timeout": .int(5),
    ], id: "b-shell-5") == 5)
    #expect(try await budget(action: "shell", body: [
        "command": .string("true"), "timeout": .int(9_999),
    ], id: "b-shell-huge") == 120)
    #expect(try await budget(action: "shell", body: [
        "command": .string("true"), "timeout": .int(0),
    ], id: "b-shell-zero") == 1)
}

// ============================================================================
// ROW: maccontrol.action.quit_app  (REPORTS-ONLY → covered)
//
// SILENT FAILURE: quit is reported complete while a save dialog still holds
// the app up. `ok` says the REQUEST was accepted; only `verified` says the app
// is actually gone, and nothing asserted that they are allowed to disagree.
// ============================================================================

private actor _WaveAQuitAdapter: AppControlAdapter, AppStateVerificationAdapter {
    private let stillRunningAfterQuit: Bool
    private(set) var quitCalls: [String] = []

    init(stillRunningAfterQuit: Bool) { self.stillRunningAfterQuit = stillRunningAfterQuit }

    func focusApp(named name: String) async throws -> AppControlRunResult {
        AppControlRunResult(
            requestedName: name, matchedName: name, bundleIdentifier: nil,
            processIdentifier: nil, launched: false, activated: true, terminated: false
        )
    }

    func quitApp(named name: String) async throws -> AppControlRunResult {
        quitCalls.append(name)
        return AppControlRunResult(
            requestedName: name, matchedName: name, bundleIdentifier: "example.\(name)",
            processIdentifier: 42, launched: false, activated: false, terminated: true
        )
    }

    func isFrontmostApplication(matching name: String) async -> Bool { false }
    func isApplicationRunning(matching name: String) async -> Bool { stillRunningAfterQuit }
}

@Test
func quitAppNeverClaimsVerifiedWhileTheAppIsStillObservablyRunning() async throws {
    // A save sheet blocks the quit: the Apple event was accepted (`terminated`)
    // but the process is still there.
    let blocked = _WaveAQuitAdapter(stillRunningAfterQuit: true)
    let blockedResult = try await SwiftNativeMacControl(appControlAdapter: blocked)
        .dispatch(action: "quit_app", body: ["name": .string("Pages")])
    let blockedOutput = waveAObject(blockedResult.output)
    #expect(blockedResult.ok == true, "the quit REQUEST was accepted; the envelope must not lie about that")
    #expect(blockedOutput["terminated"] == .bool(true))
    #expect(blockedOutput["verified"] == .bool(false),
            "a still-running app must never be reported as verifiably quit")
    #expect(blockedOutput["status"] == .string("quit_requested"))

    // The same request against an app that really went away.
    let gone = _WaveAQuitAdapter(stillRunningAfterQuit: false)
    let goneResult = try await SwiftNativeMacControl(appControlAdapter: gone)
        .dispatch(action: "quit_app", body: ["name": .string("Pages")])
    #expect(waveAObject(goneResult.output)["verified"] == .bool(true),
            "an observed-gone app must verify, or `verified` carries no information at all")
    #expect(await gone.quitCalls == ["Pages"])
}

// ============================================================================
// ROW: maccontrol.action.spotlight  (REPORTS-ONLY → covered)
//
// SILENT FAILURE: mdfind returns nothing because the index is rebuilding, and
// `ok:true, results:[]` is indistinguishable from "the file does not exist".
// ============================================================================

@Test
func spotlightDistinguishesAnEmptyIndexFromAFailedOrTimedOutQuery() async throws {
    // (a) A genuine no-hit answer: exit 0, no lines.
    let empty = _MockProcessAdapter()
    await empty.queue(ProcessRunResult(exitCode: 0, stdout: "", stderr: ""))
    let emptyResult = try await SwiftNativeMacControl(processAdapter: empty)
        .dispatch(action: "spotlight", body: ["query": .string("nothing")])
    #expect(emptyResult.ok == true)
    #expect(emptyResult.error == nil)
    #expect(waveAObject(emptyResult.output)["count"] == .int(0))
    #expect(waveAObject(emptyResult.output)["timed_out"] == .bool(false))

    // (b) mdfind FAILED. Same empty result set — but the envelope must not
    // read the same, or "index rebuilding" becomes "file does not exist".
    let failed = _MockProcessAdapter()
    await failed.queue(ProcessRunResult(exitCode: 2, stdout: "", stderr: "mdfind: index unavailable"))
    let failedResult = try await SwiftNativeMacControl(processAdapter: failed)
        .dispatch(action: "spotlight", body: ["query": .string("nothing")])
    #expect(failedResult.ok == false, "a failed query must not present as an empty answer")
    #expect(failedResult.error?.contains("mdfind exit 2") == true, "\(failedResult.error ?? "nil")")
    #expect(waveAObject(failedResult.output)["count"] == .int(0))

    // (c) TIMED OUT. Distinct again, and typed rather than folded into (b).
    let timedOut = _MockProcessAdapter()
    await timedOut.queue(ProcessRunResult(exitCode: 15, stdout: "", stderr: "", timedOut: true))
    let timedOutResult = try await SwiftNativeMacControl(processAdapter: timedOut)
        .dispatch(action: "spotlight", body: ["query": .string("nothing")])
    #expect(timedOutResult.ok == false)
    #expect(timedOutResult.error == "spotlight timed out")
    #expect(waveAObject(timedOutResult.output)["timed_out"] == .bool(true))

    // All three envelopes must actually differ — the point of the row.
    #expect(emptyResult.error != failedResult.error)
    #expect(failedResult.error != timedOutResult.error)
}

// ============================================================================
// ROW: maccontrol.injectionCapability.ledger  (UNCOVERED → covered)
//
// SILENT FAILURE: single use is the whole reason a captured capability cannot
// be replayed inside its TTL. Repo-wide the ledger had ZERO test references.
// ============================================================================

@Test
func injectionCapabilityNonceIsSpentExactlyOnce() async throws {
    // A DEDICATED ledger, not `.shared` — a process-global under a parallel
    // suite would make this test's verdict depend on its neighbours.
    let ledger = MacInjectionCapabilityLedger()
    let now = Date(timeIntervalSince1970: 1_700_000_000)
    #expect(await ledger.consume(nonce: "n-1", now: now) == true)
    #expect(await ledger.consume(nonce: "n-1", now: now) == false, "one approval buys one injection")
    #expect(await ledger.consume(nonce: "n-1", now: now.addingTimeInterval(60)) == false,
            "a spent nonce stays spent for the whole TTL")
    #expect(await ledger.consume(nonce: "n-2", now: now) == true, "a different nonce is unaffected")

    await ledger.reset()
    #expect(await ledger.consume(nonce: "n-1", now: now) == true,
            "reset is the hermetic-test seam; after it nothing is remembered")

    // And the PRODUCTION ledger enforces the same thing, proven with a nonce
    // no other test can be holding.
    let unique = "wave-a-\(UUID().uuidString)"
    #expect(await MacInjectionCapabilityLedger.shared.consume(nonce: unique) == true)
    #expect(await MacInjectionCapabilityLedger.shared.consume(nonce: unique) == false)
}

@Test
func injectionCapabilityLedgerPrunesOnlyEntriesPastTheHourAndOnlyAboveItsFloor() async throws {
    let ledger = MacInjectionCapabilityLedger()
    let t0 = Date(timeIntervalSince1970: 1_700_000_000)

    // Below the 256-entry floor nothing is ever evicted, however old.
    for i in 0..<100 { _ = await ledger.consume(nonce: "small-\(i)", now: t0) }
    #expect(await ledger.consume(nonce: "small-0", now: t0.addingTimeInterval(7_200)) == false,
            "under the floor the ledger must not forget — a replay would look like a fresh approval")

    // Above the floor, entries older than an hour are dropped. They cannot
    // authorize anything anyway (the capability TTL is 120s), so this is
    // memory hygiene, not a weakened guarantee.
    let bulk = MacInjectionCapabilityLedger()
    for i in 0..<300 { _ = await bulk.consume(nonce: "bulk-\(i)", now: t0) }
    #expect(await bulk.consume(nonce: "bulk-0", now: t0.addingTimeInterval(60)) == false,
            "inside the hour every nonce is still spent")
    _ = await bulk.consume(nonce: "trigger", now: t0.addingTimeInterval(3_601))
    #expect(await bulk.consume(nonce: "bulk-0", now: t0.addingTimeInterval(3_601)) == true,
            "past the hour the prune must actually evict, or the set grows without bound")
}

// ============================================================================
// ROW: maccontrol.injectionCapability.mintSiteGuard  (UNCOVERED → covered)
//
// PHANTOM GUARD. Three files claim in prose that a source-conformance test
// named `macInjectionCapability_hasExactlyOneMintSite` pins the capability's
// PRIVATE constructor to a single call site. That test does not exist anywhere
// in the repo (`grep -rn hasExactlyOneMintSite` returns only the three doc
// comments). The mint() CALL sites are pinned elsewhere
// (MacInjectionCapabilityFenceTests.macInjectionCapability_mintSitesAreTheThree…),
// but the private memberwise init — visible only inside this one file, and the
// thing that makes `mint` the only constructor — is pinned by nothing.
// ============================================================================

@Test
func macInjectionCapability_privateConstructorIsReachedOnlyFromMint() throws {
    let actuator = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent()   // MacControlTests
        .deletingLastPathComponent()   // Tests
        .deletingLastPathComponent()   // NativeAgentCore
        .appendingPathComponent("Sources/MacControl/MacAccessibilityActuator.swift")
    let raw = try String(contentsOf: actuator, encoding: .utf8)
    #expect(!raw.isEmpty, "the audit is vacuous if the source cannot be read")

    // Strip comments: the file's own header DESCRIBES the constructor, and a
    // description is not a call site.
    let lines = raw.split(separator: "\n", omittingEmptySubsequences: false)
    var codeLines: [String] = []
    for line in lines {
        let trimmed = line.trimmingCharacters(in: .whitespaces)
        if trimmed.hasPrefix("//") { continue }
        if let marker = line.range(of: "//") {
            codeLines.append(String(line[line.startIndex..<marker.lowerBound]))
        } else {
            codeLines.append(String(line))
        }
    }

    // `return MacInjectionCapability(` — the construction form. `Self(` is not
    // used in this file; if it ever is, the positive control below fails.
    let constructionSites = codeLines.enumerated().filter {
        $0.element.contains("MacInjectionCapability(")
    }
    let sitesDescription = constructionSites.map { "line \($0.offset + 1)" }.joined(separator: ", ")
    #expect(constructionSites.count == 1,
            "the capability's private init must have exactly ONE construction site; a second one inside this file forges authority without an approval. Found: \(sitesDescription)")

    // …and that site is inside `mint`. Bracket it by the two nearest function
    // declarations rather than by a line number that any edit would move.
    guard let site = constructionSites.first else { return }
    let declarationsAbove = codeLines[0..<site.offset].enumerated().filter {
        $0.element.contains("func ") || $0.element.contains("static func ")
    }
    let enclosing = try #require(declarationsAbove.last?.element)
    #expect(enclosing.contains("func mint("),
            "the only construction site must sit inside mint(); it is inside: \(enclosing.trimmingCharacters(in: .whitespaces))")

    // POSITIVE CONTROL: the grep must be capable of matching. If the type were
    // renamed, every assertion above would pass vacuously.
    #expect(raw.contains("public struct MacInjectionCapability"),
            "the audited type must still be declared in this file")
    #expect(raw.contains("private init("),
            "the memberwise init must still be private, or the single-site guard is moot")
    #expect(!codeLines.joined(separator: "\n").contains("Self("),
            "this audit greps the explicit type name; a `Self(...)` form would slip past it")
}

// ============================================================================
// ROW: maccontrol.injectionSecretVault  (REPORTS-ONLY → covered)
//
// SILENT FAILURE: this holds the LITERAL characters of a pending keystroke —
// a password, a 2FA code — for up to an hour. `prune` runs only inside store()
// and take(), so an approval nobody resolves can outlive its own TTL. The only
// existing reference was a harness setup call that asserted nothing.
// ============================================================================

@Test
func injectionSecretVaultTakesOnceAndRefusesAnythingPastItsTTL() async throws {
    let vault = MacInjectionSecretVault()
    let t0 = Date(timeIntervalSince1970: 1_700_000_000)

    await vault.store(approvalID: "a", secrets: ["text": "hunter2"], now: t0)
    // SINGLE USE, like the capability it feeds.
    #expect(await vault.take(approvalID: "a", now: t0.addingTimeInterval(5)) == ["text": "hunter2"])
    #expect(await vault.take(approvalID: "a", now: t0.addingTimeInterval(5)) == nil,
            "a taken secret must be gone, not re-servable")

    // PAST THE TTL: refused, and actually removed rather than merely hidden.
    //
    // MUTATION NOTE: the TTL is enforced REDUNDANTLY — `prune` drops the entry
    // and `take`'s own guard refuses it. Removing either one alone leaves this
    // test green because the other still catches it; removing BOTH fails it
    // (verified). That redundancy is the property, so the test is written
    // against the OBSERVABLE outcome rather than against either mechanism.
    await vault.store(approvalID: "b", secrets: ["text": "s3cret"], now: t0)
    #expect(await vault.take(approvalID: "b", now: t0.addingTimeInterval(MacInjectionSecretVault.ttlSeconds + 1)) == nil,
            "an hour-old secret must not replay")
    #expect(await vault.take(approvalID: "b", now: t0.addingTimeInterval(5)) == nil,
            "the expired entry must be GONE — an earlier clock must not resurrect it")

    // An empty secret set is not stored at all: nothing to leak, nothing to
    // make a later take() look successful.
    await vault.store(approvalID: "c", secrets: [:], now: t0)
    #expect(await vault.take(approvalID: "c", now: t0) == nil)

    // A stale unresolved approval is evicted by the NEXT store(), which is the
    // only sweep the vault has.
    await vault.store(approvalID: "stale", secrets: ["text": "old"], now: t0)
    await vault.store(approvalID: "fresh", secrets: ["text": "new"], now: t0.addingTimeInterval(3_601))
    #expect(await vault.take(approvalID: "stale", now: t0.addingTimeInterval(3_601)) == nil,
            "the next store() must sweep entries past their TTL")
    #expect(await vault.take(approvalID: "fresh", now: t0.addingTimeInterval(3_602)) == ["text": "new"],
            "the sweep must not take live entries with it")

    await vault.store(approvalID: "d", secrets: ["text": "x"], now: t0)
    await vault.reset()
    #expect(await vault.take(approvalID: "d", now: t0) == nil, "reset must leave nothing behind")
}

// ============================================================================
// ROW: maccontrol.injectionApprovalDigest  (UNCOVERED → covered)
//
// SILENT FAILURE: this is the half of the replay defence that binds the
// human's decision to the body they were SHOWN. If digest() starts returning
// nil, the approval record is bound to nothing and a replay claiming that
// approval cannot be caught — and a nil return is indistinguishable from
// "no binding needed" at the call site.
// ============================================================================

@Test
func injectionApprovalDigestBindsTheShownBodyAndIsIdempotentOverRedaction() throws {
    let raw: [String: JSONValue] = ["text": .string("hunter2")]
    let shown = MacInjectionArgRedaction.redacted(tool: "mac_keystroke", input: raw)
    #expect(MacInjectionArgRedaction.isRedacted(tool: "mac_keystroke", input: shown))

    let overRaw = try #require(MacInjectionApprovalDigest.digest(tool: "mac_keystroke", input: raw))
    let overShown = try #require(MacInjectionApprovalDigest.digest(tool: "mac_keystroke", input: shown))
    #expect(overRaw == overShown,
            "digesting the raw body and the already-redacted body must agree, or the record's binding depends on WHICH sink got there first")
    #expect(overRaw.count == 64, "a SHA-256 hex digest, never a truncated stand-in")

    // Transport keys the tool chain injects BELOW the approval point must not
    // move the digest — that is what makes the record's binding survive the hop.
    var withPlumbing = raw
    withPlumbing["__session_id"] = .string("s-1")
    withPlumbing["operationId"] = .string("op-1")
    withPlumbing["operation_id"] = .string("op-1")
    withPlumbing["trigger"] = .string("chat")
    #expect(MacInjectionApprovalDigest.digest(tool: "mac_keystroke", input: withPlumbing) == overRaw)

    // A DIFFERENT shown body is a different decision.
    #expect(MacInjectionApprovalDigest.digest(tool: "mac_keystroke", input: ["text": .string("hunter3")]) != overRaw)
    // …even when the character COUNT is identical, which is all the approval
    // card renders.
    #expect(MacInjectionArgRedaction.redacted(tool: "mac_keystroke", input: ["text": .string("hunter3")])["text_character_count"]
                == shown["text_character_count"])

    // A tool the name table does not know must not collide with one it does.
    let unknown = try #require(MacInjectionApprovalDigest.digest(tool: "totally_unknown_tool", input: raw))
    #expect(unknown != overRaw,
            "an unrecognised tool must never digest to the same value as a known one")
    // …and it is still a real digest, not a nil silently read as "unbound".
    #expect(unknown.count == 64)

    // Aliases of the SAME action agree, because the digest is over the action.
    #expect(MacInjectionApprovalDigest.digest(tool: "mac.keystroke", input: raw) == overRaw)
    #expect(MacInjectionApprovalDigest.digest(tool: "keystroke", input: raw) == overRaw)
}

// ============================================================================
// ROW: attention.durationClamps  (UNCOVERED → covered)
//
// SILENT FAILURE: every existing test passes durationSeconds: 60 — dead centre
// of the range. A dropped clamp gives an unbounded attention session (a
// permanent injection lockout) or a zero-second one (every act refused as
// session-not-active), and both look like a working session at the call site.
// ============================================================================

@Test
func attentionSessionDurationIsAlwaysClampedIntoItsNamedWindow() async throws {
    let base = Date(timeIntervalSince1970: 1_700_000_000)
    // The window is written out, NOT read back from the constants under test:
    // clamping against the same constant the code clamps with passes for any
    // value those constants happen to hold, including zero.
    #expect(MacAttentionSessionStore.minimumDurationSeconds == 15)
    #expect(MacAttentionSessionStore.maximumDurationSeconds == 1_800)
    #expect(MacAttentionSessionStore.maximumWaitMilliseconds == 15_000)
    let minimum = 15.0
    let maximum = 1_800.0

    for requested in [-86_400, 0, 1, 14, 15, 60, 1_800, 1_801, 100_000] {
        let store = MacAttentionSessionStore(screenViewStore: MacScreenViewStore())
        let snapshot = try #require(
            await store.start(durationSeconds: requested, now: base, eventSource: AttentionManualSource()),
            "an available event source must always yield a session for \(requested)"
        )
        let span = snapshot.expiresAt.timeIntervalSince(snapshot.startedAt)
        #expect(span >= minimum, "duration \(requested) collapsed to \(span)s — below the floor")
        #expect(span <= maximum, "duration \(requested) reached \(span)s — past the ceiling")
        #expect(span == max(minimum, min(Double(requested), maximum)),
                "duration \(requested) must clamp to the named window, got \(span)")
        // Cancel the expiry task rather than leaving a 30-minute sleeper behind.
        _ = await store.stop()
    }
}

@Test
func attentionWaitIsClampedAndAnUnknownSessionNeverWaitsAtAll() async throws {
    // REAL wall clock: `waitForActivity` re-checks expiry against `Date()`
    // internally, so a synthetic 1970 epoch would expire the session mid-wait
    // and this test would measure the wrong thing.
    let base = Date()
    let store = MacAttentionSessionStore(screenViewStore: MacScreenViewStore())
    let source = AttentionManualSource()
    let started = try #require(await store.start(durationSeconds: 60, now: base, eventSource: source))

    // A negative wait is floored at zero — it must return immediately rather
    // than trapping or waiting forever.
    let clock = ContinuousClock()
    let negativeStart = clock.now
    let negative = try #require(await store.waitForActivity(
        sessionId: started.sessionId, after: -1, timeoutMilliseconds: -1, now: base
    ))
    #expect(negative.timedOutWaiting == false, "a zero wait did not wait, so it did not time out")
    #expect(clock.now - negativeStart < .seconds(1), "a negative wait must not sleep")

    // A wait far past the ceiling returns within the ceiling, not within the
    // number the caller asked for.
    let longStart = clock.now
    let clamped = try #require(await store.waitForActivity(
        sessionId: started.sessionId, after: 0, timeoutMilliseconds: 999_999, now: base
    ))
    let elapsed = clock.now - longStart
    let ceiling = Double(MacAttentionSessionStore.maximumWaitMilliseconds) / 1000
    #expect(clamped.timedOutWaiting == true, "no activity was emitted; the wait must report the timeout")
    #expect(elapsed < .seconds(ceiling + 5),
            "a 999,999 ms wait must be capped at \(MacAttentionSessionStore.maximumWaitMilliseconds) ms, waited \(elapsed)")
    // …and it must actually WAIT. A clamp that collapsed to zero would pass the
    // ceiling check above while silently turning every `attention next` into a
    // busy-poll that never observes anything.
    #expect(elapsed > .seconds(ceiling - 2),
            "the wait must run to its clamped ceiling, not return immediately: \(elapsed)")

    // A session id nobody minted gets nil — never a wait, never a snapshot.
    #expect(await store.waitForActivity(
        sessionId: "not-a-session", after: 0, timeoutMilliseconds: 5_000, now: base
    ) == nil)
    _ = await store.stop()
}

// ============================================================================
// ROW: actloop.dismissLabels  (UNCOVERED → covered)
//
// SILENT FAILURE: a hardcoded ENGLISH label list with zero test references.
// The ORDER is load-bearing (a sheet offering both Cancel and OK must be
// cancelled, not confirmed) and the SCOPE is load-bearing (a window behind a
// sheet often has its own Close). Both were asserted by nothing.
// ============================================================================

private func waveADismissFrame(
    modalPath: [Int]?,
    controls: [(path: [Int], label: String?, role: String)]
) -> MacLookFrame {
    var entries: [String: MacLookFrameEntry] = [:]
    for (index, control) in controls.enumerated() {
        let handle = "h\(index)"
        entries[handle] = MacLookFrameEntry(
            handle: handle,
            path: control.path,
            role: control.role,
            label: control.label,
            frame: MacAXFrame(x: 0, y: Double(index) * 30, w: 80, h: 24)
        )
    }
    return MacLookFrame(
        frameId: "f-1",
        capturedAt: Date(timeIntervalSince1970: 1_700_000_000),
        appName: "App",
        bundleId: "com.example.app",
        windowTitle: "Window",
        entries: entries,
        hasModal: modalPath != nil,
        modalPath: modalPath
    )
}

@Test
func dismissPrefersTheLeastDestructiveLabelAndStaysInsideTheModal() {
    // A sheet offering both. Confirming ("OK") is the destructive answer.
    let both = waveADismissFrame(modalPath: [1], controls: [
        (path: [1, 0], label: "OK", role: "AXButton"),
        (path: [1, 1], label: "Cancel", role: "AXButton"),
    ])
    #expect(MacActClosedLoop.dismissTarget(in: both)?.label == "Cancel",
            "a sheet offering both must be cancelled, never confirmed")

    // The documented preference order, checked pairwise against the list
    // itself so a reordering of `dismissLabels` is a failing test, not a
    // silently different answer on a live dialog.
    #expect(MacActClosedLoop.dismissLabels == ["cancel", "close", "dismiss", "done", "ok"])
    for (rank, preferred) in MacActClosedLoop.dismissLabels.enumerated() {
        for later in MacActClosedLoop.dismissLabels[(rank + 1)...] {
            let frame = waveADismissFrame(modalPath: [1], controls: [
                (path: [1, 0], label: later.capitalized, role: "AXButton"),
                (path: [1, 1], label: preferred.capitalized, role: "AXButton"),
            ])
            #expect(MacActClosedLoop.dismissTarget(in: frame)?.label?.lowercased() == preferred,
                    "\(preferred) must outrank \(later)")
        }
    }

    // SCOPE: a "Cancel" that belongs to the window BEHIND the sheet is not the
    // sheet's dismiss button. Pressing it would act on the wrong surface.
    let outside = waveADismissFrame(modalPath: [2], controls: [
        (path: [0, 0], label: "Cancel", role: "AXButton"),
        (path: [2, 0], label: "Done", role: "AXButton"),
    ])
    #expect(MacActClosedLoop.dismissTarget(in: outside)?.label == "Done",
            "the dismiss target must be scoped by the modal's path prefix")

    // No modal recorded ⇒ no dismiss target, even with a Cancel button on screen.
    let noModal = waveADismissFrame(modalPath: nil, controls: [
        (path: [0, 0], label: "Cancel", role: "AXButton"),
    ])
    #expect(MacActClosedLoop.dismissTarget(in: noModal) == nil)

    // Case and surrounding whitespace do not decide whether a dialog can be closed.
    let messy = waveADismissFrame(modalPath: [1], controls: [
        (path: [1, 0], label: "  cAnCeL \n", role: "AXButton"),
    ])
    #expect(MacActClosedLoop.dismissTarget(in: messy)?.path == [1, 0])

    // Two identical labels inside the modal ⇒ the earliest path, deterministically.
    let twins = waveADismissFrame(modalPath: [1], controls: [
        (path: [1, 5], label: "Close", role: "AXButton"),
        (path: [1, 2], label: "Close", role: "AXButton"),
    ])
    #expect(MacActClosedLoop.dismissTarget(in: twins)?.path == [1, 2])
}

/// PINNING TEST — this asserts a KNOWN GAP, not a desired behaviour.
///
/// `dismissLabels` is English-only. On a Mac running any other UI language, or
/// any app whose dismiss button says "Not Now" / "Discard" / "Got it", the
/// dismiss verb finds no target and returns the same empty answer as a screen
/// with no dialog at all — the fence's clearest locale-shaped silent zero.
///
/// When that is fixed (a localized table, or an AXCancel-role fallback), THIS
/// TEST MUST FAIL. That is the point: the fix should be a deliberate act that
/// updates `docs/evals/ledger.json` row `actloop.dismissLabels`, not a quiet
/// behaviour change nobody notices.
@Test
func dismissCannotYetNameANonEnglishOrRoleOnlyCloseControl() {
    for label in ["Abbrechen", "Annuler", "Not Now", "Discard", "Got it", "取消"] {
        let frame = waveADismissFrame(modalPath: [1], controls: [
            (path: [1, 0], label: label, role: "AXButton"),
        ])
        #expect(MacActClosedLoop.dismissTarget(in: frame) == nil,
                "KNOWN GAP: \(label) is not in dismissLabels. If this now resolves, the locale hole is closed — update ledger row actloop.dismissLabels.")
    }
    // An unlabeled control carrying only the AXCancel-shaped role is likewise
    // invisible to the label-only match.
    let roleOnly = waveADismissFrame(modalPath: [1], controls: [
        (path: [1, 0], label: nil, role: "AXButton"),
    ])
    #expect(MacActClosedLoop.dismissTarget(in: roleOnly) == nil)
}

// ============================================================================
// ROW: feed.remoteEffectReceipts  (UNCOVERED → partially covered)
//
// The receipts JSONL is the only durable record that a remote command ever ran
// on another machine. The APPEND itself cannot be proven without a seam (see
// productionSeamNeeded: `runSSH` is a private static with no injectable
// runner), so what is pinned here is the half that is reachable: a refused
// execution must never fabricate a receipt, and the fingerprint the receipt
// would carry is honest.
// ============================================================================

@Test
func aRefusedRemoteEffectNeverWritesAReceipt() async throws {
    let root = try waveARoot("remote-receipts")
    defer { try? FileManager.default.removeItem(at: root) }
    let receipts = root.appendingPathComponent("mac_control/remote_effect_receipts.jsonl")
    let store = TrustedRemoteEffectNodeStore(root: root)

    let disabled = TrustedRemoteEffectNode(
        id: "node-off",
        name: "Off",
        host: "off.example.test",
        user: "builder",
        hostKeyAlgorithm: "ssh-ed25519",
        hostKey: Data(repeating: 3, count: 32).base64EncodedString(),
        allowedExecutables: ["/usr/bin/git"],
        enabled: false
    )
    _ = try await store.upsert(disabled)

    // An id nobody registered.
    await #expect(throws: TrustedRemoteEffectError.unknownNode("ghost")) {
        try await store.execute(nodeId: "ghost", executable: "/usr/bin/git", arguments: ["status"])
    }
    // A registered but DISABLED node — the switch a human turned off.
    await #expect(throws: TrustedRemoteEffectError.disabledNode("Off")) {
        try await store.execute(nodeId: "node-off", executable: "/usr/bin/git", arguments: ["status"])
    }
    #expect(!FileManager.default.fileExists(atPath: receipts.path),
            "a refusal must leave no receipt — a receipt is a claim that something RAN")
}

@Test
func remoteNodeFingerprintIsDerivedFromTheKeyAndNeverSilentlyInvalid() async throws {
    let root = try waveARoot("remote-fingerprint")
    defer { try? FileManager.default.removeItem(at: root) }
    let store = TrustedRemoteEffectNodeStore(root: root)

    let node = TrustedRemoteEffectNode(
        id: "node-fp",
        name: "Build",
        host: "build.example.test",
        user: "builder",
        hostKeyAlgorithm: "ssh-ed25519",
        hostKey: Data(repeating: 9, count: 32).base64EncodedString(),
        allowedExecutables: ["/usr/bin/git"],
        enabled: true
    )
    let saved = try await store.upsert(node)
    let fingerprint = try #require(saved.hostKeyFingerprint)
    #expect(fingerprint.hasPrefix("SHA256:"))
    #expect(!fingerprint.contains("="), "the fingerprint is base64 with padding trimmed")
    // The receipt records `hostKeyFingerprint ?? "invalid"`. For a node the
    // store accepted, that fallback must be unreachable.
    #expect(fingerprint != "invalid")

    // A DIFFERENT key is a different fingerprint — otherwise the receipt could
    // not tell which machine's identity was actually pinned.
    var other = node
    other.hostKey = Data(repeating: 10, count: 32).base64EncodedString()
    #expect(other.hostKeyFingerprint != fingerprint)

    // …and the "invalid" arm only exists for a key `validate` would reject.
    var bogus = node
    bogus.hostKey = "not base64 at all !!!"
    #expect(bogus.hostKeyFingerprint == nil)
    await #expect(throws: TrustedRemoteEffectError.invalidNode("host key")) {
        _ = try await store.upsert(bogus)
    }
}

// ============================================================================
// ROW: screenvision.requestPermission + screenvision.captureToggleBypass
//      (both UNCOVERED → covered, source-conformance tier)
//
// A test may not CALL `CGRequestScreenCaptureAccess` — on a machine without
// the grant it fires (or permanently records) a real TCC decision, which is a
// host side effect a test target has no business causing. What CAN be pinned
// without touching TCC is the SHAPE of the code: which entry points may
// request, which must only preflight, and that capture is fail-closed.
// ============================================================================

private func waveASource(_ relative: String) throws -> String {
    let modules = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent()   // MacControlTests
        .deletingLastPathComponent()   // Tests
        .deletingLastPathComponent()   // NativeAgentCore
        .appendingPathComponent("Sources")
    return try String(contentsOf: modules.appendingPathComponent(relative), encoding: .utf8)
}

private func waveACodeOnly(_ source: String) -> String {
    source.split(separator: "\n", omittingEmptySubsequences: false)
        .map { line -> Substring in
            guard let marker = line.range(of: "//") else { return line }
            return line[line.startIndex..<marker.lowerBound]
        }
        .joined(separator: "\n")
}

@Test
func screenRecordingIsRequestedFromExactlyOneSiteAndStatusOnlyEverPreflights() throws {
    let permissions = waveACodeOnly(try waveASource("ScreenVision/ScreenVision+Permissions.swift"))
    let vision = waveACodeOnly(try waveASource("ScreenVision/ScreenVision.swift"))

    // POSITIVE CONTROL first: the symbols this audit greps for must exist, or
    // every assertion below passes on an empty match.
    #expect(permissions.contains("CGRequestScreenCaptureAccess()"))
    #expect(permissions.contains("CGPreflightScreenCaptureAccess()"))

    // THE PROMPTING CALL lives in exactly one place. A second site anywhere in
    // the module is a second lane that can burn the user's one-shot grant.
    let requestSites = (permissions + "\n" + vision)
        .components(separatedBy: "CGRequestScreenCaptureAccess(").count - 1
    #expect(requestSites == 1,
            "CGRequestScreenCaptureAccess must have exactly one call site; found \(requestSites)")

    // `requestAccess` PREFLIGHTS FIRST, so an already-granted machine never
    // re-enters the prompting path.
    let requestBody = permissions
        .components(separatedBy: "public static func requestAccess()").last ?? ""
    #expect(requestBody.contains("if CGPreflightScreenCaptureAccess() { return true }"),
            "requestAccess must short-circuit on the existing grant before it can prompt")

    // READING the status must never prompt. `permissionStatus` and
    // `isAuthorized` are the gate-a-button callers; a drift to requestAccess()
    // there means merely rendering a settings row fires a TCC prompt.
    let statusBody = vision
        .components(separatedBy: "public func permissionStatus()").last?
        .components(separatedBy: "public func").first ?? ""
    #expect(statusBody.contains("ScreenVisionPermissions.isAuthorized()"))
    #expect(!statusBody.contains("requestAccess"),
            "permissionStatus must be a pure read — it gates UI and must never prompt")

    // CAPTURE IS FAIL-CLOSED: the guard is what turns a denied grant into a
    // typed error instead of an empty image the agent reads as "nothing there".
    #expect(vision.contains("guard ScreenVisionPermissions.requestAccess() else {"),
            "captureScreen must refuse before it captures")
    let captureBody = vision
        .components(separatedBy: "public func captureScreen()").last?
        .components(separatedBy: "SCShareableContent").first ?? ""
    #expect(captureBody.contains("throw ScreenVisionError.permissionDenied"),
            "an unauthorized capture must throw, never return empty bytes")

    // `requestPermission()` is the actor's user-initiated entry point and must
    // delegate rather than owning a second TCC path of its own.
    let requestPermissionBody = vision
        .components(separatedBy: "public func requestPermission()").last ?? ""
    #expect(requestPermissionBody.contains("ScreenVisionPermissions.requestAccess()"))
    #expect(!requestPermissionBody.contains("CGRequestScreenCaptureAccess("),
            "requestPermission must go through the single request site, not around it")
}

/// PINNING TEST — this asserts a KNOWN GAP, not a desired behaviour.
///
/// `SwiftNativeScreenVision.captureScreen()` reads NO capture policy: the
/// screen-capture toggle is enforced only by SwiftUI `guard`s in views. The
/// module cannot be handed a policy today, so this pins the shape of the
/// module rather than pretending a gate exists — and it will fail the moment a
/// policy read is added, which is exactly when ledger row
/// `screenvision.captureToggleBypass` must be re-rated.
@Test
func screenVisionCaptureCallSitesAreTheTwoKnownUngatedOnes() throws {
    let vision = waveACodeOnly(try waveASource("ScreenVision/ScreenVision.swift"))

    // (a) The module itself reads NO capture policy. That is the gap: the
    // toggle is enforced only by SwiftUI guards in views, so any non-view
    // caller bypasses the user's consent silently and still gets PNG bytes.
    for policySymbol in ["multimodalPolicy", "screen_capture", "screenCaptureEnabled", "captureEnabled"] {
        #expect(!vision.contains(policySymbol),
                "KNOWN GAP: ScreenVision gained a policy read (\(policySymbol)). That is the fix ledger row screenvision.captureToggleBypass asks for — re-rate the row.")
    }

    // (b) DRIFT DETECTION on the callers. Wiring a third call site — a /show
    // command, an autonomous step, exactly the uses the seam's own comment
    // anticipates — is precisely how the bypass ships, so the set is
    // enumerated rather than bounded.
    let repoRoot = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent()   // MacControlTests
        .deletingLastPathComponent()   // Tests
        .deletingLastPathComponent()   // NativeAgentCore
        .deletingLastPathComponent()   // Modules
        .deletingLastPathComponent()   // repo root
    var callSites: [String] = []
    for searchRoot in ["Modules/NativeAgentCore/Sources", "Sources", "iOS"] {
        let url = repoRoot.appendingPathComponent(searchRoot)
        guard let walker = FileManager.default.enumerator(at: url, includingPropertiesForKeys: nil) else { continue }
        for case let file as URL in walker where file.pathExtension == "swift" {
            guard let text = try? String(contentsOf: file, encoding: .utf8) else { continue }
            for (index, line) in waveACodeOnly(text).split(separator: "\n", omittingEmptySubsequences: false).enumerated() {
                guard line.contains("captureScreen()"), !line.contains("func captureScreen()") else { continue }
                callSites.append("\(file.lastPathComponent):\(index + 1)")
            }
        }
    }
    #expect(!callSites.isEmpty, "the caller grep must match something, or this audit is vacuous")
    #expect(Set(callSites.map { $0.split(separator: ":").first.map(String.init) ?? $0 })
                == ["NativeClient+CutoverSeams.swift", "ContentView.swift"],
            "captureScreen() call sites drifted: \(callSites.sorted()). Every new caller must check the screen-capture policy first — the module will not do it for you.")
}

// ============================================================================
// ROW: maccontrol.makeMacControl  (REPORTS-ONLY → covered)
//
// SILENT FAILURE: the factory hands back a client whose CANONICAL OPERATION
// STORE is nil unless a data root can be derived. With no store, `dispatch`
// takes the short path — no operationId, no idempotency, no cancellation
// identity, no durable lifecycle row. Every result still looks well-formed, so
// a caller assembled without a root loses the entire audit trail silently.
//
// `ax_status` is used as the probe because it is a pure READ: it reports the
// accessibility trust state and never touches the screen, the pointer, or the
// keyboard.
// ============================================================================

@Test
func makeMacControlWiresTheOperationStoreExactlyWhenARootCanBeDerived() async throws {
    let root = try waveARoot("factory")
    defer { try? FileManager.default.removeItem(at: root) }

    // (a) NO ROOT ⇒ NO STORE. The result is still ok — the read succeeded —
    // but it carries no operation identity, which is the tell.
    let rootless = try await makeMacControl().dispatch(action: "ax_status", body: [:])
    #expect(rootless.ok, "ax_status is a status read; it reports rather than fails")
    #expect(rootless.operationId == nil,
            "a client with no data root has no canonical lifecycle — the absence must be visible")
    #expect(rootless.operationState == nil)

    // (b) AN EXPLICIT ROOT ⇒ a store, a durable row, and an identity on the
    // result.
    let explicitRoot = root.appendingPathComponent("explicit", isDirectory: true)
    let explicit = try await makeMacControl(operationDataRoot: explicitRoot)
        .dispatch(action: "ax_status", body: ["operationId": .string("factory-explicit")])
    #expect(explicit.operationId == "factory-explicit")
    #expect(explicit.operationState == .completed)
    let explicitPath = explicitRoot.appendingPathComponent("mac_control/operations.json")
    #expect(FileManager.default.fileExists(atPath: explicitPath.path),
            "the derived store must actually write where the factory says it does")

    // (c) DERIVED FROM THE AUDIT PATH. This is the production assembly: the
    // dispatcher passes an audit path and expects the store to land beside it.
    // A drift here puts operations.json in the wrong tree and nothing says so.
    let auditRoot = root.appendingPathComponent("derived", isDirectory: true)
    try FileManager.default.createDirectory(at: auditRoot, withIntermediateDirectories: true)
    let derived = try await makeMacControl(
        auditAppendPath: auditRoot.appendingPathComponent("mac_control_audit.jsonl")
    ).dispatch(action: "ax_status", body: ["operationId": .string("factory-derived")])
    #expect(derived.operationId == "factory-derived")
    #expect(FileManager.default.fileExists(
        atPath: auditRoot.appendingPathComponent("mac_control/operations.json").path
    ), "the store must be derived from the audit path's DIRECTORY, not from the file itself")

    // (d) An explicit root WINS over the audit path — the two must not silently
    // fight and write two half-histories.
    let bothRoot = root.appendingPathComponent("both", isDirectory: true)
    _ = try await makeMacControl(
        auditAppendPath: auditRoot.appendingPathComponent("mac_control_audit.jsonl"),
        operationDataRoot: bothRoot
    ).dispatch(action: "ax_status", body: ["operationId": .string("factory-both")])
    #expect(FileManager.default.fileExists(
        atPath: bothRoot.appendingPathComponent("mac_control/operations.json").path
    ))
    let auditStore = MacControlOperationStore(dataRoot: auditRoot)
    #expect(try await auditStore.record(operationId: "factory-both") == nil,
            "an explicit root must not leak rows into the audit-derived one")
}
