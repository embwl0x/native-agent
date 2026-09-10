import Foundation
import NativeAgentShared
import NativeAgentSharedTestSupport
import Testing
import Synchronization
@testable import NativeAgentApp

private actor BridgeBehaviorTransport: DeviceSyncTransport {
    nonisolated let role: NADeviceRole = .mac
    private var failWrites = true
    private var writes: [String: Int] = [:]

    func send(_ message: BridgeMessage) async throws {}
    func observeIncoming(_ onMessage: @escaping @Sendable (BridgeMessage) async -> Bool) async {}
    func publishPairing(secret: Data) async throws {}
    func observePairing(onChange: @escaping @Sendable (Data) async -> Bool) async {}
    func observeStatus(key: String, onChange: @escaping @Sendable (String) async -> Void) async {}
    func setStatus(key: String, value: String) async throws {
        writes[key, default: 0] += 1
        if failWrites { throw DeviceSyncError.transient(message: "injected") }
    }
    func allowWrites() { failWrites = false }
    func writeCount(_ key: String) -> Int { writes[key, default: 0] }
}

private actor ForwardedMessages {
    private var ids: [String] = []
    func append(_ id: String) { ids.append(id) }
    func all() -> [String] { ids }
}

/// Test-only pull transport whose observer registration has an explicit await
/// point.  It models the active transport authority without timing guesses.
private actor BridgeBehaviorInboundTransport: DeviceSyncTransport {
    nonisolated let role: NADeviceRole = .mac
    private var incomingHandler: (@Sendable (BridgeMessage) async -> Bool)?
    private var queued: [BridgeMessage] = []
    private var registrationWaiters: [CheckedContinuation<Void, Never>] = []

    func send(_ message: BridgeMessage) async throws {
        try Task.checkCancellation()
    }

    func observeIncoming(
        _ onMessage: @escaping @Sendable (BridgeMessage) async -> Bool
    ) async {
        incomingHandler = onMessage
        let waiters = registrationWaiters
        registrationWaiters.removeAll()
        for waiter in waiters { waiter.resume() }
    }

    func waitForIncomingObserver() async {
        guard incomingHandler == nil else { return }
        await withCheckedContinuation { registrationWaiters.append($0) }
    }

    func enqueue(_ message: BridgeMessage) {
        queued.append(message)
    }

    func drainIncoming() async -> Int {
        guard let incomingHandler else { return 0 }
        var delivered = 0
        while let next = queued.first {
            guard await incomingHandler(next) else { break }
            queued.removeFirst()
            delivered += 1
        }
        return delivered
    }

    func publishPairing(secret: Data) async throws {}
    func observePairing(onChange: @escaping @Sendable (Data) async -> Bool) async {}
    func observeStatus(key: String, onChange: @escaping @Sendable (String) async -> Void) async {}
    func setStatus(key: String, value: String) async throws {}
}

private func bridgeEvalRoot(_ label: String) throws -> URL {
    let url = FileManager.default.temporaryDirectory
        .appendingPathComponent("NativeAgentBridgeBehaviorWave2-\(label)-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
    return url
}

@Suite("app.bridges behavior wave 2", .serialized)
struct BridgeBehaviorWave2EvalTests {
    @Test("timer-driven chat survives delta rearming and publishes its final reply", .timeLimit(.minutes(1)))
    @MainActor
    func timerDrivenChatDoesNotCancelItsFinalReply() async throws {
        let root = try bridgeEvalRoot("timer-final")
        defer { try? FileManager.default.removeItem(at: root) }
        let defaultsName = "NativeAgentBridgeTimer.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: defaultsName))
        defer { defaults.removePersistentDomain(forName: defaultsName) }
        let transport = BridgeBehaviorInboundTransport()
        let secret = Data(repeating: 9, count: 32)
        let bridge = iCloudBridge(testDeviceTransport: transport,
                                  testPairingSecret: secret, testDataRoot: root,
                                  testCKSeenIDDefaults: defaults)
        defer { bridge.tearDown() }
        let result = AsyncStream<Bool>.makeStream()
        bridge.observeIncomingMessages { message in
            // Production streams from a detached consumer, then sends the
            // terminal reply on the original timer-driven receive task.
            let consumer = Task.detached {
                try await bridge.sendChatMessage(text: "partial", correlationID: message.id,
                                                 metadata: ["kind": "text_delta"])
            }
            do {
                _ = try await consumer.value
                try Task.checkCancellation()
                _ = try await bridge.sendChatMessage(text: "complete", correlationID: message.id)
                result.continuation.yield(true)
            } catch {
                result.continuation.yield(false)
            }
            result.continuation.finish()
            return true
        }
        await transport.waitForIncomingObserver()
        await transport.enqueue(try BridgeMessage.make(id: "timer-turn", sender: "ios", text: "hello").signed(with: secret))
        bridge.startDeviceDrainFallback(every: 0)
        var iterator = result.stream.makeAsyncIterator()
        #expect(await iterator.next() == true)
    }

    // app.bridges / icloud.observeIncomingMessages
    @Test("launch installs exactly one iCloud forwarder into the in-process Swift runtime")
    func iCloudLaunchForwarderTargetsSwiftRuntime() throws {
        let launch = try AppSourceScraping.appSource("AppDelegate+Launch.swift")
        let call = "iCloudBridge.shared.observeIncomingMessages"
        #expect(AppSourceScraping.occurrences(of: call, in: launch) == 1)
        guard let start = launch.range(of: call)?.lowerBound,
              let open = launch[start...].firstIndex(of: "{"),
              let end = AppSourceScraping.balancedEnd(in: launch, startingAt: open, opening: "{", closing: "}")
        else {
            Issue.record("the iCloud message forwarder is missing its closure")
            return
        }
        let closure = String(launch[start...end])
        #expect(closure.contains("await AppDelegate.forwardToSwiftRuntime(msg)"))
    }

    // app.bridges / bridge.macctl.auditFeed
    @Test("every terminal Mac-control class appends an identifiable audit row")
    func macControlAuditRecordsTerminalClasses() throws {
        let root = try bridgeEvalRoot("audit")
        defer { try? FileManager.default.removeItem(at: root) }
        MacControlBridge.appendExecAudit(argv: ["/bin/ls"], status: "completed", operationId: "op-completed", dataRoot: root)
        MacControlBridge.appendExecAudit(argv: ["/bin/ls"], status: "blocked", reason: "policy", operationId: "op-blocked", dataRoot: root)
        MacControlBridge.appendExecAudit(argv: ["/bin/ls"], status: "validation_rejected", reason: "argv", operationId: "op-invalid", dataRoot: root)

        let data = try Data(contentsOf: root.appendingPathComponent("mac_control_bridge_audit.jsonl"))
        let rows = try String(decoding: data, as: UTF8.self).split(separator: "\n").map {
            try #require(JSONSerialization.jsonObject(with: Data($0.utf8)) as? [String: Any])
        }
        #expect(rows.map { $0["status"] as? String } == ["completed", "blocked", "validation_rejected"])
        #expect(rows.map { $0["operationId"] as? String } == ["op-completed", "op-blocked", "op-invalid"])
        #expect(rows[1]["reason"] as? String == "policy")
    }

    // app.bridges / icloud.ckSeenIDs
    @Test("CloudKit seen-id persistence is ordered, capped, and restart-safe")
    func cloudKitSeenIDsPersistOrderedAcrossRestart() {
        let suite = "NativeAgentBridgeBehaviorWave2.\(UUID().uuidString)"
        let defaults = try! #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let ids = (0...2_000).map { index in index == 0 ? "z-oldest" : "id-\(index)" }
        ICloudSeenIDDefaultsStore.save(ids, defaults: defaults, key: "seen", cap: 2_000)
        let restored = ICloudSeenIDDefaultsStore.load(defaults: defaults, key: "seen", cap: 2_000)

        #expect(restored.count == 2_000)
        #expect(restored.first == "id-1")
        #expect(restored.last == "id-2000")
        #expect(defaults.stringArray(forKey: "seen") == restored)

        defaults.set(["a", "b", "a", "c"], forKey: "duplicates")
        let normalized = ICloudSeenIDDefaultsStore.load(defaults: defaults, key: "duplicates", cap: 10)
        #expect(normalized == ["a", "b", "c"])
        #expect(defaults.stringArray(forKey: "duplicates") == normalized)
    }

    // app.bridges / icloud.publishProviderCatalogStatus
    @Test("failed provider catalog publication is retried instead of deduplicated away")
    func providerCatalogFailureRetainsPreviousCache() async {
        let transport = BridgeBehaviorTransport()
        let first = await ICloudBridgeStatusPublication.publish(
            key: "catalog", value: "v1", lastPublished: nil, transport: transport
        )
        #expect(!first.succeeded)
        #expect(first.retainedValue == nil)
        await transport.allowWrites()
        let retry = await ICloudBridgeStatusPublication.publish(
            key: "catalog", value: "v1", lastPublished: first.retainedValue, transport: transport
        )
        #expect(retry.succeeded)
        #expect(retry.retainedValue == "v1")
        let duplicate = await ICloudBridgeStatusPublication.publish(
            key: "catalog", value: "v1", lastPublished: retry.retainedValue, transport: transport
        )
        #expect(duplicate.succeeded)
        #expect(await transport.writeCount("catalog") == 2)
    }

    // app.bridges / icloud.handleIncomingFromTransport
    @Test("incoming CloudKit validation distinguishes tamper and stale messages from deliverable ones")
    func incomingCloudKitValidationIsFailClosed() throws {
        let secret = Data(repeating: 7, count: 32)
        let valid = try BridgeMessage.make(id: "valid", sender: "ios", text: "hello").signed(with: secret)
        #expect(ICloudIncomingMessageDisposition.classify(valid, secret: secret, now: valid.timestamp) == .deliver)

        var staleObject = try #require(JSONSerialization.jsonObject(with: JSONEncoder().encode(valid)) as? [String: Any])
        staleObject["id"] = "stale"
        staleObject["timestamp"] = Date(timeIntervalSinceNow: -25 * 60 * 60).timeIntervalSinceReferenceDate
        let staleUnsigned = try JSONDecoder().decode(BridgeMessage.self, from: JSONSerialization.data(withJSONObject: staleObject))
        let stale = try staleUnsigned.signed(with: secret)
        #expect(ICloudIncomingMessageDisposition.classify(stale, secret: secret, now: Date()) == .permanentlyRejected(reason: "stale_timestamp"))

        var object = try #require(JSONSerialization.jsonObject(with: JSONEncoder().encode(valid)) as? [String: Any])
        object["text"] = "tampered"
        let tampered = try JSONDecoder().decode(BridgeMessage.self, from: JSONSerialization.data(withJSONObject: object))
        #expect(ICloudIncomingMessageDisposition.classify(tampered, secret: secret, now: tampered.timestamp) == .permanentlyRejected(reason: "signature_invalid"))
    }

    // app.bridges / icloud.observeIncomingMessages
    @Test("CloudKit observer forwards one valid message and does not replay it on a second drain")
    @MainActor
    func cloudKitDrainVerifiesOffMainAndIsReplaySafe() async throws {
        let root = try bridgeEvalRoot("incoming")
        defer { try? FileManager.default.removeItem(at: root) }
        let defaultsName = "NativeAgentBridgeBehaviorWave2.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: defaultsName))
        defer { defaults.removePersistentDomain(forName: defaultsName) }
        let transport = BridgeBehaviorInboundTransport()
        let secret = Data(repeating: 8, count: 32)
        let bridge = iCloudBridge(
            testDeviceTransport: transport,
            testPairingSecret: secret,
            testDataRoot: root,
            testCKSeenIDDefaults: defaults
        )
        defer { bridge.tearDown() }
        let forwarded = ForwardedMessages()
        let verificationThreads = Mutex<[Bool]>([])
        bridge.testIncomingVerificationProbe = { isMain in
            verificationThreads.withLock { $0.append(isMain) }
        }
        bridge.observeIncomingMessages { message in
            await forwarded.append(message.id)
            return true
        }
        await transport.waitForIncomingObserver()
        let message = try BridgeMessage.make(id: "only-once", sender: "ios", text: "hello").signed(with: secret)
        await transport.enqueue(message)
        #expect(await bridge.drainDeviceTransport())
        #expect(verificationThreads.withLock { $0 } == [false])
        #expect(!(await bridge.drainDeviceTransport()))
        #expect(await forwarded.all() == ["only-once"])

        // A permanent reject advances the transport but never reaches the
        // runtime. A second drain exercises the no-replay side of that receipt.
        await transport.enqueue(BridgeMessage.make(id: "tampered-once", sender: "ios", text: "bad"))
        #expect(await bridge.drainDeviceTransport())
        #expect(!(await bridge.drainDeviceTransport()))
        #expect(await forwarded.all() == ["only-once"])
    }

    // app.bridges / icloud.checkIosOutbox
    @Test("Drive outbox scan forwards a signed message once and archives its durable source")
    @MainActor
    func driveOutboxScanClaimsAndArchivesSignedMessage() async throws {
        let docs = try bridgeEvalRoot("drive-outbox")
        defer { try? FileManager.default.removeItem(at: docs) }
        let outbox = docs.appendingPathComponent(NativeAgentICloudBridgeConstants.DriveFolder.outboxIos, isDirectory: true)
        try FileManager.default.createDirectory(at: outbox, withIntermediateDirectories: true)
        let secret = Data(repeating: 4, count: 32)
        let message = try BridgeMessage.make(id: "drive-once", sender: "ios", text: "from drive").signed(with: secret)
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        try encoder.encode(message).write(to: outbox.appendingPathComponent("drive-once.json"))

        let forwarded = ForwardedMessages()
        let bridge = iCloudBridge(testDriveURL: docs, testPairingSecret: secret, testDataRoot: docs)
        bridge.observeIncomingMessages { incoming in
            await forwarded.append(incoming.id)
            return true
        }
        for _ in 0..<30 { try await Task.sleep(for: .milliseconds(10)) }
        bridge.checkIosOutbox()
        for _ in 0..<10 { try await Task.sleep(for: .milliseconds(10)) }

        #expect(await forwarded.all() == ["drive-once"])
        #expect(FileManager.default.fileExists(atPath: docs.appendingPathComponent("processed/drive-once.json").path))
        bridge.tearDown()
    }

    // app.bridges / icloud.observeStatusKey
    @Test("status observers receive CloudKit peer updates rather than being discarded")
    @MainActor
    func cloudKitStatusObserverDeliversNamedKey() async throws {
        let cloud = MockDeviceCloud()
        let mac = MockDeviceSyncTransport(role: .mac, cloud: cloud)
        let phone = MockDeviceSyncTransport(role: .ios, cloud: cloud)
        let bridge = iCloudBridge(testDeviceTransport: mac)
        var received: [String] = []
        bridge.observeStatusKey("bridge_health") { received.append($0) }
        try await phone.setStatus(key: "bridge_health", value: "online")
        // The bridge registers its transport observer in a detached task, so a
        // fixed yield count is a timing guess that loses under full-suite load.
        // The mock transport drains the current value atomically with
        // registration, so delivery is guaranteed exactly once — poll for it
        // under a bounded deadline instead.
        let clock = ContinuousClock()
        let deadline = clock.now.advanced(by: .seconds(5))
        while received.isEmpty && clock.now < deadline {
            await Task.yield()
            try? await Task.sleep(for: .milliseconds(5))
        }
        // A short settle so a duplicate delivery would still fail the pin.
        for _ in 0..<8 { await Task.yield() }
        #expect(received == ["online"])
        bridge.tearDown()
    }

    // app.bridges / icloud.sendUnsignedResyncHint
    @Test("signature resync hint is deliberately unsigned and carries only recovery metadata")
    func unsignedResyncHintCarriesRecoveryOnly() {
        let hint = iCloudBridge.unsignedResyncHintMessage(
            correlationID: "rejected-message", targetSourceKey: "iphone:1", publishedAt: "2026-08-24T00:00:00Z", secretVersion: 4
        )
        #expect(hint.signature == nil)
        #expect(hint.metadata?["kind"] == "signature_invalid_resync")
        #expect(hint.metadata?["rejectedMessageId"] == "rejected-message")
        #expect(hint.metadata?["pairing_secret_version"] == "4")
        #expect(hint.metadata?["targetSourceKey"] == "iphone:1")
    }

    // app.bridges / icloud.sendKVSChatProgress
    @Test("KVS progress payload is bounded, ephemeral, and signed over its compacted content")
    func kvsProgressPayloadIsBoundedAndSigned() throws {
        let secret = Data(repeating: 2, count: 32)
        let progress = try iCloudBridge.makeKVSChatProgressMessage(
            text: String(repeating: "x", count: 300), sessionID: "ios:1", correlationID: "turn:1",
            metadata: ["detail": String(repeating: "m", count: 300)], secret: secret
        )
        #expect(progress.text.count == 240)
        #expect(progress.metadata?["detail"]?.count == 240)
        #expect(progress.metadata?["ephemeral"] == "true")
        #expect(progress.metadata?["transport"] == "icloud")
        #expect(progress.verifySignature(secret: secret))
    }

    // app.bridges / icloud.deliveryNudges
    @Test("each delivery request owns the bounded two-nudge plan")
    func deliveryNudgesHaveAnExplicitBoundedPlan() {
        #expect(ICloudDeliveryNudgePlan.delaysNanoseconds == [1_000_000_000, 3_000_000_000])
        #expect(ICloudDeliveryNudgePlan.delaysNanoseconds.allSatisfy { $0 > 0 })
    }

    // app.bridges / macsync.chatSnapshotCoalescerGeneration
    @Test("chat snapshot coalescer upgrades once and stale generations cannot strand the next request")
    func snapshotCoalescerClearsStaleLifecycleState() {
        var state = MacSyncChatSnapshotCoalescerState()
        let startsFirst = state.enqueue(includeTranscripts: false, generation: 1)
        #expect(startsFirst)
        let startsUpgrade = state.enqueue(includeTranscripts: true, generation: 1)
        #expect(!startsUpgrade)
        let firstResolved = state.resolve(generation: 1, currentGeneration: 1, isActive: true)
        #expect(firstResolved == true)
        #expect(!state.needsTranscripts)

        let startsSecond = state.enqueue(includeTranscripts: true, generation: 2)
        #expect(startsSecond)
        state.reset()
        let startsThird = state.enqueue(includeTranscripts: false, generation: 3)
        #expect(startsThird)
        let staleResolved = state.resolve(generation: 2, currentGeneration: 3, isActive: true)
        #expect(staleResolved == nil)
        let thirdResolved = state.resolve(generation: 3, currentGeneration: 3, isActive: true)
        #expect(thirdResolved == false)
    }

    // app.bridges / macsync.archiveRetentionWatcher
    @Test("archive retention watcher resolves every required path before arming")
    func archiveRetentionPathsCreateAndReturnAllThreeDirectories() throws {
        let root = try bridgeEvalRoot("archive-paths")
        defer { try? FileManager.default.removeItem(at: root) }
        let inbox = root.appendingPathComponent("inbox", isDirectory: true)
        let responses = root.appendingPathComponent("responses", isDirectory: true)
        let paths = MacSyncArchiveRetentionWatchPaths.resolve(inboxDirectory: inbox, responsesDirectory: responses)
        #expect(paths == [inbox, responses, inbox.appendingPathComponent("_rejected", isDirectory: true)])
        #expect(paths.allSatisfy { FileManager.default.fileExists(atPath: $0.path) })
        #expect(MacSyncArchiveRetentionWatchPaths.resolve(inboxDirectory: nil, responsesDirectory: responses).isEmpty)
    }

    // app.bridges / macsync.inboxResponseKVSSweep
    @Test("KVS response sweep removes expired or orphaned keys before preserving recent responses")
    func inboxResponseSweepNeverEvictsRecentReadableResponse() {
        let now = Date(timeIntervalSince1970: 10_000)
        let entries: [MacSyncInboxResponseSweep.Entry] = [
            .init(key: "missing", modified: nil, exists: false),
            .init(key: "expired", modified: now.addingTimeInterval(-25 * 60 * 60), exists: true),
            .init(key: "unreadable", modified: nil, exists: true),
            .init(key: "fresh-a", modified: now.addingTimeInterval(-60), exists: true),
            .init(key: "fresh-b", modified: now.addingTimeInterval(-60), exists: true),
        ]
        let removed = MacSyncInboxResponseSweep.keysToRemove(entries: entries, now: now, ttl: 24 * 60 * 60, cap: 2)
        #expect(Set(removed) == ["missing", "expired", "unreadable"])
        #expect(!removed.contains("fresh-a"))
        #expect(!removed.contains("fresh-b"))
    }
}
