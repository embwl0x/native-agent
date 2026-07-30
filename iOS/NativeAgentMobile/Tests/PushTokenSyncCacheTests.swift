import XCTest
import NativeAgentShared
@testable import NativeAgentMobile

final class PushTokenSyncCacheTests: XCTestCase {
    private func makeCache() -> (String, NativeAgentPushTokenSyncCache) {
        let suite = "NativeAgentMobile.PushTokenSyncCacheTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defaults.removePersistentDomain(forName: suite)
        return (suite, NativeAgentPushTokenSyncCache(defaults: defaults))
    }

    private func pairing(_ version: Int64 = 1, secret: String = "secret") -> NativeAgentPushTokenSyncCache.PairingIdentity {
        NativeAgentPushTokenSyncCache.pairingIdentity(
            secret: Data(secret.utf8),
            secretVersion: version
        )
    }

    private func fingerprint(
        token: String = "token-a",
        pairing: NativeAgentPushTokenSyncCache.PairingIdentity
    ) -> NativeAgentPushTokenSyncCache.Fingerprint {
        NativeAgentPushTokenSyncCache.fingerprint(
            token: token,
            environment: "development",
            bundleId: "com.example.nativeagent.mobile",
            deviceId: "phone-1",
            pairing: pairing
        )
    }

    func test_unchanged_recent_token_does_not_need_mac_sync() {
        let (suite, cache) = makeCache()
        defer { UserDefaults.standard.removePersistentDomain(forName: suite) }
        let pairing = pairing()
        let fingerprint = fingerprint(pairing: pairing)
        let now = Date()

        cache.markSynced(fingerprint, now: now)

        XCTAssertFalse(cache.shouldSync(fingerprint))
        XCTAssertTrue(cache.hasFreshSyncedRegistration(pairing: pairing, now: now.addingTimeInterval(60)))
    }

    func test_unchanged_token_refreshes_mac_sync_after_short_interval() {
        let (suite, cache) = makeCache()
        defer { UserDefaults.standard.removePersistentDomain(forName: suite) }
        let pairing = pairing()
        let fingerprint = fingerprint(pairing: pairing)
        let now = Date()

        cache.markSynced(fingerprint, now: now)

        let stale = now.addingTimeInterval(NativeAgentPushTokenSyncCache.tokenSyncRefreshInterval + 1)
        XCTAssertTrue(cache.shouldSync(fingerprint, now: stale))
    }

    func test_token_change_requires_sync() {
        let (suite, cache) = makeCache()
        defer { UserDefaults.standard.removePersistentDomain(forName: suite) }
        let pairing = pairing()
        cache.markSynced(fingerprint(token: "token-a", pairing: pairing))

        XCTAssertTrue(cache.shouldSync(fingerprint(token: "token-b", pairing: pairing)))
    }

    func test_pairing_change_requires_registration() {
        let (suite, cache) = makeCache()
        defer { UserDefaults.standard.removePersistentDomain(forName: suite) }
        let oldPairing = pairing(1, secret: "old-secret")
        let newPairing = pairing(2, secret: "new-secret")
        cache.markSynced(fingerprint(pairing: oldPairing))

        XCTAssertFalse(cache.hasFreshSyncedRegistration(pairing: newPairing))
        XCTAssertTrue(cache.shouldSync(fingerprint(pairing: newPairing)))
    }

    func test_stale_registration_requires_refresh() {
        let (suite, cache) = makeCache()
        defer { UserDefaults.standard.removePersistentDomain(forName: suite) }
        let pairing = pairing()
        let now = Date()
        cache.markSynced(fingerprint(pairing: pairing), now: now)

        let staleTime = now.addingTimeInterval(NativeAgentPushTokenSyncCache.registrationRefreshInterval + 1)

        XCTAssertFalse(cache.hasFreshSyncedRegistration(pairing: pairing, now: staleTime))
    }

    func test_apns_environment_comes_from_embedded_profile_entitlement() throws {
        let profile = try makeProvisioningProfile(apsEnvironment: "production")

        let resolution = NativeAgentAPNSEnvironmentResolver.resolve(
            embeddedProfileData: profile,
            embeddedProfilePresent: true
        )

        XCTAssertEqual(resolution?.environment, .production)
        XCTAssertEqual(resolution?.source, .embeddedProvisioningProfile)
    }

    func test_missing_embedded_profile_is_distribution_production() {
        let resolution = NativeAgentAPNSEnvironmentResolver.resolve(
            embeddedProfileData: nil,
            embeddedProfilePresent: false
        )

        XCTAssertEqual(resolution?.environment, .production)
        XCTAssertEqual(resolution?.source, .distributionWithoutEmbeddedProfile)
    }

    func test_present_but_unreadable_profile_fails_closed() {
        XCTAssertNil(NativeAgentAPNSEnvironmentResolver.resolve(
            embeddedProfileData: Data("not a profile".utf8),
            embeddedProfilePresent: true
        ))
    }

    func test_deviceSourceKeyNormalizationIsStableForRouting() {
        XCTAssertEqual(
            ChatRuntimeControls.makeDeviceSourceKey(deviceName: "  User's iPhone  "),
            "iphone:User's iPhone"
        )
        XCTAssertEqual(ChatRuntimeControls.makeDeviceSourceKey(deviceName: " \n "), "iphone")
    }

    private func makeProvisioningProfile(apsEnvironment: String) throws -> Data {
        let plist: [String: Any] = [
            "Entitlements": ["aps-environment": apsEnvironment]
        ]
        let xml = try PropertyListSerialization.data(fromPropertyList: plist, format: .xml, options: 0)
        var profile = Data([0x30, 0x82, 0x01, 0x00])
        profile.append(xml)
        profile.append(Data([0x00, 0x01]))
        return profile
    }
}

@MainActor
final class ProviderCatalogCloudKitProjectionTests: XCTestCase {
    func test_cloudkit_catalog_replaces_stale_gpt_fallback_with_mac_provider() throws {
        let engine = iCloudSyncEngine.shared
        let priorProviders = engine.providers
        let priorSurfaces = engine.surfaceModels
        let priorLastSyncAt = engine.lastSyncAt
        let priorSyncError = engine.syncError
        defer {
            engine.providers = priorProviders
            engine.surfaceModels = priorSurfaces
            engine.lastSyncAt = priorLastSyncAt
            engine.syncError = priorSyncError
        }

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
        engine.providers = []
        engine.surfaceModels = [
            "ios": SurfaceModelPref(model: "gpt-5.6-sol")
        ]

        XCTAssertTrue(
            engine.applyProviderCatalogStatus(
                try NAProviderCatalogStatusCodec.encode(catalog)
            )
        )
        XCTAssertEqual(engine.providers.map(\.provider_id), ["anthropic_oauth_direct"])
        XCTAssertEqual(engine.providers.first?.models.map(\.id), ["claude-opus-5"])
        XCTAssertEqual(engine.surfaceModels["ios"]?.providerId, "anthropic_oauth_direct")
        XCTAssertEqual(engine.surfaceModels["ios"]?.model, "claude-opus-5")
    }

    func test_malformed_catalog_keeps_last_proven_provider_state() {
        let engine = iCloudSyncEngine.shared
        let priorProviders = engine.providers
        let priorSurfaces = engine.surfaceModels
        let priorLastSyncAt = engine.lastSyncAt
        let priorSyncError = engine.syncError
        defer {
            engine.providers = priorProviders
            engine.surfaceModels = priorSurfaces
            engine.lastSyncAt = priorLastSyncAt
            engine.syncError = priorSyncError
        }
        let existing = priorProviders
        let existingSurfaces = priorSurfaces

        XCTAssertFalse(engine.applyProviderCatalogStatus("{not-json"))
        XCTAssertEqual(engine.providers, existing)
        XCTAssertEqual(engine.surfaceModels, existingSurfaces)
    }
}

@MainActor
final class ICloudSnapshotFreshnessTests: XCTestCase {
    func test_ubiquitous_snapshot_requires_current_version() {
        XCTAssertTrue(iCloudSyncEngine.acceptsSnapshotReplica(
            isUbiquitous: false,
            hasCurrentVersion: nil
        ))
        XCTAssertTrue(iCloudSyncEngine.acceptsSnapshotReplica(
            isUbiquitous: true,
            hasCurrentVersion: true
        ))
        XCTAssertFalse(iCloudSyncEngine.acceptsSnapshotReplica(
            isUbiquitous: true,
            hasCurrentVersion: false
        ))
        XCTAssertFalse(iCloudSyncEngine.acceptsSnapshotReplica(
            isUbiquitous: true,
            hasCurrentVersion: nil
        ))
    }

    func test_lightweight_refresh_applies_model_preferences_without_fabricating_full_freshness() async throws {
        let engine = iCloudSyncEngine.shared
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("NativeAgentMobile.snapshot-freshness.\(UUID().uuidString)")
        let snapshots = root.appendingPathComponent("snapshots")
        try FileManager.default.createDirectory(at: snapshots, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }

        let previousSnapshotDir = engine.snapshotDir
        let previousSurfaceModels = engine.surfaceModels
        let previousLastSyncAt = engine.lastSyncAt
        let previousSyncError = engine.syncError
        let previousRefreshInFlight = engine.refreshInFlight
        let previousRefreshQueued = engine.refreshQueued
        defer {
            engine.snapshotDir = previousSnapshotDir
            engine.surfaceModels = previousSurfaceModels
            engine.lastSyncAt = previousLastSyncAt
            engine.syncError = previousSyncError
            engine.refreshInFlight = previousRefreshInFlight
            engine.refreshQueued = previousRefreshQueued
        }

        let preferences = [
            "ios": SurfaceModelPref(
                model: "gpt-5.6-sol",
                reasoningEffort: "high",
                serviceTier: "default"
            )
        ]
        let data = try JSONEncoder().encode(preferences)
        try data.write(to: snapshots.appendingPathComponent("model_preferences.json"))

        let provenAt = Date(timeIntervalSince1970: 1_700_000_000)
        engine.snapshotDir = snapshots
        engine.surfaceModels = [:]
        engine.lastSyncAt = provenAt
        engine.syncError = nil
        engine.refreshInFlight = false
        engine.refreshQueued = false

        await engine.refreshLightweightSnapshots()

        XCTAssertEqual(engine.surfaceModels["ios"], preferences["ios"])
        XCTAssertEqual(engine.lastSyncAt, provenAt)
        XCTAssertEqual(
            engine.syncError,
            "Some lightweight iCloud snapshots are still downloading."
        )
    }
}

final class ICloudLegacyReplyArchiveTests: XCTestCase {
    func test_archive_is_bounded_and_does_not_touch_processed_root_files() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("NativeAgentMobile.reply-retention.\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: root) }
        let outbox = root.appendingPathComponent("outbox")
        let processed = root.appendingPathComponent("processed")
        try FileManager.default.createDirectory(at: outbox, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: processed, withIntermediateDirectories: true)
        let unrelatedLedger = processed.appendingPathComponent("ios_chat_processed_ids.json")
        try Data("[]".utf8).write(to: unrelatedLedger)
        let now = Date()

        for index in 0..<(ICloudLegacyReplyArchive.maximumFileCount + 3) {
            let source = outbox.appendingPathComponent("reply-\(index).json")
            try Data("{}".utf8).write(to: source)
            let date = now.addingTimeInterval(TimeInterval(index))
            try FileManager.default.setAttributes([.modificationDate: date], ofItemAtPath: source.path)
            ICloudLegacyReplyArchive.archive(source, processedRoot: processed)
        }

        let archive = processed.appendingPathComponent(ICloudLegacyReplyArchive.folderName)
        ICloudLegacyReplyArchive.prune(archiveDirectory: archive, now: now.addingTimeInterval(300))
        let archived = try FileManager.default.contentsOfDirectory(at: archive, includingPropertiesForKeys: nil)
        XCTAssertEqual(archived.count, ICloudLegacyReplyArchive.maximumFileCount)
        XCTAssertTrue(FileManager.default.fileExists(atPath: unrelatedLedger.path))
        XCTAssertFalse(archived.contains { $0.lastPathComponent == "reply-0.json" })
        XCTAssertFalse(archived.contains { $0.lastPathComponent == "reply-1.json" })
        XCTAssertFalse(archived.contains { $0.lastPathComponent == "reply-2.json" })
    }

    func test_prune_removes_expired_reply_archives() throws {
        let archive = FileManager.default.temporaryDirectory
            .appendingPathComponent("NativeAgentMobile.reply-expiry.\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: archive) }
        try FileManager.default.createDirectory(at: archive, withIntermediateDirectories: true)
        let now = Date()
        let expired = archive.appendingPathComponent("expired.json")
        let current = archive.appendingPathComponent("current.json")
        try Data().write(to: expired)
        try Data().write(to: current)
        try FileManager.default.setAttributes(
            [.modificationDate: now.addingTimeInterval(-ICloudLegacyReplyArchive.maximumAge - 1)],
            ofItemAtPath: expired.path
        )

        XCTAssertEqual(ICloudLegacyReplyArchive.prune(archiveDirectory: archive, now: now), 1)
        XCTAssertFalse(FileManager.default.fileExists(atPath: expired.path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: current.path))
    }
}
