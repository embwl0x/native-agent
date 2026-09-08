import Foundation
import Testing
import NativeAgentCore
import PersistenceCore
@testable import MacControl
#if canImport(Darwin)
import Darwin
#endif

// MARK: - file ops (NATIVE)

@Test func fileReadHappyPath() async throws {
    let fm = _MockFileManagerAdapter()
    fm.files["/tmp/swiftmc/hello.txt"] = Data("hello world".utf8)
    let client = SwiftNativeMacControl(
        http: _MockHTTPClient(),
        fileManagerAdapter: fm
    )
    let r = try await client.dispatch(action: "file/read", body: [
        "path": .string("/tmp/swiftmc/hello.txt"),
    ])
    #expect(r.ok == true)
    if case .object(let obj) = r.output, case .string(let s) = obj["content"] ?? .null {
        #expect(s == "hello world")
    } else {
        Issue.record("missing content field")
    }
}

@Test func fileReadRespectsMaxBytes() async throws {
    let fm = _MockFileManagerAdapter()
    fm.files["/tmp/swiftmc/big.txt"] = Data(String(repeating: "A", count: 5000).utf8)
    let client = SwiftNativeMacControl(
        http: _MockHTTPClient(),
        fileManagerAdapter: fm
    )
    let r = try await client.dispatch(action: "file/read", body: [
        "path": .string("/tmp/swiftmc/big.txt"),
        "max_bytes": .int(100),
    ])
    if case .object(let obj) = r.output, case .string(let s) = obj["content"] ?? .null {
        #expect(s.count == 100)
    } else {
        Issue.record("missing content field")
    }
}

@Test func fileReadMissingPathThrows() async throws {
    let client = SwiftNativeMacControl(http: _MockHTTPClient(), fileManagerAdapter: _MockFileManagerAdapter())
    do {
        _ = try await client.dispatch(action: "file/read", body: [:])
        Issue.record("expected missingField")
    } catch MacControlError.missingField(let f) {
        #expect(f == "path")
    } catch {
        Issue.record("wrong error: \(error)")
    }
}

@Test func fileWriteRunsInSwift() async throws {
    let http = _MockHTTPClient()
    let fm = _MockFileManagerAdapter()
    let client = SwiftNativeMacControl(http: http, fileManagerAdapter: fm)
    let r = try await client.dispatch(action: "file/write", body: [
        "path": .string("/tmp/swiftmc/out.txt"),
        "content": .string("roundtrip"),
    ])
    #expect(r.viaSwift == true)
    #expect(r.ok == true)
    let calls = await http.calls
    #expect(calls.isEmpty)
    #expect(fm.files["/tmp/swiftmc/out.txt"] == Data("roundtrip".utf8))
}

@Test func fileWriteAppendRunsInSwift() async throws {
    let http = _MockHTTPClient()
    let fm = _MockFileManagerAdapter()
    fm.files["/tmp/swiftmc/log.txt"] = Data("a".utf8)
    let client = SwiftNativeMacControl(http: http, fileManagerAdapter: fm)
    _ = try await client.dispatch(action: "file/write", body: [
        "path": .string("/tmp/swiftmc/log.txt"),
        "content": .string("b"),
        "append": .bool(true),
    ])
    let calls = await http.calls
    #expect(calls.isEmpty)
    #expect(fm.files["/tmp/swiftmc/log.txt"] == Data("ab".utf8))
}

@Test func fileListReturnsBasenames() async throws {
    let fm = _MockFileManagerAdapter()
    fm.directories["/tmp/swiftmc/dir"] = ["a.txt", "b.txt", "c.txt"]
    let client = SwiftNativeMacControl(http: _MockHTTPClient(), fileManagerAdapter: fm)
    let r = try await client.dispatch(action: "file/list", body: [
        "path": .string("/tmp/swiftmc/dir"),
    ])
    if case .object(let obj) = r.output,
       case .array(let entries) = obj["entries"] ?? .null {
        let names = entries.compactMap { (v: JSONValue) -> String? in
            if case .string(let s) = v { return s }; return nil
        }
        #expect(names == ["a.txt", "b.txt", "c.txt"])
    } else {
        Issue.record("missing entries field")
    }
}

@Test func fileMoveRunsInSwift() async throws {
    let http = _MockHTTPClient()
    let fm = _MockFileManagerAdapter()
    fm.files["/tmp/swiftmc/a.txt"] = Data("X".utf8)
    let client = SwiftNativeMacControl(http: http, fileManagerAdapter: fm)
    _ = try await client.dispatch(action: "file/move", body: [
        "src": .string("/tmp/swiftmc/a.txt"),
        "dst": .string("/tmp/swiftmc/b.txt"),
    ])
    let calls = await http.calls
    #expect(calls.isEmpty)
    #expect(fm.files["/tmp/swiftmc/a.txt"] == nil)
    #expect(fm.files["/tmp/swiftmc/b.txt"] == Data("X".utf8))
}

@Test func fileTrashRunsInSwift() async throws {
    let http = _MockHTTPClient()
    let fm = _MockFileManagerAdapter()
    fm.files["/tmp/swiftmc/trash.txt"] = Data("X".utf8)
    let client = SwiftNativeMacControl(http: http, fileManagerAdapter: fm)
    let r = try await client.dispatch(action: "file/trash", body: [
        "path": .string("/tmp/swiftmc/trash.txt"),
    ])
    #expect(r.ok == true)
    #expect(r.viaSwift == true)
    #expect(fm.files["/tmp/swiftmc/trash.txt"] == nil)
    #expect(fm.trashed == ["/tmp/swiftmc/trash.txt"])
    let calls = await http.calls
    #expect(calls.isEmpty)
}

// MARK: - Sensitive-path fence

@Test func sensitivePathFenceBlocksKeychain() async throws {
    let fm = _MockFileManagerAdapter()
    let client = SwiftNativeMacControl(http: _MockHTTPClient(), fileManagerAdapter: fm)
    do {
        _ = try await client.dispatch(action: "file/read", body: [
            "path": .string("~/Library/Keychains/login.keychain-db"),
        ])
        Issue.record("expected sensitivePathDenied")
    } catch MacControlError.sensitivePathDenied {
        // expected
    } catch {
        Issue.record("wrong error: \(error)")
    }
    // Critical: confirm the file system was never touched (the gate
    // ran BEFORE the FileManager call).
    #expect(fm.files.isEmpty)
}

@Test func fileWriteRejectsSensitivePathInSwift() async throws {
    let http = _MockHTTPClient()
    let fm = _MockFileManagerAdapter()
    let client = SwiftNativeMacControl(http: http, fileManagerAdapter: fm)
    do {
        _ = try await client.dispatch(action: "file/write", body: [
            "path": .string("/tmp/swiftmc/trust_policy.json"),
            "content": .string("{}"),
        ])
        Issue.record("expected sensitivePathDenied")
    } catch MacControlError.sensitivePathDenied {
        // expected
    } catch {
        Issue.record("wrong error: \(error)")
    }
    let calls = await http.calls
    #expect(calls.isEmpty)
    #expect(fm.files["/tmp/swiftmc/trust_policy.json"] == nil)
}

@Test func fileWriteRejectsProtectedSystemPathInSwift() async throws {
    let http = _MockHTTPClient()
    let fm = _MockFileManagerAdapter()
    let client = SwiftNativeMacControl(http: http, fileManagerAdapter: fm)
    do {
        _ = try await client.dispatch(action: "file/write", body: [
            "path": .string("/etc/hosts"),
            "content": .string("127.0.0.1 example.local"),
        ])
        Issue.record("expected protected path denial")
    } catch MacControlError.sensitivePathDenied(let reason) {
        #expect(reason.contains("protected_system_path_denied"))
    } catch {
        Issue.record("wrong error: \(error)")
    }
    let calls = await http.calls
    #expect(calls.isEmpty)
    #expect(fm.files["/private/etc/hosts"] == nil)
}

@Test func fileMoveRejectsSensitiveDestInSwift() async throws {
    let http = _MockHTTPClient()
    let fm = _MockFileManagerAdapter()
    fm.files["/tmp/swiftmc/innocent.txt"] = Data("X".utf8)
    let client = SwiftNativeMacControl(http: http, fileManagerAdapter: fm)
    do {
        _ = try await client.dispatch(action: "file/move", body: [
            "src": .string("/tmp/swiftmc/innocent.txt"),
            "dst": .string("~/.ssh/authorized_keys"),
        ])
        Issue.record("expected sensitivePathDenied")
    } catch MacControlError.sensitivePathDenied {
        // expected
    } catch {
        Issue.record("wrong error: \(error)")
    }
    let calls = await http.calls
    #expect(calls.isEmpty)
    #expect(fm.files["/tmp/swiftmc/innocent.txt"] == Data("X".utf8))
}

// MARK: - Shell whitelist

@Test func whitelistAllowsEcho() {
    #expect(MacControlShellWhitelist.validate("echo hi") == nil)
}

@Test func whitelistRejectsRm() {
    let r = MacControlShellWhitelist.validate("rm -rf /tmp/everything")
    #expect(r != nil)
    #expect(r?.contains("not whitelisted") == true)
}

@Test func whitelistRejectsMetacharChain() {
    let r = MacControlShellWhitelist.validate("echo hi; rm -rf /")
    #expect(r?.contains("metacharacter") == true)
}

@Test func whitelistRejectsBackticks() {
    #expect(MacControlShellWhitelist.validate("echo `whoami`") != nil)
}

@Test func whitelistRejectsPipe() {
    #expect(MacControlShellWhitelist.validate("echo a | cat") != nil)
}

@Test func whitelistRejectsEmptyCommand() {
    let r = MacControlShellWhitelist.validate("   ")
    #expect(r?.contains("empty") == true)
}

@Test func whitelistRejectsAbsolutePath() {
    // Even though basename `date` IS whitelisted, an absolute path
    // bypasses NAME control — attacker could drop /tmp/date executable.
    let r = MacControlShellWhitelist.validate("/tmp/date now")
    #expect(r != nil)
    #expect(r?.contains("path not allowed") == true)
}

@Test func whitelistRejectsRelativePath() {
    // `./date` would resolve to attacker-controlled cwd.
    let r = MacControlShellWhitelist.validate("./date")
    #expect(r != nil)
    #expect(r?.contains("relative path") == true)
}

// MARK: - Shell dispatch

@Test func shellDispatchRunsInSwift() async throws {
    let http = _MockHTTPClient()
    let proc = _MockProcessAdapter()
    await proc.queue(ProcessRunResult(exitCode: 0, stdout: "hi\n", stderr: ""))
    let client = SwiftNativeMacControl(http: http, processAdapter: proc)
    let r = try await client.dispatch(action: "shell", body: [
        "command": .string("echo hi"),
    ])
    #expect(r.viaSwift == true)
    #expect(r.ok == true)
    let calls = await http.calls
    #expect(calls.isEmpty)
    let procCalls = await proc.calls
    #expect(procCalls.count == 1)
    #expect(procCalls.first?.executable == "/bin/sh")
}

@Test func shellDispatchRejectedCommandThrowsBeforeProcess() async throws {
    let http = _MockHTTPClient()
    let proc = _MockProcessAdapter()
    let client = SwiftNativeMacControl(http: http, processAdapter: proc)
    do {
        _ = try await client.dispatch(action: "shell", body: [
            "command": .string("rm -rf /"),
        ])
        Issue.record("expected shellNotWhitelisted")
    } catch MacControlError.shellNotWhitelisted {
        // expected
    } catch {
        Issue.record("wrong error: \(error)")
    }
    let calls = await http.calls
    #expect(calls.isEmpty)
    let procCalls = await proc.calls
    #expect(procCalls.isEmpty)
}

// MARK: - applescript adapter (direct)

@Test func appleScriptAdapterReturnsResult() throws {
    let scr = _MockAppleScriptAdapter()
    scr.result = "hello"
    let out = try scr.run(script: "return \"hello\"")
    #expect(out == "hello")
    #expect(scr.lastScript == "return \"hello\"")
}

@Test func appleScriptAdapterPropagatesError() {
    let scr = _MockAppleScriptAdapter()
    scr.shouldThrow = MacControlError.applescriptFailed("syntax")
    do {
        _ = try scr.run(script: "garbage")
        Issue.record("expected throw")
    } catch MacControlError.applescriptFailed(let m) {
        #expect(m == "syntax")
    } catch {
        Issue.record("wrong error: \(error)")
    }
}

@Test func fileMoveRejectsProtectedSystemDestInSwift() async throws {
    let http = _MockHTTPClient()
    let fm = _MockFileManagerAdapter()
    fm.files["/tmp/swiftmc/innocent.txt"] = Data("X".utf8)
    let client = SwiftNativeMacControl(http: http, fileManagerAdapter: fm)
    do {
        _ = try await client.dispatch(action: "file/move", body: [
            "src": .string("/tmp/swiftmc/innocent.txt"),
            "dst": .string("/Applications/NativeAgent.app/Contents/Info.plist"),
        ])
        Issue.record("expected protected path denial")
    } catch MacControlError.sensitivePathDenied(let reason) {
        #expect(reason.contains("protected_system_path_denied"))
    } catch {
        Issue.record("wrong error: \(error)")
    }
    let calls = await http.calls
    #expect(calls.isEmpty)
}

@Test func appleScriptHandlerRejectsEmptyScript() async throws {
    let http = _MockHTTPClient()
    let client = SwiftNativeMacControl(http: http)
    do {
        _ = try await client.dispatch(action: "applescript", body: [:])
        Issue.record("expected missingField")
    } catch MacControlError.missingField(let field) {
        #expect(field == "script")
    } catch {
        Issue.record("wrong error: \(error)")
    }
    let calls = await http.calls
    #expect(calls.isEmpty)
}

// MARK: - applescript dispatch

@Test func applescriptDispatchInvokesAdapter() async throws {
    let http = _MockHTTPClient()
    let scr = _MockAppleScriptAdapter()
    let client = SwiftNativeMacControl(
        http: http,
        appleScriptAdapter: scr
    )
    let r = try await client.dispatch(action: "applescript", body: [
        "script": .string("return \"hello\""),
    ])
    #expect(r.viaSwift == true)
    #expect(scr.lastScript == "return \"hello\"")
    let calls = await http.calls
    #expect(calls.isEmpty)
}

@Test func applescriptFailureSurfacesAsError() async throws {
    let http = _MockHTTPClient()
    let scr = _MockAppleScriptAdapter()
    scr.shouldThrow = MacControlError.applescriptFailed("syntax")
    let client = SwiftNativeMacControl(http: http, appleScriptAdapter: scr)
    let r = try await client.dispatch(action: "applescript", body: [
        "script": .string("garbage"),
    ])
    #expect(r.ok == false)
    #expect(r.error?.contains("syntax") == true)
    #expect(r.viaSwift == true)
    #expect(await http.calls.isEmpty)
}

@Test func applescriptMissingScriptThrows() async throws {
    let http = _MockHTTPClient()
    let client = SwiftNativeMacControl(http: http)
    do {
        _ = try await client.dispatch(action: "applescript", body: [:])
        Issue.record("expected missingField")
    } catch MacControlError.missingField(let field) {
        #expect(field == "script")
    } catch {
        Issue.record("wrong error: \(error)")
    }
    #expect(await http.calls.isEmpty)
}

// MARK: - app control

@Test func focusAppRunsInSwiftWithoutHTTP() async throws {
    let http = _MockHTTPClient()
    let apps = _MockAppControlAdapter()
    let client = SwiftNativeMacControl(http: http, appControlAdapter: apps)
    let r = try await client.dispatch(action: "focus_app", body: [
        "app": .string("Safari"),
    ])
    #expect(r.ok == true)
    #expect(r.viaSwift == true)
    #expect(r.action == "focus_app")
    #expect(await http.calls.isEmpty)
    #expect(await apps.calls == [.focus("Safari")])
    guard case .object(let obj) = r.output else {
        Issue.record("expected app-control output object")
        return
    }
    #expect(obj["status"] == .string("focused"))
    #expect(obj["bundle_identifier"] == .string("com.apple.Safari"))
    #expect(obj["activated"] == .bool(true))
}

@Test func focusAppUsesObservedFrontmostStateWhenActivationRequestReturnsFalse() async throws {
    let apps = _MockAppControlAdapter()
    await apps.configureFocus(result: AppControlRunResult(
        requestedName: "Safari",
        matchedName: "Safari",
        bundleIdentifier: "com.apple.Safari",
        processIdentifier: 123,
        launched: false,
        activated: false,
        activationRequestAccepted: false,
        activationFallbackAttempted: true,
        activationFallbackSucceeded: true,
        terminated: false
    ), frontmost: true)
    let client = SwiftNativeMacControl(http: _MockHTTPClient(), appControlAdapter: apps)

    let result = try await client.dispatch(action: "focus_app", body: ["app": .string("Safari")])

    #expect(result.ok)
    #expect(result.error == nil)
    guard case .object(let output) = result.output else {
        Issue.record("expected app-control output object")
        return
    }
    #expect(output["status"] == .string("focused"))
    #expect(output["activated"] == .bool(true))
    #expect(output["verified"] == .bool(true))
    #expect(output["activation_request_accepted"] == .bool(false))
    #expect(output["activation_fallback_succeeded"] == .bool(true))
}

@Test func focusAppFailsHonestlyWhenActivationRequestReturnsFalseAndTargetNeverBecomesFrontmost() async throws {
    let apps = _MockAppControlAdapter()
    await apps.configureFocus(result: AppControlRunResult(
        requestedName: "Safari",
        matchedName: "Safari",
        bundleIdentifier: "com.apple.Safari",
        processIdentifier: 123,
        launched: false,
        activated: false,
        activationRequestAccepted: false,
        activationFallbackAttempted: true,
        activationFallbackSucceeded: true,
        activationFailureReason: "NSRunningApplication.activate returned false; NSWorkspace.openApplication fallback completed; target was not observed frontmost within 1.5 seconds",
        terminated: false
    ), frontmost: false)
    let client = SwiftNativeMacControl(http: _MockHTTPClient(), appControlAdapter: apps)

    let result = try await client.dispatch(action: "focus_app", body: ["app": .string("Safari")])

    #expect(result.ok == false)
    #expect(result.error?.contains("NSRunningApplication.activate returned false") == true)
    #expect(result.error?.contains("fallback completed") == true)
    #expect(result.error?.contains("not observed frontmost") == true)
    guard case .object(let output) = result.output else {
        Issue.record("expected app-control output object")
        return
    }
    #expect(output["status"] == .string("focus_failed"))
    #expect(output["activated"] == .bool(false))
    #expect(output["verified"] == .bool(false))
    #expect(output["failure_reason"] == .string(result.error!))
}

@Test func quitAppRunsInSwiftWithoutHTTP() async throws {
    let http = _MockHTTPClient()
    let apps = _MockAppControlAdapter()
    let client = SwiftNativeMacControl(http: http, appControlAdapter: apps)
    let r = try await client.dispatch(action: "quit_app", body: [
        "name": .string("Safari"),
    ])
    #expect(r.ok == true)
    #expect(r.viaSwift == true)
    #expect(r.action == "quit_app")
    #expect(await http.calls.isEmpty)
    #expect(await apps.calls == [.quit("Safari")])
    guard case .object(let obj) = r.output else {
        Issue.record("expected app-control output object")
        return
    }
    #expect(obj["status"] == .string("quit_requested"))
    #expect(obj["terminated"] == .bool(true))
}

@Test func appControlMissingAppThrows() async throws {
    let apps = _MockAppControlAdapter()
    let client = SwiftNativeMacControl(http: _MockHTTPClient(), appControlAdapter: apps)
    do {
        _ = try await client.dispatch(action: "focus_app", body: [:])
        Issue.record("expected missingField")
    } catch MacControlError.missingField(let field) {
        #expect(field == "app")
    } catch {
        Issue.record("wrong error: \(error)")
    }
    #expect(await apps.calls.isEmpty)
}

// MARK: - Sensitive-path symlink follow

@Test func sensitivePathFenceFollowsSymlinkTarget() throws {
    // Create a symlink under /tmp that points at ~/.ssh — the raw symlink
    // path is benign-looking but the resolved target is fenced.
    let fm = FileManager.default
    let linkPath = "/tmp/swiftmc_link_\(UUID().uuidString)"
    let target = ((NSHomeDirectory() as NSString).expandingTildeInPath as NSString)
        .appendingPathComponent(".ssh")
    do {
        try fm.createSymbolicLink(atPath: linkPath, withDestinationPath: target)
    } catch {
        // Some sandboxes block symlink creation under /tmp — skip gracefully.
        return
    }
    defer { try? fm.removeItem(atPath: linkPath) }
    let r = MacControlSensitivePathFence.reason(forPath: linkPath)
    #expect(r != nil, "symlink target should be fenced")
}

// MARK: - Sensitive-path daemon data roots

@Test func sensitivePathFenceBlocksDaemonOAuthDir() {
    let r = MacControlSensitivePathFence.reason(
        forPath: "~/Library/Application Support/NativeAgent/oauth/google.json"
    )
    #expect(r != nil)
}

@Test func sensitivePathFenceBlocksDaemonTrustDir() {
    let r = MacControlSensitivePathFence.reason(
        forPath: "~/Library/Application Support/NativeAgent/trust/policy.json"
    )
    #expect(r != nil)
}

@Test func sensitivePathFenceBlocksDaemonSecretsDir() {
    let r = MacControlSensitivePathFence.reason(
        forPath: "~/Library/Application Support/NativeAgent/secrets/api.key"
    )
    #expect(r != nil)
}

@Test func sensitivePathFenceBlocksLocalBridgeDiscoveryCredentials() {
    #expect(MacControlSensitivePathFence.reason(
        forPath: "~/.config/claude-bridge/bridge.json"
    ) != nil)
    #expect(MacControlSensitivePathFence.reason(
        forPath: "/Users/example/Projects/NativeAgent/data/browser_ipc.json"
    ) != nil)
}

// R2-2: data root may live outside AppSupport — repo `/data/<segment>/`,
// or the Swift-native `NATIVE_AGENT_DATA_ROOT`-relocated `<root>/<segment>/`.
// Match by path-component boundary, NOT substring.

@Test func sensitivePathFenceBlocksRepoDataOAuthDir() {
    let r = MacControlSensitivePathFence.reason(
        forPath: "/Users/example/Projects/NativeAgent/data/oauth_tokens/google.json"
    )
    #expect(r != nil, "repo-relative /data/oauth_tokens/* must be fenced")
}

@Test func sensitivePathFenceAllowsNonDataBoundary() {
    // Substring `data` inside `notdata` must NOT trigger — only a true
    // `/data/` path-component boundary should.
    let r = MacControlSensitivePathFence.reason(forPath: "/tmp/notdata/oauth/x.json")
    #expect(r == nil, "substring-only match must not fence")
}

@Test func sensitivePathFenceBlocksRepoDataNextgenRemote() {
    let r = MacControlSensitivePathFence.reason(
        forPath: "/Users/example/Projects/NativeAgent/data/nextgen/remote/session.json"
    )
    #expect(r != nil)
}

// gpt-5.5 review LOW/MED follow-up (2026-06-06): `NATIVE_AGENT_DATA` is the
// legacy daemon data-root env var. The Swift port no longer reads it as a
// config source, but the sensitive-path fence MUST still cover whatever it
// points at — otherwise a stale launchctl plist can be used to pivot
// read/write tools at the daemon-era root and bypass the explicit
// AppSupport coverage. Coverage gap surfaced by the post-fix build runner:
// the previous tests only proved the fence still passes when the env var
// is unset; this test proves the new candidate ALSO denies when it IS set.
//
// Uses a UUID-stamped path so concurrent tests in this suite can't
// accidentally collide with the legacy prefix. The defer block preserves
// any pre-existing `NATIVE_AGENT_DATA` (gpt-5.5 review-2 #5): a developer
// running tests with the env var already set would otherwise see their
// shell-level export clobbered, surprising the next test run.
@Test func sensitivePathFenceBlocksLegacyDaemonDataRootWhenEnvSet() {
    let legacyRoot = "/tmp/legacy-daemon-root-test-\(UUID().uuidString)"
    let prior = getenv("NATIVE_AGENT_DATA").map { String(cString: $0) }
    setenv("NATIVE_AGENT_DATA", legacyRoot, 1)
    defer {
        if let prior {
            setenv("NATIVE_AGENT_DATA", prior, 1)
        } else {
            unsetenv("NATIVE_AGENT_DATA")
        }
    }

    // Path under the legacy root's oauth dir — should be denied.
    let denied = MacControlSensitivePathFence.reason(
        forPath: "\(legacyRoot)/oauth_tokens/google.json"
    )
    #expect(denied != nil, "legacy daemon data root must be fenced when env var is set")

    // Substring-only match below the legacy prefix must NOT trigger — segment
    // boundary discipline is still in effect.
    let benign = MacControlSensitivePathFence.reason(
        forPath: "\(legacyRoot)-not-daemon/oauth_tokens/google.json"
    )
    #expect(benign == nil, "segment-only prefix discipline must hold")
}

// MARK: - spotlight

@Test func spotlightParsesMdfindOutput() async throws {
    let proc = _MockProcessAdapter()
    await proc.queue(ProcessRunResult(
        exitCode: 0,
        stdout: "/Users/test/a.pdf\n/Users/test/b.pdf\n/Users/test/c.pdf\n",
        stderr: ""
    ))
    let client = SwiftNativeMacControl(http: _MockHTTPClient(), processAdapter: proc)
    let r = try await client.dispatch(action: "spotlight", body: [
        "query": .string("invoice"),
        "limit": .int(2),
    ])
    #expect(r.ok == true)
    if case .object(let obj) = r.output,
       case .array(let arr) = obj["results"] ?? .null {
        #expect(arr.count == 2)
    } else {
        Issue.record("missing results")
    }
    let calls = await proc.calls
    #expect(calls.first?.executable == "/usr/bin/mdfind")
    #expect(calls.first?.arguments == ["invoice"])
}

@Test func spotlightAcceptsQAlias() async throws {
    let proc = _MockProcessAdapter()
    await proc.queue(ProcessRunResult(exitCode: 0, stdout: "", stderr: ""))
    let client = SwiftNativeMacControl(http: _MockHTTPClient(), processAdapter: proc)
    let r = try await client.dispatch(action: "spotlight", body: [
        "q": .string("legacy"),
    ])
    #expect(r.ok == true)
    let calls = await proc.calls
    #expect(calls.first?.arguments == ["legacy"])
}

@Test func spotlightMissingQueryThrows() async throws {
    let proc = _MockProcessAdapter()
    let client = SwiftNativeMacControl(http: _MockHTTPClient(), processAdapter: proc)
    do {
        _ = try await client.dispatch(action: "spotlight", body: [:])
        Issue.record("expected missingField")
    } catch MacControlError.missingField {
        // expected
    } catch {
        Issue.record("wrong error: \(error)")
    }
}
