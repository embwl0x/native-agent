import Foundation
import Testing
import NativeAgentCore
import PersistenceCore
@testable import MacControl
#if canImport(Darwin)
import Darwin
#endif

// MARK: - Factory routing

@Test func factoryReturnsSwiftNative() {
    let client = makeMacControl()
    #expect(client is SwiftNativeMacControl)
}

// MARK: - Sub-action inventory invariants

@Test func actionPartitionIsExhaustive() {
    // Every documented action appears in exactly one bucket.
    let overlap = macControlNativePortedActions.intersection(macControlUnsupportedActions)
    #expect(overlap.isEmpty, "actions in both buckets: \(overlap)")
    let union = macControlNativePortedActions.union(macControlUnsupportedActions)
    #expect(union == macControlAllActions)
}

@Test func actionInventoryCoversKnownDaemonRoutes() {
    // Pin the set of sub-paths the daemon exposes (the retired daemon
    // :53537–53747). If a daemon route is added, this assertion fires so
    // the Swift dispatch table can be updated in lock-step.
    let known: Set<String> = [
        "notify", "applescript", "jxa", "shortcut", "shortcut/run",
        "focus_app", "quit_app", "keystroke", "click", "system",
        "file/read", "file/write", "file/list", "file/move", "file/trash",
        "spotlight", "shell", "self_test",
    ]
    #expect(macControlAllActions == known, "drift vs daemon routes: missing=\(known.subtracting(macControlAllActions)) extra=\(macControlAllActions.subtracting(known))")
}

// MARK: - Unknown action

@Test func dispatchUnknownActionThrows() async throws {
    let client = SwiftNativeMacControl(http: _MockHTTPClient())
    do {
        _ = try await client.dispatch(action: "bogus", body: [:])
        Issue.record("expected unknownAction")
    } catch MacControlError.unknownAction(let a) {
        #expect(a == "bogus")
    } catch {
        Issue.record("wrong error: \(error)")
    }
}

@Test func dispatchTrimsLeadingTrailingSlashes() async throws {
    // Callers occasionally pass `/notify` or `notify/`; normalize before
    // dispatch so the inventory check doesn't false-positive.
    let mc = _MockNotificationCenter()
    let client = SwiftNativeMacControl(
        http: _MockHTTPClient(),
        notificationCenterAdapter: mc
    )
    let r = try await client.dispatch(action: "/notify/", body: [
        "title": .string("hi"), "message": .string("there"),
    ])
    #expect(r.action == "notify")
    #expect(r.viaSwift == true)
    let calls = await mc.calls
    #expect(calls.count == 1)
}

// MARK: - Unsupported Swift actions

@Test func unsupportedActionReturnsSwift501() async throws {
    let http = _MockHTTPClient()
    let client = SwiftNativeMacControl(http: http)
    let r = try await client.dispatch(action: "shortcut", body: [
        "name": .string("MyShortcut"),
    ])
    #expect(r.viaSwift == true)
    #expect(r.ok == false)
    #expect(r.httpStatus == 501)
    #expect(r.error?.contains("unsupported_mac_control_action") == true)
    let calls = await http.calls
    #expect(calls.isEmpty)
}

@Test func unsupportedShortcutRunAliasReturnsSwift501() async throws {
    let http = _MockHTTPClient()
    let client = SwiftNativeMacControl(http: http)
    let r = try await client.dispatch(action: "shortcut/run", body: ["name": .string("Z")])
    #expect(r.httpStatus == 501)
    let calls = await http.calls
    #expect(calls.isEmpty)
}

/// YOLO cutover 2026-08-12 (9023d24d, 84fb8201): perimeter gates entry,
/// execution ungated.
///
/// OLD CONTRACT: with NO policyProvider — the direct-library-caller escape
/// hatch that skips the policy gates — injection still failed closed on the
/// approval attestation (403 / `approval_not_granted` / status "blocked"). The
/// point was that injection did not inherit the hatch.
/// NEW CONTRACT: the attestation self-mints, so on the no-policyProvider path
/// there is nothing left to fail closed on and the keystroke executes locally.
/// Still true and still pinned: it runs IN-PROCESS — no HTTP call is made, so
/// the direct-library path never reaches out over the wire.
@Test func unattestedKeystrokeExecutesLocallyWithNoPolicyProvider() async throws {
    let http = _MockHTTPClient()
    let sink = _InertEventSink()
    let client = SwiftNativeMacControl(http: http, eventSink: sink)
    let r = try await client.dispatch(action: "keystroke", body: [
        "text": .string("hi"),
    ])
    #expect(r.error?.hasPrefix("approval_not_granted") != true,
            "the approval tier is retired: \(r.error ?? "nil")")
    #expect(r.httpStatus != 403)
    if case .object(let obj) = r.output,
       case .string(let s) = obj["status"] ?? .null {
        #expect(s != "blocked", "no approval tier remains to block on")
    } else {
        Issue.record("missing status field")
    }
    #expect(await http.calls.isEmpty, "the direct-library path stays in-process")
}

@Test func unattestedClickExecutesLocallyWithNoPolicyProvider() async throws {
    let http = _MockHTTPClient()
    let sink = _InertEventSink()
    let client = SwiftNativeMacControl(http: http, eventSink: sink)
    let r = try await client.dispatch(action: "click", body: [:])
    #expect(r.error?.hasPrefix("approval_not_granted") != true)
    #expect(r.httpStatus != 403)
    #expect(r.viaSwift == true)
    #expect(await http.calls.isEmpty, "the direct-library path stays in-process")
}

@Test func unsupportedActionSurfacesHttpStatusHint() async throws {
    let http = _MockHTTPClient()
    let client = SwiftNativeMacControl(http: http)
    let r = try await client.dispatch(action: "shortcut", body: ["name": .string("X")])
    #expect(r.httpStatus == 501)
    #expect(r.viaSwift == true)
}

@Test func nativeResultHasNilHttpStatus() async throws {
    let mc = _MockNotificationCenter()
    let client = SwiftNativeMacControl(
        http: _MockHTTPClient(),
        notificationCenterAdapter: mc
    )
    let r = try await client.dispatch(action: "notify", body: [
        "title": .string("hi"), "message": .string("there"),
    ])
    #expect(r.viaSwift == true)
    #expect(r.httpStatus == nil, "native in-process result has no upstream status")
}

@Test func unsupportedActionNeverPostsHTTP() async throws {
    let http = _MockHTTPClient()
    let client = SwiftNativeMacControl(http: http)
    _ = try await client.dispatch(action: "keystroke", body: ["text": .string("hi")])
    let calls = await http.calls
    #expect(calls.isEmpty)
}

@Test func unsupportedJxaDoesNotUseTransport() async throws {
    let http = _MockHTTPClient()
    await http.queueFailure(NSError(domain: "test", code: -1009, userInfo: nil))
    let client = SwiftNativeMacControl(http: http)
    let r = try await client.dispatch(action: "jxa", body: ["script": .string("x")])
    #expect(r.httpStatus == 501)
    #expect(await http.calls.isEmpty)
}

@Test func unknownActionThrowsWithoutHttp() async throws {
    let http = _MockHTTPClient()
    let client = SwiftNativeMacControl(http: http)
    do {
        _ = try await client.dispatch(action: "bogus", body: [:])
        Issue.record("expected unknownAction")
    } catch MacControlError.unknownAction(let action) {
        #expect(action == "bogus")
        // expected
    } catch {
        Issue.record("wrong error: \(error)")
    }
    let calls = await http.calls
    #expect(calls.isEmpty, "must not even attempt HTTP for unknown action")
}

// MARK: - Misc

@Test func resultJSONRoundTrip() {
    let r = MacControlResult(
        ok: true,
        action: "notify",
        output: .object(["title": .string("x")]),
        error: nil,
        durationMs: 42,
        viaSwift: true
    )
    let json = r.toJSON()
    if case .object(let obj) = json {
        if case .bool(let b) = obj["ok"] { #expect(b == true) } else { Issue.record("ok") }
        if case .string(let a) = obj["action"] { #expect(a == "notify") } else { Issue.record("action") }
        if case .bool(let v) = obj["viaSwift"] { #expect(v == true) } else { Issue.record("viaSwift") }
    } else {
        Issue.record("not an object")
    }
}
