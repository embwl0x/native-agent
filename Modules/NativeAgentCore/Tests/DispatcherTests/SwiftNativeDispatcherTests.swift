import Foundation
import Testing
import NativeAgentCore
import PersistenceCore
@testable import Dispatcher

// MARK: - Fake HTTP client

actor _FakeDispatcherHTTP: DispatcherHTTPClient {
    struct Invocation: Equatable {
        let url: URL
        let body: Data
        let timeout: TimeInterval
    }
    private var responses: [(status: Int, body: Data, throwing: Error?)] = []
    private(set) var invocations: [Invocation] = []

    func queueResponse(status: Int, body: Data = Data("{}".utf8)) {
        responses.append((status, body, nil))
    }
    func queueError(_ err: Error) {
        responses.append((0, Data(), err))
    }

    func postJSON(url: URL, body: Data, timeout: TimeInterval) async throws -> (status: Int, body: Data) {
        invocations.append(.init(url: url, body: body, timeout: timeout))
        guard !responses.isEmpty else {
            return (200, Data("{}".utf8))
        }
        let r = responses.removeFirst()
        if let e = r.throwing { throw e }
        return (r.status, r.body)
    }
}

// MARK: - Helpers

private func makeTempDir() -> URL {
    let url = URL(fileURLWithPath: NSTemporaryDirectory())
        .appendingPathComponent("DispatcherTests-\(UUID().uuidString)", isDirectory: true)
    try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
    return url
}

private func canonicalDispatchResponse(
    tool: String = "capabilities.summary",
    status: String = "ok",
    output: String = "{\"count\": 12}",
    runId: String = "run-1"
) -> Data {
    let json = """
    {
      "ok": true,
      "tool": "\(tool)",
      "status": "\(status)",
      "output": \(output),
      "error": null,
      "executed": true,
      "verify_passed": true,
      "duration_us": 1234,
      "duration_ms": 1,
      "args_hash": "abcdef1234567890",
      "effective_autonomy": "auto",
      "autonomy_source": "default",
      "provider_match": true,
      "trace_event_id": "evt-1",
      "run_id": "\(runId)",
      "started_at": "2026-05-31T00:00:00.000000+00:00"
    }
    """
    return Data(json.utf8)
}

// MARK: - Factory

@Test func factoryReturnsSwiftNative() {
    let d = makeDispatcher()
    #expect(d is SwiftNativeDispatcher)
}

/// Registration-time fail-closed guard (2026-07-21 audit, pending_approval
/// dead-end): the factory is the production registration seam. A registry
/// carrying a SIDE-EFFECTING action with NO autonomyResolver would dispatch-
/// time fail-closed to "ask" and return status="pending_approval" with NO
/// approval record staged anywhere — an unapprovable dead-end. The factory
/// REFUSES the registration instead: the side-effecting handler is stripped
/// (dispatch then fails honestly with native_handler_missing), read-only
/// actions pass through untouched, and wiring a resolver keeps the full
/// registry. The dispatch-time A4b guard on direct SwiftNativeDispatcher
/// construction is unaffected (FileSystemActionsTests pin stays green).
@Test func factoryRefusesSideEffectingRegistryWithoutResolver() async throws {
    let http = _FakeDispatcherHTTP()
    let ledger = DispatchLedger(
        ledgerPath: makeTempDir().appendingPathComponent("traces/events.jsonl")
    )
    let registry = LocalConnectorActions(
        handlers: [
            "probe_write": { _, _ in .object(["ok": .bool(true)]) },
            "probe_read": { _, _ in .object(["ok": .bool(true)]) },
        ],
        sideEffecting: ["probe_write"],
        trivialVerify: ["probe_read"]
    )
    let ctx = DispatchContext.defaultForSurface("native_actions")

    // No resolver wired: the side-effecting action is NOT reachable — an
    // honest failure, never an unapprovable pending_approval.
    let unguarded = makeDispatcher(http: http, ledger: ledger, localActions: registry)
    let refused = try await unguarded.dispatch(
        tool: "probe_write", input: [:], ctx: ctx, dryRun: false
    )
    #expect(refused.error?.code == "native_handler_missing")
    #expect(refused.executed == false)
    #expect(refused.status != "pending_approval")

    // Read-only actions pass through exactly as today.
    let readOnly = try await unguarded.dispatch(
        tool: "probe_read", input: [:], ctx: ctx, dryRun: false
    )
    #expect(readOnly.executed == true)
    #expect(readOnly.verifyPassed == true)

    // Resolver wired: the full registry stays reachable — no refusal.
    let guarded = makeDispatcher(
        http: http,
        ledger: ledger,
        localActions: registry,
        autonomyResolver: { _ in "auto" }
    )
    let allowed = try await guarded.dispatch(
        tool: "probe_write", input: [:], ctx: ctx, dryRun: false
    )
    #expect(allowed.executed == true)
}

// MARK: - 4. Request shape

@Test func buildRequestBodyEmitsCanonicalDispatchEnvelope() throws {
    let ctx = DispatchContext.defaultForSurface("chat", sessionId: "sess-1")
    let data = try buildDispatchRequestBody(
        tool: "capabilities.summary",
        input: ["x": .int(1)],
        ctx: ctx,
        dryRun: false
    )
    let parsed = try JSONValue.parse(data)
    guard case .object(let obj) = parsed else {
        Issue.record("expected top-level object")
        return
    }
    if case .string(let s) = obj["tool"] ?? .null {
        #expect(s == "capabilities.summary")
    } else { Issue.record("missing tool") }
    if case .object(let input) = obj["input"] ?? .null,
       case .int(let n) = input["x"] ?? .null {
        #expect(n == 1)
    } else { Issue.record("input.x missing") }
    if case .string(let s) = obj["surface"] ?? .null {
        #expect(s == "chat")
    } else { Issue.record("missing surface") }
    if case .bool(let b) = obj["dry_run"] ?? .null {
        #expect(b == false)
    } else { Issue.record("missing dry_run") }
    if case .string(let s) = obj["session_id"] ?? .null {
        #expect(s == "sess-1")
    } else { Issue.record("missing session_id") }
}

// MARK: - 5. Empty tool rejected

@Test func buildRequestBodyRejectsEmptyTool() {
    let ctx = DispatchContext.defaultForSurface("chat")
    do {
        _ = try buildDispatchRequestBody(tool: "   ", input: [:], ctx: ctx, dryRun: false)
        Issue.record("expected throw")
    } catch let e as DispatcherError {
        #expect(e == .missingTool)
    } catch {
        Issue.record("wrong error type: \(error)")
    }
}

// MARK: - 6. Missing native handler fails closed

@Test func swiftNativeMissingHandlerFailsClosedAndWritesLedger() async throws {
    let tmp = makeTempDir()
    let ledgerPath = tmp.appendingPathComponent("traces/events.jsonl")
    let ledger = DispatchLedger(ledgerPath: ledgerPath)
    let fake = _FakeDispatcherHTTP()
    let d = SwiftNativeDispatcher(
        baseURL: URL(string: "http://127.0.0.1:9999")!,
        http: fake,
        timeout: 5,
        ledger: ledger
    )
    let result = try await d.dispatch(
        tool: "capabilities.summary",
        input: ["x": .int(1)],
        ctx: DispatchContext.defaultForSurface("chat", sessionId: "s-1"),
        dryRun: false
    )
    #expect(result.tool == "capabilities.summary")
    #expect(result.ok == false)
    #expect(result.status == "failed")
    #expect(result.executed == false)
    #expect(result.error?.code == "native_handler_missing")
    #expect(result.providerMatch == false)
    let invs = await fake.invocations
    #expect(invs.isEmpty)
    let tail = try await ledger.tail(limit: 10)
    #expect(tail.count == 1)
    #expect(tail[0].title == "tool:capabilities.summary")
    #expect(tail[0].status == "failed")
}

// MARK: - 7. Ledger JSONL round-trip

@Test func ledgerRoundTrip() async throws {
    let tmp = makeTempDir()
    let ledgerPath = tmp.appendingPathComponent("traces/events.jsonl")
    let ledger = DispatchLedger(ledgerPath: ledgerPath)
    let entry = DispatchLedgerEntry(
        id: "id-1",
        title: "tool:foo",
        status: "ok",
        payload: .object(["k": .string("v")]),
        createdAt: "2026-05-31T00:00:00.000000+00:00"
    )
    try await ledger.append(entry)
    let tail = try await ledger.tail(limit: 5)
    #expect(tail.count == 1)
    #expect(tail[0].id == "id-1")
    #expect(tail[0].title == "tool:foo")
    #expect(tail[0].status == "ok")
}

// MARK: - 12. Ledger flock-safe concurrent appends

@Test func ledgerConcurrentAppends() async throws {
    let tmp = makeTempDir()
    let ledgerPath = tmp.appendingPathComponent("traces/events.jsonl")
    let ledger = DispatchLedger(ledgerPath: ledgerPath)
    await withTaskGroup(of: Void.self) { group in
        for i in 0..<20 {
            group.addTask {
                let entry = DispatchLedgerEntry(
                    id: "id-\(i)",
                    title: "tool:c-\(i)",
                    status: "ok",
                    payload: .object(["i": .int(Int64(i))]),
                    createdAt: "2026-05-31T00:00:00.000000+00:00"
                )
                try? await ledger.append(entry)
            }
        }
    }
    let tail = try await ledger.tail(limit: 100)
    #expect(tail.count == 20)
    let ids = Set(tail.map { $0.id })
    #expect(ids.count == 20)
}

// MARK: - 13. dispatcherArgsHash stable

@Test func argsHashStable() {
    let a = dispatcherArgsHash(["x": .int(1), "y": .string("two")])
    let b = dispatcherArgsHash(["x": .int(1), "y": .string("two")])
    #expect(a == b)
    let c = dispatcherArgsHash(["x": .int(2), "y": .string("two")])
    #expect(a != c)
}

// MARK: - 14. dispatcherNowISO format

@Test func nowISOMatchesPythonShape() {
    let s = dispatcherNowISO(Date(timeIntervalSince1970: 1_700_000_000))
    let pattern = "^\\d{4}-\\d{2}-\\d{2}T\\d{2}:\\d{2}:\\d{2}(\\.\\d{6})?\\+00:00$"
    let regex = try! NSRegularExpression(pattern: pattern)
    let range = NSRange(s.startIndex..., in: s)
    #expect(regex.firstMatch(in: s, range: range) != nil, "got: \(s)")
}

@Test func nowISOMatchesPythonShapeAtZeroMicroseconds() {
    // Zero microseconds → no fraction (matches Python's isoformat()).
    let zero = dispatcherNowISO(Date(timeIntervalSince1970: 1_717_154_096.0))
    #expect(!zero.contains("."), "expected no fraction at zero micro, got: \(zero)")
    #expect(zero.hasSuffix("+00:00"))

    // Non-zero microseconds → fraction present.
    let nonZero = dispatcherNowISO(Date(timeIntervalSince1970: 1_717_154_096.123456))
    #expect(nonZero.contains("."), "expected fraction, got: \(nonZero)")
    let pattern = "^\\d{4}-\\d{2}-\\d{2}T\\d{2}:\\d{2}:\\d{2}\\.\\d{6}\\+00:00$"
    let regex = try! NSRegularExpression(pattern: pattern)
    let range = NSRange(nonZero.startIndex..., in: nonZero)
    #expect(regex.firstMatch(in: nonZero, range: range) != nil, "got: \(nonZero)")
}

// MARK: - 15. §6.159 (wave 37 W06) — native failed-handler DispatchError.recoverable parity
//
// `persona_read` is owned by LocalConnectorActions.personaReadOnly. A
// failed-handler-return
// receipt (a handler that RAN and returned ok=False) sets recoverable=TRUE
//. These tests drive the EXACT live-flip
// configuration and pin that the native receipt matches: a handler that
// executed and failed is recoverable=true, executed=true, status="failed".

/// A DispatchContext whose extra carries the test data-root override so the
/// native ConnectorActionContext resolves persona/data roots under `dataRoot`.
private func nativeFlipContext(dataRoot: URL) -> DispatchContext {
    DispatchContext(
        repoRoot: "",
        cwd: "",
        surface: "chat",
        sessionId: "s-flip",
        persona: "",
        activeProvider: "",
        extra: ["_na_data_root": .string(dataRoot.path)]
    )
}

@Test func nativePersonaReadBadKindIsRecoverable() async throws {
    // bad_input: an unknown `kind` is rejected by the handler INSIDE the action
    // (it RAN), so the daemon-parallel receipt is status="failed", executed=true,
    // recoverable=true. The pre-fix code hardcoded recoverable=false here.
    let tmp = makeTempDir()
    let ledger = DispatchLedger(ledgerPath: tmp.appendingPathComponent("traces/events.jsonl"))
    let d = SwiftNativeDispatcher(
        baseURL: URL(string: "http://127.0.0.1:9999")!,
        http: _FakeDispatcherHTTP(),   // never consulted: native handler claims the tool
        timeout: 5,
        ledger: ledger,
        localActions: .personaReadOnly
    )
    let result = try await d.dispatch(
        tool: "persona_read",
        input: ["kind": .string("not_a_real_kind")],
        ctx: nativeFlipContext(dataRoot: tmp),
        dryRun: false
    )
    #expect(result.status == "failed")
    #expect(result.executed == true)
    #expect(result.ok == false)
    guard let err = result.error else {
        Issue.record("expected a DispatchError on a failed native handler")
        return
    }
    #expect(err.code == "bad_input")
    // The parity fix: matches the retired daemon recoverable=True.
    #expect(err.recoverable == true, "native failed-handler receipt must be recoverable=true to match the daemon")
    // verify_passed is None on a failed run.
    #expect(result.verifyPassed == nil)
}

@Test func nativePersonaReadNotFoundIsRecoverable() async throws {
    // persona_not_found: a valid kind whose persona file is absent under the
    // temp data root. Handler RAN and returned ok=False → recoverable=true.
    let tmp = makeTempDir()
    let ledger = DispatchLedger(ledgerPath: tmp.appendingPathComponent("traces/events.jsonl"))
    let d = SwiftNativeDispatcher(
        baseURL: URL(string: "http://127.0.0.1:9999")!,
        http: _FakeDispatcherHTTP(),
        timeout: 5,
        ledger: ledger,
        localActions: .personaReadOnly
    )
    let result = try await d.dispatch(
        tool: "persona_read",
        input: ["kind": .string("soul")],   // <tmp>/memory/SOUL.md does not exist
        ctx: nativeFlipContext(dataRoot: tmp),
        dryRun: false
    )
    #expect(result.status == "failed")
    #expect(result.executed == true)
    guard let err = result.error else {
        Issue.record("expected a DispatchError on a missing persona file")
        return
    }
    #expect(err.code == "persona_not_found")
    #expect(err.recoverable == true)
}

@Test func nativePersonaReadSuccessHasNoError() async throws {
    // Success path control: a real persona file read → status="ok", no error,
    // verify_passed=true (persona_read is TRIVIAL_VERIFY).
    let tmp = makeTempDir()
    let personaDir = tmp.appendingPathComponent("memory", isDirectory: true)
    try FileManager.default.createDirectory(at: personaDir, withIntermediateDirectories: true)
    try "I am the soul.".write(
        to: personaDir.appendingPathComponent("SOUL.md"), atomically: true, encoding: .utf8)
    let ledger = DispatchLedger(ledgerPath: tmp.appendingPathComponent("traces/events.jsonl"))
    let d = SwiftNativeDispatcher(
        baseURL: URL(string: "http://127.0.0.1:9999")!,
        http: _FakeDispatcherHTTP(),
        timeout: 5,
        ledger: ledger,
        localActions: .personaReadOnly
    )
    let result = try await d.dispatch(
        tool: "persona_read",
        input: ["kind": .string("soul")],
        ctx: nativeFlipContext(dataRoot: tmp),
        dryRun: false
    )
    #expect(result.status == "ok")
    #expect(result.ok == true)
    #expect(result.error == nil)
    #expect(result.verifyPassed == true)
}
