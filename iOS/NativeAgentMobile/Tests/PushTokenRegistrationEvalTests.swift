import XCTest
@testable import NativeAgentMobile

/// Executable fence for `ios.sync / ios.sync.registerPushToken`.
@MainActor
final class PushTokenRegistrationEvalTests: XCTestCase {
    func test_blankTokenThrowsBeforeItCanBeMarkedAsASyncedRegistration() async {
        do {
            _ = try await iCloudSyncEngine.shared.registerPushToken(
                token: " \n ",
                environment: "development",
                bundleId: "com.example.nativeagent.mobile",
                deviceId: "phone-eval"
            )
            XCTFail("A blank APNS token must not look like a successful registration")
        } catch SyncError.unsupported(let message) {
            XCTAssertEqual(message, "Missing APNS device token")
        } catch {
            XCTFail("Unexpected error: \(error)")
        }
    }

    func test_onlyFreshCacheEntriesSuppressAnotherRegistrationAttempt() {
        let suite = "NativeAgentMobile.PushTokenRegistrationEvalTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defaults.removePersistentDomain(forName: suite)
        defer { defaults.removePersistentDomain(forName: suite) }

        let cache = NativeAgentPushTokenSyncCache(defaults: defaults)
        let pairing = NativeAgentPushTokenSyncCache.pairingIdentity(
            secret: Data("pairing-secret".utf8),
            secretVersion: 1
        )
        let fingerprint = NativeAgentPushTokenSyncCache.fingerprint(
            token: "apns-token",
            environment: "development",
            bundleId: "com.example.nativeagent.mobile",
            deviceId: "phone-eval",
            pairing: pairing
        )
        let registeredAt = Date(timeIntervalSinceReferenceDate: 1_000)

        cache.markSynced(fingerprint, now: registeredAt)

        XCTAssertFalse(cache.shouldSync(fingerprint, now: registeredAt.addingTimeInterval(1)))
        XCTAssertTrue(cache.hasFreshSyncedRegistration(pairing: pairing, now: registeredAt.addingTimeInterval(1)))
        XCTAssertFalse(
            cache.hasFreshSyncedRegistration(
                pairing: pairing,
                now: registeredAt.addingTimeInterval(
                    NativeAgentPushTokenSyncCache.registrationRefreshInterval + 1
                )
            )
        )
        XCTAssertTrue(
            cache.shouldSync(
                fingerprint,
                now: registeredAt.addingTimeInterval(
                    NativeAgentPushTokenSyncCache.registrationRefreshInterval + 1
                )
            )
        )
    }
}
