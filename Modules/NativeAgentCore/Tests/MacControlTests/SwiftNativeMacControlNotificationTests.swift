import Foundation
import Testing
import NativeAgentCore
import PersistenceCore
@testable import MacControl
#if canImport(Darwin)
import Darwin
#endif

// MARK: - notify (NATIVE)

@Test func notifyHappyPath() async throws {
    let mc = _MockNotificationCenter()
    let client = SwiftNativeMacControl(
        http: _MockHTTPClient(),
        notificationCenterAdapter: mc
    )
    let r = try await client.dispatch(action: "notify", body: [
        "title": .string("NativeAgent"),
        "message": .string("Hello"),
        "sound": .string("Ping"),
    ])
    #expect(r.ok == true)
    #expect(r.viaSwift == true)
    #expect(r.action == "notify")
    let calls = await mc.calls
    #expect(calls.count == 1)
    #expect(calls.first?.title == "NativeAgent")
    #expect(calls.first?.message == "Hello")
    #expect(calls.first?.soundName == "Ping")
    guard case .object(let output) = r.output,
          case .object(let receipt) = output["receipt"] else {
        Issue.record("notify response must carry a submission receipt")
        return
    }
    #expect(receipt["submission"] == .string("accepted_for_delivery"))
    #expect(receipt["authorization"] == .string("adapter_managed"))
    #expect(receipt["delivery_observed"] == .bool(false),
            "adapter acceptance must not claim a user-visible delivery")
}

@Test func notifyMissingBothFieldsThrows() async throws {
    let client = SwiftNativeMacControl(
        http: _MockHTTPClient(),
        notificationCenterAdapter: _MockNotificationCenter()
    )
    do {
        _ = try await client.dispatch(action: "notify", body: [:])
        Issue.record("expected missingField")
    } catch MacControlError.missingField {
        // expected
    } catch {
        Issue.record("wrong error: \(error)")
    }
}

@Test func notifyAdapterFailureSurfacedAsError() async throws {
    let mc = _MockNotificationCenter()
    await mc.setShouldThrow(NSError(domain: "test", code: -1, userInfo: [NSLocalizedDescriptionKey: "denied"]))
    let client = SwiftNativeMacControl(
        http: _MockHTTPClient(),
        notificationCenterAdapter: mc
    )
    let r = try await client.dispatch(action: "notify", body: [
        "title": .string("x"), "message": .string("y"),
    ])
    #expect(r.ok == false)
    #expect(r.error?.contains("notify failed") == true)
    if case .object(let output) = r.output {
        #expect(output["receipt"] == nil, "a failed post must not manufacture an acceptance receipt")
    } else {
        Issue.record("notify failure must retain an object result")
    }
}

// MARK: - LEDGER: maccontrol.action.notify

@Test func notifyBehaviorEval_authorizationSubmissionReceiptAndFailureStayDistinct() async throws {
    var deniedPolicy = _permissiveMacPolicy()
    deniedPolicy.categoryAllowed["notifications_allowed"] = false
    let deniedAdapter = _MockNotificationCenter()
    let deniedClient = SwiftNativeMacControl(
        http: _MockHTTPClient(),
        notificationCenterAdapter: deniedAdapter,
        policyProvider: _StubPolicyProvider(policy: deniedPolicy)
    )
    let refused = try await deniedClient.dispatch(action: "notify", body: [
        "title": .string("blocked"), "message": .string("must not post"),
    ])
    #expect(refused.ok == false)
    #expect(refused.httpStatus == 403)
    #expect(await deniedAdapter.calls.isEmpty,
            "authorization refusal must reach the adapter with no post attempt")

    let root = FileManager.default.temporaryDirectory
        .appendingPathComponent("mac-notify-eval-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: root) }
    let acceptedAdapter = _MockNotificationCenter()
    await acceptedAdapter.setReceipt(NotificationPostReceipt(
        authorization: .authorized,
        requestIdentifier: "notification-request-42"
    ))
    let store = MacControlOperationStore(dataRoot: root)
    let acceptedClient = SwiftNativeMacControl(
        http: _MockHTTPClient(),
        notificationCenterAdapter: acceptedAdapter,
        policyProvider: _StubPolicyProvider(policy: _permissiveMacPolicy()),
        operationStore: store
    )
    let accepted = try await acceptedClient.dispatch(action: "notify", body: [
        "operationId": .string("notify-receipt"),
        "title": .string("received by API"),
        "message": .string("not evidence of user delivery"),
    ])
    #expect(accepted.ok)
    #expect(accepted.operationState == .completed)
    #expect(accepted.verification == .unverified)
    guard case .object(let output) = accepted.output,
          case .object(let receipt) = output["receipt"] else {
        Issue.record("accepted notification must expose its adapter receipt")
        return
    }
    #expect(receipt["submission"] == .string("accepted_for_delivery"))
    #expect(receipt["authorization"] == .string("authorized"))
    #expect(receipt["request_id"] == .string("notification-request-42"))
    #expect(receipt["delivery_observed"] == .bool(false))
    let readModel = try await store.motorActionReadModel(actionId: "notify-receipt")
    #expect(readModel?.verification == .unverified)
    #expect(readModel?.expectedNextEvidence == "Separate observation of intended effect")

    let failingAdapter = _MockNotificationCenter()
    await failingAdapter.setShouldThrow(MacControlError.notificationFailed("authorization service unavailable"))
    let failingClient = SwiftNativeMacControl(
        http: _MockHTTPClient(),
        notificationCenterAdapter: failingAdapter,
        policyProvider: _StubPolicyProvider(policy: _permissiveMacPolicy())
    )
    let failed = try await failingClient.dispatch(action: "notify", body: [
        "title": .string("unavailable"), "message": .string("must fail honestly"),
    ])
    #expect(failed.ok == false)
    #expect(failed.error?.contains("notify failed") == true)
    if case .object(let failedOutput) = failed.output {
        #expect(failedOutput["receipt"] == nil)
    }
}
