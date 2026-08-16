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

    private func restoreSuppression(_ value: Any?) {
        if let value {
            UserDefaults.standard.set(value, forKey: suppressionKey)
        } else {
            UserDefaults.standard.removeObject(forKey: suppressionKey)
        }
    }
}
