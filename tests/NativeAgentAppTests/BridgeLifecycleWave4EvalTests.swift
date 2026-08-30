import Foundation
import NativeAgentShared
import NativeAgentSharedTestSupport
import Testing
@testable import NativeAgentApp

private func bridgeWave4Root(_ label: String) throws -> URL {
    let root = FileManager.default.temporaryDirectory
        .appendingPathComponent("NativeAgentBridgeWave4-\(label)-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    return root
}

private actor BridgeWave4Mailbox {
    private var accepted: [String] = []
    private var acceptsMessages = true

    func setAcceptsMessages(_ value: Bool) { acceptsMessages = value }
    func handle(_ message: BridgeMessage) -> Bool {
        guard acceptsMessages else { return false }
        accepted.append(message.id)
        return true
    }
    func ids() -> [String] { accepted }
}

private final class BridgeWave4ThrowOnceScan: @unchecked Sendable {
    private let lock = NSLock()
    private let started = DispatchSemaphore(value: 0)
    private let resume = DispatchSemaphore(value: 0)
    private var invocations = 0

    func invoke() throws {
        lock.lock()
        invocations += 1
        let shouldThrow = invocations == 1
        lock.unlock()
        guard shouldThrow else { return }
        started.signal()
        resume.wait()
        throw NSError(domain: "BridgeWave4", code: 1, userInfo: [NSLocalizedDescriptionKey: "injected scan failure"])
    }

    func waitForFirstInvocation() -> Bool {
        started.wait(timeout: .now() + 1) == .success
    }

    func releaseFirstInvocation() { resume.signal() }

    func callCount() -> Int {
        lock.lock()
        defer { lock.unlock() }
        return invocations
    }
}

private func bridgeWave4Eventually(
    _ condition: @escaping @Sendable () async -> Bool
) async -> Bool {
    for _ in 0..<100 {
        if await condition() { return true }
        try? await Task.sleep(for: .milliseconds(10))
    }
    return await condition()
}

@Suite("app.bridges lifecycle wave 4", .serialized)
struct BridgeLifecycleWave4EvalTests {
    // app.bridges / icloud.handleIncomingFromTransport
    @Test("CloudKit input returns true only for delivered or terminally rejected work, with durable rejection truth")
    @MainActor
    func incomingDispositionAndDurableRejection() async throws {
        let root = try bridgeWave4Root("incoming")
        defer { try? FileManager.default.removeItem(at: root) }
        let defaultsName = "NativeAgentBridgeWave4.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: defaultsName))
        defer { defaults.removePersistentDomain(forName: defaultsName) }
        let cloud = MockDeviceCloud()
        let mac = MockDeviceSyncTransport(role: .mac, cloud: cloud)
        let phone = MockDeviceSyncTransport(role: .ios, cloud: cloud)
        let secret = Data(repeating: 31, count: 32)
        let mailbox = BridgeWave4Mailbox()
        let bridge = iCloudBridge(
            testDeviceTransport: mac,
            testPairingSecret: secret,
            testDataRoot: root,
            testCKSeenIDDefaults: defaults
        )
        bridge.observeIncomingMessages { message in await mailbox.handle(message) }
        #expect(await bridgeWave4Eventually { await MainActor.run { bridge.incomingObserverInstalled } })

        let delivered = try BridgeMessage.make(id: "wave4-delivered", sender: "ios", text: "ok").signed(with: secret)
        try await phone.send(delivered)
        #expect(await mac.drainIncoming() == 1)
        #expect(await mailbox.ids() == [delivered.id])
        #expect(bridge.syncStatus == "Received message from iOS (CloudKit)")

        await mailbox.setAcceptsMessages(false)
        bridge.observeIncomingMessages { message in await mailbox.handle(message) }
        #expect(!bridge.incomingObserverInstalled)
        #expect(await bridgeWave4Eventually { await MainActor.run { bridge.incomingObserverInstalled } })
        let transient = try BridgeMessage.make(id: "wave4-transient", sender: "ios", text: "retry").signed(with: secret)
        try await phone.send(transient)
        #expect(await mac.drainIncoming() == 0)
        #expect(bridge.syncStatus == "iPhone message waiting — Mac runtime unavailable")

        let rejected = BridgeMessage.make(id: "wave4-terminal-reject", sender: "ios", text: "unsigned")
        try await phone.send(rejected)
        // The transient record remains ahead of the permanent rejection, so make
        // it deliverable before proving that terminal rejection advances exactly once.
        await mailbox.setAcceptsMessages(true)
        #expect(await mac.drainIncoming() == 2)
        #expect(bridge.syncStatus == "Rejected iPhone message (CloudKit): signature_invalid")
        let rejectionData = try Data(contentsOf: root.appendingPathComponent("icloud/incoming_rejections.jsonl"))
        let rejection = try #require(JSONSerialization.jsonObject(with: rejectionData) as? [String: Any])
        #expect(rejection["messageId"] as? String == rejected.id)
        #expect(rejection["status"] as? String == "permanently_rejected")
        #expect(rejection["reason"] as? String == "signature_invalid")
        bridge.tearDown()

        // A new transport begins from cursor zero. Registration must finish
        // before the replay assertion; the persisted terminal row is consumed
        // without reaching the replacement runtime.
        let restartedMac = MockDeviceSyncTransport(role: .mac, cloud: cloud)
        let restarted = iCloudBridge(
            testDeviceTransport: restartedMac,
            testPairingSecret: secret,
            testDataRoot: root,
            testCKSeenIDDefaults: defaults
        )
        let restartedMailbox = BridgeWave4Mailbox()
        restarted.observeIncomingMessages { message in await restartedMailbox.handle(message) }
        #expect(await bridgeWave4Eventually { await MainActor.run { restarted.incomingObserverInstalled } })
        _ = await restartedMac.drainIncoming()
        #expect(await restartedMailbox.ids().isEmpty)
        restarted.tearDown()
    }

    // app.bridges / icloud.checkIosOutbox
    @Test("a thrown outbox scan clears its lifecycle flags and runs one queued scan")
    @MainActor
    func thrownOutboxScanCleansUpAndReplaysQueuedDemand() async throws {
        let root = try bridgeWave4Root("scan-failure")
        defer { try? FileManager.default.removeItem(at: root) }
        let outbox = root.appendingPathComponent(NativeAgentICloudBridgeConstants.DriveFolder.outboxIos, isDirectory: true)
        try FileManager.default.createDirectory(at: outbox, withIntermediateDirectories: true)
        let fault = BridgeWave4ThrowOnceScan()
        let bridge = iCloudBridge(
            testDriveURL: root,
            testPairingSecret: Data(repeating: 32, count: 32),
            testDataRoot: root,
            testOutboxScanHook: { try fault.invoke() }
        )
        let mailbox = BridgeWave4Mailbox()
        bridge.observeIncomingMessages { message in await mailbox.handle(message) }
        #expect(fault.waitForFirstInvocation())
        #expect(bridge.outboxScanState.inFlight)
        bridge.checkIosOutbox()
        #expect(bridge.outboxScanState.queued)
        fault.releaseFirstInvocation()

        #expect(await bridgeWave4Eventually {
            await MainActor.run {
                !bridge.outboxScanState.inFlight
                    && !bridge.outboxScanState.queued
                    && fault.callCount() == 2
            }
        })
        #expect(bridge.syncStatus.contains("retained claims will retry"))
        bridge.tearDown()
    }

    // app.bridges / icloud.observeIncomingMessages
    @Test("teardown invalidates a registered transport callback until a replacement bridge installs its own observer")
    @MainActor
    func teardownGatesInstalledObserverCallback() async throws {
        let root = try bridgeWave4Root("observer-teardown")
        defer { try? FileManager.default.removeItem(at: root) }
        let cloud = MockDeviceCloud()
        let mac = MockDeviceSyncTransport(role: .mac, cloud: cloud)
        let phone = MockDeviceSyncTransport(role: .ios, cloud: cloud)
        let secret = Data(repeating: 33, count: 32)
        let defaultsName = "NativeAgentBridgeWave4.observer-teardown.\(UUID().uuidString)"
        let seenDefaults = try #require(UserDefaults(suiteName: defaultsName))
        seenDefaults.removePersistentDomain(forName: defaultsName)
        defer { seenDefaults.removePersistentDomain(forName: defaultsName) }
        let first = iCloudBridge(
            testDeviceTransport: mac,
            testPairingSecret: secret,
            testDataRoot: root,
            testCKSeenIDDefaults: seenDefaults
        )
        let firstMailbox = BridgeWave4Mailbox()
        first.observeIncomingMessages { message in await firstMailbox.handle(message) }
        #expect(await bridgeWave4Eventually { await MainActor.run { first.incomingObserverInstalled } })
        first.tearDown()
        #expect(!first.incomingObserverInstalled)

        let held = try BridgeMessage.make(id: "wave4-held", sender: "ios", text: "resume").signed(with: secret)
        try await phone.send(held)
        #expect(await mac.drainIncoming() == 0)
        #expect(await firstMailbox.ids().isEmpty)

        let replacement = iCloudBridge(
            testDeviceTransport: mac,
            testPairingSecret: secret,
            testDataRoot: root,
            testCKSeenIDDefaults: seenDefaults
        )
        let replacementMailbox = BridgeWave4Mailbox()
        replacement.observeIncomingMessages { message in await replacementMailbox.handle(message) }
        #expect(await bridgeWave4Eventually { await MainActor.run { replacement.incomingObserverInstalled } })
        _ = await mac.drainIncoming()
        #expect(await replacementMailbox.ids() == [held.id])
        replacement.tearDown()
    }

    // app.bridges / icloud.observeIncomingMessages
    @Test("launch keeps iCloud setup and the sole Swift-runtime forwarder in one MainActor task")
    func launchTaskContainsTheOnlyIncomingForwarder() throws {
        let source = try AppSourceScraping.appSource("AppDelegate+Launch.swift")
        let call = "iCloudBridge.shared.observeIncomingMessages"
        #expect(AppSourceScraping.occurrences(of: call, in: source) == 1)
        let task = "Task { @MainActor in"
        guard let callStart = source.range(of: call)?.lowerBound,
              let taskStart = source.range(of: task, options: .backwards, range: source.startIndex..<callStart)?.lowerBound,
              let opening = source[taskStart...].firstIndex(of: "{"),
              let taskEnd = AppSourceScraping.balancedEnd(in: source, startingAt: opening, opening: "{", closing: "}")
        else {
            Issue.record("iCloud launch task is not structurally balanced")
            return
        }
        let body = String(source[taskStart...taskEnd])
        #expect(body.contains("iCloudBridge.shared.setup()"))
        #expect(body.contains(call))
        #expect(body.contains("await AppDelegate.forwardToSwiftRuntime(msg)"))
    }
}
