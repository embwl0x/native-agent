import Foundation
import Testing
import NativeAgentCore
import PersistenceCore
@testable import Dispatcher

// MARK: - Wave 29 W3: native connector-action tests
//
// Exercises the 5 ported file/system connector actions both directly
// (FileSystemActions.*) and through SwiftNativeDispatcher's native-execution
// path (localActions: .fileSystemDefault). Parity targets are the Python
// handlers in the retired daemon + the retired daemon.

// MARK: - Test fixtures

private func makeSandbox() -> URL {
    let url = URL(fileURLWithPath: NSTemporaryDirectory())
        .appendingPathComponent("FSActions-\(UUID().uuidString)", isDirectory: true)
    try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
    return url.resolvingSymlinksInPath()
}

/// A context whose repo_root is the sandbox, so relative paths resolve there
/// and the sandbox check passes for anything under it.
private func ctx(_ sandbox: URL, fileAccess: [String: JSONValue] = [:], dataRoot: String? = nil) -> ConnectorActionContext {
    ConnectorActionContext(repoRoot: sandbox.path, fileAccess: fileAccess, dataRoot: dataRoot)
}

private func okObj(_ v: JSONValue) -> [String: JSONValue]? {
    guard case .object(let o) = v else { return nil }
    return o
}

private func str(_ v: JSONValue?) -> String? {
    if case .string(let s)? = v { return s }
    return nil
}

private func int(_ v: JSONValue?) -> Int? {
    switch v ?? .null {
    case .int(let i): return Int(i)
    case .double(let d): return Int(d)
    default: return nil
    }
}

private func bool(_ v: JSONValue?) -> Bool? {
    if case .bool(let b)? = v { return b }
    return nil
}

/// Local copy of a canonical daemon `/v1/dispatch` response (the sibling test
/// file's helper is `private` to that file).
private func fsCanonicalDispatchResponse(tool: String) -> Data {
    Data("""
    {
      "ok": true, "tool": "\(tool)", "status": "ok", "output": {"x": 1},
      "error": null, "executed": true, "verify_passed": true,
      "duration_us": 1, "duration_ms": 1, "args_hash": "abcdef1234567890",
      "effective_autonomy": "auto", "autonomy_source": "default",
      "provider_match": true, "trace_event_id": "evt-1", "run_id": "run-1",
      "started_at": "2026-05-31T00:00:00.000000+00:00"
    }
    """.utf8)
}

// MARK: - read_file

@Test func readFileReturnsContentAndBytes() throws {
    let sb = makeSandbox()
    let file = sb.appendingPathComponent("hello.txt")
    try "hello world".write(to: file, atomically: true, encoding: .utf8)

    let res = FileSystemActions.readFile(["path": .string(file.path)], ctx(sb))
    let obj = try #require(okObj(res))
    #expect(bool(obj["ok"]) == true)
    #expect(str(obj["content"]) == "hello world")
    #expect(int(obj["bytes"]) == 11)
    #expect(str(obj["path"]) == file.path)
}

@Test func readFileMissingPathIsBadInput() {
    let sb = makeSandbox()
    let res = FileSystemActions.readFile([:], ctx(sb))
    let obj = okObj(res)!
    #expect(bool(obj["ok"]) == false)
    #expect(str(obj["error_code"]) == "bad_input")
}

@Test func readFileNotFound() {
    let sb = makeSandbox()
    let res = FileSystemActions.readFile(["path": .string(sb.appendingPathComponent("nope.txt").path)], ctx(sb))
    let obj = okObj(res)!
    #expect(bool(obj["ok"]) == false)
    #expect(str(obj["error_code"]) == "file_not_found")
}

@Test func readFileMaxBytesTruncatesByteWindow() throws {
    let sb = makeSandbox()
    let file = sb.appendingPathComponent("big.txt")
    try String(repeating: "x", count: 100).write(to: file, atomically: true, encoding: .utf8)
    let res = FileSystemActions.readFile(["path": .string(file.path), "max_bytes": .int(10)], ctx(sb))
    let obj = okObj(res)!
    #expect(str(obj["content"])?.count == 10)
    #expect(int(obj["bytes"]) == 100)  // reports actual file size, not the slice
    #expect(int(obj["returned_bytes"]) == 10)
    #expect(bool(obj["truncated"]) == true)
}

@Test func readFileCompactsLongHandoffMarkdownByDefault() throws {
    let sb = makeSandbox()
    let file = sb.appendingPathComponent("HANDOFF_CURRENT.md")
    let body = String(repeating: "handoff-line\n", count: 4_000)
    try body.write(to: file, atomically: true, encoding: .utf8)

    let res = FileSystemActions.readFile(["path": .string(file.path)], ctx(sb))
    let obj = try #require(okObj(res))

    #expect(bool(obj["ok"]) == true)
    #expect(int(obj["bytes"]) == body.utf8.count)
    #expect(int(obj["returned_bytes"]) == connectorReadFileHandoffDefaultMaxBytes)
    #expect(str(obj["content"])?.utf8.count == connectorReadFileHandoffDefaultMaxBytes)
    #expect(bool(obj["truncated"]) == true)
}

@Test func readFileExplicitMaxBytesOverridesLongHandoffDefault() throws {
    let sb = makeSandbox()
    let file = sb.appendingPathComponent("HANDOFF_CURRENT.md")
    let body = String(repeating: "handoff-line\n", count: 4_000)
    try body.write(to: file, atomically: true, encoding: .utf8)

    let res = FileSystemActions.readFile(
        ["path": .string(file.path), "max_bytes": .int(20_000)],
        ctx(sb)
    )
    let obj = try #require(okObj(res))

    #expect(bool(obj["ok"]) == true)
    #expect(int(obj["returned_bytes"]) == 20_000)
    #expect(str(obj["content"])?.utf8.count == 20_000)
    #expect(bool(obj["truncated"]) == true)
}

@Test func readFileBadMaxBytesIsBadInput() throws {
    let sb = makeSandbox()
    let file = sb.appendingPathComponent("a.txt")
    try "a".write(to: file, atomically: true, encoding: .utf8)
    let res = FileSystemActions.readFile(["path": .string(file.path), "max_bytes": .string("oops")], ctx(sb))
    let obj = okObj(res)!
    #expect(bool(obj["ok"]) == false)
    #expect(str(obj["error_code"]) == "bad_input")
}

@Test func readFileOutsideSandboxBlocked() throws {
    let sb = makeSandbox()
    // repo_root is sb; /etc/hosts is outside the sandbox root.
    let res = FileSystemActions.readFile(["path": .string("/etc/hosts")], ctx(sb))
    let obj = okObj(res)!
    #expect(bool(obj["ok"]) == false)
    #expect(str(obj["error_code"]) == "path_not_allowed")
}

@Test func readFileFullModeDisablesSandbox() throws {
    let sb = makeSandbox()
    let outside = makeSandbox().appendingPathComponent("out.txt")
    try "outside".write(to: outside, atomically: true, encoding: .utf8)
    // file_access.mode == "full" → sandbox disabled at this layer.
    let res = FileSystemActions.readFile(
        ["path": .string(outside.path)],
        ctx(sb, fileAccess: ["mode": .string("full")])
    )
    let obj = okObj(res)!
    #expect(bool(obj["ok"]) == true)
    #expect(str(obj["content"]) == "outside")
}

@Test func readFileSensitiveDataPathBlockedEvenWhenAllowed() throws {
    let sb = makeSandbox()
    let dataRoot = sb  // treat sandbox as data root
    let oauthDir = sb.appendingPathComponent("oauth")
    try FileManager.default.createDirectory(at: oauthDir, withIntermediateDirectories: true)
    let secret = oauthDir.appendingPathComponent("token.json")
    try "{\"token\":\"x\"}".write(to: secret, atomically: true, encoding: .utf8)
    // Path is inside repo_root (allowed) but under data/oauth → sensitive block.
    let res = FileSystemActions.readFile(
        ["path": .string(secret.path)],
        ctx(sb, dataRoot: dataRoot.path)
    )
    let obj = okObj(res)!
    #expect(bool(obj["ok"]) == false)
    #expect(str(obj["error_code"]) == "path_not_allowed")
}

@Test func sensitivePathBlockFallsBackToDefaultDataRootWhenNotThreaded() {
    // SECURITY regression (gpt-5.5 review): when no data root is threaded into
    // the context, the sensitive-path block must still fire using the DEFAULT
    // data root — otherwise full-mode/broad-root callers could read OAuth
    // tokens. isSensitiveDataPath is path-based (no file need exist).
    let defaultRoot = PersistenceCore.defaultDataRoot()
    let oauthFile = defaultRoot.appendingPathComponent("oauth/token.json")
    let ctxNoDataRoot = ConnectorActionContext(repoRoot: "/", dataRoot: nil)
    #expect(FileSystemActions.isSensitiveDataPath(oauthFile, ctxNoDataRoot) == true)
    // A non-sensitive path under the default root is NOT blocked.
    let benign = defaultRoot.appendingPathComponent("skills/foo.md")
    #expect(FileSystemActions.isSensitiveDataPath(benign, ctxNoDataRoot) == false)
    // A path entirely outside the data root is NOT blocked.
    #expect(FileSystemActions.isSensitiveDataPath(URL(fileURLWithPath: "/tmp/whatever.txt"), ctxNoDataRoot) == false)
}

@Test func writeFileAtomicOverwriteToNewNestedPathSucceeds() throws {
    // Regression (gpt-5.5 review): the atomic overwrite must create a brand-new
    // destination (rename(2) creates-or-replaces, like os.replace) and must NOT
    // leave a .tmp behind.
    let sb = makeSandbox()
    let file = sb.appendingPathComponent("a/b/c/fresh.txt")  // none of a/b/c exist
    let res = FileSystemActions.writeFile(
        ["path": .string(file.path), "content": .string("brand new")],
        ctx(sb)
    )
    #expect(bool(okObj(res)!["ok"]) == true)
    #expect(try String(contentsOf: file, encoding: .utf8) == "brand new")
    // No leftover .tmp in the parent dir.
    let siblings = (try? FileManager.default.contentsOfDirectory(atPath: file.deletingLastPathComponent().path)) ?? []
    #expect(siblings.allSatisfy { !$0.hasSuffix(".tmp") })
}

// MARK: - file_excerpt

@Test func fileExcerptNumbersLinesAndWindows() throws {
    let sb = makeSandbox()
    let file = sb.appendingPathComponent("lines.txt")
    try (1...10).map { "line\($0)" }.joined(separator: "\n").write(to: file, atomically: true, encoding: .utf8)
    let res = FileSystemActions.fileExcerpt(
        ["path": .string(file.path), "start_line": .int(3), "max_lines": .int(2)],
        ctx(sb)
    )
    let obj = okObj(res)!
    #expect(bool(obj["ok"]) == true)
    #expect(int(obj["start_line"]) == 3)
    #expect(int(obj["end_line"]) == 4)
    #expect(int(obj["total_lines"]) == 10)
    #expect(bool(obj["truncated"]) == true)
    #expect(str(obj["excerpt"]) == "3: line3\n4: line4")
}

@Test func fileExcerptCapsMaxLinesAt240() throws {
    let sb = makeSandbox()
    let file = sb.appendingPathComponent("many.txt")
    try (1...300).map { "L\($0)" }.joined(separator: "\n").write(to: file, atomically: true, encoding: .utf8)
    let res = FileSystemActions.fileExcerpt(
        ["path": .string(file.path), "start_line": .int(1), "max_lines": .int(1000)],
        ctx(sb)
    )
    let obj = okObj(res)!
    #expect(int(obj["end_line"]) == 240)  // capped
    #expect(bool(obj["truncated"]) == true)
}

@Test func fileExcerptEmptyFileSafe() throws {
    let sb = makeSandbox()
    let file = sb.appendingPathComponent("empty.txt")
    try "".write(to: file, atomically: true, encoding: .utf8)
    let res = FileSystemActions.fileExcerpt(["path": .string(file.path)], ctx(sb))
    let obj = okObj(res)!
    #expect(bool(obj["ok"]) == true)
    #expect(int(obj["total_lines"]) == 0)
    #expect(int(obj["start_line"]) == 1)
    #expect(str(obj["excerpt"]) == "")
}

// MARK: - write_file

@Test func writeFileOverwriteAndReportBytes() throws {
    let sb = makeSandbox()
    let file = sb.appendingPathComponent("nested/out.txt")
    let res = FileSystemActions.writeFile(
        ["path": .string(file.path), "content": .string("hi there")],
        ctx(sb)
    )
    let obj = okObj(res)!
    #expect(bool(obj["ok"]) == true)
    #expect(int(obj["bytes_written"]) == 8)
    #expect(bool(obj["append"]) == false)
    #expect(str(obj["after_content"]) == "hi there")
    // Parent dir was auto-created and the file is on disk.
    #expect(try String(contentsOf: file, encoding: .utf8) == "hi there")
}

@Test func writeFileAppendAddsToExisting() throws {
    let sb = makeSandbox()
    let file = sb.appendingPathComponent("log.txt")
    try "a".write(to: file, atomically: true, encoding: .utf8)
    let res = FileSystemActions.writeFile(
        ["path": .string(file.path), "content": .string("b"), "append": .bool(true)],
        ctx(sb)
    )
    let obj = okObj(res)!
    #expect(bool(obj["ok"]) == true)
    #expect(bool(obj["append"]) == true)
    #expect(obj["after_content"] == nil)  // append doesn't emit diff fields
    #expect(try String(contentsOf: file, encoding: .utf8) == "ab")
}

@Test func writeFileMissingContentIsBadInput() {
    let sb = makeSandbox()
    let res = FileSystemActions.writeFile(["path": .string(sb.appendingPathComponent("x").path)], ctx(sb))
    let obj = okObj(res)!
    #expect(bool(obj["ok"]) == false)
    #expect(str(obj["error_code"]) == "bad_input")
}

@Test func writeFileReadOnlyModeBlocked() {
    let sb = makeSandbox()
    let res = FileSystemActions.writeFile(
        ["path": .string(sb.appendingPathComponent("x").path), "content": .string("y")],
        ctx(sb, fileAccess: ["mode": .string("read_only")])
    )
    let obj = okObj(res)!
    #expect(bool(obj["ok"]) == false)
    #expect(str(obj["error_code"]) == "path_not_allowed")
}

@Test func writeFileSensitivePathBlocked() throws {
    let sb = makeSandbox()
    let target = sb.appendingPathComponent("secrets/cred.json")
    let res = FileSystemActions.writeFile(
        ["path": .string(target.path), "content": .string("nope")],
        ctx(sb, dataRoot: sb.path)
    )
    let obj = okObj(res)!
    #expect(bool(obj["ok"]) == false)
    #expect(str(obj["error_code"]) == "path_not_allowed")
    #expect(FileManager.default.fileExists(atPath: target.path) == false)
}

@Test func writeFileFullModeStillBlocksProtectedSystemPath() {
    let sb = makeSandbox()
    let res = FileSystemActions.writeFile(
        ["path": .string("/etc/hosts"), "content": .string("127.0.0.1 example.local")],
        ctx(sb, fileAccess: ["mode": .string("full")])
    )
    let obj = okObj(res)!
    #expect(bool(obj["ok"]) == false)
    #expect(str(obj["error_code"]) == "path_not_allowed")
    #expect(str(obj["error"])?.contains("protected_system_path_denied") == true)
}

@Test func writeFileOverwriteCapturesBeforeContent() throws {
    let sb = makeSandbox()
    let file = sb.appendingPathComponent("doc.txt")
    try "old".write(to: file, atomically: true, encoding: .utf8)
    let res = FileSystemActions.writeFile(
        ["path": .string(file.path), "content": .string("new")],
        ctx(sb)
    )
    let obj = okObj(res)!
    #expect(str(obj["before_content"]) == "old")
    #expect(str(obj["after_content"]) == "new")
}

// MARK: - list_dir

@Test func listDirSortsDirsFirstThenName() throws {
    let sb = makeSandbox()
    let fm = FileManager.default
    try fm.createDirectory(at: sb.appendingPathComponent("zdir"), withIntermediateDirectories: true)
    try fm.createDirectory(at: sb.appendingPathComponent("adir"), withIntermediateDirectories: true)
    try "x".write(to: sb.appendingPathComponent("bfile.txt"), atomically: true, encoding: .utf8)
    try "y".write(to: sb.appendingPathComponent("afile.txt"), atomically: true, encoding: .utf8)
    let res = FileSystemActions.listDir(["path": .string(sb.path)], ctx(sb))
    let obj = okObj(res)!
    #expect(bool(obj["ok"]) == true)
    guard case .array(let arr)? = obj["entries"] else { Issue.record("no entries"); return }
    let names = arr.compactMap { v -> String? in if case .string(let s) = v { return s }; return nil }
    // dirs first (sorted), then files (sorted), dirs get a trailing slash.
    #expect(names == ["adir/", "zdir/", "afile.txt", "bfile.txt"])
    #expect(int(obj["count"]) == 4)
}

@Test func listDirTruncatesAtMaxEntries() throws {
    let sb = makeSandbox()
    for i in 0..<5 {
        try "x".write(to: sb.appendingPathComponent("f\(i).txt"), atomically: true, encoding: .utf8)
    }
    let res = FileSystemActions.listDir(["path": .string(sb.path), "max_entries": .int(3)], ctx(sb))
    let obj = okObj(res)!
    #expect(int(obj["count"]) == 3)
    #expect(bool(obj["truncated"]) == true)
    #expect(int(obj["total_visible"]) == 5)
}

@Test func listDirDoesNotFollowChildSymlinkMetadata() throws {
    let sb = makeSandbox()
    let target = sb.appendingPathComponent("target", isDirectory: true)
    try FileManager.default.createDirectory(at: target, withIntermediateDirectories: true)
    try FileManager.default.createSymbolicLink(
        at: sb.appendingPathComponent("mounted-like-child"),
        withDestinationURL: target
    )

    let res = FileSystemActions.listDir(["path": .string(sb.path)], ctx(sb))
    let obj = okObj(res)!
    guard case .array(let arr)? = obj["entries"] else {
        Issue.record("no entries")
        return
    }
    let names = arr.compactMap { value -> String? in
        guard case .string(let name) = value else { return nil }
        return name
    }

    #expect(names.contains("target/"))
    #expect(names.contains("mounted-like-child"))
    #expect(!names.contains("mounted-like-child/"))
}

@Test func listDirNotADirectory() throws {
    let sb = makeSandbox()
    let file = sb.appendingPathComponent("f.txt")
    try "x".write(to: file, atomically: true, encoding: .utf8)
    let res = FileSystemActions.listDir(["path": .string(file.path)], ctx(sb))
    let obj = okObj(res)!
    #expect(bool(obj["ok"]) == false)
    #expect(str(obj["error_code"]) == "file_not_found")
}

@Test func listDirOutsideSandboxBlocked() {
    let sb = makeSandbox()
    let res = FileSystemActions.listDir(["path": .string("/etc")], ctx(sb))
    let obj = okObj(res)!
    #expect(bool(obj["ok"]) == false)
    #expect(str(obj["error_code"]) == "path_not_allowed")
}

// MARK: - system_info

@Test func systemInfoReturnsDiskAndShape() {
    let res = FileSystemActions.systemInfo([:], ConnectorActionContext(repoRoot: "/"))
    let obj = okObj(res)!
    // ok is true unless every single field failed (won't happen — disk always works).
    #expect(bool(obj["ok"]) == true)
    // Disk always present via statfs.
    guard case .object(let disk)? = obj["disk"] else { Issue.record("no disk field"); return }
    #expect(disk["total_gb"] != nil)
    #expect(disk["free_gb"] != nil)
    #expect(disk["used_gb"] != nil)
    #expect(disk["percent_used"] != nil)
}

// MARK: - SwiftNativeDispatcher native-execution path

@Test func nativeDispatchRunsReadFileWithoutHTTP() async throws {
    let sb = makeSandbox()
    let file = sb.appendingPathComponent("native.txt")
    try "native body".write(to: file, atomically: true, encoding: .utf8)

    let http = _FakeDispatcherHTTP()  // queue NOTHING → if HTTP is hit, default {} would mis-decode
    let ledgerPath = sb.appendingPathComponent("traces/events.jsonl")
    let ledger = DispatchLedger(ledgerPath: ledgerPath)
    let d = SwiftNativeDispatcher(
        http: http,
        ledger: ledger,
        localActions: .fileSystemDefault
    )
    let dctx = DispatchContext(
        repoRoot: sb.path, cwd: sb.path, surface: "chat", sessionId: "s",
        persona: "", activeProvider: "", extra: [:]
    )
    let result = try await d.dispatch(tool: "read_file", input: ["path": .string(file.path)], ctx: dctx, dryRun: false)
    #expect(result.ok == true)
    #expect(result.status == "ok")
    #expect(result.executed == true)
    #expect(result.autonomySource == "native")
    // Output carries the native result dict.
    if case .object(let o)? = result.output?.value, case .string(let content)? = o["content"] {
        #expect(content == "native body")
    } else {
        Issue.record("expected output object with content")
    }
    // No HTTP call was made.
    let invocations = await http.invocations
    #expect(invocations.isEmpty)
    // Ledger recorded the dispatch.
    let tail = try await ledger.tail(limit: 5)
    #expect(tail.contains { $0.title == "tool:read_file" && $0.status == "ok" })
}

@Test func nativeDispatchFailedActionMapsToFailedStatus() async throws {
    let sb = makeSandbox()
    let http = _FakeDispatcherHTTP()
    let ledger = DispatchLedger(ledgerPath: sb.appendingPathComponent("traces/events.jsonl"))
    let d = SwiftNativeDispatcher(http: http, ledger: ledger, localActions: .fileSystemDefault)
    let dctx = DispatchContext(
        repoRoot: sb.path, cwd: sb.path, surface: "chat", sessionId: "s",
        persona: "", activeProvider: "", extra: [:]
    )
    // Missing file → native handler returns ok=false / error_code file_not_found.
    let result = try await d.dispatch(
        tool: "read_file",
        input: ["path": .string(sb.appendingPathComponent("ghost.txt").path)],
        ctx: dctx, dryRun: false
    )
    #expect(result.ok == false)
    #expect(result.status == "failed")
    // Receipt parity: the handler RAN (and returned ok=false), so executed=true
    // and the raw result dict is still attached as output.
    #expect(result.executed == true)
    #expect(result.error?.code == "file_not_found")
    if case .object(let o)? = result.output?.value, case .string(let code)? = o["error_code"] {
        #expect(code == "file_not_found")
    } else {
        Issue.record("expected failed output dict to be attached")
    }
    let invocations = await http.invocations
    #expect(invocations.isEmpty)
}

@Test func nativeDispatchDryRunSkipsWriteSideEffect() async throws {
    let sb = makeSandbox()
    let http = _FakeDispatcherHTTP()
    let ledger = DispatchLedger(ledgerPath: sb.appendingPathComponent("traces/events.jsonl"))
    let d = SwiftNativeDispatcher(http: http, ledger: ledger, localActions: .fileSystemDefault)
    let target = sb.appendingPathComponent("dryrun.txt")
    let dctx = DispatchContext(
        repoRoot: sb.path, cwd: sb.path, surface: "chat", sessionId: "s",
        persona: "", activeProvider: "", extra: [:]
    )
    let result = try await d.dispatch(
        tool: "write_file",
        input: ["path": .string(target.path), "content": .string("should not land")],
        ctx: dctx, dryRun: true
    )
    #expect(result.status == "dry_run")
    #expect(result.executed == false)
    // The side effect did NOT happen.
    #expect(FileManager.default.fileExists(atPath: target.path) == false)
}

@Test func nativeDispatchUnknownToolFailsClosedWithoutHTTP() async throws {
    let sb = makeSandbox()
    let http = _FakeDispatcherHTTP()
    let ledger = DispatchLedger(ledgerPath: sb.appendingPathComponent("traces/events.jsonl"))
    let d = SwiftNativeDispatcher(http: http, ledger: ledger, localActions: .fileSystemDefault)
    let dctx = DispatchContext.defaultForSurface("chat")
    let result = try await d.dispatch(tool: "some.other.action", input: [:], ctx: dctx, dryRun: false)
    #expect(result.tool == "some.other.action")
    #expect(result.ok == false)
    #expect(result.status == "failed")
    #expect(result.executed == false)
    #expect(result.error?.code == "native_handler_missing")
    let invocations = await http.invocations
    #expect(invocations.isEmpty)
}

@Test func factoryDefaultLeavesLocalActionsOff() async throws {
    let http = _FakeDispatcherHTTP()
    // HERMETICITY (2026-07-21 audit): a bare makeDispatcher() defaults its
    // ledger to DispatchLedger.defaultLedgerPath() — the LIVE data root — so
    // this dispatch once appended phantom read_file {path:/tmp/x} rows to the
    // production traces/events.jsonl on every suite run. Pin to a temp ledger.
    let tempLedger = DispatchLedger(ledgerPath: FileManager.default.temporaryDirectory
        .appendingPathComponent("dispatch-ledger-\(UUID().uuidString).jsonl"))
    let d = makeDispatcher(http: http, ledger: tempLedger)
    #expect(d is SwiftNativeDispatcher)
    let result = try await d.dispatch(tool: "read_file", input: ["path": .string("/tmp/x")], ctx: .defaultForSurface("chat"), dryRun: false)
    #expect(result.error?.code == "native_handler_missing")
    let invocations = await http.invocations
    #expect(invocations.isEmpty)
}

// MARK: - LocalConnectorActions registry

@Test func registryKnowsTheFiveActions() {
    let reg = LocalConnectorActions.fileSystemDefault
    #expect(reg.canHandle("read_file"))
    #expect(reg.canHandle("file_excerpt"))
    #expect(reg.canHandle("write_file"))
    #expect(reg.canHandle("list_dir"))
    #expect(reg.canHandle("system_info"))
    #expect(!reg.canHandle("bash"))
    #expect(reg.isSideEffecting("write_file"))
    #expect(!reg.isSideEffecting("read_file"))
    // Wave 34 W06: total grew to 14 (5 wave-29 + 5 wave-32 repo-introspect +
    // 4 wave-34 persona/system). NOTE: this assertion was STALE at 5 on base
    // (wave-32 W08 added its 5 handlers + a sibling 10-count test but never
    // updated THIS one) — corrected here to the live total.
    #expect(reg.toolNames.count == 14)
}

// MARK: - Wave 41 W14 (§6.240): system_info scoped flip registry

/// The scoped .systemInfoReadOnly registry knows ONLY system_info, marks it
/// TRIVIAL_VERIFY (read-only sentinel parity) and NOT side-effecting.
@Test func systemInfoReadOnlyRegistryScopedToOneAction() {
    let reg = LocalConnectorActions.systemInfoReadOnly
    #expect(reg.canHandle("system_info"))
    #expect(reg.toolNames == ["system_info"])
    #expect(!reg.canHandle("read_file"))     // not in this scoped registry
    #expect(!reg.canHandle("list_dir"))
    #expect(!reg.isSideEffecting("system_info"))
    #expect(reg.isTrivialVerify("system_info"))
}

/// A SUCCESSFUL system_info native run executes in-process (no HTTP), reports
/// verify_passed=true (TRIVIAL_VERIFY sentinel) and autonomySource="native".
/// system_info touches NO file_access sandbox, so a bare
/// `DispatchContext.defaultForSurface` (empty repoRoot/allowedRoots — the §6.220
/// gap the W02 cluster is fixing) is irrelevant to it: it never reads either.
@Test func nativeDispatchSystemInfoOkSetsVerifyPassedAndExecutesInProcess() async throws {
    let sb = makeSandbox()
    let http = _FakeDispatcherHTTP()  // queue nothing → any HTTP hit would mis-decode
    let ledger = DispatchLedger(ledgerPath: sb.appendingPathComponent("traces/events.jsonl"))
    let d = SwiftNativeDispatcher(http: http, ledger: ledger, localActions: .systemInfoReadOnly)
    let dctx = DispatchContext.defaultForSurface("chat")  // empty repoRoot — fine for system_info
    let result = try await d.dispatch(tool: "system_info", input: [:], ctx: dctx, dryRun: false)
    #expect(result.ok == true)
    #expect(result.status == "ok")
    #expect(result.executed == true)
    #expect(result.verifyPassed == true)   // TRIVIAL_VERIFY parity
    #expect(result.autonomySource == "native")
    // disk is the one field that should always resolve via statfs("/").
    if case .object(let o)? = result.output?.value {
        #expect(o["ok"] != nil)
        #expect(o["disk"] != nil)
    } else {
        Issue.record("expected system_info output object")
    }
    let invocations = await http.invocations
    #expect(invocations.isEmpty)
}

/// The scoped .systemInfoReadOnly registry flips ONLY system_info — any OTHER
/// tool fails closed without a daemon fallback.
@Test func systemInfoReadOnlyRegistryFailsOtherToolsClosed() async throws {
    let sb = makeSandbox()
    let http = _FakeDispatcherHTTP()
    let ledger = DispatchLedger(ledgerPath: sb.appendingPathComponent("traces/events.jsonl"))
    let d = SwiftNativeDispatcher(http: http, ledger: ledger, localActions: .systemInfoReadOnly)
    let dctx = DispatchContext.defaultForSurface("chat")
    let result = try await d.dispatch(tool: "read_file", input: ["path": .string("/tmp/x")], ctx: dctx, dryRun: false)
    #expect(result.error?.code == "native_handler_missing")
    let invocations = await http.invocations
    #expect(invocations.isEmpty)
}

// MARK: - Wave 36 W11 (§6.138): native dispatch parity fixes for the persona_read flip

/// §6.30 prereq #8 (dry-run uniformity). The daemon short-circuits dry_run for
/// ALL tools (read-only included) BEFORE the handler runs (status=dry_run,
/// executed=false, the retired daemon). A read-only native tool must NOT
/// execute on dry_run. Uses the SCOPED .personaReadOnly registry (the flip seam).
@Test func nativeDispatchDryRunReadOnlyDoesNotExecute() async throws {
    let sb = makeSandbox()
    // Write a SOUL.md so a real execution WOULD return content — proving the
    // dry-run short-circuit (output nil / executed false) is the reason it's empty.
    let personaDir = sb.appendingPathComponent("memory")
    try? FileManager.default.createDirectory(at: personaDir, withIntermediateDirectories: true)
    try "real soul".write(to: personaDir.appendingPathComponent("SOUL.md"), atomically: true, encoding: .utf8)

    let http = _FakeDispatcherHTTP()  // queue nothing → any HTTP hit would mis-decode
    let ledger = DispatchLedger(ledgerPath: sb.appendingPathComponent("traces/events.jsonl"))
    let d = SwiftNativeDispatcher(http: http, ledger: ledger, localActions: .personaReadOnly)
    let dctx = DispatchContext(
        repoRoot: sb.path, cwd: sb.path, surface: "chat", sessionId: "s",
        persona: "", activeProvider: "", extra: ["_na_data_root": .string(sb.path)]
    )
    let result = try await d.dispatch(
        tool: "persona_read", input: ["kind": .string("soul")], ctx: dctx, dryRun: true)
    #expect(result.status == "dry_run")
    #expect(result.executed == false)
    #expect(result.output == nil)         // dry_run receipt carries no output
    #expect(result.verifyPassed == nil)   // dry_run never sets verify_passed
    // No HTTP — the native registry short-circuited the dry-run in-process.
    let invocations = await http.invocations
    #expect(invocations.isEmpty)
}

/// §6.30 prereq #9 (verify semantics). A SUCCESSFUL persona_read native run must
/// report verify_passed=true (daemon TRIVIAL_VERIFY sentinel,
/// the retired daemon), and attach the content output (the gpt-5.5
/// landmine: the seam must not drop output).
@Test func nativeDispatchPersonaReadOkSetsVerifyPassedAndOutput() async throws {
    let sb = makeSandbox()
    let personaDir = sb.appendingPathComponent("memory")
    try? FileManager.default.createDirectory(at: personaDir, withIntermediateDirectories: true)
    try "soul body here".write(to: personaDir.appendingPathComponent("SOUL.md"), atomically: true, encoding: .utf8)

    let http = _FakeDispatcherHTTP()
    let ledger = DispatchLedger(ledgerPath: sb.appendingPathComponent("traces/events.jsonl"))
    let d = SwiftNativeDispatcher(http: http, ledger: ledger, localActions: .personaReadOnly)
    let dctx = DispatchContext(
        repoRoot: sb.path, cwd: sb.path, surface: "chat", sessionId: "s",
        persona: "", activeProvider: "", extra: ["_na_data_root": .string(sb.path)]
    )
    let result = try await d.dispatch(
        tool: "persona_read", input: ["kind": .string("soul")], ctx: dctx, dryRun: false)
    #expect(result.ok == true)
    #expect(result.status == "ok")
    #expect(result.executed == true)
    #expect(result.verifyPassed == true)  // TRIVIAL_VERIFY parity (prereq #9)
    #expect(result.autonomySource == "native")
    // Output carries the persona content (output-preservation landmine).
    if case .object(let o)? = result.output?.value, case .string(let content)? = o["content"] {
        #expect(content == "soul body here")
    } else {
        Issue.record("expected persona_read output with content")
    }
    let invocations = await http.invocations
    #expect(invocations.isEmpty)
}

/// A FAILED native read (ok=false) must NOT set verify_passed=true — daemon
/// passes verify_passed=None on every failure branch.
@Test func nativeDispatchPersonaReadFailedLeavesVerifyPassedNil() async throws {
    let sb = makeSandbox()  // no SOUL.md → persona_not_found
    let http = _FakeDispatcherHTTP()
    let ledger = DispatchLedger(ledgerPath: sb.appendingPathComponent("traces/events.jsonl"))
    let d = SwiftNativeDispatcher(http: http, ledger: ledger, localActions: .personaReadOnly)
    let dctx = DispatchContext(
        repoRoot: sb.path, cwd: sb.path, surface: "chat", sessionId: "s",
        persona: "", activeProvider: "", extra: ["_na_data_root": .string(sb.path)]
    )
    let result = try await d.dispatch(
        tool: "persona_read", input: ["kind": .string("user")], ctx: dctx, dryRun: false)
    #expect(result.ok == false)
    #expect(result.status == "failed")
    #expect(result.executed == true)        // handler ran + returned ok=false
    #expect(result.verifyPassed == nil)     // failure → verify_passed nil
    #expect(result.error?.code == "persona_not_found")
    // §6.158 #6 parity (wave 37 W08): a handler-ran-then-failed error is
    // recoverable=true, matching the retired daemon.
    #expect(result.error?.recoverable == true)
    let invocations = await http.invocations
    #expect(invocations.isEmpty)
}

/// The scoped .personaReadOnly registry flips ONLY persona_read — any OTHER tool
/// fails closed without a daemon fallback.
@Test func personaReadOnlyRegistryFailsOtherToolsClosed() async throws {
    let sb = makeSandbox()
    let http = _FakeDispatcherHTTP()
    let ledger = DispatchLedger(ledgerPath: sb.appendingPathComponent("traces/events.jsonl"))
    let d = SwiftNativeDispatcher(http: http, ledger: ledger, localActions: .personaReadOnly)
    let dctx = DispatchContext.defaultForSurface("chat")
    let result = try await d.dispatch(tool: "read_file", input: ["path": .string("/tmp/x")], ctx: dctx, dryRun: false)
    #expect(result.error?.code == "native_handler_missing")
    let invocations = await http.invocations
    #expect(invocations.isEmpty)
}

// MARK: - Wave 37 W08 (§6.159): native dispatch parity for the workspace_list flip

/// §6.30 prereq #8 (dry-run uniformity). A read-only native tool must NOT execute
/// on dry_run — the daemon short-circuits dry_run for ALL tools before the handler
/// runs (status=dry_run, executed=false). Uses the SCOPED .workspaceListReadOnly
/// registry (the second flip seam).
@Test func nativeDispatchWorkspaceListDryRunDoesNotExecute() async throws {
    let sb = makeSandbox()
    // Populate the workspace so a real execution WOULD return items — proving the
    // dry-run short-circuit (output nil / executed false) is why it's empty.
    let ws = sb.appendingPathComponent("workspace")
    try? FileManager.default.createDirectory(at: ws, withIntermediateDirectories: true)
    try "x".write(to: ws.appendingPathComponent("real.txt"), atomically: true, encoding: .utf8)

    let http = _FakeDispatcherHTTP()  // queue nothing → any HTTP hit would mis-decode
    let ledger = DispatchLedger(ledgerPath: sb.appendingPathComponent("traces/events.jsonl"))
    let d = SwiftNativeDispatcher(http: http, ledger: ledger, localActions: .workspaceListReadOnly)
    let dctx = DispatchContext(
        repoRoot: sb.path, cwd: sb.path, surface: "chat", sessionId: "s",
        persona: "", activeProvider: "", extra: ["_na_workspace_root": .string(ws.path)]
    )
    let result = try await d.dispatch(
        tool: "workspace_list", input: [:], ctx: dctx, dryRun: true)
    #expect(result.status == "dry_run")
    #expect(result.executed == false)
    #expect(result.output == nil)         // dry_run receipt carries no output
    #expect(result.verifyPassed == nil)   // dry_run never sets verify_passed
    let invocations = await http.invocations
    #expect(invocations.isEmpty)
}

/// §6.30 prereq #9 (verify semantics). A SUCCESSFUL workspace_list native run must
/// report verify_passed=true (daemon TRIVIAL_VERIFY sentinel) and attach the items
/// output (the gpt-5.5 output-preservation landmine: the seam must not drop output).
@Test func nativeDispatchWorkspaceListOkSetsVerifyPassedAndOutput() async throws {
    let sb = makeSandbox()
    let ws = sb.appendingPathComponent("workspace")
    try? FileManager.default.createDirectory(at: ws, withIntermediateDirectories: true)
    try "hello".write(to: ws.appendingPathComponent("note.txt"), atomically: true, encoding: .utf8)

    let http = _FakeDispatcherHTTP()
    let ledger = DispatchLedger(ledgerPath: sb.appendingPathComponent("traces/events.jsonl"))
    let d = SwiftNativeDispatcher(http: http, ledger: ledger, localActions: .workspaceListReadOnly)
    let dctx = DispatchContext(
        repoRoot: sb.path, cwd: sb.path, surface: "chat", sessionId: "s",
        persona: "", activeProvider: "", extra: ["_na_workspace_root": .string(ws.path)]
    )
    let result = try await d.dispatch(
        tool: "workspace_list", input: [:], ctx: dctx, dryRun: false)
    #expect(result.ok == true)
    #expect(result.status == "ok")
    #expect(result.executed == true)
    #expect(result.verifyPassed == true)  // TRIVIAL_VERIFY parity (prereq #9)
    #expect(result.autonomySource == "native")
    // Output carries the listed items (output-preservation landmine).
    if case .object(let o)? = result.output?.value,
       case .int(let count)? = o["count"],
       case .array(let items)? = o["items"] {
        #expect(count == 1)
        #expect(items.count == 1)
        if case .object(let item0)? = items.first, case .string(let path)? = item0["path"] {
            #expect(path == "note.txt")
        } else {
            Issue.record("expected first workspace item with a path")
        }
    } else {
        Issue.record("expected workspace_list output with count + items")
    }
    let invocations = await http.invocations
    #expect(invocations.isEmpty)
}

/// A FAILED native list (ok=false — e.g. a subdir escaping the workspace root)
/// must NOT set verify_passed=true — the daemon passes verify_passed=None on every
/// failure branch.
@Test func nativeDispatchWorkspaceListFailedLeavesVerifyPassedNil() async throws {
    let sb = makeSandbox()
    let ws = sb.appendingPathComponent("workspace")
    try? FileManager.default.createDirectory(at: ws, withIntermediateDirectories: true)

    let http = _FakeDispatcherHTTP()
    let ledger = DispatchLedger(ledgerPath: sb.appendingPathComponent("traces/events.jsonl"))
    let d = SwiftNativeDispatcher(http: http, ledger: ledger, localActions: .workspaceListReadOnly)
    let dctx = DispatchContext(
        repoRoot: sb.path, cwd: sb.path, surface: "chat", sessionId: "s",
        persona: "", activeProvider: "", extra: ["_na_workspace_root": .string(ws.path)]
    )
    let result = try await d.dispatch(
        tool: "workspace_list", input: ["subdir": .string("../../etc")], ctx: dctx, dryRun: false)
    #expect(result.ok == false)
    #expect(result.status == "failed")
    #expect(result.executed == true)        // handler ran + returned ok=false
    #expect(result.verifyPassed == nil)     // failure → verify_passed nil
    #expect(result.error?.code == "path_not_allowed")
    // §6.158 #6 parity (wave 37 W08): a handler-ran-then-failed error is
    // recoverable=true, matching the retired daemon.
    #expect(result.error?.recoverable == true)
    let invocations = await http.invocations
    #expect(invocations.isEmpty)
}

/// §6.180 (wave 38 W04) — error_code DEFAULT parity. When a native handler
/// returns ok=false WITHOUT supplying its own error_code, the dispatcher must
/// default the error envelope code to "handler_raised" (the daemon's
/// ErrorCode.handler_raised fallback at the retired daemon), NOT
/// "tool_error". workspace_list's NotADirectory catch branch
/// (PersonaSystemActions.swift:439-444) returns {ok:false, error:...} with no
/// error_code — the exact path that exercised the old "tool_error" divergence.
/// Target a FILE as the subdir so contentsOfDirectory throws NotADirectory.
@Test func nativeDispatchWorkspaceListMissingErrorCodeDefaultsToHandlerRaised() async throws {
    let sb = makeSandbox()
    let ws = sb.appendingPathComponent("workspace")
    try? FileManager.default.createDirectory(at: ws, withIntermediateDirectories: true)
    // A regular FILE inside the workspace. Listing it as a subdir exists but is
    // NOT a directory → contentsOfDirectory throws → the {ok:false} (no
    // error_code) branch fires.
    try "x".write(to: ws.appendingPathComponent("afile.txt"), atomically: true, encoding: .utf8)

    let http = _FakeDispatcherHTTP()
    let ledger = DispatchLedger(ledgerPath: sb.appendingPathComponent("traces/events.jsonl"))
    let d = SwiftNativeDispatcher(http: http, ledger: ledger, localActions: .workspaceListReadOnly)
    let dctx = DispatchContext(
        repoRoot: sb.path, cwd: sb.path, surface: "chat", sessionId: "s",
        persona: "", activeProvider: "", extra: ["_na_workspace_root": .string(ws.path)]
    )
    let result = try await d.dispatch(
        tool: "workspace_list", input: ["subdir": .string("afile.txt")], ctx: dctx, dryRun: false)
    #expect(result.ok == false)
    #expect(result.status == "failed")
    #expect(result.executed == true)        // handler ran + returned ok=false
    #expect(result.verifyPassed == nil)
    // The fix under test: NO tool-supplied error_code → daemon "handler_raised"
    // default, NOT the old "tool_error".
    #expect(result.error?.code == "handler_raised")
    #expect(result.error?.recoverable == true)
    let invocations = await http.invocations
    #expect(invocations.isEmpty)
}

/// The scoped .workspaceListReadOnly registry flips ONLY workspace_list — any
/// OTHER tool (INCLUDING persona_read, flipped by the SEPARATE leash) fails
/// closed without a daemon fallback.
@Test func workspaceListReadOnlyRegistryFailsOtherToolsClosed() async throws {
    let sb = makeSandbox()
    let http = _FakeDispatcherHTTP()
    let ledger = DispatchLedger(ledgerPath: sb.appendingPathComponent("traces/events.jsonl"))
    let d = SwiftNativeDispatcher(http: http, ledger: ledger, localActions: .workspaceListReadOnly)
    let dctx = DispatchContext.defaultForSurface("chat")
    let result = try await d.dispatch(tool: "persona_read", input: ["kind": .string("soul")], ctx: dctx, dryRun: false)
    #expect(result.error?.code == "native_handler_missing")
    let invocations = await http.invocations
    #expect(invocations.isEmpty)
}

// MARK: - Wave 38 W07 (§6.180): time_now native flip via scoped .timeNowReadOnly

/// §6.30 prereq #8 (dry-run uniformity). A read-only native tool must NOT execute
/// on dry_run — the daemon short-circuits dry_run for ALL tools before the handler
/// runs (status=dry_run, executed=false). Uses the SCOPED .timeNowReadOnly registry.
@Test func nativeDispatchTimeNowDryRunDoesNotExecute() async throws {
    let sb = makeSandbox()
    let http = _FakeDispatcherHTTP()  // queue nothing → any HTTP hit would mis-decode
    let ledger = DispatchLedger(ledgerPath: sb.appendingPathComponent("traces/events.jsonl"))
    let d = SwiftNativeDispatcher(http: http, ledger: ledger, localActions: .timeNowReadOnly)
    let dctx = DispatchContext.defaultForSurface("chat")
    let result = try await d.dispatch(
        tool: "time_now", input: [:], ctx: dctx, dryRun: true)
    #expect(result.status == "dry_run")
    #expect(result.executed == false)
    #expect(result.output == nil)         // dry_run receipt carries no output
    #expect(result.verifyPassed == nil)   // dry_run never sets verify_passed
    let invocations = await http.invocations
    #expect(invocations.isEmpty)
}

/// §6.30 prereq #9 (verify semantics). A SUCCESSFUL time_now native run must report
/// verify_passed=true (daemon TRIVIAL_VERIFY sentinel) and attach the clock output
/// (the gpt-5.5 output-preservation landmine: the seam must not drop output).
@Test func nativeDispatchTimeNowOkSetsVerifyPassedAndOutput() async throws {
    let sb = makeSandbox()
    let http = _FakeDispatcherHTTP()
    let ledger = DispatchLedger(ledgerPath: sb.appendingPathComponent("traces/events.jsonl"))
    let d = SwiftNativeDispatcher(http: http, ledger: ledger, localActions: .timeNowReadOnly)
    let dctx = DispatchContext.defaultForSurface("chat")
    // Pin a concrete IANA timezone so the output is deterministic across hosts.
    let result = try await d.dispatch(
        tool: "time_now", input: ["timezone": .string("America/Denver")], ctx: dctx, dryRun: false)
    #expect(result.ok == true)
    #expect(result.status == "ok")
    #expect(result.executed == true)
    #expect(result.verifyPassed == true)  // TRIVIAL_VERIFY parity (prereq #9)
    #expect(result.autonomySource == "native")
    // Output carries the clock fields (output-preservation landmine).
    if case .object(let o)? = result.output?.value {
        #expect({ if case .bool(true)? = o["ok"] { return true } else { return false } }())
        #expect({ if case .string("America/Denver")? = o["timezone"] { return true } else { return false } }())
        // The shape carries the canonical keys the daemon's _exec_time_now emits.
        #expect(o["iso"] != nil)
        #expect(o["utcIso"] != nil)
        #expect(o["utcOffset"] != nil)
        #expect(o["epochSeconds"] != nil)
        #expect(o["date"] != nil)
        #expect(o["time"] != nil)
        #expect(o["dayOfWeek"] != nil)
    } else {
        Issue.record("expected time_now output object")
    }
    let invocations = await http.invocations
    #expect(invocations.isEmpty)
}

/// A FAILED native time_now (ok=false — an unknown timezone → bad_input) must NOT
/// set verify_passed=true — the daemon passes verify_passed=None on every failure
/// branch. The handler still RAN (executed=true) and returned ok=false.
@Test func nativeDispatchTimeNowUnknownTzFailsWithoutVerify() async throws {
    let sb = makeSandbox()
    let http = _FakeDispatcherHTTP()
    let ledger = DispatchLedger(ledgerPath: sb.appendingPathComponent("traces/events.jsonl"))
    let d = SwiftNativeDispatcher(http: http, ledger: ledger, localActions: .timeNowReadOnly)
    let dctx = DispatchContext.defaultForSurface("chat")
    let result = try await d.dispatch(
        tool: "time_now", input: ["timezone": .string("Not/AZone")], ctx: dctx, dryRun: false)
    #expect(result.ok == false)
    #expect(result.status == "failed")
    #expect(result.executed == true)        // handler ran + returned ok=false
    #expect(result.verifyPassed == nil)     // failure → verify_passed nil
    #expect(result.error?.code == "bad_input")
    // §6.158 #6 parity: a handler-ran-then-failed error is recoverable=true.
    #expect(result.error?.recoverable == true)
    let invocations = await http.invocations
    #expect(invocations.isEmpty)
}

/// The scoped .timeNowReadOnly registry flips ONLY time_now — any OTHER tool
/// (INCLUDING persona_read / workspace_list, flipped by SEPARATE leashes) fails
/// closed without a daemon fallback.
@Test func timeNowReadOnlyRegistryFailsOtherToolsClosed() async throws {
    let sb = makeSandbox()
    let http = _FakeDispatcherHTTP()
    let ledger = DispatchLedger(ledgerPath: sb.appendingPathComponent("traces/events.jsonl"))
    let d = SwiftNativeDispatcher(http: http, ledger: ledger, localActions: .timeNowReadOnly)
    let dctx = DispatchContext.defaultForSurface("chat")
    let result = try await d.dispatch(tool: "workspace_list", input: [:], ctx: dctx, dryRun: false)
    #expect(result.error?.code == "native_handler_missing")
    let invocations = await http.invocations
    #expect(invocations.isEmpty)
}

/// §6.180 (wave 38 W07) — CLOSES §6.179 #4. A native handler that returns
/// `ok=false` WITHOUT an `error_code` must surface code="handler_raised" — the
/// daemon's default, NOT the prior Swift
/// default "tool_error". time_now always sets bad_input, so this exercises the
/// shared default via a synthetic no-error_code handler over the same seam.
@Test func nativeDispatchMissingErrorCodeDefaultsToHandlerRaised() async throws {
    let sb = makeSandbox()
    let http = _FakeDispatcherHTTP()
    let ledger = DispatchLedger(ledgerPath: sb.appendingPathComponent("traces/events.jsonl"))
    // A scoped registry whose single handler returns a failed dict with NO
    // error_code (mirrors e.g. workspace_list's contentsOfDirectory catch branch
    // {ok:false, error:...}). Marked TRIVIAL_VERIFY to prove the failure path
    // still leaves verifyPassed nil.
    let reg = LocalConnectorActions(
        handlers: ["time_now": { _, _ in .object(["ok": .bool(false), "error": .string("boom")]) }],
        sideEffecting: [],
        trivialVerify: ["time_now"]
    )
    let d = SwiftNativeDispatcher(http: http, ledger: ledger, localActions: reg)
    let dctx = DispatchContext.defaultForSurface("chat")
    let result = try await d.dispatch(tool: "time_now", input: [:], ctx: dctx, dryRun: false)
    #expect(result.ok == false)
    #expect(result.status == "failed")
    #expect(result.executed == true)
    #expect(result.verifyPassed == nil)
    #expect(result.error?.code == "handler_raised")   // daemon default parity (§6.179 #4)
    #expect(result.error?.recoverable == true)
    let invocations = await http.invocations
    #expect(invocations.isEmpty)
}

// MARK: - Wave 39 W08 (§6.201): persona_list_skills native flip via scoped registry

/// §6.30 prereq #8 (dry-run uniformity). A read-only native tool must NOT execute
/// on dry_run — the daemon short-circuits dry_run for ALL tools before the handler
/// runs (status=dry_run, executed=false). Uses the SCOPED
/// .personaListSkillsReadOnly registry.
@Test func nativeDispatchPersonaListSkillsDryRunDoesNotExecute() async throws {
    let sb = makeSandbox()
    let http = _FakeDispatcherHTTP()  // queue nothing → any HTTP hit would mis-decode
    let ledger = DispatchLedger(ledgerPath: sb.appendingPathComponent("traces/events.jsonl"))
    let d = SwiftNativeDispatcher(http: http, ledger: ledger, localActions: .personaListSkillsReadOnly)
    let dctx = DispatchContext.defaultForSurface("chat")
    let result = try await d.dispatch(
        tool: "persona_list_skills", input: [:], ctx: dctx, dryRun: true)
    #expect(result.status == "dry_run")
    #expect(result.executed == false)
    #expect(result.output == nil)         // dry_run receipt carries no output
    #expect(result.verifyPassed == nil)   // dry_run never sets verify_passed
    let invocations = await http.invocations
    #expect(invocations.isEmpty)
}

/// §6.30 prereq #9 (verify semantics). A SUCCESSFUL persona_list_skills native run
/// must report verify_passed=true (daemon TRIVIAL_VERIFY sentinel) and attach the
/// manifest output (the gpt-5.5 output-preservation landmine: the seam must not
/// drop output). A missing persona/data skill-body dir yields ok=true + an empty
/// manifest (the daemon's first-run-empty behavior), which is exactly the
/// deterministic, host-independent success shape this seam test needs.
@Test func nativeDispatchPersonaListSkillsOkSetsVerifyPassedAndOutput() async throws {
    let sb = makeSandbox()
    let http = _FakeDispatcherHTTP()
    let ledger = DispatchLedger(ledgerPath: sb.appendingPathComponent("traces/events.jsonl"))
    let d = SwiftNativeDispatcher(http: http, ledger: ledger, localActions: .personaListSkillsReadOnly)
    let dctx = DispatchContext.defaultForSurface("chat")
    let result = try await d.dispatch(
        tool: "persona_list_skills", input: [:], ctx: dctx, dryRun: false)
    #expect(result.ok == true)
    #expect(result.status == "ok")
    #expect(result.executed == true)
    #expect(result.verifyPassed == true)  // TRIVIAL_VERIFY parity (prereq #9)
    #expect(result.autonomySource == "native")
    // Output carries the manifest fields (output-preservation landmine). The
    // canonical keys _exec_persona_list_skills emits are present regardless of
    // whether any skills were found.
    if case .object(let o)? = result.output?.value {
        #expect({ if case .bool(true)? = o["ok"] { return true } else { return false } }())
        #expect(o["skills"] != nil)
        #expect(o["manifest"] != nil)
        #expect(o["count"] != nil)
        #expect(o["returned"] != nil)
        #expect(o["sources"] != nil)
    } else {
        Issue.record("expected persona_list_skills output object")
    }
    let invocations = await http.invocations
    #expect(invocations.isEmpty)
}

/// The scoped .personaListSkillsReadOnly registry flips ONLY persona_list_skills —
/// any OTHER tool (INCLUDING persona_read / workspace_list / time_now, flipped by
/// SEPARATE leashes) fails closed without a daemon fallback.
@Test func personaListSkillsReadOnlyRegistryFailsOtherToolsClosed() async throws {
    let sb = makeSandbox()
    let http = _FakeDispatcherHTTP()
    let ledger = DispatchLedger(ledgerPath: sb.appendingPathComponent("traces/events.jsonl"))
    let d = SwiftNativeDispatcher(http: http, ledger: ledger, localActions: .personaListSkillsReadOnly)
    let dctx = DispatchContext.defaultForSurface("chat")
    let result = try await d.dispatch(tool: "time_now", input: [:], ctx: dctx, dryRun: false)
    #expect(result.error?.code == "native_handler_missing")
    let invocations = await http.invocations
    #expect(invocations.isEmpty)
}

// MARK: - Wave 41 W02 (§6.220-rd2 #2): seam sandbox-escape regression
//
// The `NativeClient._swiftDispatch` seam used to build the DispatchContext via
// `DispatchContext.defaultForSurface("chat")`, which carries an EMPTY repoRoot
// and EMPTY extra. When the `.dispatchReadFile` / `.dispatchFileExcerpt` flags
// flipped ON, `FileSystemActions.allowedRoots(ctx)` therefore returned `[]`,
// and the `!allowed.isEmpty && !isWithinRoots(...)` guard was SKIPPED — an
// absolute path like `/etc/passwd` resolved, passed the (skipped) sandbox check,
// fell outside the data root so the sensitive-path block didn't fire, and was
// READ. These tests pin the seam's NEW context (repoRoot = repo, read-only
// file_access, `_na_data_root`) and prove the escape is now REJECTED with the
// daemon-parity `path_not_allowed` error, through the SAME dispatcher path the
// production seam uses (ConnectorActionContext.fromDispatch + scoped registry).

/// Reproduce the context `_swiftDispatch` now builds for the file-system flips:
/// repoRoot = repo root, read-only file_access, `_na_data_root` threaded so the
/// sensitive-path block resolves against the real data root.
private func w41SeamContext(repoRoot: String, dataRoot: String, sessionId: String = "s") -> DispatchContext {
    var extra: [String: JSONValue] = [
        "file_access": .object([
            "mode": .string("read_only"),
            "sandbox": .string("read_only"),
        ]),
    ]
    if !dataRoot.isEmpty { extra["_na_data_root"] = .string(dataRoot) }
    return DispatchContext(
        repoRoot: repoRoot, cwd: repoRoot, surface: "chat", sessionId: sessionId,
        persona: "", activeProvider: "", extra: extra
    )
}

@Test func w41ReadFileSeamRejectsEtcPasswdAbsolutePath() async throws {
    let sb = makeSandbox()  // stand-in for the repo root
    let http = _FakeDispatcherHTTP()  // queue NOTHING → any HTTP fallthrough mis-decodes
    let ledger = DispatchLedger(ledgerPath: sb.appendingPathComponent("traces/events.jsonl"))
    let d = SwiftNativeDispatcher(http: http, ledger: ledger, localActions: .readFileReadOnly)
    // repoRoot = sb (the sole allowed root); data root is a sibling so /etc is
    // outside BOTH. read-only file_access keeps the sandbox ENGAGED.
    let dctx = w41SeamContext(repoRoot: sb.path, dataRoot: sb.appendingPathComponent("data").path)
    let result = try await d.dispatch(
        tool: "read_file", input: ["path": .string("/etc/passwd")], ctx: dctx, dryRun: false
    )
    // REJECTED natively (executed but ok=false) with parity error_code.
    #expect(result.ok == false)
    #expect(result.executed == true)  // native handler ran and refused
    #expect(result.autonomySource == "native")
    if case .object(let o)? = result.output?.value, case .string(let code)? = o["error_code"] {
        #expect(code == "path_not_allowed")
    } else {
        Issue.record("expected native rejection output with error_code path_not_allowed")
    }
    // No network escape hatch: the rejection is native.
    let invocations = await http.invocations
    #expect(invocations.isEmpty)
}

@Test func w41FileExcerptSeamRejectsEtcPasswdAbsolutePath() async throws {
    let sb = makeSandbox()
    let http = _FakeDispatcherHTTP()
    let ledger = DispatchLedger(ledgerPath: sb.appendingPathComponent("traces/events.jsonl"))
    let d = SwiftNativeDispatcher(http: http, ledger: ledger, localActions: .fileExcerptReadOnly)
    let dctx = w41SeamContext(repoRoot: sb.path, dataRoot: sb.appendingPathComponent("data").path)
    let result = try await d.dispatch(
        tool: "file_excerpt",
        input: ["path": .string("/etc/passwd"), "start_line": .int(1), "max_lines": .int(5)],
        ctx: dctx, dryRun: false
    )
    #expect(result.ok == false)
    #expect(result.executed == true)
    #expect(result.autonomySource == "native")
    if case .object(let o)? = result.output?.value, case .string(let code)? = o["error_code"] {
        #expect(code == "path_not_allowed")
    } else {
        Issue.record("expected native rejection output with error_code path_not_allowed")
    }
    let invocations = await http.invocations
    #expect(invocations.isEmpty)
}

/// Negative control / regression pin: the OLD seam context (empty repoRoot +
/// empty extra, i.e. `DispatchContext.defaultForSurface`) DISABLES the sandbox,
/// so `/etc/passwd` would have been READ. This documents the exact escape the
/// fix closes — `allowedRoots` is empty, so the guard is skipped and a real read
/// is attempted (succeeds on any host where /etc/passwd is world-readable).
@Test func w41OldDefaultForSurfaceContextWouldHaveLeakedEtcPasswd() async throws {
    let sb = makeSandbox()
    let http = _FakeDispatcherHTTP()
    let ledger = DispatchLedger(ledgerPath: sb.appendingPathComponent("traces/events.jsonl"))
    let d = SwiftNativeDispatcher(http: http, ledger: ledger, localActions: .readFileReadOnly)
    // The pre-fix context: empty repoRoot, empty extra → allowedRoots == [].
    let oldCtx = DispatchContext.defaultForSurface("chat", sessionId: "s")
    let result = try await d.dispatch(
        tool: "read_file", input: ["path": .string("/etc/passwd")], ctx: oldCtx, dryRun: false
    )
    // The sandbox is BYPASSED (allowedRoots empty), so the ONLY thing standing
    // between the read and /etc/passwd is whether the file happens to be
    // sensitive-data-path-blocked (it is NOT — /etc is outside any data root).
    // On a normal macOS/Linux host /etc/passwd is world-readable, so the read
    // SUCCEEDS — that is the escape. We assert the absence of a sandbox rejection
    // to pin the contrast with the fixed seam above.
    if case .object(let o)? = result.output?.value, case .string(let code)? = o["error_code"] {
        #expect(code != "path_not_allowed")  // NOT blocked by the sandbox = escape
    }
    // The native handler ran either way.
    let invocations = await http.invocations
    #expect(invocations.isEmpty)
}

// MARK: - Wave 42 W01 (§6.260): ACTION-NAME-scoped file-sandbox context selector
//
// REOPEN of §6.240-rd2 #1. The §6.220-rd2 #2 fix made `_swiftDispatch` build a
// sandbox-ENGAGING DispatchContext whenever EITHER file flag (.dispatchReadFile /
// .dispatchFileExcerpt) was ON, then applied it to WHATEVER tool the call
// dispatched. So a persona_read / workspace_list / time_now / persona_list_skills
// / system_info dispatch in the same process got the read_file sandbox context
// (non-empty repoRoot + read-only file_access + `_na_data_root`) instead of its
// legacy `defaultForSurface("chat")` — flipping the non-file actions' persona root
// from `defaultPersonaRoot()` to the `<dataRoot>/memory` legacy fallback, a
// behavior change. These tests pin `DispatchContext.fileSandboxContextForTool`:
// ONLY a read_file / file_excerpt dispatch whose OWN flag is ON engages the
// sandbox context; every other action keeps the legacy default EVEN when a file
// flag is ON.

private let w42DataRootURL = URL(fileURLWithPath: "/private/var/na/data")
private let w42DataRoot = "/private/var/na/data"
private let w42RepoRoot = "/private/var/na"  // parent of the data root

/// Assert a context is the legacy `defaultForSurface` shape: empty repoRoot/cwd
/// and NO sandbox `extra` (no `file_access`, no `_na_data_root`).
private func w42ExpectDefaultShape(_ ctx: DispatchContext) {
    #expect(ctx.repoRoot == "")
    #expect(ctx.cwd == "")
    #expect(ctx.extra.isEmpty)
    #expect(ctx.extra["_na_data_root"] == nil)
    #expect(ctx.extra["file_access"] == nil)
}

/// Assert a context is the sandbox-ENGAGING shape: repoRoot = data-root parent,
/// read-only file_access, `_na_data_root` threaded.
private func w42ExpectSandboxShape(_ ctx: DispatchContext) {
    #expect(ctx.repoRoot == w42RepoRoot)
    #expect(ctx.cwd == w42RepoRoot)
    if case .string(let dr)? = ctx.extra["_na_data_root"] {
        #expect(dr == w42DataRoot)
    } else {
        Issue.record("expected _na_data_root threaded")
    }
    if case .object(let fa)? = ctx.extra["file_access"] {
        #expect(fa["mode"] == .string("read_only"))
        #expect(fa["sandbox"] == .string("read_only"))
    } else {
        Issue.record("expected read-only file_access")
    }
}

/// THE reopen assertion: with `.dispatchReadFile` ON, a `persona_read` dispatch
/// must STILL get the legacy `defaultForSurface` context — NOT the read_file
/// sandbox context. (Pre-fix: it got the sandbox context, flipping its persona
/// root to the `<dataRoot>/memory` legacy fallback.)
@Test func w42PersonaReadContextUnchangedWhenReadFileFlagOn() {
    let ctx = DispatchContext.fileSandboxContextForTool(
        "persona_read",
        readFileEnabled: true,            // read_file flip is ON…
        fileExcerptEnabled: false,
        dataRoot: w42DataRootURL,
        surface: "chat", sessionId: "s"
    )
    w42ExpectDefaultShape(ctx)            // …but persona_read is unaffected.
    #expect(ctx.surface == "chat")
    #expect(ctx.sessionId == "s")
}

/// Same guarantee with BOTH file flags ON — persona_read still legacy default.
@Test func w42PersonaReadContextUnchangedWhenBothFileFlagsOn() {
    let ctx = DispatchContext.fileSandboxContextForTool(
        "persona_read",
        readFileEnabled: true,
        fileExcerptEnabled: true,
        dataRoot: w42DataRootURL
    )
    w42ExpectDefaultShape(ctx)
}

/// workspace_list / time_now / persona_list_skills / system_info — every other
/// natively-flippable action keeps the legacy default when a file flag is ON.
@Test func w42OtherActionsKeepDefaultContextWhenFileFlagOn() {
    for tool in ["workspace_list", "time_now", "persona_list_skills", "system_info"] {
        let ctx = DispatchContext.fileSandboxContextForTool(
            tool,
            readFileEnabled: true,
            fileExcerptEnabled: true,
            dataRoot: w42DataRootURL
        )
        w42ExpectDefaultShape(ctx)
    }
}

/// A read_file dispatch whose OWN flag is ON DOES get the sandbox context.
@Test func w42ReadFileContextEngagesSandboxWhenItsFlagOn() {
    let ctx = DispatchContext.fileSandboxContextForTool(
        "read_file",
        readFileEnabled: true,
        fileExcerptEnabled: false,
        dataRoot: w42DataRootURL
    )
    w42ExpectSandboxShape(ctx)
}

/// A file_excerpt dispatch whose OWN flag is ON DOES get the sandbox context.
@Test func w42FileExcerptContextEngagesSandboxWhenItsFlagOn() {
    let ctx = DispatchContext.fileSandboxContextForTool(
        "file_excerpt",
        readFileEnabled: false,
        fileExcerptEnabled: true,
        dataRoot: w42DataRootURL
    )
    w42ExpectSandboxShape(ctx)
}

/// Cross-scoping guard: read_file with ONLY file_excerpt's flag ON (its own flag
/// OFF) keeps the legacy default, so no sandbox context. This
/// is the inverse of the original bug: a file tool must NOT inherit the OTHER
/// file tool's flag.
@Test func w42ReadFileKeepsDefaultWhenOnlyFileExcerptFlagOn() {
    let ctx = DispatchContext.fileSandboxContextForTool(
        "read_file",
        readFileEnabled: false,           // read_file's own flag is OFF
        fileExcerptEnabled: true,
        dataRoot: w42DataRootURL
    )
    w42ExpectDefaultShape(ctx)
}

/// Symmetric: file_excerpt with ONLY read_file's flag ON keeps the legacy default.
@Test func w42FileExcerptKeepsDefaultWhenOnlyReadFileFlagOn() {
    let ctx = DispatchContext.fileSandboxContextForTool(
        "file_excerpt",
        readFileEnabled: true,
        fileExcerptEnabled: false,        // file_excerpt's own flag is OFF
        dataRoot: w42DataRootURL
    )
    w42ExpectDefaultShape(ctx)
}

/// With BOTH file flags OFF, even a read_file dispatch keeps the legacy default
/// context. Pins that the selector is purely additive over the flags.
@Test func w42ReadFileKeepsDefaultWhenAllFlagsOff() {
    let ctx = DispatchContext.fileSandboxContextForTool(
        "read_file",
        readFileEnabled: false,
        fileExcerptEnabled: false,
        dataRoot: w42DataRootURL
    )
    w42ExpectDefaultShape(ctx)
}

/// SECURITY invariant (gpt-5.5 W01-review finding #1): the sandbox-engaging
/// branch must ALWAYS yield a NON-empty repoRoot so `allowedRoots` is non-empty
/// and the `FileSystemActions` guard ENGAGES (an empty repoRoot → empty
/// allowedRoots → `!allowed.isEmpty` false → guard SKIPPED = the §6.240 W02
/// escape). The `dataRoot: URL` signature makes this structural — any valid file
/// URL has a non-empty `.path`, and its `deletingLastPathComponent().path` is
/// non-empty for any real path. Pinned for a deep path and a shallow one.
@Test func w42ReadFileSandboxAlwaysHasNonEmptyRepoRoot() {
    for raw in ["/private/var/na/data", "/data", "/Users/x/Library/Application Support/NativeAgent"] {
        let ctx = DispatchContext.fileSandboxContextForTool(
            "read_file", readFileEnabled: true, fileExcerptEnabled: false,
            dataRoot: URL(fileURLWithPath: raw)
        )
        #expect(!ctx.repoRoot.isEmpty)            // guard ENGAGES — no empty-roots bypass
        #expect(ctx.repoRoot == ctx.cwd)
        #expect(ctx.extra["_na_data_root"] != nil)
        #expect(ctx.extra["file_access"] != nil)
    }
}

/// PARITY (gpt-5.5 W01-review finding #2): a literal leading `~` in the data root
/// (the `NATIVE_AGENT_DATA_ROOT` env-var case `PersistenceCore.defaultDataRoot`
/// deliberately PRESERVES via URLComponents) must NOT be expanded by the helper.
/// Computing the parent URL-natively (`dataRoot.deletingLastPathComponent()`)
/// preserves it; reconstructing via `URL(fileURLWithPath: dataRoot.path)` would
/// expand `~` → `$HOME`. Build the same tilde-preserving URL the env-var branch
/// builds and assert the threaded `_na_data_root` keeps the tilde.
@Test func w42ReadFileSandboxPreservesLeadingTildeDataRoot() {
    var comps = URLComponents()
    comps.scheme = "file"
    comps.path = "~/na/data"
    guard let tildeURL = comps.url else {
        Issue.record("could not build tilde-preserving file URL")
        return
    }
    let ctx = DispatchContext.fileSandboxContextForTool(
        "read_file", readFileEnabled: true, fileExcerptEnabled: false, dataRoot: tildeURL
    )
    if case .string(let dr)? = ctx.extra["_na_data_root"] {
        #expect(dr.hasPrefix("~"))               // tilde NOT expanded to $HOME
    } else {
        Issue.record("expected _na_data_root threaded")
    }
    #expect(ctx.repoRoot.hasPrefix("~"))         // parent kept the tilde too
}

// MARK: - A4 fail-open fix (loop-A 2026-06-13): autonomy resolver must
// translate the FULL trust vocabulary and FAIL CLOSED on unknown levels.

/// The normalizer mirrors AutonomyGate.map: allowed→auto, supervised/confirm→ask,
/// deny/blocked→never, and EVERY unknown level→ask (never "auto"). The old
/// code fail-OPENed any non-{auto,ask,never} value to the "auto" scaffold.
@Test func dispatchAutonomyNormalizationFailsClosed() {
    for v in ["auto", "AUTO", " app_data_autonomous ", "workspace_autonomous"] {
        #expect(SwiftNativeDispatcher.normalizeDispatchAutonomy(v) == "auto")
    }
    for v in ["ask", "supervised", "confirm", "send_approval", "CONFIRM"] {
        #expect(SwiftNativeDispatcher.normalizeDispatchAutonomy(v) == "ask")
    }
    for v in ["never", "deny", "blocked"] {
        #expect(SwiftNativeDispatcher.normalizeDispatchAutonomy(v) == "never")
    }
    // Unknown / typo'd / empty → fail CLOSED to "ask", never "auto".
    for v in ["", "garbage", "approve", "supervize", "yolo", "allow"] {
        #expect(SwiftNativeDispatcher.normalizeDispatchAutonomy(v) == "ask")
    }
}

/// End-to-end: a trust policy that returns a vocabulary level the dispatcher
/// didn't previously recognize (confirm/garbage) must NOT auto-execute a
/// side-effecting tool — it queues for approval. 'deny' blocks; 'auto' still runs.
@Test func dispatchUnknownAutonomyDoesNotAutoExecute() async throws {
    let sb = makeSandbox()
    let http = _FakeDispatcherHTTP()
    let ledger = DispatchLedger(ledgerPath: sb.appendingPathComponent("traces/events.jsonl"))
    let reg = LocalConnectorActions(
        handlers: ["probe": { _, _ in .object(["ok": .bool(true)]) }],
        sideEffecting: ["probe"],
        trivialVerify: []
    )
    func dispatcher(_ level: String) -> SwiftNativeDispatcher {
        SwiftNativeDispatcher(
            http: http, ledger: ledger, localActions: reg,
            autonomyResolver: { _ in level }
        )
    }
    let dctx = DispatchContext.defaultForSurface("chat")

    // 'confirm' previously fell through to the "auto" default and EXECUTED.
    let confirm = try await dispatcher("confirm").dispatch(tool: "probe", input: [:], ctx: dctx, dryRun: false)
    #expect(confirm.status == "pending_approval")
    #expect(confirm.executed == false)

    // An unknown/garbage level fails CLOSED, not open.
    let garbage = try await dispatcher("garbage-level").dispatch(tool: "probe", input: [:], ctx: dctx, dryRun: false)
    #expect(garbage.status == "pending_approval")
    #expect(garbage.executed == false)

    // 'deny' blocks outright.
    let deny = try await dispatcher("deny").dispatch(tool: "probe", input: [:], ctx: dctx, dryRun: false)
    #expect(deny.status == "blocked")
    #expect(deny.executed == false)

    // 'auto' still executes — no regression for the allowed path.
    let auto = try await dispatcher("auto").dispatch(tool: "probe", input: [:], ctx: dctx, dryRun: false)
    #expect(auto.executed == true)
}

/// A4b guard: with NO trust resolver wired, a SIDE-EFFECTING native tool must
/// fail closed (require approval) instead of silently auto-executing — while a
/// read-only tool still auto-executes (no regression). The native-action
/// registry is read-only-only today; this trips if a side-effecting action is
/// ever added without first wiring a resolver.
@Test func dispatchNoResolverSideEffectingFailsClosedReadOnlyRuns() async throws {
    let sb = makeSandbox()
    let http = _FakeDispatcherHTTP()
    let ledger = DispatchLedger(ledgerPath: sb.appendingPathComponent("traces/events.jsonl"))
    let dctx = DispatchContext.defaultForSurface("native_actions")

    // Side-effecting tool, NO autonomyResolver → must NOT auto-execute.
    let seReg = LocalConnectorActions(
        handlers: ["probe": { _, _ in .object(["ok": .bool(true)]) }],
        sideEffecting: ["probe"],
        trivialVerify: []
    )
    let dSe = SwiftNativeDispatcher(http: http, ledger: ledger, localActions: seReg)
    let se = try await dSe.dispatch(tool: "probe", input: [:], ctx: dctx, dryRun: false)
    #expect(se.status == "pending_approval")
    #expect(se.executed == false)

    // Read-only tool, NO resolver → still auto-executes (no regression).
    let roReg = LocalConnectorActions(
        handlers: ["read_probe": { _, _ in .object(["ok": .bool(true)]) }],
        sideEffecting: [],
        trivialVerify: []
    )
    let dRo = SwiftNativeDispatcher(http: http, ledger: ledger, localActions: roReg)
    let ro = try await dRo.dispatch(tool: "read_probe", input: [:], ctx: dctx, dryRun: false)
    #expect(ro.executed == true)
}

// MARK: - A5.5(d): DispatchLedger co-writer routes through the shared capped append

@Test func dispatchLedgerAppendRoutesThroughCappedWriterCleanly() async throws {
    // traces/events.jsonl is a multi-writer feed; this co-writer used to append
    // UNBOUNDED. It now routes through the shared appendJSONLCapped (the 5000-
    // line boundary itself is pinned by JSONLLineCapTests). This pin proves the
    // rerouting round-trips every row with no corruption/duplication.
    let sb = makeSandbox()
    let ledgerPath = sb.appendingPathComponent("traces/events.jsonl")
    let ledger = DispatchLedger(ledgerPath: ledgerPath)
    for i in 0..<50 {
        try await ledger.append(DispatchLedgerEntry(
            id: "e\(i)", kind: "dispatch", title: "tool:t\(i)",
            status: "ok", payload: .object(["n": .int(Int64(i))]),
            createdAt: "2026-07-23T00:00:0\(i % 10)Z"
        ))
    }
    let text = try String(contentsOf: ledgerPath, encoding: .utf8)
    let lines = text.split(separator: "\n", omittingEmptySubsequences: true)
    #expect(lines.count == 50, "expected 50 ledger lines, got \(lines.count)")
    let tail = try await ledger.tail(limit: 5)
    #expect(tail.count == 5)
    #expect(tail.last?.id == "e49")
}
