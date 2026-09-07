import Foundation
import NativeAgentShared
import NativeAgentSharedTestSupport
import XCTest
@testable import NativeAgentMobile

private actor BridgeMessageRecorder {
    private var messages: [BridgeMessage] = []

    func append(_ message: BridgeMessage) {
        messages.append(message)
    }

    func ids() -> [String] {
        messages.map(\.id)
    }

    func first() -> BridgeMessage? {
        messages.first
    }
}

/// A transport-level scheduling probe, not a message codec replacement. It
/// lets the bridge's single-flight drain own the concurrency contract while
/// all payload encoding/decoding remains in NativeAgentShared.
private actor SlowDrainTransport: DeviceSyncTransport {
    nonisolated let role: NADeviceRole = .ios
    private var incomingDrains = 0
    private var pairingDrains = 0
    private var statusDrains = 0
    private var pendingSendFailures = 0
    private var acceptedSends = 0
    private var releaseFirstDrain: CheckedContinuation<Void, Never>?

    func send(_ message: BridgeMessage) async throws {
        if pendingSendFailures > 0 {
            pendingSendFailures -= 1
            throw DeviceSyncError.conflict
        }
        acceptedSends += 1
    }
    func observeIncoming(_ onMessage: @escaping @Sendable (BridgeMessage) async -> Bool) async {}
    func publishPairing(secret: Data) async throws {}
    func observePairing(onChange: @escaping @Sendable (Data) async -> Bool) async {}
    func setStatus(key: String, value: String) async throws {}
    func observeStatus(key: String, onChange: @escaping @Sendable (String) async -> Void) async {}

    func drainIncoming() async -> Int {
        incomingDrains += 1
        if incomingDrains == 1 {
            await withCheckedContinuation { continuation in
                releaseFirstDrain = continuation
            }
        }
        return 0
    }

    func drainPairing() async -> Bool {
        pairingDrains += 1
        return false
    }

    func drainStatus() async -> Int {
        statusDrains += 1
        return 0
    }

    func hasStartedFirstDrain() -> Bool { incomingDrains == 1 }
    func failNextSend() { pendingSendFailures = 1 }
    func acceptedSendCount() -> Int { acceptedSends }
    func release() {
        releaseFirstDrain?.resume()
        releaseFirstDrain = nil
    }
    func counts() -> (incoming: Int, pairing: Int, status: Int) {
        (incomingDrains, pairingDrains, statusDrains)
    }
}

/// Coverage-ledger fences `ios.sync` and `ios.screens`.
///
/// Rows exercised here:
/// - ios.bridge.setup / ios.bridge.publishedStatus / ios.bridge.drainDeviceTransport
/// - ios.bridge.observerRegistry / ios.bridge.foregroundPairingRedrain
/// - ios.sync.applyCloudKitSnapshotStatus
/// - ios.push.didReceiveRemoteNotification / ios.app.didReceiveRemoteNotification
/// - ios.app.configureNotifications / ios.app.foregroundRefresh
/// - ios.kg.emptyState / ios.kg.search / ios.kg.detailSheet.neighbors
///
/// These are deliberately source-integrity evaluations where the production
/// owners are singleton/UIKit/CloudKit-bound.  They pin the observable
/// lifecycle ordering and truthful empty/error affordances at the boundary;
/// the simulator ui-walk then proves those labelled states are reachable.
final class ICloudSyncVisibleLifecycleEvalTests: XCTestCase {
    private func body(_ header: String, in source: String) throws -> String {
        guard let headerRange = source.range(of: header),
              let open = source.range(of: "{", range: headerRange.upperBound..<source.endIndex)
        else {
            throw MobileEvalSources.LocatorError.missing(header)
        }
        var depth = 0
        var cursor = open.lowerBound
        while cursor < source.endIndex {
            if source[cursor] == "{" { depth += 1 }
            if source[cursor] == "}" {
                depth -= 1
                if depth == 0 { return String(source[open.upperBound..<cursor]) }
            }
            cursor = source.index(after: cursor)
        }
        throw MobileEvalSources.LocatorError.missing("balanced body for \(header)")
    }

    func testBridgeSetupUsesGenerationGuardAndNeverBlocksTheMainActorOnICloudMount() throws {
        let bridge = try MobileEvalSources.mobileSource("iCloudBridge.swift")
        let setup = try body("func setup()", in: bridge)
        let apply = try body("private func applyContainerResult(", in: bridge)

        XCTAssertTrue(setup.contains("guard !isSetUp else { return }"))
        XCTAssertTrue(setup.contains("setupGeneration += 1"))
        XCTAssertTrue(setup.contains("Task.detached"))
        XCTAssertTrue(setup.contains("url(forUbiquityContainerIdentifier:"))
        XCTAssertTrue(apply.contains("generation == setupGeneration"))
        XCTAssertTrue(apply.contains("isSetUp"))
        XCTAssertTrue(apply.contains("iCloud unavailable"))
        XCTAssertTrue(apply.contains("isSetUp = false"),
                      "a failed container lookup must leave setup retryable rather than permanently showing a stale connecting state")
    }

    func testCloudKitDrainIsSingleFlightAndCatchesPairingAndStatusAfterMessages() throws {
        let bridge = try MobileEvalSources.mobileSource("iCloudBridge.swift")
        let drain = try body("func drainDeviceTransport() async -> Bool", in: bridge)

        XCTAssertTrue(drain.contains("guard NADeviceSyncRecoveryBudget.hasTime, let ck = deviceTransport else { return false }"))
        XCTAssertTrue(drain.contains("deviceDrainInFlight"))
        XCTAssertTrue(drain.contains("deviceDrainQueued = true"))
        XCTAssertTrue(drain.contains("await ck.drainIncoming()"))
        XCTAssertTrue(drain.contains("await ck.drainPairing()"))
        XCTAssertTrue(drain.contains("await ck.drainStatus()"))
        XCTAssertTrue(drain.contains("defer"), "the single-flight latch must be released on errors and cancellation")
    }

    func testObserverRegistrationRedrainsAndRemovalUsesTheMatchingRegistry() throws {
        let bridge = try MobileEvalSources.mobileSource("iCloudBridge.swift")
        let pairs = [
            ("func observeIncomingMessages(", "func removeIncomingObserver(", "messageHandlers"),
            ("func observeRejectedMessages(", "func removeRejectedObserver(", "rejectionHandlers"),
            ("func observeResyncHints(", "func removeResyncObserver(", "resyncHintHandlers"),
            ("func observeNotifications(", "func removeNotificationObserver(", "notificationHandlers"),
        ]
        for (registerHeader, removeHeader, registry) in pairs {
            let register = try body(registerHeader, in: bridge)
            let remove = try body(removeHeader, in: bridge)
            XCTAssertTrue(register.contains("\(registry)[id]"))
            XCTAssertTrue(register.contains("drainIncoming") || register.contains("checkMacOutbox"),
                          "a late \(registry) observer misses the already-arrived message unless registration redrains")
            XCTAssertTrue(remove.contains("\(registry).removeValue(forKey: id)"),
                          "removing a \(registry) observer must not leave a stale callback alive after its screen disappears")
        }
    }

    func testSnapshotStatusOnlyAdvancesFreshnessAfterVerifiedDecodeAndWrite() throws {
        let setup = try MobileEvalSources.mobileSource("iCloudSyncEngine+Setup.swift")
        let apply = try body("func applyCloudKitSnapshotStatus(", in: setup)

        guard let decode = apply.range(of: "NAMobileSnapshotStatusCodec.decode"),
              let write = apply.range(of: "data.write("),
              let freshness = apply.range(of: "lastSyncAt = Date()")
        else {
            return XCTFail("CloudKit snapshot status no longer has decode/write/freshness stages")
        }
        XCTAssertLessThan(decode.lowerBound, write.lowerBound)
        XCTAssertLessThan(write.lowerBound, freshness.lowerBound)
        // 2026-09-06 (ab60f226): applyCloudKitSnapshotStatus now returns Bool so
        // the transport claims the peer's generation only on a durable apply,
        // so the lifecycle guard early-exits with `return true` — a teardown
        // mid-apply is not a delivery to retry, the engine is simply gone. What
        // this line guards is unchanged: a stale generation must not reach
        // `lastSyncAt = Date()`.
        XCTAssertTrue(apply.contains("guard generation == lifecycleGeneration else { return true }"))
        XCTAssertTrue(apply.contains("snapshot failed:"),
                      "a bad snapshot must render an error instead of advancing the visible freshness claim")
    }

    func testPushAndForegroundPathsRefreshTheSharedVisibleStoresWithoutPretendingAResult() throws {
        let app = try MobileEvalSources.mobileSource("NativeAgentMobileApp.swift")
        let notifications = try MobileEvalSources.mobileSource("MobilePushNotifications.swift")
        let push = try body(
            "didReceiveRemoteNotification userInfo: [AnyHashable: Any],\n        fetchCompletionHandler",
            in: notifications
        )
        let foreground = try body("private func refreshOnForeground()", in: app)

        XCTAssertTrue(push.contains("PushReceiptLedger.record"))
        XCTAssertTrue(push.contains("drainIfDeviceSyncPush"))
        XCTAssertTrue(push.contains("pollIncomingNow"))
        XCTAssertTrue(push.contains("refreshChatTranscriptsSnapshot"))
        XCTAssertTrue(push.contains("refreshInboxSnapshot"))
        XCTAssertTrue(push.contains("refreshActivitySnapshot"))
        XCTAssertTrue(push.contains("NativeAgentRemotePushProcessor.process"))
        XCTAssertTrue(push.contains("completionGate.complete(outcome.backgroundFetchResult)"))
        XCTAssertTrue(foreground.contains("guard pairingStore.usesICloudTransport else { return }"))
        XCTAssertTrue(foreground.contains("refreshSnapshots"))
    }

    func testKnowledgeGraphHasTruthfulLoadingEmptyAndUnavailableStates() throws {
        let graph = try MobileEvalSources.mobileSource("KnowledgeGraphView.swift")

        XCTAssertTrue(graph.contains("ProgressView(\"Loading graph…\")"))
        XCTAssertTrue(graph.contains("title: \"No entities\""))
        XCTAssertTrue(graph.contains("Knowledge graph snapshot is still downloading from iCloud"))
        XCTAssertTrue(graph.contains(".searchable(text: $searchText"))
        XCTAssertTrue(graph.contains("selectedEntity = entity"))
        XCTAssertTrue(graph.contains("neighbors"),
                      "entity detail must retain the neighbor relationship view instead of presenting an empty shell")
    }
}

/// Executed iOS sync contracts at the signed message, transport, and snapshot
/// boundaries. All durable state is isolated to a temporary
/// directory or a unique UserDefaults suite; no CloudKit, KVS, Keychain write,
/// or source-text inspection is involved.
///
/// Rows exercised:
/// ios.bridge.setup, ios.bridge.sendChatMessage, ios.bridge.handleIncomingFromTransport,
/// ios.bridge.drainDeviceTransport, ios.bridge.observerRegistry,
/// ios.bridge.publishedStatus, ios.sync.applyCloudKitSnapshotStatus.
@MainActor
final class IOSSyncTransportBoundaryEvalTests: XCTestCase {
    private let secret = Data(repeating: 0xA5, count: 32)
    private var defaultsSuite = ""
    private var defaults: UserDefaults!
    private var pairing: PairingStore!
    private var bridge: iCloudBridge!
    private var cloud: MockDeviceCloud!
    private var iosTransport: MockDeviceSyncTransport!
    private var macTransport: MockDeviceSyncTransport!

    override func setUp() async throws {
        try await super.setUp()
        defaultsSuite = "NativeAgentMobileTests.syncTransport.\(UUID().uuidString)"
        defaults = try XCTUnwrap(UserDefaults(suiteName: defaultsSuite))
        defaults.removePersistentDomain(forName: defaultsSuite)

        pairing = PairingStore()
        pairing.iCloudPairingSecret = secret
        cloud = MockDeviceCloud()
        iosTransport = MockDeviceSyncTransport(role: .ios, cloud: cloud)
        macTransport = MockDeviceSyncTransport(role: .mac, cloud: cloud)
        bridge = iCloudBridge(
            deviceTransport: iosTransport,
            pairingStore: pairing,
            userDefaults: defaults
        )
    }

    override func tearDown() async throws {
        pairing.iCloudPairingSecret = nil
        defaults.removePersistentDomain(forName: defaultsSuite)
        bridge = nil
        iosTransport = nil
        macTransport = nil
        cloud = nil
        pairing = nil
        defaults = nil
        try await super.tearDown()
    }

    private func signedMacMessage(
        id: String = UUID().uuidString,
        text: String = "Mac reply",
        metadata: [String: String]? = nil
    ) throws -> BridgeMessage {
        try BridgeMessage.make(
            id: id,
            sender: "mac",
            text: text,
            metadata: metadata
        ).signed(with: secret)
    }

    private func signedExpiredMacMessage(id: String) throws -> BridgeMessage {
        let date = ISO8601DateFormatter().string(from: Date(timeIntervalSinceNow: -25 * 60 * 60))
        let wire: [String: Any] = [
            "id": id,
            "sender": "mac",
            "timestamp": date,
            "text": "expired reply",
        ]
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return try decoder.decode(
            BridgeMessage.self,
            from: JSONSerialization.data(withJSONObject: wire, options: [.sortedKeys])
        ).signed(with: secret)
    }

    func testSendRequiresASecretBeforeAnyTransportWriteAndRecoversFromThrow() async throws {
        let unpaired = iCloudBridge(deviceTransport: iosTransport, userDefaults: defaults)
        do {
            _ = try await unpaired.sendChatMessage(text: "must not leave this phone")
            XCTFail("an unsigned chat must never reach the transport")
        } catch let error as BridgeError {
            guard case .missingPairingSecret = error else {
                return XCTFail("unexpected bridge error: \(error)")
            }
        }
        let unsignedWriteCount = await cloud.chatCount()
        XCTAssertEqual(unsignedWriteCount, 0)
        XCTAssertNil(unpaired.lastSyncAt)
        XCTAssertEqual(unpaired.syncStatus, "iCloud not checked")

        await cloud.setSimulateConflictOnSend(true)
        do {
            _ = try await bridge.sendChatMessage(text: "conflict")
            XCTFail("a transport conflict must surface to the sender")
        } catch let error as DeviceSyncError {
            guard case .conflict = error else {
                return XCTFail("unexpected transport error: \(error)")
            }
        }
        let failedWriteCount = await cloud.chatCount()
        XCTAssertEqual(failedWriteCount, 0)
        XCTAssertNil(bridge.lastSyncAt)
        XCTAssertEqual(bridge.syncStatus, "iCloud not checked")

        await cloud.setSimulateConflictOnSend(false)
        let received = BridgeMessageRecorder()
        await macTransport.observeIncoming { message in
            await received.append(message)
            return true
        }

        let sent = try await bridge.sendChatMessage(
            text: "Phone request",
            sessionID: "session-17",
            correlationID: "turn-17",
            metadata: ["kind": "chat", "targetSourceKey": "mac"]
        )
        let delivered = await macTransport.drainIncoming()

        XCTAssertEqual(delivered, 1)
        let receivedIDs = await received.ids()
        let firstReceived = await received.first()
        XCTAssertEqual(receivedIDs, [sent.id])
        let first = try XCTUnwrap(firstReceived)
        XCTAssertEqual(first.sender, "ios")
        XCTAssertEqual(first.sessionID, "session-17")
        XCTAssertEqual(first.correlationID, "turn-17")
        XCTAssertTrue(first.verifySignature(secret: secret))
        XCTAssertEqual(bridge.syncStatus, "Sending via CloudKit")
        XCTAssertNotNil(bridge.lastSyncAt)
    }

    func testIncomingDecisionTablePersistsRejectionAcrossBridgeRecreation() async throws {
        let noContainer = iCloudBridge(
            pairingStore: pairing,
            userDefaults: defaults,
            ubiquityContainerURL: { _ in nil }
        )
        noContainer.setup()
        for _ in 0..<100 where noContainer.syncStatus == "iCloud connecting…" {
            await Task.yield()
        }
        XCTAssertFalse(noContainer.available)
        XCTAssertEqual(
            noContainer.syncStatus,
            "iCloud unavailable — sign into iCloud in Settings → Apple Account"
        )

        bridge.setup()
        XCTAssertTrue(bridge.available)
        XCTAssertEqual(bridge.syncStatus, "CloudKit ready")

        let noSecret = iCloudBridge(deviceTransport: iosTransport, userDefaults: defaults)
        let noSecretObserver = noSecret.observeIncomingMessages { _ in
            XCTFail("an unverified incoming message must not dispatch")
        }
        let heldWithoutSecret = await noSecret.handleIncomingFromTransport(
            try signedMacMessage(id: "no-secret-1")
        )
        XCTAssertFalse(heldWithoutSecret)
        noSecret.removeIncomingObserver(noSecretObserver)

        let message = try signedMacMessage(id: "inbound-1")
        let heldWithoutConsumer = await bridge.handleIncomingFromTransport(message)
        XCTAssertFalse(heldWithoutConsumer, "a reply must stay eligible until Chat registers")

        var deliveredIDs: [String] = []
        let observer = bridge.observeIncomingMessages { deliveredIDs.append($0.id) }
        let firstAccepted = await bridge.handleIncomingFromTransport(message)
        let duplicateAccepted = await bridge.handleIncomingFromTransport(message)
        XCTAssertTrue(firstAccepted)
        XCTAssertTrue(duplicateAccepted, "an already persisted receipt is safe to acknowledge")
        XCTAssertEqual(deliveredIDs, [message.id], "duplicate transport delivery must not duplicate the transcript")
        XCTAssertEqual(bridge.syncStatus, "Received from Mac (CloudKit)")

        let foreign = try signedMacMessage(
            id: "foreign-1",
            metadata: ["targetSourceKey": "desktop:someone-else"]
        )
        let foreignAccepted = await bridge.handleIncomingFromTransport(foreign)
        XCTAssertTrue(foreignAccepted, "foreign-targeted data is consumed, not allowed to wedge the cursor")
        XCTAssertEqual(deliveredIDs, [message.id])

        let actionResponseWithoutCorrelation = try signedMacMessage(
            id: "response-without-correlation",
            metadata: ["kind": "icloud_action_response"]
        )
        let heldActionResponse = await bridge.handleIncomingFromTransport(actionResponseWithoutCorrelation)
        XCTAssertFalse(heldActionResponse, "an action response without its durable action id must remain eligible")

        let invalid = BridgeMessage.make(sender: "mac", text: "tampered")
        let heldInvalidWithoutRejection = await bridge.handleIncomingFromTransport(invalid)
        XCTAssertFalse(heldInvalidWithoutRejection, "a bad signature must wait for a visible rejection consumer")
        var rejectionReasons: [String] = []
        let rejectionObserver = bridge.observeRejectedMessages { rejectionReasons.append($0.reason) }
        let invalidAccepted = await bridge.handleIncomingFromTransport(invalid)
        XCTAssertTrue(invalidAccepted)
        XCTAssertEqual(rejectionReasons, ["signature_invalid"])
        XCTAssertTrue(bridge.syncStatus.contains("Re-pair"))

        let recreated = iCloudBridge(
            deviceTransport: MockDeviceSyncTransport(role: .ios, cloud: cloud),
            pairingStore: pairing,
            userDefaults: defaults
        )
        var replayedRejection = false
        let recreatedObserver = recreated.observeRejectedMessages { _ in replayedRejection = true }
        let recreatedAccepted = await recreated.handleIncomingFromTransport(invalid)
        XCTAssertTrue(recreatedAccepted)
        XCTAssertFalse(replayedRejection, "the persisted rejection receipt must survive bridge recreation")
        recreated.removeRejectedObserver(recreatedObserver)

        let notification = try signedMacMessage(
            id: "notification-1",
            metadata: ["kind": "notification"]
        )
        let heldNotification = await bridge.handleIncomingFromTransport(notification)
        XCTAssertFalse(heldNotification)
        var deliveredNotifications: [String] = []
        let notificationObserver = bridge.observeNotifications {
            deliveredNotifications.append($0.id)
        }
        let acceptedNotification = await bridge.handleIncomingFromTransport(notification)
        XCTAssertTrue(acceptedNotification)
        XCTAssertEqual(deliveredNotifications, [notification.id])

        let expired = try signedExpiredMacMessage(id: "expired-1")
        let statusBeforeArchive = bridge.syncStatus
        let archivedExpiredMessage = await bridge.handleIncomingFromTransport(expired)
        XCTAssertTrue(archivedExpiredMessage)
        XCTAssertEqual(bridge.syncStatus, statusBeforeArchive, "archived history must not claim a fresh visible reply")

        bridge.removeIncomingObserver(observer)
        bridge.removeRejectedObserver(rejectionObserver)
        bridge.removeNotificationObserver(notificationObserver)
    }

    func testObserversRemoveSilentlyAndTeardownClearsEveryRegistry() async throws {
        var retiredMessage = 0
        var liveMessage = 0
        let retiredMessageID = bridge.observeIncomingMessages { _ in retiredMessage += 1 }
        let liveMessageID = bridge.observeIncomingMessages { _ in liveMessage += 1 }
        bridge.removeIncomingObserver(retiredMessageID)
        let deliveredChat = await bridge.handleIncomingFromTransport(try signedMacMessage(id: "observer-chat"))
        XCTAssertTrue(deliveredChat)
        XCTAssertEqual(retiredMessage, 0)
        XCTAssertEqual(liveMessage, 1)

        var retiredRejection = 0
        var liveRejection = 0
        let retiredRejectionID = bridge.observeRejectedMessages { _ in retiredRejection += 1 }
        let liveRejectionID = bridge.observeRejectedMessages { _ in liveRejection += 1 }
        bridge.removeRejectedObserver(retiredRejectionID)
        let deliveredRejection = await bridge.handleIncomingFromTransport(BridgeMessage.make(id: "observer-reject", sender: "mac", text: "bad"))
        XCTAssertTrue(deliveredRejection)
        XCTAssertEqual(retiredRejection, 0)
        XCTAssertEqual(liveRejection, 1)

        var retiredNotification = 0
        var liveNotification = 0
        let retiredNotificationID = bridge.observeNotifications { _ in retiredNotification += 1 }
        let liveNotificationID = bridge.observeNotifications { _ in liveNotification += 1 }
        bridge.removeNotificationObserver(retiredNotificationID)
        let deliveredNotification = await bridge.handleIncomingFromTransport(try signedMacMessage(
            id: "observer-notification", metadata: ["kind": "notification"]
        ))
        XCTAssertTrue(deliveredNotification)
        XCTAssertEqual(retiredNotification, 0)
        XCTAssertEqual(liveNotification, 1)

        // A resync hint deliberately has no local visual callback unless the
        // Keychain-owning PairingStore installs new material. Removing the
        // observer still must leave that registry unable to retain a callback.
        var retiredResync = 0
        var liveResync = 0
        let retiredResyncID = bridge.observeResyncHints { _ in retiredResync += 1 }
        let liveResyncID = bridge.observeResyncHints { _ in liveResync += 1 }
        bridge.removeResyncObserver(retiredResyncID)
        let acceptedResyncHint = await bridge.handleIncomingFromTransport(BridgeMessage.make(
            id: "observer-resync", sender: "mac", text: "refresh", metadata: ["kind": "signature_invalid_resync"]
        ))
        XCTAssertTrue(acceptedResyncHint)
        XCTAssertEqual(retiredResync, 0)

        bridge.tearDown()
        XCTAssertFalse(bridge.available)
        XCTAssertEqual(bridge.syncStatus, "iCloud disconnected")
        let heldAfterTeardown = await bridge.handleIncomingFromTransport(try signedMacMessage(id: "after-teardown"))
        let heldRejectedAfterTeardown = await bridge.handleIncomingFromTransport(
            BridgeMessage.make(id: "after-teardown-rejection", sender: "mac", text: "bad")
        )
        let heldNotificationAfterTeardown = await bridge.handleIncomingFromTransport(try signedMacMessage(
            id: "after-teardown-notification", metadata: ["kind": "notification"]
        ))
        let consumedResyncAfterTeardown = await bridge.handleIncomingFromTransport(BridgeMessage.make(
            id: "after-teardown-resync", sender: "mac", text: "refresh", metadata: ["kind": "signature_invalid_resync"]
        ))
        XCTAssertFalse(heldAfterTeardown)
        XCTAssertFalse(heldRejectedAfterTeardown)
        XCTAssertFalse(heldNotificationAfterTeardown)
        XCTAssertTrue(consumedResyncAfterTeardown)
        XCTAssertEqual(retiredMessage, 0)
        XCTAssertEqual(liveMessage, 1)
        XCTAssertEqual(retiredRejection, 0)
        XCTAssertEqual(liveRejection, 1)
        XCTAssertEqual(retiredNotification, 0)
        XCTAssertEqual(liveNotification, 1)
        XCTAssertEqual(retiredResync, 0)
        XCTAssertEqual(liveResync, 0)
        bridge.removeIncomingObserver(liveMessageID)
        bridge.removeRejectedObserver(liveRejectionID)
        bridge.removeNotificationObserver(liveNotificationID)
        bridge.removeResyncObserver(liveResyncID)
    }

    func testDrainCoalescesConcurrentCallsAndRecoversToTheNextPass() async throws {
        let slow = SlowDrainTransport()
        let slowBridge = iCloudBridge(deviceTransport: slow, pairingStore: pairing, userDefaults: defaults)
        await slow.failNextSend()
        do {
            _ = try await slowBridge.sendChatMessage(text: "transport fault")
            XCTFail("the injected transport failure must reach the sender")
        } catch let error as DeviceSyncError {
            guard case .conflict = error else {
                return XCTFail("unexpected injected transport error: \(error)")
            }
        }
        let recoveredSend = try await slowBridge.sendChatMessage(text: "transport recovered")
        let recoveredSendCount = await slow.acceptedSendCount()
        XCTAssertEqual(recoveredSend.sender, "ios")
        XCTAssertEqual(recoveredSendCount, 1, "a throwing transport must not poison its next send or drain pass")

        let first = Task { await slowBridge.drainDeviceTransport() }
        for _ in 0..<100 where !(await slow.hasStartedFirstDrain()) {
            await Task.yield()
        }
        let startedFirstDrain = await slow.hasStartedFirstDrain()
        XCTAssertTrue(startedFirstDrain)
        let firstOverlap = await slowBridge.drainDeviceTransport()
        let secondOverlap = await slowBridge.drainDeviceTransport()
        XCTAssertFalse(firstOverlap)
        XCTAssertFalse(secondOverlap)
        await slow.release()
        let firstResult = await first.value
        XCTAssertFalse(firstResult)

        for _ in 0..<100 {
            let current = await slow.counts()
            if current.incoming == 2, current.pairing == 2, current.status == 2 { break }
            await Task.yield()
        }
        let counts = await slow.counts()
        XCTAssertEqual(counts.incoming, 2, "overlapping drains must collapse into one queued re-run")
        XCTAssertEqual(counts.pairing, 2)
        XCTAssertEqual(counts.status, 2)
        slowBridge.tearDown()
    }

    func testSnapshotStatusPublishesEachGroupAndPreservesPriorCacheOnCorruption() async throws {
        let engine = iCloudSyncEngine.shared
        let priorSnapshotDir = engine.snapshotDir
        let priorCachePreference = engine.prefersCloudKitSnapshotCache
        let priorCacheRootOverride = engine.cloudKitSnapshotCacheRootOverride
        let priorLastSyncAt = engine.lastSyncAt
        let priorSyncError = engine.syncError
        let priorProviders = engine.providers
        let priorSkills = engine.skills
        let priorTranscripts = engine.chatTranscripts
        let priorDeskItems = engine.deskItems
        let priorWorkshopTasks = engine.workshopTasks
        let priorRuns = engine.runs
        let priorTurnSummaries = engine.turnSummaries
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("nativeagent-ios-snapshot-status-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer {
            engine.snapshotDir = priorSnapshotDir
            engine.prefersCloudKitSnapshotCache = priorCachePreference
            engine.cloudKitSnapshotCacheRootOverride = priorCacheRootOverride
            engine.lastSyncAt = priorLastSyncAt
            engine.syncError = priorSyncError
            engine.providers = priorProviders
            engine.skills = priorSkills
            engine.chatTranscripts = priorTranscripts
            engine.deskItems = priorDeskItems
            engine.workshopTasks = priorWorkshopTasks
            engine.runs = priorRuns
            engine.turnSummaries = priorTurnSummaries
            try? FileManager.default.removeItem(at: root)
        }

        engine.cloudKitSnapshotCacheRootOverride = root
        let encoder = JSONEncoder()
        let coreBytes = try encoder.encode([
            ProviderInfo(
                provider_id: "provider-status", display_name: "Status Provider", auth_modes: ["api_key"],
                auth_status: ProviderAuthStatus(provider_id: "provider-status", state: "ready", detail: "verified", user_info: nil, last_checked_at: nil),
                models: []
            ),
        ])
        let catalogBytes = try encoder.encode([
            SkillRecord(id: "skill-status", name: "Status Skill", status: "ready", kind: nil, description: nil, triggers: nil, riskClass: nil, autoload: nil, useCount: nil, updatedAt: nil),
        ])
        let chatBytes = try encoder.encode([
            ChatTranscriptSnapshot(sessionId: "status-session", messages: [
                ChatMessageRecord(id: "status-message", sessionId: "status-session", role: "assistant", content: "arrived"),
            ]),
        ])
        let deskBytes = try encoder.encode([
            MobileDeskItem(
                handle: "desk-status", alias: "Desk Status", parent: nil, kind: "task", status: "open",
                project: "NativeAgent", title: "Snapshot", summary: nil, openedAt: "2026-01-01T00:00:00Z",
                updatedAt: "2026-01-01T00:00:00Z", closedAt: nil, pinned: false, blockedReason: nil,
                waitingOn: nil, blockedOn: [], deferUntil: nil, origin: "test", requiresOwnerInput: false, recentNotes: []
            ),
        ])
        let activityBytes = try encoder.encode([
            WorkshopTaskRecord(id: "workshop-status", title: "Snapshot", objective: "Publish", status: "active", phase: "execute", createdAt: "2026-01-01T00:00:00Z"),
        ])
        // This is the canonical JSON snapshot shape emitted by the Mac, then
        // decoded by the production advanced projection; it is not a mirror
        // type owned by the test.
        let advancedBytes = Data("[{\"id\":\"run-status\",\"kind\":\"test\",\"status\":\"completed\",\"createdAt\":\"2026-01-01T00:00:00Z\"}]".utf8)
        let turnSummaryBytes = Data("{\"summaries\":[],\"truncated\":false,\"totalTurnsSeen\":7}".utf8)
        func completeGroup(
            _ group: NAMobileSnapshotGroup,
            values: [String: Data]
        ) -> [String: Data] {
            Dictionary(uniqueKeysWithValues: group.filenames.map {
                ($0, values[$0] ?? Data("[]".utf8))
            })
        }
        let updates: [(NAMobileSnapshotGroup, [String: Data], () -> Bool)] = [
            (.core, completeGroup(.core, values: ["providers.json": coreBytes]), { engine.providers.map(\.id) == ["provider-status"] }),
            (.catalog, completeGroup(.catalog, values: ["skills_snapshot.json": catalogBytes]), { engine.skills.map(\.id) == ["skill-status"] }),
            (.chat, completeGroup(.chat, values: ["chat_transcripts.json": chatBytes]), { engine.chatTranscripts["status-session"]?.records.map(\.id) == ["status-message"] }),
            (.desk, completeGroup(.desk, values: ["desk.json": deskBytes]), { engine.deskItems.map(\.handle) == ["desk-status"] }),
            (.activity, completeGroup(.activity, values: ["workshop_tasks.json": activityBytes]), { engine.workshopTasks.map(\.id) == ["workshop-status"] }),
            (.advanced, completeGroup(.advanced, values: [
                "runs.json": advancedBytes,
                "turn_summaries.json": turnSummaryBytes,
            ]), {
                engine.runs.map(\.id) == ["run-status"]
                    && engine.turnSummaries?.totalTurnsSeen == 7
            }),
        ]
        for (group, files, didPublish) in updates {
            let status = try NAMobileSnapshotStatusCodec.encode(group: group, files: files)
            await engine.applyCloudKitSnapshotStatus(status, group: group)
            XCTAssertTrue(didPublish(), "\(group.rawValue) must refresh its @Published projection from validated bytes")
            XCTAssertNil(engine.syncError)
            let cache = try XCTUnwrap(engine.snapshotDir)
            for filename in group.filenames {
                XCTAssertEqual(
                    try Data(contentsOf: cache.appendingPathComponent(filename)),
                    files[filename],
                    "validated \(group.rawValue) bytes must be durable for \(filename)"
                )
            }
        }
        let provenSnapshotDir = try XCTUnwrap(engine.snapshotDir)
        let provenBytes = try Data(contentsOf: provenSnapshotDir.appendingPathComponent("providers.json"))
        XCTAssertEqual(provenBytes, coreBytes)
        let provenFreshness = try XCTUnwrap(engine.lastSyncAt)

        await engine.applyCloudKitSnapshotStatus("{not a status envelope}", group: .core)
        XCTAssertEqual(try Data(contentsOf: provenSnapshotDir.appendingPathComponent("providers.json")), provenBytes)
        XCTAssertEqual(engine.providers.map(\.id), ["provider-status"])
        XCTAssertEqual(engine.lastSyncAt, provenFreshness)
        XCTAssertTrue(engine.syncError?.contains("CloudKit core snapshot failed") == true)
    }

}
