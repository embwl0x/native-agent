import Foundation
import Testing
import NativeAgentCore
import PersistenceCore
@testable import MacControl
#if canImport(Darwin)
import Darwin
#endif

// MARK: - Gate pre-flight (wave 30 W01)

@Test func preflightMasterGateOffShortCircuitsBeforeProxy() async throws {
    // shell is Swift-native; with master gate OFF the pre-flight must refuse
    // IN-PROCESS (viaSwift:true, 403) WITHOUT any HTTP call.
    let http = _MockHTTPClient()
    var pol = _permissiveMacPolicy()
    pol.enabled = false
    let client = SwiftNativeMacControl(
        http: http,
        policyProvider: _StubPolicyProvider(policy: pol)
    )
    let r = try await client.dispatch(action: "shell", body: ["command": .string("echo hi")])
    #expect(r.ok == false)
    #expect(r.viaSwift == true)
    #expect(r.httpStatus == 403)
    #expect(r.error == "mac_control_disabled: master gate off")
    let calls = await http.calls
    #expect(calls.isEmpty, "refused request must NOT round-trip to the daemon")
}

@Test func preflightPerCategoryOffRefusesWithDaemonParityString() async throws {
    let http = _MockHTTPClient()
    var pol = _permissiveMacPolicy()
    pol.categoryAllowed["shell_allowed"] = false
    let client = SwiftNativeMacControl(
        http: http,
        policyProvider: _StubPolicyProvider(policy: pol)
    )
    let r = try await client.dispatch(action: "shell", body: ["command": .string("echo hi")])
    #expect(r.error == "category_disabled: shell_allowed is off")
    #expect(r.httpStatus == 403)
    let calls = await http.calls
    #expect(calls.isEmpty)
}

/// Pins the refusal RESULT.OUTPUT contract that NativeClient.synthesizeNativeReceipt
/// (Sources/NativeAgentApp/NativeClient.swift, W31 W05) reads to build an honest
/// `blocked:true / block_reason / status:"blocked"` receipt instead of the wave-30
/// W01 synthesized 200/blocked=false. If a future refactor of `refusalResult` drops
/// `block_reason` / `blocked_by` from the output object, the NativeClient receipt
/// silently regresses to blocked=false — this test fails first.
@Test func preflightRefusalOutputCarriesBlockReasonContractForNativeClient() async throws {
    let http = _MockHTTPClient()
    var pol = _permissiveMacPolicy()
    pol.enabled = false
    let client = SwiftNativeMacControl(
        http: http,
        policyProvider: _StubPolicyProvider(policy: pol)
    )
    let r = try await client.dispatch(action: "shell", body: ["command": .string("echo hi")])
    #expect(r.ok == false)
    #expect(r.httpStatus == 403)
    // The NativeClient reads block_reason / blocked_by / status out of result.output.
    guard case .object(let out) = r.output else {
        Issue.record("refusal result.output must be a JSON object the NativeClient can read")
        return
    }
    #expect(out["status"] == .string("blocked"))
    #expect(out["blocked_by"] == .string("swift_gate_preflight"))
    // block_reason must be non-empty and match the gate reason verbatim (daemon parity).
    guard case .string(let reason)? = out["block_reason"] else {
        Issue.record("refusal result.output must carry a string block_reason")
        return
    }
    #expect(!reason.isEmpty)
    #expect(reason == r.error, "block_reason must mirror the gate reason the daemon's _blocked_receipt logs")
}

@Test func preflightRemoteIosOffRefusesOnlyForIosTrigger() async throws {
    let http = _MockHTTPClient()
    var pol = _permissiveMacPolicy()
    pol.remoteFromIOSAllowed = false
    let client = SwiftNativeMacControl(
        http: http,
        policyProvider: _StubPolicyProvider(policy: pol)
    )
    // ios trigger → refused.
    let r = try await client.dispatch(action: "shortcut", body: [
        "name": .string("X"), "trigger": .string("ios"),
    ])
    #expect(r.error == "remote_ios_disabled: remote_from_ios_allowed is off")
    #expect(await http.calls.isEmpty)
}

@Test func preflightUserTriggerNotGatedByRemoteIos() async throws {
    let http = _MockHTTPClient()
    var pol = _permissiveMacPolicy()
    pol.remoteFromIOSAllowed = false
    let client = SwiftNativeMacControl(
        http: http,
        policyProvider: _StubPolicyProvider(policy: pol)
    )
    // user trigger (default) → remote gate does not apply, then shortcut
    // fails closed because it is not implemented in Swift yet.
    let r = try await client.dispatch(action: "shortcut", body: ["name": .string("X")])
    #expect(r.viaSwift == true)
    #expect(r.httpStatus == 501)
    #expect(await http.calls.isEmpty)
}

@Test func preflightAllowsProceedToNativeAction() async throws {
    // notify is NATIVE; a permissive policy must let it run in-process.
    let mc = _MockNotificationCenter()
    let client = SwiftNativeMacControl(
        http: _MockHTTPClient(),
        notificationCenterAdapter: mc,
        policyProvider: _StubPolicyProvider(policy: _permissiveMacPolicy())
    )
    let r = try await client.dispatch(action: "notify", body: [
        "title": .string("hi"), "message": .string("there"),
    ])
    #expect(r.ok == true)
    #expect(r.viaSwift == true)
    #expect(await mc.calls.count == 1)
}

@Test func preflightNilProviderIsTransparent() async throws {
    // No provider (test-only direct handler mode) → shell can execute in-process.
    let http = _MockHTTPClient()
    let proc = _MockProcessAdapter()
    await proc.queue(ProcessRunResult(exitCode: 0, stdout: "hi\n", stderr: ""))
    let client = SwiftNativeMacControl(http: http, processAdapter: proc)  // no provider
    let r = try await client.dispatch(action: "shell", body: ["command": .string("echo hi")])
    #expect(r.viaSwift == true)
    #expect(await http.calls.isEmpty)
    #expect(await proc.calls.count == 1)
}

@Test func preflightUnresolvedPolicyFailsClosedInSwift() async throws {
    let http = _MockHTTPClient()
    let client = SwiftNativeMacControl(
        http: http,
        policyProvider: _StubPolicyProvider(policy: nil)
    )
    let r = try await client.dispatch(action: "shell", body: ["command": .string("echo hi")])
    #expect(r.viaSwift == true)
    #expect(r.httpStatus == 403)
    #expect(r.error == "mac_control_policy_unavailable: Swift trust policy could not be resolved")
    #expect(await http.calls.isEmpty)
}

@Test func preflightUnresolvedPolicyBlocksNativeActionBeforeSideEffect() async throws {
    let http = _MockHTTPClient()
    let mc = _MockNotificationCenter()
    let client = SwiftNativeMacControl(
        http: http,
        notificationCenterAdapter: mc,
        policyProvider: _StubPolicyProvider(policy: nil)
    )
    let r = try await client.dispatch(action: "notify", body: [
        "title": .string("hi"), "message": .string("there"),
    ])
    #expect(r.viaSwift == true)
    #expect(r.httpStatus == 403)
    #expect(await http.calls.isEmpty)
    #expect(await mc.calls.isEmpty, "in-process notification must NOT have fired ungated")
}

@Test func preflightNoProviderStillRunsNativeInProcess() async throws {
    // Contrast with above: NO provider configured (the default) keeps wave-29
    // behavior — notify runs in-process (no policy expectation on that path).
    let http = _MockHTTPClient()
    let mc = _MockNotificationCenter()
    let client = SwiftNativeMacControl(
        http: http,
        notificationCenterAdapter: mc
    )  // no provider
    let r = try await client.dispatch(action: "notify", body: [
        "title": .string("hi"), "message": .string("there"),
    ])
    #expect(r.viaSwift == true)
    #expect(await mc.calls.count == 1)
    #expect(await http.calls.isEmpty)
}

@Test func preflightSelfTestUnsupportedWithoutDaemon() async throws {
    // self_test has no single pre-flight category and no Swift executor yet.
    let http = _MockHTTPClient()
    var pol = _permissiveMacPolicy()
    pol.enabled = false
    let client = SwiftNativeMacControl(
        http: http,
        policyProvider: _StubPolicyProvider(policy: pol)
    )
    let r = try await client.dispatch(action: "self_test", body: [:])
    #expect(r.viaSwift == true)
    #expect(r.httpStatus == 501)
    #expect(await http.calls.isEmpty)
}

@Test func preflightFilePolicyDeniesOutsideWorkspace() async throws {
    // file/write is Swift-native. With a trust policy that denies outside
    // workspaces and no full-mac window, an outside path must refuse with the
    // verbatim W4 file-policy string BEFORE the write.
    let http = _MockHTTPClient()
    var pol = _permissiveMacPolicy()
    pol.trustPolicy = MacControlTrustPolicy(
        outsideWorkspaceDefault: "deny",
        permissionLevel: "balanced"
    )
    pol.workspaceRoots = ["/tmp/allowed_ws"]
    let client = SwiftNativeMacControl(
        http: http,
        policyProvider: _StubPolicyProvider(policy: pol)
    )
    let r = try await client.dispatch(action: "file/write", body: [
        "path": .string("/tmp/outside/file.txt"),
        "content": .string("x"),
    ])
    #expect(r.ok == false)
    #expect(r.viaSwift == true)
    #expect(r.httpStatus == 403)
    #expect(r.error?.hasPrefix("file_policy_denied:") == true)
    #expect(r.error?.contains("outside configured workspaces") == true)
    #expect(await http.calls.isEmpty)
}

@Test func preflightFilePolicyAllowsInsideWorkspace() async throws {
    let http = _MockHTTPClient()
    let fm = _MockFileManagerAdapter()
    var pol = _permissiveMacPolicy()
    pol.trustPolicy = MacControlTrustPolicy(outsideWorkspaceDefault: "deny")
    pol.workspaceRoots = ["/tmp/allowed_ws"]
    let client = SwiftNativeMacControl(
        http: http,
        fileManagerAdapter: fm,
        policyProvider: _StubPolicyProvider(policy: pol)
    )
    let r = try await client.dispatch(action: "file/write", body: [
        "path": .string("/tmp/allowed_ws/file.txt"),
        "content": .string("x"),
    ])
    #expect(r.viaSwift == true)
    #expect(r.ok == true)
    #expect(fm.files["/tmp/allowed_ws/file.txt"] == Data("x".utf8))
    #expect(await http.calls.isEmpty)
}

@Test func preflightFullMacBlocksTrashWithoutDeveloperModeEvenWithStaleDestructiveFlag() async throws {
    let http = _MockHTTPClient()
    let fm = _MockFileManagerAdapter()
    fm.files["/tmp/swiftmc/trash.txt"] = Data("X".utf8)
    var pol = _permissiveMacPolicy()
    pol.trustPolicy = MacControlTrustPolicy(
        outsideWorkspaceDefault: "allow",
        permissionLevel: "full_mac_os",
        developerMode: false,
        allowDestructiveActions: true
    )
    let client = SwiftNativeMacControl(
        http: http,
        fileManagerAdapter: fm,
        policyProvider: _StubPolicyProvider(policy: pol)
    )
    let r = try await client.dispatch(action: "file/trash", body: [
        "path": .string("/tmp/swiftmc/trash.txt"),
    ])
    #expect(r.ok == false)
    #expect(r.httpStatus == 403)
    #expect(r.error == "developer_mode_required: file/trash requires Developer Mode")
    #expect(fm.files["/tmp/swiftmc/trash.txt"] != nil)
    #expect(fm.trashed.isEmpty)
    #expect(await http.calls.isEmpty)
}

@Test func preflightDeveloperModeAllowsTrash() async throws {
    let http = _MockHTTPClient()
    let fm = _MockFileManagerAdapter()
    fm.files["/tmp/swiftmc/trash.txt"] = Data("X".utf8)
    var pol = _permissiveMacPolicy()
    pol.trustPolicy = MacControlTrustPolicy(
        outsideWorkspaceDefault: "allow",
        permissionLevel: "full_mac_os",
        developerMode: true,
        allowDestructiveActions: false
    )
    let client = SwiftNativeMacControl(
        http: http,
        fileManagerAdapter: fm,
        policyProvider: _StubPolicyProvider(policy: pol)
    )
    let r = try await client.dispatch(action: "file/trash", body: [
        "path": .string("/tmp/swiftmc/trash.txt"),
    ])
    #expect(r.ok == true)
    #expect(r.httpStatus == nil)
    #expect(fm.files["/tmp/swiftmc/trash.txt"] == nil)
    #expect(fm.trashed == ["/tmp/swiftmc/trash.txt"])
    #expect(await http.calls.isEmpty)
}

@Test func preflightSensitivePathSkipsFilePolicyRefusal() async throws {
    // A sensitive path that is ALSO outside-workspace must NOT surface the
    // file-policy string from the pre-flight — the pre-flight skips it so the
    // authoritative sensitive reason from the native write fence wins. The
    // request therefore reaches the Swift file handler, whose sensitive fence
    // raises the sensitive-path error.
    let http = _MockHTTPClient()
    var pol = _permissiveMacPolicy()
    pol.trustPolicy = MacControlTrustPolicy(outsideWorkspaceDefault: "deny")
    pol.workspaceRoots = ["/tmp/allowed_ws"]
    let client = SwiftNativeMacControl(
        http: http,
        policyProvider: _StubPolicyProvider(policy: pol)
    )
    do {
        _ = try await client.dispatch(action: "file/write", body: [
            "path": .string("/tmp/outside/trust_policy.json"),
            "content": .string("x"),
        ])
        Issue.record("expected sensitivePathDenied")
    } catch MacControlError.sensitivePathDenied(let reason) {
        #expect(reason.contains("trust_policy.json"))
    } catch {
        Issue.record("wrong error: \(error)")
    }
    #expect(await http.calls.isEmpty)
}

@Test func preflightCategoryMapMatchesDaemon() {
    // Pin every dispatch action → gate category against the verified daemon
    // _gate(...) calls. self_test maps to nil (multi-category sweep).
    #expect(macControlGateCategory(forAction: "applescript") == "applescript")
    #expect(macControlGateCategory(forAction: "jxa") == "jxa")
    #expect(macControlGateCategory(forAction: "shortcut") == "shortcuts")
    #expect(macControlGateCategory(forAction: "shortcut/run") == "shortcuts")
    #expect(macControlGateCategory(forAction: "focus_app") == "accessibility")
    #expect(macControlGateCategory(forAction: "quit_app") == "accessibility")
    #expect(macControlGateCategory(forAction: "keystroke") == "accessibility")
    #expect(macControlGateCategory(forAction: "click") == "accessibility")
    #expect(macControlGateCategory(forAction: "system") == "system")
    #expect(macControlGateCategory(forAction: "file/read") == "file_ops")
    #expect(macControlGateCategory(forAction: "file/write") == "file_ops")
    #expect(macControlGateCategory(forAction: "file/list") == "file_ops")
    #expect(macControlGateCategory(forAction: "file/move") == "file_ops")
    #expect(macControlGateCategory(forAction: "file/trash") == "file_ops")
    #expect(macControlGateCategory(forAction: "notify") == "notifications")
    #expect(macControlGateCategory(forAction: "shell") == "shell")
    #expect(macControlGateCategory(forAction: "spotlight") == "spotlight")
    #expect(macControlGateCategory(forAction: "self_test") == nil)
}

@Test func preflightFilePolicyPathKeysMatchDaemon() {
    #expect(macControlFilePolicyPathKeys(forAction: "file/read") == ["path"])
    #expect(macControlFilePolicyPathKeys(forAction: "file/write") == ["path"])
    #expect(macControlFilePolicyPathKeys(forAction: "file/list") == ["path"])
    #expect(macControlFilePolicyPathKeys(forAction: "file/trash") == ["path"])
    #expect(macControlFilePolicyPathKeys(forAction: "file/move") == ["src", "dst"])
    #expect(macControlFilePolicyPathKeys(forAction: "notify") == [])
}
