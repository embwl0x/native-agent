import CryptoKit
import Foundation
import XCTest
import Security
@testable import NativeAgentMobile

@MainActor
final class CloudKitPairingBoundaryTests: XCTestCase {
    private let suppressionKey = "mobile.pairing.ignoredCloudKitSecretHash"

    func testCloudKitPairingRejectsNonCanonicalSecretLengths() {
        let store = PairingStore()
        let previousSecret = store.iCloudPairingSecret
        let previousPaired = store.isICloudPaired
        let previousSuppression = UserDefaults.standard.object(forKey: suppressionKey)
        UserDefaults.standard.removeObject(forKey: suppressionKey)
        defer {
            store.iCloudPairingSecret = previousSecret
            store.isICloudPaired = previousPaired
            restoreSuppression(previousSuppression)
        }

        XCTAssertFalse(store.applyCloudKitPairingSecret(Data(repeating: 1, count: 31)))
        XCTAssertEqual(store.iCloudPairingSecret, previousSecret)

        XCTAssertFalse(store.applyCloudKitPairingSecret(Data(repeating: 1, count: 33)))
        XCTAssertEqual(store.iCloudPairingSecret, previousSecret)
    }

    func testCloudKitPairingChangesPublishedStateOnlyAfterKeychainCommit() {
        let store = PairingStore()
        let previousSecret = store.iCloudPairingSecret
        let previousPaired = store.isICloudPaired
        let previousSuppression = UserDefaults.standard.object(forKey: suppressionKey)
        UserDefaults.standard.removeObject(forKey: suppressionKey)
        let secret = Data(repeating: 0x5A, count: 32)
        defer {
            store.iCloudPairingSecret = previousSecret
            store.isICloudPaired = previousPaired
            restoreSuppression(previousSuppression)
        }

        XCTAssertFalse(store.applyCloudKitPairingSecret(secret) { _ in errSecInteractionNotAllowed })
        XCTAssertEqual(store.iCloudPairingSecret, previousSecret)
        XCTAssertEqual(store.isICloudPaired, previousPaired)

        XCTAssertTrue(store.applyCloudKitPairingSecret(secret) { _ in errSecSuccess })
        XCTAssertEqual(store.iCloudPairingSecret, secret)
        XCTAssertTrue(store.isICloudPaired)
        XCTAssertTrue(store.isPaired)
    }

    func testClearIgnoresSameSecretButAllowsRotatedSecret() {
        let store = PairingStore()
        let previousSecret = store.iCloudPairingSecret
        let previousPaired = store.isICloudPaired
        let previousSuppression = UserDefaults.standard.object(forKey: suppressionKey)
        let oldSecret = Data(repeating: 0x41, count: 32)
        let rotatedSecret = Data(repeating: 0x42, count: 32)
        defer {
            store.iCloudPairingSecret = previousSecret
            store.isICloudPaired = previousPaired
            restoreSuppression(previousSuppression)
        }

        UserDefaults.standard.removeObject(forKey: suppressionKey)
        store.iCloudPairingSecret = oldSecret
        store.isICloudPaired = true
        XCTAssertTrue(store.clearPairing { errSecSuccess })

        XCTAssertFalse(store.shouldAcceptCloudKitPairingSecret(oldSecret))
        XCTAssertTrue(store.shouldAcceptCloudKitPairingSecret(rotatedSecret))
    }

    func testClearFailurePreservesPublishedStateAndSuppression() {
        let store = PairingStore()
        let previousSecret = store.iCloudPairingSecret
        let previousPaired = store.isICloudPaired
        let previousSuppression = UserDefaults.standard.object(forKey: suppressionKey)
        let oldSecret = Data(repeating: 0x45, count: 32)
        defer {
            store.iCloudPairingSecret = previousSecret
            store.isICloudPaired = previousPaired
            restoreSuppression(previousSuppression)
        }

        UserDefaults.standard.removeObject(forKey: suppressionKey)
        store.iCloudPairingSecret = oldSecret
        store.isICloudPaired = true

        XCTAssertFalse(store.clearPairing { errSecInteractionNotAllowed })
        XCTAssertEqual(store.iCloudPairingSecret, oldSecret)
        XCTAssertTrue(store.isICloudPaired)
        XCTAssertNil(UserDefaults.standard.string(forKey: suppressionKey))
    }

    func testUpdateFailureNeverDeletesOrReplacesExistingSecret() {
        let old = Data(repeating: 0x11, count: 32)
        let replacement = Data(repeating: 0x22, count: 32)
        var durable: Data? = old
        var addCalled = false

        let status = PairingStore.persistSecretTransaction(
            replacement,
            read: { durable.map { (errSecSuccess, $0) } ?? (errSecItemNotFound, nil) },
            update: { _ in errSecInteractionNotAllowed },
            add: { value in addCalled = true; durable = value; return errSecSuccess }
        )

        XCTAssertEqual(status, errSecInteractionNotAllowed)
        XCTAssertEqual(durable, old)
        XCTAssertFalse(addCalled)
    }

    func testMissingItemAddsAndRequiresExactReadBack() {
        let replacement = Data(repeating: 0x33, count: 32)
        var durable: Data?
        let status = PairingStore.persistSecretTransaction(
            replacement,
            read: { durable.map { (errSecSuccess, $0) } ?? (errSecItemNotFound, nil) },
            update: { value in durable = value; return errSecSuccess },
            add: { value in durable = value; return errSecSuccess }
        )
        XCTAssertEqual(status, errSecSuccess)
        XCTAssertEqual(durable, replacement)

        durable = nil
        let failedReadBack = PairingStore.persistSecretTransaction(
            replacement,
            read: { durable.map { (errSecSuccess, $0) } ?? (errSecItemNotFound, nil) },
            update: { value in durable = value; return errSecSuccess },
            add: { _ in errSecSuccess }
        )
        XCTAssertEqual(failedReadBack, errSecDecode)
        XCTAssertNil(durable)
    }

    func testDeleteFailurePreservesDurableSecret() {
        let old = Data(repeating: 0x44, count: 32)
        let durable: Data? = old
        let status = PairingStore.deleteSecretTransaction(
            read: { durable.map { (errSecSuccess, $0) } ?? (errSecItemNotFound, nil) },
            delete: { errSecInteractionNotAllowed }
        )
        XCTAssertEqual(status, errSecInteractionNotAllowed)
        XCTAssertEqual(durable, old)
    }

    func testKVSPairingAcceptsOnlyFreshExact32ByteMaterial() {
        let secret = Data(repeating: 7, count: 32)
        let encoded = secret.base64EncodedString()
        XCTAssertEqual(PairingStore.validatedKVSPairingSecret(base64: encoded, publishedAt: "2026-08-24T01:00:00Z", ignoredPublishedAt: "2026-08-24T00:00:00Z"), secret)
        XCTAssertNil(PairingStore.validatedKVSPairingSecret(base64: encoded, publishedAt: "2026-08-24T00:00:00Z", ignoredPublishedAt: "2026-08-24T00:00:00Z"))
        XCTAssertNil(PairingStore.validatedKVSPairingSecret(base64: Data(repeating: 1, count: 31).base64EncodedString(), publishedAt: nil, ignoredPublishedAt: nil))
        XCTAssertNil(PairingStore.validatedKVSPairingSecret(base64: "bad", publishedAt: nil, ignoredPublishedAt: nil))
    }

    func testRejectedMessagesAlwaysGiveAPairingRecoveryLever() {
        XCTAssertTrue(ICloudBridgeRejectedMessage(messageID: "x", correlationID: nil, reason: "stale timestamp").userMessage.contains("clocks"))
        for reason in ["signature_invalid", "missing pairing secret", "tampered"] {
            XCTAssertTrue(ICloudBridgeRejectedMessage(messageID: "x", correlationID: nil, reason: reason).userMessage.contains("Re-pair"))
        }
    }

    private func restoreSuppression(_ value: Any?) {
        if let value {
            UserDefaults.standard.set(value, forKey: suppressionKey)
        } else {
            UserDefaults.standard.removeObject(forKey: suppressionKey)
        }
    }
}

// MARK: - ios.sync fence evals (2026-08-23, coverage ledger wave A)
//
// The pairing gate decides whether the ENTIRE app is usable. Every failure
// here is silent by construction: a gate that reads false shows a fully
// rendered app with every screen empty; a rejected QR key looks like a
// successful scan that never pairs; a retired bearer token left on disk is
// invisible until someone greps for it; a secret version that never persists
// makes the HMAC self-heal re-fetch forever (or never).
//
// Every test below is hermetic: UserDefaults keys are saved and restored, and
// the only durable-write path exercised goes through the injected `persist`
// closure, so no test touches the Keychain.
//
// Ledger rows: ios.pairing.gate, ios.pairing.legacyCredentialPurge,
// ios.pairing.knownSecretVersion, ios.pairing.applyICloudSecret,
// ios.pairing.applyCloudKitPairingSecret, ios.pairing.pairingNearExpiry.
@MainActor
final class PairingGateFenceTests: XCTestCase {

    private let retiredServerURLKey = "mobile.pairing.serverURL"
    private let retiredBearerTokenKey = "mobile.pairing.bearerToken"
    private let pairedKey = "mobile.pairing.iCloudPaired"
    private let knownSecretVersionKey = "mobile.pairing.knownSecretVersion"
    private let cloudKitSuppressionKey = "mobile.pairing.ignoredCloudKitSecretHash"

    private func withRestoredDefaults(_ keys: [String], _ body: () throws -> Void) rethrows {
        let saved = keys.map { ($0, UserDefaults.standard.object(forKey: $0)) }
        defer {
            for (key, value) in saved {
                if let value {
                    UserDefaults.standard.set(value, forKey: key)
                } else {
                    UserDefaults.standard.removeObject(forKey: key)
                }
            }
        }
        try body()
    }

    // MARK: ios.pairing.gate

    /// `usesICloudTransport` gates the whole app; `isPaired` gates signed
    /// sends. They are DIFFERENT predicates and the difference is deliberate:
    /// a Keychain-only bootstrap (secret present, flag not yet written) must
    /// still bring the app up. Collapsing them either bricks that device or
    /// lets it try to send unsigned messages the Mac will reject.
    func testTransportGateAndSignedGateDivergeExactlyWhereIntended() {
        withRestoredDefaults([pairedKey]) {
            let store = PairingStore()
            let secret = Data(repeating: 0x11, count: 32)

            // 1. Nothing at all → app is gated off.
            store.isICloudPaired = false
            store.iCloudPairingSecret = nil
            XCTAssertFalse(store.usesICloudTransport)
            XCTAssertFalse(store.isICloudSigned)
            XCTAssertFalse(store.isPaired)

            // 2. Keychain bootstrap raced ahead of the flag → transport is
            //    usable, but signed sends are NOT yet claimed.
            store.isICloudPaired = false
            store.iCloudPairingSecret = secret
            XCTAssertTrue(store.usesICloudTransport, "a Keychain-only bootstrap must still bring the app up")
            XCTAssertTrue(store.isICloudSigned)
            XCTAssertFalse(store.isPaired, "isPaired requires BOTH the flag and the secret")

            // 3. Flag survived an unpair that lost the secret → transport is
            //    attempted, signing is not. This is the state that renders a
            //    full app with empty screens; it must not report isPaired.
            store.isICloudPaired = true
            store.iCloudPairingSecret = nil
            XCTAssertTrue(store.usesICloudTransport)
            XCTAssertFalse(store.isICloudSigned)
            XCTAssertFalse(store.isPaired)

            // 4. Fully paired.
            store.isICloudPaired = true
            store.iCloudPairingSecret = secret
            XCTAssertTrue(store.usesICloudTransport)
            XCTAssertTrue(store.isICloudSigned)
            XCTAssertTrue(store.isPaired)
        }
    }

    /// The paired flag is the only piece of the gate that is persisted, and it
    /// is written by the property observer. A refactor that drops the `didSet`
    /// makes the app forget it is paired on every relaunch.
    func testPairedFlagIsPersistedByTheGateItself() {
        withRestoredDefaults([pairedKey]) {
            UserDefaults.standard.removeObject(forKey: pairedKey)
            let store = PairingStore()
            XCTAssertFalse(store.isICloudPaired)

            store.applyICloudPairing()
            XCTAssertTrue(store.isICloudPaired)
            XCTAssertTrue(
                UserDefaults.standard.bool(forKey: pairedKey),
                "the paired flag must reach UserDefaults or the gate resets on relaunch"
            )
        }
    }

    // MARK: ios.pairing.legacyCredentialPurge

    /// The retired LAN/HTTP credentials must be erased on every launch, not
    /// once. A bearer token left on disk is an inert credential nobody sees
    /// until it leaks; the removal being dropped in a refactor is invisible.
    func testLaunchPurgesRetiredHTTPCredentialsEveryTime() {
        withRestoredDefaults([retiredServerURLKey, retiredBearerTokenKey, pairedKey]) {
            UserDefaults.standard.set("http://192.168.1.20:8765", forKey: retiredServerURLKey)
            UserDefaults.standard.set("bearer-abc123", forKey: retiredBearerTokenKey)

            _ = PairingStore()

            XCTAssertNil(UserDefaults.standard.object(forKey: retiredServerURLKey))
            XCTAssertNil(UserDefaults.standard.object(forKey: retiredBearerTokenKey))

            // Idempotent: a downgrade-then-upgrade rewrites them, and the next
            // launch must sweep again rather than treating the purge as done.
            UserDefaults.standard.set("bearer-rewritten", forKey: retiredBearerTokenKey)
            _ = PairingStore()
            XCTAssertNil(UserDefaults.standard.object(forKey: retiredBearerTokenKey))
        }
    }

    // MARK: ios.pairing.knownSecretVersion

    /// The stale-secret check survives relaunches only if this actually
    /// persists. A value that never lands makes the HMAC self-heal either
    /// re-fetch on every launch or never notice a rotated Mac secret.
    func testKnownSecretVersionPersistsAndSurvivesAFreshStore() {
        withRestoredDefaults([knownSecretVersionKey, pairedKey]) {
            UserDefaults.standard.removeObject(forKey: knownSecretVersionKey)
            let store = PairingStore()
            XCTAssertEqual(store.knownSecretVersion, 0, "an unpaired device starts at version 0")

            store.knownSecretVersion = 7
            XCTAssertEqual(store.knownSecretVersion, 7)
            XCTAssertEqual(PairingStore().knownSecretVersion, 7, "the version must survive a relaunch")
        }
    }

    /// The Int64→Int hop at the setter is the narrowing hazard the ledger
    /// names. On a 64-bit device it is lossless; this pins that, so a value
    /// beyond Int32 cannot silently wrap into a LOWER version (which would
    /// make every subsequent rotation look stale and stop self-healing).
    func testLargeSecretVersionsRoundTripWithoutNarrowing() throws {
        try XCTSkipUnless(Int.bitWidth == 64, "narrowing is only lossless on a 64-bit word")
        withRestoredDefaults([knownSecretVersionKey, pairedKey]) {
            let store = PairingStore()
            for version: Int64 in [Int64(Int32.max), Int64(Int32.max) + 1, 4_294_967_296, 9_007_199_254_740_991] {
                store.knownSecretVersion = version
                XCTAssertEqual(store.knownSecretVersion, version, "version \(version) did not round trip")
                XCTAssertGreaterThan(store.knownSecretVersion, 0, "a wrapped version reads as stale forever")
            }
        }
    }

    // MARK: ios.pairing.applyICloudSecret

    /// The QR / paste path. Every rejection below currently returns false
    /// BEFORE any durable write, which is why this test is hermetic — and
    /// that ordering is itself the property: a guard that moved after the
    /// Keychain write would half-pair the device.
    func testMalformedPairingKeysAreRefusedWithoutTouchingPairedState() {
        withRestoredDefaults([pairedKey, cloudKitSuppressionKey]) {
            let store = PairingStore()
            store.isICloudPaired = false
            store.iCloudPairingSecret = nil

            let tooShort = Data(repeating: 0x22, count: 31).base64EncodedString()
            let tooLong = Data(repeating: 0x22, count: 33).base64EncodedString()
            // The exact silent-failure the ledger names: a QR/clipboard round
            // trip that picked up a newline. Foundation's default base64
            // decoder rejects it, so the scan "works" and nothing pairs.
            let withNewline = Data(repeating: 0x22, count: 32).base64EncodedString() + "\n"

            for bad in [tooShort, tooLong, withNewline, "", "not base64 at all", "   "] {
                XCTAssertFalse(
                    store.applyICloudSecret(base64: bad),
                    "\(bad.debugDescription) must be refused"
                )
                XCTAssertNil(store.iCloudPairingSecret, "a refused key must not reach published state")
                XCTAssertFalse(store.isICloudPaired, "a refused key must not flip the paired gate")
            }
        }
    }

    // MARK: ios.pairing.applyCloudKitPairingSecret

    /// The CloudKit pairing lane, driven entirely through the injected
    /// persist closure so the durable boundary is provable without a Keychain.
    /// The transactional property: published state changes ONLY after the
    /// durable write reports success.
    func testCloudKitPairingCommitsPublishedStateOnlyAfterADurableWrite() {
        withRestoredDefaults([pairedKey, cloudKitSuppressionKey]) {
            UserDefaults.standard.removeObject(forKey: cloudKitSuppressionKey)
            let store = PairingStore()
            store.isICloudPaired = false
            store.iCloudPairingSecret = nil

            let secret = Data(repeating: 0x33, count: 32)

            // A failed durable write must leave the device UNPAIRED.
            var persistCalls = 0
            let failed = store.applyCloudKitPairingSecret(secret) { _ in
                persistCalls += 1
                return errSecInteractionNotAllowed   // Keychain locked
            }
            XCTAssertFalse(failed)
            XCTAssertEqual(persistCalls, 1)
            XCTAssertNil(store.iCloudPairingSecret, "a failed Keychain write must not publish a secret")
            XCTAssertFalse(store.isICloudPaired, "a failed Keychain write must not flip the paired gate")

            // A successful durable write commits both.
            var durable: Data?
            let ok = store.applyCloudKitPairingSecret(secret) { value in
                durable = value
                return errSecSuccess
            }
            XCTAssertTrue(ok)
            XCTAssertEqual(durable, secret)
            XCTAssertEqual(store.iCloudPairingSecret, secret)
            XCTAssertTrue(store.isICloudPaired)
        }
    }

    /// A wrong-length secret must never reach the durable writer at all — the
    /// length guard is what keeps a truncated CloudKit record from installing
    /// an unusable HMAC key that then fails every signature silently.
    func testWrongLengthCloudKitSecretsNeverReachTheDurableWriter() {
        withRestoredDefaults([pairedKey, cloudKitSuppressionKey]) {
            UserDefaults.standard.removeObject(forKey: cloudKitSuppressionKey)
            let store = PairingStore()
            store.isICloudPaired = false
            store.iCloudPairingSecret = nil

            for count in [0, 16, 31, 33, 64] {
                var persistCalls = 0
                let accepted = store.applyCloudKitPairingSecret(Data(repeating: 0x44, count: count)) { _ in
                    persistCalls += 1
                    return errSecSuccess
                }
                XCTAssertFalse(accepted, "\(count)-byte secret must be refused")
                XCTAssertEqual(persistCalls, 0, "\(count)-byte secret reached the Keychain writer")
                XCTAssertFalse(store.shouldAcceptCloudKitPairingSecret(Data(repeating: 0x44, count: count)))
            }
            XCTAssertTrue(store.shouldAcceptCloudKitPairingSecret(Data(repeating: 0x44, count: 32)))
        }
    }

    /// A deliberate unpair suppresses ONLY the exact secret that was cleared.
    /// Suppressing by device (or forever) is the shape that makes re-pairing
    /// impossible with no error; accepting everything is the shape that makes
    /// an unpair not stick.
    func testUnpairSuppressionIsScopedToTheExactClearedSecret() {
        withRestoredDefaults([cloudKitSuppressionKey, pairedKey]) {
            let cleared = Data(repeating: 0x55, count: 32)
            let rotated = Data(repeating: 0x56, count: 32)
            let clearedHash = SHA256.hash(data: cleared).map { String(format: "%02x", $0) }.joined()
            UserDefaults.standard.set(clearedHash, forKey: cloudKitSuppressionKey)

            let store = PairingStore()
            XCTAssertFalse(store.shouldAcceptCloudKitPairingSecret(cleared),
                           "the exact unpaired secret must stay suppressed")
            XCTAssertTrue(store.shouldAcceptCloudKitPairingSecret(rotated),
                          "a rotated Mac secret must re-pair without a manual fallback")

            // Installing the rotated secret clears the suppression so the
            // latch cannot outlive the pairing it was about.
            var persisted: Data?
            XCTAssertTrue(store.applyCloudKitPairingSecret(rotated) { persisted = $0; return errSecSuccess })
            XCTAssertEqual(persisted, rotated)
            XCTAssertNil(
                UserDefaults.standard.string(forKey: cloudKitSuppressionKey),
                "a successful install must clear the unpair suppression latch"
            )
        }
    }

    // MARK: ios.pairing.pairingNearExpiry — a DEAD surface, pinned dead

    /// `pairingNearExpiry` reads a value nothing ever assigns, so it is
    /// constant-false in the shipped app. That is fine today (iCloud pairing
    /// has no TTL handshake) but the verdict is undated and unguarded: the day
    /// someone wires `lastKnownExpiresAt`, a live expiry warning appears with
    /// zero coverage. This test holds the verdict AND fails the moment it
    /// stops being true, forcing a real eval at that point.
    func testPairingExpiryIsProvablyDormantInTheShippedApp() throws {
        withRestoredDefaults([pairedKey]) {
            let store = PairingStore()
            XCTAssertNil(store.lastKnownExpiresAt)
            XCTAssertFalse(store.pairingNearExpiry, "with no expiry known, nothing is near expiry")

            // The predicate itself is correct — it is the INPUT that is dead.
            store.lastKnownExpiresAt = Date().addingTimeInterval(60 * 24 * 3600)
            XCTAssertFalse(store.pairingNearExpiry)
            store.lastKnownExpiresAt = Date().addingTimeInterval(3 * 24 * 3600)
            XCTAssertTrue(store.pairingNearExpiry)
        }

        // …and nothing in the shipped sources assigns it.
        let sources = try Self.mobileSourcesRoot()
        var assignments: [String] = []
        let walker = FileManager.default.enumerator(at: sources, includingPropertiesForKeys: nil)
        for case let url as URL in walker! where url.pathExtension == "swift" {
            guard let text = try? String(contentsOf: url, encoding: .utf8) else { continue }
            for line in text.split(separator: "\n") {
                let trimmed = line.trimmingCharacters(in: .whitespaces)
                guard trimmed.contains("lastKnownExpiresAt") else { continue }
                // The declaration itself is not an assignment.
                if trimmed.hasPrefix("@Published var lastKnownExpiresAt") { continue }
                if trimmed.hasPrefix("///") || trimmed.hasPrefix("//") { continue }
                if trimmed.contains("guard let exp = lastKnownExpiresAt") { continue }
                assignments.append("\(url.lastPathComponent): \(trimmed)")
            }
        }
        XCTAssertTrue(
            assignments.isEmpty,
            "lastKnownExpiresAt is now written — the expiry banner is live and needs its own eval: \(assignments)"
        )
    }

    private static func mobileSourcesRoot() throws -> URL {
        var directory = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
        for _ in 0..<6 {
            let sources = directory.appendingPathComponent("Sources", isDirectory: true)
            let project = directory.appendingPathComponent("project.yml")
            if FileManager.default.fileExists(atPath: sources.path),
               FileManager.default.fileExists(atPath: project.path) {
                return sources
            }
            let parent = directory.deletingLastPathComponent()
            if parent.path == directory.path { break }
            directory = parent
        }
        throw NSError(
            domain: "PairingGateFenceTests",
            code: 1,
            userInfo: [NSLocalizedDescriptionKey: "Could not locate NativeAgentMobile/Sources from \(#filePath)"]
        )
    }
}
