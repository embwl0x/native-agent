import Foundation
import Testing
@testable import NativeAgentShared

#if canImport(CloudKit) && !os(Linux)
import CloudKit
#endif

@Suite("Mobile snapshot status codec")
struct MobileSnapshotStatusCodecTests {
    @Test func roundTripsAndCompressesBoundedFiles() throws {
        let repeated = Data(
            String(repeating: #"{"name":"tool_catalog","available":true}"#, count: 8_000).utf8
        )
        let files = [
            "skills_snapshot.json": Data(#"[{"id":"skill-1","name":"One"}]"#.utf8),
            "tools_snapshot.json": repeated,
        ]

        let value = try NAMobileSnapshotStatusCodec.encode(
            group: .catalog,
            files: files
        )
        let decoded = try NAMobileSnapshotStatusCodec.decode(
            value,
            expectedGroup: .catalog
        )

        #expect(decoded == files)
        #expect(Data(value.utf8).count < repeated.count)
    }

    @Test func rejectsWrongGroupAndUnknownFilename() throws {
        let value = try NAMobileSnapshotStatusCodec.encode(
            group: .chat,
            files: ["chat_transcripts.json": Data("[]".utf8)]
        )

        #expect(throws: (any Error).self) {
            _ = try NAMobileSnapshotStatusCodec.decode(value, expectedGroup: .core)
        }
        #expect(throws: (any Error).self) {
            _ = try NAMobileSnapshotStatusCodec.encode(
                group: .core,
                files: ["../trust_policy.json": Data("{}".utf8)]
            )
        }
    }
}

@Suite("Provider catalog status codec")
struct ProviderCatalogStatusCodecTests {
    @Test func credentialFreeCatalogRoundTrips() throws {
        let catalog = NAProviderCatalogStatus(
            providers: [
                NAProviderCatalogProvider(
                    providerID: "anthropic_oauth_direct",
                    displayName: "Anthropic",
                    authState: "ready",
                    authModes: ["oauth"],
                    models: [
                        NAProviderCatalogModel(
                            id: "claude-opus-5",
                            name: "Claude Opus 5",
                            contextLength: 200_000,
                            supportsStreaming: true,
                            supportsVision: true,
                            supportsTools: true,
                            supportsJSONMode: true,
                            defaultReasoningEffort: "high",
                            supportedReasoningEfforts: ["low", "high"],
                            supportsFast: false
                        )
                    ]
                )
            ],
            surfaces: [
                "ios": NAProviderSurfaceSelection(
                    providerID: "anthropic_oauth_direct",
                    model: "claude-opus-5",
                    reasoningEffort: "high",
                    serviceTier: "default"
                )
            ]
        )

        let value = try NAProviderCatalogStatusCodec.encode(catalog)
        #expect(!value.contains("token"))
        #expect(try NAProviderCatalogStatusCodec.decode(value) == catalog)
    }

    @Test func rejectsFutureVersionWithoutReplacingLastGoodState() throws {
        let value = """
        {"version":2,"providers":[],"surfaces":{}}
        """
        #expect(throws: (any Error).self) {
            try NAProviderCatalogStatusCodec.decode(value)
        }
    }

    @Test func rejectsOversizedStatusBeforeCloudKitWrite() {
        let huge = NAProviderCatalogStatus(
            providers: [
                NAProviderCatalogProvider(
                    providerID: String(repeating: "x", count: NAProviderCatalogStatusCodec.maximumBytes),
                    displayName: "Huge",
                    authState: "ready",
                    authModes: [],
                    models: []
                )
            ],
            surfaces: [:]
        )
        #expect(throws: DeviceSyncError.self) {
            try NAProviderCatalogStatusCodec.encode(huge)
        }
    }
}

@Suite("DeviceSyncTransport codec")
struct DeviceSyncCodecTests {
    @Test func encodeDecodeRoundTripsBridgeMessageLossless() throws {
        let secret = Data("nativeagent-secret".utf8)
        let original = try BridgeMessage.make(
            sender: "ios",
            text: "hello from iphone",
            sessionID: "session-42",
            correlationID: "corr-1",
            metadata: ["kind": "chat", "surface": "ios"]
        ).signed(with: secret)

        let fields = try NAChatMessageCodec.encode(original)

        #expect(fields.recordName == original.id)
        #expect(fields.direction == NAChatDirection.ios2mac.rawValue)
        #expect(fields.sessionId == "session-42")
        #expect(fields.senderDevice == "ios")
        #expect(fields.kind == "chat")
        #expect(fields.notificationTitle == nil)
        #expect(fields.notificationScreen == nil)
        #expect(fields.notificationEventID == nil)

        let decoded = try NAChatMessageCodec.decode(fields)
        #expect(decoded.id == original.id)
        #expect(decoded.text == original.text)
        #expect(decoded.correlationID == "corr-1")
        // Signature survives the round trip verbatim.
        #expect(decoded.verifySignature(secret: secret))
    }

    @Test func notificationRecordProjectsVisualPushFieldsWithoutReplacingPayloadAuthority() throws {
        let message = BridgeMessage.make(
            sender: "mac",
            text: "The build finished.",
            metadata: [
                "kind": "notification",
                "title": "NativeAgent",
                "userInfo.screen": "inbox",
                "userInfo.eventId": String(repeating: "a", count: 64),
            ]
        )

        let fields = try NAChatMessageCodec.encode(message)
        #expect(fields.kind == "notification")
        #expect(fields.text == "The build finished.")
        #expect(fields.notificationTitle == "NativeAgent")
        #expect(fields.notificationScreen == "inbox")
        #expect(fields.notificationEventID == String(repeating: "a", count: 64))
        let decoded = try NAChatMessageCodec.decode(fields)
        #expect(decoded.id == message.id)
        #expect(decoded.text == message.text)
        #expect(decoded.metadata == message.metadata)
    }

    @Test func directionDerivesFromSender() {
        #expect(NAChatMessageCodec.direction(forSender: "mac") == .mac2ios)
        #expect(NAChatMessageCodec.direction(forSender: "MAC") == .mac2ios)
        #expect(NAChatMessageCodec.direction(forSender: "ios") == .ios2mac)
    }

    @Test func cloudKitPayloadBoundaryAcceptsBelowLimitAndRejectsOversizeAttachment() throws {
        let below = MultimodalAttachment(
            type: "image",
            base64: Data(repeating: 0x11, count: 500_000).base64EncodedString(),
            mime: "image/jpeg",
            name: "below.jpg",
            byteSize: 500_000
        )
        let accepted = BridgeMessage.make(
            sender: "ios",
            text: "below boundary",
            attachments: [below]
        )
        _ = try NAChatMessageCodec.encode(accepted)

        let above = MultimodalAttachment(
            type: "image",
            base64: Data(repeating: 0x22, count: 700_000).base64EncodedString(),
            mime: "image/jpeg",
            name: "above.jpg",
            byteSize: 700_000
        )
        let rejected = BridgeMessage.make(
            sender: "ios",
            text: "above boundary",
            attachments: [above]
        )
        do {
            _ = try NAChatMessageCodec.encode(rejected)
            Issue.record("oversized CloudKit payload should have failed before transport")
        } catch let error as DeviceSyncError {
            guard case .payloadTooLarge(let actual, let maximum) = error else {
                Issue.record("unexpected device-sync error: \(error)")
                return
            }
            #expect(actual > maximum)
            #expect(error.localizedDescription.contains("smaller image"))
        }
    }

    @Test func stableIDRetryAcceptsOnlyByteExactServerRecord() throws {
        let message = BridgeMessage.make(
            id: "stable-id",
            sender: "ios",
            text: "retry me",
            sessionID: "s1"
        )
        let intended = try NAChatMessageCodec.encode(message)
        #expect(NAChatMessageCodec.isExactIdempotentReplay(
            existingPayloadJSON: intended.payloadJSON,
            existingDirection: intended.direction,
            intended: intended
        ))
        #expect(!NAChatMessageCodec.isExactIdempotentReplay(
            existingPayloadJSON: intended.payloadJSON + " ",
            existingDirection: intended.direction,
            intended: intended
        ))
        #expect(!NAChatMessageCodec.isExactIdempotentReplay(
            existingPayloadJSON: intended.payloadJSON,
            existingDirection: NAChatDirection.mac2ios.rawValue,
            intended: intended
        ))
    }
}

@Suite("DeviceSyncTransport resolver")
struct DeviceSyncResolverTests {
    @Test func defaultsToKVSWhenUnsetOrUnknown() {
        #expect(DeviceSyncTransportResolver.resolvedKind(environment: [:], infoValue: nil) == .kvs)
        #expect(DeviceSyncTransportResolver.resolvedKind(
            environment: ["NATIVE_AGENT_DEVICE_SYNC": "garbage"], infoValue: nil) == .kvs)
        #expect(DeviceSyncTransportResolver.resolvedKind(
            environment: ["NATIVE_AGENT_DEVICE_SYNC": ""], infoValue: nil) == .kvs)
    }

    @Test func selectsCloudKitWhenRequested() {
        #expect(DeviceSyncTransportResolver.resolvedKind(
            environment: ["NATIVE_AGENT_DEVICE_SYNC": "cloudkit"], infoValue: nil) == .cloudkit)
        #expect(DeviceSyncTransportResolver.resolvedKind(
            environment: ["NATIVE_AGENT_DEVICE_SYNC": "  CloudKit  "], infoValue: nil) == .cloudkit)
        #expect(DeviceSyncTransportResolver.resolvedKind(
            environment: ["NATIVE_AGENT_DEVICE_SYNC": "kvs"], infoValue: nil) == .kvs)
    }

    // CK-4: the baked Info.plist value selects the transport when no env var is
    // set — the iOS/standalone path (iOS can't read a per-process env var).
    @Test func bakedInfoValueSelectsWhenEnvAbsent() {
        #expect(DeviceSyncTransportResolver.resolvedKind(environment: [:], infoValue: "cloudkit") == .cloudkit)
        #expect(DeviceSyncTransportResolver.resolvedKind(environment: [:], infoValue: "  CloudKit ") == .cloudkit)
        #expect(DeviceSyncTransportResolver.resolvedKind(environment: [:], infoValue: "kvs") == .kvs)
        #expect(DeviceSyncTransportResolver.resolvedKind(environment: [:], infoValue: "garbage") == .kvs)
    }

    // Env var wins over the baked value (a test can always override a ship build).
    @Test func envVarOverridesBakedInfoValue() {
        #expect(DeviceSyncTransportResolver.resolvedKind(
            environment: ["NATIVE_AGENT_DEVICE_SYNC": "kvs"], infoValue: "cloudkit") == .kvs)
        #expect(DeviceSyncTransportResolver.resolvedKind(
            environment: ["NATIVE_AGENT_DEVICE_SYNC": "cloudkit"], infoValue: "kvs") == .cloudkit)
        // An EMPTY env var does not override — falls back to the baked value.
        #expect(DeviceSyncTransportResolver.resolvedKind(
            environment: ["NATIVE_AGENT_DEVICE_SYNC": ""], infoValue: "cloudkit") == .cloudkit)
    }

    @Test func cloudKitTransportCanStartWithoutUbiquityContainer() {
        #expect(DeviceSyncTransportResolver.bridgeCanStart(
            cloudKitTransportActive: true,
            ubiquityContainerAvailable: false
        ))
        #expect(DeviceSyncTransportResolver.bridgeCanStart(
            cloudKitTransportActive: false,
            ubiquityContainerAvailable: true
        ))
        #expect(!DeviceSyncTransportResolver.bridgeCanStart(
            cloudKitTransportActive: false,
            ubiquityContainerAvailable: false
        ))
    }
}

@Suite("MockDeviceSyncTransport round trip")
struct MockDeviceSyncTransportTests {
    @Test func iosSendReachesMacObserver() async throws {
        let cloud = MockDeviceCloud()
        let macTransport = MockDeviceSyncTransport(role: .mac, cloud: cloud)
        let iosTransport = MockDeviceSyncTransport(role: .ios, cloud: cloud)

        let inbox = Inbox()
        await macTransport.observeIncoming { message in
            await inbox.append(message)
            return true
        }

        let secret = Data("pair".utf8)
        let sent = try BridgeMessage.make(
            sender: "ios",
            text: "ping from phone",
            sessionID: "s1"
        ).signed(with: secret)
        try await iosTransport.send(sent)

        let dispatched = await macTransport.drainIncoming()
        #expect(dispatched == 1)

        let received = await inbox.messages
        #expect(received.count == 1)
        #expect(received.first?.id == sent.id)
        #expect(received.first?.text == "ping from phone")
        #expect(received.first?.verifySignature(secret: secret) == true)
    }

    @Test func macDoesNotReceiveItsOwnOutboundMessage() async throws {
        let cloud = MockDeviceCloud()
        let macTransport = MockDeviceSyncTransport(role: .mac, cloud: cloud)

        let inbox = Inbox()
        await macTransport.observeIncoming { message in
            await inbox.append(message)
            return true
        }

        // Mac sends → direction mac2ios → NOT inbound for the Mac side.
        try await macTransport.send(BridgeMessage.make(sender: "mac", text: "reply"))
        let dispatched = await macTransport.drainIncoming()

        #expect(dispatched == 0)
        #expect(await inbox.messages.isEmpty)
    }

    @Test func duplicateDrainDoesNotRedeliver() async throws {
        let cloud = MockDeviceCloud()
        let macTransport = MockDeviceSyncTransport(role: .mac, cloud: cloud)
        let iosTransport = MockDeviceSyncTransport(role: .ios, cloud: cloud)

        let inbox = Inbox()
        await macTransport.observeIncoming { message in
            await inbox.append(message)
            return true
        }

        try await iosTransport.send(BridgeMessage.make(sender: "ios", text: "once"))
        _ = await macTransport.drainIncoming()
        let second = await macTransport.drainIncoming()

        #expect(second == 0)
        #expect(await inbox.messages.count == 1)
    }

    @Test func pairingSecretPropagatesToPeer() async throws {
        let cloud = MockDeviceCloud()
        let macTransport = MockDeviceSyncTransport(role: .mac, cloud: cloud)
        let iosTransport = MockDeviceSyncTransport(role: .ios, cloud: cloud)

        let secret = Data("shared-pairing-secret".utf8)
        try await macTransport.publishPairing(secret: secret)

        let box = SecretBox()
        await iosTransport.observePairing { received in
            await box.set(received)
            return true
        }
        #expect(await box.value == secret)
    }

    @Test func canonicalThirtyTwoBytePairingSecretPublishesAndDrainsToIOS() async throws {
        let cloud = MockDeviceCloud()
        let macTransport = MockDeviceSyncTransport(role: .mac, cloud: cloud)
        let iosTransport = MockDeviceSyncTransport(role: .ios, cloud: cloud)
        let secret = Data(repeating: 0xA5, count: 32)

        let box = SecretBox()
        await iosTransport.observePairing { received in
            guard received.count == 32 else { return false }
            await box.set(received)
            return true
        }
        try await macTransport.publishPairing(secret: secret)
        _ = await iosTransport.drainPairing()

        #expect(await box.value == secret)
    }

    @Test func statusPropagatesToPeer() async throws {
        let cloud = MockDeviceCloud()
        let macTransport = MockDeviceSyncTransport(role: .mac, cloud: cloud)
        let iosTransport = MockDeviceSyncTransport(role: .ios, cloud: cloud)

        try await macTransport.setStatus(key: "mac_status", value: "ready")

        let box = StringBox()
        await iosTransport.observeStatus(key: "mac_status") { value in
            await box.set(value)
        }
        #expect(await box.value == "ready")
    }

    // 'observe' must mean ONGOING: a publish AFTER the observer is registered
    // must fire the handler (the CK-1 blind spot this wave fixes).

    @Test func pairingObserveBeforePublishFiresOnLaterPublish() async throws {
        let cloud = MockDeviceCloud()
        let macTransport = MockDeviceSyncTransport(role: .mac, cloud: cloud)
        let iosTransport = MockDeviceSyncTransport(role: .ios, cloud: cloud)

        // Observer registered FIRST — nothing published yet.
        let box = SecretBox()
        await iosTransport.observePairing { received in
            await box.set(received)
            return true
        }
        #expect(await box.value == nil)

        // Peer publishes AFTER — the ongoing observer must fire with the secret.
        let secret = Data("late-pairing-secret".utf8)
        try await macTransport.publishPairing(secret: secret)
        #expect(await box.value == secret)
    }

    @Test func rejectedPairingCommitRemainsEligibleForForegroundRedrain() async throws {
        let cloud = MockDeviceCloud()
        let macTransport = MockDeviceSyncTransport(role: .mac, cloud: cloud)
        let iosTransport = MockDeviceSyncTransport(role: .ios, cloud: cloud)
        let gate = PairingCommitGate()

        await iosTransport.observePairing { secret in
            await gate.attempt(secret)
        }
        let secret = Data(repeating: 0x3C, count: 32)
        try await macTransport.publishPairing(secret: secret)
        #expect(await gate.attemptCount == 1)
        #expect(await gate.committedSecret == nil)

        await gate.allowCommit()
        #expect(await iosTransport.drainPairing())
        #expect(await gate.attemptCount == 2)
        #expect(await gate.committedSecret == secret)
        #expect(await iosTransport.drainPairing() == false)
    }

    @Test func statusObserveBeforePublishFiresOnLaterWrite() async throws {
        let cloud = MockDeviceCloud()
        let macTransport = MockDeviceSyncTransport(role: .mac, cloud: cloud)
        let iosTransport = MockDeviceSyncTransport(role: .ios, cloud: cloud)

        // Observer registered FIRST — nothing written yet.
        let box = StringBox()
        await iosTransport.observeStatus(key: "mac_status") { value in
            await box.set(value)
        }
        #expect(await box.value == nil)

        // Peer writes AFTER — the ongoing observer must fire with the value.
        try await macTransport.setStatus(key: "mac_status", value: "typing")
        #expect(await box.value == "typing")
    }

    // A rejected handler (returns false) must NOT have its message skipped — the
    // cursor cannot advance past an undelivered inbound record (the CK-1
    // message-loss guarantee), asserted through the mock now that it mirrors
    // CloudKitDeviceTransport.drainIncoming's halt semantics.
    @Test func rejectedMessageIsRedeliveredNotLost() async throws {
        let cloud = MockDeviceCloud()
        let macTransport = MockDeviceSyncTransport(role: .mac, cloud: cloud)
        let iosTransport = MockDeviceSyncTransport(role: .ios, cloud: cloud)

        let gate = DeliveryGate()
        let inbox = Inbox()
        await macTransport.observeIncoming { message in
            guard await gate.isOpen else { return false }   // reject until opened
            await inbox.append(message)
            return true
        }

        try await iosTransport.send(BridgeMessage.make(sender: "ios", text: "must-not-drop"))
        let rejected = await macTransport.drainIncoming()
        #expect(rejected == 0)
        #expect(await inbox.messages.isEmpty)

        await gate.open()   // the previously-rejected message must redeliver
        let delivered = await macTransport.drainIncoming()
        #expect(delivered == 1)
        #expect(await inbox.messages.first?.text == "must-not-drop")
    }
}

// MARK: - CloudKit crash-guard (the 2026-06-03 _os_crash defense)

#if canImport(CloudKit) && !os(Linux)
@Suite("CloudKitDeviceTransport pull cursor")
struct CloudKitDeviceTransportPullCursorTests {
    private let now = Date(timeIntervalSince1970: 2_000_000)

    @Test func establishedIdleCursorSlidesWithSafetyOverlap() {
        let previous = now.addingTimeInterval(-86_400)
        let next = CloudKitDeviceTransport.nextPullCursor(
            previousCursor: previous,
            queryStartedAt: now,
            safeRecordDate: nil,
            halted: false
        )
        #expect(next == now.addingTimeInterval(-30))
    }

    @Test func firstEverEmptyPullRetainsBootstrapCursor() {
        let next = CloudKitDeviceTransport.nextPullCursor(
            previousCursor: nil,
            queryStartedAt: now,
            safeRecordDate: nil,
            halted: false
        )
        #expect(next == nil)
    }

    @Test func rejectedFirstRecordCannotAdvanceCursor() {
        let previous = now.addingTimeInterval(-120)
        let next = CloudKitDeviceTransport.nextPullCursor(
            previousCursor: previous,
            queryStartedAt: now,
            safeRecordDate: nil,
            halted: true
        )
        #expect(next == previous)
    }

    @Test func cursorNeverRegressesWhilePreservingOverlap() {
        let previous = now.addingTimeInterval(-20)
        let safeRecord = now.addingTimeInterval(-10)
        let next = CloudKitDeviceTransport.nextPullCursor(
            previousCursor: previous,
            queryStartedAt: now,
            safeRecordDate: safeRecord,
            halted: true
        )
        #expect(next == previous)
    }
}

// An UNCONFIGURED CloudKitDeviceTransport (CloudKit entitlement absent) must
// NEVER construct a CKContainer. `CKContainer.__allocating_init` traps
// synchronously (AMFI hard-kill, exit 137) when CloudKit isn't entitled — so if
// any of these methods actually reached the constructor, THIS TEST PROCESS
// would die. A passing run is therefore itself the proof that every entry point
// short-circuits before touching CloudKit. Every case here uses `configured:
// false`; the throwing methods must throw `.notConfigured`, the drains must
// return their empty defaults, and `accountStatus` must report "notConfigured".
@Suite("CloudKitDeviceTransport crash-guard")
struct CloudKitCrashGuardTests {
    private func unconfigured(_ role: NADeviceRole = .mac) -> CloudKitDeviceTransport {
        CloudKitDeviceTransport(role: role, containerIdentifier: "iCloud.example.test", configured: false)
    }

    @Test func unconfiguredSendThrowsNotConfigured() async {
        do {
            try await unconfigured().send(BridgeMessage.make(sender: "mac", text: "x"))
            Issue.record("send should have thrown .notConfigured before touching CKContainer")
        } catch let e as DeviceSyncError {
            #expect(e.isNotConfigured)
        } catch {
            Issue.record("unexpected error type: \(error)")
        }
    }

    @Test func unconfiguredPublishPairingThrowsNotConfigured() async {
        do {
            try await unconfigured().publishPairing(secret: Data("s".utf8))
            Issue.record("publishPairing should have thrown .notConfigured")
        } catch let e as DeviceSyncError {
            #expect(e.isNotConfigured)
        } catch {
            Issue.record("unexpected error type: \(error)")
        }
    }

    @Test func unconfiguredSetStatusThrowsNotConfigured() async {
        do {
            try await unconfigured().setStatus(key: "k", value: "v")
            Issue.record("setStatus should have thrown .notConfigured")
        } catch let e as DeviceSyncError {
            #expect(e.isNotConfigured)
        } catch {
            Issue.record("unexpected error type: \(error)")
        }
    }

    @Test func unconfiguredSubscribeThrowsNotConfigured() async {
        do {
            try await unconfigured().subscribeToChanges()
            Issue.record("subscribeToChanges should have thrown .notConfigured")
        } catch let e as DeviceSyncError {
            #expect(e.isNotConfigured)
        } catch {
            Issue.record("unexpected error type: \(error)")
        }
    }

    // The other two public subscribe entry points funnel through the same
    // registerBroadSubscription guard — assert them directly so the "every
    // public method is proven crash-safe" claim is literally complete.
    @Test func unconfiguredSubscribePairingThrowsNotConfigured() async {
        do {
            try await unconfigured().subscribeToPairingChanges()
            Issue.record("subscribeToPairingChanges should have thrown .notConfigured")
        } catch let e as DeviceSyncError {
            #expect(e.isNotConfigured)
        } catch {
            Issue.record("unexpected error type: \(error)")
        }
    }

    @Test func unconfiguredSubscribeStatusThrowsNotConfigured() async {
        do {
            try await unconfigured().subscribeToStatusChanges()
            Issue.record("subscribeToStatusChanges should have thrown .notConfigured")
        } catch let e as DeviceSyncError {
            #expect(e.isNotConfigured)
        } catch {
            Issue.record("unexpected error type: \(error)")
        }
    }

    @Test func unconfiguredDrainsAndAccountReturnSafeDefaults() async {
        let t = unconfigured()
        #expect(await t.drainIncoming() == 0)
        #expect(await t.drainPairing() == false)
        #expect(await t.drainStatus() == 0)
        #expect(await t.accountStatus() == "notConfigured")
    }

    @Test func unconfiguredObserveIsNoOpAndNeverSubscribes() async {
        let t = unconfigured()
        // observe* must return without subscribing (no CKContainer). A follow-up
        // drain still returns empty — nothing was registered or fetched.
        await t.observeIncoming { _ in true }
        await t.observePairing { _ in true }
        await t.observeStatus(key: "mac_status") { _ in }
        #expect(await t.drainIncoming() == 0)
        #expect(await t.drainStatus() == 0)
    }

    // The safe factory: it degrades to nil (legacy transport) rather than ever
    // handing back a transport that would trap.

    @Test func factoryReturnsNilForKVSSelection() {
        let t = DeviceSyncTransportResolver.makeCloudKitTransport(
            role: .mac, containerIdentifier: "iCloud.example.test",
            environment: ["NATIVE_AGENT_DEVICE_SYNC": "kvs"],
            hasEntitlement: { true })
        #expect(t == nil)
    }

    @Test func factoryDegradesToNilWhenEntitlementAbsent() {
        // cloudkit selected, but entitlement missing → nil (stay on legacy),
        // NOT a trapping transport.
        let t = DeviceSyncTransportResolver.makeCloudKitTransport(
            role: .mac, containerIdentifier: "iCloud.example.test",
            environment: ["NATIVE_AGENT_DEVICE_SYNC": "cloudkit"],
            hasEntitlement: { false })
        #expect(t == nil)
    }

    @Test func factoryBuildsTransportWhenSelectedAndGranted() {
        // cloudkit selected AND entitled → a real transport is returned. It is
        // constructed but NOT exercised here (construction stores strings only;
        // no CKContainer until a method runs), so this stays crash-safe.
        let t = DeviceSyncTransportResolver.makeCloudKitTransport(
            role: .mac, containerIdentifier: "iCloud.example.test",
            environment: ["NATIVE_AGENT_DEVICE_SYNC": "cloudkit"],
            hasEntitlement: { true })
        #expect(t != nil)
        #expect(t?.role == .mac)
    }

    @Test func productionSubscriptionRejectionCannotMasqueradeAsAlreadyExisting() throws {
        let testFile = URL(fileURLWithPath: #filePath)
        let sourceFile = testFile
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .appendingPathComponent("Sources/NativeAgentShared/CloudKitDeviceTransport.swift")
        let source = try String(contentsOf: sourceFile, encoding: .utf8)

        #expect(source.contains("database.subscription(for: id)"))
        #expect(source.contains("Self.subscription(existing, matches: subscription)"))
        #expect(!source.contains("case .serverRejectedRequest"))
    }

    @Test func deviceSyncSubscriptionsAreUserLevelAndRecognizeExactLegacyIDs() {
        #expect(DeviceCloudKitSubscriptionID.current == [
            "NAChatMessage.incoming",
            "NANotification.visible",
            "NAPairingDevice.changes",
            "NAStatus.changes",
        ])
        #expect(DeviceCloudKitSubscriptionID.current.allSatisfy {
            !$0.hasSuffix(".mac") && !$0.hasSuffix(".ios")
        })
        #expect(DeviceCloudKitSubscriptionID.current.allSatisfy(
            DeviceCloudKitSubscriptionID.recognizes
        ))
        #expect(DeviceCloudKitSubscriptionID.legacy.allSatisfy(
            DeviceCloudKitSubscriptionID.recognizes
        ))
        #expect(!DeviceCloudKitSubscriptionID.recognizes("NAChatMessage.attacker"))
        #expect(!DeviceCloudKitSubscriptionID.recognizes("NAStatus.changes.extra"))
    }

    @Test func visibleNotificationSubscriptionIsHighPriorityAndEventScoped() throws {
        let subscription = CloudKitDeviceTransport.makeVisibleNotificationSubscription()
        let info = try #require(subscription.notificationInfo)

        #expect(subscription.subscriptionID == "NANotification.visible")
        #expect(subscription.recordType == NADeviceSyncRecordType.notification)
        #expect(subscription.predicate.predicateFormat == "TRUEPREDICATE")
        #expect(info.alertLocalizationKey == "NATIVEAGENT_CLOUDKIT_NOTIFICATION_BODY_FORMAT")
        #expect(info.alertLocalizationArgs == ["text"])
        #expect(info.titleLocalizationKey == "NATIVEAGENT_CLOUDKIT_NOTIFICATION_TITLE_FORMAT")
        #expect(info.titleLocalizationArgs == ["notificationTitle"])
        #expect(info.soundName == "default")
        #expect(info.shouldSendContentAvailable == false)
        #expect(info.collapseIDKey == "notificationEventId")
        #expect((info.desiredKeys ?? []).count <= 3)
        #expect(Set(info.desiredKeys ?? []) == Set([
            "notificationScreen",
            "notificationEventId",
            "kind",
        ]))
    }

    @Test func visualNotificationCapabilityRejectsStaleContracts() {
        #expect(NAVisualNotificationCapability.isReady(
            NAVisualNotificationCapability.encoded(ready: true)
        ))
        #expect(!NAVisualNotificationCapability.isReady(
            NAVisualNotificationCapability.encoded(ready: false)
        ))
        #expect(!NAVisualNotificationCapability.isReady("nanotification-v1:ready"))
    }

    @Test func silentChatSubscriptionRemainsSchemaIndependent() throws {
        let silent = CloudKitDeviceTransport.makeSilentChatSubscription()
        let visible = CloudKitDeviceTransport.makeVisibleNotificationSubscription()
        let silentInfo = try #require(silent.notificationInfo)
        let visibleInfo = try #require(visible.notificationInfo)

        // This broad wire predicate is compatible with legacy records and does
        // not depend on a queryable optional field in Production CloudKit.
        #expect(silent.predicate.predicateFormat == "TRUEPREDICATE")
        #expect(silent.recordType == NADeviceSyncRecordType.chatMessage)
        #expect(visible.recordType == NADeviceSyncRecordType.notification)
        #expect(visible.predicate.predicateFormat == "TRUEPREDICATE")
        #expect(silentInfo.shouldSendContentAvailable)
        #expect(silentInfo.alertLocalizationKey == nil)
        #expect(!visibleInfo.shouldSendContentAvailable)
        #expect(visibleInfo.alertLocalizationKey != nil)
    }

    @Test func staleSameIDSubscriptionCannotMasqueradeAsVisibleAlert() {
        let expected = CloudKitDeviceTransport.makeVisibleNotificationSubscription()
        #expect(CloudKitDeviceTransport.subscription(expected, matches: expected))

        let stale = CKQuerySubscription(
            recordType: NADeviceSyncRecordType.chatMessage,
            predicate: NSPredicate(format: "kind == %@", "notification"),
            subscriptionID: "NANotification.visible",
            options: [.firesOnRecordCreation]
        )
        let staleInfo = CKSubscription.NotificationInfo()
        staleInfo.shouldSendContentAvailable = true
        stale.notificationInfo = staleInfo

        #expect(!CloudKitDeviceTransport.subscription(stale, matches: expected))
    }

    @Test func notificationRecordsCannotOverlapTheSilentChatSubscription() throws {
        let ordinary = try NAChatMessageCodec.encode(
            BridgeMessage.make(sender: "mac", text: "hello")
        )
        let notification = try NAChatMessageCodec.encode(
            BridgeMessage.make(
                sender: "mac",
                text: "done",
                metadata: ["kind": "notification"]
            )
        )

        #expect(CloudKitDeviceTransport.recordType(for: ordinary) == NADeviceSyncRecordType.chatMessage)
        #expect(CloudKitDeviceTransport.recordType(for: notification) == NADeviceSyncRecordType.notification)
        #expect(
            CloudKitDeviceTransport.makeSilentChatSubscription().recordType
                != CloudKitDeviceTransport.makeVisibleNotificationSubscription().recordType
        )
        #expect(DeviceCloudKitSubscriptionID.legacy.contains("NAChatMessage.notifications.visible"))
    }
}
#endif

// MARK: - Test actors (Sendable accumulators)

private actor Inbox {
    private(set) var messages: [BridgeMessage] = []
    func append(_ m: BridgeMessage) { messages.append(m) }
}

private actor SecretBox {
    private(set) var value: Data?
    func set(_ v: Data) { value = v }
}

private actor StringBox {
    private(set) var value: String?
    func set(_ v: String) { value = v }
}

private actor DeliveryGate {
    private(set) var isOpen = false
    func open() { isOpen = true }
}

private actor PairingCommitGate {
    private(set) var attemptCount = 0
    private(set) var committedSecret: Data?
    private var canCommit = false

    func allowCommit() {
        canCommit = true
    }

    func attempt(_ secret: Data) -> Bool {
        attemptCount += 1
        guard canCommit else { return false }
        committedSecret = secret
        return true
    }
}
