import Foundation
import Testing
import NativeAgentCore
import PersistenceCore
@testable import MacControl

private func operationTestRoot() throws -> URL {
    let root = FileManager.default.temporaryDirectory
        .appendingPathComponent("maccontrol-operation-tests-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    return root
}

private func operationDigest(
    action: String,
    body: [String: JSONValue] = [:]
) throws -> String {
    try MacControlOperationStore.requestDigest(action: action, body: body)
}

private actor _SuspendingProcessAdapter: ProcessAdapter {
    func run(executable: String, arguments: [String], timeoutSeconds: Int) async throws -> ProcessRunResult {
        try await Task.sleep(nanoseconds: 30_000_000_000)
        return ProcessRunResult(exitCode: 0, stdout: "late", stderr: "")
    }
}

private actor _CancellationIgnoringNotificationAdapter: NotificationCenterAdapter {
    func postNotification(title: String, message: String, soundName: String?) async throws {
        do { try await Task.sleep(nanoseconds: 100_000_000) }
        catch { /* Simulate an effect already handed to an uncancellable API. */ }
    }
}

private actor _UncancellableNotificationAdapter: NotificationCenterAdapter {
    private let delay: TimeInterval
    private(set) var calls = 0

    init(delay: TimeInterval) {
        self.delay = delay
    }

    func postNotification(title: String, message: String, soundName: String?) async throws {
        calls += 1
        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            DispatchQueue.global().asyncAfter(deadline: .now() + delay) {
                continuation.resume()
            }
        }
    }
}

@Test func operationStoreRejectsInvalidIdentityAndMismatchedReplay() async throws {
    let root = try operationTestRoot()
    defer { try? FileManager.default.removeItem(at: root) }
    let store = MacControlOperationStore(dataRoot: root)

    await #expect(throws: MacControlOperationStoreError.invalidOperationId) {
        try await store.begin(
            operationId: "bad id",
            action: "shell",
            requestDigest: operationDigest(action: "shell")
        )
    }
    _ = try await store.begin(
        operationId: "op-1",
        action: "shell",
        requestDigest: operationDigest(action: "shell")
    )
    await #expect(throws: MacControlOperationStoreError.actionMismatch) {
        try await store.begin(
            operationId: "op-1",
            action: "notify",
            requestDigest: operationDigest(action: "notify")
        )
    }
    await #expect(throws: MacControlOperationStoreError.requestMismatch) {
        try await store.begin(
            operationId: "op-1",
            action: "shell",
            requestDigest: operationDigest(
                action: "shell",
                body: ["command": .string("different")]
            )
        )
    }
}

@Test func operationStoreCASAndTerminalReplayAreDurable() async throws {
    let root = try operationTestRoot()
    defer { try? FileManager.default.removeItem(at: root) }
    let store = MacControlOperationStore(dataRoot: root)
    let digest = try operationDigest(action: "shell")
    let first = try await store.begin(
        operationId: "op-cas",
        action: "shell",
        requestDigest: digest,
        deadlineSeconds: 12
    )
    guard case .accepted = first else {
        Issue.record("first begin must accept")
        return
    }
    let duplicate = try await store.begin(
        operationId: "op-cas",
        action: "shell",
        requestDigest: digest,
        deadlineSeconds: 12
    )
    guard case .duplicateActive = duplicate else {
        Issue.record("active duplicate must not execute")
        return
    }
    _ = try await store.transition(operationId: "op-cas", to: .started)
    _ = try await store.transition(
        operationId: "op-cas",
        to: .completed,
        verification: .unverified,
        outcomeCode: "exit_0"
    )

    let restarted = MacControlOperationStore(dataRoot: root)
    let replay = try await restarted.begin(
        operationId: "op-cas",
        action: "shell",
        requestDigest: digest
    )
    guard case .replay(let record) = replay else {
        Issue.record("terminal identity must replay after restart")
        return
    }
    #expect(record.state == .completed)
    #expect(record.verification == .unverified)
    let read = try await restarted.motorActionReadModel(actionId: "op-cas")
    #expect(read?.domain == "mac_control")
    #expect(read?.phase == .succeeded)
    #expect(read?.actionIdentity == CausalTransitionEvidence.opaqueIdentity("op-cas"))
    #expect(read?.expectedNextEvidence == nil)
    // A terminal replay retains its historical deadline in the canonical
    // operation record, but it must not advertise live deadline work through
    // the motor read model after the effect has settled.
    #expect(read?.deadline == nil)
}

@Test func operationStoreFailsClosedOnCorruption() async throws {
    let root = try operationTestRoot()
    defer { try? FileManager.default.removeItem(at: root) }
    let directory = root.appendingPathComponent("mac_control", isDirectory: true)
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    try Data("not-json".utf8).write(to: directory.appendingPathComponent("operations.json"))
    let store = MacControlOperationStore(dataRoot: root)
    await #expect(throws: MacControlOperationStoreError.corruptStore) {
        try await store.begin(
            operationId: "op-corrupt",
            action: "shell",
            requestDigest: operationDigest(action: "shell")
        )
    }
}

@Test func operationStoreRecoveryTerminalizesInterruptedWork() async throws {
    let root = try operationTestRoot()
    defer { try? FileManager.default.removeItem(at: root) }
    let store = MacControlOperationStore(dataRoot: root)
    _ = try await store.begin(
        operationId: "op-restart",
        action: "shell",
        requestDigest: operationDigest(action: "shell")
    )
    _ = try await store.transition(operationId: "op-restart", to: .started)
    _ = try await store.begin(
        operationId: "op-accepted-only",
        action: "shell",
        requestDigest: operationDigest(action: "shell", body: [
            "operationId": .string("op-accepted-only"),
        ])
    )
    #expect(try await store.recoverInterruptedOperations() == 2)
    let record = try await store.record(operationId: "op-restart")
    #expect(record?.state == .outcomeUnknown)
    #expect(record?.verification == .unknown)
    #expect(record?.expectedNextEvidence?.contains("do not retry automatically") == true)
    #expect(try await store.motorActionReadModel(actionId: "op-restart")?.phase == .waitingExternal)
    #expect(try await store.motorActionReadModel(actionId: "op-restart")?.deadline == nil)
    #expect(record?.outcomeCode == "restart_interrupted")

    let accepted = try await store.record(operationId: "op-accepted-only")
    #expect(accepted?.state == .failed)
    #expect(accepted?.verification == .failed)
}

@Test func nativeClientTerminalReplayDoesNotRepeatSideEffect() async throws {
    let root = try operationTestRoot()
    defer { try? FileManager.default.removeItem(at: root) }
    let notification = _MockNotificationCenter()
    let store = MacControlOperationStore(dataRoot: root)
    let client = SwiftNativeMacControl(
        notificationCenterAdapter: notification,
        operationStore: store
    )
    let body: [String: JSONValue] = [
        "operationId": .string("notify-once"),
        "title": .string("one"),
        "message": .string("only once"),
    ]
    let first = try await client.dispatch(action: "notify", body: body)
    let replay = try await client.dispatch(action: "notify", body: body)
    #expect(first.operationState == .completed)
    #expect(first.verification == .unverified)
    #expect(replay.operationState == .completed)
    #expect(await notification.calls.count == 1)
}

@Test func operationIdentityCannotReplayAChangedPayload() async throws {
    let root = try operationTestRoot()
    defer { try? FileManager.default.removeItem(at: root) }
    let notification = _MockNotificationCenter()
    let store = MacControlOperationStore(dataRoot: root)
    let client = SwiftNativeMacControl(
        notificationCenterAdapter: notification,
        operationStore: store
    )
    _ = try await client.dispatch(action: "notify", body: [
        "operationId": .string("notify-bound-request"),
        "title": .string("same action"),
        "message": .string("first payload"),
    ])
    let persisted = try String(
        contentsOf: root
            .appendingPathComponent("mac_control", isDirectory: true)
            .appendingPathComponent("operations.json"),
        encoding: .utf8
    )
    #expect(persisted.contains("first payload") == false)
    #expect(persisted.contains("same action") == false)

    await #expect(throws: MacControlError.self) {
        try await client.dispatch(action: "notify", body: [
            "operationId": .string("notify-bound-request"),
            "title": .string("same action"),
            "message": .string("changed payload"),
        ])
    }
    #expect(await notification.calls.count == 1)
}

@Test func processTimeoutIsNotReportedAsOrdinaryExitFailure() async throws {
    let root = try operationTestRoot()
    defer { try? FileManager.default.removeItem(at: root) }
    let process = _MockProcessAdapter()
    await process.queue(ProcessRunResult(exitCode: 15, stdout: "", stderr: "", timedOut: true))
    let store = MacControlOperationStore(dataRoot: root)
    let client = SwiftNativeMacControl(processAdapter: process, operationStore: store)
    let result = try await client.dispatch(action: "shell", body: [
        "operationId": .string("timeout-op"),
        "command": .string("true"),
        "timeout": .int(1),
    ])
    #expect(result.ok == false)
    #expect(result.operationState == .timedOut)
    #expect(result.error == "shell timed out")
    let read = try await client.motorActionReadModel(actionId: "timeout-op")
    #expect(read?.phase == .expired)
}

@Test func cancellationAcknowledgesOnlyAfterInFlightTaskStops() async throws {
    let root = try operationTestRoot()
    defer { try? FileManager.default.removeItem(at: root) }
    let store = MacControlOperationStore(dataRoot: root)
    let runner = SwiftNativeMacControl(
        processAdapter: _SuspendingProcessAdapter(),
        operationStore: store
    )
    let canceller = SwiftNativeMacControl(operationStore: store)
    let dispatch = Task {
        try await runner.dispatch(action: "shell", body: [
            "operationId": .string("cancel-op"),
            "command": .string("true"),
        ])
    }

    for _ in 0..<100 {
        if try await store.record(operationId: "cancel-op")?.state == .started { break }
        try await Task.sleep(nanoseconds: 5_000_000)
    }
    let cancellation = try await canceller.cancel(operationId: "cancel-op")
    #expect(cancellation.acknowledged == true)
    #expect(cancellation.state == .cancelAcknowledged)
    let result = try await dispatch.value
    #expect(result.operationState == .cancelAcknowledged)
    #expect(result.ok == false)
}

@Test func lateSuccessfulEffectIsNotRelabeledAsCancelled() async throws {
    let root = try operationTestRoot()
    defer { try? FileManager.default.removeItem(at: root) }
    let store = MacControlOperationStore(dataRoot: root)
    let runner = SwiftNativeMacControl(
        notificationCenterAdapter: _CancellationIgnoringNotificationAdapter(),
        operationStore: store
    )
    let canceller = SwiftNativeMacControl(operationStore: store)
    let dispatch = Task {
        try await runner.dispatch(action: "notify", body: [
            "operationId": .string("late-success"),
            "title": .string("already handed off"),
            "message": .string("cannot retract"),
        ])
    }
    for _ in 0..<100 {
        if try await store.record(operationId: "late-success")?.state == .started { break }
        try await Task.sleep(nanoseconds: 5_000_000)
    }
    let cancellation = try await canceller.cancel(operationId: "late-success")
    let result = try await dispatch.value
    #expect(cancellation.acknowledged == false)
    #expect(cancellation.state == .completed)
    #expect(result.operationState == .completed)
    #expect(result.verification == .unverified)
}

@Test func nonCooperativeCancellationBecomesUnknownAndCannotReplay() async throws {
    let root = try operationTestRoot()
    defer { try? FileManager.default.removeItem(at: root) }
    let notification = _UncancellableNotificationAdapter(delay: 0.8)
    let store = MacControlOperationStore(dataRoot: root)
    let runner = SwiftNativeMacControl(
        notificationCenterAdapter: notification,
        operationStore: store
    )
    let canceller = SwiftNativeMacControl(operationStore: store)
    let body: [String: JSONValue] = [
        "operationId": .string("unknown-cancel-effect"),
        "title": .string("uncancellable"),
        "message": .string("effect may already be in flight"),
    ]
    let dispatch = Task { try await runner.dispatch(action: "notify", body: body) }
    for _ in 0..<100 {
        if try await store.record(operationId: "unknown-cancel-effect")?.state == .started { break }
        try await Task.sleep(nanoseconds: 5_000_000)
    }

    let cancellation = try await canceller.cancel(operationId: "unknown-cancel-effect")
    let result = try await dispatch.value
    #expect(cancellation.acknowledged == false)
    #expect(cancellation.state == .outcomeUnknown)
    #expect(result.operationState == .outcomeUnknown)
    #expect(result.verification == .unknown)
    #expect(result.httpStatus == 409)

    let replay = try await runner.dispatch(action: "notify", body: body)
    #expect(replay.operationState == .outcomeUnknown)
    #expect(replay.httpStatus == 409)
    #expect(await notification.calls == 1)
}

@Test func nonCooperativeDeadlineBecomesUnknownRatherThanRetryableTimeout() async throws {
    let root = try operationTestRoot()
    defer { try? FileManager.default.removeItem(at: root) }
    let notification = _UncancellableNotificationAdapter(delay: 2.2)
    let client = SwiftNativeMacControl(
        notificationCenterAdapter: notification,
        operationStore: MacControlOperationStore(dataRoot: root)
    )
    let body: [String: JSONValue] = [
        "operationId": .string("unknown-deadline-effect"),
        "title": .string("uncancellable"),
        "message": .string("deadline crossed after handoff"),
        "timeout": .int(1),
    ]

    let result = try await client.dispatch(action: "notify", body: body)
    #expect(result.operationState == .outcomeUnknown)
    #expect(result.verification == .unknown)
    #expect(result.httpStatus == 409)
    if case .object(let output) = result.output {
        #expect(output["retryable"] == .bool(false))
    } else {
        Issue.record("unknown outcome should be structured")
    }

    let replay = try await client.dispatch(action: "notify", body: body)
    #expect(replay.operationState == .outcomeUnknown)
    #expect(await notification.calls == 1)
}

@Test func fileMutationVerificationUsesExactReadback() async throws {
    let root = try operationTestRoot()
    defer { try? FileManager.default.removeItem(at: root) }
    let files = _MockFileManagerAdapter()
    let client = SwiftNativeMacControl(
        fileManagerAdapter: files,
        operationStore: MacControlOperationStore(dataRoot: root)
    )
    let result = try await client.dispatch(action: "file/write", body: [
        "operationId": .string("write-verified"),
        "path": .string("/tmp/swiftmc/verified.txt"),
        "content": .string("exact"),
    ])
    #expect(result.operationState == .completed)
    #expect(result.verification == .satisfied)
}

@Test func appFocusVerificationRequiresSeparateFrontmostObservation() async throws {
    let root = try operationTestRoot()
    defer { try? FileManager.default.removeItem(at: root) }
    let verified = SwiftNativeMacControl(
        appControlAdapter: _MockAppControlAdapter(),
        operationStore: MacControlOperationStore(dataRoot: root)
    )
    let verifiedResult = try await verified.dispatch(action: "focus_app", body: [
        "operationId": .string("focus-verified"),
        "app": .string("Safari"),
    ])
    #expect(verifiedResult.verification == .satisfied)

    let unobserved = SwiftNativeMacControl(
        appControlAdapter: _CommandOnlyAppControlAdapter(),
        operationStore: MacControlOperationStore(dataRoot: root)
    )
    let unobservedResult = try await unobserved.dispatch(action: "focus_app", body: [
        "operationId": .string("focus-unobserved"),
        "app": .string("Safari"),
    ])
    #expect(unobservedResult.verification == .unverified)
}

private actor _CommandOnlyAppControlAdapter: AppControlAdapter {
    func focusApp(named name: String) async throws -> AppControlRunResult {
        AppControlRunResult(
            requestedName: name,
            matchedName: name,
            bundleIdentifier: "example.\(name)",
            processIdentifier: 42,
            launched: false,
            activated: true,
            terminated: false
        )
    }

    func quitApp(named name: String) async throws -> AppControlRunResult {
        AppControlRunResult(
            requestedName: name,
            matchedName: name,
            bundleIdentifier: "example.\(name)",
            processIdentifier: 42,
            launched: false,
            activated: false,
            terminated: true
        )
    }
}
